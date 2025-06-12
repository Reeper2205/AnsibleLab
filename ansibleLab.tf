# Provider configuration
provider "aws" {
  region = "eu-west-1"
}

# Data sources for latest AMIs
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC configuration
resource "aws_vpc" "ansible_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "ansible-lab-vpc"
  }
}

# Public subnet for NAT gateway
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.ansible_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "ansible-public-subnet"
  }
}

# Private subnet for instances
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.ansible_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-1a"
  tags = {
    Name = "ansible-private-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.ansible_vpc.id
  tags = {
    Name = "ansible-igw"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "ansible-nat-eip"
  }
}

# NAT Gateway
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
  tags = {
    Name = "ansible-nat-gw"
  }
  depends_on = [aws_internet_gateway.igw]
}

# Route table for public subnet
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.ansible_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "ansible-public-rt"
  }
}

resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Route table for private subnet
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.ansible_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
  tags = {
    Name = "ansible-private-rt"
  }
}

resource "aws_route_table_association" "private_rt_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

# Security Group for all instances
resource "aws_security_group" "ansible_sg" {
  vpc_id = aws_vpc.ansible_vpc.id
  name   = "ansible-ssh-sg"

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    description = "All traffic from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ansible-ssh-sg"
  }
}

# IAM Role and Instance Profile for SSM
resource "aws_iam_role" "ssm_role" {
  name = "ansible-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_instance_profile" {
  name = "ansible-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# Control Node (Ubuntu, t3.medium)
resource "aws_instance" "control_node" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.private_subnet.id
  vpc_security_group_ids      = [aws_security_group.ansible_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_instance_profile.name
  associate_public_ip_address = false

  tags = {
    Name = "ansible-control-node"
  }
}

# Test Machines (Amazon Linux, t3.micro)
resource "aws_instance" "test_node" {
  count                       = 3
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private_subnet.id
  vpc_security_group_ids      = [aws_security_group.ansible_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_instance_profile.name
  associate_public_ip_address = false

  tags = {
    Name = "ansible-test-node-${count.index + 1}"
  }
}

# Outputs
output "control_node_private_ip" {
  description = "Private IP of the control node"
  value       = aws_instance.control_node.private_ip
}

output "test_nodes_private_ips" {
  description = "Private IPs of the test nodes"
  value       = aws_instance.test_node[*].private_ip
}