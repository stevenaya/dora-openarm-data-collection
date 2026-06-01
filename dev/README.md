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
default Git sources. Editable mode does not sync, initialize, or update
submodules; it leaves the working tree as-is.

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
dev/sync-editable-pins.sh --sync-submodules
```

This updates `pyproject.toml`, `dev/submodule-overrides.txt` when needed, and
`uv.lock`. `.gitmodules` stays pointed at the public submodule repositories.

6. Push the parent repository changes.

7. To reproduce another team member's parent-repo state, run:

```bash
source scripts/setup-env.sh --dev
```

This installs pinned core-library Git commits and any remote node overrides
recorded by that parent repository.

8. For PRs, upstream changes from the inside out:

   - First open PRs for the core algorithm repositories.
   - After they land, switch your local core repositories to the public branches.
   - Update each node's source pins from your fork to the public repository.
   - Open PRs for the changed node submodules.
   - After node PRs land, switch the parent repo's submodule pins back to the
     public node branches and run:

```bash
dev/sync-editable-pins.sh --sync-submodules
```

Finally, open the parent repository PR.


## Environment Modes

```bash
source scripts/setup-env.sh
```

Installs common dependencies from parent `[project].dependencies`.
It also syncs submodule URLs from `.gitmodules` and checks out all clean
submodules to the commits recorded by the parent repository.

```bash
source scripts/setup-env.sh --dev
```

Also installs the parent `core-pinned` dependency group to override node
dependencies, development tools such as Ruff, and remote node overrides from
`dev/submodule-overrides.txt`.
During submodule checkout it skips the paths listed in
`dev/submodule-overrides.txt`, because those commits may only exist in forks and
are installed later by `scripts/install-node.sh`.

```bash
source scripts/setup-env.sh -e
```

Installs local editable packages from `dev/requirements-local/editable.txt` to
override node dependencies, plus development tools such as Ruff.
It skips all submodule URL sync and checkout/update work.

This file is ignored by Git; commit only `editable.example.txt`.

## Submodule Pins

`.gitmodules` should stay pointed at the public submodule repositories. The
parent repository still records exact submodule commits through normal gitlink
entries.

Fork-only node commits are recorded separately in
`dev/submodule-overrides.txt`:

```text
path url rev
```

`source scripts/setup-env.sh --dev` exports this file as
`DORA_NODE_OVERRIDE_FILE`. During Dora builds, `scripts/install-node.sh` installs
listed nodes from `git+url@rev` instead of from the local submodule checkout.

`source scripts/setup-env.sh -e` ignores this file for node installation and
does not touch submodule checkouts.

## Build Behavior

Dataflow `build` commands call:

```yaml
build: ./scripts/install-node.sh dora-openarm
```

`scripts/install-node.sh` reads `.venv/.dora_env`, written by
`scripts/setup-env.sh`.

- No parent overrides: install the node normally from its own `pyproject.toml`.
- With parent overrides: install parent-owned deps first, then skip those deps
  when installing the node.
- With `DORA_NODE_OVERRIDE_FILE` from `source scripts/setup-env.sh --dev`, install
  listed nodes from the pinned remote Git URL instead of the local submodule.
- With `source scripts/setup-env.sh -e`, `DORA_NODE_OVERRIDE_FILE` is empty and
  node builds install from the local `nodes/` checkout.

This lets one dataflow build command work for local editable development and
fork-pinned reproduction.

## Freeze Commands

Preview pin changes:

```bash
dev/sync-editable-pins.sh --dry-run
```

Update parent pins and `uv.lock`:

```bash
dev/sync-editable-pins.sh
```

Also sync remote node overrides for submodules currently pointing at fork
commits:

```bash
dev/sync-editable-pins.sh --sync-submodules
```

Only sync remote node overrides:

```bash
dev/sync-editable-pins.sh --submodules-only
```

The submodule override sync refuses local-only submodule commits. Push or fetch
the remote first, then rerun. The old `--sync-gitmodules` and
`--gitmodules-only` names are kept as aliases, but they update
`dev/submodule-overrides.txt` rather than `.gitmodules`.
