#!/usr/bin/env bash
# cpuset·mem_limit 을 bench.config.yml 의 budget 과 대조한다.
#  1) 정적: compose config (profile 포함) 의 cpuset / mem_limit
#  2) 동적: 떠 있는 컨테이너의 docker inspect HostConfig.CpusetCpus / Memory
# compose 에 정의된 서비스는 전부 예산표에 있어야 하고 값이 같아야 한다. 예산표에만 있는 서비스(kafka, redis)는 건너뛴다.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker jq python3
load_versions

to_bytes() {
  # 1280m / 1g / 숫자 → bytes
  local v="$1"
  case "$v" in
    *g|*G) echo $(( ${v%[gG]} * 1024 * 1024 * 1024 )) ;;
    *m|*M) echo $(( ${v%[mM]} * 1024 * 1024 )) ;;
    *)     echo "$v" ;;
  esac
}

fail=0
printf '%-18s %-8s %-10s %-8s %-12s %-12s %s\n' SERVICE CPUSET EXPECT_CPU MEM EXPECT_MEM SOURCE RESULT

# 1) 정적 검사 (profile 서비스 포함)
static_json="$(compose --profile '*' config --format json)"
for svc in $(jq -r '.services | keys[]' <<< "$static_json"); do
  exp_cpu="$(cfg "budget.$svc.cpuset" 2>/dev/null || true)"
  exp_mem="$(cfg "budget.$svc.mem_limit" 2>/dev/null || true)"
  if [[ -z "$exp_cpu" || -z "$exp_mem" ]]; then
    printf '%-18s %-8s %-10s %-8s %-12s %-12s %s\n' "$svc" - - - - compose "FAIL 예산표에 없음"
    fail=1; continue
  fi
  got_cpu="$(jq -r --arg s "$svc" '.services[$s].cpuset // ""' <<< "$static_json")"
  got_mem="$(jq -r --arg s "$svc" '.services[$s].mem_limit // ""' <<< "$static_json")"
  got_mem_b="$(to_bytes "$got_mem")"
  exp_mem_b="$(to_bytes "$exp_mem")"
  res=OK
  [[ "$got_cpu" == "$exp_cpu" && "$got_mem_b" == "$exp_mem_b" ]] || { res=FAIL; fail=1; }
  printf '%-18s %-8s %-10s %-8s %-12s %-12s %s\n' "$svc" "$got_cpu" "$exp_cpu" "$got_mem" "$exp_mem" compose "$res"
done

# 2) 동적 검사 (떠 있는 컨테이너)
for svc in $(compose config --services); do
  cid="$(container_id "$svc")"
  if [[ -z "$cid" ]]; then
    printf '%-18s %-8s %-10s %-8s %-12s %-12s %s\n' "$svc" - - - - inspect "FAIL 컨테이너 없음"
    fail=1; continue
  fi
  exp_cpu="$(cfg "budget.$svc.cpuset")"
  exp_mem_b="$(to_bytes "$(cfg "budget.$svc.mem_limit")")"
  got_cpu="$(docker inspect --format '{{.HostConfig.CpusetCpus}}' "$cid")"
  got_mem_b="$(docker inspect --format '{{.HostConfig.Memory}}' "$cid")"
  res=OK
  [[ "$got_cpu" == "$exp_cpu" && "$got_mem_b" == "$exp_mem_b" ]] || { res=FAIL; fail=1; }
  printf '%-18s %-8s %-10s %-8s %-12s %-12s %s\n' "$svc" "$got_cpu" "$exp_cpu" "$got_mem_b" "$exp_mem_b" inspect "$res"
done

if [[ $fail -eq 0 ]]; then ok "리소스 예산 일치"; else die "리소스 예산 불일치"; fi
