"""Run Alembic migrations to head. Executed as a Kubernetes Job before the API rolls out.

Retries the database connection so the Job tolerates Postgres still starting up.
"""

import logging
import sys
import time
from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text

from orders.config import Settings

log = logging.getLogger("orders.migrate")
ALEMBIC_INI = Path(__file__).resolve().parent.parent / "alembic.ini"


def wait_for_database(url: str, attempts: int) -> None:
    engine = create_engine(url, connect_args={"connect_timeout": 3})
    try:
        for attempt in range(1, attempts + 1):
            try:
                with engine.connect() as conn:
                    conn.execute(text("SELECT 1"))
                return
            except Exception as exc:
                log.warning("database not reachable (%d/%d): %s", attempt, attempts, exc)
                time.sleep(2)
        raise RuntimeError("database never became reachable")
    finally:
        engine.dispose()


def main(attempts: int = 30) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    settings = Settings.from_env()
    wait_for_database(settings.database_url, attempts)
    command.upgrade(Config(str(ALEMBIC_INI)), "head")
    log.info("migrations applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
