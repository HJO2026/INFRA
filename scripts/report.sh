#!/usr/bin/env bash
# results/<RUN_ID>/*/run-*/metrics.json → results/<RUN_ID>/report.md
# 회차별 처리량·p50/p95/p99·에러율, 유효 회차의 중앙값과 편차(%). 백분위는 산술평균하지 않는다 (중앙값).
# 편차 = (max − min) / 중앙값 × 100. 임계값 초과 시 경고 (bench.config.yml measure.deviation_warn_pct)
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd python3
[[ -n "${RUN_ID:-}" ]] || die "RUN_ID 가 필요하다"
run_dir="$REPO_ROOT/results/$RUN_ID"
[[ -d "$run_dir" ]] || die "결과 디렉터리 없음: $run_dir"
WARN_PCT="$(cfg measure.deviation_warn_pct)"

python3 - "$run_dir" "$RUN_ID" "$WARN_PCT" <<'PY'
import json, sys, os, glob, statistics, datetime
run_dir, run_id, warn_pct = sys.argv[1], sys.argv[2], float(sys.argv[3])
run_meta = json.load(open(os.path.join(run_dir, "run.json"))) if os.path.exists(os.path.join(run_dir, "run.json")) else {}
host = json.load(open(os.path.join(run_dir, "host.json"))) if os.path.exists(os.path.join(run_dir, "host.json")) else {}
files = sorted(glob.glob(os.path.join(run_dir, "*", "run-*", "metrics.json")))
if not files:
    print("metrics.json 이 없다. scripts/collect.sh 먼저", file=sys.stderr); sys.exit(1)
runs = [json.load(open(f)) for f in files]
targets = run_meta.get("targets") or sorted({r["target"] for r in runs}, key=lambda t: [r["target"] for r in runs].index(t))
by_t = {t: sorted([r for r in runs if r["target"] == t], key=lambda r: r["run_no"]) for t in targets}
METRICS = [("throughput_rps", "처리량(성공 req/s)", "{:.1f}"), ("p50_ms", "p50 ms", "{:.2f}"), ("p95_ms", "p95 ms", "{:.2f}"),
           ("p99_ms", "p99 ms", "{:.2f}"), ("error_rate", "에러율 %", "{:.3f}")]
def val(r, k):
    v = r.get(k)
    if v is None: return None
    return v * 100 if k == "error_rate" else v
def fmt(k, v, f):
    return "-" if v is None else f.format(v)
def dev(vals, med):
    if not vals or med is None or med == 0: return None
    return (max(vals) - min(vals)) / med * 100
warnings = []
L = []
L.append(f"# 측정 리포트 `{run_id}`")
L.append("")
L.append(f"- 생성: {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}")
L.append(f"- 대상: {', '.join(targets)}  /  회차: {run_meta.get('runs', max(len(v) for v in by_t.values()))}  /  순서: {'무작위 (시드 고정)' if len(targets) > 1 else '단일'}")
load = (runs[0].get("load") or {})
L.append(f"- 부하: constant-arrival-rate {load.get('rate')} req/s, 워밍업 {load.get('warmup_seconds')}s (버림), steady {load.get('steady_seconds')}s (집계), VU {load.get('pre_allocated_vus')}~{load.get('max_vus')}, 시드 {load.get('seed')}")
sc = run_meta.get("scenarios") or {}
L.append("- 시나리오: " + ", ".join(f"{t}: k6/scenarios/{sc.get(t, '?')}.js" for t in targets))
if host:
    L.append(f"- 호스트: {host.get('cpu_model')} 물리코어 {host.get('physical_cores')}, RAM {host.get('host_mem_gib')}GB, {host.get('os')}, {host.get('docker_runtime')}, VM CPU {host.get('vm_cpus')} / {host.get('vm_mem_mib')}MiB, 디스크 {host.get('disk')}")
    if host.get("foreign_containers"):
        L.append(f"- ⚠ 측정 중 다른 프로젝트 컨테이너가 같은 VM 에 있었다: {', '.join(host['foreign_containers'])}")
L.append(f"- 이미지: " + "; ".join(f"{t}={by_t[t][0].get('app_image')} ({(by_t[t][0].get('app_image_id') or '')[7:19]})" for t in targets if by_t[t]))
L.append("- 규칙: 회차 전 TRUNCATE·VACUUM ANALYZE·컨테이너 재시작 (OS 페이지 캐시는 비우지 못함). `dropped_iterations` ≠ 0 또는 4xx 발생 회차는 무효. 백분위는 회차 중앙값 (산술평균 금지). 편차 = (max−min)/중앙값×100")
L.append("")
summary = {}
for t in targets:
    rs = by_t[t]; valid = [r for r in rs if r["valid"]]
    L.append(f"## {t}")
    L.append("")
    L.append("| 회차 | 유효 | " + " | ".join(n for _, n, _ in METRICS) + " | dropped | 요청수(steady) | 비고 |")
    L.append("|---|---|" + "---|" * len(METRICS) + "---|---|---|")
    for r in rs:
        note = "; ".join(r.get("invalid_reasons") or [])
        L.append(f"| {r['run_no']} | {'O' if r['valid'] else '**X**'} | " + " | ".join(fmt(k, val(r, k), f) for k, _, f in METRICS)
                 + f" | {int(r.get('dropped_iterations') or 0)} | {int(r.get('http_reqs_steady') or 0)} | {note} |")
    meds = {}; devs = {}
    for k, _, f in METRICS:
        vals = [val(r, k) for r in valid if val(r, k) is not None]
        meds[k] = statistics.median(vals) if vals else None
        devs[k] = dev(vals, meds[k])
    summary[t] = {"median": meds, "dev": devs, "valid": len(valid), "total": len(rs)}
    L.append(f"| **중앙값** ({len(valid)}/{len(rs)} 유효) | | " + " | ".join(fmt(k, meds[k], f) for k, _, f in METRICS) + " | | | |")
    L.append("| 편차 % | | " + " | ".join("-" if devs[k] is None else f"{devs[k]:.1f}" for k, _, _ in METRICS) + " | | | |")
    L.append("")
    if len(valid) < 3: warnings.append(f"{t}: 유효 회차 {len(valid)}개 (< 3). 신뢰 불가")
    for k, n, _ in METRICS:
        if devs.get(k) is not None and devs[k] > warn_pct and k != "error_rate":
            warnings.append(f"{t}: {n} 편차 {devs[k]:.1f}% > {warn_pct:.0f}%. 회차 간 신뢰 불가")
    # 엔드포인트별 중앙값
    eps = sorted({e for r in valid for e in (r.get("per_endpoint") or {})})
    if eps:
        L.append(f"엔드포인트별 (유효 회차 중앙값)")
        L.append("")
        L.append("| 엔드포인트 | req/s | p50 ms | p95 ms | p99 ms | fail % |")
        L.append("|---|---|---|---|---|---|")
        for e in eps:
            rows = [r["per_endpoint"][e] for r in valid if e in (r.get("per_endpoint") or {})]
            def med(key, scale=1.0):
                v = [row[key] * scale for row in rows if row.get(key) is not None]
                return statistics.median(v) if v else None
            st = load.get("steady_seconds") or 1
            L.append(f"| {e} | {fmt('', med('reqs', 1.0/st), '{:.1f}')} | {fmt('', med('p50_ms'), '{:.2f}')} | {fmt('', med('p95_ms'), '{:.2f}')} | {fmt('', med('p99_ms'), '{:.2f}')} | {fmt('', med('fail_rate', 100), '{:.3f}')} |")
        L.append("")
if len(targets) > 1:
    base = targets[0]
    L.append(f"## 비교 (중앙값, 배율은 `{base}` 대비)")
    L.append("")
    L.append("| 지표 | " + " | ".join(targets) + " | " + " | ".join(f"{t}/{base}" for t in targets[1:]) + " |")
    L.append("|---|" + "---|" * (len(targets) + len(targets) - 1))
    for k, n, f in METRICS:
        row = [fmt(k, summary[t]["median"][k], f) for t in targets]
        ratios = []
        for t in targets[1:]:
            a, b = summary[t]["median"][k], summary[base]["median"][k]
            if a is None or b in (None, 0): ratios.append("-")
            else:
                ratio = a / b
                # 편차보다 작은 차이는 "차이 없음"
                d = max(summary[t]["dev"].get(k) or 0, summary[base]["dev"].get(k) or 0)
                same = abs(ratio - 1) * 100 < d
                ratios.append(f"{ratio:.2f}x" + (" (차이 없음: 편차 이내)" if same else ""))
        L.append(f"| {n} | " + " | ".join(row) + " | " + " | ".join(ratios) + " |")
    L.append("")
if warnings:
    L.append("## 경고")
    L.append("")
    for w in warnings: L.append(f"- ⚠ {w}")
    L.append("")
L.append("## 확인 목록")
L.append("")
L.append(f"- dropped_iterations 전 회차 0: {'예' if all(int(r.get('dropped_iterations') or 0) == 0 for r in runs) else '**아니오**'}")
L.append(f"- 무효 회차: {sum(1 for r in runs if not r['valid'])}개")
L.append("- 그래프: Grafana `bench-overview` 대시보드에서 각 회차 `started_at`~`ended_at` 구간 (metrics.json) 스크린샷을 붙일 것")
L.append("- 알려진 한계: L3 캐시·메모리 대역폭 경합은 cpuset 으로 못 막음. OS 페이지 캐시 미초기화")
open(os.path.join(run_dir, "report.md"), "w").write("\n".join(L) + "\n")
for w in warnings: print(f"WARN {w}", file=sys.stderr)
print(os.path.join(run_dir, "report.md"))
PY
ok "report: $run_dir/report.md"
