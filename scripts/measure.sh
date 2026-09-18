#!/usr/bin/env bash
# k6 1회 실행. 결과: results/<RUN_ID>/<target>/run-<RUN_NO>/{summary.json,k6.log,meta.json}
# 사용: scripts/measure.sh <target>   (환경: RUN_ID, RUN_NO, 선택 RATE/WARMUP_SECONDS/STEADY_SECONDS/PRE_VUS/MAX_VUS 로 config 덮어쓰기)
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker jq
load_versions

TARGET="${1:-${TARGET:-stub}}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$TARGET}"
RUN_NO="${RUN_NO:-1}"
SCENARIO="$(cfg "targets.$TARGET.scenario" 2>/dev/null || echo smoke)"
[[ -f "$REPO_ROOT/k6/scenarios/$SCENARIO.js" ]] || die "시나리오 없음: k6/scenarios/$SCENARIO.js"
ov="$(cfg "targets.$TARGET.override" 2>/dev/null || true)"; [[ -n "$ov" ]] && export COMPOSE_OVERRIDE="$ov"

RATE="${RATE:-$(cfg measure.rate)}"
WARMUP="${WARMUP_SECONDS:-$(cfg measure.warmup_seconds)}"
STEADY="${STEADY_SECONDS:-$(cfg measure.steady_seconds)}"
PRE_VUS="${PRE_VUS:-$(cfg measure.pre_allocated_vus)}"
MAX_VUS="${MAX_VUS:-$(cfg measure.max_vus)}"
SEED="${SEED:-$(cfg measure.seed)}"
TREND="$(cfg measure.k6_trend_stats)"

rel="$RUN_ID/$TARGET/run-$RUN_NO"
out_host="$REPO_ROOT/results/$rel"
out_ctr="/results/$rel"
mkdir -p "$out_host"

wait_healthy app 60
app_cid="$(container_id app)"
app_image="$(docker inspect --format '{{.Config.Image}}' "$app_cid")"
app_image_id="$(docker inspect --format '{{.Image}}' "$app_cid")"
want_img="$(cfg "targets.$TARGET.image" 2>/dev/null || true)"
if [[ -n "$want_img" && "$want_img" != "$app_image" ]]; then
  warn "실행 중 app 이미지($app_image)가 target 설정($want_img)과 다르다. reset.sh $TARGET 을 먼저 실행했는지 확인"
fi

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "measure: run_id=$RUN_ID target=$TARGET run_no=$RUN_NO scenario=$SCENARIO rate=$RATE/s warmup=${WARMUP}s steady=${STEADY}s vus=$PRE_VUS..$MAX_VUS seed=$SEED"

set +e
compose --profile k6 run --rm --no-deps -T \
  -e RATE="$RATE" -e WARMUP_SECONDS="$WARMUP" -e STEADY_SECONDS="$STEADY" \
  -e PRE_VUS="$PRE_VUS" -e MAX_VUS="$MAX_VUS" -e SEED="$SEED" \
  k6 run --quiet \
    --out experimental-prometheus-rw \
    --summary-export "$out_ctr/summary.json" \
    --summary-trend-stats "$TREND" \
    --tag "run_id=$RUN_ID" --tag "target=$TARGET" --tag "run_no=$RUN_NO" \
    "scenarios/$SCENARIO.js" 2>&1 | tee "$out_host/k6.log"
rc=${PIPESTATUS[0]}
set -e
ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n --arg run_id "$RUN_ID" --arg target "$TARGET" --argjson run_no "$RUN_NO" --arg scenario "$SCENARIO" \
  --arg started "$started" --arg ended "$ended" --argjson k6_exit "$rc" \
  --arg app_image "$app_image" --arg app_image_id "$app_image_id" \
  --argjson rate "$RATE" --argjson warmup "$WARMUP" --argjson steady "$STEADY" --argjson seed "$SEED" \
  --argjson pre_vus "$PRE_VUS" --argjson max_vus "$MAX_VUS" \
  '{run_id:$run_id,target:$target,run_no:$run_no,scenario:$scenario,started_at:$started,ended_at:$ended,k6_exit_code:$k6_exit,
    app_image:$app_image,app_image_id:$app_image_id,
    load:{rate:$rate,warmup_seconds:$warmup,steady_seconds:$steady,seed:$seed,pre_allocated_vus:$pre_vus,max_vus:$max_vus}}' \
  > "$out_host/meta.json"

[[ -f "$out_host/summary.json" ]] || die "summary.json 이 없다 (k6 exit=$rc). $out_host/k6.log 확인"
if (( rc != 0 )); then
  # 99 = threshold 실패(여기서는 항상 통과하도록 설정), 그 외는 실행 오류
  warn "k6 exit code $rc"
fi
ok "measure 완료: $out_host (k6 exit=$rc)"
