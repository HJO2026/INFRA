# 측정 리포트 `20260920T012440Z-hjo`

- 생성: 2026-09-20T01:26:50+00:00
- 대상: hjo  /  회차: 1  /  순서: 단일
- 부하: constant-arrival-rate 50 req/s, 워밍업 30s (버림), steady 60s (집계), VU 50~200, 시드 42
- 시나리오: hjo: k6/scenarios/get-smoke.js
- 호스트: Apple M1 물리코어 8, RAM 16GB, macOS 26.6.2, Docker Desktop / server 24.0.7, VM CPU 8 / 7846MiB, 디스크 Protocol=Apple Fabric    Solid State=Yes
- 이미지: hjo=hjo-app:dev (9baff5ca6f26)
- 규칙: 회차 전 TRUNCATE·VACUUM ANALYZE·컨테이너 재시작 (OS 페이지 캐시는 비우지 못함). `dropped_iterations` ≠ 0 또는 4xx 발생 회차는 무효. 백분위는 회차 중앙값 (산술평균 금지). 편차 = (max−min)/중앙값×100

## hjo

| 회차 | 유효 | 처리량(성공 req/s) | p50 ms | p95 ms | p99 ms | 에러율 % | dropped | 요청수(steady) | 비고 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | O | 50.0 | 21.52 | 179.04 | 409.44 | 0.000 | 0 | 3001 |  |
| **중앙값** (1/1 유효) | | 50.0 | 21.52 | 179.04 | 409.44 | 0.000 | | | |
| 편차 % | | 0.0 | 0.0 | 0.0 | 0.0 | - | | | |

엔드포인트별 (유효 회차 중앙값)

| 엔드포인트 | req/s | p50 ms | p95 ms | p99 ms | fail % |
|---|---|---|---|---|---|
| posts_detail | 20.2 | 7.94 | 85.12 | 243.71 | 0.000 |
| posts_latest | 14.7 | 25.14 | 275.32 | 502.03 | 0.000 |
| posts_popular | 10.3 | 25.68 | 217.43 | 446.31 | 0.000 |
| posts_trending | 4.8 | 19.68 | 214.11 | 444.47 | 0.000 |

## 경고

- ⚠ hjo: 유효 회차 1개 (< 3). 신뢰 불가

## 확인 목록

- dropped_iterations 전 회차 0: 예
- 무효 회차: 0개
- 그래프: Grafana `bench-overview` 대시보드에서 각 회차 `started_at`~`ended_at` 구간 (metrics.json) 스크린샷을 붙일 것
- 알려진 한계: L3 캐시·메모리 대역폭 경합은 cpuset 으로 못 막음. OS 페이지 캐시 미초기화
