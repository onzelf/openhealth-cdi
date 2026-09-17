# reads the account's existing default vpc/subnet - read-only, changes
# nothing in aws. we use existing networking as-is rather than owning or
# tagging it, matching "normal ec2 networking" from the l0 spec.

data "aws_vpc" "default" {
  default = true
}

# only one subnet is needed for a single-host l0 deployment. the other
# default subnets (b/c/d) exist in aws but are never looked up here.
data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.aws_region}a"
  default_for_az    = true
}
