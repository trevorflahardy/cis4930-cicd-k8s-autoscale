"""Exercise the real SqlAlchemyStore and Redis. CI runs these against service containers."""

import os
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient

from orders.config import Settings
from orders.main import create_app
from orders.queue import OrderCache, OrderQueue, connect_redis
from orders.store import SqlAlchemyStore
from orders.worker import process_one

ALEMBIC_INI = Path(__file__).resolve().parents[2] / "alembic.ini"

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not os.environ.get("PG_HOST"), reason="PG_HOST not set"),
]


@pytest.fixture
def settings() -> Settings:
    return Settings.from_env()


@pytest.fixture
def pg(settings):
    command.upgrade(Config(str(ALEMBIC_INI)), "head")
    store = SqlAlchemyStore(settings.database_url)
    yield store
    store.close()


@pytest.fixture
def real_redis(settings):
    r = connect_redis(settings)
    r.flushdb()
    yield r
    r.close()


def test_order_lifecycle_against_real_services(settings, pg, real_redis):
    with TestClient(create_app(settings=settings, store=pg, redis=real_redis)) as client:
        assert client.get("/ready").status_code == 200

        payload = {"customer": "grace", "item": "gear", "quantity": 2, "unit_price_cents": 500}
        order = client.post("/orders", json=payload).json()
        assert order["total_cents"] == 1000

        persisted = pg.get(order["id"])
        assert persisted is not None
        assert persisted.price_signature == order["price_signature"]

        cache, queue = OrderCache(real_redis, 60), OrderQueue(real_redis)
        assert process_one(pg, cache, queue, "it-worker", work_ms=0, timeout=2) == order["id"]

        fetched = client.get(f"/orders/{order['id']}")
        assert fetched.headers["X-Cache"] == "MISS"
        assert fetched.json()["status"] == "processed"
        assert fetched.json()["processed_by"] == "it-worker"
        assert pg.status_counts().get("processed", 0) >= 1


def test_migrations_round_trip(pg):
    cfg = Config(str(ALEMBIC_INI))
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    command.check(cfg)  # raises if ORM models and migrations disagree
