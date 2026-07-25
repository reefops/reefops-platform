path "platform/data/seaweedfs/s3" {
  capabilities = ["read"]
}

path "platform/metadata/seaweedfs/s3" {
  capabilities = ["read"]
}

# El gateway S3 necesita materializar su ACL para la identidad Barman.
# Esta política pertenece al sintetizador de configuración, no al consumidor.
path "platform/data/postgresql/barman-s3" {
  capabilities = ["read"]
}

path "platform/metadata/postgresql/barman-s3" {
  capabilities = ["read"]
}
