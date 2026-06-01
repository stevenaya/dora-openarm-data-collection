#!/usr/bin/env bash
# Install local Dora nodes while letting the parent repo selectively own deps.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/install-node.sh [-e|--editable] NODE [NODE ...]

NODE may be a path or a node name under nodes/. -e/--editable forces local
node installation even when DORA_NODE_OVERRIDE_FILE contains a remote override.

If DORA_PARENT_DEP_OVERRIDES is empty, each node is installed normally.
If it contains package names, parent-owned dependencies are refreshed from the
parent repo first; the remaining node dependencies are installed from the
node's own pyproject.toml and tool.uv.sources.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

node_paths=()
force_local_nodes=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e|--editable)
      force_local_nodes=1
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing node after -e/--editable" >&2
        exit 2
      fi
      node_paths+=("$1")
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        node_paths+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      node_paths+=("$1")
      ;;
  esac
  shift
done

if [ "${#node_paths[@]}" -lt 1 ]; then
  usage >&2
  exit 2
fi

set -- "${node_paths[@]}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${repo_root}/.venv/.dora_env"
if [ -f "${env_file}" ]; then
  # shellcheck source=/dev/null
  source "${env_file}"
fi

overrides="${DORA_PARENT_DEP_OVERRIDES:-}"
node_override_file="${DORA_NODE_OVERRIDE_FILE:-}"
python_args=()
if [ -x "${repo_root}/.venv/bin/python" ]; then
  python_args=(--python "${repo_root}/.venv/bin/python")
fi

resolve_node_path() {
  local value="$1"
  local candidate

  for candidate in "${value}" "${repo_root}/${value}" "${repo_root}/nodes/${value}"; do
    if [ -f "${candidate}/pyproject.toml" ]; then
      (cd "${candidate}" && pwd)
      return 0
    fi
  done

  return 1
}

node_override_spec() {
  local node_input="$1"
  local node_path="$2"

  if [ "${force_local_nodes}" -eq 1 ] || [ -z "${node_override_file}" ] || [ ! -f "${node_override_file}" ]; then
    return 0
  fi

  python3 - "${node_override_file}" "${repo_root}" "${node_input}" "${node_path}" <<'PY'
from __future__ import annotations

import shlex
import sys
from pathlib import Path

override_file = Path(sys.argv[1])
repo_root = Path(sys.argv[2]).resolve()
node_input = sys.argv[3]
node_path = sys.argv[4]


def normalize_path(value: str) -> str:
    return value.replace("\\", "/").strip("/")


keys = {normalize_path(node_input), Path(node_input).name}
if "/" not in normalize_path(node_input):
    keys.add(f"nodes/{normalize_path(node_input)}")
if node_path:
    resolved = Path(node_path).resolve()
    keys.add(resolved.name)
    try:
        keys.add(resolved.relative_to(repo_root).as_posix())
    except ValueError:
        pass

with override_file.open(encoding="utf-8") as file:
    for raw_line in file:
        parts = shlex.split(raw_line, comments=True)
        if not parts:
            continue
        if len(parts) != 3:
            raise SystemExit(f"{override_file} lines must be: path url rev; got {raw_line.rstrip()}")
        path, url, rev = parts
        if normalize_path(path) in keys or Path(path).name in keys:
            print(f"{path}\t{url}\t{rev}")
            break
PY
}

install_node_dependencies() {
  local node_path="$1"

  if [ ! -f "${node_path}/pyproject.toml" ]; then
    return 0
  fi

  local deps_file
  deps_file="$(mktemp)"
  python3 - "${node_path}" "${overrides}" > "${deps_file}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib

node_path = Path(sys.argv[1])
overrides = {
    re.sub(r"[-_.]+", "-", name).lower()
    for name in sys.argv[2].split()
    if name.strip()
}


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def requirement_name(spec: str) -> str:
    spec = spec.split(";", 1)[0].strip()
    if " @ " in spec:
        spec = spec.split(" @ ", 1)[0].strip()
    match = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)", spec)
    return normalize(match.group(1)) if match else ""


def source_requirement(name: str, source: object) -> str | None:
    if not isinstance(source, dict):
        return None

    if git_url := source.get("git"):
        requirement = f"{name} @ git+{git_url}"
        if rev := source.get("rev"):
            requirement = f"{requirement}@{rev}"
        if subdirectory := source.get("subdirectory"):
            requirement = f"{requirement}#subdirectory={subdirectory}"
        return requirement

    if path_value := source.get("path"):
        path = Path(path_value)
        if not path.is_absolute():
            path = (node_path / path).resolve()
        return f"{name} @ file://{path}"

    if url := source.get("url"):
        return f"{name} @ {url}"

    return None


with (node_path / "pyproject.toml").open("rb") as file:
    data = tomllib.load(file)

sources = {
    normalize(name): source
    for name, source in data.get("tool", {}).get("uv", {}).get("sources", {}).items()
}

for dependency in data.get("project", {}).get("dependencies", []):
    name = requirement_name(dependency)
    if name and name in overrides:
        continue
    print(source_requirement(name, sources.get(name)) or dependency)
PY
  mapfile -t install_deps < "${deps_file}"
  rm -f "${deps_file}"

  if [ "${#install_deps[@]}" -gt 0 ]; then
    uv pip install "${python_args[@]}" --project "${node_path}" "${install_deps[@]}"
  fi
}

install_parent_requirements_file() {
  if [ -z "${DORA_PARENT_REQUIREMENTS_FILE:-}" ]; then
    return 0
  fi
  if [ ! -f "${DORA_PARENT_REQUIREMENTS_FILE}" ]; then
    echo "missing ${DORA_PARENT_REQUIREMENTS_FILE}" >&2
    echo "run scripts/setup-env.sh before building nodes with local editable overrides" >&2
    exit 1
  fi
  uv pip install "${python_args[@]}" --project "${repo_root}" -r "${DORA_PARENT_REQUIREMENTS_FILE}"
}

if [ -z "${overrides}" ] && { [ -z "${node_override_file}" ] || [ "${force_local_nodes}" -eq 1 ]; }; then
  if [ -n "${DORA_NODE_INSTALLER:-}" ]; then
    read -r -a install_cmd <<< "${DORA_NODE_INSTALLER}"
  elif command -v uv >/dev/null 2>&1; then
    for node_input in "$@"; do
      node_path="$(resolve_node_path "${node_input}" || true)"
      if [ -z "${node_path}" ]; then
        echo "missing node ${node_input}; expected a path or nodes/${node_input}" >&2
        exit 1
      fi
      uv pip install "${python_args[@]}" --project "${node_path}" -e "${node_path}"
    done
    exit 0
  elif [ -x "${repo_root}/.venv/bin/python" ]; then
    install_cmd=("${repo_root}/.venv/bin/python" -m pip install)
  elif command -v pip >/dev/null 2>&1; then
    install_cmd=(pip install)
  else
    install_cmd=(python3 -m pip install)
  fi

  args=()
  for node_input in "$@"; do
    node_path="$(resolve_node_path "${node_input}" || true)"
    if [ -z "${node_path}" ]; then
      echo "missing node ${node_input}; expected a path or nodes/${node_input}" >&2
      exit 1
    fi
    args+=(-e "${node_path}")
  done
  "${install_cmd[@]}" "${args[@]}"
  exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required when parent dependency or node overrides are set" >&2
  exit 1
fi

for group in ${DORA_PARENT_DEP_GROUPS:-}; do
  uv pip install "${python_args[@]}" --project "${repo_root}" --group "${group}"
done

install_parent_requirements_file

for node_input in "$@"; do
  node_path="$(resolve_node_path "${node_input}" || true)"
  override_spec="$(node_override_spec "${node_input}" "${node_path}" || true)"

  if [ -n "${override_spec}" ]; then
    IFS=$'\t' read -r override_path override_url override_rev <<< "${override_spec}"
    if [ -n "${node_path}" ]; then
      install_node_dependencies "${node_path}"
      install_parent_requirements_file
    else
      echo "warning: ${override_path} is installed from a remote override without local dependency filtering" >&2
    fi
    uv pip install "${python_args[@]}" --no-deps "git+${override_url}@${override_rev}"
    continue
  fi

  if [ -z "${node_path}" ]; then
    echo "missing node ${node_input}; expected a path or nodes/${node_input}" >&2
    exit 1
  fi

  install_node_dependencies "${node_path}"
  install_parent_requirements_file
  uv pip install "${python_args[@]}" --no-deps -e "${node_path}"
done
