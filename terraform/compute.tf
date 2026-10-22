resource "aws_instance" "admin" {
  ami                         = data.aws_ssm_parameter.ubuntu_2404_amd64.value
  instance_type               = var.admin_instance_type
  subnet_id                   = aws_subnet.admin_private.id
  vpc_security_group_ids      = [aws_security_group.admin.id]
  iam_instance_profile        = aws_iam_instance_profile.admin.name
  associate_public_ip_address = false

  user_data = <<-BOOTSTRAP
    #!/bin/bash
    set -eu

    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
      if [ -f "$source_file" ]; then
        sed -i 's|http://|https://|g' "$source_file"
      fi
    done
  BOOTSTRAP

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_size_gib
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.common_tags, {
      Name = "${var.project_name}-admin-root"
    })
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin"
    Role = "admin"
  })
}

resource "aws_instance" "target" {
  ami                         = data.aws_ssm_parameter.ubuntu_2404_amd64.value
  instance_type               = var.target_instance_type
  subnet_id                   = aws_subnet.target_private.id
  vpc_security_group_ids      = [aws_security_group.target.id]
  iam_instance_profile        = aws_iam_instance_profile.target.name
  associate_public_ip_address = false

  user_data = <<-BOOTSTRAP
    #!/bin/bash
    set -eu

    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
      if [ -f "$source_file" ]; then
        sed -i 's|http://|https://|g' "$source_file"
      fi
    done
  BOOTSTRAP

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_size_gib
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(var.common_tags, {
      Name = "${var.project_name}-target-root"
    })
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target"
    Role = "target"
  })
}

resource "aws_ebs_volume" "target_data" {
  availability_zone = var.availability_zone
  size              = var.target_data_volume_size_gib
  type              = "gp3"
  encrypted         = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-sftp-data"
    Role = "target-data"
  })
}

resource "aws_volume_attachment" "target_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.target_data.id
  instance_id = aws_instance.target.id
}
