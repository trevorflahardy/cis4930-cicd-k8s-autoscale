from datetime import UTC, datetime

import fakeredis
import pytest
from fastapi.testclient import TestClient

from orders.config import Settings
from orders.main import create_app
from orders.models import Order, OrderIn


class InMemoryStore:
    """Test double that satisfies the OrderStore protocol."""

    def __init__(self) -> None:
        self.orders: dict[int, Order] = {}
        self.healthy = True

    def ping(self) -> None:
        if not self.healthy:
            raise ConnectionError("postgres down")

    def create(self, order: OrderIn, total_cents: int, signature: str) -> Order:
        new = Order(
            id=len(self.orders) + 1,
            total_cents=total_cents,
            price_signature=signature,
            status="pending",
            created_at=datetime.now(UTC),
            **order.model_dump(),
        )
        self.orders[new.id] = new
        return new

    def get(self, order_id: int) -> Order | None:
        return self.orders.get(order_id)

    def mark_processed(self, order_id: int, worker: str) -> bool:
        order = self.orders.get(order_id)
        if order is None or order.status != "pending":
            return False
        self.orders[order_id] = order.model_copy(
            update={
                "status": "processed",
                "processed_by": worker,
                "processed_at": datetime.now(UTC),
            }
        )
        return True

    def status_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for o in self.orders.values():
            counts[o.status] = counts.get(o.status, 0) + 1
        return counts

    def close(self) -> None:
        pass


@pytest.fixture
def settings() -> Settings:
    return Settings(pricing_iterations=10, app_version="test-sha")


@pytest.fixture
def store() -> InMemoryStore:
    return InMemoryStore()


@pytest.fixture
def redis() -> fakeredis.FakeRedis:
    return fakeredis.FakeRedis(decode_responses=True)


@pytest.fixture
def client(settings, store, redis):
    with TestClient(create_app(settings=settings, store=store, redis=redis)) as c:
        yield c


@pytest.fixture
def order_payload() -> dict:
    return {"customer": "ada", "item": "widget", "quantity": 3, "unit_price_cents": 250}
