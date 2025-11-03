# Restaurant Analytics Stream Stack - Makefile
# Default goal
.DEFAULT_GOAL := help

# Tools
COMPOSE := docker compose
PY := python

# Paths
AIRFLOW_LOGS := data/airflow/logs
PGADMIN_DATA := data/pgadmin
POSTGRES_DATA := data/postgres

help:
	@echo "Available targets:"
	@echo "  make reset        - Clean local volumes and caches, then spin up the stack"
	@echo "  make clean        - Remove Airflow logs, pgadmin data, postgres data, and Python caches"
	@echo "  make up           - docker compose up -d"
	@echo "  make check        - Verify services, DBs/users, connections, and API health"
	@echo "  make trigger      - Trigger the realtime Airflow DAG and show recent runs"
	@echo "  make verify       - Check row counts in key tables"
	@echo "  make ps           - Show container status"
	@echo "  make logs         - Tail logs for all services"
	@echo "  make down         - docker compose down"
	@echo "  make destroy      - docker compose down -v and clean volumes/caches"

reset: clean up check

clean:
	@echo "Cleaning Airflow logs, PgAdmin data, Postgres data, and Python caches ..."
	@$(PY) -c "import pathlib, shutil; \
paths=[pathlib.Path('$(AIRFLOW_LOGS)'), pathlib.Path('$(PGADMIN_DATA)'), pathlib.Path('$(POSTGRES_DATA)')]; \
[ (p.exists() and [ (shutil.rmtree(x) if x.is_dir() else x.unlink(missing_ok=True)) for x in p.iterdir() ]) for p in paths ]; \
[ p.mkdir(parents=True, exist_ok=True) for p in paths ]; \
[ shutil.rmtree(p, ignore_errors=True) for p in pathlib.Path('.').rglob('__pycache__') ]"
	@echo "Clean complete."

up:
	@$(COMPOSE) up -d

ps:
	@$(COMPOSE) ps

logs:
	@$(COMPOSE) logs --tail=200 --follow

check:
	@echo "Checking container status ..."
	@$(COMPOSE) ps
	@echo "Checking Restaurant API health ..."
	@$(COMPOSE) exec webserver bash -lc "curl -s http://restaurant-api:8000/health || true"
	@echo "Checking Airflow SQL Alchemy connection ..."
	@$(COMPOSE) exec webserver bash -lc "airflow config get-value database sql_alchemy_conn || true"
	@echo "Checking Airflow connections ..."
	@$(COMPOSE) exec webserver bash -lc "airflow connections list | grep -E 'postgres_restaurant|restaurant_api' || true"
	@echo "Checking Postgres databases exist (airflow_db, restaurant_analytics) ..."
	@$(COMPOSE) exec postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"SELECT datname FROM pg_database WHERE datname IN ('airflow_db','restaurant_analytics');\"
	@echo "Checking Postgres roles exist (airflow_user, restaurant_user) ..."
	@$(COMPOSE) exec postgres psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"SELECT rolname FROM pg_roles WHERE rolname IN ('airflow_user','restaurant_user');\"
	@echo "Pre-ingestion events_raw count (should be 0 on fresh reset) ..."
	@$(COMPOSE) exec postgres psql -U postgres -d restaurant_analytics -v ON_ERROR_STOP=1 -c \"SELECT COUNT(*) AS events_raw_count FROM raw_data.events_raw;\" || true

trigger:
	@echo "Triggering realtime DAG ..."
	@$(COMPOSE) exec webserver bash -lc "airflow dags trigger restaurant_realtime_stream && sleep 8 && airflow dags list-runs -d restaurant_realtime_stream | tail -n 10"

verify:
	@echo "Verifying row counts in key tables ..."
	@$(COMPOSE) exec postgres psql -U postgres -d restaurant_analytics -v ON_ERROR_STOP=1 -c \"SELECT COUNT(*) AS events_raw_count FROM raw_data.events_raw;\" -c \"SELECT COUNT(*) AS orders_count FROM analytics.orders;\" -c \"SELECT COUNT(*) AS payments_count FROM analytics.payments;\" -c \"SELECT COUNT(*) AS audit_count FROM analytics.audit_log;\" -c \"SELECT MAX(ingested_at) AS last_ingested FROM raw_data.events_raw;\"

down:
	@$(COMPOSE) down

destroy:
	@$(COMPOSE) down -v
	@$(MAKE) clean
	@echo "Stack destroyed and local volumes cleaned."
