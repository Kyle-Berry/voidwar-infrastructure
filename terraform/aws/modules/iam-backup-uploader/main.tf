data "aws_iam_policy_document" "backup_upload" {
  statement {
    sid    = "AllowBackupUploads"
    effect = "Allow"

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${var.bucket_arn}/backups/*"
    ]
  }
}

resource "aws_iam_user" "backup_uploader" {
  name = "voidwar-backup-uploader"

  tags = {
    Project   = "VoidWar"
    Purpose   = "OffsiteBackupUploads"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_policy" "backup_upload" {
  name        = "voidwar-backup-upload"
  description = "Allows uploading VoidWar backups to the designated S3 prefix"

  policy = data.aws_iam_policy_document.backup_upload.json
}

resource "aws_iam_user_policy_attachment" "backup_upload" {
  user       = aws_iam_user.backup_uploader.name
  policy_arn = aws_iam_policy.backup_upload.arn
}
