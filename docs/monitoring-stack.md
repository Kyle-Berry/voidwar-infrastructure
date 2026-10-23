
# Monitoring Stack

This document describes the deployment, configuration, and operation of the VoidWar monitoring stack.

The stack runs through Docker Compose on the OVHcloud bare-metal Ubuntu host and provides visibility into Linux system metrics.

For overall infrastructure design, see [Architecture](architecture.md).

## Components

The monitoring stack consists of three services:

| Component | Purpose |
|---|---|
| Node Exporter | Exposes Linux host metrics |
| Prometheus | Scrapes and stores time-series metrics |
| Grafana | Provides dashboards and visualization |

The live deployment directory is:

`/opt/voidwar/monitoring`

The sanitized configuration is maintained under `docker/monitoring/` in the repository.

## Repository Layout

```text
docker/monitoring/
├── .env.example
├── .gitignore
├── compose.yaml
├── grafana/
│   └── provisioning/
│       └── datasources/
│           └── prometheus.yml
└── prometheus/
    └── prometheus.yml
```

Runtime databases, credentials, and metrics storage are excluded from version control.

## Docker Configuration

The stack uses versioned container images:

| Service | Image |
|---|---|
| Node Exporter | `quay.io/prometheus/node-exporter:v1.12.1` |
| Prometheus | `prom/prometheus:v3.5.2` |
| Grafana | `grafana/grafana-oss:12.1.1` |

All three services use Docker host networking.

### Network Exposure

| Service | Listening address |
|---|---|
| Grafana | `127.0.0.1:3000` |
| Prometheus | `127.0.0.1:9090` |
| Node Exporter | `127.0.0.1:9100` |

The monitoring services bind to loopback rather than public interfaces.

Grafana is accessed externally through the Nginx HTTPS reverse proxy:

`https://grafana.voidwar.net`

Prometheus and Node Exporter are not exposed publicly.

Because host networking shares the host's network namespace, service-level listening addresses are important for restricting access.

## Node Exporter

Node Exporter collects Linux host metrics such as CPU, memory, filesystem, disk I/O, and network activity.

The container uses the host PID namespace and a read-only host filesystem mount.

Relevant Compose settings:

```yaml
network_mode: host
pid: host

command:
  - --path.rootfs=/host
  - --web.listen-address=127.0.0.1:9100

volumes:
  - /:/host:ro,rslave
```

The `--path.rootfs=/host` setting allows Node Exporter to collect host-level metrics from its containerized environment.

The metrics endpoint is available locally at:

`http://127.0.0.1:9100/metrics`

## Prometheus

Prometheus scrapes and stores metrics from Node Exporter and its own monitoring endpoint.

Configuration file:

`docker/monitoring/prometheus/prometheus.yml`

### Collection Settings

| Setting | Value |
|---|---|
| Scrape interval | 15 seconds |
| Data retention | 30 days |
| Listening address | `127.0.0.1:9090` |
| Storage | Docker named volume |

The Prometheus storage volume is named:

`monitoring_prometheus-data`

### Scrape Targets

| Job | Target |
|---|---|
| `prometheus` | `127.0.0.1:9090` |
| `node-exporter` | `127.0.0.1:9100` |

Both targets should report `up` when the services are healthy.

### Configuration Reload

Prometheus runs with `--web.enable-lifecycle`, allowing its configuration to be reloaded without recreating the container.

After updating `prometheus.yml`:

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

Verify target health afterward:

```bash
curl -fsS http://127.0.0.1:9090/api/v1/targets
```

Configuration can also be validated with:

```bash
docker exec voidwar-prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

## Grafana

Grafana provides dashboards for viewing metrics collected by Prometheus.

Its public URL is:

`https://grafana.voidwar.net`

Nginx terminates HTTPS and forwards requests to the local Grafana listener at `127.0.0.1:3000`.

### Data Source Provisioning

The Prometheus data source is provisioned from:

`docker/monitoring/grafana/provisioning/datasources/prometheus.yml`

The configured data source URL is:

`http://127.0.0.1:9090`

Because both services use host networking, Grafana can reach Prometheus through the host loopback interface.

### Persistent Data

Grafana application data is stored under:

`/opt/voidwar/monitoring/grafana/data`

This includes the Grafana database, user accounts, dashboard state, and installed plugins.

The directory is excluded from Git.

### Administrator Credentials

The Compose configuration reads the initial administrator credentials from environment variables:

```yaml
GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER:-admin}
GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?Set GRAFANA_ADMIN_PASSWORD in .env}
```

A local `.env` file supplies the credentials and is excluded from version control.

These variables initialize credentials for a new Grafana database. Changing them later does not necessarily update credentials already stored in an existing database.

## Deployment

The repository contains a sanitized deployment example.

For a new deployment, navigate to:

```bash
cd docker/monitoring
```

Create the local environment file:

```bash
cp .env.example .env
```

Edit `.env` and configure a strong, unique Grafana administrator password.

Validate the Compose configuration:

```bash
docker compose config -q
```

Start the services:

```bash
docker compose up -d
```

**Production note:** The live stack already runs from `/opt/voidwar/monitoring`. Do not start a second copy from the repository on the same host, as this could cause container-name, port, and storage conflicts.

## Routine Operations

Run production Compose commands from the live deployment directory:

```bash
cd /opt/voidwar/monitoring
```

### Check Service Status

```bash
docker compose ps
```

Expected containers:

- `voidwar-node-exporter`
- `voidwar-prometheus`
- `voidwar-grafana`

### Inspect Logs

```bash
docker logs --tail 100 voidwar-node-exporter
docker logs --tail 100 voidwar-prometheus
docker logs --tail 100 voidwar-grafana
```

### Apply Configuration Changes

Validate Compose before applying changes:

```bash
docker compose config -q
```

Recreate an individual service when required:

```bash
docker compose up -d prometheus
```

Or reconcile the full stack:

```bash
docker compose up -d
```

Normal container recreation should preserve persistent data stored in configured volumes and bind mounts.

Avoid `docker compose down -v` unless removal of named volumes and their stored data is intentional.

## Health Verification

### Verify Listening Addresses

```bash
sudo ss -lntp | grep -E ':(3000|9090|9100)\b'
```

All three services should listen on `127.0.0.1`, not public interfaces.

### Node Exporter

```bash
curl -fsS http://127.0.0.1:9100/metrics \
  | sed -n '1,20p'
```

Expected result: Prometheus-formatted metrics.

### Prometheus

```bash
curl -fsS http://127.0.0.1:9090/-/healthy
curl -fsS http://127.0.0.1:9090/api/v1/targets
```

Expected result: Prometheus is healthy, with the `prometheus` and `node-exporter` targets reporting `up`.

### Grafana

```bash
curl -fsS http://127.0.0.1:3000/api/health
curl -I https://grafana.voidwar.net
```

Expected result: Grafana reports a healthy database, and its public HTTPS endpoint normally redirects unauthenticated requests to `/login`.

The repository's `scripts/verify_infrastructure.sh` automates several container, listener, endpoint, and service-health checks.

## Troubleshooting

### Grafana Is Unavailable

First test the local service:

```bash
curl -fsS http://127.0.0.1:3000/api/health
```

If Grafana is healthy locally but unavailable publicly, investigate Nginx, DNS, TLS, and firewall configuration.

See [Nginx and TLS Deployment](nginx-tls-deployment.md).

### Dashboards Show No Metrics

Check Prometheus and its scrape targets:

```bash
curl -fsS http://127.0.0.1:9090/-/healthy
curl -fsS http://127.0.0.1:9090/api/v1/targets
```

Verify that the Grafana data source points to `http://127.0.0.1:9090`.

If Node Exporter is down, inspect its container logs, host mount, and port 9100 listener.

### Prometheus Is Unhealthy

Check the logs and validate the configuration:

```bash
docker logs --tail 100 voidwar-prometheus

docker exec voidwar-prometheus \
  promtool check config /etc/prometheus/prometheus.yml
```

Also verify the configured storage volume and available disk space.

## Repository Hygiene

The public repository excludes:

- Real `.env` files and administrator credentials
- Grafana databases and user sessions
- Prometheus time-series data and write-ahead logs
- API tokens and application secrets
- Generated runtime files

Only sanitized configuration, provisioning definitions, and deployment documentation are tracked.

## Related Documentation

- [Architecture](architecture.md)
- [Nginx and TLS Deployment](nginx-tls-deployment.md)
- [Security Hardening](security-hardening.md)
- [Maintenance Runbook](maintenance-runbook.md)

## Summary

VoidWar uses Node Exporter, Prometheus, and Grafana to monitor Linux host performance through a Docker Compose deployment.

Metrics collection and visualization remain bound to loopback interfaces, while Grafana is accessible externally through the Nginx HTTPS reverse proxy.

The repository preserves the deployment configuration without exposing credentials or persistent monitoring data.
