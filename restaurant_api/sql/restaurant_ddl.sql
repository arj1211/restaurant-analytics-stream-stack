CREATE TABLE IF NOT EXISTS events_raw (
  offset        BIGINT PRIMARY KEY,
  event_id      UUID UNIQUE NOT NULL,
  event_type    TEXT NOT NULL,
  ts            TIMESTAMPTZ NOT NULL,
  partition_key TEXT,
  payload       JSONB NOT NULL,
  ingested_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS orders (
  order_id      UUID PRIMARY KEY,
  visit_id      UUID,
  service_type  TEXT,
  order_ts      TIMESTAMPTZ,
  subtotal      NUMERIC(10,2),
  tax           NUMERIC(10,2),
  tip           NUMERIC(10,2),
  total         NUMERIC(10,2),
  location_code TEXT
);

CREATE TABLE IF NOT EXISTS order_items (
  order_item_id UUID PRIMARY KEY,
  order_id      UUID NOT NULL REFERENCES orders(order_id),
  menu_item_id  UUID,
  category      TEXT,
  item_name     TEXT,
  unit_price    NUMERIC(10,2),
  qty           INT,
  extended_price NUMERIC(10,2)
);

CREATE TABLE IF NOT EXISTS payments (
  payment_id    UUID PRIMARY KEY,
  order_id      UUID NOT NULL REFERENCES orders(order_id),
  method        TEXT,
  provider      TEXT,
  amount        NUMERIC(10,2),
  auth_code     TEXT
);

CREATE TABLE IF NOT EXISTS feedback (
  feedback_id   UUID PRIMARY KEY,
  order_id      UUID,
  customer_id   UUID,
  rating        INT,
  nps           INT,
  comment       TEXT,
  created_ts    TIMESTAMPTZ
);