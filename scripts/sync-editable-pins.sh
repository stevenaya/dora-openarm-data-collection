#!/usr/bin/env bash
# Update parent pyproject git pins from requirements-local/editable.txt.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/sync-editable-pins.sh [--requirements FILE] [--pyproject FILE] [--dry-run] [--allow-dirty]

Reads editable local packages from requirements-local/editable.txt, detects each
package's git remote, current commit, and subdirectory, then updates only those
packages in the parent pyproject.toml.

By default, the script fails if a local package repository has uncommitted
changes, because those changes cannot be reproduced from a commit pin.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
requirements_file="${repo_root}/requirements-local/editable.txt"
pyproject_file="${repo_root}/pyproject.toml"
dry_run=0
allow_dirty=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --requirements)
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing value for --requirements" >&2
        exit 2
      fi
      requirements_file="$1"
      ;;
    --pyproject)
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing value for --pyproject" >&2
        exit 2
      fi
      pyproject_file="$1"
      ;;
    --dry-run)
      dry_run=1
      ;;
    --allow-dirty)
      allow_dirty=1
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

python3 - "${repo_root}" "${requirements_file}" "${pyproject_file}" "${dry_run}" "${allow_dirty}" <<'PY'
from __future__ import annotations

import difflib
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib

repo_root = Path(sys.argv[1]).resolve()
requirements_file = Path(sys.argv[2])
pyproject_file = Path(sys.argv[3])
dry_run = sys.argv[4] == "1"
allow_dirty = sys.argv[5] == "1"

if not requirements_file.is_absolute():
    requirements_file = (repo_root / requirements_file).resolve()
if not pyproject_file.is_absolute():
    pyproject_file = (repo_root / pyproject_file).resolve()


@dataclass(frozen=True)
class Pin:
    name: str
    git: str
    rev: str
    subdirectory: str
    path: Path


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def run_git(path: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(path), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def try_git(path: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(path), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def editable_target(line: str) -> str:
    tokens = shlex.split(line)
    if len(tokens) >= 2 and tokens[0] in {"-e", "--editable"}:
        return tokens[1]
    for token in tokens:
        if token.startswith("--editable="):
            return token.split("=", 1)[1]
    return ""


def resolve_editable_path(target: str) -> Path:
    candidate = Path(target)
    if candidate.is_absolute():
        return candidate.resolve()

    candidates = [
        (repo_root / candidate).resolve(),
        (requirements_file.parent / candidate).resolve(),
    ]
    for path in candidates:
        if path.exists():
            return path
    return candidates[0]


def project_name(path: Path) -> str:
    pyproject = path / "pyproject.toml"
    if not pyproject.exists():
        raise SystemExit(f"{path} does not contain pyproject.toml")
    with pyproject.open("rb") as file:
        data = tomllib.load(file)
    name = data.get("project", {}).get("name", "")
    if not name:
        raise SystemExit(f"{pyproject} does not define [project].name")
    return normalize(name)


def editable_paths() -> list[Path]:
    if not requirements_file.exists():
        raise SystemExit(f"missing {requirements_file}")

    paths: list[Path] = []
    with requirements_file.open(encoding="utf-8") as file:
        for raw_line in file:
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue
            target = editable_target(line)
            if target:
                paths.append(resolve_editable_path(target))
    return paths


def pin_from_path(path: Path) -> Pin:
    name = project_name(path)
    git_root = Path(run_git(path, "rev-parse", "--show-toplevel")).resolve()

    status = run_git(git_root, "status", "--porcelain")
    if status and not allow_dirty:
        raise SystemExit(
            f"{git_root} has uncommitted changes; commit them first or use --allow-dirty"
        )

    remote_name = try_git(git_root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if remote_name:
        remote_name = remote_name.split("/", 1)[0]
    else:
        remote_name = "origin"
    remote = run_git(git_root, "remote", "get-url", remote_name)
    rev = run_git(git_root, "rev-parse", "HEAD")
    rel = path.resolve().relative_to(git_root)
    subdirectory = "" if str(rel) == "." else rel.as_posix()
    return Pin(name=name, git=remote, rev=rev, subdirectory=subdirectory, path=path)


def source_line(pin: Pin) -> str:
    parts = [f"git = {toml_string(pin.git)}", f"rev = {toml_string(pin.rev)}"]
    if pin.subdirectory:
        parts.append(f"subdirectory = {toml_string(pin.subdirectory)}")
    return f"{pin.name} = {{ {', '.join(parts)} }}\n"


def table_bounds(lines: list[str], header: str) -> tuple[int, int] | None:
    start = None
    for index, line in enumerate(lines):
        if line.strip() == header:
            start = index
            break
    if start is None:
        return None

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if re.match(r"\s*\[", lines[index]):
            end = index
            break
    return start, end


def update_sources(lines: list[str], pins: list[Pin]) -> list[str]:
    bounds = table_bounds(lines, "[tool.uv.sources]")
    if bounds is None:
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.append("[tool.uv.sources]\n")
        bounds = len(lines) - 1, len(lines)

    start, end = bounds
    for pin in pins:
        pattern = re.compile(rf"^\s*{re.escape(pin.name)}\s*=")
        replacement = source_line(pin)
        for index in range(start + 1, end):
            if pattern.match(lines[index]):
                lines[index] = replacement
                break
        else:
            lines.insert(end, replacement)
            end += 1
    return lines


def update_core_group(lines: list[str], pins: list[Pin]) -> list[str]:
    package_names = [pin.name for pin in pins]
    bounds = table_bounds(lines, "[dependency-groups]")
    if bounds is None:
        insert_at = 0
        project_bounds = table_bounds(lines, "[project]")
        if project_bounds is not None:
            insert_at = project_bounds[1]
        lines[insert_at:insert_at] = ["\n", "[dependency-groups]\n", "core-pinned = [\n", "]\n"]
        bounds = insert_at + 1, insert_at + 4

    start, end = bounds
    group_start = None
    for index in range(start + 1, end):
        if re.match(r"\s*core-pinned\s*=\s*\[", lines[index]):
            group_start = index
            break

    if group_start is None:
        lines.insert(end, "core-pinned = [\n")
        lines.insert(end + 1, "]\n")
        group_start = end
        end += 2

    group_end = None
    for index in range(group_start + 1, len(lines)):
        if lines[index].strip() == "]":
            group_end = index
            break
    if group_end is None:
        raise SystemExit("could not find end of dependency-groups.core-pinned")

    existing = {
        normalize(match.group(1))
        for line in lines[group_start + 1 : group_end]
        if (match := re.search(r'"([^"]+)"', line))
    }
    for name in package_names:
        if name not in existing:
            lines.insert(group_end, f'  "{name}",\n')
            group_end += 1
            existing.add(name)
    return lines


paths = editable_paths()
if not paths:
    raise SystemExit(f"no editable paths found in {requirements_file}")

pins = [pin_from_path(path) for path in paths]
original = pyproject_file.read_text(encoding="utf-8").splitlines(keepends=True)
updated = update_sources(original.copy(), pins)
updated = update_core_group(updated, pins)

for pin in pins:
    suffix = f", subdirectory={pin.subdirectory}" if pin.subdirectory else ""
    print(f"{pin.name}: {pin.git} @ {pin.rev}{suffix}")

if updated == original:
    print(f"{pyproject_file} already up to date.")
    raise SystemExit(0)

if dry_run:
    print(f"\nDry run: {pyproject_file} would change:\n")
    sys.stdout.writelines(
        difflib.unified_diff(
            original,
            updated,
            fromfile=str(pyproject_file),
            tofile=str(pyproject_file),
        )
    )
else:
    pyproject_file.write_text("".join(updated), encoding="utf-8")
    print(f"Updated {pyproject_file}")
PY
