#!/usr/bin/env bash
# Prepare the Python environment used by the parent dataflow repository.

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  setup_env_script="${BASH_SOURCE[0]}"
  case "${1:-}" in
    -h|--help)
      bash "${setup_env_script}" "$@"
      return $?
      ;;
  esac

  DORA_SETUP_ENV_CALLED_FROM_SOURCE=1 bash "${setup_env_script}" "$@"
  setup_env_status=$?
  if [ "${setup_env_status}" -eq 0 ]; then
    setup_env_repo_root="$(cd "$(dirname "${setup_env_script}")/.." && pwd)"
    # shellcheck source=/dev/null
    source "${setup_env_repo_root}/.venv/bin/activate"
    echo "Activated ${setup_env_repo_root}/.venv"
  fi
  setup_env_return_status="${setup_env_status}"
  unset setup_env_script setup_env_status setup_env_repo_root
  return "${setup_env_return_status}"
fi

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: source scripts/setup-env.sh [--dev | -e|--editable]

Modes:
  default       Sync dependencies from the parent pyproject.toml.
  --dev         Sync parent deps plus pinned core deps and development tools.
  -e, --editable
                Sync parent deps plus development tools and
                dev/requirements-local/editable.txt.

Use `source` so the script can activate .venv in the current shell.
USAGE
}

mode="default"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dev)
      mode="dev"
      ;;
    -e|--editable)
      mode="editable"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

find_uv() {
  local candidate

  if [ -n "${UV:-}" ] && [ -x "${UV}" ]; then
    printf '%s\n' "${UV}"
    return 0
  fi

  for candidate in "${HOME}/.local/bin/uv" /usr/local/bin/uv /usr/bin/uv; do
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  candidate="$(command -v uv || true)"
  if [ -n "${candidate}" ]; then
    case "${candidate}" in
      "${repo_root}/.venv/"*)
        echo "uv resolves to ${candidate}, which may be replaced by this script." >&2
        echo "Install uv outside the project virtualenv or set UV=/path/to/uv." >&2
        return 1
        ;;
      *)
        printf '%s\n' "${candidate}"
        return 0
        ;;
    esac
  fi

  echo "uv is required. Install uv outside the project virtualenv first." >&2
  return 1
}

sync_submodules() {
  local clean_submodules=()
  local dirty_submodules=()
  local path

  if [ ! -f "${repo_root}/.gitmodules" ]; then
    return 0
  fi

  echo "Syncing submodule URLs..."
  git submodule sync --recursive

  while IFS= read -r path; do
    if git -C "${path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ -n "$(git -C "${path}" status --porcelain)" ]; then
        dirty_submodules+=("${path}")
        continue
      fi
    fi
    clean_submodules+=("${path}")
  done < <(git config --file "${repo_root}/.gitmodules" --get-regexp 'submodule\..*\.path' | sed 's/^[^ ]* //')

  if [ "${#dirty_submodules[@]}" -gt 0 ]; then
    echo "Skipping dirty submodules with uncommitted changes:" >&2
    for path in "${dirty_submodules[@]}"; do
      echo "  ${path}" >&2
    done
    echo "Commit, stash, or discard those changes before updating them." >&2
  fi

  if [ "${#clean_submodules[@]}" -gt 0 ]; then
    echo "Updating clean submodules..."
    git submodule update --init --recursive -- "${clean_submodules[@]}"
  fi
}

uv_bin="$(find_uv)"
local_requirements=""

if [ "${mode}" = "editable" ]; then
  local_requirements="${repo_root}/dev/requirements-local/editable.txt"
  if [ ! -f "${local_requirements}" ]; then
    echo "missing ${local_requirements}" >&2
    echo "copy dev/requirements-local/editable.example.txt to dev/requirements-local/editable.txt and edit paths." >&2
    exit 1
  fi
fi

python_args=()
if [ -n "${PYTHON_VERSION:-}" ]; then
  python_args=(-p "${PYTHON_VERSION}")
fi

sync_submodules

"${uv_bin}" venv --seed --allow-existing "${python_args[@]}"

sync_args=(sync --no-install-project)
override_groups=()
case "${mode}" in
  dev)
    sync_args+=(--group core-pinned --group dev-tools)
    override_groups+=(core-pinned)
    ;;
  editable)
    sync_args+=(--group dev-tools)
    ;;
esac

"${uv_bin}" "${sync_args[@]}"

case "${mode}" in
  editable)
    "${uv_bin}" pip install --python "${repo_root}/.venv/bin/python" -r "${local_requirements}"
    ;;
esac

overrides="$(
  python3 - "${repo_root}" "${mode}" "${override_groups[@]}" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib

repo_root = Path(sys.argv[1])
mode = sys.argv[2]
groups = sys.argv[3:]


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def requirement_name(spec: str) -> str:
    spec = spec.split(";", 1)[0].strip()
    if " @ " in spec:
        spec = spec.split(" @ ", 1)[0].strip()
    match = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)", spec)
    return normalize(match.group(1)) if match else ""


def load_pyproject(path: Path) -> dict:
    with path.open("rb") as file:
        return tomllib.load(file)


def package_name_from_path(path: Path) -> str:
    pyproject_path = path / "pyproject.toml"
    if not pyproject_path.exists():
        return ""
    data = load_pyproject(pyproject_path)
    return normalize(data.get("project", {}).get("name", ""))


def editable_path(line: str) -> str:
    if line.startswith("-e "):
        return line[3:].strip()
    if line.startswith("--editable "):
        return line[len("--editable ") :].strip()
    return ""


def requirement_file_names(path: Path) -> set[str]:
    names: set[str] = set()
    with path.open(encoding="utf-8") as file:
        for raw_line in file:
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue
            editable = editable_path(line)
            if editable:
                candidate = Path(editable)
                candidates = (
                    [candidate]
                    if candidate.is_absolute()
                    else [repo_root / candidate, path.parent / candidate]
                )
                for candidate_path in candidates:
                    name = package_name_from_path(candidate_path)
                    if name:
                        names.add(name)
                        break
                continue
            if name := requirement_name(line):
                names.add(name)
    return names


parent = load_pyproject(repo_root / "pyproject.toml")
dependency_groups = parent.get("dependency-groups", {})

names: set[str] = set()
for group in groups:
    for requirement in dependency_groups.get(group, []):
        if name := requirement_name(requirement):
            names.add(name)

if mode == "editable":
    names.update(requirement_file_names(repo_root / "dev" / "requirements-local" / "editable.txt"))

print(" ".join(sorted(names)))
PY
)"

env_file="${repo_root}/.venv/.dora_env"
override_group_value="${override_groups[*]}"
cat > "${env_file}" <<EOF
export VIRTUAL_ENV="${repo_root}/.venv"
case ":\$PATH:" in
  *":${repo_root}/.venv/bin:"*) ;;
  *) export PATH="${repo_root}/.venv/bin:\$PATH" ;;
esac
export DORA_PARENT_DEP_OVERRIDES="${overrides}"
export DORA_PARENT_DEP_GROUPS="${override_group_value}"
export DORA_PARENT_REQUIREMENTS_FILE="${local_requirements}"
EOF

activate_file="${repo_root}/.venv/bin/activate"
if [ -f "${activate_file}" ] && ! grep -q 'dora-openarm-data-collection env' "${activate_file}"; then
  cat >> "${activate_file}" <<'EOF'

# dora-openarm-data-collection env
if [ -f "$VIRTUAL_ENV/.dora_env" ]; then
  # shellcheck source=/dev/null
  source "$VIRTUAL_ENV/.dora_env"
fi
EOF
fi

echo "Environment ready (${mode})."
echo "Environment file: ${env_file}"
echo "Parent dependency overrides: ${overrides:-none}"
if [ "${DORA_SETUP_ENV_CALLED_FROM_SOURCE:-0}" != "1" ]; then
  echo "Run: source .venv/bin/activate"
fi
