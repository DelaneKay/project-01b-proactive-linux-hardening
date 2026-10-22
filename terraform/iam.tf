resource "aws_iam_policy" "ssm_agent" {
  name        = "${var.project_name}-ssm-agent-policy"
  description = "Minimum Session Manager agent permissions for Project 1B"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SessionManagerAgentChannels"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-ssm-agent-policy"
  })
}

resource "aws_iam_role" "admin" {
  name = "${var.project_name}-admin-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-role"
    Role = "admin"
  })
}

resource "aws_iam_role" "target" {
  name = "${var.project_name}-target-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-role"
    Role = "target"
  })
}

resource "aws_iam_role_policy_attachment" "admin_ssm_agent" {
  role       = aws_iam_role.admin.name
  policy_arn = aws_iam_policy.ssm_agent.arn
}

resource "aws_iam_role_policy_attachment" "target_ssm_agent" {
  role       = aws_iam_role.target.name
  policy_arn = aws_iam_policy.ssm_agent.arn
}

resource "aws_iam_instance_profile" "admin" {
  name = "${var.project_name}-admin-profile"
  role = aws_iam_role.admin.name

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-profile"
    Role = "admin"
  })
}

resource "aws_iam_instance_profile" "target" {
  name = "${var.project_name}-target-profile"
  role = aws_iam_role.target.name

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-profile"
    Role = "target"
  })
}

data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "admin_ssm_client" {
  name        = "${var.project_name}-admin-ssm-client-policy"
  description = "Allow the admin node to manage Session Manager sessions to the target"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartSessionOnTarget"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.target.id}",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell"
        ]
      },
      {
        Sid    = "ManageOwnSessions"
        Effect = "Allow"
        Action = [
          "ssm:ResumeSession",
          "ssm:TerminateSession",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/&{aws:userid}-*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-ssm-client-policy"
  })
}

resource "aws_iam_role_policy_attachment" "admin_ssm_client" {
  role       = aws_iam_role.admin.name
  policy_arn = aws_iam_policy.admin_ssm_client.arn
}

resource "aws_iam_policy" "admin_s3_transfer" {
  name        = "${var.project_name}-admin-s3-transfer-policy"
  description = "Allow the admin node to use only the Ansible transfer bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BucketListingAndLocation"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.ansible_transfer.arn
      },
      {
        Sid    = "TransferTemporaryFiles"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.ansible_transfer.arn}/*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-s3-transfer-policy"
  })
}

resource "aws_iam_role_policy_attachment" "admin_s3_transfer" {
  role       = aws_iam_role.admin.name
  policy_arn = aws_iam_policy.admin_s3_transfer.arn
}
