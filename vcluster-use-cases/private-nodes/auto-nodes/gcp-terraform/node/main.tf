terraform {
  required_version = ">= 1.5"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 6" }
    random = { source = "hashicorp/random", version = ">= 3.6.0" }
  }
}

locals {
  project = var.vcluster.requirements["project"]
  region  = var.vcluster.requirements["region"]
  
  # Accept multiple zones (comma-separated) or "*", or leave blank
  zone_input = try(var.vcluster.requirements["zone"], "")

  vcluster_name      = var.vcluster.instance.metadata.name
  vcluster_namespace = var.vcluster.instance.metadata.namespace

  network_name = var.vcluster.nodeEnvironment.outputs["network_name"]
  subnet_name  = var.vcluster.nodeEnvironment.outputs["subnet_name"]

  instance_type = var.vcluster.nodeType.spec.properties["instance-type"]

  # New: capture spot property from NodeType
  use_spot = try(
    lower(var.vcluster.nodeType.spec.properties["spot"]) == "true",
    false
  )

  # Parse zones into a list (trim blanks)
  zones_raw = compact([for z in split(",", tostring(local.zone_input)) : trimspace(z)])
  # contains() is for lists; use regex to test for '-' in strings
  zones_are_full = length(local.zones_raw) > 0 && anytrue([
    for z in local.zones_raw : can(regex("-", z))
  ])
}

provider "google" {
  project = local.project
  region  = local.region
}

# Discover available zones (all), we'll filter to the selected region
data "google_compute_zones" "all" {}

# Pick one zone inside the selected region from the allowed set
locals {
  # All zones belonging to the selected region
  region_zones = [for z in data.google_compute_zones.all.names : z if startswith(z, "${local.region}-")]

  # Expand input:
  # - if empty or "*" -> all region zones
  # - if full names were provided -> use as-is
  # - else treat entries as suffixes (a,b,c) and expand to "${region}-a", etc.
  expanded_zones = (
    length(local.zones_raw) == 0 || contains(local.zones_raw, "*")
    ? local.region_zones
    : (
        local.zones_are_full
        ? local.zones_raw
        : [for s in local.zones_raw : "${local.region}-${s}"]
      )
  )

  # Keep only zones that actually exist in the selected region
  candidate_zones = [for z in local.expanded_zones : z if contains(local.region_zones, z)]
}

resource "random_id" "vm_suffix" {
  byte_length = 4
}

resource "random_shuffle" "pick_zone" {
  input        = local.candidate_zones
  result_count = 1
  keepers = {
    # Change these to control when the zone is re-picked
    node_request = random_id.vm_suffix.hex
    region       = local.region
    zones_hash   = join(",", local.candidate_zones)
  }
}

locals {
  # Fallback to first region zone if somehow candidate list is empty
  selected_zone = length(random_shuffle.pick_zone.result) > 0 ? random_shuffle.pick_zone.result[0] : local.region_zones[0]
}

data "google_project" "project" {
  project_id = local.project
}

data "google_compute_image" "img" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

# Optional: pin provider.zone to the selected zone (some resources read it)
provider "google" {
  alias   = "with_zone"
  project = local.project
  region  = local.region
  zone    = local.selected_zone
}

module "private_instance" {
  source  = "terraform-google-modules/vm/google//modules/compute_instance"
  version = "~> 13.0"

  region            = local.region
  zone              = local.selected_zone
  subnetwork        = local.subnet_name
  num_instances     = 1
  hostname          = "gcp-${var.vcluster.name}-beta-${random_id.vm_suffix.hex}"
  instance_template = google_compute_instance_template.spot_tpl.self_link

  # Will use NAT
  access_config = []

  labels = {
    vcluster  = local.vcluster_name
    namespace = local.vcluster_namespace
  }
}

resource "google_compute_instance_template" "spot_tpl" {
  provider    = google.with_zone
  project     = local.project
  name_prefix = "${var.vcluster.name}-beta-"
  region      = local.region

  machine_type = local.instance_type

  disk {
    source_image = data.google_compute_image.img.self_link
    auto_delete  = true
    boot         = true
    disk_type    = "pd-standard"
    disk_size_gb = 100
  }

  network_interface {
    subnetwork = local.subnet_name
  }

  service_account {
    email  = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data = var.vcluster.userData
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    cloud-init status --wait || true
  EOT

  scheduling {
    provisioning_model  = local.use_spot ? "SPOT" : "STANDARD"
    preemptible         = local.use_spot
    automatic_restart   = local.use_spot ? false : true
    on_host_maintenance = local.use_spot ? "TERMINATE" : "MIGRATE"
  }
}
