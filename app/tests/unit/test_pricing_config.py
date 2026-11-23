from orders.config import Settings
from orders.models import OrderIn
from orders.pricing import price_order


def test_price_is_quantity_times_unit_price():
    total, _ = price_order(OrderIn(customer="a", item="b", quantity=4, unit_price_cents=99), 10)
    assert total == 396


def test_signature_is_deterministic_and_tamper_evident():
    base = OrderIn(customer="a", item="b", quantity=1, unit_price_cents=100)
    changed = base.model_copy(update={"unit_price_cents": 101})
    assert price_order(base, 10)[1] == price_order(base, 10)[1]
    assert price_order(base, 10)[1] != price_order(changed, 10)[1]


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("PG_HOST", "postgres")
    monkeypatch.setenv("REDIS_PORT", "6380")
    monkeypatch.setenv("REDIS_PASSWORD", "")
    monkeypatch.setenv("PRICING_ITERATIONS", "7")
    s = Settings.from_env()
    assert s.pg_host == "postgres"
    assert s.redis_port == 6380
    assert s.redis_password is None
    assert s.pricing_iterations == 7


def test_database_url_escapes_credentials():
    url = Settings(pg_password="p@ss/w:rd", pg_host="db").database_url
    assert url.drivername == "postgresql+psycopg"
    assert url.password == "p@ss/w:rd"
    assert "p@ss/w:rd" not in url.render_as_string(hide_password=True)
    assert url.host == "db"
