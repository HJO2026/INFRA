# impl 레포 연결 가이드

역할 1·2 와 각 impl 레포(`impl-<name>`)가 bench-infra 에 붙는 방법. 측정 절차는 bench-infra 에만 있고
impl 레포는 **이미지, `compose.override.yml`, 마이그레이션** 만 제공한다 (study-spec 10장).

## 1. 앱 이미지 계약

| 항목 | 값 |
|---|---|
| 포트 | 8080 |
| 헬스 | `GET /actuator/health` 가 `{"status":"UP"}`. compose healthcheck 는 이미지에 curl 이 없다고 보고 `bash` 의 `/dev/tcp` 로 친다. 경로는 `APP_HEALTH_PATH` (기본 `/actuator/health`, probes 를 켰으면 `/actuator/health/readiness`) |
| 지표 | `GET /actuator/prometheus` (`micrometer-registry-prometheus` 의존성) |
| DB 접속 | 환경변수 `DB_WRITE_URL`, `DB_USERNAME`, `DB_PASSWORD` (앱 레포 환경변수 표와 같은 이름). 노브: `DB_POOL_SIZE`, `VIRTUAL_THREADS_ENABLED` |
| 인증 | `JWT_SECRET` (HS256, 32바이트 이상). compose 가 `.env` 에서 읽어 넣는다 |
| JVM 옵션 | compose 가 `JAVA_OPTS` 로 주입한다. **값을 주면 이미지 기본값을 대체**하므로 G1·GC 로그 옵션까지 함께 넣는다. 기본값 `-Xms1g -Xmx1g -XX:+UseG1GC -XX:ActiveProcessorCount=4 -Xlog:gc*:file=/logs/gc.log:time,uptime` |
| GC 로그 | 컨테이너 `/logs/gc.log` (named volume `gclogs`). 꺼내기: `docker compose cp app:/logs/gc.log results/<run-id>/` |
| 시간대 | 컨테이너 `TZ=UTC`. 앱도 UTC 로 동작해야 한다 |
| 로깅 | study-spec 4장 수준(`root: WARN`). 동기 로깅이면 문서화 |

대시보드 패널이 채워지려면 앱 설정에 아래가 필요하다:

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

## 2. Dockerfile

**앱 레포(`../APP`)의 `Dockerfile` 을 그대로 쓴다.** bench-infra 는 Dockerfile 템플릿을 두지 않는다
(앱 레포가 Temurin 25 고정 2단계 빌드 + non-root + graceful shutdown 을 이미 갖고 있다).

```bash
docker build -t bench/impl-<name>:v1 .          # impl 레포 루트에서
```

- 빌드 컨텍스트는 Gradle 프로젝트 루트(`gradlew`, `build.gradle(.kts)`, `src/`).
- 태그는 명시 버전만 (`latest` 금지). 측정 결과에 이미지 ID 가 기록된다.
- 이미지에 curl·wget 이 없어도 된다. compose healthcheck 는 `bash` 의 `/dev/tcp` 로 친다 (1장).

## 3. bench-infra 에 target 등록

`bench.config.yml` 의 `targets` 에 추가한다:

```yaml
targets:
  impl-<name>:
    image: bench/impl-<name>:v1
    scenario: <scenario>                 # k6/scenarios/<scenario>.js (실제 워크로드 시나리오는 미결)
    override: /abs/path/impl-<name>/compose.override.yml   # 추가 컴포넌트가 있을 때만
```

이후 `./run-test.sh impl-<name> 3`, 또는 baseline 과 같이 `./run-test.sh baseline,impl-<name> 3` (회차마다 순서 무작위).

단발 확인은 환경변수로도 된다: `APP_IMAGE=bench/impl-<name>:v1 docker compose up -d --wait`.

## 4. 추가 컴포넌트 (compose.override.yml)

impl 레포 루트에 `compose.override.yml` 을 두고 `-f` 로 합친다. 지킬 것:

- cpuset `"0-3"` (SUT 코어 안에서), `mem_limit` 은 `docs/role-3.md` 예산표 (Kafka 1280m, Redis 320m). 예산 변경은 근거와 함께 `docs/open-questions.md` 에
- 데이터는 named volume, bind mount 는 설정 파일만
- 이미지 태그 고정. `versions.env` 에 태그·digest 추가 후 `make pin`
- 회차 초기화(토픽 재생성 등)가 필요하면 `bench.config.yml reset` 섹션 확장이 필요하다. 지금은 `truncate_tables` 와 `restart_services` 만 있다 (open-questions 참고)
- `make check-resources` 가 override 서비스도 예산표(`bench.config.yml budget`)와 대조한다. 예산표에 없는 서비스는 실패한다

붙이는 법:

```bash
docker compose -f compose.yaml -f /abs/path/impl-<name>/compose.override.yml up -d --wait
make reset COMPOSE_OVERRIDE=/abs/path/impl-<name>/compose.override.yml
./run-test.sh impl-<name> 3      # bench.config.yml targets.<name>.override 에 적어 두면 자동
```

Kafka 를 붙이는 예시 (Redis 는 주석):

```yaml
name: bench

services:
  app:
    environment:
      # 예: 앱이 추가 컴포넌트 주소를 환경변수로 받는 경우
      SPRING_KAFKA_BOOTSTRAP_SERVERS: kafka:9092
    depends_on:
      kafka:
        condition: service_healthy

  # 예시: Kafka (KRaft 단일 노드). 도입 시 태그·digest 는 versions.env 에 추가하고 open-questions 에 근거를 적는다
  kafka:
    image: apache/kafka:4.0.0            # 예시 태그. 실제 도입 시 make pin 으로 digest 고정
    container_name: bench-kafka
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_NUM_PARTITIONS: 4            # study-spec 5장 baseline
      KAFKA_HEAP_OPTS: -Xmx1g -Xms1g
      TZ: UTC
    volumes:
      - kafkadata:/var/lib/kafka/data
    cpuset: "0-3"
    mem_limit: 1280m
    memswap_limit: 1280m
    healthcheck:
      test: ["CMD-SHELL", "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    networks: [bench]

  # 예시: Redis
  # redis:
  #   image: redis:8.0.3-bookworm
  #   command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru", "--save", ""]
  #   cpuset: "0-3"
  #   mem_limit: 320m
  #   memswap_limit: 320m
  #   networks: [bench]

volumes:
  kafkadata:
```

## 5. 스키마·시드 (역할 1·2)

- 스키마·마이그레이션은 impl 이미지가 시작할 때 스스로 적용한다 (Flyway 등). bench-infra 는 스키마를 만들지 않는다.
- 시드는 앱 레포의 `seed/` 생성기가 만든다 (덤프 배포 아님, `seed/README.md`). bench-infra 에는 시드 생성·복원 코드가 없다.
  측정용 postgres 로 옮기는 방법은 미정 (`docs/open-questions.md`).
- 회차마다 비우는 "측정 대상 테이블" 은 `bench.config.yml reset.truncate_tables` 에 둔다. 지금은 비어 있고,
  측정 대상이 확정되면 `post_view_events`, `post_likes` 등을 넣는다 (역할 1 이 알려 줄 것).

## 6. 결과 읽기

`results/<run-id>/report.md` 에 회차별 처리량·p50/p95/p99·에러율, 유효 회차 중앙값, 편차(%) 표가 생긴다.
`dropped_iterations ≠ 0` 또는 4xx 가 있으면 그 회차는 무효로 표시된다. 각 회차의 시간 범위는 `metrics.json` 의 `started_at`/`ended_at`.
Grafana(`http://localhost:3000`, 익명 조회) 의 `bench overview` 대시보드에서 그 범위를 보고 스크린샷을 리포트에 붙인다.
