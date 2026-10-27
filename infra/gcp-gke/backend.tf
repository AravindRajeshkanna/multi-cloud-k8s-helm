# Remote state in a GCS bucket (object versioning on, native locking).
# Bucket and prefix are supplied at init time:
#   terraform init -backend-config=backend.hcl
# See backend.hcl.example and docs/github-secrets.md.
terraform {
  backend "gcs" {}
}
