# Provider configuration (e.g. for AWS)
provider "aws" {
  region = "ap-east-1"
}

/*&module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "main"
  cidr = "10.0.0.0/16"

  azs             = ["ap-east-1a", "ap-east-1b"]
  private_subnets = ["10.0.1.0/24"]
  public_subnets  = ["10.0.101.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = false
} */

# VPC configuration
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Public Subnet configuration
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-east-1a"
}

# Private Subnet configuration
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-east-1b"
}

# Security Group configuration for Load Balancer
resource "aws_security_group" "lb" {
  name_prefix = "lb-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443 # Secure HTTPS port
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group configuration for EC2 instance
resource "aws_security_group" "web" {
  name_prefix = "web-"
  vpc_id      = aws_vpc.main.id

  # Allow SSH access from your public IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_PUBLIC_IP/32"] # Replace with your public IP address
  }

  # Allow inbound traffic from the ALB's security group
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instance configuration
resource "aws_instance" "web" {
  ami                    = "ami-0adf9038274eb22ed" # Amazon Linux 2 LTS AMI (HVM), SSD Volume Type
  instance_type          = "t2.micro"
  key_name               = "sshkey"
  subnet_id              = aws_subnet.private.id # Placing EC2 instance in the private subnet
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<EOF
              #!/bin/bash
              echo "Hello, World!" > index.html
              nohup python -m SimpleHTTPServer 80 &
              EOF
}

# EBS volume configuration
resource "aws_ebs_volume" "web" {
  availability_zone = "ap-east-1a"
  size              = 30
  type              = "gp3"
  tags = {
    Name = "web-ebs"
  }
}

# Attach EBS volume to EC2 instance
resource "aws_volume_attachment" "web" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.web.id
  instance_id = aws_instance.web.id
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Attach Internet Gateway to the Public Subnet
resource "aws_internet_gateway_attachment" "igw_attachment" {
  vpc_id              = aws_vpc.main.id
  internet_gateway_id = aws_internet_gateway.igw.id
}

# Add a Route to the Internet Gateway for Public Subnet
resource "aws_route" "public_internet_route" {
  route_table_id         = aws_subnet.public.route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Application Load Balancer (ALB) configuration
resource "aws_lb" "web" {
  name               = "alb-web"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb.id]
  subnets            = [aws_subnet.public.id]

  tags = {
    Name = "ALB-web"
  }

  # Enable HTTPS on ALB
  enable_deletion_protection = false
  idle_timeout               = 400
  enable_http2               = true
}

# ALB Listener configuration
resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.web.arn
  port              = "443" # Secure HTTPS port
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ALB Target Group configuration
resource "aws_lb_target_group" "web" {
  name     = "web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

# Auto Scaling Group (ASG) configuration
resource "aws_autoscaling_group" "web" {
  name                 = "web-asg"
  max_size             = 2
  min_size             = 1
  desired_capacity     = 1
  launch_configuration = aws_launch_configuration.web.name
  vpc_zone_identifier  = [aws_subnet.private.id]
  health_check_type    = "ELB"
}

# Launch Configuration configuration
resource "aws_launch_configuration" "web" {
  name_prefix                 = "web-lc-"
  image_id                    = "ami-0adf9038274eb22ed"
  instance_type               = "t2.micro"
  security_groups             = [aws_security_group.web.id]
  associate_public_ip_address = true

  user_data = <<EOF
              #!/bin/bash
              echo "Hello, World!" > index.html
              nohup python -m SimpleHTTPServer 80 &
              EOF
}

# ALB Listener Rule configuration
resource "aws_lb_listener_rule" "web" {
  listener_arn = aws_lb_listener.web.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  condition {
    host_header {
      values = ["your-domain.com"] # Replace with your domain name
    }
  }
}

# ALB Target Group Attachment configuration
resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

