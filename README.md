# Data collection configurations for OpenArm with dora-rs

This repository provides data collection configurations for [OpenArm](https://openarm.dev/) with [dora-rs](https://dora-rs.ai/).

## Setup

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) and Git,
then run the following from the repository root after cloning:

```bash
git submodule update --init --recursive
uv sync
source .venv/bin/activate
```

[`pyproject.toml`](pyproject.toml) selects Python 3.12 and Dora CLI 1.0.1.
uv creates `.venv` in this repository and downloads a compatible Python if needed;
no `.python-version` file is required. The parent project only manages the build
tool environment and is not installed as a Python package.

Build and run the desired dataflow from the same activated shell. For example,
to use WebXR with MuJoCo (no real arms required):

```bash
dora build dataflow-webxr-mujoco.yaml --uv
./nodes/dora-openarm-webxr/example/prepare_tls.sh "$(hostname).local"
dora run dataflow-webxr-mujoco.yaml --uv
```

See the WebXR section below for browser URLs and TLS details. Other dataflows
use the same `dora build <dataflow>.yaml --uv` and
`dora run <dataflow>.yaml --uv` commands, with their own hardware prerequisites.

The current dataflows install node packages into the shared root `.venv` via
their `build` commands. `uv.lock` locks the parent tool dependencies, not the
node dependencies installed by Dora. In each new terminal, run
`source .venv/bin/activate` before invoking `dora` so that it uses this project's
CLI rather than another program with the same name.

After building nodes, use `uv sync --inexact` instead of plain `uv sync` when
updating the tool environment. Plain `uv sync` removes packages not declared
by the parent project; if that happens, run the dataflow build again.
See [uv's synchronization rules](https://docs.astral.sh/uv/concepts/projects/sync/).

## Configurations

[`metadata.yaml`](metadata.yaml) is metadata used by configurations with real cameras. [`metadata_mujoco.yaml`](metadata_mujoco.yaml) is metadata used by configurations that render cameras with MuJoCo.

### KER configuration

[`dataflow-ker.yaml`](dataflow-ker.yaml) is a configuration for leader-follower teleoperation with real OpenArm units and cameras. A [KER](https://github.com/enactic/dora-openarm-ker) leader arm controls the follower arms while wrist, head and ceiling cameras are recorded.

### VR configuration

[`dataflow-vr.yaml`](dataflow-vr.yaml) is a configuration for VR teleoperation with real OpenArm units and cameras. VR controller poses are received over UDP by [dora-openarm-vr](https://github.com/enactic/dora-openarm-vr), converted to joint positions by inverse kinematics ([dora-openarm-kinematics](https://github.com/enactic/dora-openarm-kinematics)) and sent to the follower arms.

[`dataflow-vr-mujoco.yaml`](dataflow-vr-mujoco.yaml) is the same VR teleoperation but with a MuJoCo simulation ([dora-openarm-mujoco](https://github.com/enactic/dora-openarm-mujoco)) instead of real OpenArm units and cameras. We can use this for testing VR teleoperation and data collection without real hardware.

### WebXR configuration

[`dataflow-webxr-mujoco.yaml`](dataflow-webxr-mujoco.yaml) is a configuration for WebXR teleoperation with a MuJoCo simulation. [dora-openarm-webxr](https://github.com/enactic/dora-openarm-webxr) starts a Web server and the Web browser on a VR device such as Meta Quest 3 or PICO 4 connects to it to stream controller poses. No native VR application is needed.

WebXR requires HTTPS, so a TLS certificate is needed. A self-signed certificate is enough; see the [dora-openarm-webxr setup instructions](https://github.com/enactic/dora-openarm-webxr#setup) for how to generate one. Then run:

```bash
dora build dataflow-webxr-mujoco.yaml --uv
./nodes/dora-openarm-webxr/example/prepare_tls.sh $(hostname).local
dora run dataflow-webxr-mujoco.yaml --uv
```

Open http://localhost:8000/ on the local machine for the data collection UI, and open `https://${YOUR_HOST_NAME}:8443/` in the Web browser on your VR device (where `${HOSTNAME}` matches the value passed to `prepare_tls.sh`) to start teleoperation.

### Dummy configuration

[`dataflow_dummy.yaml`](dataflow_dummy.yaml) is a configuration that doesn't use real OpenArm. We can use this for testing a dataflow without real OpenArm.

## Debugging OpenArm libraries

The OpenArm-specific dependency repositories are checked out under [`lib/`](lib/README.md).
Initialize them with `git submodule update --init --recursive`.

Relevant nodes in the dataflows include a commented `build` alternative that
installs their underlying libraries with `-e`. To debug changes in `lib/`,
comment out that node's normal `build` line and uncomment the `lib/` alternative.
Keep only one active `build` entry per node. For example:

```yaml
    # build: pip install -e nodes/dora-openarm-kinematics
    build: pip install -e lib/openarm_mujoco -e lib/openarm_control -e nodes/dora-openarm-kinematics
```

Run `dora build <dataflow>.yaml --uv` again from the repository root, then restart
the dataflow. The alternative includes the node and its OpenArm dependency chain
in the same installation command. CAN bindings use `lib/openarm_can/python`;
changes to their C++ code require rebuilding.

Commenting the alternative out again does not uninstall an existing editable
library. Recreate the environment or explicitly reinstall released packages
when switching back to package-index dependencies.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

Copyright 2026 Enactic, Inc.

## Code of Conduct

All participation in the OpenArm project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md).
