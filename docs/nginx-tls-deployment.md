
# Nginx and TLS Deployment

This document describes the deployment and operation of the VoidWar Nginx reverse proxy, including HTTPS, Let's Encrypt certificate renewal, and Grafana access.

Nginx runs in Docker on the OVHcloud bare-metal Ubuntu host and serves as the public HTTP/HTTPS entry point.

For overall infrastructure design, see [Architecture](architecture.md).

## Responsibilities

Nginx provides:

- Public HTTP and HTTPS listeners on ports 80 and 443
- HTTP-to-HTTPS redirects
- A static landing page at `voidwar.net`
- Canonical redirects from `www.voidwar.net`
- HTTPS reverse proxying for `grafana.voidwar.net`
- ACME HTTP challenge handling for certificate renewal

The live deployment directory is `/opt/voidwar/nginx`.

The sanitized repository configuration is maintained under `docker/nginx/`.

## Repository Layout

```text
docker/nginx/
├── .gitignore
├── compose.yaml
├── conf/
│   └── default.conf.example
└── html/
    └── index.html
```

The repository excludes live certificates, private keys, Certbot account data, ACME runtime files, and logs.

## Docker Deployment

The deployment uses the `nginx:1.29-alpine` image and a container named `voidwar-nginx`.

Important Compose settings:

```yaml
restart: unless-stopped
network_mode: host
```

Host networking allows Nginx to bind directly to ports 80 and 443 and reach Grafana at `127.0.0.1:3000`.

No Docker `ports:` mapping is required.

### Bind Mounts

| Host path | Container path | Purpose |
|---|---|---|
| `./html` | `/usr/share/nginx/html` | Static website |
| `./conf/default.conf` | `/etc/nginx/conf.d/default.conf` | Virtual-host configuration |
| `./certbot` | `/var/www/certbot` | ACME challenge files |
| `/etc/letsencrypt` | `/etc/letsencrypt` | TLS certificates |

All four mounts are read-only inside the container.

The repository tracks `conf/default.conf.example`, while the deployed Compose configuration expects `conf/default.conf`.

For a new deployment, copy and review the example:

```bash
cp conf/default.conf.example conf/default.conf
mkdir -p certbot
```

The local configuration file is excluded from Git.

**Important:** The production container already runs from `/opt/voidwar/nginx`. Do not start a second copy from the Git repository on the same host, as it would conflict with the existing container and HTTP/HTTPS listeners.

## HTTP and HTTPS Routing

| Request | Behavior |
|---|---|
| `http://voidwar.net` | Redirect to HTTPS |
| `https://voidwar.net` | Serve static landing page |
| `http://www.voidwar.net` | Redirect to canonical HTTPS hostname |
| `https://www.voidwar.net` | Redirect to `https://voidwar.net` |
| `http://grafana.voidwar.net` | Redirect to HTTPS |
| `https://grafana.voidwar.net` | Reverse proxy to Grafana |

Redirects preserve the original request URI.

The static website is served from `/usr/share/nginx/html`, with its source tracked at `docker/nginx/html/index.html`.

## Grafana Reverse Proxy

Nginx forwards requests for `grafana.voidwar.net` to the local Grafana listener:

```nginx
proxy_pass http://127.0.0.1:3000;
```

Grafana listens on the host's loopback interface rather than a public interface.

The proxy forwards the original request context:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

HTTP/1.1 and connection upgrade headers are also configured for Grafana functionality that requires upgraded connections.

Grafana's configured public root URL is:

```text
https://grafana.voidwar.net
```

## TLS Certificates

Let's Encrypt provides the certificate used by Nginx.

The certificate covers:

- `voidwar.net`
- `www.voidwar.net`
- `grafana.voidwar.net`

Nginx reads the certificate and private key from:

```text
/etc/letsencrypt/live/voidwar.net/fullchain.pem
/etc/letsencrypt/live/voidwar.net/privkey.pem
```

The HTTPS configuration supports TLS 1.2 and TLS 1.3.

Certificate files must exist before starting Nginx with the full HTTPS configuration. Initial issuance may require a temporary HTTP-only configuration or another controlled ACME bootstrap method.

Certificate files and private keys are never committed to the repository.

### Inspect Certificates

```bash
sudo certbot certificates
```

Inspect the certificate metadata directly:

```bash
sudo openssl x509 \
  -in /etc/letsencrypt/live/voidwar.net/fullchain.pem \
  -noout -dates -ext subjectAltName
```

## Automated Certificate Renewal

Certificate renewal is managed by the host's `certbot.timer` systemd unit.

Certbot uses the webroot challenge method with:

```text
/opt/voidwar/nginx/certbot
```

Nginx serves HTTP challenge files through:

```text
/.well-known/acme-challenge/
```

### Renewal Deployment Hook

After successful certificate renewal, Certbot executes:

```text
/etc/letsencrypt/renewal-hooks/deploy/reload-voidwar-nginx.sh
```

The hook validates the running Nginx configuration before reloading it:

```bash
/usr/bin/docker exec voidwar-nginx nginx -t
/usr/bin/docker exec voidwar-nginx nginx -s reload
```

This allows Nginx to begin serving the renewed certificate without replacing the container.

### Verify Renewal Configuration

```bash
sudo systemctl status certbot.timer --no-pager
sudo systemctl list-timers --all | grep certbot
sudo certbot renew --dry-run
```

A successful dry run tests the renewal process without replacing the live certificate. It does not, by default, exercise the deployment hook.

The deployment hook should be checked separately when modified.

## Routine Operations

Run production Compose commands from the live deployment directory:

```bash
cd /opt/voidwar/nginx
```

Check container status and logs:

```bash
sudo docker compose ps
sudo docker logs --tail 100 voidwar-nginx
```

Validate the Compose and Nginx configurations:

```bash
sudo docker compose config -q
sudo docker exec voidwar-nginx nginx -t
```

Reload Nginx after a successful configuration test:

```bash
sudo docker exec voidwar-nginx nginx -s reload
```

For configuration-only changes, a graceful reload is generally preferable to recreating the container.

## Endpoint Validation

Verify HTTP redirects and HTTPS responses:

```bash
curl -I http://voidwar.net
curl -I https://voidwar.net

curl -I http://www.voidwar.net
curl -I https://www.voidwar.net

curl -I http://grafana.voidwar.net
curl -I https://grafana.voidwar.net
```

Expected behavior:

- HTTP requests redirect to HTTPS.
- The primary HTTPS website returns `200 OK`.
- The `www` hostname redirects to the canonical hostname.
- Grafana is reachable through HTTPS and normally redirects unauthenticated requests to `/login`.

Check public listening ports:

```bash
sudo ss -lntp | grep -E ':(80|443)\b'
```

The repository also includes `scripts/verify_infrastructure.sh`, which automates several endpoint, container, TLS, and service-health checks.

## Troubleshooting

### Nginx Fails to Start

Check the container logs, Compose configuration, and host listeners:

```bash
sudo docker logs --tail 100 voidwar-nginx
sudo docker compose config -q
sudo ss -lntp | grep -E ':(80|443)\b'
```

Common causes include missing certificate files, invalid Nginx directives, incorrect bind mounts, file permissions, or port conflicts.

### HTTPS or Certificate Errors

Verify:

- Certificate expiration and subject alternative names
- DNS resolution for the requested hostname
- Port 443 accessibility
- Nginx configuration validity
- Certbot renewal status

Inspect the public endpoint:

```bash
curl -Iv https://voidwar.net
```

### Grafana Proxy Errors

Test the upstream locally:

```bash
curl -I http://127.0.0.1:3000
```

If Grafana does not respond locally, investigate the Grafana container first.

If Grafana responds locally but not through HTTPS, check the Nginx proxy configuration, certificate coverage, DNS, and Nginx logs.

### ACME Renewal Failures

Check:

- `certbot.timer` and Certbot logs
- The configured webroot directory
- HTTP accessibility of the ACME challenge path
- Firewall and DNS settings
- Deployment-hook permissions and behavior

Test renewal with:

```bash
sudo certbot renew --dry-run
```

## Related Documentation

- [Architecture](architecture.md)
- [Monitoring Stack](monitoring-stack.md)
- [Security Hardening](security-hardening.md)
- [Maintenance Runbook](maintenance-runbook.md)

## Summary

VoidWar uses a Dockerized Nginx reverse proxy to provide HTTPS for its public website and Grafana monitoring interface.

The deployment combines host networking, read-only configuration and certificate mounts, automated Let's Encrypt renewal, configuration validation, and graceful reloads.

Production secrets and runtime files remain outside the public Git repository.
