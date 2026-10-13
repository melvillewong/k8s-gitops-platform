# because: CI reads only the notification webhook, never Loki's or Grafana's secrets
path "secret/data/notify/discord" {
  capabilities = ["read"]
}
