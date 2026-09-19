# bench-infra

서버 고도화 스터디(3인)의 공통 측정 인프라 레포. 세 명이 각자 만든 구현(impl-<name>)을
같은 리소스, 같은 데이터, 같은 절차로 부하 측정하기 위한 compose, 모니터링, 측정 스크립트를 둔다.
이 레포에서 작업하는 사람은 역할 3(세팅·스크립트) 담당이다.

## 문서 (작업 전 반드시 읽을 것)
- `docs/study-spec.md`: 스터디 합의 원문. 진실의 원천. 다른 문서와 충돌하면 이 문서가 우선
- `docs/role-3.md`: 이 레포에서 할 일, 범위 밖 항목, 외부 인터페이스, 단계와 완료 판정
- `docs/open-questions.md`: 결정이 필요한데 막힌 것을 기록하는 곳
- `docs/progress.md`: 단계별 진행 결과 (작업하면서 갱신)

## 외부 레포
- 스프링 앱: `/Users/heo/async/project/HJO/APP` (Makefile 기본 `APP_DIR=../APP`). 이미지는 그 레포의 `Dockerfile`로 `make build-app`.
  Dockerfile 템플릿은 두지 않는다 (앱 레포 것이 진실의 원천)
- 시드 데이터: APP 레포 `feat/seed-data` 브랜치의 `seed/` (생성기 방식, `seed/seed.sh s|m|l`). bench-infra에는 시드 생성·복원 코드를 두지 않는다

## 불변 규칙
- 이미지 태그는 명시 버전만. `latest` 금지. `versions.env`에 태그와 digest를 같이 기록
- 측정 로직은 `Makefile`과 `scripts/`에만 둔다. CI 워크플로가 생기더라도 `make` 호출만 한다
- 컨테이너 기동·정지·상태·로그는 `docker compose` 를 그대로 쓴다. 래퍼를 만들지 않는다 (루트 `compose.yaml`)
- cpuset: SUT(app, postgres, 이후 kafka/redis) `0-3`, k6 `4-5`, 모니터링 `6`
- 전체 메모리 예산은 Docker VM 할당 8GB. 컨테이너별 `mem_limit`은 `docs/role-3.md` 예산표를 따른다
- DB·Kafka 데이터는 named volume. bind mount는 설정 파일과 스크립트만
- 타임존 UTC, 난수 시드 고정
- 스키마, 마이그레이션, API 코드, 시드 생성 로직은 범위 밖. 수정하지 말고 경로와 변수로 연결 지점만 둔다
- 공통 규약(API, 스키마, 측정 절차)을 임의로 바꾸지 않는다. 필요하면 open-questions에 기록

## 디렉터리 (설계서 v3 기준, monitoring/templates 추가)
```
compose.yaml        루트 진입점 (compose/ 아래 include). `docker compose up -d --wait` 가 그대로 된다
compose/            compose.base.yml, compose.monitoring.yml, profiles(kafka, redis는 나중)
postgres/           postgresql.conf (baseline 값). 스키마는 넣지 않음
monitoring/         prometheus/, grafana/{provisioning,dashboards}/
k6/{lib,scenarios}  러너 공통 코드. 실제 워크로드 시나리오는 미결
verify/             뼈대만 (내용은 미결)
scripts/            preflight, reset, measure, collect, report, build-app, check-*
results/            측정 결과 (git 제외, 리포트 md만 커밋 가능)
versions.env, .env.example(로컬 비밀값 예시, .env 는 git 제외), bench.config.yml, Makefile, run-test.sh
```

## 작업 방식
- `docs/role-3.md`의 단계를 순서대로 진행한다
- 각 단계의 완료 판정 명령을 실제로 실행하고, 통과해야 다음 단계로 간다
- 단계가 끝나면 `docs/progress.md`에 결과를 적고 아래 커밋 규칙대로 커밋한다
- 셸 스크립트는 bash, `set -euo pipefail`, shellcheck 경고 0
- 스크립트는 멱등하게. 두 번 실행해도 같은 결과

## 브랜치 전략
- `main`은 항상 검증 명령이 통과하는 상태. `main`에 직접 커밋하지 않는다
- 작업마다 `main`에서 브랜치를 딴다: `<type>/<짧은-설명>` (type은 커밋 type과 같음, 설명은 영문 kebab-case)
  - 예: `feat/kafka-profile`, `fix/preflight-cpu-check`, `docs/impl-guide`, `chore/pin-k6`
- 한 브랜치에는 한 가지 목적만. 커밋은 그 안에서 여러 개여도 된다
- 끝나면 검증 명령을 통과시킨 뒤 `git switch main && git merge --no-ff <branch>`, 병합한 브랜치는 `git branch -d`로 삭제
- 원격이 생기면 병합 대신 PR로 올린다. `git push`는 사람이 한다

## 커밋 규칙
형식:
```
<type>(<scope>): <요약>

- <무엇을 했는지 + 필요하면 왜. 구체적 값(버전, 경로, 옵션)까지>
- ...
```
- type: `feat` 기능, `fix` 버그, `chore` 설정·빌드·버전, `docs` 문서, `refactor` 동작 불변 정리, `perf` 성능, `test` 검증 스크립트
- scope: 바뀐 영역 하나. `compose`, `docker`, `monitoring`, `grafana`, `prometheus`, `k6`, `postgres`, `scripts`, `templates`, `docs`, `make` 등
- 요약: 한국어, 한 줄, 마침표 없음. 핵심 변경을 쉼표로 나열해도 된다
- 본문: 요약 다음 빈 줄 하나 뒤에 `- ` 불릿 (빈 줄이 없으면 git이 본문까지 제목으로 취급해 `git log --oneline`이 깨진다). 한 불릿에 한 가지. 기본값·대체 동작 같은 주의점은 괄호로
- 단계 완료 커밋도 같은 형식을 쓰고 본문 첫 불릿에 `stage N 완료`를 적는다

예시:
```
chore(docker): Temurin 25 고정 2단계 빌드 Dockerfile, JAVA_OPTS 주입, GC 로그, graceful shutdown

- 빌드: eclipse-temurin:25.0.4_7-jdk-noble 안에서 bootJar (의존성 레이어 분리, Gradle 캐시 마운트)
- 실행: eclipse-temurin:25.0.4_7-jre-noble, non-root(app) 사용자, 포트 8080
- JAVA_OPTS 기본값 -XX:+UseG1GC -Xlog:gc*:file=/logs/gc.log:time,uptime (값을 주면 대체됨. 힙·ActiveProcessorCount는 인프라가 주입)
- exec java로 PID 1 실행 → docker stop의 SIGTERM으로 graceful shutdown
- .dockerignore로 빌드 컨텍스트 최소화
```

## 막혔을 때 (사람이 자리에 없다고 가정)
- 질문하지 않는다. 가장 되돌리기 쉬운 선택을 하고 `docs/open-questions.md`에 "무엇을, 왜, 되돌리려면" 기록
- 같은 문제로 같은 접근을 3번 실패하면 멈추고 기록한 뒤, 그 단계에서 가능한 부분만 남기고 다음 단계로
- 지정된 이미지 태그가 존재하지 않으면 존재하는 가장 가까운 버전을 쓰고 기록
- 범위 밖 파일이 필요하면 스텁으로 대체하고 교체 지점을 기록

## 검증 명령
- `docker compose config -q` (루트 `compose.yaml` 이 compose/ 아래를 include 한다)
- `shellcheck scripts/*.sh run-test.sh`
- `make preflight`

## 알려진 함정
- cpuset 번호는 Docker VM 기준. preflight에서 `docker info`의 CPU 수 7 이상, 메모리 약 8GB 확인
- k6 → Prometheus remote write: Prometheus에 `--web.enable-remote-write-receiver` 필요.
  k6는 `K6_PROMETHEUS_RW_SERVER_URL`, 백분위 보려면 `K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99)`
- postgres 18 공식 이미지는 PGDATA 기본 경로가 바뀌었다(버전별 하위 디렉터리). 볼륨 마운트 위치를 이미지 문서로 확인할 것
- macOS Docker Desktop에서 cAdvisor는 일부 지표(디스크 IO 등)가 비거나 부정확할 수 있다. 컨테이너별 CPU·메모리가 나오면 통과로 본다
- `dropped_iterations`가 0이 아니면 그 회차는 무효. k6 요약 JSON에서 확인
