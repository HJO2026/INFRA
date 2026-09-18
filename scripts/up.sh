#!/usr/bin/env bash
# 스택 기동 후 모든 서비스가 healthy 가 될 때까지 기다린다. 멱등 (이미 떠 있으면 변경분만 적용).
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

log "compose up (APP_IMAGE=$APP_IMAGE)"
compose up -d --remove-orphans --quiet-pull

# profile 서비스(k6)는 제외되므로 config --services 에 안 나온다
for svc in $(compose config --services); do
  wait_healthy "$svc" 180
  ok "$svc healthy"
done
compose ps
