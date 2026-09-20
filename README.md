# bench-infra

서버 고도화 스터디의 공통 측정 인프라. 세 구현을 같은 리소스·데이터·절차로 부하 측정한다.
설계 원문은 `docs/study-spec.md`, 이 레포의 범위는 `docs/role-3.md`.

맥·리눅스·윈도우에서 같은 명령으로 돈다. 윈도우는 **Git Bash** 또는 **WSL2** 에서 친다 (자세한 건 [윈도우에서](#윈도우에서)).

---

## 처음 한 번: 클론부터 결과까지

아래를 위에서 아래로 그대로 따라 치면 된다. 명령은 전부 **bench-infra 레포 루트**에서 친다.

### 0. 준비물

| 항목 | 요구 |
|---|---|
| Docker | Docker Desktop 또는 Colima. **VM 에 CPU 7개 이상, 메모리 8GB** 할당 |
| 디스크 | Docker 디스크 이미지 60GB 이상 권장 (M/L 시드를 쓸 때) |
| 명령 | `docker`, `bash`, `git`, `jq`, `curl`, 파이썬 3 |
| 선택 | `make` (없으면 스크립트를 직접 부르면 된다. [make 없이 쓰기](#make-없이-쓰기)) |

VM 자원 확인. CPU 7 미만이면 cpuset 배치가 안 맞아 `make preflight` 가 실패한다.

```bash
docker info --format 'CPU {{.NCPU}} / MEM {{.MemTotal}}'
```

- **맥·윈도우(Docker Desktop)**: Settings > Resources 에서 CPU·메모리를 올린다.
- **윈도우 WSL2 백엔드**: Docker Desktop 설정이 아니라 `%UserProfile%\.wslconfig` 에서 정한다. [윈도우에서](#윈도우에서) 참고.

### 1. 앱 레포를 나란히 클론

bench-infra 는 앱 레포를 `../APP` 에서 찾는다. **두 레포가 같은 부모 폴더 아래 나란히** 있어야 한다.

```
어떤폴더/
├─ INFRA/     ← 이 레포 (이미 클론했다)
└─ APP/       ← 스프링 앱 레포
```

```bash
git clone https://github.com/HJO2026/APP.git ../APP
git -C ../APP switch feat/seed-data      # 시드 생성기가 이 브랜치에 있다
```

폴더 이름이 `APP` 이 아니거나 다른 곳에 두었다면 `.env` 에 `APP_DIR=/실제/경로` 를 적는다.

### 2. 로컬 설정 파일 만들기

```bash
cp .env.example .env
```

`.env` 를 열어 **`JWT_SECRET` 을 팀 공용 값으로 채운다.** 팀원끼리 값이 다르면 k6 가 만든 토큰을 앱이 거부한다.

### 3. 이미지 준비

```bash
make pin          # versions.env 의 이미지 digest 채우기 (최초 1회)
make build-app    # ../APP 의 Dockerfile 로 hjo-app:dev 빌드
```

### 4. 스택 띄우기

```bash
docker compose up -d --wait
```

postgres, app, prometheus, cadvisor, postgres_exporter 가 뜬다. Grafana 는 기본으로 꺼져 있다.

```bash
make check-resources    # cpuset·메모리가 예산표와 같은지
make check-targets      # Prometheus 가 전부 긁고 있는지
```

> 앱이 `exited (1)` 로 죽고 로그에 `Found non-empty schema(s) "public" but no schema history table` 가 보이면
> 예전 볼륨이 남은 것이다. [문제 생기면](#문제-생기면) 참고.

### 5. 시드 데이터 넣기

시드는 앱 레포의 생성기가 만든다. 생성기는 **자기 postgres**(프로젝트 `hjo-seed`)에 만들므로 측정용으로 한 번 옮겨야 한다.
규모는 `s`(글 5만) / `m` / `l` 중 고른다. 처음이면 `s` 로 한다.

```bash
# 5-1) 생성. 호스트 5432 가 다른 컨테이너에 잡혀 있으면 PGPORT 로 피한다
PGPORT=55432 bash ../APP/seed/seed.sh s

# 5-2) 이 컴퓨터에서 처음 돌릴 때만 필요하다 (위 명령이 "[완료]" 없이 조용히 끝난 경우)
PGPORT=55432 docker compose -f ../APP/seed/compose.seed.yml exec -T postgres \
  psql -U hjo -d postgres -c "CREATE DATABASE bench TEMPLATE seed_s STRATEGY FILE_COPY"

# 5-3) 측정용 postgres 로 옮긴다. app 을 먼저 멈춰야 --clean 이 성공한다
docker compose stop app
PGPORT=55432 docker compose -f ../APP/seed/compose.seed.yml exec -T postgres pg_dump -U hjo -Fc -Z 6 bench \
  | docker compose exec -T postgres pg_restore -U bench -d bench --clean --if-exists --no-owner --no-privileges

# 5-4) 통계를 갱신하고 app 을 다시 띄운다. VACUUM ANALYZE 는 건너뛰면 안 된다
docker compose exec -T postgres psql -U bench -d bench -c 'VACUUM ANALYZE'
docker compose up -d --wait app

# 5-5) 확인. S 기준 posts 50000 / users 15000
docker compose exec -T postgres psql -U bench -d bench -c \
  "SELECT 'posts' t, count(*) FROM posts UNION ALL SELECT 'users', count(*) FROM users"

# 5-6) 시드용 postgres 는 이제 내려도 된다 (VM 자원을 아낀다)
PGPORT=55432 docker compose -f ../APP/seed/compose.seed.yml down
```

### 6. 측정

```bash
make preflight              # VM 자원·이미지·컨테이너 상태 점검
./run-test.sh hjo 3         # preflight → (초기화 → k6 → 집계 → 쿨다운) × 3 → 리포트
```

3회에 약 8분 걸린다. 파이프라인만 빨리 확인하려면:

```bash
WARMUP_SECONDS=5 STEADY_SECONDS=15 COOLDOWN_SECONDS=0 ./run-test.sh hjo 1
```

### 7. 결과 보기

```bash
cat "results/$(ls -t results | head -1)/report.md"   # 가장 최근 회차 리포트
make check-dashboard                                 # 대시보드 패널 쿼리를 실제로 돌려 빈 패널 확인
```

리포트에는 회차별 처리량·p50/p95/p99·에러율과 유효 회차의 중앙값·편차가 들어 있다.
`dropped_iterations` 가 0이 아니거나 4xx 가 나온 회차는 **무효**로 표시된다.

Prometheus 는 <http://localhost:9090> 에서 바로 열린다.

---

## 윈도우에서

**Git Bash 와 WSL2 둘 다 된다.** WSL2 쪽이 맥·리눅스와 동작이 같아서 더 편하다.

### VM 자원 (WSL2 백엔드)

Docker Desktop 설정창이 아니라 `%UserProfile%\.wslconfig` 를 만들어야 CPU·메모리가 잡힌다. 저장 후 `wsl --shutdown`.

```ini
[wsl2]
processors=8
memory=8GB
```

`docker info --format 'CPU {{.NCPU}} / MEM {{.MemTotal}}'` 로 반영됐는지 확인한다.

### 클론할 때 줄바꿈

이 레포에는 `.gitattributes` 가 있어 줄바꿈이 LF 로 고정된다. 그래도 **이미 CRLF 로 받아 둔 경우**
`bash: $'\r': command not found` 가 난다. 그러면 한 번 정규화한다.

```bash
git config core.autocrlf false
git rm --cached -r . && git reset --hard
```

### 파이썬

`python3` 가 없어도 된다. 스크립트가 `python3` → `python` → `py -3` 순으로 찾는다.
다만 **윈도우 기본 PATH 의 `python3` 는 Microsoft Store 를 여는 껍데기**라, 파이썬을 python.org 에서 설치하고
"Add to PATH" 를 켜는 쪽이 깔끔하다.

### make

Git Bash 에는 `make` 가 없다. 설치하거나 스크립트를 직접 부른다.

```powershell
winget install ezwinports.make
```

### 자원 패널이 비면

`make check-targets` 가 "cAdvisor 가 컨테이너별 지표를 못 내고 있다" 고 하면 cAdvisor 마운트 경로가 이 플랫폼과 안 맞는 것이다.
`.env` 에서 바꿀 수 있다.

```bash
CADVISOR_DOCKER_ROOT=/var/lib/docker
CADVISOR_CONTAINERD_SOCK=/run/containerd/containerd.sock
```

측정 자체는 계속 된다. 자원 패널만 빈다. **이 경로는 아직 윈도우에서 검증되지 않았다.**
확인해 보고 결과를 `docs/open-questions.md` 에 남겨 주면 좋겠다.

---

## 평소 쓰는 명령

컨테이너는 **그냥 `docker compose`** 로 다룬다. 루트 `compose.yaml` 이 `compose/` 아래를 include 하고
이미지 태그를 `versions.env` 에서 읽으므로 별도 플래그가 필요 없다.

```bash
docker compose ps
docker compose logs -f app
docker compose down              # 볼륨 유지
docker compose down -v           # DB 데이터까지 삭제
docker compose config -q         # 설정 검증
```

`make` 는 **여러 단계를 순서대로 밟는 것(측정 절차)** 에만 쓴다.

| 명령 | 설명 |
|---|---|
| `make help` | 타깃 목록 |
| `make pin` / `make pin-check` | `versions.env` digest 갱신 / 일치 확인 |
| `make build-app` | `APP_DIR` 의 Dockerfile 로 `APP_IMAGE` 빌드 |
| `make preflight` | VM 자원, 디스크, digest, 컨테이너 상태, 예산, 외부 컨테이너 점검 |
| `make check-resources` | cpuset·mem_limit 을 예산표와 대조 |
| `make check-targets` | Prometheus 타깃 전부 up + cAdvisor 컨테이너별 지표 확인 |
| `make check-dashboard` | 대시보드 패널 쿼리 실행, 필수 패널이 비면 실패 |
| `make dashboard` | 대시보드 JSON 재생성 |
| `make reset` | app 정지 → TRUNCATE → VACUUM ANALYZE → postgres 재시작 → app 재생성 |
| `make measure TARGET=<이름>` | k6 1회 (`RUN_ID`, `RUN_NO` 환경변수) |
| `make collect` / `make report` | `RUN_ID` 의 회차 집계 / `report.md` 생성 |
| `make lint` | shellcheck |
| `./run-test.sh <이름>[,<이름>] <횟수>` | 전체 측정 절차 |

환경변수로 덮어쓸 수 있는 값: `APP_IMAGE`, `APP_DIR`, `COMPOSE_OVERRIDE`(콜론 구분), `RATE`, `WARMUP_SECONDS`,
`STEADY_SECONDS`, `COOLDOWN_SECONDS`, `PRE_VUS`, `MAX_VUS`, `SEED`, `PROM_CONFIG=prometheus.1s.yml`(1초 스크레이프).

### make 없이 쓰기

`make X` 는 전부 `scripts/X.sh` 를 부르는 것뿐이다. 그대로 바꿔 치면 된다.

| make | 직접 |
|---|---|
| `make pin` | `scripts/pin-versions.sh` |
| `make build-app` | `scripts/build-app.sh` |
| `make preflight` | `scripts/preflight.sh` |
| `make check-resources` | `scripts/check-resources.sh` |
| `make check-targets` | `scripts/check-targets.sh` |
| `make check-dashboard` | `scripts/check-dashboard.sh` |
| `make dashboard` | `scripts/dashboard.sh` |
| `make reset` | `scripts/reset.sh` |
| `make measure TARGET=hjo` | `scripts/measure.sh hjo` |
| `make collect` / `make report` | `scripts/collect.sh` / `scripts/report.sh` |
| `make test` | `./run-test.sh` |

---

## Grafana (선택)

기본으로 뜨지 않는다. 보려면 `compose/compose.monitoring.yml` 의 `grafana:` 블록과 맨 아래 `grafanadata:` 볼륨의
주석을 풀고 `docker compose up -d --wait`. <http://localhost:3000> 에서 열린다.
익명 조회, 편집은 admin/admin, 대시보드 `bench overview` 는 자동 등록된다.

Grafana 없이도 측정·판정은 그대로다. 지표는 Prometheus 가 모으고 `make check-dashboard` 가 패널 쿼리를 직접 실행한다.

---

## 다른 구현 측정하기

1. impl 레포가 자기 `Dockerfile` 로 이미지를 빌드한다 (`docs/impl-guide.md`)
2. `bench.config.yml` 의 `targets` 에 이름·이미지를 등록한다

   ```yaml
   targets:
     hjo:
       image: hjo-app:dev
       scenario: get-smoke
     impl-a:
       image: bench/impl-a:v1
       scenario: get-smoke
       override: /절대/경로/impl-a/compose.override.yml   # 추가 컴포넌트가 있을 때만
   ```

3. `./run-test.sh hjo,impl-a 3` — 회차마다 대상 순서를 무작위로 섞는다 (시드 고정이라 재현된다)

---

## 측정 규칙 (스크립트가 강제한다)

- open model: k6 `constant-arrival-rate`. 워밍업 구간은 버리고 `steady` 만 집계
- `dropped_iterations ≠ 0` 또는 4xx 발생 회차는 무효
- 회차 전 초기화: TRUNCATE, VACUUM ANALYZE, postgres 재시작, app 재생성. **OS 페이지 캐시는 비우지 못한다**
- 3회 이상, 백분위는 회차 **중앙값** (산술평균 금지). 편차 15% 초과 시 경고
- 타임존 UTC, 난수 시드 고정, 이미지 태그·digest 고정
- k6 지표는 Prometheus 로 remote write 되어 서버 지표와 같은 시간축에 놓인다 (`run_id`, `target`, `run_no` 태그)

cpuset 배치: SUT(app, postgres) `0-3`, k6 `4-5`, 모니터링 `6`. 컨테이너별 메모리는 `bench.config.yml` 의 `budget`.

호스트 포트: 8080(app), 15432(postgres), 9090(prometheus), 8081(cadvisor), 9187(exporter), 3000(grafana).
충돌하면 `.env` 에서 `APP_HOST_PORT`, `PG_HOST_PORT`, `PROM_HOST_PORT`, `GRAFANA_HOST_PORT` 로 바꾼다.

---

## 문제 생기면

**앱이 `exited (1)`, 로그에 `Found non-empty schema(s) "public" but no schema history table`**

예전에 쓰던 테이블이 볼륨에 남아 Flyway 가 멈춘 것이다. 남은 게 뭔지 먼저 본다.

```bash
docker compose exec -T postgres psql -U bench -d bench -c "\dt"
```

버려도 되는 것만 있으면 볼륨째 지우고 다시 시작한다. **DB 데이터가 전부 사라지니 시드를 다시 넣어야 한다.**

```bash
docker compose down -v && docker compose up -d --wait
```

**`port is already allocated`**

다른 프로젝트 컨테이너가 그 포트를 쓰고 있다. 누가 쓰는지 보고 `.env` 에서 포트를 바꾼다.

```bash
docker ps --format '{{.Names}}\t{{.Ports}}'
```

앱 레포 시드는 5432 를 쓰므로 `PGPORT=55432` 를 붙인다 (위 5번 참고).

**`command not found: docker compose`**

명령을 변수에 넣은 경우다. `DC="docker compose"` 후 `$DC ps` 는 zsh 에서 깨진다.
zsh 는 변수를 단어로 쪼개지 않는다. 명령을 그대로 적는다.

**회차가 계속 무효로 나온다**

- `dropped_iterations ≠ 0`: k6 가 목표 도착률을 못 맞춘 것이다. VU 부족이면 `PRE_VUS`·`MAX_VUS` 를 올리고,
  SUT 포화면 `RATE` 를 낮춘다
- `4xx`: 시나리오가 없는 자원을 부른 것이다. 시드가 제대로 들어갔는지 본다

**측정값이 회차마다 많이 흔들린다**

`make preflight` 가 경고하는 다른 프로젝트 컨테이너를 멈춘다. 같은 VM 의 CPU 를 나눠 쓴다.

```bash
docker ps --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}'
```

---

## 디렉터리

```
compose.yaml        루트 진입점 (compose/ 아래를 include)
compose/            compose.base.yml (postgres, app, k6), compose.monitoring.yml
postgres/           postgresql.conf (baseline: shared_buffers 256MB, max_connections 30, work_mem 4MB, UTC)
monitoring/         prometheus/, grafana/{provisioning,dashboards,gen-dashboard.py}, postgres_exporter/queries.yaml
k6/lib              러너 공통 코드
k6/scenarios        시나리오. get-smoke.js 는 조회 API 샘플이고 합의된 워크로드는 아직 미결
verify/             부하 후 정합성 검증 자리 (내용 미결)
scripts/            preflight, reset, measure, collect, report, check-*, pin-versions, build-app, dashboard
.env.example        로컬 비밀값·노브 예시 (.env 는 git 제외)
results/            측정 결과 (report.md 만 커밋)
docs/               study-spec, role-3, open-questions, progress, impl-guide, harness-notes
```

## 알려진 함정

- Docker Desktop(맥) 에서 cAdvisor 의 디스크 IO 지표는 비거나 부정확할 수 있다. 컨테이너별 CPU·메모리가 나오면 정상
- `jvm_gc_pause_*` 는 첫 GC 이후에만 생긴다. 가벼운 부하에서는 비어 있는 게 정상
- 서버 지연 백분위·톰캣 패널은 앱에 `percentiles-histogram` 과 `tomcat.mbeanregistry` 설정이 있어야 채워진다 (`docs/impl-guide.md`)
- postgres 18 이미지는 볼륨 루트가 `/var/lib/postgresql` (PGDATA 는 `18/docker` 하위)
- 시드를 파이프로 옮기므로 `pg_restore -j` (병렬)는 쓸 수 없다. 병렬이 필요하면 덤프를 파일로 받는다
- 덤프에 `flyway_schema_history` 가 들어 있어 복원 뒤 앱이 다시 떠도 마이그레이션을 재적용하지 않는다
