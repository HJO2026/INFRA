#!/usr/bin/env bash
# 측정 전 점검: VM CPU·메모리, 디스크 여유, 이미지 digest 일치, 컨테이너 상태(healthy), 리소스 예산, 다른 프로젝트 컨테이너.
# RUN_ID 가 있으면 results/<RUN_ID>/host.json 에 호스트 스펙을 기록한다 (study-spec 3장 기록 항목).
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker jq
resolve_python
load_versions

fails=0
fail() { warn "FAIL $*"; fails=$((fails + 1)); }

# --- Docker VM 리소스 ---
docker info >/dev/null 2>&1 || die "docker 데몬에 연결할 수 없다"
ncpu="$(docker info --format '{{.NCPU}}')"
mem_b="$(docker info --format '{{.MemTotal}}')"
mem_mib=$(( mem_b / 1024 / 1024 ))
min_cpu="$(cfg preflight.min_vm_cpus)"; min_mem="$(cfg preflight.min_vm_mem_mib)"
if (( ncpu >= min_cpu )); then ok "VM CPU $ncpu (>= $min_cpu)"; else fail "VM CPU $ncpu < $min_cpu (cpuset 0-6 필요)"; fi
if (( mem_mib >= min_mem )); then ok "VM 메모리 ${mem_mib}MiB (>= ${min_mem})"; else fail "VM 메모리 ${mem_mib}MiB < ${min_mem}MiB"; fi

# --- 디스크 (VM 디스크는 경고만: docs/open-questions.md) ---
min_disk="$(cfg preflight.min_disk_free_gib)"
# `/` 는 컨테이너 안 경로다. Git Bash 가 이걸 윈도우 경로로 바꾸지 않도록 이 명령에서만 변환을 끈다
vm_free_kib="$(MSYS_NO_PATHCONV=1 docker run --rm --entrypoint df "$K6_IMAGE" -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "$vm_free_kib" ]]; then
  vm_free_gib=$(( vm_free_kib / 1024 / 1024 ))
  if (( vm_free_gib >= min_disk )); then ok "VM 디스크 여유 ${vm_free_gib}GiB"; else warn "VM 디스크 여유 ${vm_free_gib}GiB < ${min_disk}GiB (M/L 덤프 전에 Docker Desktop 디스크 크기 확인)"; fi
fi
host_free_gib=$(( $(df -Pk "$REPO_ROOT" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
ok "호스트 디스크 여유 ${host_free_gib}GiB (results/ 위치)"
docker_df="$(docker system df --format '{{.Type}}: {{.Size}} (reclaimable {{.Reclaimable}})' 2>/dev/null | tr '\n' '; ')"
log "docker system df: $docker_df"

# --- 이미지 digest 일치 ---
while IFS= read -r line; do
  [[ "$line" =~ ^([A-Z0-9_]+)_IMAGE=(.+)$ ]] || continue
  name="${BASH_REMATCH[1]}"; image="${BASH_REMATCH[2]}"
  if [[ "$name" == "APP" ]]; then continue; fi
  want_var="${name}_DIGEST"; want="${!want_var:-}"
  [[ -n "$want" ]] || { fail "$image digest 미기록 (make pin)"; continue; }
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "이미지 없음, pull: $image"; docker pull -q "$image" >/dev/null || { fail "pull 실패: $image"; continue; }
  fi
  if docker image inspect --format '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$image" | grep -q "@$want\$"; then
    ok "$image digest 일치"
  else
    fail "$image 로컬 digest 가 versions.env 와 다름 (docker pull $image 후 재확인, 또는 make pin)"
  fi
done < "$VERSIONS_ENV"

# --- 앱 이미지 ---
if docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
  ok "APP_IMAGE $APP_IMAGE ($(docker image inspect --format '{{.Id}}' "$APP_IMAGE" | cut -c8-19))"
elif docker pull -q "$APP_IMAGE" >/dev/null 2>&1; then
  ok "APP_IMAGE $APP_IMAGE pull"
else
  fail "APP_IMAGE 없음: $APP_IMAGE (make build-app)"
fi

# --- 컨테이너 상태 ---
for svc in $(compose config --services); do
  cid="$(container_id "$svc")"
  if [[ -z "$cid" ]]; then fail "$svc 컨테이너 없음 (docker compose up -d --wait)"; continue; fi
  st="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
  case "$st" in healthy|running) ok "$svc $st" ;; *) fail "$svc $st" ;; esac
done

# --- 리소스 예산 ---
if "$REPO_ROOT/scripts/check-resources.sh" >/dev/null 2>&1; then ok "cpuset·mem_limit 예산 일치"; else fail "리소스 예산 불일치 (scripts/check-resources.sh)"; fi

# --- 같은 VM 의 다른 컨테이너 (측정 간섭) ---
foreign="$(docker ps --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}' | awk -F'\t' '$2 != "bench" {print $1}' | tr '\n' ' ')"
if [[ -n "$foreign" ]]; then warn "bench 외 실행 중 컨테이너가 VM 자원을 같이 쓴다: $foreign (측정 전 정지 권장)"; else ok "다른 프로젝트 컨테이너 없음"; fi

# --- 호스트 스펙 기록 ---
# 플랫폼이 뭐든 preflight 를 죽이지 않는다. 못 읽은 값은 unknown/0 으로 남긴다 (기록용이라 판정에 쓰지 않는다).
cpu_model=unknown; phys_cores=0; host_mem_gib=0; os_ver=unknown; disk_type=unknown; host_mem_b=""
case "$BENCH_OS" in
  mac)
    cpu_model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    phys_cores="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 0)"
    host_mem_gib=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    os_ver="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
    disk_type="$(diskutil info / 2>/dev/null | awk -F': +' '/Solid State|Protocol/ {printf "%s=%s ", $1, $2}')"
    ;;
  windows)
    # Git Bash. 호스트 스펙은 PowerShell 로 읽는다 (VM 쪽 CPU·메모리는 위에서 docker info 로 이미 봤다)
    ps_get() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r' | head -n1 || true; }
    cpu_model="$(ps_get '(Get-CimInstance Win32_Processor).Name')"
    phys_cores="$(ps_get '(Get-CimInstance Win32_Processor).NumberOfCores')"
    host_mem_b="$(ps_get '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory')"
    os_ver="$(ps_get '(Get-CimInstance Win32_OperatingSystem).Caption')"
    disk_type="$(ps_get '(Get-PhysicalDisk | Select-Object -First 1).MediaType')"
    [[ -n "$cpu_model" ]] || cpu_model=unknown
    [[ "$phys_cores" =~ ^[0-9]+$ ]] || phys_cores="${NUMBER_OF_PROCESSORS:-0}"
    [[ "$host_mem_b" =~ ^[0-9]+$ ]] && host_mem_gib=$(( host_mem_b / 1024 / 1024 / 1024 ))
    [[ -n "$os_ver" ]] || os_ver=Windows
    [[ -n "$disk_type" ]] || disk_type=unknown
    ;;
  *)
    # 리눅스. WSL2 도 여기로 온다. ARM 리눅스에는 'model name' 이 없어서 여러 키를 본다
    cpu_model="$(awk -F': +' '/^(model name|Model name|Hardware|Model)/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    [[ -n "$cpu_model" ]] || cpu_model="$(uname -m)"
    phys_cores="$(nproc 2>/dev/null || echo 0)"
    host_mem_gib=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 / 1024 ))
    if [[ -r /etc/os-release ]]; then os_ver="$(. /etc/os-release && echo "$PRETTY_NAME")"; else os_ver="$(uname -sr)"; fi
    disk_type="$(lsblk -d -o NAME,ROTA 2>/dev/null | tr '\n' ' ' || echo unknown)"
    ;;
esac
runtime="$(docker info --format '{{.OperatingSystem}} / server {{.ServerVersion}}')"
log "호스트: $cpu_model, 물리코어 $phys_cores, 메모리 ${host_mem_gib}GB, $os_ver, 디스크 $disk_type"
log "Docker: $runtime, VM CPU $ncpu, VM 메모리 ${mem_mib}MiB"

if [[ -n "${RUN_ID:-}" ]]; then
  # shellcheck disable=SC2031  # REPO_ROOT 는 common.sh 가 export 한 값. 서브셸 수정 없음 (오탐)
  out="$REPO_ROOT/results/$RUN_ID/host.json"; mkdir -p "$(dirname "$out")"
  py3 - "$out" "$cpu_model" "$phys_cores" "$host_mem_gib" "$os_ver" "$disk_type" "$runtime" "$ncpu" "$mem_mib" "$foreign" "$APP_IMAGE" <<'PY'
import json, sys, datetime
a = sys.argv
json.dump({
  "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
  "cpu_model": a[2], "physical_cores": int(a[3]), "host_mem_gib": int(a[4]), "os": a[5], "disk": a[6].strip(),
  "docker_runtime": a[7], "vm_cpus": int(a[8]), "vm_mem_mib": int(a[9]),
  "foreign_containers": a[10].split(), "app_image": a[11],
}, open(a[1], "w"), ensure_ascii=False, indent=2)
PY
  ok "호스트 스펙 기록: $out"
fi

if (( fails > 0 )); then die "preflight 실패 항목 $fails 개"; fi
ok "preflight 통과"
