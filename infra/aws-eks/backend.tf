# Remote state in S3 with native lockfile locking (Terraform >= 1.10).
# Bucket, key and region are supplied at init time so nothing account-specific
# is committed:
#   terraform init -backend-config=backend.hcl
# See backend.hcl.example and docs/github-secrets.md.
terraform {
  backend "s3" {}
}
