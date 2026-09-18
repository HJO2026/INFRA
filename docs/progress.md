# 진행 기록

| 단계 | 상태 | 판정 명령 결과 요약 | 커밋 |
|---|---|---|---|
| 0. 스캐폴드 | 통과 | `make help` 타깃 목록 출력. `scripts/pin-versions.sh` 2회 실행 → 두 번째 "변경 없음", `--check` 전부 일치. `versions.env` 7개 이미지 digest 채워짐. shellcheck 0 | (아래) |
| 1. Dockerfile 템플릿 + 스텁 앱 | 통과 | `scripts/build-stub.sh` → `templates/Dockerfile` 멀티스테이지로 `bench/stub-app:dev` 빌드 성공 (Spring Boot 3.5.16, Gradle 9.7.1 wrapper, JDK 25). 런타임 이미지 비루트, ENTRYPOINT 에 JVM 옵션 없음 | (아래) |
