path "platform/data/postgresql/barman-s3" {
  capabilities = ["read"]
}

path "platform/metadata/postgresql/barman-s3" {
  capabilities = ["read"]
}

path "platform/data/identity/openfga-postgresql" {
  capabilities = ["read"]
}

path "platform/metadata/identity/openfga-postgresql" {
  capabilities = ["read"]
}

path "platform/data/identity/authorizer-postgresql" {
  capabilities = ["read"]
}

path "platform/metadata/identity/authorizer-postgresql" {
  capabilities = ["read"]
}

path "platform/data/identity/authorizer-migrator-postgresql" {
  capabilities = ["read"]
}

path "platform/metadata/identity/authorizer-migrator-postgresql" {
  capabilities = ["read"]
}
