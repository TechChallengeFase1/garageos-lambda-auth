terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Empacota o diretorio lambda/ num zip, sem depender de ferramenta externa.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  backend "s3" {
    bucket       = "garageos-tfstate-266380777968"
    key          = "lambda/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = local.env
      ManagedBy   = "terraform"
      Source      = "garageos-lambda-auth"
    }
  }
}

locals {
  env  = terraform.workspace == "default" ? "producao" : terraform.workspace
  name = "${var.project}-${local.env}"
}
