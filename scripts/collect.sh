#!/usr/bin/env bash
# 회차 요약 JSON(summary.json) → metrics.json. steady 구간만 집계, 유효성 판정.
# 무효 조건: dropped_iterations ≠ 0 (어느 구간이든), 4xx > 0 (스크립트 버그), steady 요청 0, k6 비정상 종료
# 사용: scripts/collect.sh            (RUN_ID 아래 metrics.json 이 없는 회차 전부)
#       scripts/collect.sh <target> <run_no>
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd python3
[[ -n "${RUN_ID:-}" ]] || die "RUN_ID 가 필요하다"
run_dir="$REPO_ROOT/results/$RUN_ID"
[[ -d "$run_dir" ]] || die "결과 디렉터리 없음: $run_dir"

collect_one() {
  local d="$1"
  [[ -f "$d/summary.json" ]] || { warn "summary.json 없음: $d"; return 1; }
  python3 - "$d" <<'PY'
import json, sys, os
d = sys.argv[1]
s = json.load(open(os.path.join(d, "summary.json")))
meta = json.load(open(os.path.join(d, "meta.json"))) if os.path.exists(os.path.join(d, "meta.json")) else {}
m = s.get("metrics", {})
def g(name, field, default=0.0):
    v = m.get(name)
    if not v: return default
    return float(v.get(field, default))
steady = float(meta.get("load", {}).get("steady_seconds") or 0) or None
reasons = []
dropped_total = g("dropped_iterations", "count")
dropped_steady = g("dropped_iterations{scenario:steady}", "count")
reqs = g("http_reqs{scenario:steady}", "count")
e4 = g("errors_4xx", "count")
e4s = g("errors_4xx{scenario:steady}", "count")
e5 = g("errors_5xx{scenario:steady}", "count")
et = g("errors_timeout{scenario:steady}", "count")
ec = g("errors_conn{scenario:steady}", "count")
k6_exit = int(meta.get("k6_exit_code", 0))
if dropped_total > 0: reasons.append(f"dropped_iterations={int(dropped_total)} (VU 부족 또는 SUT 포화. preAllocatedVUs/maxVUs 상향 후 재측정)")
if e4 > 0: reasons.append(f"4xx={int(e4)} (스크립트 버그로 간주)")
if reqs == 0: reasons.append("steady 구간 요청 0")
if k6_exit not in (0, 99): reasons.append(f"k6 exit={k6_exit}")
err_reqs = e5 + et + ec
# 엔드포인트별
per = {}
for key in m:
    if key.startswith("http_req_duration{scenario:steady,name:"):
        name = key[len("http_req_duration{scenario:steady,name:"):-1]
        per[name] = {
            "reqs": g(f"http_reqs{{scenario:steady,name:{name}}}", "count"),
            "p50_ms": g(key, "p(50)"), "p95_ms": g(key, "p(95)"), "p99_ms": g(key, "p(99)"),
            "fail_rate": g(f"http_req_failed{{scenario:steady,name:{name}}}", "value"),
        }
out = {
    "run_id": meta.get("run_id"), "target": meta.get("target"), "run_no": meta.get("run_no"),
    "valid": len(reasons) == 0, "invalid_reasons": reasons,
    "steady_seconds": steady,
    "throughput_rps": (reqs - err_reqs) / steady if steady else None,   # 초당 성공 요청 수
    "requests_rps": reqs / steady if steady else None,
    "p50_ms": g("http_req_duration{scenario:steady}", "p(50)"),
    "p95_ms": g("http_req_duration{scenario:steady}", "p(95)"),
    "p99_ms": g("http_req_duration{scenario:steady}", "p(99)"),
    "avg_ms": g("http_req_duration{scenario:steady}", "avg"),
    "max_ms": g("http_req_duration{scenario:steady}", "max"),
    "error_rate": (err_reqs / reqs) if reqs else None,
    "http_req_failed_rate": g("http_req_failed{scenario:steady}", "value"),
    "http_reqs_steady": reqs, "http_reqs_total": g("http_reqs", "count"),
    "dropped_iterations": dropped_total, "dropped_iterations_steady": dropped_steady,
    "errors": {"5xx": e5, "timeout": et, "conn": ec, "4xx_steady": e4s, "4xx_total": e4},
    "vus_max": g("vus_max", "value"),
    "per_endpoint": per,
    "load": meta.get("load"), "app_image": meta.get("app_image"), "app_image_id": meta.get("app_image_id"),
    "started_at": meta.get("started_at"), "ended_at": meta.get("ended_at"),
}
json.dump(out, open(os.path.join(d, "metrics.json"), "w"), indent=2, ensure_ascii=False)
flag = "valid" if out["valid"] else "INVALID: " + "; ".join(reasons)
print(f"{out['target']} run-{out['run_no']}: rps={out['throughput_rps']:.1f} p50={out['p50_ms']:.1f} p95={out['p95_ms']:.1f} p99={out['p99_ms']:.1f}ms err={100*(out['error_rate'] or 0):.2f}% dropped={int(dropped_total)} -> {flag}")
PY
}

if [[ $# -ge 2 ]]; then
  collect_one "$run_dir/$1/run-$2"
else
  n=0
  for d in "$run_dir"/*/run-*/; do
    [[ -d "$d" ]] || continue
    collect_one "${d%/}" && n=$((n + 1))
  done
  ok "collect: ${n}개 회차"
fi
