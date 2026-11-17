# Portal users -- a copy of the vSphere labs' list
# (stuttgart-things/stuttgart-things clusters/labul/vsphere/infra-sthings/
# zitadel-portal-config/users.auto.tfvars); keep them in step. No passwords
# here: initial ones via TF_VAR_user_initial_passwords (README), changed at
# the first login.
# Removing a user from this list deletes it in ZITADEL.
users = {
  sthings  = { email = "sthings@sthings-edge.com", first_name = "Stuttgart", last_name = "Things", roles = ["portal-admin"] }
  indy     = { email = "indy@sthings-edge.com", first_name = "Henry", last_name = "Jones", roles = ["portal-admin"] }
  tommy    = { email = "tommy@sthings-edge.com", first_name = "Tom", last_name = "O’Meara", roles = ["portal-admin"] }
  mcfly    = { email = "mcfly@sthings-edge.com", first_name = "Marty", last_name = "McFly", roles = ["portal-user"] }
  mcclane  = { email = "mcclane@sthings-edge.com", first_name = "John", last_name = "McClane", roles = ["portal-user"] }
  fmcguire = { email = "fmcguire@sthings-edge.com", first_name = "Frankie", last_name = "McGuire", roles = ["portal-user"] }
  rdevaney = { email = "rdevaney@sthings-edge.com", first_name = "Rory", last_name = "Devaney", roles = ["portal-user"] }
  someara  = { email = "someara@sthings-edge.com", first_name = "Sheila", last_name = "O’Meara", roles = ["portal-user"] }
}

# sthings-backstage roles (#675, #676, #681), as on LabUL/LabDA: portal-admin
# -> backstage-platform, portal-user -> backstage-developer. The beta/team
# roles of the vSphere labs (doc, biff) are not used here yet.
backstage_roles = {
  sthings  = ["backstage-platform"]
  indy     = ["backstage-platform"]
  tommy    = ["backstage-platform"]
  mcfly    = ["backstage-developer"]
  mcclane  = ["backstage-developer"]
  fmcguire = ["backstage-developer"]
  rdevaney = ["backstage-developer"]
  someara  = ["backstage-developer"]
}

# No vault / argocd project yet (lab.auto.tfvars): ArgoCD's roles are in
# apps.auto.tfvars (harvester-extras.tf) until #677.
vault_roles  = {}
argocd_roles = {}
