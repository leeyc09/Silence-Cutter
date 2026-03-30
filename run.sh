#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║   Silence Cutter                                                  ║${NC}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

export TOKENIZERS_PARALLELISM=false

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
    PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
else
    log_error "Python 실행 파일을 찾을 수 없습니다."
    log_error "./setup_mac.sh 로 환경을 먼저 준비하세요."
    exit 1
fi

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-7860}"
SHARE="${SHARE:-false}"
BROWSER="${BROWSER:-true}"

show_help() {
    echo ""
    echo "사용법: ./run.sh [옵션]"
    echo ""
    echo "옵션:"
    echo "  --host HOST      바인드할 호스트 (기본값: 0.0.0.0)"
    echo "  --port PORT      사용할 포트 (기본값: 7860)"
    echo "  --share          Gradio 공유 링크 생성"
    echo "  --no-browser     브라우저 자동 열기 비활성화"
    echo "  -h, --help       도움말 표시"
    echo ""
    echo "환경 변수:"
    echo "  HOST             --host 와 동일"
    echo "  PORT             --port 와 동일"
    echo "  SHARE            true 이면 공유 링크 활성화"
    echo "  BROWSER          false 이면 브라우저 자동 열기 비활성화"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --share)
            SHARE="true"
            shift
            ;;
        --no-browser)
            BROWSER="false"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "알 수 없는 옵션: $1"
            show_help
            exit 1
            ;;
    esac
done

ORIGINAL_PORT=$PORT
while lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; do
    log_warning "포트 $PORT 가 이미 사용 중입니다. 다음 포트를 시도합니다."
    PORT=$((PORT + 1))
    if [ $((PORT - ORIGINAL_PORT)) -ge 100 ]; then
        log_error "포트 ${ORIGINAL_PORT}~${PORT} 범위를 사용할 수 없습니다."
        exit 1
    fi
done

if [ "$PORT" != "$ORIGINAL_PORT" ]; then
    log_success "빈 포트 $PORT 를 자동 선택했습니다."
fi

for cmd in ffmpeg ffprobe; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$cmd 를 찾을 수 없습니다."
        log_error "Homebrew 사용 시: brew install ffmpeg"
        exit 1
    fi
done

echo ""
log_info "설정:"
echo "  Python:       $PYTHON_BIN"
echo "  Host:         $HOST"
echo "  Port:         $PORT"
echo "  Share:        $SHARE"
echo "  Browser:      $BROWSER"
echo ""

if [ "$HOST" = "0.0.0.0" ]; then
    LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "localhost")
    echo -e "${GREEN}${BOLD}접속 URL:${NC}"
    echo -e "  로컬:        ${YELLOW}http://localhost:$PORT${NC}"
    echo -e "  네트워크:    ${YELLOW}http://$LOCAL_IP:$PORT${NC}"
else
    echo -e "${GREEN}${BOLD}접속 URL:${NC}"
    echo -e "  ${YELLOW}http://$HOST:$PORT${NC}"
fi

if [ "$SHARE" = "true" ]; then
    echo -e "  공유 링크:   ${YELLOW}(기동 후 출력됩니다)${NC}"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}Ctrl+C 로 종료${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

cd "$SCRIPT_DIR"

ARGS=(--host "$HOST" --port "$PORT")
if [ "$SHARE" = "true" ]; then
    ARGS+=(--share)
fi
if [ "$BROWSER" != "true" ]; then
    ARGS+=(--no-browser)
fi

exec "$PYTHON_BIN" -m silence_cutter.app "${ARGS[@]}"
