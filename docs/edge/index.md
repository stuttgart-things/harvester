# Edge cluster

A single-node **k3s** cluster for the edge: a LattePanda Mu (Intel N100, 8 GB,
64 GB eMMC) behind a GL.iNet GL-SFT1200 router, which runs only occasionally
and has to manage with **only that one node** -- no central OpenBao/ESO, NFS,
lab DNS, S3 or Rancher. It runs the table-tennis stack (zaehlwerk,
schmetterpause, homerun2 with LED matrix and light), MinIO for the backups and
OpenBao as the devices' PKI. Built and tested on lab VMs first
(harvester#364). Published at
[stuttgart-things.github.io/harvester/docs/edge](https://stuttgart-things.github.io/harvester/docs/edge/)
and in Backstage TechDocs.

| Doc | |
|---|---|
| [Architecture](./architecture.md) | the box, the router, k3s and Cilium, the services, the two name worlds (edge CA / OpenBao vs. Hetzner DNS / Let's Encrypt), the edge CA, what runs and what does not, DNS commands |
| [Step by step](./step-by-step.md) | a new cluster in phases -- secrets, node, cluster files, Flux files (ClusterApps + render **or** by hand), bootstrap, OpenBao/MinIO -- each with one commit and a check; CLI and Dagger side by side |
| [Runbook](./runbook.md) (all in one) | who creates which file in a cluster folder; *Recreate from scratch* in ten steps (with the commands); moving to the hardware |
| [k3s + Cilium](./k3s.md) | runbook step 3 in full: the three files (`cat <<EOF`), what the role sets up, Ansible CLI and Dagger runs, verify, idempotency |
| [From scratch](./from-scratch.md) | every file you write by hand, as `cat <<'EOF'` blocks -- the persistent secrets (with value generators, sops CLI or Dagger), a new cluster folder, and the Flux files without the generator (2B) |
| [Lab testing](./lab-testing.md) | the device path with the ESP mock, mock vs. real boards, watching the apps |
| [Notes](./notes.md) | lessons (the layers, the CNPG backup), first rollout, footprint |

## Clusters

| Folder | Node | Lab | |
|---|---|---|---|
| [`clusters/edge`](https://github.com/stuttgart-things/harvester/blob/main/clusters/edge/README.md) | `edge-tt-test1`, `10.100.136.89` | LabDA (vSphere) | the first lab cluster, reference |
| `clusters/edge-test2` | `edge-tt-test2`, `10.31.102.144` | labul (Proxmox) | the rebuild test: built from scratch with these docs |
| (box) | LattePanda Mu | edge LAN `192.168.8.0/24` | next |

All edge clusters share the persistent secrets in `secrets/edge/` (same root
CA, same OpenBao seal key, same app values) and get their content from one
OCI artifact, `oci://ghcr.io/stuttgart-things/flux/repo`.
