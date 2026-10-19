module "s3_backups" {
  source = "../../modules/s3-backups"
}

module "iam_backup_uploader" {
  source = "../../modules/iam-backup-uploader"

  bucket_arn = module.s3_backups.bucket_arn
}
