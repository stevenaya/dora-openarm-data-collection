# OpenArm Libraries

These submodules contain the OpenArm-specific libraries used by `nodes/`.
They are pinned to the official release tags listed below for local development.
General dependencies such as NumPy, PyArrow, and the MuJoCo engine remain
managed by the Python package manager.

| Repository | Release tag | Python package directory | Used by |
|---|---|---|---|
| [openarm_driver](openarm_driver) | `0.5.0` | `lib/openarm_driver` | `dora-openarm` |
| [openarm_can](openarm_can) | `1.4.0` | `lib/openarm_can/python` | `openarm_driver`, `openarm_ker`, `dora-openarm-cell-lifter` |
| [openarm_ker](openarm_ker) | `0.3.0` | `lib/openarm_ker` | `dora-openarm-ker` |
| [openarm_control](openarm_control) | `0.4.0` | `lib/openarm_control` | `dora-openarm-kinematics` |
| [openarm_mujoco](openarm_mujoco) | `2.3.0` | `lib/openarm_mujoco` | `openarm_control`, `dora-openarm-mujoco` |

Node dependencies use version ranges, so future package-index resolutions may
select newer releases, while an existing environment may retain an already
installed compatible version. Refresh these submodule pins when updating the
dependency baseline; the pins do not constrain ordinary package-index installs.

Initialize the source checkouts from the repository root:

```bash
git submodule update --init --recursive
```

Adding these submodules does not automatically change the existing dataflow
build commands to use local library sources. To debug a library through a
dataflow, comment out the relevant node's normal `build` line and uncomment its
`lib/` alternative, then rebuild and restart the dataflow. See the parent
[README](../README.md#debugging-openarm-libraries) for details.

Alternatively, install all library checkouts explicitly from the repository root:

```bash
uv pip install --python .venv/bin/python \
  -e lib/openarm_can/python \
  -e lib/openarm_driver \
  -e lib/openarm_ker \
  -e lib/openarm_mujoco \
  -e lib/openarm_control
```
