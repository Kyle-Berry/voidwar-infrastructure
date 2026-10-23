
# Security Hardening

This document describes the security controls used to protect the VoidWar infrastructure environment, hosted on an OVHcloud bare-metal server running Ubuntu Server 22.04 LTS.

The approach emphasizes restricted administrative access, minimal public service exposure, defense in depth, and repeatable verification.

## Security Overview

The environment implements:

- Ed25519 SSH key authentication with root and password login disabled
- UFW default-deny inbound firewall rules
- Fail2Ban protection for SSH authentication
- Non-root administration with `sudo` for privileged operations
- HTTPS for public web services
- Localhost-only monitoring listeners
- Least-privilege AWS IAM access for offsite backups
- Sanitized infrastructure configuration in the public repository

Example configurations are maintained under `config/ssh/`, `config/ufw/`, and `config/fail2ban/`.

## SSH Hardening

SSH provides remote administration through a dedicated non-root account using Ed25519 public-key authentication.

The SSH configuration includes:

- `PermitRootLogin no`
- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- Public-key authentication enabled
- Unnecessary forwarding features restricted where appropriate

The SSH configuration example is located at:

`config/ssh/sshd_config.example`

### Validation

```bash
sudo sshd -t
sudo sshd -T
sudo systemctl status ssh --no-pager
```

Before changing SSH configuration, keep an existing session open and verify that a second session can authenticate successfully.

A nonstandard SSH port may reduce automated scanning noise but is not treated as a substitute for authentication controls.

## UFW Firewall

UFW restricts inbound traffic using a default-deny policy.

The baseline configuration:

- Denies incoming traffic by default
- Allows outgoing traffic by default
- Denies routed traffic by default
- Limits SSH connection attempts
- Permits required Minecraft, HTTP, and HTTPS traffic
- Enables low-volume firewall logging

The public configuration example is located at:

`config/ufw/ufw-rules.example`

### Validation

```bash
sudo ufw status verbose
sudo ufw status numbered
sudo ss -tulpn
```

Firewall rules and service listening addresses must be reviewed together to identify unintended exposure.

## Fail2Ban

Fail2Ban monitors SSH authentication failures and temporarily bans sources that exceed configured thresholds.

The `sshd` jail uses:

| Setting | Configuration |
|---|---|
| Ban duration | 1 hour |
| Detection window | 15 minutes |
| Maximum retries | 3 |
| Log source | systemd journal |
| Exclusions | Loopback addresses |

The active configuration is managed under `/etc/fail2ban/jail.d/`.

The sanitized example is available at:

`config/fail2ban/custom_hardening.local.example`

### Validation

```bash
sudo systemctl status fail2ban --no-pager
sudo fail2ban-client status sshd
sudo journalctl -u fail2ban -n 50 --no-pager
```

Fail2Ban supplements SSH authentication and firewall controls rather than replacing them.

## Service Exposure and Docker Networking

VoidWar exposes only the services needed for remote administration, Minecraft connectivity, and public web access.

| Service | Intended exposure |
|---|---|
| SSH | Public, restricted by authentication and firewall controls |
| Minecraft | Public game traffic |
| Nginx HTTP/HTTPS | Public website and Grafana reverse proxy |
| Grafana | `127.0.0.1:3000`, accessed externally through Nginx |
| Prometheus | `127.0.0.1:9090` |
| Node Exporter | `127.0.0.1:9100` |

The Nginx and monitoring containers use Docker host networking. Because these containers share the host network namespace, explicitly binding internal services to loopback addresses is important.

### Validation

```bash
sudo docker ps
sudo ss -tulpn
```

Monitoring ports should not be directly reachable from the public internet.

## HTTPS and Certificate Management

Nginx provides HTTPS for `voidwar.net`, `www.voidwar.net`, and `grafana.voidwar.net`.

Let's Encrypt certificates are managed through Certbot. A systemd timer handles renewal, and a deployment hook validates and reloads Nginx after successful renewal.

### Validation

```bash
sudo systemctl status certbot.timer --no-pager
sudo certbot certificates
```

See [Nginx and TLS Deployment](nginx-tls-deployment.md) for configuration and renewal procedures.

## AWS Backup Security

Offsite backups are stored in a private AWS S3 bucket provisioned through Terraform.

The backup infrastructure uses:

- S3 Block Public Access
- Server-side encryption with SSE-S3
- Bucket versioning
- Lifecycle expiration policies
- A dedicated IAM uploader identity
- IAM permissions scoped to required bucket listing and object uploads

The uploader does not require S3 object retrieval or deletion permissions.

AWS is used for backup storage; the production workload remains on the OVHcloud host.

See [Backup Workflow](backup-workflow.md) and [Restore Procedure](restore-procedure.md).

## Repository and Credential Hygiene

The public repository contains sanitized configuration examples and infrastructure code, not live credentials or runtime data.

Sensitive materials excluded from version control include:

- SSH private keys and AWS credentials
- Terraform state files
- Application secrets and environment files
- Backup archives and server runtime data

Production-specific ports are omitted from selected public examples. Port secrecy is not considered a primary security control.

## Infrastructure Verification

The repository includes `scripts/verify_infrastructure.sh`, which checks several operational and security-relevant conditions:

- Required Docker containers and service health
- Local-only monitoring listeners
- HTTP redirects and HTTPS endpoint behavior
- TLS certificate expiration and renewal configuration
- Fail2Ban SSH jail status

Run from the repository root:

```bash
cd ~/voidwar-infrastructure
bash scripts/verify_infrastructure.sh
```

This is an infrastructure health check, not a comprehensive security audit. SSH policy, UFW rules, OS updates, and AWS permissions still require separate review.

## Operational Precautions

Before applying security-related changes:

1. Keep an active SSH session open when modifying remote access or firewall rules.
2. Validate configurations before restarting or reloading services.
3. Confirm required ports remain accessible.
4. Review service status and logs after changes.
5. Verify public endpoints and internal listener bindings.
6. Maintain recoverable backups before significant changes.

For routine maintenance and troubleshooting, see [Maintenance Runbook](maintenance-runbook.md).

## Summary

VoidWar uses layered Linux and cloud security controls to reduce unnecessary exposure while maintaining required services.

The security baseline combines hardened SSH access, UFW, Fail2Ban, restricted monitoring endpoints, HTTPS, least-privilege AWS IAM, and repeatable infrastructure checks.
