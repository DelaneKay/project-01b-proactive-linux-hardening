resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_subnet" "nat_public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-public"
    Tier = "public"
  })
}

resource "aws_subnet" "admin_private" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.admin_private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-private"
    Tier = "private"
  })
}

resource "aws_subnet" "target_private" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.target_private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-private"
    Tier = "private"
  })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_route_table" "nat_public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-public-rt"
    Tier = "public"
  })
}

resource "aws_route_table_association" "nat_public" {
  subnet_id      = aws_subnet.nat_public.id
  route_table_id = aws_route_table.nat_public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat-eip"
  })
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.nat_public.id

  depends_on = [aws_internet_gateway.lab]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-nat"
  })
}

resource "aws_route_table" "admin_private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-admin-private-rt"
    Tier = "private"
  })
}

resource "aws_route_table_association" "admin_private" {
  subnet_id      = aws_subnet.admin_private.id
  route_table_id = aws_route_table.admin_private.id
}

resource "aws_route_table" "target_private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-target-private-rt"
    Tier = "private"
  })
}

resource "aws_route_table_association" "target_private" {
  subnet_id      = aws_subnet.target_private.id
  route_table_id = aws_route_table.target_private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.admin_private.id,
    aws_route_table.target_private.id
  ]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.ansible_transfer.arn
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.ansible_transfer.arn}/*"
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          "arn:aws:s3:::session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb",
          "arn:aws:s3:::session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb.sig"
        ]
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-s3-endpoint"
  })
}
