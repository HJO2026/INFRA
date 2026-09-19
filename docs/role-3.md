# 역할 3: 세팅·스크립트

## 범위
- compose (base + monitoring, 이후 kafka/redis 프로파일 자리만)
- 컨테이너별 cpuset·메모리 제한, PG 설정 파일(baseline 값은 study-spec 5장)
- 모니터링 스택: Prometheus, cAdvisor, postgres_exporter (+ Grafana 프로비저닝. 2026-09-20 부터 기본 꺼짐, 쓰는 사람만 주석 해제)
- 측정 절차 스크립트: preflight, reset, measure, collect, report, `run-test.sh`
- 공통 Grafana 대시보드 JSON (study-spec 8장 지표 목록)
- ~~앱 Dockerfile 템플릿 + 스텁 앱~~ (2026-09-20 제거. Dockerfile 은 앱 레포 것, `templates/` 도 삭제)
- 사용 문서 (README, impl 레포 연결 가이드)

## 범위 밖 (수정 금지)
- 스프링 앱 코드, 스키마·마이그레이션, contract-tests, broken-impls: 역할 1
- 시드 생성 스크립트와 데이터: 역할 2 (앱 레포 `feat/seed-data`의 `seed/`)
- 경계 애매, 러너와 뼈대만 만들고 내용은 TODO로 남김: k6 실제 워크로드 시나리오(워크로드 미결), verify 스크립트 내용

## 외부 인터페이스
| 대상 | 연결 방식 | 기본값 |
|---|---|---|
| 앱 이미지 | 환경변수 `APP_IMAGE`, `make build-app APP_DIR=<앱 레포>` | `hjo-app:dev`, `../APP` |
| 시드 데이터 | 앱 레포 `seed/seed.sh s\|m\|l` 로 생성 → `pg_dump \| pg_restore` 한 줄로 측정용 postgres 로 이관 (README) | 규모 s |
| 비밀값·노브 | `.env` (`.env.example` 복사). compose 가 `versions.env` 다음에 읽는다 | `JWT_SECRET` 은 개발용 기본값 |
| impl 추가 컴포넌트 | impl 레포의 `compose.override.yml`을 `-f`로 합침 | 없음 |

앱 이미지 계약 (study-spec 10장 + 앱 레포 README 의 환경변수 표): 포트 8080, `/actuator/health`와 `/actuator/prometheus` 노출,
DB 접속은 `DB_WRITE_URL/DB_USERNAME/DB_PASSWORD`, 인증은 `JWT_SECRET`, JVM 옵션은 compose의 `JAVA_OPTS`로 주입
(값을 주면 이미지 기본값을 대체한다). 기본 JVM 옵션: `-Xms1g -Xmx1g -XX:+UseG1GC -XX:ActiveProcessorCount=4 -Xlog:gc*:file=/logs/gc.log:time,uptime`.
healthcheck 는 이미지에 curl 이 없어 `bash` 의 `/dev/tcp` 로 친다 (`APP_HEALTH_PATH`, 기본 `/actuator/health`).

## 리소스 예산 (초기안, 변경 시 근거 기록)
| 컨테이너 | cpuset | mem_limit |
|---|---|---|
| app | 0-3 | 1.25g |
| postgres | 0-3 | 1g |
| (kafka, 나중) | 0-3 | 1.25g |
| (redis, 나중) | 0-3 | 320m |
| k6 | 4-5 | 1g |
| prometheus | 6 | 512m |
| grafana (선택) | 6 | 256m |
| cadvisor | 6 | 256m |
| postgres_exporter | 6 | 64m |

## 단계와 완료 판정

### 0. 스캐폴드
디렉터리, `.gitignore`(seed/dumps, results 원본), `Makefile`(help 타깃), `versions.env`,
`scripts/pin-versions.sh`(태그로 digest 조회해 versions.env 갱신).
- 판정: `make help` 출력, `scripts/pin-versions.sh` 실행 후 versions.env 모든 이미지에 digest 존재

### 1. Dockerfile 템플릿 + 스텁 앱
`templates/Dockerfile`: 멀티스테이지(Gradle 빌드 → `eclipse-temurin:25-jdk` 런타임), JVM 옵션 하드코딩 금지.
`stub-app/`: Spring Boot 3.5.x, actuator + micrometer-registry-prometheus + JDBC(PostgreSQL),
`GET /ping`, `GET /db`(DB 왕복 1회), 테이블 1개. Gradle이 없으면 start.spring.io로 wrapper 포함 생성.
- 판정: 템플릿으로 스텁 이미지 빌드 성공

### 2. compose base
postgres(`postgres/postgresql.conf`: shared_buffers 256MB, max_connections 30, work_mem 4MB, UTC), app.
cpuset·mem_limit은 예산표대로. healthcheck 포함.
- 판정: `docker compose up -d --wait` 후 전부 healthy, `scripts/check-resources.sh`가 `docker inspect`로 CpusetCpus·Memory를 예산표와 대조해 통과,
  `curl /actuator/prometheus`에 `hikaricp_` 지표 존재

### 3. 모니터링
Prometheus(스크레이프 5초, remote-write receiver on), Grafana(데이터소스·대시보드 프로비저닝, 익명 조회),
cAdvisor, postgres_exporter.
- 판정: `scripts/check-targets.sh`가 Prometheus `/api/v1/targets`에서 전 타깃 up 확인

### 4. 시드 복원
`make seed SEED_PROFILE=<S|M|L|stub>`: `pg_restore -j 4` → `VACUUM ANALYZE` → 테이블별 행 수 출력.
스텁 덤프 생성 스크립트 포함(스텁 앱 테이블만).
- 판정: stub 프로파일로 복원 성공, 행 수 출력

### 5. 측정 파이프라인
- `scripts/preflight.sh`: VM CPU·메모리, 디스크 여유, 이미지 digest 일치, 컨테이너 상태
- `scripts/reset.sh`: 컨테이너 재시작 + 측정 대상 테이블 초기화(대상 목록은 `bench.config.yml`) + `VACUUM ANALYZE`.
  OS 페이지 캐시는 못 비움을 로그에 남김
- `k6/scenarios/smoke.js`: `constant-arrival-rate`로 `/ping`, `/db`. 워밍업 시나리오와 측정 시나리오 분리(태그로 구분),
  `--out experimental-prometheus-rw`, `--summary-export`
- `scripts/collect.sh`: 요약 JSON 수집, `dropped_iterations` ≠ 0이면 회차 invalid 표시
- `scripts/report.sh`: 회차별 처리량, p50/p95/p99, 에러율 → 중앙값과 편차(%) 표를 `results/<run-id>/report.md`로.
  백분위 산술평균 금지. 편차 15% 초과 시 경고
- `run-test.sh <target> <runs>`: preflight → (reset → measure → collect → 쿨다운) × runs → report.
  target 여러 개면 순서 무작위화. 난수 시드 고정
- 판정: `./run-test.sh stub 3` 완주, report.md 생성, dropped_iterations 0

### 6. 대시보드
study-spec 8장 지표 목록 전부 패널로. 지금 없는 지표(Kafka 등)도 패널은 만들어 둠.
- 판정: `scripts/check-dashboard.sh`가 각 패널 쿼리를 Prometheus에 실행해 결과 유무 목록 출력.
  스텁 환경에서 나와야 할 것(HTTP, JVM, Hikari, PG, 컨테이너 CPU·메모리)이 비어 있지 않음

### 7. 문서
`README.md`(사전 준비, 명령 사용법), `docs/impl-guide.md`(impl 레포가 Dockerfile 복사하고 override 붙이는 법, 이미지 계약).
- 판정: README 명령만 따라 `docker compose down -v` 후 처음부터 단계 2~5 재현 성공
