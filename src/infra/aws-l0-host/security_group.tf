# allows ssh in on port 22 from one address only (ssh_allowed_cidr).
# outbound is left unrestricted - a deliberate choice for this l0 bootstrap
# stage; scoping egress down to specific ports is follow-up work.

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

  # dashboard/hub ports are deliberately not opened here - per the l0 spec,
  # they're reached through an ssh tunnel, never exposed directly.

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
