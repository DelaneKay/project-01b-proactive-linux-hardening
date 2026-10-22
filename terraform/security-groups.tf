resource "aws_security_group" "admin" {
  name        = "${var.project_name}-admin-sg"
  description = "Admin node: no inbound access; outbound HTTPS for AWS services"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "HTTPS to AWS Systems Manager and S3 endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-sg"
    Role = "admin"
  })
}

resource "aws_security_group" "target" {
  name        = "${var.project_name}-target-sg"
  description = "Target node: no inbound access; outbound HTTPS for AWS services"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "HTTPS to AWS Systems Manager and S3 endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-sg"
    Role = "target"
  })
}
