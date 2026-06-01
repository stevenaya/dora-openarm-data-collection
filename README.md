# Data collection configurations for OpenArm with dora-rs

This repository provides data collection configurations for [OpenArm](https://openarm.dev/) with [dora-rs](https://dora-rs.ai/).

## Configurations

[`dataflow/metadata.yaml`](dataflow/metadata.yaml) is metadata used by all configurations.

## Development Environment

Create the Python environment from the parent repository:

```bash
source scripts/setup-env.sh
```

The default mode syncs the parent repository's normal project dependencies.
Those common packages live in `[project].dependencies`, so `uv run dora ...`
will also keep them in the environment during its own sync step.

To also use pinned core dependencies from the parent `pyproject.toml`:

```bash
source scripts/setup-env.sh --dev
```

To use local editable core dependencies, copy
[`dev/requirements-local/editable.example.txt`](dev/requirements-local/editable.example.txt)
to `dev/requirements-local/editable.txt`, edit the paths, then run:

```bash
source scripts/setup-env.sh -e
```

The dataflow `build` commands use [`scripts/install-node.sh`](scripts/install-node.sh).
If a package name is present in `DORA_PARENT_DEP_OVERRIDES`, the node installer
refreshes that package from the parent `core-pinned` group or
`dev/requirements-local/editable.txt`, then installs the node dependencies not owned
by the parent using that node's own metadata and `tool.uv.sources`. If the
environment variable is not set, nodes are installed normally with their full
dependency declarations.

After committing changes in local editable core repositories, update the parent
git pins from `dev/requirements-local/editable.txt`:

```bash
dev/sync-editable-pins.sh
```

Use `--dry-run` to preview the `pyproject.toml` changes.

### Real configuration

TODO

### Dummy configuration

[`dataflow/dataflow_dummy.yaml`](dataflow/dataflow_dummy.yaml) is a configuration that doesn't use real OpenArm. We can use this for testing a dataflow without real OpenArm.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

Copyright 2026 Enactic, Inc.

## Code of Conduct

All participation in the OpenArm project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).
