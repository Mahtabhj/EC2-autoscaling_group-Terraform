resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "main"
  }
}

resource "aws_subnet" "subnet1" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "app-subnet-1"
  }
}

resource "aws_subnet" "subnet2" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "elb-subnet-2"
  }
}


resource "aws_internet_gateway" "main-igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

resource "aws_eip" "nat" {}

resource "aws_nat_gateway" "main-natgw" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.subnet2.id

  tags = {
    Name = "main-nat"
  }
}

resource "aws_route_table" "main-public-rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main-natgw.id
  }

  tags = {
    Name = "main-public-rt"
  }
}

resource "aws_route_table_association" "public-assoc-1" {
  subnet_id      = aws_subnet.subnet1.id
  route_table_id = aws_route_table.main-public-rt.id
}

resource "aws_route_table_association" "public-assoc-2" {
  subnet_id      = aws_subnet.subnet2.id
  route_table_id = aws_route_table.main-public-rt.id
}

resource "aws_security_group" "bastion-sg" {
  name   = "bastion-security-group"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "elb-sg" {
  name        = "elb-security-group"
  description = "Security group for ELB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_configuration" "web_lc" {
  name                      = "web-launch-config"
  image_id                  = "ami-01428ed083fc6ed14"
  instance_type             = "t2.micro"
  associate_public_ip_address = true  # Associate a public IP with instances launched from this launch configuration
  security_groups           = [aws_security_group.bastion-sg.id]

  user_data = <<-EOL
    #!/bin/bash -xe
    sudo su
    apt-get update -y
    apt install apache2 -y
    systemctl status apache2
  EOL
}

resource "aws_autoscaling_group" "web_asg" {
  name                      = "web-asg"
  launch_configuration      = aws_launch_configuration.web_lc.name
  vpc_zone_identifier       = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  min_size                  = 2
  max_size                  = 5
  desired_capacity          = 2
  health_check_type         = "ELB"
  termination_policies      = ["OldestInstance"]
  load_balancers            = [aws_elb.web_elb.name]

  tag {
    key                 = "Name"
    value               = "HelloWorldASG"
    propagate_at_launch = true
  }
}

data "aws_autoscaling_group" "web_asg_data" {
  name = aws_autoscaling_group.web_asg.name
}

resource "aws_elb" "web_elb" {
  name               = "web-elb"
  subnets            = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  security_groups    = [aws_security_group.elb-sg.id]
  cross_zone_load_balancing = true

  health_check {
    target              = "HTTP:80/"
    interval            = 30
    timeout             = 5
    unhealthy_threshold = 2
    healthy_threshold   = 2
  }

  listener {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }
}

resource "aws_autoscaling_policy" "cpu_scale_out" {
  name                   = "cpu-scale-out-policy"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 0
}

resource "aws_autoscaling_policy" "cpu_scale_in" {
  name                   = "cpu-scale-in-policy"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 0
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_high" {
  alarm_name          = "cpu-utilization-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80.0
  alarm_description   = "Scale out if CPU utilization is high"
  alarm_actions       = [aws_autoscaling_policy.cpu_scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_low" {
  alarm_name          = "cpu-utilization-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 20.0
  alarm_description   = "Scale in if CPU utilization is low"
  alarm_actions       = [aws_autoscaling_policy.cpu_scale_in.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }
}
