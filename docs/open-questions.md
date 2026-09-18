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
