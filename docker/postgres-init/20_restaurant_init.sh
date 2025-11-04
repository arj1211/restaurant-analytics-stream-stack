#!/usr/bin/env bash
set -euo pipefail

echo "Initializing restaurant analytics roles, database, schemas, permissions, extensions, and application schema..."

# This script is idempotent. It uses the superuser env from the Postgres container:
# POSTGRES_USER and POSTGRES_DB (mapped from POSTGRES_SUPERUSER and POSTGRES_DEFAULT_DB)
# It also relies on these env vars passed via docker-compose to the postgres service:
# RESTAURANT_DB_NAME, RESTAURANT_DB_USER, RESTAURANT_DB_PASSWORD
# ANALYTICS_READONLY_USER, ANALYTICS_READONLY_PASSWORD
# AIRFLOW_DB_USER (for conditional grants)

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<EOSQL
-- 1) Create/Update required roles (restaurant_user, analytics_reader)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${RESTAURANT_DB_USER}') THEN
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', '${RESTAURANT_DB_USER}', '${RESTAURANT_DB_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${RESTAURANT_DB_USER}', '${RESTAURANT_DB_PASSWORD}');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${ANALYTICS_READONLY_USER}') THEN
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', '${ANALYTICS_READONLY_USER}', '${ANALYTICS_READONLY_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${ANALYTICS_READONLY_USER}', '${ANALYTICS_READONLY_PASSWORD}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

SELECT 'Ensuring restaurant analytics database exists' AS step;

-- 2) Conditionally create the restaurant analytics database (outside transaction)
SELECT format('CREATE DATABASE %I OWNER %I', '${RESTAURANT_DB_NAME}', '${RESTAURANT_DB_USER}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${RESTAURANT_DB_NAME}')
\gexec

ALTER DATABASE "${RESTAURANT_DB_NAME}" OWNER TO "${RESTAURANT_DB_USER}";
COMMENT ON DATABASE "${RESTAURANT_DB_NAME}" IS 'Restaurant analytics application data';

-- 3) Connect to the restaurant analytics database
\c ${RESTAURANT_DB_NAME}

-- 4) Create schemas owned by restaurant_user
CREATE SCHEMA IF NOT EXISTS raw_data AUTHORIZATION "${RESTAURANT_DB_USER}";
CREATE SCHEMA IF NOT EXISTS analytics AUTHORIZATION "${RESTAURANT_DB_USER}";
CREATE SCHEMA IF NOT EXISTS staging AUTHORIZATION "${RESTAURANT_DB_USER}";

COMMENT ON SCHEMA raw_data IS 'Raw event data and streaming ingestion tables';
COMMENT ON SCHEMA analytics IS 'Processed analytics tables and views';
COMMENT ON SCHEMA staging IS 'Temporary staging tables for ETL processes';

-- 5) Schema usage grants
GRANT USAGE ON SCHEMA raw_data TO "${RESTAURANT_DB_USER}";
GRANT USAGE ON SCHEMA analytics TO "${RESTAURANT_DB_USER}";
GRANT USAGE ON SCHEMA staging TO "${RESTAURANT_DB_USER}";

DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AIRFLOW_DB_USER}') THEN
    EXECUTE format('GRANT USAGE ON SCHEMA raw_data TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('GRANT USAGE ON SCHEMA analytics TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('GRANT USAGE ON SCHEMA staging TO %I', '${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

GRANT USAGE ON SCHEMA raw_data TO "${ANALYTICS_READONLY_USER}";
GRANT USAGE ON SCHEMA analytics TO "${ANALYTICS_READONLY_USER}";

-- 6) Table-level grants (apply to existing tables)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA raw_data TO "${RESTAURANT_DB_USER}";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA analytics TO "${RESTAURANT_DB_USER}";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA staging TO "${RESTAURANT_DB_USER}";

DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AIRFLOW_DB_USER}') THEN
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA raw_data TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA analytics TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA staging TO %I', '${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

GRANT SELECT ON ALL TABLES IN SCHEMA raw_data TO "${ANALYTICS_READONLY_USER}";
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO "${ANALYTICS_READONLY_USER}";

-- 7) Default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_data GRANT ALL ON TABLES TO "${RESTAURANT_DB_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT ALL ON TABLES TO "${RESTAURANT_DB_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA staging GRANT ALL ON TABLES TO "${RESTAURANT_DB_USER}";

DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AIRFLOW_DB_USER}') THEN
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA raw_data GRANT ALL ON TABLES TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT ALL ON TABLES TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA staging GRANT ALL ON TABLES TO %I', '${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

ALTER DEFAULT PRIVILEGES IN SCHEMA raw_data GRANT SELECT ON TABLES TO "${ANALYTICS_READONLY_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO "${ANALYTICS_READONLY_USER}";

-- Sequences privileges
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA raw_data TO "${RESTAURANT_DB_USER}";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA analytics TO "${RESTAURANT_DB_USER}";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA staging TO "${RESTAURANT_DB_USER}";

DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AIRFLOW_DB_USER}') THEN
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA raw_data TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA analytics TO %I', '${AIRFLOW_DB_USER}');
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA staging TO %I', '${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

-- 8) Useful extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

COMMENT ON EXTENSION "uuid-ossp" IS 'UUID generation functions';
COMMENT ON EXTENSION "pg_stat_statements" IS 'Statement execution statistics';
COMMENT ON EXTENSION "pg_trgm" IS 'Trigram matching for text search';

-- 9) Audit log table and permissions
CREATE TABLE IF NOT EXISTS analytics.audit_log
(
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ DEFAULT now(),
    user_name TEXT DEFAULT current_user,
    operation TEXT NOT NULL,
    table_name TEXT,
    record_id TEXT,
    old_values JSONB,
    new_values JSONB,
    details JSONB
);

COMMENT ON TABLE analytics.audit_log IS 'Audit trail for important database operations';

GRANT SELECT, INSERT ON analytics.audit_log TO "${RESTAURANT_DB_USER}";
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${AIRFLOW_DB_USER}') THEN
    EXECUTE format('GRANT SELECT, INSERT ON analytics.audit_log TO %I', '${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;
GRANT SELECT ON analytics.audit_log TO "${ANALYTICS_READONLY_USER}";

-- Grant sequence permissions if the sequence exists (created by SERIAL)
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'audit_log_id_seq' AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname='analytics')) THEN
    EXECUTE 'GRANT ALL ON SEQUENCE analytics.audit_log_id_seq TO ' || quote_ident('${RESTAURANT_DB_USER}');
    EXECUTE 'GRANT ALL ON SEQUENCE analytics.audit_log_id_seq TO ' || quote_ident('${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

-- 10) Health check function
CREATE OR REPLACE FUNCTION analytics.health_check()
RETURNS TABLE (component TEXT, status TEXT, details JSONB)
AS \$\$
BEGIN
    RETURN QUERY
    SELECT
        'database'::TEXT AS component,
        'healthy'::TEXT AS status,
        jsonb_build_object(
            'timestamp', now(),
            'database', current_database(),
            'user', current_user,
            'version', version()
        ) AS details;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION analytics.health_check() IS 'Health check function for monitoring database status';

GRANT EXECUTE ON FUNCTION analytics.health_check() TO "${RESTAURANT_DB_USER}", "${ANALYTICS_READONLY_USER}";
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${AIRFLOW_DB_USER}') THEN
    EXECUTE format('GRANT EXECUTE ON FUNCTION analytics.health_check() TO %I', '${AIRFLOW_DB_USER}');
  END IF;
END
\$\$ LANGUAGE plpgsql;

-- 11) Application schema (aligned with Airflow DAGs and SSE operator)
-- Set the search path for subsequent object creation
SET search_path = analytics, raw_data, staging, public;

-- RAW DATA: Use column name event_offset to avoid reserved keywords
CREATE TABLE IF NOT EXISTS raw_data.events_raw (
    event_offset BIGINT PRIMARY KEY,
    event_id UUID UNIQUE NOT NULL,
    event_type TEXT NOT NULL,
    ts TIMESTAMPTZ NOT NULL,
    partition_key TEXT,
    payload JSONB NOT NULL,
    ingested_at TIMESTAMPTZ DEFAULT now(),
    ingested_by TEXT DEFAULT current_user
);

CREATE INDEX IF NOT EXISTS idx_events_raw_ts ON raw_data.events_raw (ts);
CREATE INDEX IF NOT EXISTS idx_events_raw_event_type ON raw_data.events_raw (event_type);
CREATE INDEX IF NOT EXISTS idx_events_raw_partition_key ON raw_data.events_raw (partition_key);
CREATE INDEX IF NOT EXISTS idx_events_raw_ingested_at ON raw_data.events_raw (ingested_at);
CREATE INDEX IF NOT EXISTS idx_events_raw_payload_gin ON raw_data.events_raw USING gin (payload);

COMMENT ON TABLE raw_data.events_raw IS 'Complete audit trail of all streaming events';
COMMENT ON COLUMN raw_data.events_raw.event_offset IS 'Monotonically increasing offset for stream processing';
COMMENT ON COLUMN raw_data.events_raw.payload IS 'Complete event payload as JSON';

-- ANALYTICS TABLES
CREATE TABLE IF NOT EXISTS analytics.orders (
    order_id UUID PRIMARY KEY,
    visit_id UUID,
    service_type TEXT NOT NULL CHECK (service_type IN ('dine_in', 'takeout', 'delivery')),
    order_ts TIMESTAMPTZ NOT NULL,
    location_code TEXT NOT NULL,
    subtotal NUMERIC(10,2),
    tax NUMERIC(10,2),
    tip NUMERIC(10,2),
    total NUMERIC(10,2),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_order_ts ON analytics.orders (order_ts);
CREATE INDEX IF NOT EXISTS idx_orders_location_code ON analytics.orders (location_code);
CREATE INDEX IF NOT EXISTS idx_orders_service_type ON analytics.orders (service_type);
CREATE INDEX IF NOT EXISTS idx_orders_total ON analytics.orders (total);

COMMENT ON TABLE analytics.orders IS 'Restaurant orders with financial summary';

CREATE TABLE IF NOT EXISTS analytics.order_items (
    order_item_id UUID PRIMARY KEY,
    order_id UUID NOT NULL REFERENCES analytics.orders(order_id) ON DELETE CASCADE,
    menu_item_id UUID,
    category TEXT NOT NULL,
    item_name TEXT NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    qty INTEGER NOT NULL CHECK (qty > 0),
    extended_price NUMERIC(10,2) NOT NULL CHECK (extended_price >= 0),
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON analytics.order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_category ON analytics.order_items (category);
CREATE INDEX IF NOT EXISTS idx_order_items_menu_item_id ON analytics.order_items (menu_item_id);

COMMENT ON TABLE analytics.order_items IS 'Individual items within orders';

CREATE TABLE IF NOT EXISTS analytics.payments (
    payment_id UUID PRIMARY KEY,
    order_id UUID NOT NULL REFERENCES analytics.orders(order_id) ON DELETE CASCADE,
    method TEXT NOT NULL,
    provider TEXT,
    amount NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    auth_code TEXT,
    processed_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payments_order_id ON analytics.payments (order_id);
CREATE INDEX IF NOT EXISTS idx_payments_method ON analytics.payments (method);
CREATE INDEX IF NOT EXISTS idx_payments_provider ON analytics.payments (provider);
CREATE INDEX IF NOT EXISTS idx_payments_processed_at ON analytics.payments (processed_at);

COMMENT ON TABLE analytics.payments IS 'Payment transactions for orders';

CREATE TABLE IF NOT EXISTS analytics.feedback (
    feedback_id UUID PRIMARY KEY,
    order_id UUID REFERENCES analytics.orders(order_id) ON DELETE SET NULL,
    customer_id UUID,
    rating INTEGER CHECK (rating BETWEEN 1 AND 5),
    nps INTEGER CHECK (nps BETWEEN 0 AND 10),
    comment TEXT,
    created_ts TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feedback_order_id ON analytics.feedback (order_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON analytics.feedback (rating);
CREATE INDEX IF NOT EXISTS idx_feedback_nps ON analytics.feedback (nps);
CREATE INDEX IF NOT EXISTS idx_feedback_created_ts ON analytics.feedback (created_ts);

COMMENT ON TABLE analytics.feedback IS 'Customer feedback and satisfaction scores';

-- ANALYTICS VIEWS
CREATE OR REPLACE VIEW analytics.hourly_sales AS
SELECT
    date_trunc('hour', order_ts) AS hour,
    location_code,
    service_type,
    COUNT(*) AS order_count,
    SUM(subtotal) AS subtotal,
    SUM(tax) AS tax,
    SUM(tip) AS tip,
    SUM(total) AS total,
    AVG(total) AS avg_order_value
FROM analytics.orders
WHERE total IS NOT NULL
GROUP BY date_trunc('hour', order_ts), location_code, service_type
ORDER BY hour DESC;

COMMENT ON VIEW analytics.hourly_sales IS 'Hourly sales aggregation by location and service type';

CREATE OR REPLACE VIEW analytics.daily_sales AS
SELECT
    date_trunc('day', order_ts) AS day,
    location_code,
    COUNT(*) AS order_count,
    SUM(total) AS total_revenue,
    AVG(total) AS avg_order_value,
    SUM(tip) AS total_tips,
    AVG(tip) AS avg_tip
FROM analytics.orders
WHERE total IS NOT NULL
GROUP BY date_trunc('day', order_ts), location_code
ORDER BY day DESC, location_code;

COMMENT ON VIEW analytics.daily_sales IS 'Daily sales summary by location';

CREATE OR REPLACE VIEW analytics.menu_performance AS
SELECT
    oi.category,
    oi.item_name,
    COUNT(*) AS times_ordered,
    SUM(oi.qty) AS total_quantity_sold,
    SUM(oi.extended_price) AS total_revenue,
    AVG(oi.unit_price) AS avg_unit_price,
    AVG(oi.extended_price) AS avg_extended_price
FROM analytics.order_items oi
JOIN analytics.orders o ON oi.order_id = o.order_id
WHERE o.total IS NOT NULL
GROUP BY oi.category, oi.item_name
ORDER BY total_revenue DESC;

COMMENT ON VIEW analytics.menu_performance IS 'Menu item sales performance metrics';

CREATE OR REPLACE VIEW analytics.satisfaction_summary AS
SELECT
    date_trunc('day', created_ts) AS day,
    COUNT(*) AS feedback_count,
    AVG(rating::NUMERIC) AS avg_rating,
    AVG(nps::NUMERIC) AS avg_nps,
    COUNT(CASE WHEN rating >= 4 THEN 1 END) * 100.0 / COUNT(*) AS satisfaction_rate,
    COUNT(CASE WHEN nps >= 9 THEN 1 END) * 100.0 / COUNT(*) AS promoter_rate,
    COUNT(CASE WHEN nps <= 6 THEN 1 END) * 100.0 / COUNT(*) AS detractor_rate
FROM analytics.feedback
WHERE rating IS NOT NULL AND nps IS NOT NULL
GROUP BY date_trunc('day', created_ts)
ORDER BY day DESC;

COMMENT ON VIEW analytics.satisfaction_summary IS 'Daily customer satisfaction metrics';

-- STAGING TABLES
CREATE TABLE IF NOT EXISTS staging.event_staging (
    id SERIAL PRIMARY KEY,
    event_offset BIGINT,
    event_id UUID,
    event_type TEXT,
    ts TIMESTAMPTZ,
    partition_key TEXT,
    payload JSONB,
    processed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_event_staging_processed ON staging.event_staging (processed);
CREATE INDEX IF NOT EXISTS idx_event_staging_event_type ON staging.event_staging (event_type);

COMMENT ON TABLE staging.event_staging IS 'Temporary staging for bulk event processing';

-- UTILITY FUNCTIONS
CREATE OR REPLACE FUNCTION analytics.get_latest_offset()
RETURNS BIGINT AS \$\$
BEGIN
    RETURN COALESCE((SELECT MAX(event_offset) FROM raw_data.events_raw), 0);
END;
\$\$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.get_latest_offset() IS 'Get the latest processed event offset';

CREATE OR REPLACE FUNCTION analytics.calculate_order_metrics(p_order_id UUID)
RETURNS TABLE(
    order_id UUID,
    item_count INTEGER,
    total_items INTEGER,
    calculated_subtotal NUMERIC
) AS \$\$
BEGIN
    RETURN QUERY
    SELECT
        p_order_id,
        COUNT(*)::INTEGER AS item_count,
        SUM(qty)::INTEGER AS total_items,
        SUM(extended_price) AS calculated_subtotal
    FROM analytics.order_items
    WHERE order_items.order_id = p_order_id;
END;
\$\$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.calculate_order_metrics(UUID) IS 'Calculate order-level metrics from items';

-- AUDIT TRIGGERS
CREATE OR REPLACE FUNCTION analytics.audit_trigger_function()
RETURNS TRIGGER AS \$\$
DECLARE
    new_json jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE NULL END;
    old_json jsonb := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE NULL END;
    rec_id text;
BEGIN
    rec_id := COALESCE(
        COALESCE(new_json->>'order_id', old_json->>'order_id'),
        COALESCE(new_json->>'payment_id', old_json->>'payment_id'),
        COALESCE(new_json->>'feedback_id', old_json->>'feedback_id'),
        COALESCE(new_json->>'id', old_json->>'id')
    );

    INSERT INTO analytics.audit_log (operation, table_name, record_id, old_values, new_values)
    VALUES (
        TG_OP,
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        rec_id,
        old_json,
        new_json
    );

    RETURN COALESCE(NEW, OLD);
END;
\$\$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_orders_trigger ON analytics.orders;
CREATE TRIGGER audit_orders_trigger
    AFTER INSERT OR UPDATE OR DELETE ON analytics.orders
    FOR EACH ROW EXECUTE FUNCTION analytics.audit_trigger_function();

DROP TRIGGER IF EXISTS audit_payments_trigger ON analytics.payments;
CREATE TRIGGER audit_payments_trigger
    AFTER INSERT OR UPDATE OR DELETE ON analytics.payments
    FOR EACH ROW EXECUTE FUNCTION analytics.audit_trigger_function();

-- SAMPLE DATA VALIDATION FUNCTIONS
CREATE OR REPLACE FUNCTION analytics.validate_data_consistency()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    details TEXT
) AS \$\$
BEGIN
    -- Check for orders without items
    RETURN QUERY
    SELECT
        'orders_without_items'::TEXT,
        CASE WHEN COUNT(*) > 0 THEN 'WARNING' ELSE 'OK' END::TEXT,
        'Found ' || COUNT(*) || ' orders without items'::TEXT
    FROM analytics.orders o
    LEFT JOIN analytics.order_items oi ON o.order_id = oi.order_id
    WHERE oi.order_id IS NULL;

    -- Check for payment mismatches
    RETURN QUERY
    SELECT
        'payment_amount_mismatches'::TEXT,
        CASE WHEN COUNT(*) > 0 THEN 'WARNING' ELSE 'OK' END::TEXT,
        'Found ' || COUNT(*) || ' orders where payment amount != order total'::TEXT
    FROM analytics.orders o
    JOIN analytics.payments p ON o.order_id = p.order_id
    WHERE ABS(o.total - p.amount) > 0.01;
END;
\$\$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.validate_data_consistency() IS 'Check data consistency across tables';

-- Completion Notices
DO \$\$
BEGIN
    RAISE NOTICE 'Restaurant analytics initialization completed successfully.';
    RAISE NOTICE 'Database: %', current_database();
END
\$\$;
EOSQL

echo "Restaurant analytics initialization script completed."
