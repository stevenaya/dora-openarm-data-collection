#!/usr/bin/env bash
# Install local Dora nodes while letting the parent repo selectively own deps.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/install-node.sh NODE_PATH [NODE_PATH ...]

If DORA_PARENT_DEP_OVERRIDES is empty, each node is installed normally.
If it contains package names, parent-owned dependencies are refreshed from the
parent repo first; the remaining node dependencies are installed from the
node's own pyproject.toml and tool.uv.sources.
USAGE
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${repo_root}/.venv/.dora_env"
if [ -f "${env_file}" ]; then
  # shellcheck source=/dev/null
  source "${env_file}"
fi

overrides="${DORA_PARENT_DEP_OVERRIDES:-}"
python_args=()
if [ -x "${repo_root}/.venv/bin/python" ]; then
  python_args=(--python "${repo_root}/.venv/bin/python")
fi

if [ -z "${overrides}" ]; then
  if [ -n "${DORA_NODE_INSTALLER:-}" ]; then
    read -r -a install_cmd <<< "${DORA_NODE_INSTALLER}"
  elif command -v uv >/dev/null 2>&1; then
    for node_path in "$@"; do
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
  for node_path in "$@"; do
    args+=(-e "${node_path}")
  done
  "${install_cmd[@]}" "${args[@]}"
  exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required when DORA_PARENT_DEP_OVERRIDES is set" >&2
  exit 1
fi

for group in ${DORA_PARENT_DEP_GROUPS:-}; do
  uv pip install "${python_args[@]}" --project "${repo_root}" --group "${group}"
done

if [ -n "${DORA_PARENT_REQUIREMENTS_FILE:-}" ]; then
  if [ ! -f "${DORA_PARENT_REQUIREMENTS_FILE}" ]; then
    echo "missing ${DORA_PARENT_REQUIREMENTS_FILE}" >&2
    echo "run scripts/setup-env.sh before building nodes with local editable overrides" >&2
    exit 1
  fi
  uv pip install "${python_args[@]}" --project "${repo_root}" -r "${DORA_PARENT_REQUIREMENTS_FILE}"
fi

for node_path in "$@"; do
  if [ ! -f "${node_path}/pyproject.toml" ]; then
    echo "missing ${node_path}/pyproject.toml" >&2
    exit 1
  fi

  mapfile -t install_deps < <(
    python3 - "${node_path}" "${overrides}" <<'PY'
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


def requirement_name(spec: str) -> str:
    spec = spec.split(";", 1)[0].strip()
    if " @ " in spec:
        spec = spec.split(" @ ", 1)[0].strip()
    match = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)", spec)
    return re.sub(r"[-_.]+", "-", match.group(1)).lower() if match else ""


with (node_path / "pyproject.toml").open("rb") as file:
    data = tomllib.load(file)

for dependency in data.get("project", {}).get("dependencies", []):
    name = requirement_name(dependency)
    if name and name in overrides:
        continue
    print(dependency)
PY
  )

  if [ "${#install_deps[@]}" -gt 0 ]; then
    uv pip install "${python_args[@]}" --project "${node_path}" "${install_deps[@]}"
  fi

  uv pip install "${python_args[@]}" --no-deps -e "${node_path}"
done
