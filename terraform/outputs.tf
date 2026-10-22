output "admin_instance_id" {
  description = "EC2 instance ID for the private Ansible control node."
  value       = aws_instance.admin.id
}

output "admin_private_ip" {
  description = "Private IPv4 address of the Ansible control node."
  value       = aws_instance.admin.private_ip
}

output "target_instance_id" {
  description = "EC2 instance ID for the private SFTP target."
  value       = aws_instance.target.id
}

output "target_private_ip" {
  description = "Private IPv4 address of the SFTP target."
  value       = aws_instance.target.private_ip
}

output "ansible_transfer_bucket" {
  description = "Private S3 bucket used for temporary Ansible module transfers."
  value       = aws_s3_bucket.ansible_transfer.bucket
}
