from orders.queue import OrderCache, OrderQueue
from orders.worker import process_one


def test_worker_processes_order_and_invalidates_cache(client, store, redis, order_payload):
    order_id = client.post("/orders", json=order_payload).json()["id"]
    cache, queue = OrderCache(redis, 60), OrderQueue(redis)

    assert process_one(store, cache, queue, "worker-1", work_ms=0, timeout=1) == order_id

    assert store.get(order_id).status == "processed"
    assert store.get(order_id).processed_by == "worker-1"
    assert queue.depth() == 0
    assert queue.processed_total() == 1
    assert cache.get(order_id) is None

    fresh = client.get(f"/orders/{order_id}")
    assert fresh.headers["X-Cache"] == "MISS"
    assert fresh.json()["status"] == "processed"


def test_worker_returns_none_on_empty_queue(store, redis):
    assert process_one(store, OrderCache(redis, 60), OrderQueue(redis), "w", 0, timeout=1) is None


def test_worker_is_idempotent_for_duplicate_messages(client, store, redis, order_payload):
    order_id = client.post("/orders", json=order_payload).json()["id"]
    queue = OrderQueue(redis)
    queue.push(order_id)  # duplicate delivery
    cache = OrderCache(redis, 60)

    process_one(store, cache, queue, "w", 0, timeout=1)
    process_one(store, cache, queue, "w", 0, timeout=1)

    assert queue.processed_total() == 1


def test_queue_is_fifo(redis):
    queue = OrderQueue(redis)
    for i in (1, 2, 3):
        queue.push(i)
    assert [queue.pop(1) for _ in range(3)] == [1, 2, 3]
