module "vault-base-setup" {
  source          = "github.com/stuttgart-things/vault-base-setup"
  vault_addr      = var.vault_addr
  skip_tls_verify = true
  kubeconfig_path = var.kubeconfig_path
  cluster_name    = var.cluster_name

  csi_enabled = false
  vso_enabled = false

  pki_enabled = false

  certmanager_vault_issuer_ca_bundle = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURVekNDQWp1Z0F3SUJBZ0lVSGpSc0dOTXJKbHdYVkNXbGJUV05hRW13RDdrd0RRWUpLb1pJaHZjTkFRRUwKQlFBd01URUxNQWtHQTFVRUJoTUNSRVV4RERBS0JnTlZCQW9UQTNOMllURVVNQklHQTFVRUF4TUxjM1JvYVc1bgpjeTVzWVdJd0hoY05Nall3TXpBME1UUTFPREkyV2hjTk16WXdNekF4TVRRMU9EVTFXakF4TVFzd0NRWURWUVFHCkV3SkVSVEVNTUFvR0ExVUVDaE1EYzNaaE1SUXdFZ1lEVlFRREV3dHpkR2hwYm1kekxteGhZakNDQVNJd0RRWUoKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBTDJJZHVZV1RKKytBZUN0Z0lhZkJ2VFo5VXlyelQwRgovWlBSQW0raERaODhJcmNQcUdWZ0FUdXVYbDdiVERwQVJqK3VwU2t4ek5EZENxbDAySmVteGxNWklMdGxRMEhZCjFwTGJETEEvLytZRXhPeGlra1VoTXBneUg2dmQyRHd4QXhVdFhyVG9GN216cWFlMDdoMjlCRzFZdFFNQldCOFoKZUJ6ZFJybXhiSUphblZLOHRGV211dmtUbThYT0NWVXJTbE5Ld2RCVzdZQnhJeGF3MVIxUUVTVFNWS2tacHY5MAplU080QjNQb0hEdlYrRnEzTUVBMlpJYVNqNjd6TTBPRGFmSVZ6RXVuRUhqRDByOUdKcndScUFsWk1BTllvbUVRCmNZU3FyYXdVeHErRnphTjM1MC92azJOM1JyZFBSM1RjZU5SdWJFY2lDcjYyTnlpRWgxSE82Uk1DQXdFQUFhTmoKTUdFd0RnWURWUjBQQVFIL0JBUURBZ0VHTUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3SFFZRFZSME9CQllFRkllNQo5cXZZSzByREpwMDhtQWFOZUtSNUN2b09NQjhHQTFVZEl3UVlNQmFBRkllNTlxdllLMHJESnAwOG1BYU5lS1I1CkN2b09NQTBHQ1NxR1NJYjNEUUVCQ3dVQUE0SUJBUUJobzBTRTM2WmxqQno4a1pSZGNHc2FacmdxSVR6WE5TbEQKZkRaMDNhM2lFWHhWNUE5bFZCQmFGcE9JTUZ4aFZVdzVOaHNISUZTSk93ZFBsZUdzVFBPbHRmTTI1OE5peTZ2RAo2ZnhvK2drVURCNUIyNjIydFF6Rmpod2U4TjdnYVkyWVZRSExMeUxBbFlKbW9XK2YzQ3plRzF6R0hKcnE0M1F4CmttcTkrZ1dpUU4yY3NOQ1VyZEdNY29INWN1K2h6NkRldk0xcjlxRDUzdVVrV2lBenVQZ2l4ZHhzQXBrNmxoMVkKTHdGclJ5RGIrQTF1VWhKMTkvZWQ4ajRmRmhEdVFTd3ZaOU9NVDZTQ0pqUFN4QVk3WWorbTM1MThodTlvdmhZdApGZTdlM3lPaUE0endzYy9vcm40VExUekR0QytYYnBmbU9LMTVlQk5xV2dreGJ6OGowYksyCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0=" # pragma: allowlist secret
  certmanager_vault_issuer_enabled    = true
  certmanager_vault_issuer_pki_role   = "sthings-lab"
  certmanager_vault_issuer_server     = var.vault_addr
  certmanager_vault_issuer_policy_name = "pki-issue"
}

variable "vault_addr" {
  type        = string
  description = "Vault server address"
  default     = "https://vault.infra.sthings.lab"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to kubeconfig"
  default     = "/home/sthings/.kube/platform.sthings.lab"
}

variable "cluster_name" {
  type        = string
  description = "Cluster name"
  default     = "platform-sthings"
}
