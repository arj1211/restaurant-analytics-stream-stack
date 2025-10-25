import json
import os
from datetime import datetime

import requests
from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook

API_URL = os.getenv("RESTAURANT_API_URL", "http://restaurant-api:8000")


def fetch_and_load(**context):
    offset = int(Variable.get("restaurant_stream_offset", default_var="0"))
    limit = 1000
    r = requests.get(
        f"{API_URL}/events", params={"since": offset, "limit": limit}, timeout=30
    )
    r.raise_for_status()
    payload = r.json()
    events = payload.get("events", [])
    next_since = payload.get("next_since", offset)
    if not events:
        # nothing new; keep watermark unchanged
        return

    pg = PostgresHook(postgres_conn_id="postgres_dwh")  # explicit
    with pg.get_conn() as conn, conn.cursor() as cur:
        cur.executemany(
            """
            INSERT INTO events_raw (offset, event_id, event_type, ts, partition_key, payload)
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

        for e in events:
            t = e["event_type"]
            p = e["payload"]
            if t == "order_created":
                cur.execute(
                    """
                    INSERT INTO orders (order_id, visit_id, service_type, order_ts, location_code)
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
                    INSERT INTO order_items (order_item_id, order_id, menu_item_id, category, item_name, unit_price, qty, extended_price)
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
                    UPDATE orders
                       SET subtotal = %s, tax = %s, tip = %s, total = %s
                     WHERE order_id = %s;
                """,
                    (p["subtotal"], p["tax"], p["tip"], p["total"], p["order_id"]),
                )
                cur.execute(
                    """
                    INSERT INTO payments (payment_id, order_id, method, provider, amount, auth_code)
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
                    INSERT INTO feedback (feedback_id, order_id, customer_id, rating, nps, comment, created_ts)
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

    Variable.set("restaurant_stream_offset", str(next_since))


with DAG(
    dag_id="restaurant_stream_ingest",
    start_date=datetime(2025, 10, 1),
    schedule_interval="*/1 * * * *",  # every minute
    catchup=False,
    max_active_runs=1,
    tags=["restaurant", "stream", "synthetic"],
) as dag:
    t = PythonOperator(task_id="fetch_and_load", python_callable=fetch_and_load)
