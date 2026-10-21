variable "region" {
  description = "AWS Region for the lab (use a sandbox account)"
  type        = string
  default     = "eu-west-1"
}

variable "profile" {
  description = "AWS CLI profile (for example an IAM Identity Center profile after aws sso login). Used by the provider and printed in the output commands. Null uses the normal credential chain (AWS_PROFILE, default profile)"
  type        = string
  default     = null
}

variable "name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "asg-lab"
}

variable "instance_types" {
  description = "Instance types the group may use for Spot. Several types in several zones means more Spot pools and fewer interruptions. They are NOT burstable (T) types on purpose: a T instance is throttled to its baseline (10 percent on a t3.micro) once its credits are gone, so the lab could never reach 75 percent CPU"
  type        = list(string)
  default     = ["c5.large", "c5a.large", "c6i.large", "c6a.large"]
}

variable "min_size" {
  description = "Minimum number of instances"
  type        = number
  default     = 1
}

variable "desired_capacity" {
  description = "Instances at creation. Set to 2 to start with two Spot instances. Later changes made by the scaling policy are not reverted"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of instances (the scale-out limit)"
  type        = number
  default     = 2
}

variable "cpu_high_threshold" {
  description = "Average CPU percent of the group that adds an instance"
  type        = number
  default     = 75
}

variable "enable_scale_in" {
  description = "Also create a scale-in policy and alarm (CPU low for 5 minutes removes an instance)"
  type        = bool
  default     = false
}

variable "cpu_low_threshold" {
  description = "Average CPU percent at or below which the group removes an instance (only with enable_scale_in)"
  type        = number
  default     = 25
}

variable "capacity_rebalance" {
  description = "Proactively replace Spot instances that get a rebalance recommendation. Recommended in production, but it can briefly add an extra instance, so it is off for a predictable lab"
  type        = bool
  default     = false
}

variable "create_spot_service_linked_role" {
  description = "Create AWSServiceRoleForEC2Spot. Set to true ONLY if the account has never used Spot, because creating it twice fails"
  type        = bool
  default     = false
}
