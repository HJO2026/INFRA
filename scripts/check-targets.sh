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
      jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.scrapeUrl)\t\(.health)\tlast=\(.lastScrape[0:19])"' <<< "$json" | column -t
      ok "Prometheus 타깃 전부 up"
      exit 0
    fi
  fi
  if (( $(date +%s) >= deadline )); then
    [[ -n "$json" ]] && jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.scrapeUrl)\t\(.health)\t\(.lastError)"' <<< "$json" | column -t
    die "Prometheus 타깃 중 up 이 아닌 것이 있다 ($PROM_URL)"
  fi
  sleep 3
done
