# Look up existing default networking without managing its settings or tags.

data "aws_vpc" "default" {
  default = true
}

# Select the default subnet in the configured region's availability zone a.
data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.aws_region}a"
  default_for_az    = true
}
