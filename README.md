# smokeping-grafana
Docker compose for smokeping-prober + prometheus + grafana

Added SuperQ's [smokeping_prober](https://github.com/SuperQ/smokeping_prober) to Michael Rodgers' prometheus + grafana [docker-compose](https://gitlab.com/mjrod/py-pg) stack.

This stack does a few pings per second to configured IPv4 destinations and plots the results in a histogram and heatmap.

<img width="1702" alt="image" src="https://github.com/MTN-RowinAndruscavage/smokeping-grafana/assets/8740187/4c00166d-76da-4c7e-aa7c-a5b92f5abf4c">

## Quick Start

1. Copy the example environment file and customize your targets:

```
cp .env.example .env
```

2. Edit `.env` to set your ping targets and other options:
The defaults are for Cloudflare's and Google's DNS GeoIPs, which should be fairly close to whereever you are.

Ping interval for each target could be 1s or more, but defaults to 0.2s prevent modems from going to sleep which can interfere with latency measurements.

```
TARGETS=1.1.1.1 8.8.8.8
PING_INTERVAL=0.2s
GF_ADMIN_PASSWORD=mysecretpassword
```

3. Start the stack:

```
docker compose up -d
```

4. Run the setup container to generate and import the dashboard:

```
docker compose --profile setup run --rm setup
```

The dashboard will be available at [localhost:3000/d/smokeping-dashboard](http://localhost:3000/d/smokeping-dashboard) (default login: `admin` / `password`).

## Updating Targets

When you add or remove ping targets in `.env`:

```
docker compose up -d
docker compose --profile setup run --rm setup --rebuild
```

The `--rebuild` flag saves a timestamped backup of the current dashboard in Grafana before overwriting it with the new configuration.

## Configuration

All user-facing configuration is in `.env` (copy from `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `TARGETS` | `1.1.1.1 8.8.8.8` | Space-separated ping targets (IPs or hostnames) |
| `PING_INTERVAL` | `0.2s` | Interval between pings |
| `GF_ADMIN_PASSWORD` | `password` | Grafana admin password |

The setup script also accepts these environment variables:

| Variable | Default | Description |
|---|---|---|
| `GRAFANA_URL` | `http://localhost:3000` | Grafana base URL (overridden to `http://grafana:3000` when run via Docker) |
| `GRAFANA_USER` | `admin` | Grafana admin username |
| `GRAFANA_PASSWORD` | `password` | Grafana admin password |

## How It Works

- **Datasource provisioning**: The Prometheus datasource is configured via file-based provisioning (`provisioning/datasources/datasource.yml`) with a fixed UID, so no manual setup is needed.
- **Dashboard generation**: `setup.sh` reads ping targets from the `TARGETS` environment variable and uses `jq` to generate the dashboard JSON with 3 panels per target (histogram, heatmap, dropped pings) plus global request/error stats.
- **Dashboard import**: The generated JSON is imported via Grafana's HTTP API and also written to `grafana_smokeping_dashboard.json` to keep the repo file in sync.
- **Containerized setup**: The setup service runs in a Docker container (Alpine with bash, jq, curl), so no host dependencies beyond Docker are needed.

## Dependencies

- Docker and Docker Compose

For host-direct usage (without the setup container), `jq` and `curl` are also required:

```
TARGETS="1.1.1.1 8.8.8.8" ./setup.sh
```

## Limitations

smokeping_prober is configured to only sort the ping results into 0.005 ms buckets, so unfortunately you don't have the original latency data to do additional statistics on.

