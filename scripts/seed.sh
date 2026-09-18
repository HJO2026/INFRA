#!/usr/bin/env bash
# 덤프 복원: pg_restore -j 4 → VACUUM ANALYZE → 테이블별 행 수 출력
# 사용: scripts/seed.sh <S|M|L|stub>     덤프 파일: seed/dumps/<PROFILE>.dump (pg_dump -Fc, 스키마+데이터)
# 멱등: --clean --if-exists 로 기존 객체를 지우고 다시 만든다. 두 번 실행해도 같은 행 수.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

PROFILE="${1:-${SEED_PROFILE:-stub}}"
DUMP_HOST="$REPO_ROOT/seed/dumps/$PROFILE.dump"
DUMP_IN_CONTAINER="/seed/$PROFILE.dump"       # compose 가 seed/dumps 를 /seed 로 마운트
PGUSER_="$(cfg postgres.user)"; PGDB_="$(cfg postgres.db)"
JOBS="${PG_RESTORE_JOBS:-4}"

[[ -f "$DUMP_HOST" ]] || die "덤프 없음: $DUMP_HOST  (stub 은 'make seed-stub-dump', S/M/L 은 역할 2 배포본을 seed/dumps/ 에 둔다)"
wait_healthy postgres 60

log "프로파일 $PROFILE: $DUMP_HOST ($(du -h "$DUMP_HOST" | cut -f1), sha256 $(shasum -a 256 "$DUMP_HOST" | cut -c1-12)…)"
compose exec -T postgres pg_restore --list "$DUMP_IN_CONTAINER" >/dev/null || die "pg_restore --list 실패: -Fc(custom) 형식이 아닌 듯"

# 복원 중 앱이 테이블을 잡고 있지 않도록 앱을 잠시 멈춘다 (--clean 이 DROP 을 한다)
app_was_up=0
if [[ -n "$(container_id app)" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$(container_id app)")" == "true" ]]; then
  app_was_up=1; log "app 정지 (복원 중 락 회피)"; compose stop app >/dev/null
fi

log "pg_restore -j $JOBS --clean --if-exists"
start=$(date +%s)
compose exec -T postgres pg_restore -U "$PGUSER_" -d "$PGDB_" -j "$JOBS" \
  --clean --if-exists --no-owner --no-privileges --exit-on-error "$DUMP_IN_CONTAINER"
log "복원 $(( $(date +%s) - start ))s"

log "VACUUM ANALYZE"
start=$(date +%s)
psql_in "VACUUM ANALYZE;" >/dev/null
log "VACUUM ANALYZE $(( $(date +%s) - start ))s"

if [[ $app_was_up -eq 1 ]]; then
  log "app 재시작"; compose start app >/dev/null; wait_healthy app 180
fi

echo
printf '%-32s %12s\n' TABLE ROWS
printf '%-32s %12s\n' -------------------------------- ------------
total=0
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  n="$(psql_in "SELECT count(*) FROM \"$t\"")"
  printf '%-32s %12s\n' "$t" "$n"
  total=$(( total + n ))
done < <(psql_in "SELECT relname FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY relname")
printf '%-32s %12s\n' "(합계)" "$total"
ok "시드 복원 완료: 프로파일 $PROFILE"
