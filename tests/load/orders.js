// k6 load profile: a burst of mock client traffic against the orders API.
// ~70% of iterations create orders (CPU-heavy pricing + enqueue), ~30% read them back.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://orders-control-plane:30080';
const RATE = Number(__ENV.RATE || 40);
const HOLD = __ENV.HOLD || '90s';

export const options = {
  scenarios: {
    client_spike: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 300,
      stages: [
        { target: RATE, duration: '20s' },
        { target: RATE, duration: HOLD },
        { target: 0, duration: '10s' },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],
    checks: ['rate>0.98'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'max'],
};

const headers = { 'Content-Type': 'application/json' };
const items = ['widget', 'gadget', 'sprocket', 'gizmo'];

export default function () {
  if (Math.random() < 0.7) {
    const body = JSON.stringify({
      customer: `vu-${__VU}`,
      item: items[__ITER % items.length],
      quantity: 1 + (__ITER % 5),
      unit_price_cents: 199 + (__VU % 50),
    });
    const res = http.post(`${BASE_URL}/orders`, body, { headers, tags: { name: 'POST /orders' } });
    check(res, { 'order created': (r) => r.status === 201 });
  } else {
    const id = 1 + Math.floor(Math.random() * 50);
    const res = http.get(`${BASE_URL}/orders/${id}`, { tags: { name: 'GET /orders/:id' } });
    check(res, { 'order read': (r) => r.status === 200 || r.status === 404 });
  }
}

export function handleSummary(data) {
  return { '/out/k6-summary.json': JSON.stringify(data, null, 2) };
}
