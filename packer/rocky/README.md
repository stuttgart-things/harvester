# Rocky Linux 9.7 Base Image (Packer + QEMU)

Builds a Rocky Linux 9.7 QEMU disk image with custom packages and users configured via cloud-init.

## Prerequisites

- [Packer](https://www.packer.io/) >= 1.7
- QEMU with KVM support
- `genisoimage` (for cloud-init ISO generation)
- OVMF firmware (`/usr/share/OVMF/OVMF_CODE_4M.fd`, `/usr/share/OVMF/OVMF_VARS_4M.fd`)
- `jq`, `yq`, `curl` (for Harvester upload)

## File Structure

```
.
├── spec.pkr.hcl              # QEMU source and build definition (incl. upload post-processor)
├── spec.cloud-init.pkr.hcl   # Cloud-init user-data/meta-data generation
├── variables.pkr.hcl         # Variable definitions and defaults
├── packages.yaml             # Packages to install in the image
├── users.yaml                # Users and SSH keys to provision
├── upload.sh                 # Harvester image upload script
├── vmi_template.yaml         # Harvester VirtualMachineImage CRD template
└── README.md
```

## Configuration

### packages.yaml

Define which packages to install:

```yaml
packages:
  - qemu-guest-agent
  - vim
  - curl
```

### users.yaml

Define users and their SSH public keys:

```yaml
users:
  - name: admin
    groups: wheel
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... admin@example.com
```

Each user entry supports:

| Field                  | Default                       | Description                  |
|------------------------|-------------------------------|------------------------------|
| `name`                 | (required)                    | Username                     |
| `groups`               | `wheel`                       | Comma-separated group list   |
| `shell`                | `/bin/bash`                   | Login shell                  |
| `sudo`                 | `ALL=(ALL) NOPASSWD:ALL`      | Sudoers rule                 |
| `ssh_authorized_keys`  | (required)                    | List of public SSH keys      |

## Usage

### Initialize plugins

```bash
packer init .
```

### Build the image

```bash
packer build .
```

The output image (`rocky-9-base-amd64.img`) will be placed in the `output/` directory. The Harvester upload is skipped by default.

### Build and upload to Harvester

```bash
packer build \
  -var 'upload_to_harvester=true' \
  -var 'harvester_vip=10.31.101.8' \
  -var 'harvester_password=yourpassword' .
```

### Override variables

```bash
# Custom image name
packer build -var 'image_name=rocky-9-custom' .

# Custom YAML files
packer build -var 'users_file=prod-users.yaml' -var 'packages_file=prod-packages.yaml' .
```

### All variables

| Variable              | Default                                  | Description                          |
|-----------------------|------------------------------------------|--------------------------------------|
| `rocky_url`           | Rocky 9 GenericCloud image URL           | Source cloud image                   |
| `rocky_checksum`      | SHA256 checksum                          | Checksum for source image            |
| `image_name`          | `rocky-9-base`                           | Output image name prefix             |
| `namespace`           | `default`                                | Namespace designation                |
| `output_location`     | `output/`                                | Directory for build output           |
| `packages_file`       | `packages.yaml`                          | Path to packages YAML                |
| `users_file`          | `users.yaml`                             | Path to users YAML                   |
| `upload_to_harvester` | `false`                                  | Set to `true` to upload to Harvester |
| `harvester_vip`       | (empty)                                  | Harvester VIP address                |
| `harvester_password`  | (empty, sensitive)                       | Harvester admin password             |

## GitHub Actions

The build can be triggered via the `Packer Build` workflow:

```
Actions → Packer Build → Run workflow
```

Inputs:
- **packer_dir**: Directory containing the Packer config (default: `harvester/packer/rocky`)
- **template**: Packer template target (default: `.`)
- **var_file**: Optional `.pkrvars.hcl` file for overrides
- **log_level**: Packer log verbosity (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`)

## Backstage Integration

To manage users and packages from Backstage:

1. Backstage updates `users.yaml` and/or `packages.yaml` in the repository
2. Backstage triggers the `Packer Build` GitHub Actions workflow
3. Packer reads the YAML files at build time and generates the cloud-init configuration
