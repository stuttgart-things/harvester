// ---- shared entries (`_<name>`) ---------------------------------------------
//
// The `_` entries every built cluster reads through a `shared:` reference in
// an AppSecretProfile (clusters/machinery-hv/fleet-state/appsecretprofiles.yaml)
// and the cluster-vault-sthings-lab mapping. Until now they were seeded by
// hand; this puts the ones that are plain configuration -- not a person's
// credential -- into git, encrypted:
//
//   homerun2/_teams-webhook   teamsWebhookUrl   Teams channel `harvester-apps`
//                                               (harvester#523)
//
// `homerun2/_git-pat` stays hand-seeded (README, "Not here"): whose token that
// is, is a decision for a person.
//
// VALUES COME ONLY FROM shared.tfvars.sops.json, decrypted on the fly:
//
//   sops exec-file --filename shared.tfvars.json shared.tfvars.sops.json 'terraform apply -var-file={}'
//
// `shared_entries` has NO default on purpose. With `default = {}` a plain
// `terraform apply` -- e.g. to rotate an AppRole secret_id -- would plan to
// DELETE every shared entry. Without a default it stops and asks instead.
// Every run of this root therefore goes through `sops exec-file`.
//
// The values end up in this root's state (backend.tf: a Secret on platform,
// next to the AppRole secret_ids that already are), never in a plan output:
// the provider marks data_json sensitive.

variable "shared_entries" {
  description = "Shared `_` KV entries on the fleet mounts, keyed by <mount>/<entry>. From shared.tfvars.sops.json only."
  type = map(object({
    data = map(string)
  }))

  validation {
    condition = alltrue([
      for k in keys(var.shared_entries) :
      can(regex("^(homerun2|schmetterpause|observability)/_[a-z0-9-]+$", k))
    ])
    error_message = "Keys are <mount>/_<entry>: mount one of homerun2, schmetterpause, observability (main.tf local.app_mounts); entry starts with `_` and is one path segment."
  }
}

resource "vault_kv_secret_v2" "shared" {
  for_each = var.shared_entries

  mount     = vault_mount.app[split("/", each.key)[0]].path
  name      = split("/", each.key)[1]
  data_json = jsonencode(each.value.data)

  // A value a person changes in the OpenBao UI is drift, and the next apply
  // puts git's value back. That is the point: git is the source.
}

output "shared_entries" {
  description = "Paths of the shared entries this root manages (no values)."
  value       = sort(keys(var.shared_entries))
}
