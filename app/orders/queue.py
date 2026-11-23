from redis import Redis

from orders.config import Settings
from orders.models import Order

QUEUE_KEY = "orders:queue"
PROCESSED_KEY = "orders:processed_total"


def _cache_key(order_id: int) -> str:
    return f"order:{order_id}"


class OrderCache:
    """Read-through cache for order lookups."""

    def __init__(self, redis: Redis, ttl_seconds: int) -> None:
        self._redis = redis
        self._ttl = ttl_seconds

    def get(self, order_id: int) -> Order | None:
        raw = self._redis.get(_cache_key(order_id))
        return Order.model_validate_json(raw) if raw else None

    def set(self, order: Order) -> None:
        self._redis.set(_cache_key(order.id), order.model_dump_json(), ex=self._ttl)

    def invalidate(self, order_id: int) -> None:
        self._redis.delete(_cache_key(order_id))


class OrderQueue:
    """FIFO work queue. Its length is the signal KEDA uses to scale the worker Deployment."""

    def __init__(self, redis: Redis) -> None:
        self._redis = redis

    def push(self, order_id: int) -> None:
        self._redis.lpush(QUEUE_KEY, order_id)

    def pop(self, timeout: int) -> int | None:
        item = self._redis.brpop([QUEUE_KEY], timeout=timeout)
        return int(item[1]) if item else None

    def depth(self) -> int:
        return int(self._redis.llen(QUEUE_KEY))

    def record_processed(self) -> None:
        self._redis.incr(PROCESSED_KEY)

    def processed_total(self) -> int:
        return int(self._redis.get(PROCESSED_KEY) or 0)


def connect_redis(settings: Settings) -> Redis:
    return Redis(
        host=settings.redis_host,
        port=settings.redis_port,
        password=settings.redis_password,
        decode_responses=True,
        socket_timeout=5,
        socket_connect_timeout=3,
    )
