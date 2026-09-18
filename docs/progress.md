# 진행 기록

| 단계 | 상태 | 판정 명령 결과 요약 | 커밋 |
|---|---|---|---|
| 0. 스캐폴드 | 통과 | `make help` 타깃 목록 출력. `scripts/pin-versions.sh` 2회 실행 → 두 번째 "변경 없음", `--check` 전부 일치. `versions.env` 7개 이미지 digest 채워짐. shellcheck 0 | (아래) |
| 1. Dockerfile 템플릿 + 스텁 앱 | 통과 | `scripts/build-stub.sh` → `templates/Dockerfile` 멀티스테이지로 `bench/stub-app:dev` 빌드 성공 (Spring Boot 3.5.16, Gradle 9.7.1 wrapper, JDK 25). 런타임 이미지 비루트, ENTRYPOINT 에 JVM 옵션 없음 | (아래) |
| 2. compose base | 통과 | `make up` → postgres·app healthy. `scripts/check-resources.sh` compose 설정·docker inspect 모두 예산표와 일치. `/actuator/prometheus` 에 `hikaricp_` 16줄. PG shared_buffers 256MB/max_connections 30/work_mem 4MB/UTC, JVM `JAVA_TOOL_OPTIONS` 주입 확인. 호스트 5432 충돌로 PG 호스트 포트 기본 15432 (open-questions) | (아래) |
| 3. 모니터링 | 통과 | `make up` 6개 서비스 healthy. `scripts/check-targets.sh` app·cadvisor·postgres_exporter·prometheus 전부 up. Grafana 익명 조회 200, Prometheus 데이터소스 프로비저닝 확인. remote-write receiver 켜짐(POST /api/v1/write → 400). cAdvisor 컨테이너별 CPU·메모리·디스크IO 시계열 확인 (Docker Desktop 마운트 조정, open-questions). check-resources 모니터링 4개 포함 일치 | (아래) |
