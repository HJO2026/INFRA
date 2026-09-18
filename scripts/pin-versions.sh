#!/usr/bin/env bash
# versions.env 의 *_IMAGE 태그마다 레지스트리에서 매니페스트 digest 를 조회해 *_DIGEST 를 채운다.
# 멱등: 이미 같은 값이면 파일이 바뀌지 않는다. 로컬 빌드 이미지(APP_IMAGE)는 건너뛴다.
# 사용: scripts/pin-versions.sh [--check]   (--check 는 갱신 없이 불일치만 보고)
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

lookup_digest() {
  # 태그 → 매니페스트(리스트) digest. buildx 가 없으면 로컬 이미지의 RepoDigest 로 대체
  local image="$1" d
  # (buildx 구버전은 --format 을 무시하므로 텍스트 출력의 Digest: 줄을 읽는다)
  d="$(docker buildx imagetools inspect "$image" 2>/dev/null | awk '/^Digest:/ {print $2; exit}' || true)"
  if [[ -z "$d" ]]; then
    d="$(docker image inspect --format '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$image" 2>/dev/null | head -n1 | sed 's/.*@//' || true)"
  fi
  printf '%s' "$d"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
changed=0
missing=0

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^([A-Z0-9_]+)_IMAGE=(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    image="${BASH_REMATCH[2]}"
    if [[ "$name" == "APP" ]]; then
      printf '%s\n' "$line" >> "$tmp"; continue
    fi
    if [[ "$image" == *:latest || "$image" != *:* ]]; then
      die "latest 또는 태그 없는 이미지는 금지: $image"
    fi
    digest="$(lookup_digest "$image")"
    if [[ -z "$digest" ]]; then
      warn "digest 조회 실패: $image"; missing=1
    fi
    LAST_NAME="$name"; LAST_DIGEST="$digest"; LAST_IMAGE="$image"
    printf '%s\n' "$line" >> "$tmp"
  elif [[ "$line" =~ ^([A-Z0-9_]+)_DIGEST=(.*)$ ]]; then
    name="${BASH_REMATCH[1]}"
    current="${BASH_REMATCH[2]}"
    if [[ "$name" == "${LAST_NAME:-}" && -n "${LAST_DIGEST:-}" ]]; then
      if [[ "$current" != "$LAST_DIGEST" ]]; then
        changed=1
        if [[ $CHECK_ONLY -eq 1 ]]; then
          warn "$LAST_IMAGE digest 불일치: 파일=$current 레지스트리=$LAST_DIGEST"
          printf '%s\n' "$line" >> "$tmp"
        else
          log "$LAST_IMAGE -> $LAST_DIGEST"
          printf '%s_DIGEST=%s\n' "$name" "$LAST_DIGEST" >> "$tmp"
        fi
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
done < "$VERSIONS_ENV"

if [[ $CHECK_ONLY -eq 1 ]]; then
  [[ $missing -eq 0 && $changed -eq 0 ]] && ok "versions.env digest 전부 일치"
  [[ $missing -eq 0 && $changed -eq 0 ]]
  exit $?
fi

if cmp -s "$tmp" "$VERSIONS_ENV"; then
  ok "versions.env 변경 없음"
else
  cp "$tmp" "$VERSIONS_ENV"
  ok "versions.env 갱신"
fi
[[ $missing -eq 0 ]] || die "일부 이미지 digest 를 못 채웠다"
# 빈 digest 가 남아 있으면 실패
if grep -Eq '^[A-Z0-9_]+_DIGEST=$' "$VERSIONS_ENV"; then
  die "빈 *_DIGEST 가 남아 있다"
fi
