import os
from dataclasses import dataclass

from sqlalchemy.engine import URL


@dataclass(frozen=True)
class Settings:
    pg_host: str = "localhost"
    pg_port: int = 5432
    pg_db: str = "orders"
    pg_user: str = "orders"
    pg_password: str = ""
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_password: str | None = None
    cache_ttl_seconds: int = 60
    pricing_iterations: int = 50_000
    worker_work_ms: int = 200
    app_version: str = "dev"

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ.get
        return cls(
            pg_host=env("PG_HOST", cls.pg_host),
            pg_port=int(env("PG_PORT", str(cls.pg_port))),
            pg_db=env("PG_DB", cls.pg_db),
            pg_user=env("PG_USER", cls.pg_user),
            pg_password=env("PG_PASSWORD", cls.pg_password),
            redis_host=env("REDIS_HOST", cls.redis_host),
            redis_port=int(env("REDIS_PORT", str(cls.redis_port))),
            redis_password=env("REDIS_PASSWORD") or None,
            cache_ttl_seconds=int(env("CACHE_TTL_SECONDS", str(cls.cache_ttl_seconds))),
            pricing_iterations=int(env("PRICING_ITERATIONS", str(cls.pricing_iterations))),
            worker_work_ms=int(env("WORKER_WORK_MS", str(cls.worker_work_ms))),
            app_version=env("APP_VERSION", cls.app_version),
        )

    @property
    def database_url(self) -> URL:
        return URL.create(
            "postgresql+psycopg",
            username=self.pg_user,
            password=self.pg_password,
            host=self.pg_host,
            port=self.pg_port,
            database=self.pg_db,
        )
