variable "aws_region" {
  description = "AWS Region where the Project 1B lab will be created."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to identify Project 1B AWS resources."
  type        = string
  default     = "mds-linux-hardening-1b"
}

variable "common_tags" {
  description = "Tags applied to resources created for this lab."
  type        = map(string)
  default = {
    Project     = "mds-linux-hardening-1b"
    Environment = "learning-lab"
    ManagedBy   = "Terraform"
  }
}

variable "vpc_cidr" {
  description = "Address range for the Project 1B VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zone" {
  description = "Single Availability Zone used by this lab."
  type        = string
  default     = "us-east-1a"
}

variable "public_subnet_cidr" {
  description = "Public subnet that will contain the NAT Gateway."
  type        = string
  default     = "10.20.0.0/24"
}

variable "admin_private_subnet_cidr" {
  description = "Private subnet for the Ansible admin node."
  type        = string
  default     = "10.20.10.0/24"
}

variable "target_private_subnet_cidr" {
  description = "Private subnet for the SFTP target node."
  type        = string
  default     = "10.20.20.0/24"
}

variable "admin_instance_type" {
  description = "Instance type for the Ansible admin node."
  type        = string
  default     = "t3.small"
}

variable "target_instance_type" {
  description = "Instance type for the SFTP target node."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for each EC2 instance."
  type        = number
  default     = 20
}

variable "target_data_volume_size_gib" {
  description = "Encrypted gp3 data volume size for target SFTP files."
  type        = number
  default     = 5
}
