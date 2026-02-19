# PostgreSQL 18 Streaming Replication with repmgr & Witness on Debian 13

> **3-node Docker setup — Configuration guide**

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Building and Starting the Containers](#3-building-and-starting-the-containers)
4. [Configuring Replication with repmgr](#4-configuring-replication-with-repmgr)
5. [Generated Configuration Files](#5-generated-configuration-files)
6. [Verifying the Cluster](#6-verifying-the-cluster)
7. [Common Operations](#7-common-operations)
8. [Known Issues and Limitations](#8-known-issues-and-limitations)
9. [Quick Command Reference](#9-quick-command-reference)

---

## 1. Overview

This guide describes the setup of PostgreSQL 18 streaming replication with automatic failover, orchestrated by **repmgr**, across three Debian 13 Docker containers.

### Architecture

| Node | Hostname | Role | Exposed Ports |
|------|----------|------|---------------|
| postgresql1 | postgresql1 | **Primary** | 5440:5432 / 2240:22 |
| postgresql2 | postgresql2 | **Standby** | 5441:5432 / 2241:22 |
| postgresql3 | postgresql3 | **Witness** | 5442:5432 / 2242:22 |

- **Primary** — master instance accepting all writes.
- **Standby** — read-only replica, ready to take over if the primary fails.
- **Witness** — lightweight node that holds no replicated data; its sole purpose is to act as a tie-breaker in repmgr failover votes to prevent split-brain.

> **Note:** The witness does not host any replicated PostgreSQL data. It runs a local PostgreSQL instance only to store repmgr metadata.

### Project Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Debian 13 base image — copies init scripts into `/scripts/` |
| `docker-compose.yml` | Defines the 3 services, shared volumes, network, and password secret |
| `init-pg.sh` | Runs automatically on container start: installs PG 18 + repmgr, configures SSH, `postgresql.conf`, `pg_hba.conf`, creates roles |
| `repmgr_standby.sh` | Must be run **manually** in order (primary first, then standby, then witness) to register each node in the repmgr cluster |

---

## 2. Prerequisites

### 2.1 Host Environment

- Docker Engine >= 24 and Docker Compose v2.
- An **external Docker network** named `postgresql_network` must exist before startup:

```bash
docker network create postgresql_network
```

### 2.2 Password File

A plain-text file containing the PostgreSQL password is required and mounted via Docker secrets. The default expected path is:

```
./secrets/postgres_password.txt
```

This password is used for:
- The `postgres` superuser.
- The `repmgr` user (replication and repmgr monitoring).

>  **Never commit this file to Git.** Add the path to your `.gitignore`.


## 3. Building and Starting the Containers

### 3.1 Build the Image

The Docker image is shared by all three nodes:

```bash
docker compose build
```

### 3.2 Start the Containers

On first start, each container automatically runs `init-pg.sh`:

```bash
# Start all nodes in parallel
docker compose up -d

# Follow initialization logs
docker compose logs -f
```

### 3.3 What `init-pg.sh` Does on Each Node

1. Installs **PostgreSQL 18** from the official PGDG repository, along with `repmgr`, `rsync`, `openssh-server`, and required tools.
2. Creates the `18/main` cluster if it does not exist.
3. Loads the password from the Docker secret file and writes `/var/lib/postgresql/.pgpass` for the `postgres` and `repuser` accounts.
4. Generates a **4096-bit RSA SSH key pair** for the `postgres` user and deposits the public key in the shared volume `/shared-keys/`.
5. Updates `postgresql.conf`: `shared_buffers`, `max_wal_size`, `min_wal_size`, `wal_log_hints`, `listen_addresses = '*'`.
6. Adds the Docker network range (`172.0.0.0/8`) to `pg_hba.conf`.
7. Sets the password for the `postgres` superuser.
8. Restarts PostgreSQL and tails the log file (keeps the container alive).

> **Note:** After `init-pg.sh`, each node has a working PostgreSQL 18 instance but replication is **not yet configured**. The repmgr step is manual.

---

## 4. Configuring Replication with repmgr

`repmgr_standby.sh` must be run manually in **strict order**:

```
primary → standby → witness
```

> ⚠️ **Order is mandatory.** The standby clones the primary, and the witness registers against the primary. If the primary is not ready, the other two will fail.

---

### 4.1 Step 1 — Primary (postgresql1)

```bash
docker exec -it postgresql1 bash /scripts/repmgr_standby.sh
```

On the primary, the script:

- Updates `postgresql.conf`: `wal_level=replica`, `max_wal_senders=10`, `max_replication_slots=10`, `hot_standby=on`, `archive_mode=on`, `shared_preload_libraries='repmgr'`.
- Adds a replication rule to `pg_hba.conf` for the `172.0.0.0/8` range.
- Restarts PostgreSQL to apply changes.
- Collects all SSH public keys from `/shared-keys/` and appends them to the `postgres` user's `authorized_keys`.
- Writes `/etc/postgresql/18/main/repmgr.conf` with `node_id=1`.
- Creates the `repmgr` role (`LOGIN`, `REPLICATION`) and the `replication` database.
- Registers the primary: `repmgr primary register`.
- Starts the `repmgrd` daemon.

---

### 4.2 Step 2 — Standby (postgresql2)

```bash
docker exec -it postgresql2 bash /scripts/repmgr_standby.sh
```

On the standby, the script:

- Applies the same `postgresql.conf` and `pg_hba.conf` changes as on the primary.
- **Stops PostgreSQL** locally.
- **Deletes the existing PGDATA** directory (`/var/lib/postgresql/18/main`).
- Clones the primary: `repmgr standby clone --fast-checkpoint` from `postgresql1`.
- Starts PostgreSQL and waits for it to be ready.
- Registers the standby: `repmgr standby register`.
- Starts the `repmgrd` daemon.

> **The deletion of the old PGDATA is destructive. Never run this step on the primary by mistake.**

---

### 4.3 Step 3 — Witness (postgresql3)

```bash
docker exec -it postgresql3 bash /scripts/repmgr_standby.sh
```

On the witness, the script:

- Applies the standard `postgresql.conf` and `pg_hba.conf` changes.
- Writes a `repmgr.conf` with `node_id=3`, `priority=0` (excluded from primary elections), and `failover=automatic`.
- Registers the witness against the primary: `repmgr witness register -h postgresql1`.
- Starts the `repmgrd` daemon.

> **Note:** The witness does not clone the primary. PostgreSQL runs on it only to host repmgr metadata.

---

## 5. Generated Configuration Files

### 5.1 `repmgr.conf` — Primary and Standby

```ini
node_id=1                          # 1=primary, 2=standby, 3=witness
node_name=postgresql1
conninfo='host=postgresql1 port=5432 user=repmgr dbname=replication passfile=/var/lib/postgresql/.pgpass'
data_directory='/var/lib/postgresql/18/main'
pg_bindir='/usr/lib/postgresql/18/bin'
use_replication_slots=yes          # persistent replication slots
failover=automatic                 # automatic failover
log_file='/var/log/repmgr/repmgr.log'

# Service management commands
promote_command='repmgr standby promote -f <conf> --log-to-file --verbose'
follow_command='repmgr standby follow -f <conf> --upstream-node-id=%n --wait-upto=%t --log-to-file --verbose'
service_start_command='/usr/bin/pg_ctlcluster 18 main start'
service_stop_command='/usr/bin/pg_ctlcluster 18 main stop'
service_restart_command='/usr/bin/pg_ctlcluster 18 main restart'
service_reload_command='/usr/bin/pg_ctlcluster 18 main reload'
```

### 5.2 `repmgr.conf` — Witness Additional Parameters

```ini
priority=0                         # excludes witness from primary elections
monitoring_history=yes             # stores monitoring metrics history
monitor_interval_secs=2            # metric collection interval
reconnect_attempts=6               # attempts before marking a node as dead
reconnect_interval=10              # seconds between reconnect attempts
```

### 5.3 `.pgpass`

Located at `/var/lib/postgresql/.pgpass`, used by repmgr for passwordless authentication:

```
# Format: hostname:port:database:user:password
*:5432:*:repuser:<password>
*:5432:*:postgres:<password>
postgresql1:5432:replication:repmgr:<password>
postgresql2:5432:replication:repmgr:<password>
postgresql3:5432:replication:repmgr:<password>
```

> ⚠️ This file must have permissions `600` and belong to the `postgres` user, otherwise PostgreSQL and repmgr will silently ignore it.

---

## 6. Verifying the Cluster

### 6.1 Cluster Status

```bash
docker exec -it postgresql1 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf cluster show'
```

Expected output:

```
 ID | Name        | Role    | Status    | Upstream    | Location
----+-------------+---------+-----------+-------------+---------
  1 | postgresql1 | primary | * running |             | default
  2 | postgresql2 | standby |   running | postgresql1 | default
  3 | postgresql3 | witness | * running | postgresql1 | default
```

### 6.2 Replication Status

```bash
# Check WAL senders on the primary
docker exec -it postgresql1 su - postgres -c \
  "psql -c 'SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;'"

# Check WAL receiver on the standby
docker exec -it postgresql2 su - postgres -c \
  "psql -c 'SELECT status, sender_host, received_lsn, replay_lsn FROM pg_stat_wal_receiver;'"
```

### 6.3 SSH Connectivity Between Nodes

repmgr uses SSH for file transfers during clone and switchover operations. Verify passwordless SSH works:

```bash
docker exec -it postgresql1 su - postgres -c 'ssh postgresql2 echo OK'
docker exec -it postgresql1 su - postgres -c 'ssh postgresql3 echo OK'
```

---

## 7. Common Operations

### 7.1 Automatic Failover

When `repmgrd` is running on all nodes, failover is automatic. If the primary becomes unavailable, the standby is promoted after the reconnect window defined in `repmgr.conf` (`reconnect_attempts=6`, `reconnect_interval=10s` → maximum ~60 seconds).

Simulate a primary failure:

```bash
docker stop postgresql1

# Wait ~60 seconds, then check cluster state
docker exec -it postgresql2 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf cluster show'
```

### 7.2 Manual Switchover (Planned Maintenance)

A switchover gracefully transfers the primary role to the standby with no data loss:

```bash
# Run from the intended new primary (postgresql2)
docker exec -it postgresql2 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf standby switchover --siblings-follow'
```

### 7.3 Rejoin a Former Primary After Failover

After a failover, the old primary must be reintegrated as a standby:

```bash
# On the former primary once it's back online
repmgr -h <new_primary> -U repmgr -d replication \
  -f /etc/postgresql/18/main/repmgr.conf standby clone --fast-checkpoint

service postgresql start
repmgr -f /etc/postgresql/18/main/repmgr.conf standby register --force
```

### 7.4 Viewing Logs

```bash
# repmgr daemon logs
docker exec -it postgresql1 tail -f /var/log/repmgr/repmgr.log

# PostgreSQL logs
docker exec -it postgresql1 tail -f /var/log/postgresql/postgresql-18-main.log
```

---

## 8. Known Issues and Limitations

### 8.1 Container Start Order

Docker Compose starts all three containers in parallel. `init-pg.sh` only initializes PostgreSQL and SSH — it does not configure replication. `repmgr_standby.sh` must be run manually in the correct order **after all three containers are up** and all SSH keys have been deposited in `/shared-keys/`.

### 8.2 The `/shared-keys/` Shared Volume

Each node's public SSH key is deposited into the `shared-keys` Docker volume during `init-pg.sh`. The `repmgr_standby.sh` script then reads all keys to populate `authorized_keys`. This assumes all three `init-pg.sh` runs have completed before `repmgr_standby.sh` is launched on the primary.

### 8.3 Witness Conditional Logic Bug in `repmgr_standby.sh`

There is a logic issue in the `repmgr.conf` generation section:

```bash
# Current (always true — WITNESSHOST is always set)
if [ -n "${WITNESSHOST}" ]; then
    # generates config WITHOUT priority=0  ← applied to ALL nodes including witness
```

The condition `if [ -n "${WITNESSHOST}" ]` is **always true** because `WITNESSHOST` is hardcoded at the top of the script. As a result, the witness currently receives the same `repmgr.conf` as the primary/standby, **without** `priority=0`.

**Fix:** Replace the condition with:

```bash
if [ "$HOSTNAME" != "$WITNESSHOST" ]; then
```

> **Verify that the `repmgr.conf` generated on `postgresql3` contains `priority=0`.** If it does not, the witness could be elected as primary during a failover.

### 8.4 Docker Network Range in `pg_hba.conf`

The `pg_hba.conf` rules allow the range `172.0.0.0/8`. This is broader than standard Docker ranges (`172.17.0.0/16`). In production, restrict this to the actual subnet of the `postgresql_network` network.

### 8.5 SSH `StrictHostKeyChecking no`

The SSH config generated for the `postgres` user disables host key verification:

```
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
```

This is acceptable for development but is a security risk in production. Consider pre-populating a `known_hosts` file for production environments.

---

## 9. Quick Command Reference

### First-Time Installation

```bash
# 1. Create the external Docker network
docker network create postgresql_network

# 2. Build and start containers
docker compose build
docker compose up -d

# 3. Wait for initialization to complete (init-pg.sh)
#    Ctrl+C when all 3 nodes show "PostgreSQL 18 prêt"
docker compose logs -f

# 4. Configure replication — PRIMARY first
docker exec -it postgresql1 bash /scripts/repmgr_standby.sh

# 5. Configure replication — STANDBY
docker exec -it postgresql2 bash /scripts/repmgr_standby.sh

# 6. Configure replication — WITNESS last
docker exec -it postgresql3 bash /scripts/repmgr_standby.sh

# 7. Verify cluster state
docker exec -it postgresql1 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf cluster show'
```

### Useful Day-to-Day Commands

```bash
# Cluster status
docker exec -it postgresql1 su - postgres -c \
  'repmgr -f /etc/postgresql/18/main/repmgr.conf cluster show'

# Replication lag
docker exec -it postgresql1 su - postgres -c \
  "psql -c 'SELECT client_addr, state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;'"

# repmgrd status on a node
docker exec -it postgresql1 service repmgrd status

# Start/stop repmgrd
docker exec -it postgresql1 service repmgrd start
docker exec -it postgresql1 service repmgrd stop
```

---

*Documentation generated from `init-pg.sh`, `repmgr_standby.sh`, and `docker-compose.yml` — PostgreSQL 18 + repmgr + Debian 13*