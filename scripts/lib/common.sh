#!/usr/bin/env bash
# 공통 함수. 각 스크립트가 `source "$(dirname "$0")/lib/common.sh"` 로 읽는다.
# 이 파일 자체는 실행하지 않는다.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

VERSIONS_ENV="${VERSIONS_ENV:-$REPO_ROOT/versions.env}"
BENCH_CONFIG="${BENCH_CONFIG:-$REPO_ROOT/bench.config.yml}"
COMPOSE_FILE="$REPO_ROOT/compose.yaml"   # compose/ 아래 파일들을 include 한다. 이미지 태그는 versions.env, 로컬 값은 .env
# impl 레포 override 파일. 여러 개면 콜론(:)으로 구분
COMPOSE_OVERRIDE="${COMPOSE_OVERRIDE:-}"
export TZ=UTC

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
ok()   { printf '[%s] OK   %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARN %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] FAIL %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "필요한 명령이 없다: $c"
  done
}

# versions.env 의 KEY=value 를 현재 셸로 읽는다 (셸에 이미 있는 값이 우선)
load_versions() {
  [[ -f "$VERSIONS_ENV" ]] || die "versions.env 없음: $VERSIONS_ENV"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    if [[ -z "${!key:-}" ]]; then
      export "$key=$val"
    fi
  done < "$VERSIONS_ENV"
}

# docker compose 공통 호출. 인자는 compose 하위 명령
compose() {
  local args=(-f "$COMPOSE_FILE")
  if [[ -n "$COMPOSE_OVERRIDE" ]]; then
    local f
    IFS=':' read -ra _files <<< "$COMPOSE_OVERRIDE"
    for f in "${_files[@]}"; do args+=(-f "$f"); done
  fi
  docker compose "${args[@]}" "$@"
}

# bench.config.yml 에서 단순 스칼라 키를 읽는다. 중첩은 "a.b.c" 로 지정.
# 값이 배열이면 한 줄에 하나씩 출력.
cfg() {
  local path="$1"
  [[ -f "$BENCH_CONFIG" ]] || die "bench.config.yml 없음: $BENCH_CONFIG"
  python3 - "$BENCH_CONFIG" "$path" <<'PY'
import sys, re
path = sys.argv[2].split('.')
# 의존성 없이 쓰기 위한 아주 작은 YAML 부분집합 파서 (2칸 들여쓰기, 스칼라, 문자열 배열)
def parse(lines):
    root = {}
    stack = [(-1, root)]
    for raw in lines:
        line = raw.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip(' '))
        text = line.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if text.startswith('- '):
            item = text[2:].strip().strip('"').strip("'")
            if isinstance(parent, dict) and '__list__' in parent:
                parent['__list__'].append(item)
            continue
        m = re.match(r'^([A-Za-z0-9_\-]+):\s*(.*)$', text)
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        val = re.sub(r'\s+#.*$', '', val).strip()
        if val == '':
            child = {'__list__': []}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = val.strip('"').strip("'")
    return root
data = parse(open(sys.argv[1], encoding='utf-8'))
node = data
for p in path:
    if isinstance(node, dict) and p in node:
        node = node[p]
    else:
        sys.exit(1)
if isinstance(node, dict):
    if node.get('__list__'):
        print('\n'.join(node['__list__']))
    else:
        print('\n'.join(k for k in node if k != '__list__'))
else:
    print(node)
PY
}

container_id() {
  compose ps -q "$1" 2>/dev/null | head -n1
}

wait_healthy() {
  # wait_healthy <service> [timeout_sec]  : healthcheck 가 있으면 healthy, 없으면 running 까지 대기
  local svc="$1" timeout="${2:-120}" i cid status
  for ((i = 0; i < timeout; i++)); do
    cid="$(container_id "$svc")"
    if [[ -n "$cid" ]]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
      case "$status" in
        healthy|running) return 0 ;;
        exited|dead) die "$svc 컨테이너가 종료됨 (status=$status). docker compose logs $svc 확인" ;;
      esac
    fi
    sleep 1
  done
  die "$svc 가 ${timeout}s 안에 healthy 가 되지 않았다"
}

psql_in() {
  # psql_in <sql>  : postgres 컨테이너 안에서 실행
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bench}" -d "${POSTGRES_DB:-bench}" -qtAX -c "$1"
}
