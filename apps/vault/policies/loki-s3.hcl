# Read-only access to the Garage S3 key for Loki (task-07). KV v2 reads go through `data/`.
path "secret/data/garage/loki-key" {
  capabilities = ["read"]
}
