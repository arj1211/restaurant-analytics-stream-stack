"""
Server-Sent Events (SSE) Stream Operator for Airflow
==================================================

This custom operator enables real-time streaming data ingestion from SSE endpoints.
It replaces the traditional polling approach with continuous stream consumption.
"""

import json
import logging
import time
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional

import requests
from airflow import AirflowException
from airflow.configuration import conf
from airflow.models import BaseOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook
from airflow.utils.context import Context


class SSEStreamOperator(BaseOperator):
    """
    Operator that consumes Server-Sent Events stream and processes events in real-time.

    This operator maintains a persistent connection to an SSE endpoint and processes
    events as they arrive, providing true real-time data ingestion capabilities.
    """

    template_fields = (
        "sse_url",
        "postgres_conn_id",
        "max_events_per_run",
        "timeout_seconds",
    )

    def __init__(
        self,
        sse_url: str,
        postgres_conn_id: str = "postgres_restaurant",
        max_events_per_run: int = 1000,
        timeout_seconds: int = 60,
        batch_size: int = 100,
        event_processors: Optional[Dict[str, callable]] = None,
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self.sse_url = sse_url
        self.postgres_conn_id = postgres_conn_id
        self.max_events_per_run = max_events_per_run
        self.timeout_seconds = timeout_seconds
        self.batch_size = batch_size
        self.event_processors = event_processors or {}
        self.logger = logging.getLogger(__name__)

    def execute(self, context: Context) -> Dict[str, Any]:
        """Execute the SSE streaming operator."""
        self.logger.info(f"Starting SSE stream consumption from {self.sse_url}")

        start_time = datetime.utcnow()
        events_processed = 0
        events_batch = []

        try:
            # Initialize database connection
            pg_hook = PostgresHook(postgres_conn_id=self.postgres_conn_id)

            # Start SSE stream
            with requests.get(
                self.sse_url,
                stream=True,
                timeout=self.timeout_seconds,
                headers={"Accept": "text/event-stream"},
            ) as response:
                response.raise_for_status()

                self.logger.info("Successfully connected to SSE stream")

                for line in response.iter_lines(decode_unicode=True):
                    # Check timeout
                    if (
                        datetime.utcnow() - start_time
                    ).total_seconds() > self.timeout_seconds:
                        self.logger.info(
                            f"Timeout reached after {self.timeout_seconds} seconds"
                        )
                        break

                    # Check max events limit
                    if events_processed >= self.max_events_per_run:
                        self.logger.info(
                            f"Max events limit reached: {self.max_events_per_run}"
                        )
                        break

                    # Parse SSE event
                    event = self._parse_sse_line(line)
                    if event:
                        events_batch.append(event)
                        events_processed += 1

                        # Process batch when it reaches batch_size
                        if len(events_batch) >= self.batch_size:
                            self._process_events_batch(pg_hook, events_batch)
                            events_batch = []

                # Process remaining events in batch
                if events_batch:
                    self._process_events_batch(pg_hook, events_batch)

        except requests.exceptions.RequestException as e:
            raise AirflowException(f"Failed to connect to SSE stream: {str(e)}")
        except Exception as e:
            raise AirflowException(f"Error processing SSE stream: {str(e)}")

        execution_time = (datetime.utcnow() - start_time).total_seconds()

        result = {
            "events_processed": events_processed,
            "execution_time_seconds": execution_time,
            "events_per_second": events_processed / execution_time
            if execution_time > 0
            else 0,
            "batches_processed": (events_processed // self.batch_size)
            + (1 if events_processed % self.batch_size > 0 else 0),
        }

        self.logger.info(f"SSE stream processing completed: {result}")
        return result

    def _parse_sse_line(self, line: str) -> Optional[Dict[str, Any]]:
        """Parse a single SSE line into an event."""
        if not line.strip():
            return None

        try:
            # SSE format: "data: {json_data}"
            if line.startswith("data: "):
                data_str = line[6:]  # Remove 'data: ' prefix
                return json.loads(data_str)

            # Handle other SSE fields if needed (id, event, etc.)
            return None

        except json.JSONDecodeError as e:
            self.logger.warning(
                f"Failed to parse SSE line as JSON: {line[:100]}... Error: {e}"
            )
            return None
        except Exception as e:
            self.logger.warning(f"Unexpected error parsing SSE line: {e}")
            return None

    def _process_events_batch(
        self, pg_hook: PostgresHook, events: List[Dict[str, Any]]
    ) -> None:
        """Process a batch of events with database insertion."""
        if not events:
            return

        self.logger.info(f"Processing batch of {len(events)} events")

        try:
            with pg_hook.get_conn() as conn:
                with conn.cursor() as cursor:
                    # Insert raw events
                    self._insert_raw_events(cursor, events)

                    # Process events by type
                    for event in events:
                        self._process_event_by_type(cursor, event)

                    conn.commit()

        except Exception as e:
            self.logger.error(f"Error processing events batch: {e}")
            raise

    def _insert_raw_events(self, cursor, events: List[Dict[str, Any]]) -> None:
        """Insert events into raw_data.events_raw table."""
        raw_events_data = []

        for event in events:
            raw_events_data.append(
                {
                    "event_offset": event.get("offset"),
                    "event_id": event.get("event_id"),
                    "event_type": event.get("event_type"),
                    "ts": event.get("ts"),
                    "partition_key": event.get("partition_key"),
                    "payload": json.dumps(event.get("payload", {})),
                }
            )

        if raw_events_data:
            cursor.executemany(
                """
                INSERT INTO raw_data.events_raw
                (event_offset, event_id, event_type, ts, partition_key, payload)
                VALUES (%(event_offset)s, %(event_id)s, %(event_type)s, %(ts)s, %(partition_key)s, %(payload)s::jsonb)
                ON CONFLICT (event_offset) DO NOTHING;
                """,
                raw_events_data,
            )

    def _process_event_by_type(self, cursor, event: Dict[str, Any]) -> None:
        """Process individual event based on its type."""
        event_type = event.get("event_type")
        payload = event.get("payload", {})

        # Use custom processors if available
        if event_type in self.event_processors:
            self.event_processors[event_type](cursor, event, payload)
            return

        # Default processors for known event types
        if event_type == "order_created":
            self._process_order_created(cursor, payload)
        elif event_type == "order_item_added":
            self._process_order_item_added(cursor, payload)
        elif event_type == "payment_captured":
            self._process_payment_captured(cursor, payload)
        elif event_type == "feedback_submitted":
            self._process_feedback_submitted(cursor, payload)
        else:
            self.logger.warning(f"Unknown event type: {event_type}")

    def _process_order_created(self, cursor, payload: Dict[str, Any]) -> None:
        """Process order_created event."""
        cursor.execute(
            """
            INSERT INTO analytics.orders
            (order_id, visit_id, service_type, order_ts, location_code)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (order_id) DO NOTHING;
            """,
            (
                payload.get("order_id"),
                payload.get("visit_id"),
                payload.get("service_type"),
                payload.get("order_ts"),
                payload.get("location_code"),
            ),
        )

    def _process_order_item_added(self, cursor, payload: Dict[str, Any]) -> None:
        """Process order_item_added event."""
        cursor.execute(
            """
            INSERT INTO analytics.order_items
            (order_item_id, order_id, menu_item_id, category, item_name, unit_price, qty, extended_price)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (order_item_id) DO NOTHING;
            """,
            (
                payload.get("order_item_id"),
                payload.get("order_id"),
                payload.get("menu_item_id"),
                payload.get("category"),
                payload.get("item_name"),
                payload.get("unit_price"),
                payload.get("qty"),
                payload.get("extended_price"),
            ),
        )

    def _process_payment_captured(self, cursor, payload: Dict[str, Any]) -> None:
        """Process payment_captured event."""
        # Update order financial information
        cursor.execute(
            """
            UPDATE analytics.orders
            SET subtotal = %s, tax = %s, tip = %s, total = %s, updated_at = now()
            WHERE order_id = %s;
            """,
            (
                payload.get("subtotal"),
                payload.get("tax"),
                payload.get("tip"),
                payload.get("total"),
                payload.get("order_id"),
            ),
        )

        # Insert payment record
        cursor.execute(
            """
            INSERT INTO analytics.payments
            (payment_id, order_id, method, provider, amount, auth_code)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (payment_id) DO NOTHING;
            """,
            (
                payload.get("payment_id"),
                payload.get("order_id"),
                payload.get("method"),
                payload.get("provider"),
                payload.get("amount"),
                payload.get("auth_code"),
            ),
        )

    def _process_feedback_submitted(self, cursor, payload: Dict[str, Any]) -> None:
        """Process feedback_submitted event."""
        cursor.execute(
            """
            INSERT INTO analytics.feedback
            (feedback_id, order_id, customer_id, rating, nps, comment, created_ts)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (feedback_id) DO NOTHING;
            """,
            (
                payload.get("feedback_id"),
                payload.get("order_id"),
                payload.get("customer_id"),
                payload.get("rating"),
                payload.get("nps"),
                payload.get("comment"),
                payload.get("created_ts"),
            ),
        )


class SSEStreamSensor(BaseOperator):
    """
    Sensor that monitors SSE stream availability and health.

    This can be used to check if the SSE endpoint is available before
    starting the streaming operator.
    """

    def __init__(self, sse_url: str, timeout_seconds: int = 10, **kwargs) -> None:
        super().__init__(**kwargs)
        self.sse_url = sse_url
        self.timeout_seconds = timeout_seconds
        self.logger = logging.getLogger(__name__)

    def execute(self, context: Context) -> bool:
        """Check if SSE endpoint is available."""
        try:
            # Try to connect to the SSE endpoint
            response = requests.get(
                self.sse_url.replace("/stream", "/health"),  # Check health endpoint
                timeout=self.timeout_seconds,
            )
            response.raise_for_status()

            health_data = response.json()
            self.logger.info(f"SSE endpoint health check: {health_data}")

            return True

        except Exception as e:
            self.logger.error(f"SSE endpoint health check failed: {e}")
            raise AirflowException(f"SSE endpoint not available: {e}")


# Utility functions for custom event processors


def create_custom_event_processor(processor_func: callable):
    """
    Decorator to create custom event processors.

    Usage:
        @create_custom_event_processor
        def my_processor(cursor, event, payload):
            # Custom processing logic
            pass
    """

    def wrapper(*args, **kwargs):
        return processor_func(*args, **kwargs)

    return wrapper


# Example custom processor
@create_custom_event_processor
def custom_loyalty_processor(cursor, event: Dict[str, Any], payload: Dict[str, Any]):
    """Example custom processor for loyalty events."""
    # This would be called for events of type 'loyalty_points_earned' or similar
    pass
