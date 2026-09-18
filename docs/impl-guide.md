# impl 레포 연결 가이드

역할 1·2 와 각 impl 레포(`impl-<name>`)가 bench-infra 에 붙는 방법. 측정 절차는 bench-infra 에만 있고
impl 레포는 **이미지, `compose.override.yml`, 마이그레이션** 만 제공한다 (study-spec 10장).

## 1. 앱 이미지 계약

| 항목 | 값 |
|---|---|
| 포트 | 8080 |
| 헬스 | `GET /actuator/health` (compose healthcheck 는 `/actuator/health/readiness` 에 `"UP"` 을 기대) |
| 지표 | `GET /actuator/prometheus` (`micrometer-registry-prometheus` 의존성) |
| DB 접속 | 환경변수 `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD` |
| JVM 옵션 | Dockerfile 에 하드코딩 금지. compose 가 `JAVA_TOOL_OPTIONS` 로 주입 (기본 `-Xms1g -Xmx1g -XX:+UseG1GC -Xlog:gc`) |
| 시간대 | 컨테이너 `TZ=UTC`. 앱도 UTC 로 동작해야 한다 |
| 로깅 | study-spec 4장 수준(`root: WARN`). 동기 로깅이면 문서화 |

대시보드 패널이 채워지려면 앱 설정에 아래가 필요하다 (스텁 앱 `stub-app/src/main/resources/application.yml` 참고):

```yaml
management:
  endpoints.web.exposure.include: health,prometheus,metrics
  endpoint.health.probes.enabled: true
  metrics.distribution.percentiles-histogram.http.server.requests: true   # 서버 지연 p50/p95/p99 패널
server:
  tomcat.mbeanregistry.enabled: true                                       # 톰캣 스레드·커넥션 패널
```

비동기 적재 구현은 e2e 적재 지연을 Micrometer Timer `bench.ingest.e2e` (percentiles-histogram 켬) 로 내면 대시보드
"e2e 적재 지연" 패널에 바로 잡힌다. 다른 이름을 쓰면 `monitoring/grafana/gen-dashboard.py` 의 쿼리를 바꾼다.

## 2. Dockerfile 복사

```bash
cp bench-infra/templates/Dockerfile impl-<name>/Dockerfile
cd impl-<name>
docker build -t bench/impl-<name>:v1 --build-arg JDK_IMAGE=eclipse-temurin:25-jdk .
```

- 빌드 컨텍스트는 Gradle 프로젝트 루트(`gradlew`, `build.gradle(.kts)`, `src/`).
- `bootJar` 산출물 이름을 `app.jar` 로 맞추거나 (`tasks.bootJar { archiveFileName = "app.jar" }`) Dockerfile 의 `COPY` 경로를 고친다.
- 런타임 스테이지는 비루트(`app`)로 실행되고 `curl` 이 들어 있다(healthcheck 용). 그 외 JVM 옵션·환경변수는 넣지 않는다.
- 태그는 명시 버전만 (`latest` 금지). 측정 결과에 이미지 ID 가 기록된다.

## 3. bench-infra 에 target 등록

`bench.config.yml` 의 `targets` 에 추가한다:

```yaml
targets:
  impl-<name>:
    image: bench/impl-<name>:v1
    scenario: smoke                      # k6/scenarios/<scenario>.js (실제 워크로드 시나리오는 미결)
    override: /abs/path/impl-<name>/compose.override.yml   # 추가 컴포넌트가 있을 때만
```

이후 `./run-test.sh impl-<name> 3`, 또는 baseline 과 같이 `./run-test.sh baseline,impl-<name> 3` (회차마다 순서 무작위).

단발 확인은 환경변수로도 된다: `APP_IMAGE=bench/impl-<name>:v1 make up`.

## 4. 추가 컴포넌트 (compose.override.yml)

`templates/compose.override.yml` 을 복사해 시작한다. 지킬 것:

- cpuset `"0-3"` (SUT 코어 안에서), `mem_limit` 은 `docs/role-3.md` 예산표 (Kafka 1280m, Redis 320m). 예산 변경은 근거와 함께 `docs/open-questions.md` 에
- 데이터는 named volume, bind mount 는 설정 파일만
- 이미지 태그 고정. `versions.env` 에 태그·digest 추가 후 `make pin`
- 회차 초기화(토픽 재생성 등)가 필요하면 `bench.config.yml reset` 섹션 확장이 필요하다. 지금은 `truncate_tables` 와 `restart_services` 만 있다 (open-questions 참고)
- `make check-resources` 가 override 서비스도 예산표(`bench.config.yml budget`)와 대조한다. 예산표에 없는 서비스는 실패한다

## 5. 스키마·시드 (역할 1·2)

- 스키마·마이그레이션은 impl 이미지가 시작할 때 스스로 적용한다 (Flyway 등). bench-infra 는 스키마를 만들지 않는다.
- 시드 덤프는 `seed/dumps/<S|M|L>.dump` 에 둔다. 형식: `pg_dump -Fc -Z 6` (스키마 + 데이터, 전체 DB). `make seed SEED_PROFILE=M` 이
  `pg_restore -j 4 --clean --if-exists --no-owner` → `VACUUM ANALYZE` → 테이블별 행 수 순으로 복원한다.
  덤프에 스키마가 포함되어야 `--clean` 이 깨끗하게 동작한다. 앱은 복원 중 잠시 멈췄다 다시 뜬다.
- 회차마다 비우는 "측정 대상 테이블" 은 `bench.config.yml reset.truncate_tables` 에 있다. 지금은 스텁 테이블(`stub_ping`) 이고,
  실제 스키마가 확정되면 `post_view_events`, `post_likes` 등으로 교체한다 (역할 1 이 알려 줄 것).

## 6. 결과 읽기

`results/<run-id>/report.md` 에 회차별 처리량·p50/p95/p99·에러율, 유효 회차 중앙값, 편차(%) 표가 생긴다.
`dropped_iterations ≠ 0` 또는 4xx 가 있으면 그 회차는 무효로 표시된다. 각 회차의 시간 범위는 `metrics.json` 의 `started_at`/`ended_at`.
Grafana(`http://localhost:3000`, 익명 조회) 의 `bench overview` 대시보드에서 그 범위를 보고 스크린샷을 리포트에 붙인다.
