import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// Custom metrics
const errorRate   = new Rate('error_rate');
const reqDuration = new Trend('request_duration', true);
const reqCount    = new Counter('request_count');

// Options driven entirely by CLI flags (--vus / --duration)
// No `scenarios` block here — avoids the override warning
export const options = {
  thresholds: {
    http_req_failed:   ['rate<0.05'],   // < 5% errors
    http_req_duration: ['p(95)<2000'],  // 95th percentile < 2s
    error_rate:        ['rate<0.05'],
  },
};

export default function () {
  const url = __ENV.TARGET_URL;

  const res = http.get(url, {
    headers: {
      'Content-Type': 'application/json',
      'Accept':       'application/json',
    },
    timeout: '10s',
  });

  // Track custom metrics
  reqCount.add(1);
  reqDuration.add(res.timings.duration);
  errorRate.add(res.status >= 400);

  // Assertions
  check(res, {
    'status is 200':       (r) => r.status === 200,
    'response time < 2s':  (r) => r.timings.duration < 2000,
    'body is not empty':   (r) => r.body && r.body.length > 0,
  });

  sleep(1);
}
