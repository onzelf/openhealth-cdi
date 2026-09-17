# adopts the account's existing default vpc/subnet into terraform, rather
# than creating a new one. matches "normal ec2 networking" from the l0 spec -
# no custom network design needed at this stage.

resource "aws_default_vpc" "main" {
  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# only one subnet is needed for a single-host l0 deployment. the other 3
# default subnets (b/c/d) stay in aws, untouched and unmanaged by this module.
resource "aws_default_subnet" "main" {
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${var.project_name}-subnet-a"
  }
}
