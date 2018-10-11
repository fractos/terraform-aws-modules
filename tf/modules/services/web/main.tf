########
# ROLE #
########

resource "aws_iam_role" "service" {
  name = "${var.name}-service-role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "service" {
  name = "${var.name}-service-role-policy"
  role = "${aws_iam_role.service.name}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:AuthorizeSecurityGroupIngress",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:Describe*",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

###########
# SERVICE #
###########

resource "aws_ecs_service" "service" {
  name            = "${var.name}"
  cluster         = "${var.cluster_id}"
  task_definition = "${var.task_definition_arn}"
  desired_count   = "${var.desired_count}"
  iam_role        = "${aws_iam_role.service.id}"

  load_balancer {
    target_group_arn = "${aws_alb_target_group.service.arn}"
    container_name   = "${var.container_name}"
    container_port   = "${var.container_port}"
  }

  depends_on = [
    "aws_iam_role_policy.service",
  ]
}

###################
# SSL CERTIFICATE #
###################

resource "aws_iam_server_certificate" "service" {
  count       = "${var.certificate_body == "" ? 0 : 1}"
  name_prefix = "${var.hostname}.${var.domain}"

  certificate_body  = "${var.certificate_body}"
  private_key       = "${var.certificate_key}"
  certificate_chain = "${var.certificate_chain}"

  lifecycle {
    create_before_destroy = true
  }
}

##################
# SECURITY GROUP #
##################

data "aws_security_group" "default" {
  vpc_id = "${var.vpc}"
  name   = "default"
}

resource "aws_security_group" "web" {
  count       = "${var.load_balancer_arn == "" ? 1 : 0}"
  name        = "${var.name}-web"
  description = "Web access for ${var.name}"
  vpc_id      = "${var.vpc}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${var.ip_whitelist}"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${var.ip_whitelist}"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Project = "${var.project}"
  }
}

#############################
# APPLICATION LOAD BALANCER #
#############################

resource "aws_alb" "service" {
  count   = "${var.load_balancer_arn == "" ? 1 : 0}"
  name    = "${var.name}"
  subnets = ["${var.subnets}"]

  security_groups = [
    "${aws_security_group.web.id}",
    "${data.aws_security_group.default.id}",
  ]

  tags {
    Project = "${var.project}"
  }
}

resource "aws_alb_target_group" "service" {
  name                 = "${var.name}"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = "${var.vpc}"
  deregistration_delay = 30

  health_check {
    path                = "${var.health_check_path}"
    timeout             = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 60
    matcher             = "${var.health_check_matcher}"
  }
}

resource "aws_alb_listener" "http" {
  count             = "${var.load_balancer_arn == "" ? 1 : 0}"
  load_balancer_arn = "${aws_alb.service.id}"
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.service.id}"
    type             = "forward"
  }
}

resource "aws_alb_listener" "https_new_cert" {
  count             = "${var.load_balancer_arn == ""  && var.certificate_arn == "" ? 1 : 0}"
  load_balancer_arn = "${aws_alb.service.id}"
  port              = 443
  protocol          = "HTTPS"

  ssl_policy      = "${var.elb_ssl_policy}"
  certificate_arn = "${aws_iam_server_certificate.service.arn}"

  default_action {
    target_group_arn = "${aws_alb_target_group.service.id}"
    type             = "forward"
  }
}

resource "aws_alb_listener" "https_existing_cert" {
  count             = "${var.load_balancer_arn == "" && var.certificate_arn != "" ? 1 : 0}"
  load_balancer_arn = "${aws_alb.service.id}"
  port              = 443
  protocol          = "HTTPS"

  ssl_policy      = "${var.elb_ssl_policy}"
  certificate_arn = "${var.certificate_arn}"

  default_action {
    target_group_arn = "${aws_alb_target_group.service.id}"
    type             = "forward"
  }
}

resource "aws_alb_listener_rule" "http" {
  count        = "${var.load_balancer_http_listener_arn == "" ? 0 : 1}"
  listener_arn = "${var.load_balancer_http_listener_arn}"
  priority     = "${var.service_number_http}"

  action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.service.arn}"
  }

  condition {
    field  = "host-header"
    values = ["${var.hostname}.${var.domain}"]
  }

  lifecycle {
    ignore_changes = ["priority"]
  }
}

resource "aws_alb_listener_rule" "https" {
  count        = "${var.load_balancer_https_listener_arn == "" ? 0 : 1}"
  listener_arn = "${var.load_balancer_https_listener_arn}"
  priority     = "${var.service_number_https}"

  action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.service.arn}"
  }

  condition {
    field  = "host-header"
    values = ["${var.hostname}.${var.domain}"]
  }

  lifecycle {
    ignore_changes = ["priority"]
  }
}

#######
# DNS #
#######

resource "aws_route53_record" "service" {
  zone_id = "${var.external_zone_id}"
  name    = "${var.hostname}.${var.domain}"
  type    = "A"

  alias {
    name                   = "${var.load_balancer_fqdn == "" ? join("", aws_alb.service.*.dns_name) : var.load_balancer_fqdn}"
    zone_id                = "${var.load_balancer_zone_id == "" ? join("", aws_alb.service.*.zone_id) : var.load_balancer_zone_id}"
    evaluate_target_health = false
  }
}
