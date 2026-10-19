output "bucket_arn" {
  description = "ARN of the VoidWar S3 backup bucket"
  value       = aws_s3_bucket.backups.arn
}
