terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

# Primary Region: the source instance and its AMI
provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Lab       = var.name
      ManagedBy = "terraform"
    }
  }
}

# Secondary Region: the AMI copy and the restored instance
provider "aws" {
  alias   = "secondary"
  region  = var.secondary_region
  profile = var.profile

  default_tags {
    tags = {
      Lab       = var.name
      ManagedBy = "terraform"
    }
  }
}
