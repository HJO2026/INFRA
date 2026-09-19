# bench-infra 측정 인프라. 측정 로직은 여기와 scripts/ 에만 둔다. CI 는 make 만 호출한다.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

VERSIONS_ENV ?= versions.env
COMPOSE_FILES := -f compose/compose.base.yml $(if $(wildcard compose/compose.monitoring.yml),-f compose/compose.monitoring.yml)
# impl 레포의 compose.override.yml 등을 붙일 때: make up COMPOSE_OVERRIDE=/path/a.yml:/path/b.yml
COMPOSE_OVERRIDE ?=
COMPOSE_EXTRA := $(foreach f,$(subst :, ,$(COMPOSE_OVERRIDE)),-f $(f))
COMPOSE := docker compose --env-file $(VERSIONS_ENV) $(COMPOSE_FILES) $(COMPOSE_EXTRA)
export COMPOSE_OVERRIDE

TARGET ?=
RUNS ?= 3

.PHONY: help pin pin-check config lint build-app up down down-v ps logs \
        check-resources check-targets check-dashboard dashboard \
        preflight reset measure collect report test

help: ## 타깃 목록
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  변수: TARGET=$(TARGET) RUNS=$(RUNS) APP_IMAGE=$${APP_IMAGE:-(versions.env)} COMPOSE_OVERRIDE=$(COMPOSE_OVERRIDE)"

pin: ## versions.env 의 이미지 digest 를 레지스트리에서 조회해 채운다
	scripts/pin-versions.sh

pin-check: ## versions.env digest 가 레지스트리와 일치하는지만 확인
	scripts/pin-versions.sh --check

config: ## compose 설정 검증 (문법·변수 치환)
	$(COMPOSE) config -q && echo "compose config OK"

lint: ## shellcheck
	shellcheck scripts/*.sh scripts/lib/*.sh run-test.sh && echo "shellcheck OK"

build-app: ## 앱 레포(APP_DIR, 기본 ../APP)의 Dockerfile 로 APP_IMAGE 빌드
	scripts/build-app.sh

up: ## SUT + 모니터링 기동 후 healthy 대기
	scripts/up.sh

down: ## 컨테이너 정지·삭제 (볼륨 유지)
	$(COMPOSE) down --remove-orphans

down-v: ## 컨테이너와 named volume 까지 삭제
	$(COMPOSE) down --remove-orphans -v

ps: ## 컨테이너 상태
	$(COMPOSE) ps

logs: ## 로그 팔로우 (SVC=app 처럼 지정 가능)
	$(COMPOSE) logs -f $(SVC)

check-resources: ## cpuset·mem_limit 이 예산표와 일치하는지 docker inspect 로 대조
	scripts/check-resources.sh

check-targets: ## Prometheus 타깃 전부 up 인지 확인
	scripts/check-targets.sh

check-dashboard: ## 대시보드 패널 쿼리를 Prometheus 에 실행해 결과 유무 출력
	scripts/check-dashboard.sh

dashboard: ## monitoring/grafana/gen-dashboard.py 로 대시보드 JSON 재생성
	python3 monitoring/grafana/gen-dashboard.py

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
