#!/usr/bin/env bash
# 스텁 앱 테이블(stub_ping)만으로 seed/dumps/stub.dump 를 만든다. 파이프라인 검증용이며 실제 시드(역할 2)와 무관.
# 형식은 실제 덤프와 같은 규약: pg_dump -Fc -Z 6 (스키마 + 데이터). 멱등: 실행할 때마다 같은 행 수로 다시 만든다.
# 사용: scripts/make-stub-dump.sh [rows]   (기본 10000)
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

ROWS="${1:-10000}"
PGUSER_="$(cfg postgres.user)"; PGDB_="$(cfg postgres.db)"
OUT="$REPO_ROOT/seed/dumps/stub.dump"

wait_healthy postgres 60
log "stub_ping 을 ${ROWS} 행으로 채운다 (난수 시드 고정)"
psql_in "CREATE TABLE IF NOT EXISTS stub_ping (id BIGSERIAL PRIMARY KEY, note TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now());" >/dev/null
psql_in "TRUNCATE stub_ping RESTART IDENTITY;" >/dev/null
psql_in "SELECT setseed(0.42); INSERT INTO stub_ping (note, created_at) SELECT 'stub-' || md5(random()::text), TIMESTAMPTZ '2026-01-01 00:00:00+00' + (g || ' seconds')::interval FROM generate_series(1, ${ROWS}) AS g;" >/dev/null

log "pg_dump -Fc -Z 6 → $OUT"
mkdir -p "$(dirname "$OUT")"
tmp="$OUT.tmp"
compose exec -T postgres pg_dump -Fc -Z 6 -U "$PGUSER_" -d "$PGDB_" --table=stub_ping > "$tmp"
mv "$tmp" "$OUT"
ok "덤프 생성: $OUT ($(du -h "$OUT" | cut -f1)), 행 수 $(psql_in 'SELECT count(*) FROM stub_ping')"
