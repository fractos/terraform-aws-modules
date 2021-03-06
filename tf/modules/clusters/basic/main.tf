# Basic cluster module

resource "aws_ecs_cluster" "basic" {
  name = "${var.cluster_name}"
}

data "template_file" "dockerhub_credentials" {
  template = "${file("${path.module}/files/s3-objects/bootstrap-objects/dockerhub_credentials.template")}"

  vars {
    cluster_id         = "${aws_ecs_cluster.basic.name}"
    dockerhub_username = "${var.dockerhub_username}"
    dockerhub_password = "${var.dockerhub_password}"
    dockerhub_email    = "${var.dockerhub_email}"
  }
}

resource "aws_s3_bucket_object" "dockerhub_credentials" {
  count   = "${var.dockerhub_username == "" ? 0 : 1}"
  bucket  = "${var.bootstrap_objects_bucket}"
  key     = "${aws_ecs_cluster.basic.name}/dockerhub_credentials"
  content = "${data.template_file.dockerhub_credentials.rendered}"
}

resource "aws_iam_role" "basic" {
  name = "${var.cluster_name}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "basic_ec2" {
  role = "${aws_iam_role.basic.name}"

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_policy" "basic_abilities" {
  count       = "${var.bootstrap_objects_bucket == "" ? 0 : 1}"
  name        = "${var.cluster_name}"
  description = "Cluster userdata abilities (route53, s3 access)"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:HeadObject"
        ],
        "Resource": "arn:aws:s3:::${var.bootstrap_objects_bucket}/*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "s3:ListBucket"
        ],
        "Resource": "arn:aws:s3:::${var.bootstrap_objects_bucket}"
      }
    ]
  }
EOF
}

resource "aws_iam_role_policy_attachment" "basic_abilities" {
  count = "${var.bootstrap_objects_bucket == "" ? 0 : 1}"
  role  = "${aws_iam_role.basic.name}"

  policy_arn = "${aws_iam_policy.basic_abilities.arn}"
}

data "aws_vpc" "main" {
  id = "${var.vpc}"
}

resource "aws_security_group" "basic" {
  count       = "${var.peered_vpc_cidr == "" ? 1 : 0}"
  name        = "${var.cluster_name}"
  description = "Cluster access"
  vpc_id      = "${data.aws_vpc.main.id}"

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.main.cidr_block}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    "Project" = "${var.project}"
  }
}

resource "aws_security_group" "basic_peering" {
  count       = "${var.peered_vpc_cidr == "" ? 0 : 1}"
  name        = "${var.cluster_name}"
  description = "Cluster access"
  vpc_id      = "${data.aws_vpc.main.id}"

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_vpc.main.cidr_block}"]
  }

  ingress {
    from_port   = "${var.peered_vpc_port_from}"
    to_port     = "${var.peered_vpc_port_to}"
    protocol    = "tcp"
    cidr_blocks = ["${var.peered_vpc_cidr}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    "Project" = "${var.project}"
  }
}

resource "aws_iam_instance_profile" "basic" {
  name = "${var.cluster_name}"
  role = "${aws_iam_role.basic.name}"
}

locals {
  elasticsearch_config_string = <<EOFELASTICSEARCH
# system parameters for ElasticSearch 5 and above
sysctl -w vm.max_map_count=262144
sysctl -w fs.file-max=65536
# make permanent
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
echo "fs.file-max=65536" >> /etc/sysctl.conf
EOFELASTICSEARCH

  elasticsearch_config = "${var.enable_elasticsearch == 1 ? local.elasticsearch_config_string : ""}"

  dockerhub_ecs_config_string = <<EOFECS
echo "Setting up ecs-agent"
aws s3 cp s3://${var.bootstrap_objects_bucket}/${join("", aws_s3_bucket_object.dockerhub_credentials.*.key)} /etc/ecs/ecs.config
EOFECS

  ecs_config_string = <<EOFECS
echo "Setting up ecs-agent"
echo "ECS_CLUSTER=${var.cluster_name}" > /etc/ecs/ecs.config
EOFECS

  ecs_config = "${var.dockerhub_username == "" ? local.ecs_config_string : local.dockerhub_ecs_config_string}"
}

resource "aws_launch_configuration" "basic" {
  name_prefix          = "${var.cluster_name}-"
  image_id             = "${var.ami}"
  instance_type        = "${var.instance_type}"
  iam_instance_profile = "${aws_iam_instance_profile.basic.name}"
  key_name             = "${var.key_name}"

  security_groups = [
    "${var.peered_vpc_cidr == "" ? join("", aws_security_group.basic.*.id) : join("", aws_security_group.basic_peering.*.id)}",
  ]

  user_data = <<EOF
#!/bin/bash

yum update -q -y

# install packages

yum install -q -y jq aws-cli amazon-efs-utils wget

# mount the EFS volume and add to fstab so it mounts at boot

mkdir -p ${var.mount_point_data}

echo "${aws_efs_file_system.data.id}:/ ${var.mount_point_data} efs defaults,_netdev 0 0" >> /etc/fstab

n=0
until [ $n -ge 5 ]
  do
    echo "trying EFS mount in 10 seconds..."
    sleep 10
    mount ${var.mount_point_data}
    if [ $? -eq 0 ]; then
      echo "EFS mounted"
      break
    else
      echo "EFS failed to mount"
      ((n += 1))
    fi
  done

# mount the EBS volume and add to fstab so it mounts at boot

mkdir -p ${var.mount_point_data_ebs}
mkfs -t ext4 /dev/xvdf
mount /dev/xvdf ${var.mount_point_data_ebs}
echo "/dev/xvdf ${var.mount_point_data_ebs} ext4 defaults,nofail" >> /etc/fstab

# make swap
fallocate -l ${var.swap_size_gb}G /swap
mkswap /swap
chmod 0600 /swap
swapon /swap
echo "/swap    swap   swap   defaults  0 0" >> /etc/fstab

${local.elasticsearch_config}

${local.ecs_config}

# restart docker so it can see newly mounted volumes
service docker restart

# daily cleanup for docker
cat > /etc/cron.daily/docker-cleanup.sh <<EOFCAT
#!/bin/sh
docker system prune -a -f
EOFCAT

chmod +x /etc/cron.daily/docker-cleanup.sh
${var.additional_config}
EOF

  root_block_device {
    volume_size           = "${var.root_size}"
    volume_type           = "gp2"
    delete_on_termination = true
  }

  # docker
  ebs_block_device {
    device_name           = "/dev/xvdcz"
    volume_size           = "${var.docker_size}"
    volume_type           = "gp2"
    delete_on_termination = true
  }

  # data-ebs
  ebs_block_device {
    device_name           = "/dev/xvdf"
    volume_size           = "${var.data_ebs_size}"
    volume_type           = "gp2"
    delete_on_termination = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "basic" {
  name                 = "${var.cluster_name}"
  launch_configuration = "${aws_launch_configuration.basic.name}"

  max_size            = "${var.max_size}"
  min_size            = "${var.min_size}"
  vpc_zone_identifier = ["${var.subnets}"]

  default_cooldown = 0

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "${var.project}"
    propagate_at_launch = true
  }

  depends_on = [
    "aws_efs_mount_target.data_mount_target",
  ]
}
