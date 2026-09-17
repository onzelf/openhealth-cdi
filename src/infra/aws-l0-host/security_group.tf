# Allow SSH from one IPv4 address and unrestricted IPv4 outbound traffic
# for the L0 bootstrap.

resource "aws_security_group" "l0_host" {
  name        = "${var.project_name}-ssh-only"
  description = "L0 host: SSH-only inbound from one address, unrestricted outbound"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from a single allowed address"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # Access the dashboard and Hub through an SSH tunnel; no inbound rules
  # for their ports are defined here.

  egress {
    description = "all outbound traffic - deliberately unrestricted for now"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ssh-only"
  }
}
