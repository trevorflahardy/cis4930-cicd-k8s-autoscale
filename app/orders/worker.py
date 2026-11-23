"""Queue worker: drains orders:queue and marks orders processed.

Run with `python -m orders.worker`. KEDA scales this Deployment on the Redis list length.
"""

import logging
import signal
import socket
import time
from types import FrameType

from orders.config import Settings
from orders.queue import OrderCache, OrderQueue, connect_redis
from orders.store import OrderStore, SqlAlchemyStore

log = logging.getLogger("orders.worker")


def process_one(
    store: OrderStore,
    cache: OrderCache,
    queue: OrderQueue,
    worker_id: str,
    work_ms: int,
    timeout: int = 5,
) -> int | None:
    """Pop and process a single order. Returns the order id, or None if the queue was empty."""
    order_id = queue.pop(timeout)
    if order_id is None:
        return None
    time.sleep(work_ms / 1000)  # simulated fulfillment call (payment, inventory, shipping)
    if store.mark_processed(order_id, worker_id):
        cache.invalidate(order_id)
        queue.record_processed()
    return order_id


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    settings = Settings.from_env()
    worker_id = socket.gethostname()
    store = SqlAlchemyStore(settings.database_url, pool_size=2)
    redis = connect_redis(settings)
    cache = OrderCache(redis, settings.cache_ttl_seconds)
    queue = OrderQueue(redis)

    running = True

    def stop(signum: int, _frame: FrameType | None) -> None:
        nonlocal running
        log.info("received signal %s, finishing current order", signum)
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("worker %s started (work_ms=%s)", worker_id, settings.worker_work_ms)
    processed = 0
    while running:
        try:
            if process_one(store, cache, queue, worker_id, settings.worker_work_ms, timeout=2):
                processed += 1
                if processed % 50 == 0:
                    log.info("processed %d orders", processed)
        except Exception:
            log.exception("error processing order; retrying")
            time.sleep(1)
    store.close()
    redis.close()
    log.info("worker %s stopped after %d orders", worker_id, processed)


if __name__ == "__main__":
    main()
