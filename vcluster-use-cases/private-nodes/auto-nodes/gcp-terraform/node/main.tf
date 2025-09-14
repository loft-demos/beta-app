terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6"
    }
  }
}

locals {
  project = var.vcluster.requirements["project"]
  region  = var.vcluster.requirements["region"]
  zone    = var.vcluster.requirements["zone"]

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
}

provider "google" {
  project = local.project
  region  = local.region
  zone    = local.zone
}

resource "random_id" "vm_suffix" {
  byte_length = 4
}

module "private_instance" {
  source  = "terraform-google-modules/vm/google//modules/compute_instance"
  version = "~> 13.0"

  region            = local.region
  zone              = local.zone
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

data "google_project" "project" {
  project_id = local.project
}

data "google_compute_image" "img" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance_template" "spot_tpl" {
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
