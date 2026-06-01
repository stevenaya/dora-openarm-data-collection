# Development Workflow

## Quick Flow

1. Create the base environment.

```bash
source scripts/setup-env.sh
```

2. For local core-package development, add editable local repositories to
   `dev/requirements-local/editable.txt`.

Each node may declare its own core-library sources in its `pyproject.toml`.
Editable paths in this file let the parent environment override those sources
during Dora builds.

```bash
cp dev/requirements-local/editable.example.txt dev/requirements-local/editable.txt
# edit paths, for example:
# -e /home/li/Documents/gits/openarm_driver
# -e /home/li/Documents/gits/openarm_v20_mujoco/v2
```

```bash
source scripts/setup-env.sh -e
```

This makes Dora builds use your local core repositories instead of the node's
default Git sources.

3. If you need to modify a node submodule itself, fork it first and work on a
   dedicated branch.

4. After development, commit and push all changed core repositories or node
   submodules.

```bash
git -C /path/to/core-repo commit -am "..."
git -C /path/to/core-repo push
```

5. Sync the parent repository to the pushed commits so others can reproduce the
   same test environment.

```bash
dev/sync-editable-pins.sh --sync-gitmodules
```

This updates `pyproject.toml`, `.gitmodules` when needed, and `uv.lock`.

6. Push the parent repository changes.

7. To reproduce another team member's parent-repo state, run:

```bash
source scripts/setup-env.sh --dev
```

This installs the pinned core-library Git commits and node submodule versions
recorded by that parent repository.

8. For PRs, upstream changes from the inside out:

   - First open PRs for the core algorithm repositories.
   - After they land, switch your local core repositories to the public branches.
   - Update each node's source pins from your fork to the public repository.
   - Open PRs for the changed node submodules.
   - After node PRs land, switch the parent repo's submodule pins back to the
     public node branches and run:

```bash
dev/sync-editable-pins.sh --sync-gitmodules
```

Finally, open the parent repository PR.


## Environment Modes

```bash
source scripts/setup-env.sh
```

Installs common dependencies from parent `[project].dependencies`.

```bash
source scripts/setup-env.sh --dev
```

Also installs the parent `core-pinned` dependency group to override node
dependencies.

```bash
source scripts/setup-env.sh -e
```

Installs local editable packages from `dev/requirements-local/editable.txt` to
override node dependencies.

This file is ignored by Git; commit only `editable.example.txt`.

## Build Behavior

Dataflow `build` commands call:

```yaml
build: ./scripts/install-node.sh nodes/dora-openarm
```

`scripts/install-node.sh` reads `.venv/.dora_env`, written by
`scripts/setup-env.sh`.

- No parent overrides: install the node normally from its own `pyproject.toml`.
- With parent overrides: install parent-owned deps first, then skip those deps
  when installing the node.

This lets local editable core packages override a node's default Git sources.

## Freeze Commands

Preview pin changes:

```bash
dev/sync-editable-pins.sh --dry-run
```

Update parent pins and `uv.lock`:

```bash
dev/sync-editable-pins.sh
```

Also sync `.gitmodules` for submodules currently pointing at fork commits:

```bash
dev/sync-editable-pins.sh --sync-gitmodules
```

Only sync `.gitmodules`:

```bash
dev/sync-editable-pins.sh --gitmodules-only
```

The `.gitmodules` sync refuses local-only submodule commits. Push or fetch the
remote first, then rerun.
