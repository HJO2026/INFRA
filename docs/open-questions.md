# 미결 · 임시 결정 기록

형식: 날짜 / 단계 / 무엇을 정했나 / 왜 / 되돌리려면

## 2026-09-18 / 0단계 / 모니터링 이미지 버전 선택
- 정한 것: `prom/prometheus:v3.14.0`, `grafana/grafana:12.4.11`, `gcr.io/cadvisor/cadvisor:v0.55.1`,
  `prometheuscommunity/postgres-exporter:v0.20.1`
- 왜: study-spec 은 PG·JDK·k6 태그만 정했고 모니터링 스택은 "명시 버전" 규칙만 있음. 작업 시점 Docker Hub 최신
  안정 태그 중 linux/arm64 매니페스트가 있는 것을 골랐다. Grafana 는 13.x 가 있으나 프로비저닝 포맷 호환이
  검증된 12.x 계열을 택했다.
- 되돌리려면: `versions.env` 태그를 바꾸고 `make pin` 실행

## 2026-09-18 / 0단계 / Docker Desktop 디스크 이미지 30GB
- 정한 것: 그대로 진행. preflight 는 디스크 여유를 경고만 하고 실패시키지 않는다 (임계값은 `bench.config.yml`)
- 왜: study-spec 3장은 60GB 이상을 요구하지만 이 호스트의 Docker Desktop 디스크 이미지는 30,518MiB. 스텁·S 프로파일에는 충분.
  M/L 덤프(6~35GB) 복원 전에 Docker Desktop 설정에서 늘려야 한다
- 되돌리려면: Docker Desktop > Resources > Disk image size 를 60GB 이상으로 올리고 preflight 임계값 상향

## 2026-09-18 / 0단계 / 루트의 role-3.md 사본
- 정한 것: `docs/role-3.md` 와 내용이 같은 루트 `role-3.md` 는 `.gitignore` 로 제외 (삭제하지 않음)
- 왜: 내가 만든 파일이 아니고 삭제는 되돌리기 어렵다. 진실의 원천은 `docs/` 아래
- 되돌리려면: 루트 파일을 지우고 `.gitignore` 의 `/role-3.md` 줄 삭제

## 2026-09-18 / 2단계 / 호스트 포트 변수화, PG 기본 15432
- 정한 것: compose 의 호스트 포트를 `PG_HOST_PORT`(기본 15432), `APP_HOST_PORT`(기본 8080) 변수로. 컨테이너 안 포트는 5432/8080 그대로
- 왜: 이 호스트에서 다른 프로젝트의 컨테이너(`postgres_db`)가 5432 를 점유하고 있어 `make up` 이 실패했다. 남의 컨테이너를 멈추는 건 되돌리기 어렵다.
  k6·exporter 는 compose 네트워크 안에서 서비스명으로 붙으므로 측정에는 영향 없음
- 되돌리려면: `PG_HOST_PORT=5432 make up` 또는 compose 기본값 수정
- 참고: 측정 중에는 다른 프로젝트 컨테이너(kafka-ui, mysql_db, postgres_db)가 같은 VM 의 CPU·메모리를 쓴다. preflight 가 경고한다 (5단계)

## 2026-09-18 / 2단계 / 앱 이미지 템플릿에 curl 추가, memswap_limit 고정
- 정한 것: `templates/Dockerfile` 런타임 스테이지에 `curl` 설치. compose healthcheck 가 `/actuator/health/readiness` 를 curl 로 확인.
  모든 SUT·k6 컨테이너에 `memswap_limit` = `mem_limit` 지정 (스왑 사용 금지)
- 왜: `eclipse-temurin:25-jdk` 에는 curl·wget 이 없다. 스왑을 막아야 mem_limit 초과 시 동작(OOM)이 호스트마다 같다
- 되돌리려면: Dockerfile 의 apt-get 줄 삭제 + healthcheck 를 bash `/dev/tcp` 방식으로 교체. memswap_limit 줄 삭제

## 2026-09-18 / 3단계 / cAdvisor 마운트를 Docker Desktop(macOS) 기준으로 구성
- 정한 것: cAdvisor 볼륨을 `/var/run/docker.sock`, `/run/containerd/containerd.sock`, `/var/lib/docker`, `/sys` 네 개만 마운트.
  리눅스 호스트용 표준 구성의 `/:/rootfs`, `/var/run`(디렉터리), `/dev/disk` 는 뺐다
- 왜: Docker Desktop 은 `/var/run` 디렉터리 마운트를 Mac 쪽 경로로 매핑해 docker.sock 을 못 찾고, cAdvisor v0.55 의 docker factory 는
  containerd 소켓과 `/var/lib/docker`(rw 레이어 식별) 가 없으면 컨테이너를 아예 등록하지 않는다. 이 구성으로 컨테이너별 CPU·메모리·디스크 IO 지표가 나온다
- 되돌리려면: 리눅스 호스트에서 지표가 비면 표준 마운트(`/:/rootfs:ro`, `/var/run:/var/run:ro`, `/dev/disk/:/dev/disk:ro`)를 추가
