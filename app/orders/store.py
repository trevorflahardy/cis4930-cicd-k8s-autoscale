from typing import Protocol

from sqlalchemy import URL, create_engine, func, select, text, update
from sqlalchemy.orm import sessionmaker

from orders.db import OrderRecord
from orders.models import Order, OrderIn


class OrderStore(Protocol):
    def ping(self) -> None: ...
    def create(self, order: OrderIn, total_cents: int, signature: str) -> Order: ...
    def get(self, order_id: int) -> Order | None: ...
    def mark_processed(self, order_id: int, worker: str) -> bool: ...
    def status_counts(self) -> dict[str, int]: ...
    def close(self) -> None: ...


class SqlAlchemyStore:
    """OrderStore backed by Postgres through the SQLAlchemy ORM."""

    def __init__(self, database_url: str | URL, pool_size: int = 4) -> None:
        self.engine = create_engine(
            database_url,
            pool_size=pool_size,
            max_overflow=2,
            pool_timeout=5,
            pool_pre_ping=True,
            connect_args={"connect_timeout": 3},
        )
        self._sessions = sessionmaker(self.engine, expire_on_commit=False)

    def ping(self) -> None:
        with self.engine.connect() as conn:
            conn.execute(text("SELECT 1"))

    def create(self, order: OrderIn, total_cents: int, signature: str) -> Order:
        record = OrderRecord(
            **order.model_dump(), total_cents=total_cents, price_signature=signature
        )
        with self._sessions.begin() as session:
            session.add(record)
        return Order.model_validate(record)

    def get(self, order_id: int) -> Order | None:
        with self._sessions() as session:
            record = session.get(OrderRecord, order_id)
            return Order.model_validate(record) if record else None

    def mark_processed(self, order_id: int, worker: str) -> bool:
        stmt = (
            update(OrderRecord)
            .where(OrderRecord.id == order_id, OrderRecord.status == "pending")
            .values(status="processed", processed_at=func.now(), processed_by=worker)
        )
        with self._sessions.begin() as session:
            return session.execute(stmt).rowcount == 1

    def status_counts(self) -> dict[str, int]:
        stmt = select(OrderRecord.status, func.count()).group_by(OrderRecord.status)
        with self._sessions() as session:
            return {status: count for status, count in session.execute(stmt).all()}

    def close(self) -> None:
        self.engine.dispose()
