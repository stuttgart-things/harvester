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
  # MinIO on platform (artifacts-console): MINIO_IDENTITY_OPENID_* on the
  # server, claim `groups` -> MinIO policies of the same name, minio-admin and
  # minio-readonly (Crossplane Policy objects in
  # clusters/machinery-hv/xrs/platform-minio-oidc-policies.yaml). The console
  # calls back on /oauth_callback. Root user stays.
  minio = {
    url               = "https://artifacts-console.platform.sthings.lab"
    redirect_paths    = ["/oauth_callback"]
    post_logout_paths = ["/login"]
    roles = {
      "minio-admin"    = "MinIO admin"
      "minio-readonly" = "MinIO read-only"
    }
    users = {
      sthings  = ["minio-admin"]
      indy     = ["minio-admin"]
      tommy    = ["minio-admin"]
      mcfly    = ["minio-readonly"]
      mcclane  = ["minio-readonly"]
      fmcguire = ["minio-readonly"]
      rdevaney = ["minio-readonly"]
      someara  = ["minio-readonly"]
    }
  }
}
