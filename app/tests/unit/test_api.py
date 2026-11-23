def test_index_reports_version_and_pod(client):
    body = client.get("/").json()
    assert body["service"] == "orders-api"
    assert body["version"] == "test-sha"
    assert body["pod"]


def test_health_is_dependency_free(client, store):
    store.healthy = False
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_ready_ok_when_dependencies_up(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.json()["checks"] == {"postgres": "ok", "redis": "ok"}


def test_ready_503_when_postgres_down(client, store):
    store.healthy = False
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.json()["checks"]["postgres"].startswith("error")


def test_every_response_names_the_serving_pod(client):
    assert client.get("/health").headers["X-Served-By"]


def test_create_order_prices_queues_and_caches(client, redis, order_payload):
    resp = client.post("/orders", json=order_payload)
    assert resp.status_code == 201
    order = resp.json()
    assert order["total_cents"] == 750
    assert order["status"] == "pending"
    assert len(order["price_signature"]) == 32
    assert redis.llen("orders:queue") == 1
    assert redis.exists(f"order:{order['id']}")


def test_get_order_cache_hit_then_miss_after_invalidation(client, redis, order_payload):
    order_id = client.post("/orders", json=order_payload).json()["id"]

    hit = client.get(f"/orders/{order_id}")
    assert hit.status_code == 200
    assert hit.headers["X-Cache"] == "HIT"

    redis.delete(f"order:{order_id}")
    miss = client.get(f"/orders/{order_id}")
    assert miss.headers["X-Cache"] == "MISS"
    assert miss.json()["id"] == order_id
    assert client.get(f"/orders/{order_id}").headers["X-Cache"] == "HIT"


def test_get_missing_order_404(client):
    assert client.get("/orders/9999").status_code == 404


def test_invalid_order_rejected(client, order_payload):
    order_payload["quantity"] = 0
    assert client.post("/orders", json=order_payload).status_code == 422


def test_stats_reports_counts_and_queue_depth(client, order_payload):
    for _ in range(3):
        client.post("/orders", json=order_payload)
    stats = client.get("/stats").json()
    assert stats["orders_total"] == 3
    assert stats["orders"] == {"pending": 3}
    assert stats["queue_depth"] == 3
    assert stats["processed_total"] == 0
