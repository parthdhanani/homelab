# Virtual Cloud Network
resource "oci_core_vcn" "cryptex_vcn" {
  compartment_id = var.compartment_id
  display_name   = "cryptex-vcn"
  cidr_blocks    = [var.vcn_cidr_block]
  dns_label      = "cryptex"
  freeform_tags  = var.freeform_tags
}

# Internet Gateway
resource "oci_core_internet_gateway" "cryptex_igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.cryptex_vcn.id
  display_name   = "cryptex-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

# Route Table
resource "oci_core_route_table" "cryptex_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.cryptex_vcn.id
  display_name   = "cryptex-route-table"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.cryptex_igw.id
  }
}

# Security List - Zero Attack Surface (SSH + ICMP only)
resource "oci_core_default_security_list" "cryptex_security_list" {
  manage_default_resource_id = oci_core_vcn.cryptex_vcn.default_security_list_id
  display_name               = "cryptex-security-list"
  freeform_tags              = var.freeform_tags

  # Egress: Allow all outbound
  egress_security_rules {
    destination      = "0.0.0.0/0"
    protocol         = "all"
    description      = "Allow all outbound traffic"
    destination_type = "CIDR_BLOCK"
    stateless        = false
  }

  # Ingress: SSH on port 22
  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "SSH (port 22)"
    stateless   = false

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Ingress: ICMP Echo Reply
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "ICMP Echo Reply"
    stateless   = false

    icmp_options {
      type = 0
    }
  }

  # Ingress: ICMP Echo Request (ping)
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "ICMP Echo Request (ping)"
    stateless   = false

    icmp_options {
      type = 8
    }
  }

  # Ingress: ICMP Destination Unreachable (Path MTU Discovery)
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "ICMP Destination Unreachable (Path MTU Discovery)"
    stateless   = false

    icmp_options {
      type = 3
      code = 4
    }
  }

  # No HTTP/HTTPS ports — all web traffic via Cloudflare Tunnel
}

# Subnet
resource "oci_core_subnet" "cryptex_subnet" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.cryptex_vcn.id
  cidr_block                 = var.subnet_cidr_block
  display_name               = "cryptex-subnet"
  dns_label                  = "cryptex"
  route_table_id             = oci_core_route_table.cryptex_route_table.id
  security_list_ids          = [oci_core_default_security_list.cryptex_security_list.id]
  dhcp_options_id            = oci_core_vcn.cryptex_vcn.default_dhcp_options_id
  prohibit_public_ip_on_vnic = false
  freeform_tags              = var.freeform_tags
}
