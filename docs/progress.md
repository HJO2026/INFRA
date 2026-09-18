# 진행 기록

| 단계 | 상태 | 판정 명령 결과 요약 | 커밋 |
|---|---|---|---|
| 0. 스캐폴드 | 통과 | `make help` 타깃 목록 출력. `scripts/pin-versions.sh` 2회 실행 → 두 번째 "변경 없음", `--check` 전부 일치. `versions.env` 7개 이미지 digest 채워짐. shellcheck 0 | (아래) |
| 1. Dockerfile 템플릿 + 스텁 앱 | 통과 | `scripts/build-stub.sh` → `templates/Dockerfile` 멀티스테이지로 `bench/stub-app:dev` 빌드 성공 (Spring Boot 3.5.16, Gradle 9.7.1 wrapper, JDK 25). 런타임 이미지 비루트, ENTRYPOINT 에 JVM 옵션 없음 | (아래) |
| 2. compose base | 통과 | `make up` → postgres·app healthy. `scripts/check-resources.sh` compose 설정·docker inspect 모두 예산표와 일치. `/actuator/prometheus` 에 `hikaricp_` 16줄. PG shared_buffers 256MB/max_connections 30/work_mem 4MB/UTC, JVM `JAVA_TOOL_OPTIONS` 주입 확인. 호스트 5432 충돌로 PG 호스트 포트 기본 15432 (open-questions) | (아래) |
| 3. 모니터링 | 통과 | `make up` 6개 서비스 healthy. `scripts/check-targets.sh` app·cadvisor·postgres_exporter·prometheus 전부 up. Grafana 익명 조회 200, Prometheus 데이터소스 프로비저닝 확인. remote-write receiver 켜짐(POST /api/v1/write → 400). cAdvisor 컨테이너별 CPU·메모리·디스크IO 시계열 확인 (Docker Desktop 마운트 조정, open-questions). check-resources 모니터링 4개 포함 일치 | (아래) |
| 4. 시드 복원 | 통과 | `make seed-stub-dump` → `seed/dumps/stub.dump` (pg_dump -Fc -Z 6, 10,000행, 264K). `make seed SEED_PROFILE=stub` 2회 연속 성공(--clean --if-exists 로 멱등), pg_restore -j 4 → VACUUM ANALYZE → 행 수 표(stub_ping 10000). 복원 중 app 은 잠시 정지 후 재시작. `/db` 가 rows 10000 반환 | (아래) |
| 5. 측정 파이프라인 | 통과 | `./run-test.sh stub 3` 완주 (exit 0, 약 7분). `results/20260918T065354Z-stub/report.md` 생성. 3회 전부 유효, `dropped_iterations` 0, 요청 3001/회차, 50 req/s, p50 2.33ms / p95 4.29 / p99 6.49 (중앙값). p99 편차 30.9% 경고 출력 (저부하 ms 단위 잡음. 경고 로직 동작 확인). k6 지표가 Prometheus 에 run_id/target/run_no 태그로 적재됨 | (아래) |
| 6. 대시보드 | 통과 | `monitoring/grafana/dashboards/bench-overview.json` (생성기 gen-dashboard.py, 7행 35패널 81쿼리, study-spec 8장 지표 전부). `scripts/check-dashboard.sh`: 필수(stub) 쿼리 비어 있음 0, optional 5 (GC pause ×3: GC 미발생, cfs throttling, 네트워크), later 4 (e2e, Kafka). Grafana 프로비저닝 로드 확인. Tomcat 지표 위해 스텁에 mbeanregistry 켬, exporter 에 checkpointer 컬렉터·커스텀 쿼리 추가 | (아래) |
| 7. 문서 | 통과 | `README.md`, `docs/impl-guide.md`, `templates/compose.override.yml`, `docs/harness-notes.md`. README 명령만 순서대로 실행 (`make down -v` → up → check-resources → check-targets → seed-stub-dump → seed → preflight → `./run-test.sh stub 3` → check-dashboard) 전부 exit 0. `results/20260918T070555Z-stub/report.md` 3회 유효, dropped 0, 대시보드 필수 패널 비어 있음 0 | (아래) |

커밋 이력은 `git log --oneline` (stage 0 ~ stage 7, 각 단계 1커밋).

---

# 요약 (2026-09-18, 역할 3 작업 종료)

## 단계 판정

| 단계 | 판정 | 비고 |
|---|---|---|
| 0 스캐폴드 | 통과 | |
| 1 Dockerfile 템플릿 + 스텁 | 통과 | 템플릿 런타임에 `curl` 추가 (healthcheck 용) |
| 2 compose base | 통과 | PG 호스트 포트 기본 15432 (호스트 5432 충돌) |
| 3 모니터링 | 통과 | cAdvisor 마운트를 Docker Desktop 기준으로 조정 |
| 4 시드 복원 | 통과 | 스텁 덤프만. S/M/L 은 역할 2 배포본 필요 |
| 5 측정 파이프라인 | 통과 | 스텁 3회 완주. 실제 워크로드 시나리오는 미결 (뼈대만) |
| 6 대시보드 | 통과 | GC pause 패널은 optional (스텁 부하로 GC 미발생) |
| 7 문서 | 통과 | README 순서대로 재현 성공 |

**부분(범위상 뼈대만)**: `k6/scenarios/` 실제 워크로드(이벤트·좋아요·목록·상세), `verify/` 내용, Kafka/Redis compose 프로파일(예시는 `templates/compose.override.yml`).
**실패**: 없음.

## open-questions 중 사람이 결정해야 할 것 (`docs/open-questions.md`)

1. **모니터링 이미지 버전**: Prometheus v3.14.0, Grafana 12.4.11(13.x 아님), cAdvisor v0.55.1, postgres_exporter v0.20.1. 이대로 `v1` 태그로 고정할지
2. **Docker Desktop 디스크 30GB**: M/L 덤프(6~35GB) 전에 60GB+ 로 올려야 한다. preflight 는 경고만
3. **PG 호스트 포트 15432**: 이 호스트의 다른 컨테이너(`postgres_db`) 때문. 공통 기본값으로 둘지, 각자 `PG_HOST_PORT` 로 맞출지
4. **루트 `role-3.md` 사본**: `.gitignore` 로 제외만 했다. 지워도 되는지
5. **템플릿에 curl 설치, `memswap_limit` 고정**: 앱 이미지 계약에 넣을지 (impl 이미지 크기 +수 MB)
6. **GC pause 패널 optional**: 실제 워크로드에서 GC 가 나오면 `stub` 으로 되돌릴지
7. **e2e 적재 지연 지표 이름** `bench.ingest.e2e` 제안 (역할 1 합의 필요)
8. **postgres_exporter `--extend.query-path`** 가 deprecated. 다음 exporter 버전에서 없어지면 대체 방법 필요
9. **cAdvisor 마운트가 Linux 호스트에서 다를 수 있음**: 스터디의 인텔 호스트가 Linux 면 표준 마운트를 다시 넣어야 한다. 한 번 확인 필요
10. **측정 값 기본치** (`bench.config.yml measure`): rate 50/s, 워밍업 30s, steady 60s, 쿨다운 60s, VU 50~200 은 스텁용 임시값. SLO·목표 RPS 확정 후 교체
11. **preflight 의 외부 컨테이너 경고**를 실패로 바꿀지 (지금은 kafka-ui, mysql_db, postgres_db 가 떠 있는 채로 측정했다)

## 역할 1 (스프링·스키마·테스트) 에게 전달할 인터페이스 요구사항

- **이미지 계약** (`docs/impl-guide.md` 1·2장): 포트 8080, `/actuator/health/readiness` 가 `"UP"`, `/actuator/prometheus`, DB 는 `SPRING_DATASOURCE_URL/USERNAME/PASSWORD`, JVM 옵션은 Dockerfile 에 넣지 않음(compose 가 `JAVA_TOOL_OPTIONS` 주입), `bootJar` 이름 `app.jar` (또는 Dockerfile COPY 수정), `templates/Dockerfile` 그대로 사용
- **지표 설정**: `management.metrics.distribution.percentiles-histogram.http.server.requests=true`, `server.tomcat.mbeanregistry.enabled=true`, 비동기 적재는 Timer `bench.ingest.e2e`(percentiles-histogram). 이게 없으면 서버 지연·톰캣·e2e 패널이 빈다
- **스키마 적용 주체**: bench-infra 는 스키마를 만들지 않는다. 앱이 시작 시 마이그레이션(Flyway 등)을 적용해야 하고, 덤프 복원(`pg_restore --clean`, 덤프에 스키마 포함) 뒤에 앱이 재시작해도 깨지지 않아야 한다 (마이그레이션 히스토리 테이블이 덤프에 포함되는지 역할 2 와 합의)
- **회차 초기화 대상**: `bench.config.yml reset.truncate_tables` 에 넣을 테이블명 (예: `post_view_events`, `post_likes`) 과 TRUNCATE 만으로 충분한지(집계 테이블, 시퀀스, 캐시, 토픽). 추가 초기화가 필요하면 방식을 알려 줄 것
- **인증**: k6 가 쓸 JWT. 토큰 발급은 측정 제외이므로 시나리오 환경변수(예: `BENCH_JWT`)로 미리 발급한 장기 토큰을 넣는 방식을 제안. 발급 방법·만료를 정해 줄 것
- **응답 규약**: 유효 요청은 200/202 만. 4xx 가 나오면 회차가 무효 처리된다 (`scripts/collect.sh`)
- **verify/**: 부하 후 정합성 검증 항목(이벤트 유실, 좋아요 중복, 카운트 일치)과 판정 SQL. 뼈대만 있음
- **compose.override.yml**: 추가 컴포넌트는 `templates/compose.override.yml` 규칙(cpuset 0-3, 예산표 mem_limit, named volume, 태그 고정). `bench.config.yml budget` 에 없는 서비스는 `check-resources` 가 실패시킨다

## 역할 2 (시드) 에게 전달할 인터페이스 요구사항

- **덤프 형식**: `pg_dump -Fc -Z 6` 로 **전체 DB(스키마 + 데이터)**. 파일명 `seed/dumps/S.dump`, `M.dump`, `L.dump`. DB·유저 `bench`
- **복원 방식** (`scripts/seed.sh`): `pg_restore -j 4 --clean --if-exists --no-owner --no-privileges --exit-on-error` → `VACUUM ANALYZE` → 테이블별 행 수. `--exit-on-error` 라 덤프 안의 확장·롤 의존이 있으면 실패한다. 확장이 필요하면 미리 알려 줄 것
- **검증 값**: 배포 시 테이블별 행 수와 파일 sha256 을 같이 준다 (seed.sh 가 출력하는 표와 대조)
- **ERD 불일치**(study-spec 11장: `boards`, `post_stats` vs `users`) 는 역할 1 과 정리해야 `reset.truncate_tables` 와 k6 키 분포를 채울 수 있다
- **k6 키 분포 파라미터**: 인기 글 ID 범위, Zipf 파라미터, 사용자 ID 범위. `k6/lib/common.js` 의 시드 고정 난수(`makeRng`)로 재현 가능하게 만들 자리는 있다
- **용량**: M 6~8GB, L 25~35GB 면 Docker Desktop 디스크(현재 30GB) 를 먼저 늘려야 한다
