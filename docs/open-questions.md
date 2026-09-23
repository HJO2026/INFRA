# 미결 · 임시 결정 기록

형식: 날짜 / 단계 / 무엇을 정했나 / 왜 / 되돌리려면

## 2026-09-18 / 0단계 / 모니터링 이미지 버전 선택
- 정한 것: `prom/prometheus:v3.14.0`, `grafana/grafana:12.4.11`, `gcr.io/cadvisor/cadvisor:v0.55.1`,
  `prometheuscommunity/postgres-exporter:v0.20.1`
- 왜: study-spec 은 PG·JDK·k6 태그만 정했고 모니터링 스택은 "명시 버전" 규칙만 있음. 작업 시점 Docker Hub 최신
  안정 태그 중 linux/arm64 매니페스트가 있는 것을 골랐다. Grafana 는 13.x 가 있으나 프로비저닝 포맷 호환이
  검증된 12.x 계열을 택했다.
- 되돌리려면: `versions.env` 태그를 바꾸고 `make pin` 실행

## 2026-09-18 / 0단계 / Docker Desktop 디스크 이미지 30GB
- 정한 것: 그대로 진행. preflight 는 디스크 여유를 경고만 하고 실패시키지 않는다 (임계값은 `bench.config.yml`)
- 왜: study-spec 3장은 60GB 이상을 요구하지만 이 호스트의 Docker Desktop 디스크 이미지는 30,518MiB. 스텁·S 프로파일에는 충분.
  M/L 덤프(6~35GB) 복원 전에 Docker Desktop 설정에서 늘려야 한다
- 되돌리려면: Docker Desktop > Resources > Disk image size 를 60GB 이상으로 올리고 preflight 임계값 상향

## 2026-09-18 / 0단계 / 루트의 role-3.md 사본
- 정한 것: `docs/role-3.md` 와 내용이 같은 루트 `role-3.md` 는 `.gitignore` 로 제외 (삭제하지 않음)
- 왜: 내가 만든 파일이 아니고 삭제는 되돌리기 어렵다. 진실의 원천은 `docs/` 아래
- 되돌리려면: 루트 파일을 지우고 `.gitignore` 의 `/role-3.md` 줄 삭제

## 2026-09-18 / 2단계 / 호스트 포트 변수화, PG 기본 15432
- 정한 것: compose 의 호스트 포트를 `PG_HOST_PORT`(기본 15432), `APP_HOST_PORT`(기본 8080) 변수로. 컨테이너 안 포트는 5432/8080 그대로
- 왜: 이 호스트에서 다른 프로젝트의 컨테이너(`postgres_db`)가 5432 를 점유하고 있어 `make up` 이 실패했다. 남의 컨테이너를 멈추는 건 되돌리기 어렵다.
  k6·exporter 는 compose 네트워크 안에서 서비스명으로 붙으므로 측정에는 영향 없음
- 되돌리려면: `PG_HOST_PORT=5432 make up` 또는 compose 기본값 수정
- 참고: 측정 중에는 다른 프로젝트 컨테이너(kafka-ui, mysql_db, postgres_db)가 같은 VM 의 CPU·메모리를 쓴다. preflight 가 경고한다 (5단계)

## 2026-09-18 / 2단계 / 앱 이미지 템플릿에 curl 추가, memswap_limit 고정
- 정한 것: `templates/Dockerfile` 런타임 스테이지에 `curl` 설치. compose healthcheck 가 `/actuator/health/readiness` 를 curl 로 확인.
  모든 SUT·k6 컨테이너에 `memswap_limit` = `mem_limit` 지정 (스왑 사용 금지)
- 왜: `eclipse-temurin:25-jdk` 에는 curl·wget 이 없다. 스왑을 막아야 mem_limit 초과 시 동작(OOM)이 호스트마다 같다
- 되돌리려면: Dockerfile 의 apt-get 줄 삭제 + healthcheck 를 bash `/dev/tcp` 방식으로 교체. memswap_limit 줄 삭제

## 2026-09-18 / 3단계 / cAdvisor 마운트를 Docker Desktop(macOS) 기준으로 구성
- 정한 것: cAdvisor 볼륨을 `/var/run/docker.sock`, `/run/containerd/containerd.sock`, `/var/lib/docker`, `/sys` 네 개만 마운트.
  리눅스 호스트용 표준 구성의 `/:/rootfs`, `/var/run`(디렉터리), `/dev/disk` 는 뺐다
- 왜: Docker Desktop 은 `/var/run` 디렉터리 마운트를 Mac 쪽 경로로 매핑해 docker.sock 을 못 찾고, cAdvisor v0.55 의 docker factory 는
  containerd 소켓과 `/var/lib/docker`(rw 레이어 식별) 가 없으면 컨테이너를 아예 등록하지 않는다. 이 구성으로 컨테이너별 CPU·메모리·디스크 IO 지표가 나온다
- 되돌리려면: 리눅스 호스트에서 지표가 비면 표준 마운트(`/:/rootfs:ro`, `/var/run:/var/run:ro`, `/dev/disk/:/dev/disk:ro`)를 추가

## 2026-09-18 / 6단계 / GC pause 패널을 optional 로, postgres_exporter 커스텀 쿼리
- 정한 것: 대시보드 "GC pause" 두 패널은 `benchExpect=optional` (check-dashboard 가 비어 있어도 통과). 나머지 JVM 패널(allocation, heap, 스레드)은 필수
- 왜: Micrometer `jvm_gc_pause_*` 는 첫 GC 이후에만 등록된다. 스텁 부하(50 req/s × 90s, 1GB 힙)로는 GC 가 한 번도 안 일어났다. 실제 워크로드에서는 나온다
- 되돌리려면: `monitoring/grafana/gen-dashboard.py` 에서 expect 를 `required` 로 바꾸고 `make dashboard` (2026-09-20 에 `stub` 표식 이름을 `required` 로 바꿈)
- 정한 것: postgres_exporter 에 `--collector.stat_checkpointer`(PG17+ 체크포인트), `--extend.query-path` 커스텀 쿼리(`monitoring/postgres_exporter/queries.yaml`: WAL 생성량, 대기 종류별 백엔드, 락 대기 최장 시간)
- 왜: 기본 컬렉터가 PG 18 의 pg_stat_checkpointer·pg_stat_wal 을 안 주고, "락 대기 시간" 은 PG 가 직접 노출하지 않아 pg_stat_activity 로 근사했다. `--extend.query-path` 는 deprecated 지만 v0.20.1 에서 동작한다
- 되돌리려면: compose 의 해당 플래그·볼륨 삭제. exporter 를 올릴 때 플래그가 사라지면 커스텀 쿼리를 sql_exporter 등으로 옮긴다

## 2026-09-18 / 6단계 / e2e 적재 지연 지표 이름 제안
- 정한 것: 대시보드 "e2e 적재 지연" 패널은 Micrometer Timer `bench.ingest.e2e` (Prometheus 이름 `bench_ingest_e2e_seconds_bucket`) 를 읽는다. 아직 없는 지표라 `later`
- 왜: study-spec 8장은 "컨슈머 Micrometer 타이머 또는 ingested_at 사후 집계" 라고만 했고 이름이 없다. 역할 1 에게 제안하는 인터페이스
- 되돌리려면: 역할 1 이 다른 이름을 쓰면 gen-dashboard.py 의 쿼리만 교체

## 2026-09-20 / 스텁 앱·덤프 시드 제거 / 앱·시드 연결 방식 미정
- 정한 것: `stub-app/`, `scripts/{build-stub,seed,make-stub-dump}.sh`, `seed/`, `k6/scenarios/smoke.js`, `make seed`·`seed-stub-dump` 삭제.
  앱은 `../APP` 레포 자체 Dockerfile 로 `make build-app` (`APP_IMAGE=hjo-app:dev`). 대시보드 필수 표식 `stub` → `required`
- 왜: 실제 스프링 앱과 시드(앱 레포 `feat/seed-data`, 생성기 방식)가 생겼다. 시드는 덤프가 아니라 SQL 생성기 + fingerprint 로 공유하므로
  `pg_restore` 경로가 필요 없다
- 남은 결정:
  - **시드를 측정용 postgres(bench-postgres)로 옮기는 법**: 앱 레포 시드는 자기 compose(`hjo-seed`, 호스트 5432)의 postgres 에 `seed_s/m/l`·`bench` DB 를 만든다.
    (a) 앱 레포 `seed.sh` 가 bench-postgres 를 대상으로 돌게 하기, (b) 시드 postgres 의 `bench` 를 `pg_dump`/`pg_restore` 로 옮기기 중 택일. study-spec 은 덤프 공유, 앱 레포 README 는 생성기 공유라 스펙과도 맞춰야 한다
  - **앱 기동 조건**: 앱은 `JWT_SECRET`(32바이트+) 이 없으면 기동하지 않는다. compose 에 아직 주입하지 않았다
  - **healthcheck**: compose 는 `/actuator/health/readiness` 를 보지만 앱은 `management.endpoint.health.probes.enabled` 를 켜지 않았다 (쿠버네티스 밖에서는 readiness 그룹이 없다). 앱 이미지에 `curl` 이 있는지도 확인 필요
  - **JVM 옵션**: 앱 Dockerfile 은 `JAVA_OPTS`(기본값 대체 방식), compose 는 `JAVA_TOOL_OPTIONS` 를 준다. 둘 다 적용되지만 어느 쪽으로 통일할지
  - **k6 시나리오**: smoke 를 지워 시나리오가 없다. `bench.config.yml targets` 도 비어 있다
- 되돌리려면: `git revert` 로 이 커밋을 되돌리면 스텁 앱·덤프 복원 경로가 그대로 돌아온다

## 2026-09-20 / 앱 연동 / 시드 이관, .env, JAVA_OPTS, healthcheck
- 정한 것 (앞 항목의 "남은 결정" 중 넷):
  - **시드 이관**: 앱 레포 `seed/seed.sh` 로 만든 뒤 `pg_dump -Fc | pg_restore` 한 줄로 측정용 postgres 로 옮긴다 (README "시드 데이터").
    bench-infra 에 make 타깃이나 스크립트를 두지 않고 문서로만 둔다
  - **비밀값**: 루트 `.env` (git 제외, 예시는 `.env.example`). compose 는 `--env-file versions.env --env-file .env` 순으로 읽는다.
    `JWT_SECRET` 은 compose 에 개발용 기본값을 두어 `.env` 없이도 `config`·`up` 이 동작한다
  - **JVM 옵션**: 앱 기준인 `JAVA_OPTS` 로 통일 (`JAVA_TOOL_OPTIONS` 제거). 값을 주면 이미지 기본값을 대체하므로 G1·GC 로그·`ActiveProcessorCount=4` 까지 기본값에 넣었다. GC 로그는 named volume `gclogs`(`/logs`)
  - **healthcheck**: 앱 이미지에 curl·wget 이 없다(실행해 확인). `bash` 의 `/dev/tcp` 로 HTTP 를 직접 친다. 경로는 `APP_HEALTH_PATH`, 기본 `/actuator/health`
- 왜: 시드 생성은 역할 2 의 코드이고 규모별로 수십 분이 걸린다. 인프라가 감싸면 두 곳에서 관리된다.
  DB·JVM·인증 환경변수는 앱 레포 README 의 이름을 그대로 쓰는 편이 계약이 하나로 유지된다
- 되돌리려면: compose 의 환경변수 이름·healthcheck 블록을 이전 커밋에서 되살린다. `.env` 는 지우면 그만이다 (compose 는 없으면 건너뛴다)
- 남은 것: k6 시나리오와 `bench.config.yml targets` 는 여전히 비어 있다. 앱의 readiness probe 를 켜면 `APP_HEALTH_PATH` 를 `/actuator/health/readiness` 로 바꾼다

## 2026-09-20 / 사용성 / 컨테이너 조작은 make 를 거치지 않는다
- 정한 것: 루트에 `compose.yaml` 추가 (`include` 로 `compose/` 아래 두 파일, `env_file: versions.env`).
  `docker compose up -d --wait|ps|logs|down|config` 가 플래그 없이 그대로 된다.
  Makefile 에서 `up`·`down`·`down-v`·`ps`·`logs`·`config` 타깃과 `scripts/up.sh` 삭제. `make` 는 측정 절차(여러 단계를 순서대로)만 담당
- 왜: 기동·정지 같은 표준 동작까지 make 로 감싸면 docker 사용법을 알아도 이 레포의 사용법을 새로 익혀야 한다.
  `--env-file`·`-f` 조합을 감추려고 만든 래퍼였는데, `include` + `env_file` 로 compose 자체가 해결한다.
  healthy 대기는 compose 내장 `--wait` 로 충분해 `up.sh` 도 필요 없다
- 확인: 루트 `.env` 가 `versions.env` 를 덮어쓰는 순서까지 동작 확인. `docker compose config -q`, `check-resources`, `check-targets` 통과
- 되돌리려면: `compose.yaml` 을 지우면 이전처럼 `-f compose/compose.base.yml -f compose/compose.monitoring.yml --env-file versions.env` 를 붙여야 한다

## 2026-09-20 / 정리 / templates·results·루트 role-3.md 삭제
- 정한 것: `templates/` 삭제 (Dockerfile 은 앱 레포 것이 진실의 원천, compose.override 예시는 `docs/impl-guide.md` 4장 안으로 옮김),
  `results/` 의 스텁 측정 결과 2건 삭제(디렉터리와 `.gitkeep` 은 유지. 스크립트가 여기에 쓴다), 루트 `role-3.md` 사본 삭제(`.gitignore` 줄도 제거)
- 왜: 앱 레포가 생기면서 Dockerfile 템플릿이 이중 관리가 됐다(계약도 `SPRING_DATASOURCE_*`·`JAVA_TOOL_OPTIONS` 로 낡아 있었다).
  스텁 결과는 스텁 앱을 지운 뒤로 참조할 대상이 없다
- 되돌리려면: `git revert` 또는 해당 커밋에서 파일 복구. 스텁 결과는 진행 기록(`docs/progress.md`)에 수치가 남아 있다
- 유지: `run-test.sh` 는 측정 절차 전체(preflight → (reset → measure → collect → 쿨다운) × 회차 → report)라 지우지 않는다

## 2026-09-20 / 모니터링 / Grafana 는 기본 꺼짐
- 정한 것: `compose/compose.monitoring.yml` 의 `grafana:` 서비스와 `grafanadata:` 볼륨을 주석 처리.
  쓰려는 사람이 주석을 풀고 `docker compose up -d --wait`. 프로비저닝 파일(`monitoring/grafana/**`)과 대시보드 JSON 은 그대로 둔다
- 왜: 팀 합의로 대시보드는 붙이고 싶은 사람만 붙이기로 했다. 모니터링 코어(Prometheus·cAdvisor·exporter)는 측정 판정에 필요해 그대로 둔다
- 확인: `docker compose config --services` 에서 grafana 제외 (postgres, app, cadvisor, postgres_exporter, prometheus).
  Prometheus 는 Grafana 를 스크레이프하지 않으므로 `check-targets` 에 영향 없음. `check-dashboard` 는 Prometheus 에 직접 질의하므로 Grafana 없이 동작
- 되돌리려면: 그 블록들의 주석을 푼다 (예산표 `bench.config.yml budget.grafana` 는 남겨 뒀다)


## 2026-09-20 / 윈도우 지원 / 실행 환경을 Git Bash·WSL2 까지 넓힘
- 정한 것: 스크립트가 플랫폼을 직접 감지한다 (`scripts/lib/common.sh` 의 `BENCH_OS`). mac / linux / windows 세 갈래.
  WSL2 안에서 돌리면 linux 로 잡히고 그게 맞다
- 왜: 스터디 구성원 중 인텔 윈도우 호스트가 있다. 기존 코드는 "Darwin 아니면 리눅스" 라 Git Bash 에서 `/etc/os-release` 를 읽다 죽었다
- 되돌리려면: `BENCH_OS` 분기를 지우고 `uname -s` 직접 비교로 되돌린다

## 2026-09-20 / 윈도우 지원 / MSYS 경로 변환은 전부 끄지 않는다
- 정한 것: `MSYS2_ARG_CONV_EXCL='/results;/k6;/seed;/logs'` 만 설정. `MSYS_NO_PATHCONV=1` 을 전역으로 켜지 않는다.
  예외로 `preflight.sh` 의 `df -Pk /` 한 줄에만 붙였다
- 왜: Git Bash 는 슬래시로 시작하는 인자를 윈도우 경로로 바꾼다. 이 변환은 **호스트 경로에는 있어야** 맞다
  (`build-app.sh` 가 빌드 컨텍스트로 넘기는 경로). 전역으로 끄면 앱 빌드가 깨진다. 컨테이너 안 경로만 제외하는 게 맞다
- 되돌리려면: common.sh 의 해당 블록 삭제. 앱 레포 `seed/seed.sh` 는 호출마다 직접 붙이는 방식을 쓴다

## 2026-09-20 / 윈도우 지원 / 파이썬 실행 파일 이름
- 정한 것: `python3` 를 직접 부르지 않고 `py3` 함수를 쓴다. `python3` → `python` → `py -3` 순으로 실제 실행해 보고 고른다
- 왜: 윈도우에는 `python3` 가 없고 `python` 이나 `py -3` 만 있는 경우가 많다. 게다가 윈도우 기본 PATH 의 `python3` 는
  Microsoft Store 를 여는 껍데기라 `command -v` 로는 못 거른다. `cfg()` 가 파이썬을 쓰므로 이게 막히면 전부 멈춘다
- 되돌리려면: `py3` 호출을 `python3` 로 되돌리고 `resolve_python` 삭제

## 2026-09-20 / 윈도우 지원 / cAdvisor 마운트 경로를 변수로
- 정한 것: `CADVISOR_DOCKER_ROOT`, `CADVISOR_CONTAINERD_SOCK` 로 `.env` 에서 바꿀 수 있게 했다. 기본값은 기존 값 그대로.
  `check-targets.sh` 가 컨테이너별 지표가 나오는지 확인하고 안 나오면 경고한다
- 왜: 이 두 경로는 내가 macOS Docker Desktop VM 을 보고 맞춘 값이다. **윈도우에서는 확인하지 못했다.**
  WSL2 백엔드도 같은 경로일 가능성이 높지만 다르면 자원 패널만 빈다. 측정 자체는 계속 된다
- 되돌리려면: compose 의 `${...:-}` 를 고정 경로로 되돌린다
- **확인 필요**: 윈도우 사용자가 `make check-targets` 결과를 알려 줄 것

## 2026-09-20 / 윈도우 지원 / .gitattributes 로 줄바꿈 고정
- 정한 것: `* text=auto eol=lf` + 확장자별 `eol=lf`
- 왜: Git 기본값(`core.autocrlf=true`)으로 윈도우에서 클론하면 셸 스크립트가 CRLF 가 되고 bash 가 첫 줄에서 죽는다
- 되돌리려면: `.gitattributes` 삭제. 단, 이미 CRLF 로 받은 사람은 `git add --renormalize .` 가 필요하다

## 2026-09-23 / DB 통합 / 측정용 postgres 를 시드 생성기와 한 컨테이너로 합침
- 정한 것: compose 프로젝트 이름을 `bench` → `hjo-bench` 로 바꾸고, 측정용 postgres 의 볼륨을 `seed-pgdata`,
  계정을 `hjo`, 측정 DB 를 `bench` 로 맞췄다. 앱 레포 시드 생성기를 같은 프로젝트 이름으로 돌리면
  **같은 컨테이너·같은 볼륨**을 쓴다. 덤프로 옮기는 단계가 사라졌다 (`make seed`)
- 왜: postgres 가 둘이라 매번 `pg_dump | pg_restore` 로 옮겨야 했다. 프로파일을 바꿀 때마다 전체 복원이 필요했고,
  시드 생성기의 빠른 템플릿 복제(FILE_COPY)를 못 썼다
- 어떻게 한 컨테이너에서 두 설정을 쓰나: 생성할 때는 생성기가 자기 설정(WAL 4GB, 제한 없음)으로 컨테이너를 만들고,
  끝나면 `scripts/seed.sh` 가 `docker compose up -d --wait` 로 측정 설정(cpuset 0-3, 1GB, postgresql.conf)으로 되돌린다.
  데이터는 볼륨에 있어 그대로다. 생성·측정 설정 충돌을 재시작 한 번으로 푼 것
- 되돌리려면: `compose/compose.base.yml` 의 postgres 를 원래 값(볼륨 pgdata, 계정 bench)으로 되돌리고
  README 의 덤프 이관 절차를 되살린다
- 확인한 것: 템플릿 복제(`CREATE DATABASE ... TEMPLATE ... FILE_COPY`)는 **플래너 통계(pg_statistic)를 같이 복사한다.**
  복원 후 VACUUM ANALYZE 가 필요 없다. 다만 `pg_stat_user_tables.n_live_tup` 같은 누적 통계는 0 으로 보이므로
  행 수는 `pg_class.reltuples` 로 읽는다
- 남은 것: `compose.seed.yml` 을 INFRA 로 옮기는 건 보류. 앱 레포 `seed.sh` 가 그 파일이 자기 옆에 있다고 가정해서
  (`cd $(dirname $0); docker compose -f compose.seed.yml`) 옮기면 깨진다. 옮기려면 역할 2 와 조율해
  `SEED_COMPOSE` 환경변수를 받게 해야 한다

## 2026-09-23 / 측정값 / rate 50 req/s 는 baseline 이 감당하지 못한다
- 관찰: S 프로파일(글 5만)에서 `rate: 50` 으로 돌리면 회차가 무효로 나온다.
  postgres CPU 가 388%(cpuset 0-3 포화)까지 올라가고 모든 엔드포인트가 균일하게 느려진다 (p50 약 1,000ms, dropped 100+)
- 원인: 인덱스가 PK 뿐이라(study-spec 5장 baseline) 목록 조회가 매번 posts 5만 행 순차 스캔 + post_stats 해시 조인 + 정렬을 한다.
  한 번에 약 58ms, 병렬 워커 2개까지 붙어 CPU 로는 약 136ms. 초당 25건이면 4코어를 넘는다
- `rate: 15` 에서는 정상이다: p50 30.8ms, p95 37.5ms, p99 46.3ms, dropped 0, 유효
- 지금 한 것: 없음. `bench.config.yml` 의 `rate: 50` 은 원래 자리값이고 워크로드·SLO 가 확정되면 바뀐다
- **팀 결정 필요**: 목표 RPS 를 얼마로 잡을지. baseline 포화점이 20~40 req/s 근처라는 게 이번에 나온 실측이다

## 2026-09-23 / 미해결 / 9/20 측정값과 차이를 설명하지 못했다
- 9/20 같은 시나리오·같은 앱 이미지(9baff5ca6f26)·같은 S 프로파일에서 50 req/s 에 p50 21.5ms 가 나왔고 무효 회차가 없었다.
  지금은 같은 조건에서 p50 1,000ms 에 무효다
- 대조한 것: 앱 이미지 ID 동일, DB 크기 118MB→121MB(사실상 동일), 행 수 동일, postgresql.conf 동일,
  cpuset·mem_limit 동일, 플래너 통계 존재, 같은 VM 에 다른 프로젝트 컨테이너는 오히려 지금이 더 적다
- 차이는 DB 를 만든 방식뿐이다 (9/20 은 `pg_restore`, 지금은 템플릿 FILE_COPY 복제).
  그것만으로 5배 이상 차이가 날 이유를 찾지 못했다. **원인 미상으로 남긴다**
- 다음에 볼 것: 9/20 방식으로 한 번 더 만들어 같은 부하를 주고 실행계획을 비교
