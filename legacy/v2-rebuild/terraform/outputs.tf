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

    Wait 5 minutes for cloud-init + reboot, then:
      1. SSH in and verify: cat /var/log/cryptex-init.log
      2. Run: ./scripts/transfer-to-vps.sh ${oci_core_instance.cryptex_server.public_ip}
      3. SSH in, run: cd /opt/cryptex && ./scripts/setup-env.sh
      4. Run: ./scripts/deploy.sh

  EOT
}
