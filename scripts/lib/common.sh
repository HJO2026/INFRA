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

# --- 플랫폼 ---
# BENCH_OS: mac | linux | windows. windows 는 Git Bash(MSYS2) 로 돌릴 때다.
# WSL2 안에서 돌리면 uname 이 Linux 라 linux 로 잡히고, 그게 맞다 (리눅스처럼 동작한다).
case "$(uname -s)" in
  Darwin)               BENCH_OS=mac ;;
  MINGW*|MSYS*|CYGWIN*) BENCH_OS=windows ;;
  *)                    BENCH_OS=linux ;;
esac
export BENCH_OS

# Git Bash 는 슬래시로 시작하는 인자를 윈도우 경로로 바꿔서 docker 에 넘긴다.
# 호스트 경로(build-app.sh 의 빌드 컨텍스트 등)에는 이 변환이 **있어야** 맞고,
# 컨테이너 안 경로(measure.sh 의 --summary-export /results/...)에는 **없어야** 맞다.
# 그래서 전부 끄지 않고(그러면 build-app 이 깨진다) 컨테이너 경로 접두사만 제외한다.
# 한 번만 빼야 하는 경우(preflight 의 `df -Pk /`)는 그 명령에만 MSYS_NO_PATHCONV=1 을 붙인다.
if [[ "$BENCH_OS" == "windows" ]]; then
  export MSYS2_ARG_CONV_EXCL='/results;/k6;/seed;/logs'
fi

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

# --- 파이썬 3 ---
# 윈도우에는 python3 가 없고 python 이나 `py -3` 만 있는 경우가 많다. 게다가 윈도우 기본 PATH 의
# python3 는 Microsoft Store 를 여는 껍데기라 command -v 로는 걸러지지 않는다. 그래서 실제로 돌려 보고 고른다.
PYTHON_BIN=""; PYTHON_ARG=""
resolve_python() {
  [[ -n "$PYTHON_BIN" ]] && return 0
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 \
      && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      PYTHON_BIN="$c"; PYTHON_ARG=""; return 0
    fi
  done
  if command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
    PYTHON_BIN="py"; PYTHON_ARG="-3"; return 0
  fi
  die "파이썬 3 을 찾지 못했다 (python3 → python → py -3 순으로 확인). 설치한 뒤 다시 실행할 것"
}

# 탭으로 나뉜 줄을 보기 좋게 정렬한다. Git Bash 에는 column 이 없을 수 있어서 없으면 탭 그대로 낸다
tabalign() {
  if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}

# py3 <인자...>   파이썬 3 실행. heredoc 으로 넘긴 표준입력도 그대로 전달된다
py3() {
  resolve_python
  if [[ -n "$PYTHON_ARG" ]]; then "$PYTHON_BIN" "$PYTHON_ARG" "$@"; else "$PYTHON_BIN" "$@"; fi
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
  py3 - "$BENCH_CONFIG" "$path" <<'PY'
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

# 접속 정보는 bench.config.yml 이 진실의 원천이다 (compose 의 PGUSER/BENCH_DB 와 같은 값이어야 한다).
# cfg 는 파이썬을 띄우므로 한 번 읽고 캐시한다.
PG_USER_CACHE=""; PG_DB_CACHE=""
pg_user() { [[ -n "$PG_USER_CACHE" ]] || PG_USER_CACHE="$(cfg postgres.user)"; printf '%s' "$PG_USER_CACHE"; }
pg_db()   { [[ -n "$PG_DB_CACHE"   ]] || PG_DB_CACHE="$(cfg postgres.db)";     printf '%s' "$PG_DB_CACHE"; }

psql_in() {
  # psql_in <sql>  : 측정 대상 DB 에서 실행
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$(pg_user)" -d "$(pg_db)" -qtAX -c "$1"
}

psql_admin() {
  # psql_admin <sql> : 관리용 DB(postgres)에서 실행. 측정 DB 를 만들고 지울 때 쓴다
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$(pg_user)" -d postgres -qtAX -c "$1"
}
