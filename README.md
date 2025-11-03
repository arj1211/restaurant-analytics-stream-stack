# Restaurant Analytics Stream Stack

A real-time analytics platform for restaurant data. The stack generates synthetic restaurant events via a FastAPI service, ingests them in real time with an Apache Airflow DAG using a custom SSE operator, stores raw and normalized data in PostgreSQL, and provides PgAdmin for DB administration. Orchestration is done with Docker Compose, with Makefile and PowerShell helpers for common operations.

## Architecture

```
Restaurant API (SSE) → Airflow (SSE Operator + DAG) → PostgreSQL (raw_data, analytics, staging) → PgAdmin
```

- Restaurant API: synthetic event generator with REST and SSE endpoints
- Airflow: realtime DAG `restaurant_realtime_stream` consumes SSE and writes to Postgres
- PostgreSQL: dedicated databases, roles, schemas, extensions, tables, views, and audit triggers
- PgAdmin: database administration UI

Airflow version: `apache/airflow:2.11.0`. Provider packages are installed at container startup via `_PIP_ADDITIONAL_REQUIREMENTS` for development.

## Services

- Airflow Web UI: http://localhost:8081
- Restaurant API: http://localhost:8000
- PgAdmin: http://localhost:8080

Ports and credentials are controlled via `.env`.

## Repository Structure

```
restaurant-analytics-stream-stack/
├── .env
├── .gitignore
├── docker-compose.yml
├── Makefile
├── stack.ps1
├── docker/
│   └── postgres-init/
│       ├── 10_airflow_init.sh
│       └── 20_restaurant_init.sh
├── data/
│   ├── airflow/
│   │   ├── dags/
│   │   │   └── restaurant_realtime_stream.py
│   │   ├── logs/
│   │   └── plugins/
│   │       └── sse_operator.py
│   ├── pgadmin/
│   └── postgres/
├── restaurant_api/
│   ├── app/
│   │   └── main.py
│   ├── Dockerfile
│   └── requirements.txt
└── README.md
```

Notes:
- The runtime schema is created by the Postgres init scripts under `docker/postgres-init/`.
- Metabase variables exist in `.env` as placeholders but no Metabase service is defined in `docker-compose.yml`.

## Core Components

### Restaurant API (`restaurant_api/app/main.py`)
A synthetic data generator exposing REST and SSE endpoints:
- Endpoints:
  - `/health` — API health with current event store size
  - `/events?since=<offset>&limit=<n>` — pageable events API
  - `/stream` — Server-Sent Events stream (media type `text/event-stream`)
- Event types: `order_created`, `order_item_added`, `payment_captured`, `feedback_submitted`
- Realistic behavior:
  - Time-of-day volume variation and category boosts
  - Locations (`LOC-ON-###`), pricing per category, service type mix
  - Tip rates by service type
- Implementation details:
  - In-memory deque for recent events, async producer continually creates events
  - SSE lines formatted with `id`, `event`, and `data: {json}`

### Airflow
- Services: `airflow-init` (one-shot), `webserver`, `scheduler`
- Airflow DB: connects to `airflow_db` as `airflow_user`
- Initialization (`airflow-init`):
  - Migrates metadata DB
  - Creates admin user
  - Creates connections:
    - `postgres_restaurant` → Postgres service, schema `restaurant_analytics` (user `restaurant_user`)
    - `restaurant_api` → internal API URL (`http://restaurant-api:8000`)
  - Sets variable `restaurant_stream_offset = 0`
- Environment updates (configured in `docker-compose.yml`):
  - `AIRFLOW__CORE__MAX_ACTIVE_TASKS_PER_DAG` (replaces deprecated `DAG_CONCURRENCY`)
  - `AIRFLOW__API__AUTH_BACKENDS` includes `airflow.api.auth.backend.session` along with `basic_auth`

DAGs:
- `data/airflow/dags/restaurant_realtime_stream.py`:
  - Sensor: `SSEStreamSensor` checks API health before streaming
  - Operator: `SSEStreamOperator` consumes SSE, batch-inserts raw events and normalizes into analytics tables
  - Python tasks for data quality checks and system health monitoring
  - Placeholder SQL task to refresh future materialized views
  - Cleanup task to delete raw events older than 7 days

Plugins:
- `data/airflow/plugins/sse_operator.py`:
  - Custom `SSEStreamOperator` with batching, timeout, max events per run
  - Inserts into `raw_data.events_raw` and processes event types into `analytics.*` tables
  - `SSEStreamSensor` to verify endpoint availability
  - Decorator for custom event processors

### PostgreSQL
- Databases:
  - `airflow_db` owned by `airflow_user`
  - `restaurant_analytics` owned by `restaurant_user`
- Roles:
  - `restaurant_user` — write access
  - `analytics_reader` — read-only access
- Schemas: `raw_data`, `analytics`, `staging`
- Extensions: `uuid-ossp`, `pg_stat_statements`, `pg_trgm`
- Utility functions:
  - `analytics.health_check()`
  - `analytics.get_latest_offset()`
  - `analytics.calculate_order_metrics(order_id UUID)`
  - `analytics.validate_data_consistency()`
- Audit:
  - Table: `analytics.audit_log`
  - Trigger function: `analytics.audit_trigger_function` (JSON-safe, derives record_id from NEW/OLD)
  - Triggers on `analytics.orders` and `analytics.payments`
- Tables (partial):
  - `raw_data.events_raw` (JSONB payload, offset, timestamps)
  - `analytics.orders`, `analytics.order_items`, `analytics.payments`, `analytics.feedback`
- Views:
  - `analytics.hourly_sales`, `analytics.daily_sales`, `analytics.menu_performance`, `analytics.satisfaction_summary`

All of the above are created idempotently by:
- `docker/postgres-init/10_airflow_init.sh`
- `docker/postgres-init/20_restaurant_init.sh`

## Quick Start

Prerequisites:
- Docker and Docker Compose
- Python (used by Makefile and PowerShell helpers for cleaning)
- 8GB+ RAM recommended, 10GB+ disk

Configure environment:
- Update `.env` with strong passwords and desired settings

Makefile workflow:
```bash
# Clean local volumes/caches, bring up the stack, then run health checks
make reset

# Show container status
make ps

# Trigger the realtime DAG and show recent runs
make trigger

# Verify row counts in key tables
make verify

# Tail logs for all services
make logs

# Stop the stack
make down

# Fully destroy containers/volumes and clean local data
make destroy
```

PowerShell workflow (Windows):
```powershell
# Run from repo root
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Help
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Reset
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Ps
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Trigger
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Verify
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Logs
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Down
powershell -ExecutionPolicy Bypass -File .\stack.ps1 -Action Destroy
```

Raw Docker commands (if you prefer not to use helpers):
```bash
docker compose up -d
docker compose ps
docker compose logs -f
docker compose down
```

## Configuration

All credentials and settings are controlled via `.env`. Key variables include:
- PostgreSQL: `POSTGRES_SUPERUSER`, `POSTGRES_SUPERUSER_PASSWORD`, `POSTGRES_DEFAULT_DB`
- Airflow metadata DB: `AIRFLOW_DB_NAME`, `AIRFLOW_DB_USER`, `AIRFLOW_DB_PASSWORD`
- Application DB: `RESTAURANT_DB_NAME`, `RESTAURANT_DB_USER`, `RESTAURANT_DB_PASSWORD`
- Read-only user: `ANALYTICS_READONLY_USER`, `ANALYTICS_READONLY_PASSWORD`
- Airflow admin: `AIRFLOW_ADMIN_USER`, `AIRFLOW_ADMIN_PASSWORD`, `AIRFLOW_ADMIN_EMAIL`, `AIRFLOW_ADMIN_FIRSTNAME`, `AIRFLOW_ADMIN_LASTNAME`
- Airflow core: `AIRFLOW_UID`, `AIRFLOW_GID`, `AIRFLOW_FERNET_KEY`
- API internal URL for Airflow: `RESTAURANT_API_URL` (default `http://restaurant-api:8000`)
- Ports: `POSTGRES_EXTERNAL_PORT`, `PGADMIN_EXTERNAL_PORT`, `AIRFLOW_EXTERNAL_PORT`, `RESTAURANT_API_EXTERNAL_PORT`
- Timezone: `TZ` (e.g., `America/Toronto`)
- Development: `API_HOT_RELOAD`, `AIRFLOW_LOAD_EXAMPLES`
- Performance:
  - Airflow: `AIRFLOW_PARALLELISM`, `AIRFLOW_MAX_ACTIVE_RUNS_PER_DAG`
  - Compose reads `AIRFLOW_MAX_ACTIVE_TASKS_PER_DAG` if set; deprecated `AIRFLOW_DAG_CONCURRENCY` is not used by Airflow 2.11
  - PostgreSQL: `POSTGRES_MAX_CONNECTIONS`, `POSTGRES_SHARED_BUFFERS`, `POSTGRES_EFFECTIVE_CACHE_SIZE`

## Data Flow

1. The Restaurant API continuously generates events and exposes them via REST and SSE.
2. The Airflow realtime DAG consumes SSE, inserting into `raw_data.events_raw` and normalizing into `analytics.*` tables.
3. Audit triggers log inserts/updates/deletes to `analytics.audit_log`.
4. Data quality checks confirm consistency (e.g., orphaned items, payment mismatches).
5. Views summarize KPIs for analytics.

## Development & Debugging

Common commands:
```bash
# Container status
docker compose ps

# Logs (service names)
docker compose logs -f webserver
docker compose logs -f scheduler
docker compose logs -f restaurant-api
docker compose logs -f postgres

# Airflow CLI (inside webserver)
docker compose exec webserver airflow dags list
docker compose exec webserver airflow connections list
docker compose exec webserver airflow variables get restaurant_stream_offset

# Database access (inside postgres)
docker compose exec postgres psql -U postgres -d restaurant_analytics
```

Makefile helpers:
```bash
make check   # health checks for API, Airflow config/connections, DBs/roles, pre-ingestion counts
make trigger # trigger the realtime DAG
make verify  # row counts and last ingestion timestamp
```

## Health & Monitoring

Quick diagnostics:
```bash
docker compose ps
docker compose exec -T postgres pg_isready -U postgres
curl -f http://localhost:8000/health
curl -f http://localhost:8081/health
```

Database queries:
```sql
SELECT analytics.health_check();

SELECT
    date_trunc('minute', ingested_at) AS minute,
    COUNT(*) AS events_per_minute
FROM raw_data.events_raw
WHERE ingested_at > NOW() - INTERVAL '1 hour'
GROUP BY date_trunc('minute', ingested_at)
ORDER BY minute DESC;

SELECT analytics.validate_data_consistency();
```

## Troubleshooting

This section consolidates diagnostics, common issues, advanced deep dives, and recovery procedures.

### Quick Diagnostics

Check overall status:
```bash
# Check all services
docker compose ps

# Check service health
docker compose exec -T postgres pg_isready -U postgres
curl -f http://localhost:8000/health
curl -f http://localhost:8081/health
```

View logs:
```bash
# All services
docker compose logs

# Specific service
docker compose logs -f postgres
docker compose logs -f scheduler
docker compose logs -f webserver
docker compose logs -f restaurant-api
```

Makefile shortcuts:
```bash
make ps       # container status
make logs     # tail logs for all services
make check    # API health, Airflow config & connections, DBs & roles, pre-ingestion counts
make trigger  # trigger realtime DAG and show recent runs
make verify   # row counts and last ingestion timestamp
```

### Common Issues

1) Services Won't Start
- Symptoms: compose up fails; services "Exited" or "Restarting"
- Solutions:
```bash
docker version               # verify Docker daemon
docker system prune -f       # clean unused resources
docker compose down -v
docker compose up -d
```
On Windows, ensure Docker Desktop is running and WSL2 integration is enabled.

2) Database Connection Errors
- Symptoms: "Connection refused", "Role does not exist", Airflow can't connect
- Solutions:
```bash
docker compose exec postgres psql -U postgres -c "\du"
docker compose exec postgres psql -U postgres -c "\l"
docker compose logs postgres
```
Airflow connects to `airflow_db` as `airflow_user`. Application DB is `restaurant_analytics` owned by `restaurant_user`.

3) Airflow Issues
- Symptoms: UI not loading, DAGs not appearing, task connection errors
- Solutions:
```bash
docker compose logs airflow-init
docker compose restart webserver scheduler
ls -la data/airflow/dags/
docker compose exec webserver airflow connections list
docker compose exec webserver airflow variables get restaurant_stream_offset
```

4) No Data Flowing
- Symptoms: No events in DB; empty dashboards; API returning no events
- Solutions:
```bash
curl http://localhost:8000/events
curl -H "Accept: text/event-stream" http://localhost:8000/stream
docker compose exec webserver airflow variables get restaurant_stream_offset
docker compose exec postgres psql -U postgres -d restaurant_analytics -c "SELECT COUNT(*) FROM raw_data.events_raw;"
docker compose exec webserver airflow variables set restaurant_stream_offset 0
```

5) PgAdmin Issues
- Symptoms: Can't log in or add server
- Solutions:
```bash
# Check credentials
grep PGADMIN .env

# Add server in PgAdmin:
# Name: Restaurant Analytics
# Host: postgres
# Port: 5432
# Username: see .env (restaurant_user, analytics_reader, or postgres)
# Password: see .env
```

6) Performance Issues
- Symptoms: Slow queries; high memory; crashes
- Solutions:
```bash
docker stats
# PostgreSQL tuning
POSTGRES_MAX_CONNECTIONS=100
POSTGRES_SHARED_BUFFERS=256MB
POSTGRES_EFFECTIVE_CACHE_SIZE=1GB

docker compose down && docker compose up -d
```
Airflow performance tuning:
- `AIRFLOW_PARALLELISM`
- `AIRFLOW__CORE__MAX_ACTIVE_TASKS_PER_DAG`
- `AIRFLOW__CORE__MAX_ACTIVE_RUNS_PER_DAG`

### Advanced Troubleshooting

Database deep dive:
```bash
docker compose exec postgres psql -U postgres

-- Database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;

-- Table sizes
\c restaurant_analytics
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
FROM pg_tables
WHERE schemaname IN ('analytics', 'raw_data');

-- Recent activity
SELECT * FROM raw_data.events_raw ORDER BY ingested_at DESC LIMIT 10;
```

Airflow deep dive:
```bash
docker compose exec webserver airflow dags show restaurant_realtime_stream
docker compose exec webserver airflow tasks list restaurant_realtime_stream
docker compose exec webserver airflow connections test postgres_restaurant
```

Network checks:
```bash
docker network ls
docker network inspect restaurant-analytics-stream-stack_default
docker compose exec webserver ping -c 1 postgres || true
docker compose exec webserver curl -s http://restaurant-api:8000/health
```

### Health Monitoring

Optional health check script:
```bash
#!/bin/bash
set -e

echo "=== Health Check Report ==="
echo "Timestamp: $(date)"
echo

# Service status
echo "--- Service Status ---"
docker compose ps

# API Health
echo -e "\n--- API Health ---"
curl -s http://localhost:8000/health || echo "API not responding"

# Database connectivity
echo -e "\n--- Database Health ---"
docker compose exec -T postgres pg_isready -U postgres && echo "PostgreSQL: OK" || echo "PostgreSQL: FAILED"

# Recent events count
echo -e "\n--- Data Flow ---"
EVENTS=$(docker compose exec -T postgres psql -U postgres -d restaurant_analytics -t -c "SELECT COUNT(*) FROM raw_data.events_raw WHERE ingested_at > NOW() - INTERVAL '5 minutes';" | tr -d ' ')
echo "Recent events (5 min): $EVENTS"

# Airflow status
echo -e "\n--- Airflow Status ---"
curl -s http://localhost:8081/health || echo "Airflow not responding"

echo -e "\n=== End Health Check ==="
```

Monitoring queries:
```sql
-- Ingestion rate (last hour)
SELECT
    date_trunc('minute', ingested_at) as minute,
    COUNT(*) as events_per_minute
FROM raw_data.events_raw
WHERE ingested_at > NOW() - INTERVAL '1 hour'
GROUP BY date_trunc('minute', ingested_at)
ORDER BY minute DESC;

-- Data quality
SELECT analytics.validate_data_consistency();

-- System health
SELECT analytics.health_check();
```

### Recovery Procedures

Complete reset:
```bash
make destroy
make reset
```

Partial reset:
```bash
# Reset just the database
docker compose stop postgres
docker compose up -d postgres

# Reset Airflow metadata
docker compose stop webserver scheduler
docker compose up -d webserver scheduler
```

Data-only reset:
```bash
docker compose exec postgres psql -U postgres -d restaurant_analytics -c "TRUNCATE TABLE raw_data.events_raw CASCADE;"
docker compose exec webserver airflow variables set restaurant_stream_offset 0
```

### Getting Help

Log collection:
```bash
mkdir -p troubleshooting-logs
docker compose logs > troubleshooting-logs/all-services.log
docker compose logs postgres > troubleshooting-logs/postgres.log
docker compose logs scheduler > troubleshooting-logs/airflow-scheduler.log
docker compose logs webserver > troubleshooting-logs/airflow-webserver.log
docker compose logs restaurant-api > troubleshooting-logs/api.log

docker version > troubleshooting-logs/docker-version.txt
docker compose version > troubleshooting-logs/compose-version.txt
```

Support checklist:
1. Environment information: OS/version, Docker/Compose versions, RAM/disk
2. Error details: exact messages, steps to reproduce, when it started
3. Configuration: changes in `.env`, `docker-compose.yml`, network/firewall
4. Logs: relevant service logs, browser console errors, DB error logs

### Common Solutions Summary

| Issue | Quick Fix |
|-------|-----------|
| Port conflicts | Change ports in `.env` |
| Permissions | Ensure file and directory permissions under `data/` |
| Out of disk | `docker system prune -f` |
| Connection refused | `docker compose restart` |
| Missing data | Check offset, trigger DAG, verify API health |
| Slow performance | Reduce batch sizes, tune PostgreSQL |
| Memory issues | Increase Docker Desktop memory limit |

## Production Notes

- For production, bake provider dependencies into a custom Airflow image rather than using `_PIP_ADDITIONAL_REQUIREMENTS` at startup.
- Change all default passwords and consider secret management (Docker secrets, external KMS).
- Set appropriate Airflow task limits and scheduler params for workloads.
- Ensure Docker Desktop resource limits (CPU/RAM) are sufficient.

## Contributing

- Open issues and PRs with clear descriptions
- Update documentation alongside code changes
- Follow Python best practices and document DAG/operators

## License

MIT
