# Data collection configurations for OpenArm with dora-rs

This repository provides data collection configurations for [OpenArm](https://openarm.dev/) with [dora-rs](https://dora-rs.ai/).

## Configurations

[`dataflow/metadata.yaml`](dataflow/metadata.yaml) is metadata used by all configurations.

## Development

For the development scripts, dependency override logic, and release workflow,
see [`dev/README.md`](dev/README.md).

Quick start:

```bash
source scripts/setup-env.sh
```

For local editable core repositories:

```bash
cp dev/requirements-local/editable.example.txt dev/requirements-local/editable.txt
# add local editable package paths, then:
source scripts/setup-env.sh -e
```

### Real configuration

TODO

### Dummy configuration

[`dataflow/dataflow_dummy.yaml`](dataflow/dataflow_dummy.yaml) is a configuration that doesn't use real OpenArm. We can use this for testing a dataflow without real OpenArm.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

Copyright 2026 Enactic, Inc.

## Code of Conduct

All participation in the OpenArm project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).
