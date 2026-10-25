// State lives on the edge node itself, as a Secret in namespace minio
// (tfstate-default-minio-edge) -- no central S3, like everything here.
// config_path is where dagger/terraform mounts --kube-config
// (its kubeConfigPath default). For a local `terraform` run, pass
// -backend-config=config_path=$HOME/.kube/edge-tt-test1.
//
// Lost with the node on a reinstall; that is fine: `apply` re-creates the
// user and policy, and the import block below re-adopts the bucket.
terraform {
  backend "kubernetes" {
    secret_suffix = "minio-edge" # pragma: allowlist secret
    namespace     = "minio"
    config_path   = "/root/.kube/config"
  }
}
