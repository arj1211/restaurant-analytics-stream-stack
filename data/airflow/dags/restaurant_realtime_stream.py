"""
Restaurant Real-time Stream Processing DAG
=========================================

This DAG replaces the polling-based approach with real-time Server-Sent Events (SSE)
stream consumption, providing sub-second latency for data ingestion and processing.

Key Features:
- Real-time SSE stream consumption
- Batch processing for efficiency
- Health monitoring and error handling
- Automatic recovery and restart capabilities
- Data quality validation
"""

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

# Import custom SSE operator
from sse_operator import SSEStreamOperator, SSEStreamSensor

# =============================================================================
# DAG Configuration
# =============================================================================

# Get configuration from environment
API_URL = os.getenv("RESTAURANT_API_URL", "http://restaurant-api:8000")
POSTGRES_CONN_ID = "postgres_restaurant"

# Default arguments for the DAG
default_args = {
    "owner": "restaurant-analytics-team",
    "depends_on_past": False,
    "start_date": datetime(2025, 10, 1),
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 3,
    "retry_delay": timedelta(minutes=1),
    "catchup": False,
}

# =============================================================================
# Helper Functions
# =============================================================================


def validate_stream_health(**context):
    """
    Validate the health and performance of the streaming system.
    """
    import logging

    from airflow.providers.postgres.hooks.postgres import PostgresHook

    logger = logging.getLogger(__name__)
    pg_hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    # Check recent data ingestion
    recent_events_query = """
        SELECT
            COUNT(*) as recent_events,
            MAX(ingested_at) as last_ingestion,
            COUNT(DISTINCT event_type) as event_types
        FROM raw_data.events_raw
        WHERE ingested_at >= NOW() - INTERVAL '5 minutes';
    """

    with pg_hook.get_conn() as conn:
        with conn.cursor() as cursor:
            cursor.execute(recent_events_query)
            result = cursor.fetchone()

    recent_events, last_ingestion, event_types = result

    logger.info(
        f"Stream health check - Recent events: {recent_events}, "
        f"Last ingestion: {last_ingestion}, Event types: {event_types}"
    )

    # Alert if no recent data
    if recent_events == 0:
        logger.warning("No events ingested in the last 5 minutes!")
        # Could trigger alerts here

    return {
        "recent_events": recent_events,
        "last_ingestion": str(last_ingestion) if last_ingestion else None,
        "event_types": event_types,
        "status": "healthy" if recent_events > 0 else "warning",
    }


def cleanup_old_data(**context):
    """
    Clean up old raw events to manage storage.
    Keeps last 7 days of raw events and all processed analytics data.
    """
    from airflow.providers.postgres.hooks.postgres import PostgresHook

    pg_hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    cleanup_query = """
        DELETE FROM raw_data.events_raw
        WHERE ingested_at < NOW() - INTERVAL '7 days';
    """

    with pg_hook.get_conn() as conn:
        with conn.cursor() as cursor:
            cursor.execute(cleanup_query)
            deleted_count = cursor.rowcount
            conn.commit()

    return {"deleted_events": deleted_count}


def generate_data_quality_report(**context):
    """
    Generate a data quality report for monitoring.
    """
    from airflow.providers.postgres.hooks.postgres import PostgresHook

    pg_hook = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)

    quality_checks = [
        {
            "name": "orphaned_order_items",
            "query": """
                SELECT COUNT(*) FROM analytics.order_items oi
                LEFT JOIN analytics.orders o ON oi.order_id = o.order_id
                WHERE o.order_id IS NULL;
            """,
            "expected": 0,
        },
        {
            "name": "payment_amount_mismatches",
            "query": """
                SELECT COUNT(*) FROM analytics.orders o
                JOIN analytics.payments p ON o.order_id = p.order_id
                WHERE ABS(o.total - p.amount) > 0.01;
            """,
            "expected": 0,
        },
        {
            "name": "negative_amounts",
            "query": """
                SELECT COUNT(*) FROM analytics.orders
                WHERE total < 0 OR subtotal < 0 OR tax < 0;
            """,
            "expected": 0,
        },
    ]

    results = {}
    with pg_hook.get_conn() as conn:
        with conn.cursor() as cursor:
            for check in quality_checks:
                cursor.execute(check["query"])
                count = cursor.fetchone()[0]
                results[check["name"]] = {
                    "count": count,
                    "expected": check["expected"],
                    "passed": count == check["expected"],
                }

    return results


# =============================================================================
# DAG Definition
# =============================================================================

dag = DAG(
    "restaurant_realtime_stream",
    default_args=default_args,
    description="Real-time restaurant analytics stream processing with SSE",
    schedule_interval=timedelta(
        minutes=1
    ),  # Triggered externally or continuously running
    tags=["restaurant", "streaming", "realtime", "sse"],
    max_active_runs=1,
    is_paused_upon_creation=True,
)

# =============================================================================
# Task Definitions
# =============================================================================

# Check if SSE endpoint is available
stream_health_check = SSEStreamSensor(
    task_id="stream_health_check",
    sse_url=f"{API_URL}/stream",
    timeout_seconds=10,
    dag=dag,
    doc_md="""
    ### Stream Health Check
    Verifies that the restaurant API SSE endpoint is available and responsive
    before starting the streaming tasks.
    """,
)

# Main SSE streaming task
realtime_stream_processor = SSEStreamOperator(
    task_id="realtime_stream_processor",
    sse_url=f"{API_URL}/stream",
    postgres_conn_id=POSTGRES_CONN_ID,
    max_events_per_run=5000,  # Process up to 5000 events per run
    timeout_seconds=300,  # Run for 5 minutes before restarting
    batch_size=50,  # Process in batches of 50 events
    dag=dag,
    doc_md="""
    ### Real-time Stream Processor
    Consumes events from the restaurant API SSE stream and processes them in real-time.

    - **Max Events**: 5000 per run
    - **Timeout**: 5 minutes
    - **Batch Size**: 50 events per batch
    - **Connection**: Uses postgres_restaurant connection
    """,
)

# Data quality validation
data_quality_check = PythonOperator(
    task_id="data_quality_check",
    python_callable=generate_data_quality_report,
    dag=dag,
    doc_md="""
    ### Data Quality Check
    Runs validation queries to ensure data integrity:
    - Orphaned order items
    - Payment amount mismatches
    - Negative amounts
    """,
)

# System health monitoring
system_health_monitor = PythonOperator(
    task_id="system_health_monitor",
    python_callable=validate_stream_health,
    dag=dag,
    doc_md="""
    ### System Health Monitor
    Monitors the overall health of the streaming system:
    - Recent event ingestion rate
    - Last ingestion timestamp
    - Event type diversity
    """,
)

# Refresh materialized views for analytics
refresh_analytics_views = SQLExecuteQueryOperator(
    task_id="refresh_analytics_views",
    conn_id=POSTGRES_CONN_ID,
    sql="""
        -- Refresh any materialized views if they exist
        -- This is a placeholder for future materialized view refreshes
        SELECT 'Analytics views refreshed' as status;
    """,
    dag=dag,
    doc_md="""
    ### Refresh Analytics Views
    Refreshes materialized views used for analytics dashboards.
    Currently a placeholder for future materialized view implementations.
    """,
)

# Cleanup old data (runs less frequently)
cleanup_old_events = PythonOperator(
    task_id="cleanup_old_events",
    python_callable=cleanup_old_data,
    dag=dag,
    doc_md="""
    ### Cleanup Old Events
    Removes raw events older than 7 days to manage storage:
    - Preserves all processed analytics data
    - Only removes raw event logs
    - Runs to prevent database bloat
    """,
)

# =============================================================================
# Task Dependencies
# =============================================================================

# Primary stream processing flow
stream_health_check >> realtime_stream_processor

# Monitoring and quality checks run after stream processing
realtime_stream_processor >> [data_quality_check, system_health_monitor]

# Analytics refresh depends on successful stream processing
realtime_stream_processor >> refresh_analytics_views

# Cleanup runs independently (could be on a different schedule)
cleanup_old_events

# =============================================================================
# Additional Documentation
# =============================================================================

dag.doc_md = """
# Restaurant Real-time Stream Processing

This DAG implements real-time data ingestion using Server-Sent Events (SSE)
instead of the traditional polling approach, providing sub-second latency
for restaurant analytics data.

## Architecture

```
Restaurant API (SSE) → Airflow SSE Operator → PostgreSQL → Analytics
```

## Key Features

1. **Real-time Processing**: Uses SSE for continuous data streaming
2. **Batch Optimization**: Processes events in configurable batches
3. **Health Monitoring**: Continuous system health and data quality checks
4. **Error Recovery**: Automatic retry and recovery mechanisms
5. **Storage Management**: Automatic cleanup of old raw events

## Monitoring

- **System Health**: Monitors ingestion rates and system status
- **Data Quality**: Validates data integrity with automated checks
- **Performance**: Tracks events per second and processing efficiency

## Configuration

Key parameters can be adjusted via environment variables:
- `RESTAURANT_API_URL`: API endpoint URL
- Connection ID: `postgres_restaurant`

## Usage

This DAG is designed to run continuously. It can be triggered manually
or set up with a continuous schedule for real-time processing.

For batch processing scenarios, consider using the legacy polling DAG.
"""
