"""
Restaurant Stream Ingestion DAG (Legacy Polling Version)
========================================================

This DAG provides a traditional polling-based approach for data ingestion.
It's kept for compatibility and as a fallback to the real-time SSE streaming approach.

Use this DAG when:
- Real-time streaming is not available
- Batch processing is preferred
- Testing or debugging scenarios
"""

import json
import os
from datetime import datetime, timedelta

import requests
from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook

API_URL = os.getenv("RESTAURANT_API_URL", "http://restaurant-api:8000")


def fetch_and_load(**context):
    """
    Fetch events from the restaurant API and load them into the database.
    Uses polling approach with configurable offset tracking.
    """
    offset = int(Variable.get("restaurant_stream_offset", default_var="0"))
    limit = 1000

    # Fetch events from API
    r = requests.get(
        f"{API_URL}/events", params={"since": offset, "limit": limit}, timeout=30
    )
    r.raise_for_status()
    payload = r.json()
    events = payload.get("events", [])
    next_since = payload.get("next_since", offset)

    if not events:
        # Nothing new; keep watermark unchanged
        context['task_instance'].log.info("No new events to process")
        return {"events_processed": 0, "next_offset": offset}

    context['task_instance'].log.info(f"Processing {len(events)} events from offset {offset}")

    # Use the new database connection and schema
    pg = PostgresHook(postgres_conn_id="postgres_restaurant")
    with pg.get_conn() as conn, conn.cursor() as cur:
        # Set search path to use the new schema structure
        cur.execute("SET search_path = analytics, raw_data, public;")

        # Insert raw events into raw_data schema
        cur.executemany(
            """
            INSERT INTO raw_data.events_raw (offset, event_id, event_type, ts, partition_key, payload)
            VALUES (%(offset)s, %(event_id)s, %(event_type)s, %(ts)s, %(partition_key)s, %(payload)s::jsonb)
            ON CONFLICT (offset) DO NOTHING;
        """,
            [
                {
                    "offset": e["offset"],
                    "event_id": e["event_id"],
                    "event_type": e["event_type"],
                    "ts": e["ts"],
                    "partition_key": e.get("partition_key"),
                    "payload": json.dumps(e["payload"]),
                }
                for e in events
            ],
        )

        # Process events into analytics schema
        for e in events:
            t = e["event_type"]
            p = e["payload"]
            if t == "order_created":
                cur.execute(
                    """
                    INSERT INTO analytics.orders (order_id, visit_id, service_type, order_ts, location_code)
                    VALUES (%s,%s,%s,%s,%s)
                    ON CONFLICT (order_id) DO NOTHING;
                """,
                    (
                        p["order_id"],
                        p["visit_id"],
                        p["service_type"],
                        p["order_ts"],
                        p["location_code"],
                    ),
                )
            elif t == "order_item_added":
                cur.execute(
                    """
                    INSERT INTO analytics.order_items (order_item_id, order_id, menu_item_id, category, item_name, unit_price, qty, extended_price)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (order_item_id) DO NOTHING;
                """,
                    (
                        p["order_item_id"],
                        p["order_id"],
                        p["menu_item_id"],
                        p["category"],
                        p["item_name"],
                        p["unit_price"],
                        p["qty"],
                        p["extended_price"],
                    ),
                )
            elif t == "payment_captured":
                cur.execute(
                    """
                    UPDATE analytics.orders
                       SET subtotal = %s, tax = %s, tip = %s, total = %s, updated_at = now()
                     WHERE order_id = %s;
                """,
                    (p["subtotal"], p["tax"], p["tip"], p["total"], p["order_id"]),
                )
                cur.execute(
                    """
                    INSERT INTO analytics.payments (payment_id, order_id, method, provider, amount, auth_code)
                    VALUES (%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (payment_id) DO NOTHING;
                """,
                    (
                        p["payment_id"],
                        p["order_id"],
                        p["method"],
                        p["provider"],
                        p["amount"],
                        p["auth_code"],
                    ),
                )
            elif t == "feedback_submitted":
                cur.execute(
                    """
                    INSERT INTO analytics.feedback (feedback_id, order_id, customer_id, rating, nps, comment, created_ts)
                    VALUES (%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT (feedback_id) DO NOTHING;
                """,
                    (
                        p["feedback_id"],
                        p["order_id"],
                        p["customer_id"],
                        p["rating"],
                        p["nps"],
                        p.get("comment"),
                        p["created_ts"],
                    ),
                )
        conn.commit()

    # Update offset for next run
    Variable.set("restaurant_stream_offset", str(next_since))

    return {
        "events_processed": len(events),
        "next_offset": next_since,
        "processing_completed": True
    }


# DAG Configuration
default_args = {
    'owner': 'restaurant-analytics-team',
    'depends_on_past': False,
    'start_date': datetime(2025, 10, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=2),
}

with DAG(
    dag_id="restaurant_stream_ingest_polling",
    default_args=default_args,
    description="Legacy polling-based restaurant data ingestion (fallback)",
    schedule_interval="*/2 * * * *",  # every 2 minutes (less frequent than real-time)
    catchup=False,
    max_active_runs=1,
    tags=["restaurant", "stream", "polling", "legacy"],
    is_paused_upon_creation=True,  # Start paused, prefer real-time streaming
) as dag:

    fetch_and_load_task = PythonOperator(
        task_id="fetch_and_load",
        python_callable=fetch_and_load,
        doc_md="""
        ### Polling-based Data Ingestion

        This task fetches events from the restaurant API using traditional polling
        and loads them into the PostgreSQL database.

        **Note**: This is a legacy approach. For real-time processing, use the
        `restaurant_realtime_stream` DAG instead.

        **Configuration**:
        - Polls every 2 minutes
        - Processes up to 1000 events per run
        - Uses `postgres_restaurant` connection
        - Maintains offset in Airflow Variables
        """
    )

# DAG Documentation
dag.doc_md = """
# Restaurant Stream Ingestion (Polling Version)

This DAG provides a traditional polling-based approach for restaurant data ingestion.
It serves as a fallback option when real-time streaming is not available or suitable.

## When to Use

- **Fallback scenario**: When the SSE streaming endpoint is unavailable
- **Batch processing**: When you prefer periodic batch processing over continuous streaming
- **Testing**: For validating data processing logic in a controlled manner
- **Resource constraints**: When continuous streaming consumes too many resources

## Architecture

```
Restaurant API (REST) → Airflow Polling → PostgreSQL
```

## Key Differences from Real-time DAG

| Aspect | Polling (This DAG) | Real-time Streaming |
|--------|-------------------|-------------------|
| Latency | 2+ minutes | Sub-second |
| API Method | REST GET /events | SSE GET /stream |
| Resource Usage | Lower | Higher |
| Complexity | Simple | Advanced |
| Recovery | Manual restart | Automatic |

## Configuration

- **Schedule**: Every 2 minutes
- **Batch Size**: Up to 1000 events
- **Connection**: `postgres_restaurant`
- **Offset Tracking**: Airflow Variables

## Monitoring

Monitor the `restaurant_stream_offset` variable to track processing progress.
Check task logs for event processing statistics.
"""
