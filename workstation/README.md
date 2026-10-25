# workstation

Ansible inputs for the machine you work from: Docker, the Dagger CLI and the
cluster CLIs. How to run them: [docs/workstation.md](../docs/workstation.md).

| File | |
|---|---|
| `inventory.ini` | `localhost`, local connection |
| `requirements.yaml` | `sthings.container` + the community collections it uses |
| `tools.yaml` | versions + the `bin` selection for `sthings.container.tools` |
