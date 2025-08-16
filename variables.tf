variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "subnet_id" {
  description = "Subnet ID where the OpenVPN server will reside"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "openvpn_users" {
  description = "List of OpenVPN users to create"
  type        = list(string)
  default     = ["user1", "user2"]
}

variable "routes" {
  description = "List of routes to push to VPN clients"
  type        = list(string)
  default     = ["10.0.0.0/16", "192.168.1.0/24"]
}

variable "key_name" {
  description = "Name of the existing AWS key pair for SSH access"
  type        = string
}
