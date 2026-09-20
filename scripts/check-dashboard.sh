#!/usr/bin/env bash
# 대시보드 JSON 의 모든 패널 쿼리를 Prometheus 에 instant query 로 실행해 결과 유무를 출력한다.
# 판정: benchExpect=required 인 패널의 쿼리가 하나라도 비면 실패. optional/later 는 보고만.
# 사용: scripts/check-dashboard.sh [dashboard.json]   (PROM_URL 환경변수로 주소 변경)
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd curl
resolve_python

DASH="${1:-$REPO_ROOT/monitoring/grafana/dashboards/bench-overview.json}"
PROM_URL="${PROM_URL:-http://127.0.0.1:${PROM_HOST_PORT:-9090}}"
[[ -f "$DASH" ]] || die "대시보드 없음: $DASH"
curl -fsS "$PROM_URL/-/ready" >/dev/null || die "Prometheus 응답 없음: $PROM_URL"

py3 - "$DASH" "$PROM_URL" <<'PY'
import json, sys, urllib.request, urllib.parse
dash, prom = sys.argv[1], sys.argv[2]
d = json.load(open(dash))
subs = {"$__rate_interval": "2m", "$__interval": "15s", "$__range": "1h"}
def q(expr):
    for k, v in subs.items(): expr = expr.replace(k, v)
    data = urllib.parse.urlencode({"query": expr}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{prom}/api/v1/query", data=data), timeout=20) as r:
            j = json.load(r)
        if j.get("status") != "success": return ("ERROR", j.get("error", "")[:60])
        res = j["data"]["result"]
        if isinstance(res, list) and res:
            nonnan = [x for x in res if x.get("value", [None, "NaN"])[1] != "NaN"]
            return ("OK" if nonnan else "NAN", f"{len(res)} series")
        return ("EMPTY", "")
    except urllib.error.HTTPError as e:
        try: msg = json.load(e).get("error", "")
        except Exception: msg = str(e)
        return ("ERROR", msg[:60])
rows = []
current_row = ""
def walk(panels):
    global current_row
    for p in panels:
        if p.get("type") == "row":
            current_row = p.get("title", ""); walk(p.get("panels", [])); continue
        exp = p.get("benchExpect", "optional")
        for t in p.get("targets", []):
            st, info = q(t["expr"])
            rows.append((current_row, p.get("title", ""), t.get("refId", ""), exp, st, info, t["expr"]))
walk(d["panels"])
w1 = max(len(r[1]) for r in rows) + 1
print(f"{'PANEL':<{w1}} {'REF':<4} {'EXPECT':<9} {'RESULT':<7} INFO")
fails = 0; empties = {"required": 0, "optional": 0, "later": 0}
for row_title, title, ref, exp, st, info, expr in rows:
    flag = ""
    if st in ("EMPTY", "ERROR", "NAN") and exp == "required": fails += 1; flag = "  <-- FAIL"
    if st in ("EMPTY", "ERROR", "NAN"): empties[exp] = empties.get(exp, 0) + 1
    print(f"{title:<{w1}} {ref:<4} {exp:<9} {st:<7} {info}{flag}")
    if st == "ERROR": print(f"    expr: {expr}")
print()
print(f"쿼리 {len(rows)}개: 비어 있음 required={empties['required']} optional={empties['optional']} later={empties['later']}")
sys.exit(1 if fails else 0)
PY
rc=$?
if [[ $rc -eq 0 ]]; then ok "대시보드: 필수 패널 전부 데이터 있음"; else die "대시보드: 필수(required) 패널 중 빈 것이 있다"; fi
