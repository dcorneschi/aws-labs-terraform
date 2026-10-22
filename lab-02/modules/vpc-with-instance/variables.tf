variable "name" {
  description = "Prefix for every resource name in this VPC (for example peering-lab-vpc-a)"
  type        = string
}

variable "label" {
  description = "Human-readable label served by the test web page (for example \"VPC-A\")"
  type        = string
}

variable "cidr" {
  description = "CIDR block of this VPC"
  type        = string
}

variable "peer_cidr" {
  description = "CIDR block of the other VPC. The security group allows ping and HTTP from it"
  type        = string
}

variable "instance_type" {
  description = "Type of the test instance"
  type        = string
}
