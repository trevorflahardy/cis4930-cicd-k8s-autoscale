import logging
import socket
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from redis import Redis

from orders.config import Settings
from orders.models import Order, OrderIn
from orders.pricing import price_order
from orders.queue import OrderCache, OrderQueue, connect_redis
from orders.store import OrderStore, SqlAlchemyStore

log = logging.getLogger("orders.api")
POD_NAME = socket.gethostname()


def create_app(
    settings: Settings | None = None,
    store: OrderStore | None = None,
    redis: Redis | None = None,
) -> FastAPI:
    cfg = settings or Settings.from_env()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.store = store or SqlAlchemyStore(cfg.database_url)
        app.state.redis = redis or connect_redis(cfg)
        app.state.cache = OrderCache(app.state.redis, cfg.cache_ttl_seconds)
        app.state.queue = OrderQueue(app.state.redis)
        yield
        if store is None:
            app.state.store.close()
        if redis is None:
            app.state.redis.close()

    app = FastAPI(title="Orders API", version=cfg.app_version, lifespan=lifespan)

    @app.middleware("http")
    async def served_by(request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Served-By"] = POD_NAME
        return response

    @app.get("/")
    def index() -> dict:
        return {"service": "orders-api", "version": cfg.app_version, "pod": POD_NAME}

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    @app.get("/ready")
    def ready(request: Request) -> JSONResponse:
        checks = {}
        try:
            request.app.state.store.ping()
            checks["postgres"] = "ok"
        except Exception as exc:
            checks["postgres"] = f"error: {exc.__class__.__name__}"
        try:
            request.app.state.redis.ping()
            checks["redis"] = "ok"
        except Exception as exc:
            checks["redis"] = f"error: {exc.__class__.__name__}"
        healthy = all(v == "ok" for v in checks.values())
        return JSONResponse(
            {"status": "ready" if healthy else "not-ready", "checks": checks},
            status_code=status.HTTP_200_OK if healthy else status.HTTP_503_SERVICE_UNAVAILABLE,
        )

    @app.post("/orders", status_code=status.HTTP_201_CREATED)
    def create_order(payload: OrderIn, request: Request) -> Order:
        total, signature = price_order(payload, cfg.pricing_iterations)
        order = request.app.state.store.create(payload, total, signature)
        request.app.state.cache.set(order)
        request.app.state.queue.push(order.id)
        return order

    @app.get("/orders/{order_id}")
    def get_order(order_id: int, request: Request, response: Response) -> Order:
        cached = request.app.state.cache.get(order_id)
        if cached:
            response.headers["X-Cache"] = "HIT"
            return cached
        order = request.app.state.store.get(order_id)
        if order is None:
            raise HTTPException(status_code=404, detail="order not found")
        request.app.state.cache.set(order)
        response.headers["X-Cache"] = "MISS"
        return order

    @app.get("/stats")
    def stats(request: Request) -> dict:
        counts = request.app.state.store.status_counts()
        queue: OrderQueue = request.app.state.queue
        return {
            "orders": counts,
            "orders_total": sum(counts.values()),
            "queue_depth": queue.depth(),
            "processed_total": queue.processed_total(),
            "pod": POD_NAME,
        }

    return app


app = create_app()
