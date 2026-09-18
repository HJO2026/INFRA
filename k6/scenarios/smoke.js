// 파이프라인 검증용 스모크 시나리오: 스텁 앱의 /ping 과 /db 를 constant-arrival-rate 로 번갈아 호출.
// 실제 워크로드 시나리오(이벤트·좋아요·목록·상세)는 워크로드 미결이라 아직 없다 (docs/open-questions.md).
// 실행은 scripts/measure.sh 가 한다. 직접: k6 run -e BASE_URL=http://localhost:8080 k6/scenarios/smoke.js
import { check } from 'k6';
import { cfg, get, arrivalScenarios, steadyThresholds, summaryOptions, makeRng } from '../lib/common.js';

const ENDPOINTS = ['/ping', '/db'];

export const options = Object.assign(
  {
    scenarios: arrivalScenarios('hit'),
    thresholds: steadyThresholds(ENDPOINTS),
    discardResponseBodies: true,
    noConnectionReuse: false,
    userAgent: 'bench-k6-smoke',
  },
  summaryOptions,
);

// VU 별 결정적 난수. 엔드포인트 선택은 반복 번호로 번갈아(정확히 50:50), 난수는 이후 키 분포용 자리
let rng;
export function setup() {
  return { startedAt: new Date().toISOString(), rate: cfg.rate, warmup: cfg.warmup, steady: cfg.steady };
}

export function hit() {
  if (!rng) rng = makeRng(cfg.seed + __VU);
  const path = ENDPOINTS[__ITER % ENDPOINTS.length];
  const res = get(path, path);
  check(res, { 'status 200': (r) => r.status === 200 });
}
