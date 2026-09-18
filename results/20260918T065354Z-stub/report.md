# 측정 리포트 `20260918T065354Z-stub`

- 생성: 2026-09-18T07:01:18+00:00
- 대상: stub  /  회차: 3  /  순서: 단일
- 부하: constant-arrival-rate 50 req/s, 워밍업 30s (버림), steady 60s (집계), VU 50~200, 시드 42
- 시나리오: stub: k6/scenarios/smoke.js
- 호스트: Apple M1 물리코어 8, RAM 16GB, macOS 26.6.2, Docker Desktop / server 24.0.7, VM CPU 8 / 7846MiB, 디스크 Protocol=Apple Fabric    Solid State=Yes
- ⚠ 측정 중 다른 프로젝트 컨테이너가 같은 VM 에 있었다: kafka-ui, mysql_db, postgres_db
- 이미지: stub=bench/stub-app:dev (f8a0c95ca9b7)
- 규칙: 회차 전 TRUNCATE·VACUUM ANALYZE·컨테이너 재시작 (OS 페이지 캐시는 비우지 못함). `dropped_iterations` ≠ 0 또는 4xx 발생 회차는 무효. 백분위는 회차 중앙값 (산술평균 금지). 편차 = (max−min)/중앙값×100

## stub

| 회차 | 유효 | 처리량(성공 req/s) | p50 ms | p95 ms | p99 ms | 에러율 % | dropped | 요청수(steady) | 비고 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | O | 50.0 | 2.19 | 4.29 | 7.26 | 0.000 | 0 | 3001 |  |
| 2 | O | 50.0 | 2.33 | 4.25 | 5.26 | 0.000 | 0 | 3001 |  |
| 3 | O | 50.0 | 2.34 | 4.52 | 6.49 | 0.000 | 0 | 3001 |  |
| **중앙값** (3/3 유효) | | 50.0 | 2.33 | 4.29 | 6.49 | 0.000 | | | |
| 편차 % | | 0.0 | 6.4 | 6.2 | 30.9 | - | | | |

엔드포인트별 (유효 회차 중앙값)

| 엔드포인트 | req/s | p50 ms | p95 ms | p99 ms | fail % |
|---|---|---|---|---|---|
| /db | 25.0 | 2.97 | 4.65 | 6.89 | 0.000 |
| /ping | 25.0 | 1.96 | 3.14 | 4.67 | 0.000 |

## 경고

- ⚠ stub: p99 ms 편차 30.9% > 15%. 회차 간 신뢰 불가

## 확인 목록

- dropped_iterations 전 회차 0: 예
- 무효 회차: 0개
- 그래프: Grafana `bench-overview` 대시보드에서 각 회차 `started_at`~`ended_at` 구간 (metrics.json) 스크린샷을 붙일 것
- 알려진 한계: L3 캐시·메모리 대역폭 경합은 cpuset 으로 못 막음. OS 페이지 캐시 미초기화
