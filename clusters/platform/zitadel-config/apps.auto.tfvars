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
  # Harbor on platform (goharbor chart, ../apps/goharbor.yaml, harvester#693):
  # auth_mode oidc_auth via ../harbor-config. Harbor finds admins only in a
  # FLAT groups claim, ZITADEL sends a role map, so no oidc_admin_group: the
  # role check decides who gets in, harbor-admin users are made sysadmin once
  # after their first login (../harbor-config/README.md). Callback
  # /c/oidc/callback. Local admin stays.
  harbor = {
    url            = "https://harbor.platform.sthings.lab"
    redirect_paths = ["/c/oidc/callback"]
    roles = {
      "harbor-admin" = "Harbor admin"
      "harbor-user"  = "Harbor user"
    }
    users = {
      sthings  = ["harbor-admin"]
      indy     = ["harbor-admin"]
      tommy    = ["harbor-admin"]
      mcfly    = ["harbor-user"]
      mcclane  = ["harbor-user"]
      fmcguire = ["harbor-user"]
      rdevaney = ["harbor-user"]
      someara  = ["harbor-user"]
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
  # Grafana on machinery-hv (harvester#753): its own client -- a client has
  # one base URL. Same role keys as `grafana` (keys are per project), so the
  # grafana.ini there is the same as platform's
  # (../../machinery-hv/kube-prometheus-stack.yaml). Local admin stays.
  grafana-machinery-hv = {
    url               = "https://grafana.machinery-hv.sthings.lab"
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
  # Grafana on the Argo clusters app-dev-hv and crossplane-mgmt (harvester#753):
  # the argocd catalog's kube-prometheus-stack with grafana.oidc, id/secret
  # through ESO from OpenBao (crossplane-mgmt: app-secrets entry
  # crossplane-mgmt/observability; app-dev-hv: machinery-fleet shared entry
  # observability/_grafana-oidc-app-dev-hv). Same role keys as `grafana`.
  grafana-app-dev-hv = {
    url               = "https://grafana.app-dev-hv.sthings.lab"
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
  grafana-crossplane-mgmt = {
    url               = "https://grafana.crossplane-mgmt.sthings.lab"
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
  # Grafana on homerun2-dev (Flux, like machinery-hv): SOPS Secret
  # ../../homerun2-dev/grafana-oidc-zitadel.enc.yaml. Same role keys as `grafana`.
  grafana-homerun2-dev = {
    url               = "https://grafana.homerun2-dev.sthings.lab"
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
  # Flux web UI (flux-operator, serverOnly) on machinery-hv (harvester#719):
  # one client per cluster (one base URL). flux-web maps the role keys of the
  # role map to Kubernetes groups `zitadel:<key>` by CEL and impersonates them;
  # ../../machinery-hv/flux-web-rbac.yaml binds flux-admin => flux-web-admin
  # (actions), flux-readonly => flux-web-readonly (read, no Secrets). Id and
  # secret: SOPS Secret ../../machinery-hv/flux-web-oidc-zitadel.enc.yaml.
  # Callback /oauth2/callback. No local login in flux-web: fallback is the
  # admin kubeconfig + flux CLI (#574).
  flux-web-machinery-hv = {
    url            = "https://flux.machinery-hv.sthings.lab"
    redirect_paths = ["/oauth2/callback"]
    roles = {
      "flux-admin"    = "Flux web admin"
      "flux-readonly" = "Flux web read-only"
    }
    users = {
      sthings  = ["flux-admin"]
      indy     = ["flux-admin"]
      tommy    = ["flux-admin"]
      mcfly    = ["flux-readonly"]
      mcclane  = ["flux-readonly"]
      fmcguire = ["flux-readonly"]
      rdevaney = ["flux-readonly"]
      someara  = ["flux-readonly"]
    }
  }
  # Flux web UI on homerun2-dev (harvester#719), same as flux-web-machinery-hv
  # above: groups zitadel:<role key>, ../../homerun2-dev/flux-web-rbac.yaml,
  # SOPS Secret ../../homerun2-dev/flux-web-oidc-zitadel.enc.yaml.
  flux-web-homerun2-dev = {
    url            = "https://flux.homerun2-dev.sthings.lab"
    redirect_paths = ["/oauth2/callback"]
    roles = {
      "flux-admin"    = "Flux web admin"
      "flux-readonly" = "Flux web read-only"
    }
    users = {
      sthings  = ["flux-admin"]
      indy     = ["flux-admin"]
      tommy    = ["flux-admin"]
      mcfly    = ["flux-readonly"]
      mcclane  = ["flux-readonly"]
      fmcguire = ["flux-readonly"]
      rdevaney = ["flux-readonly"]
      someara  = ["flux-readonly"]
    }
  }
}
