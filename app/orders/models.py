from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

OrderStatus = Literal["pending", "processed"]


class OrderIn(BaseModel):
    customer: str = Field(min_length=1, max_length=64)
    item: str = Field(min_length=1, max_length=64)
    quantity: int = Field(ge=1, le=1000)
    unit_price_cents: int = Field(ge=0, le=1_000_000)


class Order(OrderIn):
    model_config = ConfigDict(from_attributes=True)

    id: int
    total_cents: int
    price_signature: str
    status: OrderStatus
    created_at: datetime
    processed_at: datetime | None = None
    processed_by: str | None = None
