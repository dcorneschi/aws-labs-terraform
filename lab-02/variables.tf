variable "region" {
  description = "AWS Region for both VPCs"
  type        = string
  default     = "eu-west-1"
}

variable "profile" {
  description = "AWS CLI profile, used by the provider and printed in the output commands. Null uses the normal credential chain (AWS_PROFILE, default profile)"
  type        = string
  default     = null
}

variable "name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "peering-lab"
}

variable "vpc_a_cidr" {
  description = "CIDR block of VPC-A. Must not overlap VPC-B: AWS refuses to peer overlapping VPCs"
  type        = string
  default     = "10.10.0.0/16"
}

variable "vpc_b_cidr" {
  description = "CIDR block of VPC-B. Must not overlap VPC-A"
  type        = string
  default     = "10.20.0.0/16"
}

variable "instance_type" {
  description = "Type of the two test instances"
  type        = string
  default     = "t3.micro"
}
