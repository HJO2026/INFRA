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

