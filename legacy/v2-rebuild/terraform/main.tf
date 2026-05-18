# Ubuntu 22.04 ARM64 Image
data "oci_core_images" "ubuntu_2204_arm64" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Compute Instance
resource "oci_core_instance" "cryptex_server" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = var.instance_display_name
  shape               = var.instance_shape
  freeform_tags       = var.freeform_tags

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.cryptex_subnet.id
    display_name     = "cryptex-vnic"
    assign_public_ip = true
    hostname_label   = "cryptex"
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_2204_arm64.images[0].id
    # Terraform provider v8.2.0+ correctly handles int64 for boot_volume_size_in_gbs
    # Value comes from terraform.tfvars (boot_volume_size_in_gbs = 200)
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(file("${path.module}/cloud-init.yaml"))
  }

  # Delete boot volume when instance is terminated (prevents orphaned volume charges)
  preserve_boot_volume = false

  timeouts {
    create = "30m"
  }
}
