# which aws account and region this module talks to.
#
# chris/igor: profile/region come from variables.tf, not hardcoded here -
# same file works against the sandbox now and the permanent/other account later.

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
