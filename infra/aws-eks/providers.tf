provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# Auth uses `aws eks get-token` on every call so tokens never expire mid-apply.
# The AWS CLI therefore has to be on PATH (it is on GitHub-hosted runners).
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
