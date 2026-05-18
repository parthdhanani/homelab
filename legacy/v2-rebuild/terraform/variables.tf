# Oracle Cloud Infrastructure Credentials
variable "tenancy_ocid" {
  description = "OCID of your tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the user calling the API"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint for the key pair being used"
  type        = string
}

variable "private_key_path" {
  description = "Path to your private API key file"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "Oracle Cloud region (e.g., ap-mumbai-1)"
  type        = string
  default     = "ap-mumbai-1"
}

variable "compartment_id" {
  description = "Compartment OCID (usually same as tenancy_ocid for root compartment)"
  type        = string
}

# Compute Instance Configuration
variable "instance_display_name" {
  description = "Display name for the compute instance"
  type        = string
  default     = "cryptex-vps"
}

variable "instance_shape" {
  description = "Shape of the instance (Ampere ARM free tier)"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs (max 4 for free tier)"
  type        = number
  default     = 4
}

variable "instance_memory_in_gbs" {
  description = "Amount of memory in GB (max 24 for free tier)"
  type        = number
  default     = 24
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB"
  type        = number
  default     = 100
}

# SSH Configuration
variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

# Network Configuration
variable "vcn_cidr_block" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr_block" {
  description = "CIDR block for the subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# Availability Domain
variable "availability_domain" {
  description = "Availability domain (format: XXXX:REGION-AD-1)"
  type        = string
}

# Tags
variable "freeform_tags" {
  description = "Free-form tags for resources"
  type        = map(string)
  default = {
    "Project"     = "CRYPTEX"
    "Environment" = "Production"
    "ManagedBy"   = "Terraform"
  }
}
