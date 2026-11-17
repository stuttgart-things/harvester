# OIDC clients next to the portal (harvester-extras.tf, harvester#574). Role keys carry the
# app name; each app reads only its own project's roles (ZITADEL role map,
# #719). Argo CD: the shared root's argocd project (#677). Users must be in
# users.auto.tfvars. Every app keeps its local admin.
apps = {
  # MinIO on platform (artifacts-console): TWO clients, one per MinIO policy
  # (harvester#719). MinIO cannot read ZITADEL's role map (a claim must be a
  # string or a list), so each client is a MinIO OpenID config with a fixed
  # ROLE_POLICY, and ZITADEL's role check decides who may use which: `minio`
  # (button "ZITADEL (admin)") -> policy minio-admin, `minio-readonly`
  # (button "ZITADEL (read-only)") -> policy minio-readonly. Policies:
  # clusters/machinery-hv/xrs/platform-minio-oidc-policies.yaml. The console
  # calls back on /oauth_callback for both. Root user stays.
  minio = {
    url               = "https://artifacts-console.platform.sthings.lab"
    redirect_paths    = ["/oauth_callback"]
    post_logout_paths = ["/login"]
    roles = {
      "minio-admin" = "MinIO admin"
    }
    users = {
      sthings = ["minio-admin"]
      indy    = ["minio-admin"]
      tommy   = ["minio-admin"]
    }
  }
  minio-readonly = {
    url               = "https://artifacts-console.platform.sthings.lab"
    redirect_paths    = ["/oauth_callback"]
    post_logout_paths = ["/login"]
    roles = {
      "minio-readonly" = "MinIO read-only"
    }
    users = {
      mcfly    = ["minio-readonly"]
      mcclane  = ["minio-readonly"]
      fmcguire = ["minio-readonly"]
      rdevaney = ["minio-readonly"]
      someara  = ["minio-readonly"]
    }
  }
  # Grafana on platform (kube-prometheus-stack): auth.generic_oauth in
  # grafana.ini (../infra.yaml), role_attribute_path on the groups claim:
  # grafana-admin => Admin, grafana-readonly => Viewer, nothing else gets in
  # (role_attribute_strict). Callback /login/generic_oauth. Local admin stays.
  grafana = {
    url               = "https://grafana.platform.sthings.lab"
    redirect_paths    = ["/login/generic_oauth"]
    post_logout_paths = ["/login"]
    roles = {
      "grafana-admin"    = "Grafana admin"
      "grafana-readonly" = "Grafana viewer"
    }
    users = {
      sthings  = ["grafana-admin"]
      indy     = ["grafana-admin"]
      tommy    = ["grafana-admin"]
      mcfly    = ["grafana-readonly"]
      mcclane  = ["grafana-readonly"]
      fmcguire = ["grafana-readonly"]
      rdevaney = ["grafana-readonly"]
      someara  = ["grafana-readonly"]
    }
  }
}
