#!/bin/bash
# Finder에서 더블클릭하면 Terminal.app에서 Silence Cutter Web UI를 실행합니다.

cd "$(dirname "$0")"
exec ./run.sh "$@"
