# bench-infra

서버 고도화 스터디의 공통 측정 인프라. 세 구현(`impl-<name>`)을 같은 리소스·데이터·절차로 부하 측정한다.
설계 원문은 `docs/study-spec.md`, 이 레포의 범위와 단계는 `docs/role-3.md`.

## 사전 준비

| 항목 | 요구 |
|---|---|
| Docker Desktop (또는 Colima) | VM 에 **CPU 7개 이상, 메모리 8GB** 할당. 디스크 이미지 60GB 이상 권장 (M/L 시드). `docker info` 로 확인 |
| 도구 | `docker` (compose v2 포함), `bash`, `jq`, `curl`, `python3`, `shellcheck`(개발 시) |
| 설정 | `cp .env.example .env` 후 `JWT_SECRET` 을 팀 값으로 (앱은 이 값이 없으면 기동하지 않는다) |
| 호스트 포트 | 8080(app), 15432(postgres), 9090(prometheus), 8081(cadvisor), 9187(exporter), 3000(grafana, 켠 경우). 충돌 시 `APP_HOST_PORT`, `PG_HOST_PORT`, `PROM_HOST_PORT`, `GRAFANA_HOST_PORT` 로 변경 |
| 측정 환경 | 다른 앱·컨테이너 종료, 전원 연결, VM 할당 고정. `make preflight` 가 다른 프로젝트 컨테이너를 경고한다 |

cpuset 배치: SUT(app, postgres, 이후 kafka/redis) `0-3`, k6 `4-5`, 모니터링 `6`. 컨테이너별 메모리는 `bench.config.yml` 의 `budget`.

## 빠른 시작

```bash
cp .env.example .env            # JWT_SECRET 등 로컬 값 (한 번)
make pin                        # versions.env 의 이미지 digest 채우기 (최초 1회, 태그 바꿀 때)
make build-app                  # 앱 레포(APP_DIR, 기본 ../APP)의 Dockerfile 로 APP_IMAGE(hjo-app:dev) 빌드

docker compose up -d --wait     # postgres, app, prometheus, cadvisor, postgres_exporter

make check-resources && make check-targets && make preflight
./run-test.sh <target> 3        # preflight → (reset → k6 → collect → 쿨다운) × 3 → results/<run-id>/report.md
make check-dashboard
```

컨테이너는 **그냥 `docker compose`** 로 다룬다. 루트 `compose.yaml` 이 `compose/` 아래 파일들을 include 하고
이미지 태그를 `versions.env` 에서 읽으므로, 별도 플래그가 필요 없다.

```bash
docker compose ps
docker compose logs -f app
docker compose down            # 볼륨 유지
docker compose down -v         # DB 데이터까지 삭제
docker compose config -q       # 설정 검증
docker compose -f compose.yaml -f /path/impl/compose.override.yml up -d --wait   # impl 추가 컴포넌트
```

`make` 는 **여러 단계를 순서대로 밟는 것(측정 절차)** 에만 쓴다. 목록은 `make help`.

`.env` 로 비밀값·노브를 덮어쓴다: `cp .env.example .env` (JWT_SECRET 등. compose 가 `versions.env` 다음에 읽는다).

## 시드 데이터

시드는 앱 레포(`../APP`)의 `seed/` 생성기가 만든다. bench-infra 에는 시드 생성·복원 코드가 없다.
생성기는 **자기 compose 의 postgres**(프로젝트 `hjo-seed`)에 `seed_s/m/l` 템플릿과 `bench` DB 를 만들므로,
측정용 postgres(`bench-postgres`)로 한 번 옮겨야 한다.

```bash
# 0) 측정 스택을 먼저 띄운다
docker compose up -d --wait

# 1) 앱 레포에서 시드 생성 (규모: s | m | l). 앱 레포의 .env 가 필요하다 (APP/seed/README.md)
bash ../APP/seed/seed.sh s

# 2) 시드 postgres 의 bench DB 를 측정용 postgres 로 옮긴다 (한 줄).
#    app 을 먼저 멈춘다. 접속 세션이 남아 있으면 --clean 이 실패한다
SEED_DC="docker compose -f ../APP/seed/compose.seed.yml"
BENCH_DC="docker compose"
$BENCH_DC stop app \
  && $SEED_DC exec -T postgres pg_dump -U hjo -Fc -Z 6 bench \
     | $BENCH_DC exec -T postgres pg_restore -U bench -d bench --clean --if-exists --no-owner --no-privileges \
  && $BENCH_DC exec -T postgres psql -U bench -d bench -c 'VACUUM ANALYZE' \
  && $BENCH_DC start app
```

- 파이프로 넘기므로 `pg_restore -j` (병렬)는 쓸 수 없다. 병렬 복원이 필요하면 덤프를 파일로 받아서 복원한다
- 복원 후 `VACUUM ANALYZE` 는 필수다 (통계가 없으면 실행 계획이 달라져 측정이 무의미해진다)
- 규모를 바꿀 때마다 1)·2)를 다시 한다. 앱 레포 쪽은 템플릿이 이미 있으면 복제만 해서 빠르다

컨테이너 안으로 **스크립트를 한 줄로 밀어 넣는** 방법 (위 2)와 같은 패턴):

```bash
BENCH_DC="docker compose"
$BENCH_DC exec -T postgres psql -U bench -d bench -v ON_ERROR_STOP=1 -f - < 어떤.sql   # SQL 파일
$BENCH_DC exec -T postgres bash -s < 어떤.sh                                          # 셸 스크립트
$BENCH_DC cp 어떤파일 postgres:/tmp/                                                   # 파일만 넣기
```

Prometheus: <http://localhost:9090>.

**Grafana 는 기본으로 뜨지 않는다.** 보고 싶은 사람만 `compose/compose.monitoring.yml` 의 `grafana:` 블록과
맨 아래 `grafanadata:` 볼륨의 주석을 풀고 `docker compose up -d --wait` 하면 <http://localhost:3000> 에서 열린다
(익명 조회, 편집은 admin/admin, 대시보드 `bench overview` 는 자동 등록).
Grafana 없이도 측정·판정은 그대로다. 지표는 Prometheus 가 모으고, `make check-dashboard` 가 패널 쿼리를 직접 실행해 빈 패널을 알려 준다.

빠른 파이프라인 확인만 할 때: `WARMUP_SECONDS=5 STEADY_SECONDS=10 COOLDOWN_SECONDS=0 ./run-test.sh <target> 1`

## 실제 구현 측정

1. impl 레포가 자기 `Dockerfile` 로 이미지를 빌드한다 (`docs/impl-guide.md`)
2. `bench.config.yml` 의 `targets` 에 이름·이미지(·override) 를 등록한다
3. 시드 데이터를 준비한다 (위 [시드 데이터](#시드-데이터))
4. `./run-test.sh baseline,impl-a 3` — 회차마다 대상 순서를 무작위(시드 고정)로 돌린다
5. `results/<run-id>/report.md` 를 읽는다 (Grafana 를 켰다면 그 구간 스크린샷을 붙인다)

## 명령

| 명령 | 설명 |
|---|---|
| `make help` | 타깃 목록 |
| `make pin` / `make pin-check` | `versions.env` digest 갱신 / 일치 확인 |
| `make lint` | shellcheck |
| `make build-app` | 앱 레포(`APP_DIR`)의 Dockerfile 로 `APP_IMAGE` 빌드 |
| `make check-resources` | cpuset·mem_limit 을 예산표와 대조 (compose 설정 + docker inspect) |
| `make check-targets` | Prometheus 타깃 전부 up |
| `make check-dashboard` | 대시보드 패널 쿼리 실행, 필수 패널이 비면 실패 |
| `make dashboard` | `monitoring/grafana/gen-dashboard.py` 로 대시보드 JSON 재생성 |
| `make preflight` | VM 자원, 디스크, digest, 컨테이너 상태, 예산, 외부 컨테이너 점검. `RUN_ID` 있으면 `host.json` 기록 |
| `make reset` | app 정지 → TRUNCATE(`bench.config.yml reset`) → VACUUM ANALYZE → postgres 재시작 → app 재생성 |
| `make measure TARGET=<target>` | k6 1회 (`RUN_ID`, `RUN_NO` 환경변수) |
| `make collect` / `make report` | `RUN_ID` 의 회차 집계 / `report.md` 생성 |
| `./run-test.sh <target>[,<target>] <runs>` | 전체 절차 |

환경변수로 덮어쓸 수 있는 값: `APP_IMAGE`, `APP_DIR`, `COMPOSE_OVERRIDE`(콜론 구분 여러 개), `RATE`, `WARMUP_SECONDS`, `STEADY_SECONDS`,
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
compose.yaml        루트 진입점 (compose/ 아래를 include). docker compose 명령이 그대로 된다
compose/            compose.base.yml (postgres, app, k6 profile), compose.monitoring.yml
postgres/           postgresql.conf (baseline: shared_buffers 256MB, max_connections 30, work_mem 4MB, UTC)
monitoring/         prometheus/, grafana/{provisioning,dashboards,gen-dashboard.py}, postgres_exporter/queries.yaml
k6/{lib,scenarios}  common.js (러너 공통). 실제 워크로드 시나리오는 미결
verify/             부하 후 정합성 검증 자리 (내용 미결)
scripts/            preflight, reset, measure, collect, report, check-*, pin-versions, build-app
.env.example        로컬 비밀값·노브 예시 (.env 는 git 제외)
results/            측정 결과 (report.md 만 커밋)
docs/               study-spec, role-3, open-questions, progress, impl-guide, harness-notes
```

## 알려진 함정

- Docker Desktop(macOS) 에서 cAdvisor 의 디스크 IO 지표는 비거나 부정확할 수 있다. 컨테이너별 CPU·메모리가 나오면 정상
- `jvm_gc_pause_*` 는 첫 GC 이후에만 생긴다
- postgres 18 이미지는 볼륨 루트가 `/var/lib/postgresql` (PGDATA 는 `18/docker` 하위)
- 같은 VM 의 다른 프로젝트 컨테이너는 SUT 와 코어를 나눠 쓴다. preflight 경고를 보고 멈추고 측정할 것
- 호스트 5432 가 다른 컨테이너에 잡혀 있어 PG 호스트 포트 기본값이 15432 다 (`docs/open-questions.md`)
