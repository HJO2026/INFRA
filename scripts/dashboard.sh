#!/usr/bin/env bash
# Grafana 대시보드 JSON 을 생성기에서 다시 만든다.
# 파이썬 실행 파일 이름이 플랫폼마다 다르므로(py3) 직접 python3 를 부르지 않는다.
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
resolve_python

py3 "$REPO_ROOT/monitoring/grafana/gen-dashboard.py" "$@"
