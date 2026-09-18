> 원본: 공통 세팅 리스트 및 정의, 규칙 관련, ERD 도메인 관련
> 

> 결정 근거와 상세 설명은 원본 토글에 있음. 이 페이지는 결론만.
> 

---

# 1. 스터디 개요

| 항목 | 결정 |
| --- | --- |
| 목표 | 서버 고도화: DB, 측정/개선. 요구사항을 한정된 리소스로 만족시키는 설계와 그 대가를 검증 |
| 기간 | 15주, 수요일 5시 (밥 먹고 스터디) |
| 토픽 | Throughput → Volume → Concurrency (ISO 품질 참고) |
| 산출물 | GitHub Organization + 문서 |
| 불참·이탈 | 과반수 동의 |

### 단계 구성

| 단계 | 하는 일 | 핵심 개념 | 기간 |
| --- | --- | --- | --- |
| 0. 세팅 | API + 도커 환경 + 측정 도구 | 제약조건, 부하 생성, 모니터링 | 2주 |
| 1. Throughput | 대량 이벤트 수집, 버퍼, 배치 적재 | 큐, 배치, 백프레셔, 비동기, 파티션 병렬 | 3주 |
| 2. Volume | 쌓인 데이터 파티셔닝·정리 | 파티셔닝, 인덱스 한계, 콜드/핫, 보관정책 | 3주 |
| 3. Concurrency | 동시 조회 폭주 대응 | 캐시, stampede, 복제본, 커넥션 풀 | 3주 |
| 4. 통합·회고 | 누적 상태 최종 부하테스트 | 병목 재발견, 결정 로그 정리 | 1주 |

남는 주차는 버퍼. 공통 API·스키마·측정 절차 변경은 버퍼 주간에만 반영.

### 토픽당 3주 사이클

1. **1주차**: 각자 해결 방식(아키텍처, 설정) 공유 및 피드백
2. **2주차**: 1.5주차까지 코딩 완료, 스터디에서 상호 리뷰 (질문 미리 준비)
3. **3주차**: 피드백 반영, 최종 측정, 수치 비교, 최종 리뷰

장단점, 트레이드오프, 대안까지 공유. 코어는 직접 구현, 확장 개념(예: 샤딩)은 발제 + 소규모 실험.

### 0단계 역할 분담

| 역할 | 범위 |
| --- | --- |
| 1 | 스프링 코드(baseline), 테스트 코드(contract-tests), JVM 설정, 하네스 |
| 2 | 시드 데이터 (생성 스크립트, S/M/L 덤프) |
| 3 (허유진) | 세팅·스크립트: compose, 리소스·cpuset, PG 설정, 모니터링 스택, 측정 스크립트, 대시보드, 앱 Dockerfile 템플릿 |

---

# 2. 원칙

1. **같은 문제를 푼다**: 도메인, API 의미, 데이터, 부하, 리소스 동일
2. **같은 절차로 잰다**: 측정은 스크립트가 실행 (`make` 스크립트에 로직, Actions는 호출만)
3. **이득과 대가를 같이 잰다**: 처리량·지연 + 유실·정합성·복구·복잡도. 연쇄 문제(동시성, 정합성)는 테스트 코드로 검증
4. **비교는 배율**: 절댓값은 기록하되 결과는 "5배 개선"처럼 표현
5. **컴포넌트 추가는 측정 근거 먼저**: 무엇이 병목이었고 왜 넣는지 수치로 제시
6. 코드 스타일(계층형, DDD 등)과 아키텍처 선택은 자유
7. 스케일아웃(replica, 클러스터)은 성능 비교가 아니라 동작·일관성·장애 관찰 용도

---

# 3. 하드웨어·리소스

| 항목 | 결정 |
| --- | --- |
| 호스트 | M1 8코어 16GB / 인텔 10코어(8+2) 16GB |
| 실행 환경 [확정] | 로컬 Docker + cpuset이 공식 측정 환경. GitHub Actions 러너는 부하 측정에 쓰지 않음 (①② 테스트 자동 실행용) |
| 코어 분배 (cpuset 분리) | SUT 4 / 부하 생성기 2 / 모니터링 1. Docker VM CPU는 7개 이상 할당 |
| 메모리 [확정] | Docker 실행 환경(Docker Desktop/Colima VM)에 할당하는 메모리 8GB. SUT·k6·모니터링 전부 이 안에서 나눔. baseline SUT 약 3.8GB, 나머지가 k6·모니터링·여유 |
| 리소스 자유도 | 컨테이너 총량(`--cpus`, `-m`)은 공통 고정. 컴포넌트 내부 설정(JVM, 커넥션 풀, 파티션 등)은 자유 = 최적화 전략 |
| 측정 유효성 | k6 `dropped_iterations` ≠ 0 이면 해당 측정 무효 |
| 알려진 한계 | L3 캐시·메모리 대역폭 경합은 cpuset으로 못 막음. 리포트에 한계로 명시 |
| 디스크 | DB·Kafka 데이터는 named volume, bind mount는 설정 파일·스크립트만 |
| 저장 공간 | 60GB 이상 (외장이면 SSD). Docker Desktop 디스크 이미지 크기 별도 설정, `docker system df -v`로 주기 확인 |

**호스트 스펙 기록 항목**: CPU 모델·물리 코어, 메모리, 디스크 종류(NVMe/SATA), OS 버전, Docker 런타임(Desktop/Colima/네이티브), VM 할당 CPU·메모리

---

# 4. 소프트웨어 스택

| 항목 | 결정 | 비고 |
| --- | --- | --- |
| JDK | 25 (LTS), `eclipse-temurin:25-jdk` | 가상 스레드 pinning 완화 |
| Spring Boot | 3.5.x | 서드파티 자료·트러블슈팅이 3.x 위주 |
| 웹 스택 | MVC 기본, 가상 스레드 선택. WebFlux 자유 |  |
| DBMS | PostgreSQL 18.6 (`postgres:18.6-bookworm`) | 선언적 파티셔닝. 단, AIO 도입으로 튜닝 자료 대부분이 17 이하 기준 |
| 시작 구성 | 앱 + DB 두 개만 | Nginx·Kafka·Redis는 필요해질 때 추가 |
| 이미지 태그 | 명시 버전 고정, latest 금지. `versions.env`에 digest | k6 `grafana/k6:2.1.0`, Kafka·Redis는 도입 시 결정 |
| GC 로그 | `-XX:+UseG1GC -Xlog:gc` 켜기 | p99 스파이크 원인 확인용 |
| Logback | AsyncAppender 사용 여부 문서화 | 동기 로깅은 고처리량에서 병목 |

```yaml
logging:
  level:
    root: WARN
    com.mycompany: INFO   # 실제 패키지명으로 교체
    org.hibernate.SQL: WARN
```

**추가 컴포넌트 후보 (자유, 측정 근거 필수)**: MQ(Kafka/RabbitMQ), 인메모리 DB(Redis/Valkey), 로드밸런서(3토픽), 리드 레플리카, 분산 락(Redisson), CDC(Debezium), 분석 저장소(TimescaleDB/ClickHouse), 오브젝트 스토리지(MinIO), Spring Batch

---

# 5. Baseline

**나이브 구현 범위**: API 코드·스키마·시드·리소스 예산·측정 절차 통일. 캐시·배치·비동기·큐 없음, 인덱스는 PK만, 커넥션·스레드 풀은 기본값에서 시작.

| 항목 | 값 | 근거 |
| --- | --- | --- |
| PG 컨테이너 | mem_limit 1GB | 2단계에서 인덱스가 메모리를 넘는 현상 재현 |
| shared_buffers | 256MB (명시) | PG 메모리의 25% |
| max_connections | 30 (기본 100에서 낮춤) | work_mem 4MB × 30 = 최대 120MB, 1GB 안에서 안전 |
| work_mem | 4MB (기본) |  |
| HikariCP | 10 (기본) | (4코어 × 2) + 1 ≈ 10 |
| JVM 힙 | App `-Xms1g -Xmx1g`, Kafka `-Xmx1g` | 컨테이너 1.25GB (오프힙 여유 250MB) |
| GC | G1GC (명시) | JDK 25 기본 |
| Kafka num.partitions | 4 (명시) | 4코어 기준 컨슈머 4개까지 병렬 |
| Redis | maxmemory 256MB |  |

메모리 합계: PG 1 + App 1.25 + Kafka 1.25 + Redis 0.3 ≈ 3.8GB. 이 값은 출발점이며 토픽 진행 중 변경 대상. 변경 시 초기값과 근거를 같이 기록.

---

# 6. 도메인 · ERD · API

**도메인 [확정]: 익명 게시판.** 대량 쓰기 대상은 조회 이벤트와 좋아요.

| 토픽 | 시나리오 |
| --- | --- |
| Throughput | 인기 글에 조회 이벤트·좋아요 대량 유입 (나이브 `view = view + 1`로 핫 로우 락 경합 유발) |
| Volume | 쌓인 이벤트·게시글이 DB 캐시를 넘어섬 |
| Concurrency | 인기 글 목록·상세 조회 폭주, 좋아요 동시 경합, 캐시 스탬피드 |

### ERD [제안]

| 테이블 | 핵심 컬럼 |
| --- | --- |
| users | id, nickname, created_at |
| posts | id, author_id, title, content, view_count, like_count, created_at |
| comments | id, post_id, user_id, content, created_at |
| post_likes | post_id, user_id (unique), created_at |
| post_view_events | event_id (UUID, unique), post_id, user_id, client_ts, created_at |

PK는 bigint 시퀀스. PK 타입 변경, 집계 테이블, 파티셔닝은 개인 선택 + ADR 기록. 시간 파티셔닝 시 파티션 사전 생성은 구현 책임.

### API 및 계약 [제안]

| API | 규칙 |
| --- | --- |
| `POST /posts/{id}/views` | `event_id`, `client_ts` 필수. 같은 `event_id`는 1회만 반영. 200/202 모두 성공 |
| `POST /posts/{id}/likes` | 멱등 (재요청 시 200 + 현재 상태). 취소 API 없음 |
| `GET /posts?sort=latest` | `created_at DESC, id DESC`, 불투명 `nextCursor` |
| `GET /posts?sort=popular` | `like_count DESC, id DESC`, 불투명 cursor |
| `GET /posts/trending` | 최근 24시간 고유 조회 이벤트 수 DESC, 상위 20개, cursor 없음 |
| `GET /posts/{id}` | 게시글 + 최신 댓글 20개(nickname 포함) + 카운트 |
| `POST /posts` | 배경 부하용 일반 쓰기 |
- 인증: JWT. 토큰 발급 API는 측정 제외, 댓글·사용자는 seed로만 생성
- 응답 크기: 목록 미리보기 100자, size 기본 20 / 최대 50
- 에러: 5xx·타임아웃·연결 실패 = 에러. 400/401/404는 스크립트 버그로 보고 회차 무효
- rate limiting 기본 금지 (도입 시 허용량·429 판정 사전 고정)
- 진실의 원천: 이벤트·좋아요는 공통 테이블에 최종 적재, 카운트 판정은 API 응답 기준

---

# 7. 시드 데이터

- **반드시 통일**: 카디널리티(실행계획), 쏠림 분포(캐시 히트율), 로우 폭(TOAST 약 2KB)이 결과를 바꿈
- **배포 방식**: 한 사람이 생성해서 덤프 공유. `pg_dump -Fc -Z 6` → `pg_restore -j 4` → **복원 후 `VACUUM ANALYZE` 필수**
- 생성 스크립트는 레포에 보관 (2단계 확장, 재현성 증빙용)
- 전송 후 행 수·파일 크기만 확인

| 테이블 | S (스모크) | M (0~1단계) | L (2단계) |
| --- | --- | --- | --- |
| boards | 20 | 20 | 20 |
| posts | 10만 | 300만 | 1,000만 |
| comments | 30만 | 900만 | 3,000만 |
| post_view_events | 100만 | 2,000만 | 1억 |
| post_likes | 10만 | 300만 | 1,000만 |
| post_stats | posts와 1:1 | 1:1 | 1:1 |

예상 크기(인덱스 포함): M 약 6~8GB, L 약 25~35GB

---

# 8. 측정 방법론

| 항목 | 결정 |
| --- | --- |
| 부하 도구 | k6 (Go 기반, 로컬 cpuset 환경에서 사실상 유일한 선택지) |
| 부하 모델 | open model: `constant-arrival-rate` / `ramping-arrival-rate`. `preAllocatedVUs`·`maxVUs` 넉넉히 (coordinated omission 방지) |
| k6 출력 | `--out experimental-prometheus-rw`로 서버 지표와 같은 시간축 |
| 지연 기준 | 클라이언트 측 `http_req_duration`. 서버 타이머는 구간 분석용 |
| e2e 적재 지연 | 페이로드 `client_ts` ~ 적재 시각. 컨슈머 Micrometer 타이머 또는 `ingested_at` 컬럼 사후 집계 |
| 모니터링 (필수) | Micrometer + Actuator, Prometheus, Grafana, cAdvisor, postgres_exporter |
| 모니터링 (나중에) | kafka_exporter, JMX exporter, node-exporter, Loki/ELK. 분산 추적(OTel, Jaeger)은 불필요 |
| 스크레이프 간격 | 부하 테스트 5초, 스파이크 분석 구간 1초 |
| 대시보드 | 공통 Grafana JSON 템플릿 |

### 측정 절차 (스크립트화: `./run-test.sh baseline 3`)

- **워밍업** 30초~1분, 해당 구간 버림. **steady state만** 집계
- **3회 이상, 중앙값** + 편차 기록. 회차 간 편차 15~20% 초과 시 신뢰 불가, 개선폭 < 편차면 "차이 없음"
- **회차 전 초기화**: truncate, 토픽 재생성, 컨테이너 재시작 (OS 페이지 캐시는 못 비움을 문서에 명시)
- 측정 전 `VACUUM ANALYZE`, 난수 시드 고정, 타임존 UTC
- 측정 순서 무작위화 (baseline을 항상 먼저 돌리지 않기)
- 환경: 다른 앱 종료, 전원 연결·성능 모드, 회차 사이 쿨다운 1~2분, Docker Desktop VM 할당 고정

### 판정

- SLO: "목표 RPS X에서 p99 ≤ Y ms, 에러율 ≤ Z%". 숫자는 실제 서비스 사례에 앵커링
- 판정 기준은 처리량 증가가 아니라 **SLO를 지키며 낼 수 있는 최대 처리량**
- 리포트에 절댓값 기록 → 결과는 배율로 표현
- 백분위수는 회차 간 산술평균 금지 (중앙값 또는 원본 합쳐서 재계산)
- 지표 목록 (RED + USE + Golden Signals 기반, 대시보드 패널 구성표)
    
    
    | 구분 | 지표 |
    | --- | --- |
    | 처리량 | 초당 성공 요청 수 |
    | 지연 | p50 / p95 / p99 |
    | 에러 | 5xx 비율, 타임아웃 비율, 커넥션 거부 비율 (타임아웃과 구분) |
    | 비동기 | e2e 적재 지연, consumer lag |
    | 포화 | HikariCP pending, 톰캣 요청 큐 길이, PG active/waiting 커넥션 |
    | GC | pause 시간·빈도, allocation rate |
    | DB | 버퍼 캐시 히트율, 체크포인트 빈도, WAL 생성량, 락 대기 시간 |
    | 자원 (컨테이너별) | CPU, 메모리, 디스크 IOPS / await |

---

# 9. 테스트 구조

| 층 | 도구 | 위치 | 책임 | 실행 |
| --- | --- | --- | --- | --- |
| ① 공통 테스트 | JUnit 5 + RestAssured + JDBC + Awaitility | `bench-infra/contract-tests` | API 의미·정합성·동시성 (블랙박스) | 로컬, PR 자동 |
| ② 개인 테스트 | JUnit + Testcontainers | 개인 레포 | 내 설계 고유 동작 | 로컬, PR 자동 |
| ③ 부하 측정 | k6 | `bench-infra/k6` | 성능, 안정성 | 라벨, 공식 비교 |
| ④ 사후 검증 | verify 스크립트 | `bench-infra/verify` | 부하 후 정합성 | ③ 직후 자동 |
- ①은 세 구현이 같은 테스트 코드 공유. ④는 부하 중에만 드러나는 버그용이라 ①로 대체 불가
- 케이스는 `cases/*.yml`에 ID(예: TP-02), owner, reviewer, given/when/then, 반드시 잡아야 할 `broken_impl` 명시
- `broken-impls/`로 테스트 자체를 검증. 테스트 클래스명·`@DisplayName`에 ID 부여

---

# 10. 레포 · 산출물

- **Org 구성**: `bench-infra`(공동 소유, 브랜치 보호 전원 승인) + `impl-<name>` × 3 = 4개, 전부 public
- 측정 절차는 `bench-infra`에만. 개인 레포는 이미지·`compose.override.yml`·migration만 제공
- `bench-infra`는 `v1`, `v2` 태그로 고정, 개인 레포는 `@v1`로 호출. infra 버전이 다른 결과끼리는 비교 안 함
- **앱 이미지 계약 [제안]**: 3번이 `bench-infra/templates/Dockerfile` 제공, 각 impl 레포에 복사해 빌드. 앱이 지킬 것: 포트 8080, `/actuator/health`·`/actuator/prometheus` 노출(`micrometer-registry-prometheus` 의존성), DB 접속은 `SPRING_DATASOURCE_URL/USERNAME/PASSWORD` 환경변수, JVM 옵션은 Dockerfile에 하드코딩하지 않고 compose에서 `JAVA_TOOL_OPTIONS`로 주입
- **Git**: 코드, 스키마 마이그레이션(.sql), 시드 생성 스크립트, 고정값, docker compose, k6 스크립트
- **Notion**: 토픽별 리포트
- ADR 템플릿
    
    번호·제목·날짜·상태(제안/채택/폐기/대체됨), 배경(어떤 측정 결과 때문인지), 검토한 대안과 트레이드오프, 결정과 근거, 예상 결과 + 실제 측정 결과, 되돌릴 기준 지표
    
- 결과 리포트 템플릿
    - 환경: 호스트 스펙, OS, Docker 런타임, 공통 설정 태그, 컨테이너별 리소스, JDK/Boot/PG 버전, 가상 스레드 여부
    - 변경점: 무엇을 왜 바꿨는지, 커밋 범위
    - 부하 조건: 시나리오, arrival rate, 지속 시간, 워밍업, 반복 횟수
    - 결과: baseline 대비 지표 표 (3회 중앙값 + 편차), `dropped_iterations` 0 확인
    - 그래프: 공통 대시보드 동일 패널 스크린샷
    - 병목 분석: 한계 지점과 판단 근거 지표
    - 다음 가설

---

# 11. 미결 · 불일치

원본끼리 내용이 어긋나거나 아직 안 정해진 것.

- [x] **실행 환경**: 로컬 cpuset으로 확정 (3장 반영)
- [x] **메모리 8GB 의미**: Docker 실행 환경 VM 할당량으로 확정 (3장 반영)
- [ ]  **ERD 불일치**: 시드 프로파일에는 `boards`, `post_stats`가 있고 `users`가 없음. ERD 제안에는 반대. 1번(스키마)·2번(시드) 간 조율
- [ ]  ERD·API·계약 [제안] → [확정]
- [ ]  SLO 숫자, 목표 RPS (실제 사례 조사 후 앵커링)
- [ ]  요구사항 카드: popular·trending 반영 지연 허용치
- [ ]  워크로드: 이벤트 스키마, 페이로드 크기 분포, 키 분포(Zipf 파라미터), timestamp 분포, 시나리오별 RPS·지속 시간(ramp-up, steady, spike)
- [ ]  토픽별 측정 지표 픽스
- [ ]  단계 간 연결: 공통 체크포인트에서 재출발 vs 완전 누적
- [ ]  L 프로파일 생성 방식: 공통 bulk 스크립트 vs 각자 1단계 결과물
- [ ]  기간 표기: 단계 합계 12주 vs 합의 15주 (버퍼 3주로 볼지)

# 12. 다음 구현 순서

1. 공통 docker compose + 시드 스크립트
2. 측정 절차 스크립트화
3. baseline 구현
4. 모니터링 스택 구성
5. 대시보드 JSON