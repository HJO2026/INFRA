#!/usr/bin/env bash
# Prometheus /api/v1/targets 의 모든 활성 타깃이 up 인지 확인. 첫 스크레이프까지 최대 60초 재시도.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd curl jq

PROM_URL="${PROM_URL:-http://127.0.0.1:${PROM_HOST_PORT:-9090}}"
expected="${EXPECTED_TARGETS:-app postgres_exporter cadvisor prometheus}"
deadline=$(( $(date +%s) + ${TARGET_WAIT_SEC:-60} ))

while :; do
  json="$(curl -fsS "$PROM_URL/api/v1/targets?state=active" 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    all_up=1
    for job in $expected; do
      health="$(jq -r --arg j "$job" '[.data.activeTargets[] | select(.labels.job==$j)] | if length==0 then "missing" else (map(.health) | unique | join(",")) end' <<< "$json")"
      [[ "$health" == "up" ]] || all_up=0
    done
    if [[ $all_up -eq 1 ]]; then
      jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.scrapeUrl)\t\(.health)\tlast=\(.lastScrape[0:19])"' <<< "$json" | tabalign
      ok "Prometheus 타깃 전부 up"

      # cAdvisor 가 up 이어도 마운트가 플랫폼과 안 맞으면 컨테이너별 지표 대신 루트 cgroup 하나만 나온다.
      # 타깃 up 만 보고 넘어가면 대시보드가 빈 뒤에야 알게 되므로 여기서 한 번 짚는다 (경고만).
      svc_count="$(curl -fsS "$PROM_URL/api/v1/query" --data-urlencode 'query=count(count by (svc) (container_memory_working_set_bytes{project="hjo-bench"}))' 2>/dev/null \
        | jq -r '.data.result[0].value[1] // "0"')"
      if [[ "$svc_count" =~ ^[0-9]+$ ]] && (( svc_count >= 2 )); then
        ok "cAdvisor 컨테이너별 지표 ${svc_count}개 서비스"
      else
        warn "cAdvisor 가 컨테이너별 지표를 못 내고 있다 (서비스 ${svc_count}개). 자원 패널이 빈다."
        warn "  compose/compose.monitoring.yml 의 cadvisor 마운트가 이 플랫폼과 안 맞는 경우다."
        warn "  .env 에 CADVISOR_DOCKER_ROOT / CADVISOR_CONTAINERD_SOCK 로 경로를 바꿔 본다 (README '윈도우' 절)."
      fi
      exit 0
    fi
  fi
  if (( $(date +%s) >= deadline )); then
    [[ -n "$json" ]] && jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.scrapeUrl)\t\(.health)\t\(.lastError)"' <<< "$json" | tabalign
    die "Prometheus 타깃 중 up 이 아닌 것이 있다 ($PROM_URL)"
  fi
  sleep 3
done
