// k6 러너 공통 코드. 시나리오 파일은 이 모듈만 import 해서 쓴다.
// 환경변수(measure.sh 가 bench.config.yml 에서 넘김): BASE_URL, RATE, WARMUP_SECONDS, STEADY_SECONDS, PRE_VUS, MAX_VUS, SEED
import http from 'k6/http';
import { Counter } from 'k6/metrics';

export const BASE_URL = __ENV.BASE_URL || 'http://app:8080';

export const cfg = {
  rate: Number(__ENV.RATE || 50),                 // 초당 도착률 (open model)
  warmup: Number(__ENV.WARMUP_SECONDS || 30),     // 워밍업 구간. 집계에서 버린다
  steady: Number(__ENV.STEADY_SECONDS || 60),     // steady state. 이 구간만 집계
  preAllocatedVUs: Number(__ENV.PRE_VUS || 50),
  maxVUs: Number(__ENV.MAX_VUS || 200),
  seed: Number(__ENV.SEED || 42),
  timeout: __ENV.HTTP_TIMEOUT || '10s',
};

// 에러 분류 카운터 (study-spec 6장: 5xx·타임아웃·연결 실패 = 에러, 4xx = 스크립트 버그 → 회차 무효)
export const errors5xx = new Counter('errors_5xx');
export const errors4xx = new Counter('errors_4xx');
export const errorsTimeout = new Counter('errors_timeout');
export const errorsConn = new Counter('errors_conn');

export function classify(res) {
  if (res.status === 0) {
    // k6 error_code: 1050 = request timeout, 그 외 0 status 는 연결 실패(DNS, dial, reset 등)
    if (res.error_code === 1050) errorsTimeout.add(1); else errorsConn.add(1);
    return 'conn';
  }
  if (res.status >= 500) { errors5xx.add(1); return '5xx'; }
  if (res.status >= 400) { errors4xx.add(1); return '4xx'; }
  return 'ok';
}

// 결정적 난수 (mulberry32). VU 마다 seed + __VU 로 시작해 재현 가능한 키 분포를 만든다
export function makeRng(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function get(path, name, extraParams) {
  const params = Object.assign({ tags: { name: name || path }, timeout: cfg.timeout }, extraParams || {});
  const res = http.get(`${BASE_URL}${path}`, params);
  classify(res);
  return res;
}

// 워밍업/측정 시나리오 두 개. 같은 exec 함수를 쓰고 scenario 태그로 구분한다.
// warmup 이 끝나는 시각에 steady 가 시작한다. 워밍업의 진행 중 요청은 gracefulStop 동안 마무리되며 scenario=warmup 태그를 유지한다.
export function arrivalScenarios(execName) {
  const common = {
    executor: 'constant-arrival-rate',
    rate: cfg.rate,
    timeUnit: '1s',
    preAllocatedVUs: cfg.preAllocatedVUs,
    maxVUs: cfg.maxVUs,
    exec: execName,
  };
  return {
    warmup: Object.assign({}, common, { startTime: '0s', duration: `${cfg.warmup}s`, gracefulStop: '10s', tags: { phase: 'warmup' } }),
    steady: Object.assign({}, common, { startTime: `${cfg.warmup}s`, duration: `${cfg.steady}s`, gracefulStop: '10s', tags: { phase: 'steady' } }),
  };
}

// 요약 JSON 에 steady 구간만의 서브메트릭이 생기도록 항상 통과하는 threshold 를 건다.
// names: 엔드포인트 name 태그 목록 (엔드포인트별 지연 분리용)
export function steadyThresholds(names) {
  const t = {
    'http_reqs{scenario:steady}': ['count>=0'],
    'http_req_duration{scenario:steady}': ['p(99)>=0'],
    'http_req_failed{scenario:steady}': ['rate>=0'],
    'iterations{scenario:steady}': ['count>=0'],
    'dropped_iterations{scenario:steady}': ['count>=0'],
    'dropped_iterations{scenario:warmup}': ['count>=0'],
    'errors_5xx{scenario:steady}': ['count>=0'],
    'errors_4xx{scenario:steady}': ['count>=0'],
    'errors_timeout{scenario:steady}': ['count>=0'],
    'errors_conn{scenario:steady}': ['count>=0'],
    'errors_4xx': ['count>=0'],
    'dropped_iterations': ['count>=0'],
  };
  (names || []).forEach((n) => {
    t[`http_req_duration{scenario:steady,name:${n}}`] = ['p(99)>=0'];
    t[`http_reqs{scenario:steady,name:${n}}`] = ['count>=0'];
    t[`http_req_failed{scenario:steady,name:${n}}`] = ['rate>=0'];
  });
  return t;
}

export const summaryOptions = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(95)', 'p(99)'],
  summaryTimeUnit: 'ms',
  // 시스템 태그에 scenario·name 이 있어야 서브메트릭이 나뉜다 (기본값에 포함되어 있지만 명시)
  systemTags: ['proto', 'subproto', 'status', 'method', 'url', 'name', 'group', 'check', 'error', 'error_code', 'tls_version', 'scenario', 'service', 'expected_response'],
};
