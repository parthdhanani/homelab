output "instance_id" {
  description = "OCID of the compute instance"
  value       = oci_core_instance.cryptex_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = oci_core_instance.cryptex_server.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = oci_core_instance.cryptex_server.private_ip
}

output "instance_state" {
  description = "State of the instance"
  value       = oci_core_instance.cryptex_server.state
}

output "ubuntu_image_name" {
  description = "Name of the Ubuntu image used"
  value       = data.oci_core_images.ubuntu_2204_arm64.images[0].display_name
}

output "ssh_command" {
  description = "SSH command for connection"
  value       = "ssh -i ~/.ssh/cryptex_vps ubuntu@${oci_core_instance.cryptex_server.public_ip}"
}

output "deployment_summary" {
  description = "Complete deployment summary"
  value       = <<-EOT

    CRYPTEX VPS Deployed
    ────────────────────────────────────────
    Public IP:  ${oci_core_instance.cryptex_server.public_ip}
    Shape:      ${var.instance_shape} (${var.instance_ocpus} OCPUs, ${var.instance_memory_in_gbs} GB RAM)
    Storage:    ${var.boot_volume_size_in_gbs} GB
    OS:         ${data.oci_core_images.ubuntu_2204_arm64.images[0].display_name}

    SSH:        ssh -i ~/.ssh/cryptex_vps ubuntu@${oci_core_instance.cryptex_server.public_ip}

    Wait 5 minutes for cloud-init + reboot, then (canonical DR path — see bootstrap/README.md):
      1. ssh ubuntu@${oci_core_instance.cryptex_server.public_ip}   # needs your GitHub SSH key
      2. git clone git@github.com:parthdhanani/cryptex.git /opt/cryptex && cd /opt/cryptex
      3. ./replicate.sh --skeleton-env && nano .env   # fill B2 + Kopia creds from key bundle
      4. ./replicate.sh --skip-secrets                # system + stack
      5. ./replicate.sh --restore                     # pull latest Kopia snapshot from B2

  EOT
}
