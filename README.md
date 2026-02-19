# pg18-repmgr-debian13

PostgreSQL 18 streaming replication with automatic failover using **repmgr** and a **witness node**, containerized with Docker on Debian 13.

```
postgresql1 (Primary) ──── streaming replication ────► postgresql2 (Standby)
        │                                                       │
        └──────────────── quorum ───── postgresql3 (Witness) ──┘
```

## Stack

- **PostgreSQL 18** — PGDG official repository
- **repmgr** — replication manager + automatic failover daemon (`repmgrd`)
- **Debian 13** (Trixie) base image
- **Docker Compose** — 3-node setup with shared SSH key volume

## Nodes

| Container | Role | 
|-----------|------|
| postgresql1 | Primary |
| postgresql2 | Standby |
| postgresql3 | Witness |

## Project Structure

```
.
├── Dockerfile                # Debian 13 image with PG 18 + repmgr
├── docker-compose.yml        # 3-node service definitions
├── init-pg.sh                # Auto-run on container start (install + base config)
├── repmgr_standby.sh         # Manual repmgr cluster setup (run in order)
├── secrets/
├── ├── postgres_password.txt # password for postgres & repmgr users
└── volumes/
    ├── postgresql1/
    │   ├── db/               # PGDATA mount
    │   └── conf/             # postgresql.conf, pg_hba.conf mount
    ├── postgresql2/
    │   ├── db/
    │   └── conf/
    └── postgresql3/
        ├── db/
        └── conf/
```

## Getting Started

### 1. Prerequisites

- Docker Engine >= 24 and Docker Compose v2
- A password file for PostgreSQL (used for both `postgres` and `repmgr` users):

```bash
mkdir -p /home/<you>/docker/password
echo "your_strong_password" > /home/<you>/docker/password/postgres_password.txt
```

Update the `secrets` path in `docker-compose.yml` to match.

### 2. Build and start

```bash
docker compose build
docker compose up -d
docker compose logs -f   # wait until all 3 nodes show PostgreSQL is ready
```

### 3. Configure replication (run in strict order)

```bash
# Primary first
docker exec -it postgresql1 bash /scripts/repmgr_standby.sh

# Then standby
docker exec -it postgresql2 bash /scripts/repmgr_standby.sh

# Witness last
docker exec -it postgresql3 bash /scripts/repmgr_standby.sh
```

### 4. Verify

```bash
docker exec -it postgresql1 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf cluster show'
```

Expected output:

```
 ID | Name        | Role    | Status    | Upstream
----+-------------+---------+-----------+------------
  1 | postgresql1 | primary | * running |
  2 | postgresql2 | standby |   running | postgresql1
  3 | postgresql3 | witness | * running | postgresql1
```

## How It Works

**`init-pg.sh`** runs automatically when a container starts. It installs PostgreSQL 18 and repmgr, generates SSH keys (deposited in a shared Docker volume for inter-node access), and applies baseline `postgresql.conf` settings. At the end of this step, each node has a standalone PG instance — no replication yet.

**`repmgr_standby.sh`** must be triggered manually, one node at a time. On the primary it creates the `repmgr` role and `replication` database, then registers the node. On the standby it wipes the local data directory and clones the primary via `repmgr standby clone`. On the witness it registers without cloning. Once all three nodes are registered, `repmgrd` is started on each to enable automatic failover.

## Failover

Automatic failover is handled by `repmgrd`. If the primary becomes unreachable, the standby is promoted after ~60 seconds (`reconnect_attempts=6 × reconnect_interval=10s`). The witness provides the quorum vote to prevent split-brain.

To manually trigger a graceful switchover (zero data loss):

```bash
docker exec -it postgresql2 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf standby switchover --siblings-follow'
```

## Security Notes

> This setup is intended for **development and testing**.

- SSH `StrictHostKeyChecking` is disabled for the `postgres` user.
- `pg_hba.conf` allows `172.0.0.0/8` — broader than a typical Docker subnet.
- The password file is mounted in plaintext via Docker secrets.

Harden all three points before any production use.


## License

MIT
