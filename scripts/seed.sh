#!/usr/bin/env bash
# 앱 레포(APP_DIR)의 시드 생성기를 측정 스택과 **같은 compose 프로젝트**로 실행한다.
# 시드를 만드는 로직 자체는 앱 레포 소관이다. 여기서는 같은 postgres·같은 볼륨을 쓰게 만드는 일만 한다.
#
# 사용: scripts/seed.sh [s|m|l|status|init]     (기본 s)
#
# 감싸는 이유 세 가지:
#   1) COMPOSE_PROJECT_NAME 을 안 주면 앱 레포 seed.sh 가 hjo-seed 프로젝트에 따로 만든다.
#      그러면 볼륨이 갈려서 측정 DB 에는 데이터가 안 보인다
#   2) bench DB 를 갈아끼우려면 접속 세션이 0이어야 한다. app 과 postgres_exporter 를 먼저 멈춘다
#   3) 앱 레포 seed.sh 는 postgres 를 시드용 설정(WAL 4GB, 자원 제한 없음)으로 다시 만든다.
#      끝나면 측정용 설정(cpuset, mem_limit, postgresql.conf)으로 되돌려야 한다
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

PROFILE="${1:-s}"
APP_DIR="${APP_DIR:-$REPO_ROOT/../APP}"
SEED_SH="$APP_DIR/seed/seed.sh"
[[ -f "$SEED_SH" ]] || die "앱 레포 시드 스크립트가 없다: $SEED_SH  (APP_DIR 로 앱 레포 경로 지정)"

# 측정 스택과 같은 프로젝트 이름을 compose 에서 직접 읽는다 (compose.yaml 의 name)
PROJECT="$(compose config --format json | py3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
[[ -n "$PROJECT" ]] || die "compose 프로젝트 이름을 읽지 못했다"

# 시드 compose 가 게시할 호스트 포트. 측정 compose 와 같은 변수를 쓴다
export PGPORT="${PGPORT:-15432}"
if [[ -f "$APP_DIR/.env" ]] && grep -qE '^\s*PGPORT=' "$APP_DIR/.env"; then
  warn "앱 레포 .env 에 PGPORT 가 있다. seed.sh 가 그 값을 쓴다 ($(grep -E '^\s*PGPORT=' "$APP_DIR/.env" | head -1))"
fi

log "시드 프로파일 $PROFILE  (프로젝트 $PROJECT, PGPORT $PGPORT)"

# --- 1) bench DB 를 붙잡고 있는 것들을 먼저 멈춘다 ---
for svc in app postgres_exporter; do
  if [[ -n "$(container_id "$svc")" ]]; then
    log "$svc 정지 (시드 교체 중 DB 세션이 있으면 안 된다)"
    compose stop -t 30 "$svc" >/dev/null 2>&1 || true
  fi
done

# --- 2) 앱 레포 생성기 실행 ---
# seed.sh 는 자기 디렉터리로 cd 한 뒤 compose.seed.yml 을 쓴다. 프로젝트 이름만 환경변수로 맞춰 준다.
log "앱 레포 생성기 실행: $SEED_SH $PROFILE"
set +e
COMPOSE_PROJECT_NAME="$PROJECT" PGPORT="$PGPORT" bash "$SEED_SH" "$PROFILE"
seed_rc=$?
set -e

# status 는 조회만 하므로 되돌릴 것이 없다
if [[ "$PROFILE" == "status" ]]; then exit "$seed_rc"; fi

# --- 2-1) 첫 실행 보정 ---
# 앱 레포 seed.sh 의 switch_to 는 첫 줄에서 기존 bench 의 프로파일을 읽는데, 이 컴퓨터에서 처음 돌리면
# bench 가 없어 그 명령이 실패한다. set -euo pipefail 이라 메시지 없이 거기서 끝난다 (앱 레포 README 에도 적혀 있다).
# 템플릿은 이미 만들어졌으므로 여기서 복제만 해 준다. bench 가 한 번 생기면 다음부터는 생성기가 알아서 한다.
BENCH_DB_NAME="$(cfg postgres.db)"
TEMPLATE="seed_$PROFILE"
has_bench="$(psql_admin "SELECT count(*) FROM pg_database WHERE datname='$BENCH_DB_NAME'" || echo 0)"
if [[ "$has_bench" == "0" ]]; then
  has_tpl="$(psql_admin "SELECT count(*) FROM pg_database WHERE datname='$TEMPLATE'" || echo 0)"
  [[ "$has_tpl" == "1" ]] || die "템플릿 $TEMPLATE 도 $BENCH_DB_NAME 도 없다. 생성기 출력을 확인할 것 (exit=$seed_rc)"
  warn "$BENCH_DB_NAME 이 없다 (앱 레포 seed.sh 첫 실행 버그). 템플릿 $TEMPLATE 에서 복제한다"
  psql_admin "CREATE DATABASE \"$BENCH_DB_NAME\" TEMPLATE \"$TEMPLATE\" STRATEGY FILE_COPY" >/dev/null
  ok "$BENCH_DB_NAME 생성 완료"
elif (( seed_rc != 0 )); then
  die "생성기가 실패했다 (exit=$seed_rc)"
fi

# --- 3) 측정용 설정으로 postgres 를 되돌리고 스택을 다시 올린다 ---
# 생성기가 postgres 를 시드용 설정으로 다시 만들어 놨다. 데이터는 볼륨에 있으므로 그대로다.
log "측정용 설정으로 스택 복구 (cpuset, mem_limit, postgresql.conf)"
compose up -d --wait

# --- 4) 확인 ---
PGDB="$(cfg postgres.db)"
echo
printf '%-24s %12s\n' TABLE ROWS
printf '%-24s %12s\n' ------------------------ ------------
while IFS='|' read -r t n; do
  [[ -z "$t" ]] && continue
  printf '%-24s %12s\n' "$t" "$n"
# pg_stat_user_tables 의 n_live_tup 은 템플릿 복제로 만든 DB 에서 0 으로 나온다 (누적 통계는 복사되지 않는다).
# pg_class.reltuples 는 DB 와 함께 복사되므로 이걸 쓴다. 플래너가 쓰는 통계(pg_statistic)도 같이 복사된다.
done < <(psql_in "SELECT relname||'|'||GREATEST(reltuples,0)::bigint FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY relname")
echo
ok "시드 준비 완료: 프로파일 $PROFILE (DB $PGDB)"
