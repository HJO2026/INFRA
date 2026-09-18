# bench-infra

서버 고도화 스터디의 공통 측정 인프라. 세 구현(`impl-<name>`)을 같은 리소스·데이터·절차로 부하 측정한다.
설계 원문은 `docs/study-spec.md`, 이 레포의 범위와 단계는 `docs/role-3.md`.

## 사전 준비

| 항목 | 요구 |
|---|---|
| Docker Desktop (또는 Colima) | VM 에 **CPU 7개 이상, 메모리 8GB** 할당. 디스크 이미지 60GB 이상 권장 (M/L 덤프). `docker info` 로 확인 |
| 도구 | `docker` (compose v2 포함), `bash`, `jq`, `curl`, `python3`, `shellcheck`(개발 시) |
| 호스트 포트 | 8080(app), 15432(postgres), 9090(prometheus), 3000(grafana), 8081(cadvisor), 9187(exporter). 충돌 시 `APP_HOST_PORT`, `PG_HOST_PORT`, `PROM_HOST_PORT`, `GRAFANA_HOST_PORT` 로 변경 |
| 측정 환경 | 다른 앱·컨테이너 종료, 전원 연결, VM 할당 고정. `make preflight` 가 다른 프로젝트 컨테이너를 경고한다 |

cpuset 배치: SUT(app, postgres, 이후 kafka/redis) `0-3`, k6 `4-5`, 모니터링 `6`. 컨테이너별 메모리는 `bench.config.yml` 의 `budget`.

## 빠른 시작 (스텁 앱으로 파이프라인 검증)

```bash
make pin            # versions.env 의 이미지 digest 채우기 (최초 1회, 태그 바꿀 때)
make build-stub     # templates/Dockerfile 로 bench/stub-app:dev 빌드
make up             # postgres, app, prometheus, grafana, cadvisor, postgres_exporter 기동 + healthy 대기
make check-resources
make check-targets
make seed-stub-dump # seed/dumps/stub.dump 생성 (스텁 테이블 1개)
make seed SEED_PROFILE=stub
make preflight
./run-test.sh stub 3            # preflight → (reset → k6 → collect → 쿨다운) × 3 → results/<run-id>/report.md
make check-dashboard
```

Grafana: <http://localhost:3000> (익명 조회, 편집은 admin/admin). 대시보드 `bench overview`.
Prometheus: <http://localhost:9090>.

빠른 파이프라인 확인만 할 때: `WARMUP_SECONDS=5 STEADY_SECONDS=10 COOLDOWN_SECONDS=0 ./run-test.sh stub 1`

## 실제 구현 측정

1. impl 레포가 `templates/Dockerfile` 로 이미지를 빌드한다 (`docs/impl-guide.md`)
2. `bench.config.yml` 의 `targets` 에 이름·이미지(·override) 를 등록한다
3. 시드 덤프를 `seed/dumps/<S|M|L>.dump` 에 두고 `make seed SEED_PROFILE=M`
4. `./run-test.sh baseline,impl-a 3` — 회차마다 대상 순서를 무작위(시드 고정)로 돌린다
5. `results/<run-id>/report.md` 를 읽고 Grafana 스크린샷을 붙인다

## 명령

| 명령 | 설명 |
|---|---|
| `make help` | 타깃 목록 |
| `make pin` / `make pin-check` | `versions.env` digest 갱신 / 일치 확인 |
| `make config` | compose 설정 검증 |
| `make lint` | shellcheck |
| `make build-stub` | 스텁 이미지 빌드 |
| `make up` / `make down` / `make down-v` | 기동 / 정지 / 볼륨까지 삭제 |
| `make ps` / `make logs SVC=app` | 상태 / 로그 |
| `make check-resources` | cpuset·mem_limit 을 예산표와 대조 (compose 설정 + docker inspect) |
| `make check-targets` | Prometheus 타깃 전부 up |
| `make check-dashboard` | 대시보드 패널 쿼리 실행, 필수 패널이 비면 실패 |
| `make dashboard` | `monitoring/grafana/gen-dashboard.py` 로 대시보드 JSON 재생성 |
| `make seed SEED_PROFILE=<S\|M\|L\|stub>` | `pg_restore -j 4` → `VACUUM ANALYZE` → 행 수 |
| `make seed-stub-dump` | 스텁 덤프 생성 |
| `make preflight` | VM 자원, 디스크, digest, 컨테이너 상태, 예산, 외부 컨테이너 점검. `RUN_ID` 있으면 `host.json` 기록 |
| `make reset` | app 정지 → TRUNCATE(`bench.config.yml reset`) → VACUUM ANALYZE → postgres 재시작 → app 재생성 |
| `make measure TARGET=stub` | k6 1회 (`RUN_ID`, `RUN_NO` 환경변수) |
| `make collect` / `make report` | `RUN_ID` 의 회차 집계 / `report.md` 생성 |
| `./run-test.sh <target>[,<target>] <runs>` | 전체 절차 |

환경변수로 덮어쓸 수 있는 값: `APP_IMAGE`, `COMPOSE_OVERRIDE`(콜론 구분 여러 개), `RATE`, `WARMUP_SECONDS`, `STEADY_SECONDS`,
`COOLDOWN_SECONDS`, `PRE_VUS`, `MAX_VUS`, `SEED`, `PROM_CONFIG=prometheus.1s.yml`(1초 스크레이프).

## 측정 규칙 (스크립트가 강제하는 것)

- open model: k6 `constant-arrival-rate`. 워밍업 시나리오는 버리고 `steady` 시나리오만 집계
- `dropped_iterations ≠ 0` 또는 4xx 발생 회차는 무효 (`metrics.json` 의 `valid`)
- 회차 전 초기화: 테이블 TRUNCATE, VACUUM ANALYZE, postgres 재시작, app 재생성. **OS 페이지 캐시는 비우지 못한다**
- 3회 이상, 백분위는 회차 **중앙값** (산술평균 금지). 편차 = (max−min)/중앙값. 15% 초과 시 경고
- 대상이 여럿이면 회차마다 순서 무작위 (시드 고정으로 재현 가능)
- 타임존 UTC, 난수 시드 고정, 이미지 태그·digest 고정 (`versions.env`)
- k6 지표는 `--out experimental-prometheus-rw` 로 Prometheus 에 들어가 서버 지표와 같은 시간축에 놓인다 (`run_id`, `target`, `run_no` 태그)

## 디렉터리

```
compose/            compose.base.yml (postgres, app, k6 profile), compose.monitoring.yml
postgres/           postgresql.conf (baseline: shared_buffers 256MB, max_connections 30, work_mem 4MB, UTC)
monitoring/         prometheus/, grafana/{provisioning,dashboards,gen-dashboard.py}, postgres_exporter/queries.yaml
k6/{lib,scenarios}  common.js (러너 공통), smoke.js (스텁용). 실제 워크로드 시나리오는 미결
verify/             부하 후 정합성 검증 자리 (내용 미결)
scripts/            preflight, reset, seed, measure, collect, report, check-*, pin-versions, build-stub, up
templates/          Dockerfile, compose.override.yml (impl 레포가 복사)
stub-app/           파이프라인 검증용 최소 Spring Boot 앱 (실제 구현 아님)
seed/dumps/         덤프 (git 제외). results/  측정 결과 (report.md 만 커밋)
docs/               study-spec, role-3, open-questions, progress, impl-guide, harness-notes
```

## 알려진 함정

- Docker Desktop(macOS) 에서 cAdvisor 의 디스크 IO 지표는 비거나 부정확할 수 있다. 컨테이너별 CPU·메모리가 나오면 정상
- `jvm_gc_pause_*` 는 첫 GC 이후에만 생긴다
- postgres 18 이미지는 볼륨 루트가 `/var/lib/postgresql` (PGDATA 는 `18/docker` 하위)
- 같은 VM 의 다른 프로젝트 컨테이너는 SUT 와 코어를 나눠 쓴다. preflight 경고를 보고 멈추고 측정할 것
- 호스트 5432 가 다른 컨테이너에 잡혀 있어 PG 호스트 포트 기본값이 15432 다 (`docs/open-questions.md`)
