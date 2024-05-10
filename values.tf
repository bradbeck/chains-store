variable "k8s-config-path" {
  type = string
  default = "~/.kube/config"
}

variable "k8s-config-context" {
  type = string
  default = "colima"
}

variable "v-role-name" {
  type = string
  default = "tekton-role"
}

variable "mongo-pass" {
  type = string
  default = "foo!bar"
}