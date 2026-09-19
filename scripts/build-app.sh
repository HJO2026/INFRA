#!/usr/bin/env bash
# 스프링 앱 레포(APP_DIR)의 자체 Dockerfile 로 앱 이미지를 빌드한다. 태그: APP_IMAGE (versions.env 또는 셸)
# 사용: scripts/build-app.sh [--no-cache]      APP_DIR 기본값: bench-infra 와 나란히 있는 ../APP
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_cmd docker
load_versions

APP_DIR="${APP_DIR:-$REPO_ROOT/../APP}"
[[ -f "$APP_DIR/Dockerfile" ]] || die "앱 Dockerfile 없음: $APP_DIR/Dockerfile (APP_DIR 로 앱 레포 경로 지정)"
extra=()
[[ "${1:-}" == "--no-cache" ]] && extra+=(--no-cache)

rev="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "빌드: $APP_IMAGE ($APP_DIR @ $rev)"
DOCKER_BUILDKIT=1 docker build ${extra[@]+"${extra[@]}"} -t "$APP_IMAGE" "$APP_DIR"
ok "이미지 빌드 완료: $APP_IMAGE ($(docker image inspect --format '{{.Id}}' "$APP_IMAGE" | cut -c8-19))"
