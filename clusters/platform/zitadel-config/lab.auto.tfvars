# Harvester values of the shared ZITADEL root (stuttgart-things#4612,
# harvester#680). main.tf / variables.tf / outputs.tf are LabUL's and LabDA's
# (module sources pinned to a commit); the lab differences live here, in
# users.auto.tfvars and backend.tf -- plus the Harvester-only
# harvester-extras.tf / apps.auto.tfvars (README).

zitadel_domain = "zitadel.platform.sthings.lab"

# sthings-portal project: one client per portal.
portals = {
  # sthings-portal on homerun2-dev (#560) -- the client from before #680,
  # kept by moved.tf (same client ID and secret).
  "homerun2-dev" = "https://portal.homerun2-dev.sthings.lab"
  # #681: the machinery-portal on platform (/clusterbook, /orders), as LabUL's
  # "machinery-portal" on infra-sthings. Not deployed yet; host assumed.
  "machinery-portal" = "https://machinery-portal.platform.sthings.lab"
}

# sthings-portal project: clients that are not portals.
oidc_apps = {}

# sthings-backstage project (#675): Backstage on platform.
backstages = {
  "backstage" = "https://backstage.platform.sthings.lab"
}

claim_machinery_machine_users = {
  # machinery-order-service on platform (#681, stuttgart-things#4297):
  # renders Orders through claim-machinery-api with its own token (client
  # credentials) in the name of the Order's requestedBy, so it needs the
  # admin role (AUTH_ADMIN_ROLES) for identity: owner templates -- as on
  # LabUL/LabDA.
  "machinery-order-service" = {
    description = "machinery-order-service (Order CRs -> render through claim-machinery-api -> git PR)"
    roles       = ["backstage-platform"]
  }
}

claim_machinery_portals = {
  # #681: the machinery-portal on machinery-hv in front of claim-machinery-api
  # (/machinery, /claims), a client of sthings-backstage as on LabDA. Not
  # deployed yet; host assumed.
  "machinery-portal-machinery-hv" = "https://machinery-portal.machinery-hv.sthings.lab"
}

# vault project (#719 step 1): OpenBao on platform. The OpenBao side (OIDC
# auth method, roles admin/reader) is ../openbao/oidc.tf.
vaults = {
  "openbao-platform" = "https://openbao.platform.sthings.lab"
}

# argocd project (#677): Argo CD on platform. The key is the client name;
# `argocd` keeps the client of the former harvester-extras.tf app (moved.tf),
# so its client ID/secret in apps/argocd-oidc-zitadel.enc.yaml stay valid.
# RBAC on the claim argocd_roles (action argocdRoles, main.tf) in
# ../apps/argocd-platform.yaml.
argocds = {
  "argocd" = "https://argocd.platform.sthings.lab"
}
