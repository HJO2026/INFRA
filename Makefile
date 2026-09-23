# bench-infra 측정 인프라. 측정 로직은 여기와 scripts/ 에만 둔다. CI 는 make 만 호출한다.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# 컨테이너 기동·정지·로그는 make 를 거치지 않는다. 루트 compose.yaml 덕분에 docker compose 명령이 그대로 된다.
#   docker compose up -d --wait / ps / logs -f app / down / down -v / config
# 여기 남은 것은 측정 절차(여러 단계를 순서대로 밟는 것)뿐이다.
VERSIONS_ENV ?= versions.env
# impl 레포의 compose.override.yml 등을 붙일 때: make reset COMPOSE_OVERRIDE=/path/a.yml:/path/b.yml
COMPOSE_OVERRIDE ?=
COMPOSE := docker compose $(if $(COMPOSE_OVERRIDE),-f compose.yaml $(foreach f,$(subst :, ,$(COMPOSE_OVERRIDE)),-f $(f)))
export COMPOSE_OVERRIDE

TARGET ?=
RUNS ?= 3
PROFILE ?= s

.PHONY: help pin pin-check lint build-app \
        check-resources check-targets check-dashboard dashboard \
        seed preflight reset measure collect report test

help: ## 타깃 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  변수: TARGET=$(TARGET) RUNS=$(RUNS) APP_IMAGE=$${APP_IMAGE:-(versions.env)} COMPOSE_OVERRIDE=$(COMPOSE_OVERRIDE)"

pin: ## versions.env 의 이미지 digest 를 레지스트리에서 조회해 채운다
	scripts/pin-versions.sh

pin-check: ## versions.env digest 가 레지스트리와 일치하는지만 확인
	scripts/pin-versions.sh --check

lint: ## shellcheck
	shellcheck scripts/*.sh scripts/lib/*.sh run-test.sh && echo "shellcheck OK"

build-app: ## 앱 레포(APP_DIR, 기본 ../APP)의 Dockerfile 로 APP_IMAGE 빌드
	scripts/build-app.sh

check-resources: ## cpuset·mem_limit 이 예산표와 일치하는지 docker inspect 로 대조
	scripts/check-resources.sh

check-targets: ## Prometheus 타깃 전부 up 인지 확인
	scripts/check-targets.sh

check-dashboard: ## 대시보드 패널 쿼리를 Prometheus 에 실행해 결과 유무 출력
	scripts/check-dashboard.sh

dashboard: ## monitoring/grafana/gen-dashboard.py 로 대시보드 JSON 재생성
	scripts/dashboard.sh

seed: ## 앱 레포 시드 생성기를 같은 compose 프로젝트로 실행 (PROFILE=s|m|l, 기본 s)
	scripts/seed.sh $(PROFILE)

preflight: ## VM 리소스, 디스크, 이미지 digest, 컨테이너 상태 점검
	scripts/preflight.sh

reset: ## 컨테이너 재시작 + 측정 테이블 초기화 + VACUUM ANALYZE
	scripts/reset.sh

measure: ## k6 1회 실행 (TARGET, RUN_ID, RUN_NO)
	scripts/measure.sh $(TARGET)

collect: ## 회차 요약 JSON 수집·유효성 판정 (RUN_ID 필요)
	scripts/collect.sh

report: ## results/<RUN_ID>/report.md 생성 (RUN_ID 필요)
	scripts/report.sh

test: ## 전체 측정: ./run-test.sh $(TARGET) $(RUNS)
	./run-test.sh $(TARGET) $(RUNS)
