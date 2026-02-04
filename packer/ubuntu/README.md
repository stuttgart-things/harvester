# Ubuntu Jammy Base Image (Packer + QEMU)

Builds a Ubuntu 22.04 (Jammy) QEMU disk image with custom packages and users configured via cloud-init.

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
    groups: sudo
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... admin@example.com
  - name: developer
    groups: sudo
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... developer@example.com
```

Each user entry supports:

| Field                  | Default                       | Description                  |
|------------------------|-------------------------------|------------------------------|
| `name`                 | (required)                    | Username                     |
| `groups`               | `sudo`                        | Comma-separated group list   |
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

The output image (`ubuntu-jammy-base-amd64.img`) will be placed in the `output/` directory. The Harvester upload is skipped by default.

### Build and upload to Harvester

```bash
packer build \
  -var 'upload_to_harvester=true' \
  -var 'harvester_vip=10.31.101.8' \
  -var 'harvester_password=yourpassword' .
```

The post-processor authenticates against the Harvester API, creates a `VirtualMachineImage` resource, and uploads the built image.

### Override variables

Variables can be overridden at build time:

```bash
# Custom image name
packer build -var 'image_name=ubuntu-jammy-custom' .

# Custom YAML files
packer build -var 'users_file=prod-users.yaml' -var 'packages_file=prod-packages.yaml' .

# Custom output location
packer build -var 'output_location=build/' .

# Use a different Ubuntu source image
packer build -var 'ubuntu_url=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img' \
             -var 'ubuntu_checksum=file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS' \
             -var 'image_name=ubuntu-noble-base' .
```

### All variables

| Variable          | Default                                  | Description                          |
|-------------------|------------------------------------------|--------------------------------------|
| `ubuntu_url`      | Ubuntu Jammy cloud image URL             | Source cloud image                   |
| `ubuntu_checksum` | Jammy SHA256SUMS URL                     | Checksum for source image            |
| `image_name`      | `ubuntu-jammy-base`                      | Output image name prefix             |
| `namespace`       | `default`                                | Namespace designation                |
| `output_location` | `output/`                                | Directory for build output           |
| `packages_file`   | `packages.yaml`                          | Path to packages YAML                |
| `users_file`      | `users.yaml`                             | Path to users YAML                   |
| `upload_to_harvester` | `false`                              | Set to `true` to upload to Harvester |
| `harvester_vip`   | (empty)                                  | Harvester VIP address                |
| `harvester_password` | (empty, sensitive)                    | Harvester admin password             |

## GitHub Actions

The build can be triggered via the `Packer Build` workflow:

```
Actions → Packer Build → Run workflow
```

Inputs:
- **packer_dir**: Directory containing the Packer config (default: `harvester/packer/ubuntu25`)
- **template**: Packer template target (default: `.`)
- **var_file**: Optional `.pkrvars.hcl` file for overrides
- **log_level**: Packer log verbosity (`TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`)

To enable the Harvester upload from the workflow, pass `harvester_vip` and `harvester_password` as variables (e.g. from repository secrets) and set `upload_to_harvester=true`:

```bash
packer build \
  -var 'upload_to_harvester=true' \
  -var "harvester_vip=${{ secrets.HARVESTER_VIP }}" \
  -var "harvester_password=${{ secrets.HARVESTER_PASSWORD }}" .
```

## Backstage Integration

To manage users and packages from Backstage:

1. Backstage updates `users.yaml` and/or `packages.yaml` in the repository
2. Backstage triggers the `Packer Build` GitHub Actions workflow
3. Packer reads the YAML files at build time and generates the cloud-init configuration
