# OIDC clients next to the portal (apps.tf, harvester#574). Role keys carry the
# app name: the flat `groups` claim (groups-claim.tf) holds the roles of all
# projects, and each app matches only its own. Users must be in
# users.auto.tfvars. Every app keeps its local admin.
apps = {
  # ArgoCD on platform: oidc.config in argocd-cm, argocd-admin => role:admin,
  # argocd-readonly => role:readonly (policy.csv). Local `admin` stays.
  argocd = {
    url               = "https://argocd.platform.sthings.lab"
    redirect_paths    = ["/auth/callback"]
    post_logout_paths = ["/"]
    roles = {
      "argocd-admin"    = "ArgoCD admin"
      "argocd-readonly" = "ArgoCD read-only"
    }
    # As in the portal: portal-admin => argocd-admin, portal-user => read-only.
    users = {
      sthings  = ["argocd-admin"]
      indy     = ["argocd-admin"]
      tommy    = ["argocd-admin"]
      mcfly    = ["argocd-readonly"]
      mcclane  = ["argocd-readonly"]
      fmcguire = ["argocd-readonly"]
      rdevaney = ["argocd-readonly"]
      someara  = ["argocd-readonly"]
    }
  }
}
