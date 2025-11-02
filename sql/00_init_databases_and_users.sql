-- =============================================================================
-- Restaurant Analytics Stream Stack - Database & User Initialization
-- =============================================================================
-- This script sets up the complete database architecture with proper security

-- =============================================================================
-- 1. CREATE DATABASES
-- =============================================================================

-- Create application-specific database for restaurant analytics
CREATE DATABASE restaurant_analytics
    WITH
    OWNER = postgres
ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TABLESPACE = pg_default
    CONNECTION LIMIT = -1;

COMMENT ON DATABASE restaurant_analytics IS 'Restaurant analytics application data';

-- Create dedicated Airflow metadata database
CREATE DATABASE airflow_db
    WITH
    OWNER = postgres
ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TABLESPACE = pg_default
    CONNECTION LIMIT = -1;

COMMENT ON DATABASE airflow_db IS 'Apache Airflow metadata and workflow data';

-- =============================================================================
-- 2. CREATE ROLES
-- =============================================================================

-- Create application user role for restaurant analytics
DO
$$
BEGIN
    IF NOT EXISTS (SELECT
    FROM pg_catalog.pg_roles
    WHERE rolname = 'restaurant_user') THEN
    CREATE ROLE restaurant_user
    WITH
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            INHERIT
            NOREPLICATION
            CONNECTION LIMIT -1
            PASSWORD 'RESTAURANT_DB_PASSWORD';
END
IF;
END
$$;

COMMENT ON ROLE restaurant_user IS 'Application user for restaurant analytics operations';

-- Create Airflow user role
DO
$$
BEGIN
    IF NOT EXISTS (SELECT
    FROM pg_catalog.pg_roles
    WHERE rolname = 'airflow_user') THEN
    CREATE ROLE airflow_user
    WITH
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            INHERIT
            NOREPLICATION
            CONNECTION LIMIT -1
            PASSWORD 'AIRFLOW_DB_PASSWORD';
END
IF;
END
$$;

COMMENT ON ROLE airflow_user IS 'Airflow service user for ETL operations and metadata management';

-- Create analytics readonly user for BI tools
DO
$$
BEGIN
    IF NOT EXISTS (SELECT
    FROM pg_catalog.pg_roles
    WHERE rolname = 'analytics_reader') THEN
    CREATE ROLE analytics_reader
    WITH
            LOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            INHERIT
            NOREPLICATION
            CONNECTION LIMIT 10
            PASSWORD 'ANALYTICS_READONLY_PASSWORD';
END
IF;
END
$$;

COMMENT ON ROLE analytics_reader IS 'Read-only access for analytics and BI tools';

-- =============================================================================
-- 3. DATABASE-LEVEL PERMISSIONS
-- =============================================================================

-- Grant database access permissions
GRANT CONNECT ON DATABASE restaurant_analytics TO restaurant_user;
GRANT CONNECT ON DATABASE restaurant_analytics TO airflow_user;
GRANT CONNECT ON DATABASE restaurant_analytics TO analytics_reader;

GRANT ALL PRIVILEGES ON DATABASE airflow_db TO airflow_user;

-- =============================================================================
-- 4. SET UP RESTAURANT ANALYTICS DATABASE PERMISSIONS
-- =============================================================================

\c restaurant_analytics

-- Create schemas for organization
CREATE SCHEMA
IF NOT EXISTS raw_data AUTHORIZATION restaurant_user;
CREATE SCHEMA
IF NOT EXISTS analytics AUTHORIZATION restaurant_user;
CREATE SCHEMA
IF NOT EXISTS staging AUTHORIZATION restaurant_user;

COMMENT ON SCHEMA raw_data IS 'Raw event data and streaming ingestion tables';
COMMENT ON SCHEMA analytics IS 'Processed analytics tables and views';
COMMENT ON SCHEMA staging IS 'Temporary staging tables for ETL processes';

-- Grant schema usage permissions
GRANT USAGE ON SCHEMA raw_data TO restaurant_user, airflow_user, analytics_reader;
GRANT USAGE ON SCHEMA analytics TO restaurant_user, airflow_user, analytics_reader;
GRANT USAGE ON SCHEMA staging TO restaurant_user, airflow_user;

-- Grant table permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA raw_data TO restaurant_user, airflow_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA analytics TO restaurant_user, airflow_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA staging TO restaurant_user, airflow_user;

-- Grant readonly permissions to analytics user
GRANT SELECT ON ALL TABLES IN SCHEMA raw_data TO analytics_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO analytics_reader;

-- Grant permissions on future tables (important for new table creation)
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_data
GRANT ALL ON TABLES TO restaurant_user, airflow_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
GRANT ALL ON TABLES TO restaurant_user, airflow_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging
GRANT ALL ON TABLES TO restaurant_user, airflow_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA raw_data
GRANT SELECT ON TABLES TO analytics_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
GRANT SELECT ON TABLES TO analytics_reader;

-- Grant sequence permissions for auto-increment columns
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA raw_data TO restaurant_user, airflow_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA analytics TO restaurant_user, airflow_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA staging TO restaurant_user, airflow_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA raw_data
GRANT ALL ON SEQUENCES TO restaurant_user, airflow_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
GRANT ALL ON SEQUENCES TO restaurant_user, airflow_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging
GRANT ALL ON SEQUENCES TO restaurant_user, airflow_user;

-- =============================================================================
-- 5. CREATE MONITORING AND HEALTH CHECK FUNCTIONS
-- =============================================================================

-- Function to check database health
CREATE OR REPLACE FUNCTION analytics.health_check
()
RETURNS TABLE
(
    component TEXT,
    status TEXT,
    details JSONB
) AS $$
BEGIN
    -- Check table existence and row counts
    RETURN QUERY
    SELECT
        'database'
    ::TEXT as component,
        'healthy'::TEXT as status,
        jsonb_build_object
    (
            'timestamp', now
    (),
            'database', current_database
    (),
            'user', current_user,
            'version', version
    ()
        ) as details;

-- Add more health checks as needed
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION analytics.health_check
() IS 'Health check function for monitoring database status';

-- Grant execute permission to all users
GRANT EXECUTE ON FUNCTION analytics.health_check
() TO restaurant_user, airflow_user, analytics_reader;

-- =============================================================================
-- 6. SECURITY POLICIES
-- =============================================================================

-- Enable row level security on sensitive tables (to be applied when tables are created)
-- This is a placeholder - specific policies will be added when tables are created

-- =============================================================================
-- 7. CREATE EXTENSION FOR ADDITIONAL FUNCTIONALITY
-- =============================================================================

-- Enable extensions that might be useful
CREATE EXTENSION
IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION
IF NOT EXISTS "pg_stat_statements";
CREATE EXTENSION
IF NOT EXISTS "pg_trgm";

COMMENT ON EXTENSION "uuid-ossp" IS 'UUID generation functions';
COMMENT ON EXTENSION "pg_stat_statements" IS 'Statement execution statistics';
COMMENT ON EXTENSION "pg_trgm" IS 'Trigram matching for text search';

-- =============================================================================
-- 8. LOGGING AND AUDITING SETUP
-- =============================================================================

-- Create audit log table for tracking important operations
CREATE TABLE
IF NOT EXISTS analytics.audit_log
(
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ DEFAULT now
(),
    user_name TEXT DEFAULT current_user,
    operation TEXT NOT NULL,
    table_name TEXT,
    record_id TEXT,
    old_values JSONB,
    new_values JSONB,
    details JSONB
);

COMMENT ON TABLE analytics.audit_log IS 'Audit trail for important database operations';

-- Grant appropriate permissions on audit log
GRANT SELECT, INSERT ON analytics.audit_log TO restaurant_user, airflow_user;
GRANT SELECT ON analytics.audit_log TO analytics_reader;
GRANT ALL ON SEQUENCE analytics.audit_log_id_seq TO restaurant_user, airflow_user;

-- =============================================================================
-- COMPLETION MESSAGE
-- =============================================================================

DO $$
BEGIN
    RAISE NOTICE 'Database initialization completed successfully!';
    RAISE NOTICE 'Created databases: restaurant_analytics, airflow_db';
    RAISE NOTICE 'Created users: restaurant_user, airflow_user, analytics_reader';
    RAISE NOTICE 'Created schemas: raw_data, analytics, staging';
    RAISE NOTICE 'Configured permissions and security policies';
END $$;