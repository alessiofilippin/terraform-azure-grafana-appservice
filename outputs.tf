output "grafana_url" {
  value = azurerm_app_service.this.default_site_hostname
}

output "grafana_username" {
  value = "admin"
}

output "grafana_password" {
  value = azurerm_key_vault_secret.grafana_password.value
  sensitive = true
}