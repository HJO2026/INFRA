#!/usr/bin/env bash
# templates/Dockerfile 로 스텁 앱 이미지를 빌드한다. 태그: versions.env 의 APP_IMAGE 기본값(bench/stub-app:dev)
# 사용: scripts/build-stub.sh [--no-cache]
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

STUB_IMAGE="${STUB_IMAGE:-bench/stub-app:dev}"
extra=()
[[ "${1:-}" == "--no-cache" ]] && extra+=(--no-cache)

log "빌드: $STUB_IMAGE (JDK_IMAGE=$JDK_IMAGE)"
DOCKER_BUILDKIT=1 docker build ${extra[@]+"${extra[@]}"} \
  -f "$REPO_ROOT/templates/Dockerfile" \
  --build-arg "JDK_IMAGE=$JDK_IMAGE" \
  -t "$STUB_IMAGE" \
  "$REPO_ROOT/stub-app"
ok "이미지 빌드 완료: $STUB_IMAGE ($(docker image inspect --format '{{.Id}}' "$STUB_IMAGE" | cut -c8-19))"
