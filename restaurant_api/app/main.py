import asyncio
import contextlib
import json
import random
import uuid
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import AsyncGenerator, Dict

from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse, StreamingResponse

# ---------------- Core in-memory store ----------------
MAX_EVENTS = 100_000
EVENTS = deque(maxlen=MAX_EVENTS)  # each is a dict event
NEXT_OFFSET = 0
QUEUE: "asyncio.Queue[dict]" = asyncio.Queue()
PRODUCER_TASK: asyncio.Task | None = None


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def weighted_choice(items):
    xs, ws = zip(*items)
    return random.choices(xs, weights=ws, k=1)[0]


CATEGORIES = [
    ("coffee", 5),
    ("breakfast", 7),
    ("appetizer", 8),
    ("salad", 7),
    ("sandwich", 8),
    ("burger", 10),
    ("pizza", 8),
    ("pasta", 7),
    ("entree", 18),
    ("dessert", 6),
    ("kids", 3),
    ("beverage", 7),
    ("alcohol", 6),
]


def price_for_category(cat: str) -> float:
    ranges = {
        "coffee": (2.25, 6.0),
        "breakfast": (8.0, 16.0),
        "appetizer": (7.0, 16.0),
        "salad": (9.0, 19.0),
        "sandwich": (10.0, 19.0),
        "burger": (12.0, 22.0),
        "pizza": (12.0, 26.0),
        "pasta": (12.0, 26.0),
        "entree": (15.0, 40.0),
        "dessert": (5.0, 12.0),
        "kids": (7.0, 12.0),
        "beverage": (2.0, 6.0),
        "alcohol": (6.0, 16.0),
    }
    low, high = ranges[cat]
    return round(random.uniform(low, high), 2)


def time_of_day_bucket(ts: datetime) -> str:
    h = ts.hour
    if 6 <= h < 11:
        return "morning"
    if 11 <= h < 15:
        return "midday"
    if 17 <= h < 23:
        return "evening"
    return "other"


def category_boosted_choice(ts: datetime) -> str:
    bucket = time_of_day_bucket(ts)
    base = dict(CATEGORIES)
    boosts = {
        "morning": {"coffee": 1.8, "breakfast": 1.6, "dessert": 0.6, "alcohol": 0.2},
        "midday": {"salad": 1.3, "sandwich": 1.4, "pizza": 1.1, "beverage": 1.2},
        "evening": {
            "entree": 1.7,
            "pasta": 1.5,
            "burger": 1.3,
            "alcohol": 1.6,
            "dessert": 1.2,
        },
        "other": {},
    }[bucket]
    pairs = [(k, w * boosts.get(k, 1.0)) for k, w in base.items()]
    return weighted_choice(pairs)


def make_event(event_type: str, payload: Dict, partition_key: str) -> Dict:
    global NEXT_OFFSET
    NEXT_OFFSET += 1
    return {
        "offset": NEXT_OFFSET,
        "event_id": str(uuid.uuid4()),
        "event_type": event_type,
        "ts": now_utc().isoformat(),
        "partition_key": partition_key,
        "payload": payload,
    }


def order_financials(items) -> Dict:
    subtotal = round(sum(i["unit_price"] * i["qty"] for i in items), 2)
    tax = round(subtotal * 0.13, 2)  # Ontario HST
    return {"subtotal": subtotal, "tax": tax}


def rnd_location() -> str:
    return f"LOC-ON-{random.randint(1, 12):03d}"


def generate_order_flow(ts: datetime, location_code: str):
    visit_id = uuid.uuid4()
    order_id = uuid.uuid4()
    service_type = weighted_choice([("dine_in", 62), ("takeout", 23), ("delivery", 15)])
    events = [
        make_event(
            "order_created",
            {
                "order_id": str(order_id),
                "visit_id": str(visit_id),
                "service_type": service_type,
                "order_ts": ts.isoformat(),
                "location_code": location_code,
            },
            location_code,
        )
    ]
    # items
    n_items = random.choices([1, 2, 3, 4], [60, 28, 9, 3], k=1)[0]
    items = []
    for _ in range(n_items):
        cat = category_boosted_choice(ts)
        unit = price_for_category(cat)
        qty = random.choices([1, 2, 3], [85, 12, 3], k=1)[0]
        itm = {
            "order_item_id": str(uuid.uuid4()),
            "order_id": str(order_id),
            "menu_item_id": str(uuid.uuid4()),
            "category": cat,
            "item_name": f"{cat.title()} {random.randint(1, 99)}",
            "unit_price": unit,
            "qty": qty,
            "extended_price": round(unit * qty, 2),
        }
        items.append(itm)
        events.append(make_event("order_item_added", itm, location_code))
    fin = order_financials(items)
    tip_rate = {
        "dine_in": random.uniform(0.12, 0.24),
        "takeout": random.choices([0.0, 0.06, 0.10], [70, 20, 10], k=1)[0],
        "delivery": random.uniform(0.08, 0.20),
    }[service_type]
    tip = round(fin["subtotal"] * tip_rate, 2)
    total = round(fin["subtotal"] + fin["tax"] + tip, 2)
    method = weighted_choice(
        [
            ("credit_card", 52),
            ("debit", 18),
            ("cash", 14),
            ("digital_wallet", 12),
            ("gift_card", 4),
        ]
    )
    provider = {
        "credit_card": weighted_choice(
            [("VISA", 48), ("Mastercard", 42), ("Amex", 10)]
        ),
        "debit": "Interac",
        "cash": None,
        "digital_wallet": weighted_choice([("Apple Pay", 65), ("Google Pay", 35)]),
        "gift_card": "Gift Card",
    }[method]
    events.append(
        make_event(
            "payment_captured",
            {
                "payment_id": str(uuid.uuid4()),
                "order_id": str(order_id),
                "method": method,
                "provider": provider,
                "amount": total,
                "auth_code": (
                    None
                    if method in ("cash", "gift_card")
                    else f"{uuid.uuid4().hex[:6].upper()}"
                ),
                "subtotal": fin["subtotal"],
                "tax": fin["tax"],
                "tip": tip,
                "total": total,
                "location_code": location_code,
            },
            location_code,
        )
    )
    if random.random() < 0.25:
        rating = random.choices([1, 2, 3, 4, 5], [4, 6, 20, 36, 34])[0]
        nps = {
            1: random.randint(0, 6),
            2: random.randint(0, 6),
            3: random.randint(4, 8),
            4: random.randint(7, 10),
            5: random.randint(8, 10),
        }[rating]
        events.append(
            make_event(
                "feedback_submitted",
                {
                    "feedback_id": str(uuid.uuid4()),
                    "order_id": str(order_id),
                    "customer_id": str(uuid.uuid4()),
                    "rating": rating,
                    "nps": nps,
                    "comment": None,
                    "created_ts": (
                        ts + timedelta(hours=random.uniform(1, 168))
                    ).isoformat(),
                },
                location_code,
            )
        )
    return events


async def producer():
    """Generate events continuously with diurnal volume variation."""
    while True:
        ts = now_utc()
        tod = time_of_day_bucket(ts)
        base = {"morning": 1, "midday": 2, "evening": 3, "other": 1}[tod]
        n_orders = max(1, int(random.gauss(mu=base, sigma=0.7)))
        for _ in range(n_orders):
            loc = rnd_location()
            for e in generate_order_flow(ts, loc):
                EVENTS.append(e)
                await QUEUE.put(e)
        sleep_s = {"morning": 1.2, "midday": 0.9, "evening": 0.6, "other": 1.5}[tod]
        await asyncio.sleep(random.uniform(sleep_s * 0.6, sleep_s * 1.4))


@asynccontextmanager
async def lifespan(app: FastAPI):
    global PRODUCER_TASK
    PRODUCER_TASK = asyncio.create_task(producer())
    try:
        yield
    finally:
        if PRODUCER_TASK:
            PRODUCER_TASK.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await PRODUCER_TASK


app = FastAPI(title="Restaurant Streaming API", version="1.0", lifespan=lifespan)


# ---------------- Endpoints ----------------
@app.get("/health")
def health():
    return {"status": "ok", "stored": len(EVENTS)}


@app.get("/events")
def get_events(
    since: int = Query(0, ge=0, description="Return events with offset > since"),
    limit: int = Query(1000, ge=1, le=5000),
):
    items = [e for e in EVENTS if e["offset"] > since][:limit]
    next_since = items[-1]["offset"] if items else since
    return JSONResponse({"events": items, "next_since": next_since})


@app.get("/stream")
async def stream() -> StreamingResponse:
    async def event_source() -> AsyncGenerator[bytes, None]:
        while True:
            e = await QUEUE.get()
            yield f"id: {e['offset']}\nevent: {e['event_type']}\ndata: {json.dumps(e, separators=(',', ':'))}\n\n".encode()

    return StreamingResponse(event_source(), media_type="text/event-stream")
