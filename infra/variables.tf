variable "aws_region" {
  description = "AWS region where resources are created"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "credit-risk-platform"
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}
