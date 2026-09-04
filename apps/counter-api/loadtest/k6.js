// k6 load test: sustained 5000 requests/second against counter-api.
//
//   k6 run loadtest/k6.js
//   BASE_URL=http://localhost:8080 RATE=5000 DURATION=60s k6 run loadtest/k6.js
//
// The default scenario is a constant-arrival-rate generator: k6 launches new
// requests at RATE/s regardless of how fast responses come back, so a slow
// server shows up as a growing queue / dropped iterations rather than a
// silently lowered throughput.
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const RATE = parseInt(__ENV.K6_VUS || '15000', 10);
const DURATION = __ENV.K6_DURATION || '60s';

const errors = new Rate('business_errors');

export const options = {
  scenarios: {
    steady_5k: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.ceil(RATE / 5),
      maxVUs: RATE * 2,
      exec: 'hitTags',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.001'],       // <0.1% transport errors
    business_errors: ['rate<0.001'],       // <0.1% non-200 bodies
    http_req_duration: ['p(95)<50', 'p(99)<150'],
    dropped_iterations: ['count<1'],       // arrival rate was actually sustained
  },
};

// 90% list endpoint, 10% single-id endpoint - both served from the cache.
export function hitTags() {
  const single = Math.random() < 0.1;
  const url = single
    ? `${BASE_URL}/v1/tags/${Math.floor(Math.random() * 10)}`
    : `${BASE_URL}/v1/tags`;
  const res = http.get(url);
  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'has body': (r) => r.body && r.body.length > 0,
  });
  errors.add(!ok);
}
