#!/usr/bin/env python3
"""bench-overview 대시보드 JSON 생성기. study-spec 8장 지표 목록을 전부 패널로 만든다.

편집은 이 파일에서 하고 `python3 monitoring/grafana/gen-dashboard.py` (또는 make dashboard) 로 JSON 을 다시 만든다.
각 패널의 benchExpect 필드(Grafana 는 무시): required = 반드시 값이 있어야 함, optional = 있으면 좋음(macOS 등에서 비어도 통과),
later = 지금 없는 컴포넌트(Kafka, e2e 타이머 등). scripts/check-dashboard.sh 가 이 필드로 판정한다.
"""
import json, os

DS = {"type": "prometheus", "uid": "prometheus"}
PROJ = '{project="hjo-bench"}'
DB = '{datname="bench"}'
APP_REQ = 'http_server_requests_seconds'
NON_ACT = 'uri!~"/actuator.*"'

panels = []
y = 0
uid_counter = [1]

def next_id():
    uid_counter[0] += 1
    return uid_counter[0]

def row(title):
    global y
    panels.append({"type": "row", "title": title, "collapsed": False, "id": next_id(),
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})
    y += 1

def ts(title, targets, expect, unit="short", w=8, h=7, x=0, desc="", ptype="timeseries", extra=None, thresholds=None, ymax=None):
    """targets: [(expr, legend), ...]"""
    global y
    p = {
        "type": ptype, "title": title, "id": next_id(), "datasource": DS, "benchExpect": expect,
        "description": desc,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"refId": chr(65 + i), "datasource": DS, "expr": e, "legendFormat": l, "range": True, "instant": False}
                    for i, (e, l) in enumerate(targets)],
        "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 1, "fillOpacity": 8, "showPoints": "never", "spanNulls": True}},
                        "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
    }
    if ymax is not None:
        p["fieldConfig"]["defaults"]["max"] = ymax
        p["fieldConfig"]["defaults"]["min"] = 0
    if thresholds:
        p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps": thresholds}
        p["fieldConfig"]["defaults"]["custom"]["thresholdsStyle"] = {"mode": "line"}
    if ptype == "stat":
        p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": "value", "graphMode": "area", "textMode": "auto", "orientation": "auto"}
        p["fieldConfig"]["defaults"].pop("custom")
    if extra:
        p.update(extra)
    panels.append(p)
    return p

def line(*specs):
    """한 줄에 패널 여러 개. specs = [dict(kwargs)...]. 폭은 24 를 n 등분."""
    global y
    n = len(specs); w = 24 // n; x = 0
    for s in specs:
        s = dict(s); s.setdefault("w", w); s["x"] = x
        ts(**s); x += s["w"]
    y += max(s.get("h", 7) for s in specs)

RI = "[$__rate_interval]"

# ---------------- 부하 (k6, 클라이언트 측) ----------------
row("부하 · 클라이언트 측 (k6 remote write)")
line(
    dict(title="요청 도착률 (k6 req/s, 시나리오별)", expect="required", unit="reqps",
         targets=[(f'sum by (scenario) (rate(k6_http_reqs_total{RI}))', "{{scenario}}")],
         desc="k6 가 보낸 초당 요청 수. warmup 은 버리고 steady 만 집계한다"),
    dict(title="클라이언트 지연 p50/p95/p99 (k6, steady)", expect="required", unit="ms",
         targets=[('max(k6_http_req_duration_p50{scenario="steady"})', "p50"),
                  ('max(k6_http_req_duration_p95{scenario="steady"})', "p95"),
                  ('max(k6_http_req_duration_p99{scenario="steady"})', "p99")],
         desc="측정 기준 지연 (http_req_duration). 서버 타이머는 구간 분석용"),
    dict(title="dropped_iterations / VU", expect="optional", unit="short",
         targets=[(f'sum(rate(k6_dropped_iterations_total{RI})) or vector(0)', "dropped/s"),
                  ('max(k6_vus)', "vus"), ('max(k6_vus_max)', "vus_max")],
         desc="dropped_iterations ≠ 0 이면 회차 무효. 지표는 드롭이 실제로 생겨야 나타난다 (없으면 0)"),
)

# ---------------- 처리량 · 지연 · 에러 (서버 측) ----------------
row("처리량 · 지연 · 에러 (서버 측, Micrometer)")
line(
    dict(title="초당 성공 요청 수 (2xx/3xx, actuator 제외)", expect="required", unit="reqps",
         targets=[(f'sum(rate({APP_REQ}_count{{status!~"5..",{NON_ACT}}}{RI}))', "성공 req/s"),
                  (f'sum by (uri) (rate({APP_REQ}_count{{status!~"5..",{NON_ACT}}}{RI}))', "{{uri}}")]),
    dict(title="서버 지연 p50/p95/p99 (histogram)", expect="required", unit="s",
         targets=[(f'histogram_quantile(0.50, sum by (le) (rate({APP_REQ}_bucket{{{NON_ACT}}}{RI})))', "p50"),
                  (f'histogram_quantile(0.95, sum by (le) (rate({APP_REQ}_bucket{{{NON_ACT}}}{RI})))', "p95"),
                  (f'histogram_quantile(0.99, sum by (le) (rate({APP_REQ}_bucket{{{NON_ACT}}}{RI})))', "p99")],
         desc="percentiles-histogram 필요 (management.metrics.distribution.percentiles-histogram.http.server.requests=true)"),
    dict(title="에러 비율: 5xx / 타임아웃 / 커넥션 거부", expect="required", unit="percentunit", ymax=1,
         targets=[(f'(sum(rate({APP_REQ}_count{{status=~"5.."}}{RI})) or vector(0)) / sum(rate({APP_REQ}_count{{{NON_ACT}}}{RI}))', "5xx 비율 (서버)"),
                  (f'(sum(rate(k6_errors_timeout_total{RI})) or vector(0)) / sum(rate(k6_http_reqs_total{RI}))', "타임아웃 비율 (k6)"),
                  (f'(sum(rate(k6_errors_conn_total{RI})) or vector(0)) / sum(rate(k6_http_reqs_total{RI}))', "커넥션 거부/실패 비율 (k6)"),
                  (f'(sum(rate(k6_errors_4xx_total{RI})) or vector(0)) / sum(rate(k6_http_reqs_total{RI}))', "4xx 비율 (k6, 스크립트 버그)")],
         desc="타임아웃과 커넥션 거부는 구분한다 (study-spec 8장). k6 커스텀 카운터 errors_timeout/errors_conn"),
)

# ---------------- 비동기 ----------------
row("비동기 (Throughput 토픽 이후)")
line(
    dict(title="e2e 적재 지연 p50/p99 (client_ts → 적재)", expect="later", unit="s",
         targets=[('histogram_quantile(0.50, sum by (le) (rate(bench_ingest_e2e_seconds_bucket[$__rate_interval])))', "p50"),
                  ('histogram_quantile(0.99, sum by (le) (rate(bench_ingest_e2e_seconds_bucket[$__rate_interval])))', "p99")],
         desc="[인터페이스 제안] 컨슈머 쪽 Micrometer Timer 이름 bench.ingest.e2e (percentiles-histogram). 또는 ingested_at 컬럼 사후 집계"),
    dict(title="consumer lag (kafka_exporter)", expect="later", unit="short",
         targets=[('sum by (consumergroup, topic) (kafka_consumergroup_lag)', "{{consumergroup}}/{{topic}}")],
         desc="Kafka 도입 시 kafka_exporter 추가 (compose profile kafka)"),
    dict(title="브로커 메시지 유입 (kafka_exporter)", expect="later", unit="short",
         targets=[('sum by (topic) (rate(kafka_topic_partition_current_offset[$__rate_interval]))', "{{topic}}")]),
)

# ---------------- 포화 ----------------
row("포화 (Saturation)")
line(
    dict(title="HikariCP: active / pending / max", expect="required", unit="short",
         targets=[('sum(hikaricp_connections_active)', "active"), ('sum(hikaricp_connections_pending)', "pending (대기 스레드)"),
                  ('sum(hikaricp_connections_idle)', "idle"), ('max(hikaricp_connections_max)', "max")]),
    dict(title="HikariCP 획득 대기 시간 (acquire p99 근사, max)", expect="required", unit="s",
         targets=[('max(hikaricp_connections_acquire_seconds_max)', "acquire max"),
                  ('sum(rate(hikaricp_connections_acquire_seconds_sum[$__rate_interval])) / sum(rate(hikaricp_connections_acquire_seconds_count[$__rate_interval]))', "acquire avg"),
                  ('sum(rate(hikaricp_connections_timeout_total[$__rate_interval]))', "timeout/s")]),
    dict(title="톰캣: busy / max 스레드, 대기 커넥션(큐 근사)", expect="required", unit="short",
         targets=[('sum(tomcat_threads_busy_threads)', "busy threads"), ('max(tomcat_threads_config_max_threads)', "max threads"),
                  ('sum(tomcat_connections_current_connections)', "current connections"),
                  ('clamp_min(sum(tomcat_connections_current_connections) - sum(tomcat_threads_busy_threads), 0)', "대기 커넥션 ≈ 요청 큐"),
                  ('sum(http_server_requests_active_seconds_gcount)', "in-flight requests")],
         desc="server.tomcat.mbeanregistry.enabled=true 필요. 톰캣은 큐 길이를 직접 노출하지 않아 (현재 커넥션 − busy 스레드) 로 근사한다. 가상 스레드면 busy 는 의미가 다름"),
)
line(
    dict(title="PG 커넥션 상태별 (pg_stat_activity)", expect="required", unit="short",
         targets=[(f'sum by (state) (pg_stat_activity_count{DB})', "{{state}}"),
                  ('max(pg_settings_max_connections)', "max_connections")]),
    dict(title="PG 대기 중 백엔드 (종류별)", expect="required", unit="short",
         targets=[('sum by (wait_event_type) (pg_wait_active_count)', "{{wait_event_type}}")],
         desc="활성 백엔드 중 대기 중인 수. Lock = 락 대기 (핫 로우 경합), IO = 디스크, LWLock = 버퍼·WAL 내부 락"),
    dict(title="JVM 스레드", expect="required", unit="short",
         targets=[('sum(jvm_threads_live_threads)', "live"), ('sum by (state) (jvm_threads_states_threads)', "{{state}}")]),
)

# ---------------- GC ----------------
row("GC (JVM)")
line(
    dict(title="GC pause: 시간 비율 (초/초)", expect="optional", unit="percentunit",
         targets=[('sum by (action, cause) (rate(jvm_gc_pause_seconds_sum[$__rate_interval]))', "{{action}} / {{cause}}")],
         desc="jvm_gc_pause_* 는 첫 GC 이후에 생긴다. 스텁 부하(50 req/s × 90s, 1GB 힙)로는 GC 가 한 번도 안 일어나 비어 있을 수 있다 (optional)"),
    dict(title="GC pause: 빈도(회/s) · 최대 pause", expect="optional", unit="short",
         targets=[('sum(rate(jvm_gc_pause_seconds_count[$__rate_interval]))', "pause/s"),
                  ('max(jvm_gc_pause_seconds_max)', "max pause (s)")]),
    dict(title="allocation rate · heap used", expect="required", unit="Bps",
         targets=[('sum(rate(jvm_gc_memory_allocated_bytes_total[$__rate_interval]))', "allocated B/s"),
                  ('sum(rate(jvm_gc_memory_promoted_bytes_total[$__rate_interval]))', "promoted B/s"),
                  ('sum(jvm_memory_used_bytes{area="heap"})', "heap used (B)"),
                  ('sum(jvm_memory_max_bytes{area="heap"})', "heap max (B)")]),
)

# ---------------- DB ----------------
row("DB (PostgreSQL)")
line(
    dict(title="버퍼 캐시 히트율", expect="required", unit="percentunit", ymax=1,
         targets=[(f'sum(rate(pg_stat_database_blks_hit{DB}{RI})) / clamp_min(sum(rate(pg_stat_database_blks_hit{DB}{RI})) + sum(rate(pg_stat_database_blks_read{DB}{RI})), 1)', "hit ratio")],
         desc="Volume 토픽: 인덱스가 shared_buffers(256MB) 를 넘으면 떨어진다. OS 페이지 캐시 히트는 여기 안 잡힘"),
    dict(title="체크포인트 빈도 · 소요", expect="required", unit="short",
         targets=[('sum(rate(pg_stat_checkpointer_num_timed_total[$__rate_interval])) * 60', "timed /min"),
                  ('sum(rate(pg_stat_checkpointer_num_requested_total[$__rate_interval])) * 60', "requested /min"),
                  ('sum(rate(pg_stat_checkpointer_write_time_total[$__rate_interval]))', "write time (ms/s)"),
                  ('sum(rate(pg_stat_checkpointer_sync_time_total[$__rate_interval]))', "sync time (ms/s)")],
         desc="requested 가 잦으면 max_wal_size 부족. PG17+ pg_stat_checkpointer (exporter --collector.stat_checkpointer)"),
    dict(title="WAL 생성량", expect="required", unit="Bps",
         targets=[('sum(rate(pg_stat_wal_wal_bytes[$__rate_interval]))', "WAL B/s"),
                  ('sum(rate(pg_stat_wal_wal_buffers_full[$__rate_interval]))', "wal_buffers_full /s"),
                  ('max(pg_wal_size_bytes)', "WAL dir size (B)")],
         desc="커스텀 쿼리 pg_stat_wal (monitoring/postgres_exporter/queries.yaml)"),
)
line(
    dict(title="락 대기: 대기 백엔드 수 · 최장 대기(초) · 데드락", expect="required", unit="short",
         targets=[('sum(pg_lock_wait_backends)', "락 대기 백엔드"), ('max(pg_lock_wait_max_seconds)', "최장 락 대기 (s)"),
                  (f'sum(rate(pg_stat_database_deadlocks{DB}{RI}))', "deadlocks /s")],
         desc="Throughput 토픽의 핫 로우(view_count+1) 경합이 여기 보인다. 락 대기 시간의 누적 합은 PG 가 노출하지 않아 최장 대기와 백엔드 수로 본다. 1초 넘는 대기는 log_lock_waits 로 로그에도 남는다"),
    dict(title="락 보유 (pg_locks, 모드별)", expect="required", unit="short",
         targets=[(f'sum by (mode) (pg_locks_count{DB})', "{{mode}}")]),
    dict(title="트랜잭션 · 튜플", expect="required", unit="short",
         targets=[(f'sum(rate(pg_stat_database_xact_commit{DB}{RI}))', "commit/s"), (f'sum(rate(pg_stat_database_xact_rollback{DB}{RI}))', "rollback/s"),
                  (f'sum(rate(pg_stat_database_tup_inserted{DB}{RI}))', "inserted/s"), (f'sum(rate(pg_stat_database_tup_updated{DB}{RI}))', "updated/s"),
                  (f'sum(rate(pg_stat_database_tup_fetched{DB}{RI}))', "fetched/s")]),
)
line(
    dict(title="DB 크기 · dead tuples", expect="required", unit="bytes",
         targets=[(f'max(pg_database_size_bytes{DB})', "db size"), ('sum(pg_stat_user_tables_n_dead_tup)', "dead tuples (count)"),
                  ('sum(pg_stat_user_tables_n_live_tup)', "live tuples (count)")]),
    dict(title="PG 디스크 블록 읽기 (캐시 미스)", expect="required", unit="short",
         targets=[(f'sum(rate(pg_stat_database_blks_read{DB}{RI}))', "blks_read/s"), (f'sum(rate(pg_stat_database_blks_hit{DB}{RI}))', "blks_hit/s")]),
    dict(title="autovacuum · 롱 트랜잭션", expect="optional", unit="short",
         targets=[('sum(pg_stat_activity_autovacuum_timestamp_seconds > 0) or vector(0)', "autovacuum 실행 중"),
                  ('max(pg_long_running_transactions_oldest_timestamp_seconds) or vector(0)', "가장 오래된 트랜잭션 (s)"),
                  (f'max(pg_stat_activity_max_tx_duration{DB})', "max tx duration (s)")]),
)

# ---------------- 자원 ----------------
row("자원 · 컨테이너별 (cAdvisor)")
line(
    dict(title="CPU (코어 사용량, 컨테이너별)", expect="required", unit="short",
         targets=[(f'sum by (svc) (rate(container_cpu_usage_seconds_total{PROJ}{RI}))', "{{svc}}")],
         desc="SUT(app+postgres) 합이 4 에 가까우면 cpuset 0-3 포화. k6 는 4-5, 모니터링은 6"),
    dict(title="메모리 working set (컨테이너별) vs limit", expect="required", unit="bytes",
         targets=[(f'container_memory_working_set_bytes{PROJ}', "{{svc}}"),
                  (f'container_spec_memory_limit_bytes{PROJ}', "{{svc}} limit")]),
    dict(title="CPU throttling (cfs)", expect="optional", unit="short",
         targets=[(f'sum by (svc) (rate(container_cpu_cfs_throttled_seconds_total{PROJ}{RI}))', "{{svc}}")],
         desc="cpuset 만 쓰고 --cpus 쿼터는 없으므로 보통 0"),
)
line(
    dict(title="디스크 IOPS (컨테이너별)", expect="optional", unit="iops",
         targets=[(f'sum by (svc) (rate(container_fs_reads_total{PROJ}{RI}) + rate(container_fs_writes_total{PROJ}{RI}))', "{{svc}}")],
         desc="macOS Docker Desktop 에서는 비거나 부정확할 수 있다 (CLAUDE.md 알려진 함정)"),
    dict(title="디스크 await 근사 (io_time / ops)", expect="optional", unit="s",
         targets=[(f'sum by (svc) (rate(container_fs_io_time_seconds_total{PROJ}{RI})) / clamp_min(sum by (svc) (rate(container_fs_reads_total{PROJ}{RI}) + rate(container_fs_writes_total{PROJ}{RI})), 1)', "{{svc}}")]),
    dict(title="디스크 처리량 · 네트워크", expect="optional", unit="Bps",
         targets=[(f'sum by (svc) (rate(container_fs_writes_bytes_total{PROJ}{RI}))', "{{svc}} write"),
                  (f'sum by (svc) (rate(container_fs_reads_bytes_total{PROJ}{RI}))', "{{svc}} read"),
                  (f'sum by (svc) (rate(container_network_receive_bytes_total{PROJ}{RI}))', "{{svc}} net rx")]),
)
line(
    dict(title="같은 VM 의 다른 프로젝트 컨테이너 CPU (측정 간섭)", expect="optional", unit="short",
         targets=[('sum by (name) (rate(container_cpu_usage_seconds_total{project!="hjo-bench", name!=""}[$__rate_interval]))', "{{name}}")],
         desc="preflight 가 경고하는 외부 컨테이너. 측정 중 0 에 가까워야 한다"),
    dict(title="Docker VM 전체 CPU · 메모리", expect="optional", unit="short",
         targets=[('sum(rate(container_cpu_usage_seconds_total{id="/"}[$__rate_interval]))', "VM CPU cores"),
                  ('container_memory_working_set_bytes{id="/"}', "VM memory working set (B)")]),
)

dashboard = {
    "uid": "bench-overview", "title": "bench overview", "tags": ["bench"], "timezone": "utc", "editable": False,
    "schemaVersion": 39, "version": 1, "refresh": "5s", "time": {"from": "now-30m", "to": "now"},
    "graphTooltip": 1, "templating": {"list": []}, "annotations": {"list": []},
    "panels": panels,
}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards", "bench-overview.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(dashboard, f, ensure_ascii=False, indent=2); f.write("\n")
print(f"{out}: {sum(1 for p in panels if p['type'] != 'row')} panels, {sum(1 for p in panels if p['type'] == 'row')} rows")
