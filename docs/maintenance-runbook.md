
# Maintenance Runbook

This runbook documents routine administration, health verification, maintenance, and troubleshooting procedures for the VoidWar infrastructure.

The environment consists of a remotely administered Ubuntu Server host running a native Paper Minecraft workload, containerized web and monitoring services, automated local backups, and AWS S3 offsite backup storage.

For architectural design and component relationships, see [Architecture](architecture.md). For detailed backup and recovery procedures, see [Backup Workflow](backup-workflow.md) and [Restore Procedure](restore-procedure.md).

## Operational Overview

| Component | Management method |
|---|---|
| Ubuntu host | SSH, systemd, standard Linux utilities |
| Minecraft server | Java, Bash, `tmux` |
| Nginx | Docker Compose |
| Prometheus, Node Exporter, Grafana | Docker Compose |
| TLS certificates | Certbot and systemd timer |
| Local backups | Bash, cron, GFS retention |
| Offsite backups | AWS CLI, Amazon S3 |
| AWS infrastructure | Terraform from administrative workstation |
| Security controls | SSH, UFW, Fail2Ban |

## Infrastructure Health Verification

The repository includes an automated verification script:

```text
scripts/verify_infrastructure.sh
```

Run it from the repository root on the dedicated server:

```bash
cd ~/voidwar-infrastructure
bash scripts/verify_infrastructure.sh
```

The script requires administrative privileges for certain checks and may request `sudo` authentication.

### Automated Checks

The script verifies:

- Docker daemon availability and required container status.
- Nginx configuration validity.
- Grafana database health.
- Prometheus health and scrape targets.
- Node Exporter metrics availability.
- Loopback-only listeners for internal monitoring services.
- Public HTTP/HTTPS endpoints and expected redirects.
- TLS certificate coverage and expiration.
- Certbot timer and deployment-hook availability.
- Fail2Ban SSH jail status.

### Interpreting Results

The script reports passed, warning, and failed checks.

| Exit code | Meaning |
|---|---|
| `0` | Required checks passed; warnings may still be present |
| `1` | One or more infrastructure checks failed |
| `2` | Required dependency or execution prerequisite is missing |

Warnings do not currently produce a nonzero exit code. Review the summary rather than relying exclusively on the exit status.

The script does not currently verify Minecraft process health, backup freshness, S3 synchronization, or Terraform state. These require the additional checks described below.

Investigate failed checks before restarting services or modifying configuration.

## Minecraft Server Management

The Paper Minecraft server runs directly on Ubuntu and uses `tmux` for persistent console access.

### tmux Aliases

The server defines the following shell aliases:

| Alias | Purpose |
|---|---|
| `tms` | Create a new `tmux` session |
| `tma` | Attach to the existing `minecraft` session |
| `tml` | List active `tmux` sessions |

Attach to the Minecraft console:

```bash
tma
```

Detach without stopping the server:

```text
Ctrl+B, then D
```

### Verify Minecraft Process Status

```bash
pgrep -af 'java.*-jar paper-.*\.jar.*nogui'
```

No matching output indicates that the expected Minecraft process is not running.

Inspect available `tmux` sessions:

```bash
tml
```

### Start Minecraft

If Minecraft is stopped, attach to the appropriate `tmux` session:

```bash
tma
```

From the server directory:

```bash
cd /home/blockboss/minecraft_server
./start.sh
```

Confirm that startup completes successfully before considering the service operational.

### Stop Minecraft

Attach to the console:

```bash
tma
```

Issue:

```text
stop
```

Wait for the Java process to exit before performing maintenance.

Avoid terminating the process forcibly unless graceful shutdown has failed and recovery procedures require intervention.

### Restart Minecraft

1. Attach to the Minecraft console.
2. Issue `stop`.
3. Wait for the Java process to exit.
4. Start the server again using `./start.sh`.
5. Verify successful startup and review the application log.

### Review Minecraft Logs

View recent output:

```bash
tail -100 /home/blockboss/minecraft_server/logs/latest.log
```

Follow new log entries:

```bash
tail -f /home/blockboss/minecraft_server/logs/latest.log
```

## Docker and Monitoring Operations

The supporting infrastructure runs in Docker.

The live deployment is organized under:

```text
/opt/voidwar/nginx
/opt/voidwar/monitoring
```

Sanitized configurations are maintained in the repository under `docker/`.

### Check Container Status

```bash
sudo docker ps
```

Inspect all containers, including stopped ones:

```bash
sudo docker ps -a
```

Expected infrastructure containers include:

```text
voidwar-nginx
voidwar-prometheus
voidwar-node-exporter
voidwar-grafana
```

The automated infrastructure verification script checks whether these containers are running.

### Inspect Container Logs

For example:

```bash
sudo docker logs --tail 100 voidwar-nginx
sudo docker logs --tail 100 voidwar-prometheus
sudo docker logs --tail 100 voidwar-grafana
```

Follow logs when investigating an active issue:

```bash
sudo docker logs -f voidwar-nginx
```

### Validate Nginx

```bash
sudo docker exec voidwar-nginx nginx -t
```

If the configuration is valid and a reload is required:

```bash
sudo docker exec voidwar-nginx nginx -s reload
```

Validate configuration before reloading or restarting the service.

### Verify Monitoring Endpoints

Grafana health:

```bash
curl -fsS http://127.0.0.1:3000/api/health
```

Prometheus health:

```bash
curl -fsS http://127.0.0.1:9090/-/healthy
```

Prometheus scrape targets:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/targets
```

Node Exporter metrics:

```bash
curl -fsS http://127.0.0.1:9100/metrics
```

These checks are already included in `verify_infrastructure.sh` and are primarily useful for investigating individual failures.

For deployment details, see [Monitoring Stack](monitoring-stack.md) and [Nginx and TLS Deployment](nginx-tls-deployment.md).

## Backup Operations

VoidWar uses automated local backups with Grandfather-Father-Son (GFS) retention and offsite synchronization to Amazon S3.

The local retention policy maintains:

- 7 daily backups.
- 4 weekly backups.
- 6 monthly backups.

### Verify Backup Scheduling

Inspect the configured cron jobs:

```bash
crontab -l
```

Check the cron service:

```bash
sudo systemctl status cron --no-pager
```

The scheduled workflow runs nightly and records output in:

```text
/home/blockboss/backups/backup.log
```

### Inspect Local Backup Archives

```bash
ls -lh /home/blockboss/backups/daily
ls -lh /home/blockboss/backups/weekly
ls -lh /home/blockboss/backups/monthly
```

List retained archives chronologically:

```bash
find /home/blockboss/backups \
  -type f \
  -name "mcserver-*.tar.gz" \
  -printf "%TY-%Tm-%Td %TH:%TM %p\n" | sort
```

Confirm that the expected recent backup exists and that retention is operating as intended.

### Review Backup Logs

```bash
tail -100 /home/blockboss/backups/backup.log
```

For live observation:

```bash
tail -f /home/blockboss/backups/backup.log
```

Review the log for:

- Graceful Minecraft shutdown and restart.
- Archive creation and validation.
- Local retention operations.
- S3 upload attempts and results.
- Errors, interruptions, or skipped operations.

A successful local backup does not, by itself, confirm successful offsite synchronization.

### Verify Offsite S3 Backups

The backup uploader uses the restricted `voidwar-backup-uploader` AWS CLI profile.

List retained objects in the backup bucket:

```bash
aws s3 ls \
  s3://voidwar-backups-9b494ddeae3a351192595c038d/backups/ \
  --recursive \
  --region us-east-2 \
  --profile voidwar-backup-uploader
```

Compare the most recent S3 objects with locally retained archives and inspect the backup log for errors.

The uploader identity has permissions to upload and list objects, but not download or delete them. Recovery downloads require a separately authorized AWS identity.

### Troubleshoot Failed S3 Uploads

If synchronization fails:

1. Inspect `/home/blockboss/backups/backup.log` for the AWS CLI error.
2. Confirm that the expected local backup archive exists.
3. Verify DNS resolution and outbound HTTPS connectivity.
4. Check the uploader's AWS credentials and permissions.
5. Confirm that the S3 bucket is accessible in `us-east-2`.
6. Retry synchronization after correcting the underlying problem.

To retry all retained backups manually on the dedicated server:

```bash
bash /home/blockboss/upload_s3_backups.sh --sync-all
```

The uploader skips objects whose names and sizes already match, avoiding unnecessary transfers.

After synchronization, verify that the expected objects appear in S3. A successful command alone should not replace independent verification of the backup inventory.

The scheduled backup workflow can retry eligible retained archives during subsequent runs.

### Backup Integrity and Recovery Testing

Backup existence alone does not prove recoverability.

Periodically validate archive integrity and confirm that expected world data, server files, and external plugin data are present.

Recovery testing should use a separately authorized environment and follow the documented restore procedure.

A complete bare-metal disaster-recovery restoration has not yet been performed.

See:

- [Backup Workflow](backup-workflow.md)
- [Restore Procedure](restore-procedure.md)

## TLS Certificate Maintenance

Let's Encrypt certificates are managed through Certbot.

### Check Renewal Timer

```bash
sudo systemctl status certbot.timer --no-pager
```

Inspect recent renewal activity:

```bash
sudo journalctl -u certbot.service -n 50 --no-pager
```

### Inspect Certificate Expiration

```bash
sudo openssl x509 \
  -in /etc/letsencrypt/live/voidwar.net/fullchain.pem \
  -noout -dates
```

### Test Renewal

When appropriate, perform a renewal simulation:

```bash
sudo certbot renew --dry-run
```

The production renewal workflow includes a deployment hook that validates and reloads Nginx after successful renewal.

The automated verification script checks certificate expiration, required hostnames, timer state, and deploy-hook availability. It does not replace review of renewal logs or periodic renewal testing.

## Host Resource Monitoring

### System Uptime and Load

```bash
uptime
```

### Memory Usage

```bash
free -h
```

### Filesystem Usage

```bash
df -h
```

### Directory Sizes

```bash
du -sh /home/blockboss/*
```

Pay particular attention to backup growth and available filesystem capacity.

### Listening Network Services

```bash
sudo ss -lntup
```

Confirm that monitoring backends remain restricted to loopback and that only intended services are exposed.

## Security Administration

### UFW

```bash
sudo ufw status verbose
```

Review firewall changes carefully before applying them to a remote server.

### Fail2Ban

Overall status:

```bash
sudo fail2ban-client status
```

SSH jail:

```bash
sudo fail2ban-client status sshd
```

### SSH Service

```bash
sudo systemctl status ssh --no-pager
```

Inspect the effective SSH daemon configuration:

```bash
sudo sshd -T
```

When changing SSH configuration or firewall rules, keep an existing administrative session open and verify a new connection before disconnecting.

For security configuration details, see [Security Hardening](security-hardening.md).

## System Updates and Reboots

### Review Available Updates

```bash
sudo apt update
apt list --upgradable
```

### Install Updates

During an appropriate maintenance window:

```bash
sudo apt upgrade
```

Review proposed package changes before confirming installation.

### Reboot Procedure

If a reboot is required:

1. Confirm that a recent local backup exists and offsite synchronization has succeeded.
2. Notify connected Minecraft players.
3. Gracefully stop the Minecraft server.
4. Review any outstanding maintenance or backup activity.
5. Reboot the host.

```bash
sudo reboot
```

After reconnecting:

```bash
uname -r
uptime
```

Run the infrastructure verification script:

```bash
cd ~/voidwar-infrastructure
bash scripts/verify_infrastructure.sh
```

Also verify Minecraft process status separately.

Do not assume the Minecraft workload automatically restarts after a host reboot; confirm its actual state and start it through the established procedure if necessary.

## Terraform and AWS Maintenance

AWS backup infrastructure is provisioned using Terraform from an administrative workstation, not from the dedicated server.

Terraform configuration is maintained under:

```text
terraform/aws/environments/dev
terraform/aws/modules/s3-backups
terraform/aws/modules/iam-backup-uploader
```

### Operational Precautions

Before modifying AWS infrastructure:

1. Authenticate using the intended administrative AWS SSO profile.
2. Verify the correct AWS account and region.
3. Confirm access to the correct Terraform state.
4. Review the proposed changes with `terraform plan`.
5. Inspect any changes affecting S3 retention, versioning, IAM permissions, or resource replacement.
6. Apply only reviewed and intentional changes.

Do not run `terraform apply` or `terraform destroy` from an uninitialized or unfamiliar working environment without verifying the existing state and intended resource changes.

The S3 bucket contains recovery data. Destructive infrastructure changes must be treated as potentially affecting disaster-recovery capability.

Terraform is responsible for AWS resource configuration; routine S3 backup uploads are performed separately by the AWS CLI uploader.

## Common Troubleshooting

### Minecraft Fails to Start

- Check the Java process and `tmux` session.
- Review `logs/latest.log`.
- Confirm Java availability and executable permissions on `start.sh`.
- Check filesystem capacity and ownership.
- Inspect recent plugin or configuration changes.

### Web or Monitoring Service Is Unavailable

- Run `verify_infrastructure.sh`.
- Check the affected Docker container's status and logs.
- Validate Nginx configuration if reverse proxying is involved.
- Test the local service endpoint independently of the public endpoint.
- Check listening addresses and firewall rules.
- Review TLS status if HTTPS is failing.

### Disk Space Is Low

- Identify the affected filesystem with `df -h`.
- Inspect large directories and backup retention.
- Review unexpected log or runtime-data growth.
- Confirm whether backup rotation is completing.

Do not manually delete recovery archives or Docker volumes without understanding their retention and recovery implications.

### Local Backup Fails

- Review the backup log.
- Verify available disk space and destination permissions.
- Check whether Minecraft shut down gracefully.
- Inspect archive-creation and validation errors.
- Confirm that the expected service state was restored after the attempt.

### S3 Backup Is Missing

- Confirm the corresponding local archive exists.
- Inspect the uploader log output.
- Check AWS credentials and bucket access.
- Review synchronization and lifecycle-retention behavior.
- Retry synchronization after resolving the underlying issue.
- Confirm that the expected object appears in S3.

### SSH Connection Fails

If an existing session is still open:

- Keep it open.
- Check SSH service status and configuration.
- Review UFW and Fail2Ban.
- Inspect authentication logs.
- Test a second connection before closing the working session.

If all SSH access is lost, use OVHcloud's available management or rescue facilities to investigate and repair the host configuration.

## Related Documentation

- [Project Overview](../README.md)
- [Architecture](architecture.md)
- [Backup Workflow](backup-workflow.md)
- [Restore Procedure](restore-procedure.md)
- [Security Hardening](security-hardening.md)
- [Monitoring Stack](monitoring-stack.md)
- [Nginx and TLS Deployment](nginx-tls-deployment.md)

## Operational Principles

VoidWar maintenance prioritizes controlled changes, service availability, least-privilege access, backup recoverability, and repeatable verification.

Automated checks provide a consistent baseline, while manual procedures address application behavior, backup integrity, cloud synchronization, and recovery scenarios that require additional operational judgment.
