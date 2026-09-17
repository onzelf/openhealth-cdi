# always resolves to the current Ubuntu 24.04 + NVIDIA driver AMI, rather
# than a hardcoded ID that goes stale as AWS ships updates.
data "aws_ssm_parameter" "gpu_ami" {
  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id"
}

resource "aws_instance" "l0_host" {
  ami                    = data.aws_ssm_parameter.gpu_ami.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.l0_host.id]
  key_name               = var.ssh_key_name
  user_data              = file("${path.module}/bootstrap.sh")

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-host"
  }
}
