#!/bin/bash

set -e

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

log_step() {
    echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"
}

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                                                                   ║${NC}"
echo -e "${BOLD}║   ${CYAN}Silence Cutter${NC}${BOLD}                                              ║${NC}"
echo -e "${BOLD}║   ${GREEN}Mac setup for VAD + subtitle pipeline${NC}${BOLD}                       ║${NC}"
echo -e "${BOLD}║                                                                   ║${NC}"
echo -e "${BOLD}║   ffmpeg + Python virtualenv + pip install                        ║${NC}"
echo -e "${BOLD}║                                                                   ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log_step "Step 1/4: 시스템 확인"

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    log_success "Apple Silicon (arm64) 감지"
else
    log_warning "Apple Silicon 환경 권장. 현재 아키텍처: $ARCH"
fi

if [ "$(uname -s)" = "Darwin" ]; then
    log_success "macOS 감지"
else
    log_warning "macOS 전용 설정 스크립트입니다. 현재 OS: $(uname -s)"
fi

log_step "Step 2/4: ffmpeg 확인"

if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    log_success "ffmpeg / ffprobe 사용 가능"
else
    if command -v brew >/dev/null 2>&1; then
        log_info "ffmpeg 설치 중..."
        brew install ffmpeg
        log_success "ffmpeg 설치 완료"
    else
        log_error "ffmpeg 가 필요하지만 Homebrew를 찾을 수 없습니다."
        log_error "먼저 Homebrew 또는 ffmpeg 를 설치한 뒤 다시 실행하세요."
        exit 1
    fi
fi

log_step "Step 3/4: Python 가상환경 준비"

if command -v python3.11 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3.11)"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
else
    log_error "python3 를 찾을 수 없습니다."
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/.venv" ]; then
    log_info "가상환경 생성 중..."
    "$PYTHON_BIN" -m venv "$SCRIPT_DIR/.venv"
    log_success ".venv 생성 완료"
else
    log_success "기존 .venv 재사용"
fi

source "$SCRIPT_DIR/.venv/bin/activate"

log_step "Step 4/4: 패키지 설치"

log_info "pip 업그레이드 중..."
pip install --upgrade pip

log_info "의존성 설치 중..."
pip install -r requirements-mac.txt

log_info "프로젝트 설치 중..."
pip install -e .

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    cat > "$SCRIPT_DIR/.env" <<'EOF'
export TOKENIZERS_PARALLELISM=false
EOF
    log_success ".env 생성"
else
    log_success "기존 .env 유지"
fi

echo ""
echo -e "${GREEN}${BOLD}설치 완료${NC}"
echo ""
echo "다음 명령으로 실행할 수 있습니다:"
echo "  ./run.sh"
echo "  python -m silence_cutter cut input.mp4"
echo ""
