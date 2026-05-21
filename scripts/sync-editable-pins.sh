#!/usr/bin/env bash
# Update parent pyproject git pins from requirements-local/editable.txt.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/sync-editable-pins.sh [options]

Reads editable local packages from requirements-local/editable.txt, detects each
package's git remote, current commit, and subdirectory, then updates only those
packages in the parent pyproject.toml.

By default, the script fails if a local package repository has uncommitted
changes, because those changes cannot be reproduced from a commit pin.

Options:
  --requirements FILE       Editable requirements file.
  --pyproject FILE          Parent pyproject.toml to update.
  --dry-run                 Print diffs without writing files.
  --allow-dirty             Allow dirty editable package/submodule repos.
  --sync-gitmodules         Update .gitmodules URLs from remotes containing submodule HEAD.
  --gitmodules-only         Only update .gitmodules URLs.
  --gitmodules FILE         .gitmodules file to update.
  --submodule PATH          Submodule path to update. May be repeated.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
requirements_file="${repo_root}/requirements-local/editable.txt"
pyproject_file="${repo_root}/pyproject.toml"
gitmodules_file="${repo_root}/.gitmodules"
dry_run=0
allow_dirty=0
sync_gitmodules=0
gitmodules_only=0
submodule_paths=()

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
    --sync-gitmodules)
      sync_gitmodules=1
      ;;
    --gitmodules-only)
      sync_gitmodules=1
      gitmodules_only=1
      ;;
    --gitmodules)
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing value for --gitmodules" >&2
        exit 2
      fi
      gitmodules_file="$1"
      ;;
    --submodule)
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing value for --submodule" >&2
        exit 2
      fi
      sync_gitmodules=1
      submodule_paths+=("$1")
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

python3 - \
  "${repo_root}" \
  "${requirements_file}" \
  "${pyproject_file}" \
  "${dry_run}" \
  "${allow_dirty}" \
  "${sync_gitmodules}" \
  "${gitmodules_only}" \
  "${gitmodules_file}" \
  -- "${submodule_paths[@]}" <<'PY'
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
sync_gitmodules = sys.argv[6] == "1"
gitmodules_only = sys.argv[7] == "1"
gitmodules_file = Path(sys.argv[8])
submodule_paths = sys.argv[10:]

if not requirements_file.is_absolute():
    requirements_file = (repo_root / requirements_file).resolve()
if not pyproject_file.is_absolute():
    pyproject_file = (repo_root / pyproject_file).resolve()
if not gitmodules_file.is_absolute():
    gitmodules_file = (repo_root / gitmodules_file).resolve()


@dataclass(frozen=True)
class Pin:
    name: str
    git: str
    rev: str
    subdirectory: str
    path: Path


@dataclass(frozen=True)
class SubmodulePin:
    path: str
    url: str
    remote: str
    rev: str
    branch: str


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


def try_git_lines(path: Path, *args: str) -> list[str]:
    output = try_git(path, *args)
    return [line.strip() for line in output.splitlines() if line.strip()]


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


def submodule_entries() -> list[str]:
    if not gitmodules_file.exists():
        raise SystemExit(f"missing {gitmodules_file}")
    output = run_git(
        repo_root,
        "config",
        "-f",
        str(gitmodules_file),
        "--get-regexp",
        r"^submodule\..*\.path$",
    )
    entries: list[str] = []
    for line in output.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) == 2:
            entries.append(parts[1])
    return entries


def normalize_submodule_path(value: str) -> str:
    path = Path(value)
    if path.is_absolute():
        try:
            path = path.resolve().relative_to(repo_root)
        except ValueError as exc:
            raise SystemExit(f"{value} is outside {repo_root}") from exc
    return path.as_posix().rstrip("/")


def gitmodules_url(path_text: str) -> str:
    return try_git(repo_root, "config", "-f", str(gitmodules_file), "--get", f"submodule.{path_text}.url")


def remotes_containing_head(path: Path) -> dict[str, str]:
    remotes: dict[str, str] = {}
    for ref in try_git_lines(path, "branch", "-r", "--contains", "HEAD"):
        ref = ref.removeprefix("* ").strip()
        if " -> " in ref or "/" not in ref:
            continue
        remote = ref.split("/", 1)[0]
        if remote not in remotes:
            remotes[remote] = run_git(path, "remote", "get-url", remote)
    return remotes


def choose_submodule_remote(path: Path, path_text: str) -> str:
    remotes = remotes_containing_head(path)
    if not remotes:
        rev = run_git(path, "rev-parse", "--short", "HEAD")
        raise SystemExit(
            f"{path_text} HEAD {rev} is not contained in any fetched remote ref. "
            f"Push this commit, or fetch the remote that already has it, then rerun."
        )

    current_url = gitmodules_url(path_text)
    matching_current = [name for name, url in remotes.items() if url == current_url]
    if matching_current:
        return sorted(matching_current)[0]

    if len(remotes) == 1:
        return next(iter(remotes))

    candidates = ", ".join(f"{name}={url}" for name, url in sorted(remotes.items()))
    raise SystemExit(
        f"{path_text} HEAD is contained in multiple remotes, but none matches "
        f"{gitmodules_file}: {candidates}. Update .gitmodules or select a state "
        f"that identifies one remote."
    )


def submodule_pin_from_path(path_text: str) -> SubmodulePin:
    path = (repo_root / path_text).resolve()
    if not path.exists():
        raise SystemExit(f"missing submodule path {path_text}")

    status = run_git(path, "status", "--porcelain")
    if status and not allow_dirty:
        raise SystemExit(f"{path} has uncommitted changes; commit them first or use --allow-dirty")

    remote = choose_submodule_remote(path, path_text)
    url = run_git(path, "remote", "get-url", remote)
    rev = run_git(path, "rev-parse", "HEAD")
    branch = run_git(path, "branch", "--show-current") or "DETACHED"
    return SubmodulePin(path=path_text, url=url, remote=remote, rev=rev, branch=branch)


def update_gitmodules_lines(lines: list[str], pins: list[SubmodulePin]) -> list[str]:
    updated = lines.copy()
    for pin in pins:
        section = f'[submodule "{pin.path}"]'
        section_index = None
        for index, line in enumerate(updated):
            if line.strip() == section:
                section_index = index
                break
        if section_index is None:
            raise SystemExit(f"{gitmodules_file} does not contain {section}")

        next_section = len(updated)
        for index in range(section_index + 1, len(updated)):
            if re.match(r"\s*\[", updated[index]):
                next_section = index
                break

        url_index = None
        for index in range(section_index + 1, next_section):
            if re.match(r"\s*url\s*=", updated[index]):
                url_index = index
                break
        replacement = f"\turl = {pin.url}\n"
        if url_index is None:
            updated.insert(next_section, replacement)
        else:
            updated[url_index] = replacement
    return updated


def sync_local_submodule_config(pins: list[SubmodulePin]) -> None:
    for pin in pins:
        subprocess.run(
            ["git", "-C", str(repo_root), "submodule", "sync", "--", pin.path],
            check=True,
        )


if not gitmodules_only:
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
    elif dry_run:
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

if sync_gitmodules:
    entries = submodule_entries()
    selected = submodule_paths or entries
    selected = [normalize_submodule_path(path) for path in selected]
    unknown = [path for path in selected if path not in entries]
    if unknown:
        raise SystemExit(f"not listed in {gitmodules_file}: {', '.join(unknown)}")

    if not selected:
        print("No changed submodules found for .gitmodules update.")
    else:
        submodule_pins = [submodule_pin_from_path(path) for path in selected]
        original_gitmodules = gitmodules_file.read_text(encoding="utf-8").splitlines(keepends=True)
        updated_gitmodules = update_gitmodules_lines(original_gitmodules, submodule_pins)

        for pin in submodule_pins:
            print(f"{pin.path}: {pin.remote} -> {pin.url} @ {pin.rev} ({pin.branch})")

        if updated_gitmodules == original_gitmodules:
            print(f"{gitmodules_file} already up to date.")
        elif dry_run:
            print(f"\nDry run: {gitmodules_file} would change:\n")
            sys.stdout.writelines(
                difflib.unified_diff(
                    original_gitmodules,
                    updated_gitmodules,
                    fromfile=str(gitmodules_file),
                    tofile=str(gitmodules_file),
                )
            )
        else:
            gitmodules_file.write_text("".join(updated_gitmodules), encoding="utf-8")
            sync_local_submodule_config(submodule_pins)
            print(f"Updated {gitmodules_file}")
PY
