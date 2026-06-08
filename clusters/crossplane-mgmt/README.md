


kubectl create secret generic crossplane-mgmt   --namespace argocd   --from-file=kubeconfig=/home/sthings/.kube/crossplane-mgmt 
secret/crossplane-mgmt created

dagger call -m github.com/stuttgart-things/dagger/sops encrypt   --age-key env:AGE_PUB   --plaintext-file ~/.kube/crossplane-mgmt   --file-extension yaml   export --path=/home/sthings/harvester/secrets/crossplane-mgmt.sthings.lab


# CREATE — override Secret names / namespace / TTL
dagger call -m github.com/stuttgart-things/blueprints/argocd create-vault-issuer \
  --cluster-name homerun2-dev \
  --kubeconfig-source-file /home/sthings/harvester/secrets/crossplane-mgmt.sthings.lab.yaml \
  --vault-env-file /home/sthings/harvester/clusters/infra/vault-infra-lab.enc.yaml \
  --sops-key env:SOPS_AGE_KEY \
  --target-namespace cert-manager \
  --token-secret-name cert-manager-vault-token \
  --ca-secret-name vault-pki-ca \
  --token-ttl 8760h \
  --progress plain