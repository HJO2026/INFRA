#!/usr/bin/env bash
# 측정 절차 전체: preflight → (reset → measure → collect → 쿨다운) × runs → report
# 사용: ./run-test.sh <target>[,<target>...] <runs>       예) ./run-test.sh stub 3    ./run-test.sh baseline,impl-a 3
# target 여러 개면 회차마다 순서를 무작위화한다 (시드 고정이라 재현 가능). 결과: results/<RUN_ID>/report.md
# 환경변수: COOLDOWN_SECONDS, RATE, WARMUP_SECONDS, STEADY_SECONDS, PRE_VUS, MAX_VUS (bench.config.yml 값 덮어쓰기)
# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/scripts/lib/common.sh"
require_cmd docker jq python3

usage() { echo "usage: $0 <target>[,<target>...] <runs>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
IFS=',' read -ra TARGETS <<< "$1"
RUNS="$2"
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || usage
known="$(cfg targets)"
for t in "${TARGETS[@]}"; do
  grep -qx "$t" <<< "$known" || die "bench.config.yml targets 에 없는 target: $t (있는 것: $(tr '\n' ' ' <<< "$known"))"
done

SEED="${SEED:-$(cfg measure.seed)}"
COOLDOWN="${COOLDOWN_SECONDS:-$(cfg measure.cooldown_seconds)}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(IFS=+; echo "${TARGETS[*]}")}"
export RUN_ID SEED
run_dir="$REPO_ROOT/results/$RUN_ID"
mkdir -p "$run_dir"

scenarios="$(for t in "${TARGETS[@]}"; do printf '%s=%s\n' "$t" "$(cfg "targets.$t.scenario" 2>/dev/null || echo smoke)"; done | jq -R 'split("=") | {(.[0]): .[1]}' | jq -s add)"
jq -n --argjson targets "$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s .)" --argjson runs "$RUNS" --argjson seed "$SEED" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg git "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
  --argjson cooldown "$COOLDOWN" --argjson scenarios "$scenarios" \
  '{run_id:env.RUN_ID,targets:$targets,runs:$runs,seed:$seed,cooldown_seconds:$cooldown,scenarios:$scenarios,started_at:$started,infra_git:$git,order:[]}' > "$run_dir/run.json"
cp "$VERSIONS_ENV" "$BENCH_CONFIG" "$run_dir/"

log "run_id=$RUN_ID targets=${TARGETS[*]} runs=$RUNS cooldown=${COOLDOWN}s seed=$SEED"
"$REPO_ROOT/scripts/preflight.sh"

total=$(( RUNS * ${#TARGETS[@]} )); done_n=0
for (( run_no = 1; run_no <= RUNS; run_no++ )); do
  if (( ${#TARGETS[@]} > 1 )); then
    order="$(python3 -c 'import random,sys; l=sys.argv[2:]; random.Random(int(sys.argv[1])).shuffle(l); print(" ".join(l))' "$(( SEED + run_no ))" "${TARGETS[@]}")"
  else
    order="${TARGETS[0]}"
  fi
  log "===== 회차 $run_no/$RUNS 순서: $order"
  jq --arg o "$order" '.order += [$o]' "$run_dir/run.json" > "$run_dir/run.json.tmp" && mv "$run_dir/run.json.tmp" "$run_dir/run.json"
  for t in $order; do
    done_n=$((done_n + 1))
    log "--- [$done_n/$total] $t run-$run_no: reset"
    "$REPO_ROOT/scripts/reset.sh" "$t"
    log "--- [$done_n/$total] $t run-$run_no: measure"
    RUN_NO="$run_no" "$REPO_ROOT/scripts/measure.sh" "$t"
    log "--- [$done_n/$total] $t run-$run_no: collect"
    "$REPO_ROOT/scripts/collect.sh" "$t" "$run_no"
    if (( done_n < total )); then
      log "--- 쿨다운 ${COOLDOWN}s"; sleep "$COOLDOWN"
    fi
  done
done

jq --arg e "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.ended_at = $e' "$run_dir/run.json" > "$run_dir/run.json.tmp" && mv "$run_dir/run.json.tmp" "$run_dir/run.json"
"$REPO_ROOT/scripts/report.sh"
ok "완료: $run_dir/report.md"
