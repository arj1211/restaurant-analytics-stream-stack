#!/usr/bin/env bash
set -euo pipefail

echo "Initializing Airflow database and user in Postgres..."

# Use env vars provided to the Postgres container:
# POSTGRES_USER and POSTGRES_DB come from POSTGRES_SUPERUSER and POSTGRES_DEFAULT_DB in docker-compose
# AIRFLOW_DB_USER, AIRFLOW_DB_PASSWORD, AIRFLOW_DB_NAME are also passed via docker-compose to the postgres service

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AIRFLOW_DB_USER}') THEN
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', '${AIRFLOW_DB_USER}', '${AIRFLOW_DB_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${AIRFLOW_DB_USER}', '${AIRFLOW_DB_PASSWORD}');
  END IF;
END \$\$ LANGUAGE plpgsql;

SELECT 'Ensuring Airflow metadata database exists' AS step;

-- CREATE DATABASE cannot run inside a transaction/DO block. Use \gexec to conditionally create.
SELECT format('CREATE DATABASE %I OWNER %I', '${AIRFLOW_DB_NAME}', '${AIRFLOW_DB_USER}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${AIRFLOW_DB_NAME}')
\gexec

ALTER DATABASE "${AIRFLOW_DB_NAME}" OWNER TO "${AIRFLOW_DB_USER}";
GRANT ALL PRIVILEGES ON DATABASE "${AIRFLOW_DB_NAME}" TO "${AIRFLOW_DB_USER}";
COMMENT ON DATABASE "${AIRFLOW_DB_NAME}" IS 'Apache Airflow metadata and workflow data';
EOSQL

echo "Airflow database and user initialization script completed."
