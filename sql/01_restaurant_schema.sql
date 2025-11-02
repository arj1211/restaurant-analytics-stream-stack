-- =============================================================================
-- Restaurant Analytics Schema - Application Tables
-- =============================================================================
-- Run this script after database initialization to create application tables
-- This should be run against the restaurant_analytics database

-- Ensure we're connected to the correct database
\c restaurant_analytics

-- Set the search path to use our schemas
SET search_path = analytics, raw_data, staging, public;

-- =============================================================================
-- 1. RAW DATA TABLES (for event streaming and audit trail)
-- =============================================================================

-- Raw events table for complete audit trail
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

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_events_raw_ts ON raw_data.events_raw (ts);
CREATE INDEX IF NOT EXISTS idx_events_raw_event_type ON raw_data.events_raw (event_type);
CREATE INDEX IF NOT EXISTS idx_events_raw_partition_key ON raw_data.events_raw (partition_key);
CREATE INDEX IF NOT EXISTS idx_events_raw_ingested_at ON raw_data.events_raw (ingested_at);
CREATE INDEX IF NOT EXISTS idx_events_raw_payload_gin ON raw_data.events_raw USING gin (payload);

COMMENT ON TABLE raw_data.events_raw IS 'Complete audit trail of all streaming events';
COMMENT ON COLUMN raw_data.events_raw.event_offset IS 'Monotonically increasing offset for stream processing';
COMMENT ON COLUMN raw_data.events_raw.payload IS 'Complete event payload as JSON';

-- =============================================================================
-- 2. ANALYTICS TABLES (normalized for efficient querying)
-- =============================================================================

-- Orders fact table
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

-- Indexes for orders
CREATE INDEX IF NOT EXISTS idx_orders_order_ts ON analytics.orders (order_ts);
CREATE INDEX IF NOT EXISTS idx_orders_location_code ON analytics.orders (location_code);
CREATE INDEX IF NOT EXISTS idx_orders_service_type ON analytics.orders (service_type);
CREATE INDEX IF NOT EXISTS idx_orders_total ON analytics.orders (total);

COMMENT ON TABLE analytics.orders IS 'Restaurant orders with financial summary';

-- Order items table
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

-- Indexes for order items
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON analytics.order_items (order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_category ON analytics.order_items (category);
CREATE INDEX IF NOT EXISTS idx_order_items_menu_item_id ON analytics.order_items (menu_item_id);

COMMENT ON TABLE analytics.order_items IS 'Individual items within orders';

-- Payments table
CREATE TABLE IF NOT EXISTS analytics.payments (
    payment_id UUID PRIMARY KEY,
    order_id UUID NOT NULL REFERENCES analytics.orders(order_id) ON DELETE CASCADE,
    method TEXT NOT NULL,
    provider TEXT,
    amount NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    auth_code TEXT,
    processed_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes for payments
CREATE INDEX IF NOT EXISTS idx_payments_order_id ON analytics.payments (order_id);
CREATE INDEX IF NOT EXISTS idx_payments_method ON analytics.payments (method);
CREATE INDEX IF NOT EXISTS idx_payments_provider ON analytics.payments (provider);
CREATE INDEX IF NOT EXISTS idx_payments_processed_at ON analytics.payments (processed_at);

COMMENT ON TABLE analytics.payments IS 'Payment transactions for orders';

-- Customer feedback table
CREATE TABLE IF NOT EXISTS analytics.feedback (
    feedback_id UUID PRIMARY KEY,
    order_id UUID REFERENCES analytics.orders(order_id) ON DELETE SET NULL,
    customer_id UUID,
    rating INTEGER CHECK (rating BETWEEN 1 AND 5),
    nps INTEGER CHECK (nps BETWEEN 0 AND 10),
    feedback_comment TEXT,
    created_ts TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes for feedback
CREATE INDEX IF NOT EXISTS idx_feedback_order_id ON analytics.feedback (order_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON analytics.feedback (rating);
CREATE INDEX IF NOT EXISTS idx_feedback_nps ON analytics.feedback (nps);
CREATE INDEX IF NOT EXISTS idx_feedback_created_ts ON analytics.feedback (created_ts);

COMMENT ON TABLE analytics.feedback IS 'Customer feedback and satisfaction scores';

-- =============================================================================
-- 3. ANALYTICS VIEWS (for common business queries)
-- =============================================================================

-- Hourly sales summary view
CREATE OR REPLACE VIEW analytics.hourly_sales AS
SELECT
    date_trunc('hour', order_ts) as hour,
    location_code,
    service_type,
    COUNT(*) as order_count,
    SUM(subtotal) as subtotal,
    SUM(tax) as tax,
    SUM(tip) as tip,
    SUM(total) as total,
    AVG(total) as avg_order_value
FROM analytics.orders
WHERE total IS NOT NULL
GROUP BY date_trunc('hour', order_ts), location_code, service_type
ORDER BY hour DESC;

COMMENT ON VIEW analytics.hourly_sales IS 'Hourly sales aggregation by location and service type';

-- Daily sales summary view
CREATE OR REPLACE VIEW analytics.daily_sales AS
SELECT
    date_trunc('day', order_ts) as day,
    location_code,
    COUNT(*) as order_count,
    SUM(total) as total_revenue,
    AVG(total) as avg_order_value,
    SUM(tip) as total_tips,
    AVG(tip) as avg_tip
FROM analytics.orders
WHERE total IS NOT NULL
GROUP BY date_trunc('day', order_ts), location_code
ORDER BY day DESC, location_code;

COMMENT ON VIEW analytics.daily_sales IS 'Daily sales summary by location';

-- Menu item performance view
CREATE OR REPLACE VIEW analytics.menu_performance AS
SELECT
    oi.category,
    oi.item_name,
    COUNT(*) as times_ordered,
    SUM(oi.qty) as total_quantity_sold,
    SUM(oi.extended_price) as total_revenue,
    AVG(oi.unit_price) as avg_unit_price,
    AVG(oi.extended_price) as avg_extended_price
FROM analytics.order_items oi
JOIN analytics.orders o ON oi.order_id = o.order_id
WHERE o.total IS NOT NULL
GROUP BY oi.category, oi.item_name
ORDER BY total_revenue DESC;

COMMENT ON VIEW analytics.menu_performance IS 'Menu item sales performance metrics';

-- Customer satisfaction summary view
CREATE OR REPLACE VIEW analytics.satisfaction_summary AS
SELECT
    date_trunc('day', created_ts) as day,
    COUNT(*) as feedback_count,
    AVG(rating::NUMERIC) as avg_rating,
    AVG(nps::NUMERIC) as avg_nps,
    COUNT(CASE WHEN rating >= 4 THEN 1 END) * 100.0 / COUNT(*) as satisfaction_rate,
    COUNT(CASE WHEN nps >= 9 THEN 1 END) * 100.0 / COUNT(*) as promoter_rate,
    COUNT(CASE WHEN nps <= 6 THEN 1 END) * 100.0 / COUNT(*) as detractor_rate
FROM analytics.feedback
WHERE rating IS NOT NULL AND nps IS NOT NULL
GROUP BY date_trunc('day', created_ts)
ORDER BY day DESC;

COMMENT ON VIEW analytics.satisfaction_summary IS 'Daily customer satisfaction metrics';

-- =============================================================================
-- 4. STAGING TABLES (for ETL processing)
-- =============================================================================

-- Staging table for bulk operations
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

-- =============================================================================
-- 5. UTILITY FUNCTIONS
-- =============================================================================

-- Function to get latest offset
CREATE OR REPLACE FUNCTION analytics.get_latest_offset()
RETURNS BIGINT AS $$
BEGIN
    RETURN COALESCE((SELECT MAX(event_offset) FROM raw_data.events_raw), 0);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.get_latest_offset() IS 'Get the latest processed event offset';

-- Function to calculate order metrics
CREATE OR REPLACE FUNCTION analytics.calculate_order_metrics(p_order_id UUID)
RETURNS TABLE(
    order_id UUID,
    item_count INTEGER,
    total_items INTEGER,
    calculated_subtotal NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p_order_id,
        COUNT(*)::INTEGER as item_count,
        SUM(qty)::INTEGER as total_items,
        SUM(extended_price) as calculated_subtotal
    FROM analytics.order_items
    WHERE order_items.order_id = p_order_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.calculate_order_metrics(UUID) IS 'Calculate order-level metrics from items';

-- =============================================================================
-- 6. TRIGGERS FOR AUDIT LOGGING
-- =============================================================================

-- Function for audit logging
CREATE OR REPLACE FUNCTION analytics.audit_trigger_function()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO analytics.audit_log (operation, table_name, record_id, old_values, new_values)
    VALUES (
        TG_OP,
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        COALESCE(NEW.order_id::TEXT, OLD.order_id::TEXT, NEW.payment_id::TEXT, OLD.payment_id::TEXT),
        CASE WHEN TG_OP = 'DELETE' THEN row_to_json(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN row_to_json(NEW) ELSE NULL END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Apply audit triggers to important tables
DROP TRIGGER IF EXISTS audit_orders_trigger ON analytics.orders;
CREATE TRIGGER audit_orders_trigger
    AFTER INSERT OR UPDATE OR DELETE ON analytics.orders
    FOR EACH ROW EXECUTE FUNCTION analytics.audit_trigger_function();

DROP TRIGGER IF EXISTS audit_payments_trigger ON analytics.payments;
CREATE TRIGGER audit_payments_trigger
    AFTER INSERT OR UPDATE OR DELETE ON analytics.payments
    FOR EACH ROW EXECUTE FUNCTION analytics.audit_trigger_function();

-- =============================================================================
-- 7. SAMPLE DATA VALIDATION FUNCTIONS
-- =============================================================================

-- Function to validate data consistency
CREATE OR REPLACE FUNCTION analytics.validate_data_consistency()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    details TEXT
) AS $$
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
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.validate_data_consistency() IS 'Check data consistency across tables';

-- =============================================================================
-- COMPLETION MESSAGE
-- =============================================================================

DO $$
BEGIN
    RAISE NOTICE 'Restaurant analytics schema created successfully!';
    RAISE NOTICE 'Tables created in schemas: raw_data, analytics, staging';
    RAISE NOTICE 'Views created for common analytics queries';
    RAISE NOTICE 'Utility functions and triggers configured';
    RAISE NOTICE 'Ready for data ingestion and analytics workloads';
END $$;