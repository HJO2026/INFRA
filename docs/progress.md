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
