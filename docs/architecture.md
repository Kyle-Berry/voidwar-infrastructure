
# VoidWar Infrastructure Architecture

This document describes the architecture of the VoidWar infrastructure environment, including public traffic flow, native Linux workloads, containerized services, monitoring data flow, backup automation, AWS infrastructure, service exposure, persistent storage, and operational design decisions.

VoidWar runs on a dedicated OVHcloud server using Ubuntu Server 22.04 LTS. The Minecraft server operates as a native Linux workload, while Nginx and the monitoring services run in Docker containers managed with Docker Compose.

The environment also integrates Amazon Web Services (AWS) for offsite backup storage. AWS resources are provisioned through Terraform, and retained local backup archives are automatically synchronized to Amazon S3.

## Architecture Overview

The infrastructure consists of a dedicated Linux host running the application, web, monitoring, and backup workloads, with AWS providing offsite backup storage.

```text
                            Public Internet
                                   |
                    +--------------+--------------+
                    |                             |
             Minecraft Clients              HTTP / HTTPS
                    |                         TCP 80 / 443
                    v                             v
          +-------------------+        +---------------------+
          | Minecraft Server  |        |   Nginx Container   |
          | Native Java       |        |   Host Networking   |
          | tmux / start.sh   |        +---------------------+
          +-------------------+          |                 |
                    |                    |                 |
                    |              Static content     Reverse proxy
                    |               voidwar.net    grafana.voidwar.net
                    |                                      |
                    |                                      v
                    |                           +---------------------+
                    |                           | Grafana Container   |
                    |                           | 127.0.0.1:3000      |
                    |                           +---------------------+
                    |                                      |
                    |                               Queries Prometheus
                    |                                      v
                    |                           +---------------------+
                    |                           | Prometheus Container|
                    |                           | 127.0.0.1:9090      |
                    |                           +---------------------+
                    |                                      |
                    |                                Scrapes metrics
                    |                                      v
                    |                           +---------------------+
                    |                           | Node Exporter       |
                    |                           | 127.0.0.1:9100      |
                    |                           +---------------------+
                    |                                      |
                    +------------------+-------------------+
                                       |
                            OVHcloud Ubuntu Host
                                       |
                              Scheduled Cron Job
                                       |
                                       v
                            +---------------------+
                            | Bash Backup Workflow|
                            | backup_system.sh    |
                            +---------------------+
                                       |
                            Validated tar.gz archives
                                       |
                                       v
                            +---------------------+
                            | Local GFS Backups   |
                            | Daily / Weekly /    |
                            | Monthly             |
                            +---------------------+
                                       |
                                       v
                            +---------------------+
                            | S3 Backup Uploader  |
                            | upload_s3_backups.sh|
                            +---------------------+
                                       |
                            AWS CLI / HTTPS
                            Restricted IAM Identity
                                       |
                                       v
                            +---------------------+
                            | Amazon S3           |
                            | Private Backup      |
                            | Bucket              |
                            | us-east-2           |
                            +---------------------+
```

The monitoring and web services operate independently of the backup synchronization process.

Minecraft clients connect directly to the native Minecraft server rather than through the Nginx web reverse proxy.

The backup workflow runs on the Linux host, and its AWS integration does not require the Minecraft server or monitoring services to run in AWS.

Terraform provisions the AWS backup infrastructure separately from the production server's daily backup operations.

## Deployment Model

The environment combines native Linux service administration, containerized supporting infrastructure, and Terraform-managed cloud resources.

The Minecraft application runs directly on Ubuntu and is managed through shell scripts and a persistent `tmux` session.

The following supporting services run in Docker:

- Nginx
- Prometheus
- Node Exporter
- Grafana

Docker Compose defines each service, its image version, restart policy, networking mode, mounted configuration, persistent storage, and security options.

The live container deployment is organized under:

```text
/opt/voidwar/nginx
/opt/voidwar/monitoring
```

Sanitized source configuration is published in this repository under:

```text
docker/nginx
docker/monitoring
```

The Minecraft server and backup automation are managed directly on the host rather than through Docker Compose.

AWS backup resources are managed using Terraform configuration stored under:

```text
terraform/aws
```

Runtime data, certificate material, credentials, logs, backup archives, Terraform state, and generated application state are intentionally excluded from Git.

## Minecraft Application

VoidWar's Minecraft server runs as a native Java application on the dedicated Ubuntu host.

The production server directory is:

```text
/home/blockboss/minecraft_server
```

The server is started through its existing `start.sh` script and managed using `tmux`.

Running Minecraft directly on the host provides access to standard Linux process management, filesystem permissions, scheduled tasks, and shell-based administration.

Minecraft's runtime data includes:

- World files
- Server configuration
- Plugin configuration and data
- Application logs
- Generated application state

The main Minecraft server directory contains a symbolic link for its plugin directory:

```text
/home/blockboss/minecraft_server/plugins -> /srv/plugins
```

The actual plugin data is stored at:

```text
/srv/plugins
```

This separation is accounted for by the backup and restoration procedures.

The Minecraft server is not containerized, and client traffic does not pass through the Nginx reverse proxy.

## Public Traffic Flow

Nginx is the only containerized web service exposed directly to the public internet.

It listens on:

```text
TCP 80
TCP 443
```

Nginx handles three public hostnames:

```text
voidwar.net
www.voidwar.net
grafana.voidwar.net
```

Requests to `http://voidwar.net` are redirected to:

```text
https://voidwar.net
```

Requests to the `www` hostname are redirected to the canonical non-`www` hostname:

```text
https://voidwar.net
```

The primary `voidwar.net` hostname serves a static HTML page from a read-only bind mount.

Requests to:

```text
https://grafana.voidwar.net
```

are reverse-proxied by Nginx to:

```text
http://127.0.0.1:3000
```

Grafana is therefore publicly reachable only through the Nginx reverse proxy.

## TLS Termination

Nginx terminates TLS for the public web endpoints.

The production certificate is issued by Let's Encrypt and includes the following subject alternative names:

```text
voidwar.net
www.voidwar.net
grafana.voidwar.net
```

The certificate directory is mounted read-only into the Nginx container:

```text
/etc/letsencrypt:/etc/letsencrypt:ro
```

Private keys and live certificate files are never committed to this repository.

The public Nginx configuration references the expected certificate paths but contains no private certificate material.

HTTP requests are redirected to HTTPS, and the configuration permits:

```text
TLSv1.2
TLSv1.3
```

Certificate renewal is automated using `certbot.timer`. After a successful renewal, a deploy hook validates and gracefully reloads Nginx.

## ACME Challenge Handling

Nginx exposes the standard ACME HTTP challenge path:

```text
/.well-known/acme-challenge/
```

Challenge files are served from:

```text
/var/www/certbot
```

The host directory used for ACME challenge files is mounted read-only into the Nginx container.

ACME challenge contents are temporary runtime data and are excluded from Git.

## Nginx Reverse Proxy

Nginx forwards requests for `grafana.voidwar.net` to the Grafana service over the host loopback interface.

The reverse proxy forwards the original request context using headers including:

```text
Host
X-Real-IP
X-Forwarded-For
X-Forwarded-Proto
```

HTTP/1.1 and upgrade headers are also configured to support Grafana features that may use upgraded connections.

Grafana is not exposed directly on a public interface.

## Monitoring Data Flow

The monitoring stack follows this data path:

```text
Node Exporter -> Prometheus -> Grafana
```

Node Exporter collects host-level Linux metrics.

Prometheus scrapes Node Exporter every 15 seconds and stores the resulting time-series data.

Grafana queries Prometheus and visualizes the collected metrics.

Prometheus also scrapes its own metrics endpoint for self-monitoring.

## Node Exporter

Node Exporter runs in a Docker container with:

```text
network_mode: host
pid: host
```

The host root filesystem is mounted into the container as:

```text
/:/host:ro,rslave
```

Node Exporter is started with:

```text
--path.rootfs=/host
```

This allows the containerized exporter to report metrics for the host system rather than only the container filesystem.

The mount is read-only, and the container uses:

```text
no-new-privileges:true
```

Node Exporter listens only on:

```text
127.0.0.1:9100
```

This prevents direct public access to the metrics endpoint. Prometheus accesses it locally over the loopback interface.

## Prometheus

Prometheus runs with host networking and listens only on:

```text
127.0.0.1:9090
```

Its current scrape configuration includes:

```text
127.0.0.1:9090
127.0.0.1:9100
```

These targets represent:

- Prometheus self-monitoring
- Node Exporter host metrics

The global scrape and evaluation intervals are both configured for 15 seconds.

Prometheus retains time-series data for:

```text
30 days
```

Persistent Prometheus data is stored in a Docker-managed named volume.

The Prometheus configuration file is mounted read-only into the container.

The Prometheus web interface and API are not exposed publicly.

## Grafana

Grafana runs with host networking and listens only on:

```text
127.0.0.1:3000
```

Its configured public root URL is:

```text
https://grafana.voidwar.net
```

The service is reachable externally only through Nginx.

Grafana uses a bind-mounted data directory for persistent runtime state. This directory contains generated data such as:

- Grafana's SQLite database
- Installed plugins
- User and dashboard state
- Application-generated files

This runtime directory is excluded from Git.

Grafana provisioning files are mounted read-only.

The Prometheus data source is provisioned automatically with:

```text
http://127.0.0.1:9090
```

as its URL.

The public Compose example requires a Grafana administrator password to be supplied through an ignored `.env` file before initial deployment.

The live Grafana instance uses the community-maintained Node Exporter Full dashboard to visualize system metrics. The dashboard itself is not represented as original work created by this project.

## Host Networking

The Nginx and monitoring containers use Docker host networking.

This design was selected because the services all run on a single dedicated Linux host and communicate through explicit loopback bindings.

Host networking allows:

- Nginx to proxy directly to `127.0.0.1:3000`
- Grafana to access Prometheus at `127.0.0.1:9090`
- Prometheus to scrape Node Exporter at `127.0.0.1:9100`
- Nginx to listen directly on the host's ports 80 and 443

This avoids Docker bridge-address discovery and the earlier unreliable use of `host.docker.internal`.

The tradeoff is that host-networked containers do not receive network isolation from a Docker bridge network. For that reason, each internal service explicitly binds to the loopback interface.

The security boundary is created through both service-level binding and the host firewall.

## Service Exposure

The intended containerized service exposure is:

| Service | Listening address | Publicly reachable |
|---|---|---|
| Nginx HTTP | `0.0.0.0:80` | Yes |
| Nginx HTTPS | `0.0.0.0:443` | Yes |
| Grafana | `127.0.0.1:3000` | Only through Nginx |
| Prometheus | `127.0.0.1:9090` | No |
| Node Exporter | `127.0.0.1:9100` | No |

Only Nginx requires public firewall rules for the web stack.

Ports 3000, 9090, and 9100 do not require public UFW allow rules.

Minecraft client traffic and SSH administration are separate from the containerized web service exposure described above.

The AWS S3 integration uses outbound HTTPS requests from the production server. It does not require opening additional inbound firewall ports.

## Container Security Controls

The containerized services use several baseline controls:

- Explicit container image versions
- `restart: unless-stopped`
- Read-only configuration mounts
- Read-only certificate mounts
- Read-only host filesystem mount for Node Exporter
- Loopback-only internal services
- `no-new-privileges:true`
- Credentials supplied outside source control
- Runtime data excluded from Git

Image versions are pinned rather than using floating `latest` tags.

## Persistence

Prometheus stores metrics in a Docker named volume:

```text
monitoring_prometheus-data
```

Grafana stores runtime state in a host bind-mounted directory:

```text
/opt/voidwar/monitoring/grafana/data
```

Nginx configuration and static content are stored as host files and mounted read-only.

Minecraft world data, application configuration, and plugin files are stored directly on the Linux host.

Local Minecraft backup archives are stored separately from the live application directory under:

```text
/home/blockboss/backups
```

Offsite copies of retained archives are stored in Amazon S3.

The repository contains source configuration and deployment examples, not live runtime data.

## Service Lifecycle

Each container uses:

```text
restart: unless-stopped
```

This allows Docker to restart the services after daemon restarts or host reboots unless an administrator deliberately stopped them.

Docker Compose is used to create, recreate, stop, inspect, and validate the service stacks.

The Nginx and monitoring stacks are maintained separately:

```text
docker/nginx
docker/monitoring
```

This separation allows the public reverse proxy and the internal observability services to be managed independently.

The native Minecraft application has its own startup and administration workflow.

The scheduled backup script preserves the Minecraft server's original runtime state. If the server was running before a backup, the script restarts it after archive creation. If the server was stopped, the backup does not start it.

## Backup Architecture

The backup system combines local archive creation, Grandfather-Father-Son (GFS) retention, and offsite synchronization to AWS S3.

The main scripts are:

```text
scripts/backup_system.sh
scripts/upload_s3_backups.sh
```

The production backup workflow runs through a scheduled cron job.

Its primary responsibilities are:

1. Detect the Minecraft server's runtime state.
2. Gracefully stop the server if it is running.
3. Wait for the original Java process to exit.
4. Create a compressed archive containing the Minecraft server files and external plugin data.
5. Restore the original Minecraft runtime state.
6. Validate and finalize the archive.
7. Promote backups into local GFS retention tiers when applicable.
8. Enforce local retention limits.
9. Synchronize retained archives to Amazon S3.

The backup workflow is executed on the OVHcloud host. AWS is used as an offsite storage destination rather than as the compute environment for Minecraft.

### Local Backup Storage

Validated backup archives are organized into three directories:

```text
/home/blockboss/backups/daily
/home/blockboss/backups/weekly
/home/blockboss/backups/monthly
```

The local GFS retention policy is:

| Tier | Retention |
|---|---|
| Daily | 7 backups |
| Weekly | 4 backups |
| Monthly | 6 backups |

Weekly and monthly archives are promoted from validated daily backups according to the scheduled retention rules.

The local backup system maintains a limited set of recovery points without allowing archive storage to grow indefinitely.

### External Plugin Data

The Minecraft server's `plugins` directory is a symbolic link to `/srv/plugins`.

The backup script includes both the Minecraft server directory and the actual external plugin directory:

```bash
tar -czf "$DAILY_TEMP_PATH" \
    -C "$TARGET_DIR" . \
    -C / srv/plugins
```

This preserves the symbolic link in the Minecraft server directory while also archiving the underlying plugin files.

The corresponding restore procedure stages the archive and restores both locations.

Older archives created before this correction may contain the symbolic link without the external plugin data.

### Backup Validation and Runtime State

The workflow creates a temporary compressed archive while Minecraft is stopped.

The server is returned to its original runtime state before archive validation and finalization.

Archives are checked using `tar` before being promoted into the local retention tiers.

A successful archive validation confirms that the compressed archive can be read, but it does not replace a full application restoration test.

The backup workflow uses process-aware waiting, concurrency protection, and cancellation handling to reduce the risk of overlapping operations or leaving the Minecraft server unintentionally stopped.

## AWS S3 Offsite Storage

Amazon S3 provides offsite copies of locally retained Minecraft backup archives.

The backup bucket is deployed in:

```text
AWS Region: us-east-2
```

The S3 bucket is:

```text
voidwar-backups-9b494ddeae3a351192595c038d
```

Backup objects are organized under:

```text
backups/
├── daily/
├── weekly/
└── monthly/
```

Each prefix corresponds to a local GFS retention tier.

Backup archives retain their date-based filenames:

```text
mcserver-YYYY-MM-DD.tar.gz
```

The S3 bucket is configured with:

- Block Public Access enabled
- SSE-S3 encryption using AES-256
- Bucket versioning
- Bucket-owner-enforced object ownership
- Lifecycle rules for object expiration and cleanup

These settings are managed through Terraform.

### S3 Synchronization

The production server invokes the AWS CLI through:

```text
upload_s3_backups.sh
```

The uploader synchronizes retained local archives into the corresponding S3 prefixes.

The synchronization process:

- Examines retained daily, weekly, and monthly archives.
- Checks whether the corresponding S3 object exists.
- Skips objects that already exist with the same key and size.
- Uploads objects that are missing or have a different size.
- Reports failures through script exit status and logs.

The object-size comparison is an upload optimization, not a cryptographic integrity check.

The uploader does not delete remote objects when their local counterparts are pruned. S3 lifecycle policies handle remote retention independently.

Because the uploader checks all locally retained archives on subsequent runs, a failed or interrupted synchronization can be retried automatically during the next scheduled execution.

If synchronization fails, previously validated local backup archives remain available.

### AWS IAM Access Model

The production server uses a dedicated IAM user:

```text
voidwar-backup-uploader
```

Its permissions are restricted to the backup bucket and the `backups/` prefix.

The uploader is granted the S3 permissions needed to list and upload backup objects, including supported multipart upload operations.

It does not have permission to:

- Download backup objects with `s3:GetObject`
- Delete backup objects with `s3:DeleteObject`
- Modify S3 bucket configuration
- Administer AWS infrastructure

This separates the production server's upload responsibilities from administrative and disaster recovery operations.

AWS credentials are stored outside the Git repository.

Downloading backups for restoration requires a separate authorized AWS administrator or recovery identity.

### S3 Lifecycle Retention

S3 uses time-based lifecycle rules rather than the local count-based GFS policy.

The configured lifecycle settings are:

| Resource | Lifecycle setting |
|---|---|
| Current daily objects | Expire after 8 days |
| Current weekly objects | Expire after 35 days |
| Current monthly objects | Expire after 190 days |
| Noncurrent object versions | Expire after 7 days |
| Incomplete multipart uploads | Abort after 7 days |

Lifecycle expiration is based on object age in S3.

The local backup script does not require S3 object-deletion permissions to maintain this policy.

S3 versioning can preserve previous object versions after an overwrite, subject to the configured lifecycle rules.

## Terraform Infrastructure Management

The AWS backup infrastructure is defined declaratively using Terraform.

The Terraform configuration is organized under:

```text
terraform/aws/
```

The environment configuration is located at:

```text
terraform/aws/environments/dev
```

Reusable modules include:

```text
terraform/aws/modules/s3-backups
terraform/aws/modules/iam-backup-uploader
```

The `s3-backups` module manages the S3 backup bucket and its associated security and lifecycle settings.

The `iam-backup-uploader` module manages the dedicated IAM identity and permissions required for offsite backup uploads.

Terraform is used to provision and manage AWS infrastructure. It is not invoked by the nightly backup cron job.

The production backup workflow uses the already-provisioned S3 bucket and IAM credentials through the AWS CLI.

Administrative Terraform operations are performed separately from the production server's restricted upload operations.

Terraform state files, provider-generated directories, and sensitive credential material are excluded from the public repository.

## Disaster Recovery Model

The infrastructure provides multiple backup recovery sources:

- **Local GFS archives:** Recent daily, weekly, and monthly recovery points stored on the OVHcloud server.
- **AWS S3 archives:** Offsite copies of retained GFS backups that remain accessible through authorized AWS recovery credentials.
- **Manually downloaded copies:** Additional backup archives occasionally downloaded to a separate Windows workstation.

The Windows copies are manual and are not part of the scheduled S3 synchronization process.

### Recovery From Local Backup Failure

If a Minecraft world, plugin, or configuration problem occurs while the dedicated server remains available, a suitable local GFS archive can be selected for restoration.

Local restoration avoids the need to retrieve an archive from AWS.

### Recovery From Dedicated Server Loss

If the OVHcloud server or its local storage becomes unavailable, an authorized administrator can retrieve a backup archive from S3.

The archive can then be transferred to a replacement Linux environment and restored using the documented recovery procedure.

Because the uploader identity does not have `GetObject` permission, backup retrieval requires a separate AWS recovery identity.

### Recovery Validation

The offsite backup process has been verified through successful automated synchronization and manual retrieval of a backup archive from S3.

A retrieved archive was successfully validated with `tar`, and its contents were inspected to confirm that Minecraft world files and external plugin data were present.

A complete replacement-server restoration, including Minecraft startup and client connectivity, has not yet been performed.

The full restoration procedure is documented in [`restore-procedure.md`](restore-procedure.md).

## Configuration Validation

Nginx configuration can be validated inside the running container with:

```bash
docker exec voidwar-nginx nginx -t
```

Docker Compose files can be rendered and validated with:

```bash
docker compose config
```

Prometheus health can be checked with:

```bash
curl -fsS http://127.0.0.1:9090/-/healthy
```

Grafana health can be checked with:

```bash
curl -fsS http://127.0.0.1:3000/api/health
```

Node Exporter metrics can be checked with:

```bash
curl -fsS http://127.0.0.1:9100/metrics
```

Prometheus target health can be checked through:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/targets
```

Expected Prometheus targets are:

```text
prometheus
node-exporter
```

Both should report:

```text
health: up
```

Listening addresses can be verified with:

```bash
sudo ss -lntp | grep -E ':(3000|9090|9100)\b'
```

The AWS Terraform configuration can be checked using:

```bash
terraform fmt -check -recursive
terraform validate
```

These Terraform commands should be executed from an appropriately initialized Terraform environment.

Backup synchronization can be reviewed through the production backup log:

```bash
tail -100 /home/blockboss/backups/backup.log
```

## Failure Isolation and Troubleshooting

If Grafana is unavailable publicly but responds on `127.0.0.1:3000`, the likely problem is in Nginx, TLS, DNS, or the reverse-proxy configuration.

If Grafana is reachable but displays no metrics, verify:

- The Prometheus data source
- Prometheus health
- Prometheus target status
- The Node Exporter metrics endpoint

If Prometheus reports Node Exporter as down, verify:

- The Node Exporter container is running
- Port 9100 is listening on loopback
- The Prometheus target remains `127.0.0.1:9100`
- The exporter can read the mounted host filesystem
- Container logs contain no startup errors

If Nginx configuration changes fail validation, the existing running configuration should remain in place until the corrected configuration passes `nginx -t`.

If S3 backup synchronization fails, verify:

- The production server has outbound network connectivity.
- The AWS CLI credentials are valid.
- The restricted IAM policy still permits the required upload operations.
- The destination bucket and expected prefixes exist.
- The local backup archives are present and readable.
- The backup log identifies the failed operation.

S3 upload failures do not invalidate previously completed local backups.

Subsequent synchronization runs retry missing or size-mismatched archives that remain within local retention.

## Repository Publication Model

The repository contains sanitized copies of the live configuration and Terraform-managed AWS infrastructure definitions.

It intentionally excludes:

- Let's Encrypt private keys
- Live certificate files
- Grafana databases
- Grafana runtime data
- Installed plugin files
- Prometheus time-series data
- Real `.env` files
- Administrator passwords
- AWS access keys and credential files
- Terraform state and state backups
- Terraform provider-generated directories
- ACME challenge runtime files
- Logs
- Backup archives

The public files are intended to demonstrate and document the implementation. They should be reviewed and adapted before use in another environment.

## Summary

The VoidWar infrastructure combines native Linux application hosting, containerized web and monitoring services, and Terraform-managed AWS backup infrastructure.

Minecraft runs directly on the dedicated Ubuntu server, while Nginx provides the public HTTP/HTTPS entry point and TLS termination layer for the web services.

Grafana, Prometheus, and Node Exporter are containerized but restricted to the host loopback interface. Prometheus collects host metrics from Node Exporter, and Grafana queries Prometheus to visualize those metrics.

Automated Bash scripts coordinate consistent Minecraft backups, local GFS retention, and offsite synchronization to a private Amazon S3 bucket.

Terraform manages the AWS backup resources, including S3 security controls, lifecycle retention, and least-privilege IAM permissions.

The resulting architecture separates application hosting, web traffic handling, observability, backup automation, and offsite disaster recovery into distinct operational responsibilities.
