variable "prefix" {
  default     = ""
  type        = string
  description = "prefix to be used to name resources."
}

variable "app_settings" {
  default     = {}
  type        = map(any)
  description = "Map of app settings which they will be configured in the function app."
}

variable "azure_region" {
  default     = ""
  type        = string
  description = "Azure Region where resources will be deployed."
}

variable "deploy_render" {
  default     = false
  type        = bool
  description = "Flag to deploy or not the image render for grafana."
}

variable "deploy_cdn" {
  default     = false
  type        = bool
  description = "Flag to deploy or not a CDN on top of the Grafana WebApp."
}

variable "smtp_on" {
  default     = false
  type        = bool
  description = "Flag to configure the smtp server for grafana."
}

variable "smtp_host" {
  default     = ""
  type        = string
  description = "SMTP Server Host or IP with port."
}

variable "smtp_password" {
  default     = ""
  type        = string
  description = "SMTP Server Password."
}

variable "smtp_user" {
  default     = ""
  type        = string
  description = "SMTP User."
}

variable "smtp_from_address" {
  default     = ""
  type        = string
  description = "SMTP From Address to use."
}

variable "smtp_from_name" {
  default     = ""
  type        = string
  description = "SMTP From Name to use."
}

variable "grafana_docker_version" {
  default     = "DOCKER|grafana/grafana-oss:9.1.1"
  type        = string
  description = "Path to dockerHub image."
}

variable "image_render_docker_version" {
  default     = "DOCKER|grafana/grafana-image-renderer"
  type        = string
  description = "Path to dockerHub image"
}

variable "grafana_plan_sku" {
  default     = "Basic"
  type        = string
  description = "SKU Type"
}

variable "grafana_plan_size" {
  default     = "B3"
  type        = string
  description = "SKU Size"
}

variable "image_render_plan_sku" {
  default     = "Basic"
  type        = string
  description = "SKU Type"
}

variable "image_render_plan_size" {
  default     = "B2"
  type        = string
  description = "SKU Size"
}