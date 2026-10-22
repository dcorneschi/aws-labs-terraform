variable "region" {
  description = "Primary Region: where the source instance runs and its AMI is created"
  type        = string
  default     = "eu-west-1"
}

variable "secondary_region" {
  description = "Secondary Region: where the AMI is copied and the restored instance runs. Must differ from region"
  type        = string
  default     = "eu-central-1"
}

variable "profile" {
  description = "AWS CLI profile, used by both providers and printed in the output commands. Null uses the normal credential chain (AWS_PROFILE, default profile)"
  type        = string
  default     = null
}

variable "name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "ami-lab"
}

variable "instance_type" {
  description = "Type of the source and the restored instance"
  type        = string
  default     = "t3.micro"
}

variable "encrypt_copy" {
  description = "Encrypt the snapshots of the AMI copy with the secondary Region's default EBS key (aws/ebs)"
  type        = bool
  default     = true
}

variable "restore" {
  description = "Launch the restored instance from the copied AMI in the secondary Region. Set false to only create and copy the AMI"
  type        = bool
  default     = true
}
