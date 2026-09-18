# stub-app

bench-infra 파이프라인(compose → 모니터링 → 시드 → k6 → 리포트)을 실제 구현 없이 끝까지 돌려 보기 위한 최소 앱.
실제 구현이 아니며, 측정 대상도 아니다.

- `GET /ping`: DB 없이 응답
- `GET /db`: `stub_ping` 테이블 count 1회 (DB 왕복 1회)
- `/actuator/health`, `/actuator/prometheus` 노출 (앱 이미지 계약)
- 테이블은 `schema.sql` 이 앱 시작 시 `CREATE TABLE IF NOT EXISTS` 로 만든다

빌드는 레포 루트에서 `make build-stub` (templates/Dockerfile 사용).
