import hashlib

from orders.models import OrderIn


def price_order(order: OrderIn, iterations: int) -> tuple[int, str]:
    """Compute the order total and a tamper-evident price signature.

    The PBKDF2 key stretch is deliberately CPU-heavy: it stands in for real per-request work
    (fraud scoring, tax rules, pricing engines) so client load turns into CPU load that the
    Kubernetes HorizontalPodAutoscaler can react to.
    """
    total = order.quantity * order.unit_price_cents
    payload = f"{order.customer}|{order.item}|{order.quantity}|{order.unit_price_cents}|{total}"
    digest = hashlib.pbkdf2_hmac("sha256", payload.encode(), b"orders-pricing", iterations)
    return total, digest.hex()[:32]
