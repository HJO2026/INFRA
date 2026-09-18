#!/usr/bin/env bash
# 회차 전 초기화: app 정지 → 측정 테이블 TRUNCATE → VACUUM ANALYZE → postgres 재시작 → app 재생성(새 JVM) → healthy 대기.
# 대상 테이블·서비스는 bench.config.yml 의 reset 섹션. TARGET 이 있으면 targets.<TARGET>.image 로 APP_IMAGE 를 바꾼다.
# 멱등. OS 페이지 캐시는 비우지 못한다 (study-spec 8장 명시 사항).
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

TARGET="${1:-${TARGET:-}}"
if [[ -n "$TARGET" ]]; then
  img="$(cfg "targets.$TARGET.image" 2>/dev/null || true)"
  [[ -n "$img" ]] && export APP_IMAGE="$img"
  ov="$(cfg "targets.$TARGET.override" 2>/dev/null || true)"
  [[ -n "$ov" ]] && export COMPOSE_OVERRIDE="$ov"
fi

wait_healthy postgres 60
log "reset 시작 (TARGET=${TARGET:-없음}, APP_IMAGE=$APP_IMAGE)"

log "app 정지"
compose stop -t 30 app >/dev/null 2>&1 || true

tables="$(cfg reset.truncate_tables 2>/dev/null || true)"
if [[ -n "$tables" ]]; then
  existing=()
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if [[ "$(psql_in "SELECT to_regclass('public.\"$t\"') IS NOT NULL")" == "t" ]]; then existing+=("\"$t\""); else warn "테이블 없음, 건너뜀: $t"; fi
  done <<< "$tables"
  if (( ${#existing[@]} > 0 )); then
    list="$(IFS=,; echo "${existing[*]}")"
    log "TRUNCATE $list"
    psql_in "TRUNCATE $list RESTART IDENTITY CASCADE;" >/dev/null
  fi
fi

if [[ "$(cfg reset.vacuum_analyze 2>/dev/null || echo true)" == "true" ]]; then
  log "VACUUM ANALYZE"; psql_in "VACUUM ANALYZE;" >/dev/null
fi

# 서비스 재시작. postgres 는 restart(볼륨 유지, shared_buffers 비움), app 은 force-recreate(새 JVM, 이미지 교체 반영)
for svc in $(cfg reset.restart_services 2>/dev/null || echo "postgres app"); do
  case "$svc" in
    app) log "app 재생성"; compose up -d --force-recreate --no-deps app >/dev/null ;;
    *)   log "$svc 재시작"; compose restart -t 30 "$svc" >/dev/null; wait_healthy "$svc" 120 ;;
  esac
done
wait_healthy app 180

warn "OS 페이지 캐시는 비우지 못했다 (Docker VM 의 페이지 캐시는 컨테이너 재시작으로 초기화되지 않음). 리포트에 명시할 것"
ok "reset 완료 (app=$(docker inspect --format '{{.Config.Image}} {{.Image}}' "$(container_id app)" | cut -c1-60))"
