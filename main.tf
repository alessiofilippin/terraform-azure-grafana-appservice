data "azurerm_subscription" "primary" {
}

data "azurerm_client_config" "current" {
}

data "http" "icanhazip" {
  url = "http://icanhazip.com"
}

resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-grafana-rg"
  location = var.azure_region
}

resource "azurerm_key_vault" "this" {
  name                        = "${var.prefix}-grafana-kv"
  location                    = azurerm_resource_group.this.location
  resource_group_name         = azurerm_resource_group.this.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "Get",
    ]

    secret_permissions = [
      "Get",
      "Set",
      "List"
    ]

    storage_permissions = [
      "Get",
    ]
  }
}

resource "random_password" "grafana_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}


resource "azurerm_key_vault_secret" "grafana_password" {
  name         = "grafana-password"
  value        = random_password.grafana_password.result
  key_vault_id = azurerm_key_vault.this.id
}

resource "azurerm_app_service_plan" "this" {
  name                = "${var.prefix}-grafana-app-plan"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  kind                = "Linux"
  reserved            = true

  sku {
    tier = var.grafana_plan_sku
    size = var.grafana_plan_size
  }
}

resource "azurerm_app_service_plan" "image_render" {
  count               = var.deploy_render == true ? 1 : 0
  name                = "${var.prefix}-img-render-app-plan"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  kind                = "Linux"
  reserved            = true

  sku {
    tier = var.image_render_plan_sku
    size = var.image_render_plan_size
  }
}

resource "azurerm_storage_account" "grafanadb" {
  name                      = "${var.prefix}grafanadatast"
  location                  = azurerm_resource_group.this.location
  resource_group_name       = azurerm_resource_group.this.name
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_2"
  enable_https_traffic_only = true

}

resource "azurerm_storage_share" "grafanadb_fileshare" {
  name                 = "grafana-data-storage"
  storage_account_name = azurerm_storage_account.grafanadb.name
  quota                = "50"

  depends_on = [
    azurerm_storage_account.grafanadb
  ]
}

resource "null_resource" "copy_grafana_db" {
  provisioner "local-exec" {
    command = <<-EOT
    az login --service-principal -u $env:ARM_CLIENT_ID -p $env:ARM_CLIENT_SECRET --tenant $env:ARM_TENANT_ID
    az account set --subscription $env:ARM_SUBSCRIPTION_ID
    $result = az storage file exists --account-name ${azurerm_storage_account.grafanadb.name} --path "grafana.db" --share-name ${azurerm_storage_share.grafanadb_fileshare.name} --account-key ${azurerm_storage_account.grafanadb.primary_access_key}
    $result = $result | ConvertFrom-Json
    if($result.exists -ne "True"){
       az storage copy -s ${path.module}/files/grafana.db -d https://${azurerm_storage_account.grafanadb.name}.file.core.windows.net/${azurerm_storage_share.grafanadb_fileshare.name} --account-key ${azurerm_storage_account.grafanadb.primary_access_key}
    }
    EOT

    interpreter = ["pwsh", "-Command"]
  }

  triggers = {
    always_run = "${timestamp()}"
  }

  depends_on = [
    azurerm_storage_share.grafanadb_fileshare
  ]
}

resource "azurerm_app_service" "image_render" {
  count               = var.deploy_render == true ? 1 : 0
  name                = "${var.prefix}-img-render-app"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  app_service_plan_id = azurerm_app_service_plan.image_render[0].id
  https_only          = true

  app_settings = merge(var.app_settings, {
    "DOCKER_REGISTRY_SERVER_URL"          = "https://index.docker.io/v1"
    "WEBSITES_CONTAINER_START_TIME_LIMIT" = "1800"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
  })

  identity {
    type = "SystemAssigned"
  }

  site_config {
    dotnet_framework_version = "v6.0"
    ftps_state               = "Disabled"
    http2_enabled            = true
    linux_fx_version         = var.image_render_docker_version
    always_on                = true
  }

  logs {
    failed_request_tracing_enabled  = true
    detailed_error_messages_enabled = true
    http_logs {
      file_system {
        retention_in_days = 4
        retention_in_mb   = 25
      }
    }
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"]
    ]
  }

  depends_on = [
    azurerm_app_service_plan.this
  ]
}

resource "azurerm_app_service" "this" {
  name                = "${var.prefix}-grafana-app"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  app_service_plan_id = azurerm_app_service_plan.this.id
  https_only          = true

  app_settings = merge(var.app_settings, {
    "DOCKER_REGISTRY_SERVER_URL"          = "https://index.docker.io/v1"
    "GF_AZURE_CLOUD"                      = "AzureCloud"
    "GF_AZURE_MANAGED_IDENTITY_ENABLED"   = "true"
    "GF_SECURITY_ADMIN_PASSWORD"          = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.this.name};SecretName=grafana-password)"
    "GF_DATABASE_URL"                     = "sqlite3:///var/lib/grafana/grafana.db?cache=private&mode=rwc&_journal_mode=WAL"
    "GF_SMTP_ENABLED"                     = var.smtp_on == true ? "true" : null
    "GF_SMTP_HOST"                        = var.smtp_on == true ? var.smtp_host : null
    "GF_SMTP_PASSWORD"                    = var.smtp_on == true ? var.smtp_password : null
    "GF_SMTP_USER"                        = var.smtp_on == true ? var.smtp_user : null
    "GF_SMTP_FROM_ADDRESS"                = var.smtp_on == true ? var.smtp_from_address : null
    "GF_SMTP_FROM_NAME"                   = var.smtp_on == true ? var.smtp_from_name : null
    "GF_RENDERING_SERVER_URL"             = var.deploy_render == true ? "http://${azurerm_app_service.image_render[0].default_site_hostname}/render" : null
    "GF_RENDERING_CALLBACK_URL"           = var.deploy_render == true ? "https://${var.prefix}-grafana-app.azurewebsites.net" : null
    "GF_LOG_FILTERS"                      = "rendering:debug"
    "GR_UNIFIED_ALERTING_ENABLED"         = "true"
    "GF_SERVER_ROOT_URL"                  = "https://${var.prefix}-grafana-app.azurewebsites.net"
    "WEBSITES_CONTAINER_START_TIME_LIMIT" = "1800"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
  })

  storage_account {
    name         = "grafana-data-storage"
    type         = "AzureFiles"
    account_name = azurerm_storage_account.grafanadb.name
    share_name   = azurerm_storage_share.grafanadb_fileshare.name
    access_key   = azurerm_storage_account.grafanadb.primary_access_key
    mount_path   = "/var/lib/grafana"
  }

  site_config {
    dotnet_framework_version = "v6.0"
    ftps_state               = "Disabled"
    http2_enabled            = true
    linux_fx_version         = var.grafana_docker_version
    always_on                = true

    cors {
      support_credentials = true
      allowed_origins     = var.deploy_cdn == true ? ["https://${var.prefix}-grafana-cdn-ep.azureedge.net"] : ["*"]
    }
  }

  logs {
    failed_request_tracing_enabled  = true
    detailed_error_messages_enabled = true
    http_logs {
      file_system {
        retention_in_days = 4
        retention_in_mb   = 25
      }
    }
  }



  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"]
    ]
  }

  depends_on = [
    azurerm_storage_account.grafanadb,
    azurerm_storage_share.grafanadb_fileshare,
    null_resource.copy_grafana_db,
    azurerm_app_service.image_render
  ]
}

resource "azurerm_key_vault_access_policy" "allow_grafana_for_secrets" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = azurerm_app_service.this.identity[0].tenant_id
  object_id    = azurerm_app_service.this.identity[0].principal_id

  key_permissions = [
    "Get",
  ]

  secret_permissions = [
    "Get",
  ]

  depends_on = [
    azurerm_app_service.this
  ]
}

resource "azurerm_role_assignment" "assign_grafana_as_sub_monitor_reader" {
  scope                = data.azurerm_subscription.primary.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_app_service.this.identity.0.principal_id

  depends_on = [
    azurerm_app_service.this,
    azurerm_app_service_plan.this
  ]
}

resource "azurerm_cdn_profile" "this" {
  name                = "${var.prefix}-grafana-cdn"
  location            = "global"
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard_Microsoft"

  depends_on = [
    azurerm_app_service.this
  ]
}

resource "azurerm_cdn_endpoint" "this" {
  name                          = "${var.prefix}-grafana-cdn-ep"
  profile_name                  = azurerm_cdn_profile.this.name
  location                      = "global"
  resource_group_name           = azurerm_resource_group.this.name
  is_http_allowed               = false
  querystring_caching_behaviour = "UseQueryString"
  origin_host_header            = azurerm_app_service.this.default_site_hostname
  is_compression_enabled        = true
  content_types_to_compress     = ["text/plain", "text/html", "text/css", "text/javascript", "application/x-javascript", "application/javascript", "application/json", "application/xml"]

  origin {
    name      = "grafana"
    host_name = azurerm_app_service.this.default_site_hostname
  }

  global_delivery_rule {
    modify_response_header_action {
      action = "Overwrite"
      name   = "origin"
      value  = "https://${azurerm_app_service.this.default_site_hostname}"
    }
    modify_request_header_action {
      action = "Overwrite"
      name   = "origin"
      value  = "https://${azurerm_app_service.this.default_site_hostname}"
    }
    cache_expiration_action {
      behavior = "Override"
      duration = "3.00:00:00"
    }
  }

  delivery_rule {
    name  = "HttpsRedirect"
    order = 1
    request_scheme_condition {
      match_values = ["HTTP"]
      operator     = "Equal"
    }
    url_redirect_action {
      redirect_type = "Found"
      protocol      = "Https"
    }
  }

  depends_on = [
    azurerm_cdn_profile.this
  ]
}