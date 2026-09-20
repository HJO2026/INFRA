// 조회 API 전용 샘플 시나리오. 파이프라인(부하 → 지표 → 리포트)이 실제 앱에 붙는지 확인하는 용도다.
//
// 주의: 이것은 **합의된 워크로드가 아니다.** 요청 비율·키 분포·RPS 는 임의로 정한 자리값이다
// (study-spec 11장 "워크로드: 키 분포(Zipf), 시나리오별 RPS" 미결). 토픽 측정에 이 숫자를 쓰지 말 것.
//
// 쓰는 API 는 인증이 없는 GET 세 종류 (PostController):
//   GET /posts?sort=latest   목록 (created_at DESC, id DESC)
//   GET /posts?sort=popular  목록 (like_count DESC, id DESC)
//   GET /posts/trending      최근 24시간 조회 기준 상위 20개
//   GET /posts/{id}          상세 (게시글 + 최신 댓글 20개)
//
// 실행: scripts/measure.sh hjo  (또는 ./run-test.sh hjo 1)
import { check } from 'k6';
import { cfg, get, arrivalScenarios, steadyThresholds, summaryOptions, makeRng } from '../lib/common.js';

// 상세 조회가 고를 게시글 ID 범위. 시드 S 프로파일 기준 1..50000 연속.
// 다른 프로파일을 쓰면 POST_ID_MIN/MAX 환경변수로 넘긴다.
const POST_ID_MIN = Number(__ENV.POST_ID_MIN || 1);
const POST_ID_MAX = Number(__ENV.POST_ID_MAX || 50000);
const PAGE_SIZE = Number(__ENV.PAGE_SIZE || 20); // study-spec 6장 기본값

// 요청 비율 (누적). 상세를 가장 무겁게 본 임의 배분이다
const MIX = [
  { until: 0.4, name: 'posts_detail' },
  { until: 0.7, name: 'posts_latest' },
  { until: 0.9, name: 'posts_popular' },
  { until: 1.0, name: 'posts_trending' },
];
const NAMES = MIX.map((m) => m.name);

export const options = Object.assign(
  {
    scenarios: arrivalScenarios('browse'),
    thresholds: steadyThresholds(NAMES),
    discardResponseBodies: false, // 응답이 비었는지 확인하려면 본문이 필요하다
    noConnectionReuse: false,
    userAgent: 'bench-k6-get-smoke',
  },
  summaryOptions,
);

let rng;

export function browse() {
  // VU 마다 시드를 고정해 재현 가능한 키 분포를 만든다 (study-spec: 난수 시드 고정)
  if (!rng) rng = makeRng(cfg.seed + __VU);

  const r = rng();
  const pick = MIX.find((m) => r < m.until).name;

  let res;
  switch (pick) {
    case 'posts_detail': {
      // 균등 분포. 실제 워크로드는 Zipf 쏠림이어야 한다 (미결이라 여기서는 균등)
      const id = POST_ID_MIN + Math.floor(rng() * (POST_ID_MAX - POST_ID_MIN + 1));
      res = get(`/posts/${id}`, 'posts_detail');
      check(res, {
        'detail 200': (x) => x.status === 200,
        'detail 본문 있음': (x) => x.status !== 200 || (x.body && x.body.length > 0),
      });
      break;
    }
    case 'posts_latest':
      res = get(`/posts?sort=latest&size=${PAGE_SIZE}`, 'posts_latest');
      check(res, { 'latest 200': (x) => x.status === 200 });
      break;
    case 'posts_popular':
      res = get(`/posts?sort=popular&size=${PAGE_SIZE}`, 'posts_popular');
      check(res, { 'popular 200': (x) => x.status === 200 });
      break;
    default:
      res = get('/posts/trending', 'posts_trending');
      check(res, { 'trending 200': (x) => x.status === 200 });
      break;
  }
}
