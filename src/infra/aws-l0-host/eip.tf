resource "aws_eip" "l0_host" {
  instance = aws_instance.l0_host.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}

output "public_ip" {
  value       = aws_eip.l0_host.public_ip
  description = "Fixed public IP - stays the same across stop/start, unlike the instance's default public IP"
}
