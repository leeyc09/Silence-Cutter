# Silence Cutter

**Final Cut Pro용 AI 무음 자동 편집 도구** — Silero VAD + Qwen3-ASR 기반

영상에서 무음 구간을 자동으로 감지·제거하고, 단어 단위 타임스탬프가 포함된 자막과 함께 FCPXML을 생성합니다. macOS Apple Silicon에 최적화되어 있으며, MLX 프레임워크를 통해 로컬에서 빠르게 동작합니다.

---

## 주요 기능

### 무음 컷 편집
- Silero VAD로 음성/무음 구간을 정밀하게 감지
- 무음 구간을 자동 제거하여 컴팩트한 타임라인 생성
- 자막이 내장된 FCPXML 파일 출력 (Final Cut Pro에서 바로 임포트)
- 여러 영상을 하나의 타임라인으로 병합 가능

### AI 음성 인식
- **Qwen3-ASR**: 고품질 음성-텍스트 변환 (0.6B / 1.7B 모델 지원)
- **Qwen3-ForcedAligner**: 단어 단위 정밀 타임스탬프 생성
- 다국어 지원: 한국어, 영어, 일본어, 중국어

### 자막 생성
- 한국어 종결어미·구두점 기반 자연스러운 줄 분할
- FCPXML 내장 타이틀, SRT, iTT (iTunes Timed Text) 포맷 지원
- 자막 최대 글자 수, 폰트 크기 등 세밀한 커스터마이징

### 5가지 작업 모드

| 모드 | 설명 |
|------|------|
| **무음 컷** | 영상 → 무음 제거 + 자막 FCPXML 생성 |
| **VAD 자막 생성** | 영상 → 원본 타임라인 기준 SRT/iTT 자막 생성 (무음 컷 없음) |
| **자막 재생성** | 편집된 FCPXML → 자막만 재생성 |
| **VAD 대본 추출** | 영상 → 대본 텍스트 추출 (선택적 iTT 동시 생성) |
| **FCPXML 자막 추출** | FCPXML → 내부 타이틀 텍스트를 txt로 추출 |

---

## 시스템 요구 사항

| 항목 | 요구 사항 |
|------|----------|
| **OS** | macOS (Apple Silicon 권장) |
| **Python** | 3.10 이상 |
| **ffmpeg** | ffmpeg, ffprobe 필수 |
| **디스크** | ASR 모델 다운로드에 약 2~4GB 필요 |

> **참고**: 모델은 첫 실행 시 자동으로 Hugging Face에서 다운로드됩니다.

---

## 설치

### 자동 설치 (권장)

```bash
./setup_mac.sh
```

이 스크립트는 다음을 자동으로 수행합니다:
1. Apple Silicon 환경 확인
2. ffmpeg 설치 (Homebrew 사용)
3. Python 가상환경 (`.venv`) 생성
4. 의존성 패키지 설치
5. 프로젝트 설치 (`pip install -e .`)

### 수동 설치

```bash
# 1. ffmpeg 설치 (없는 경우)
brew install ffmpeg

# 2. 가상환경 생성 및 활성화
python3 -m venv .venv
source .venv/bin/activate

# 3. 의존성 설치
pip install --upgrade pip
pip install -r requirements-mac.txt

# 4. 프로젝트 설치
pip install -e .
```

### 의존성 패키지

| 패키지 | 용도 |
|--------|------|
| `gradio>=4.0.0` | Web UI |
| `mlx-audio>=0.3.0` | Qwen3-ASR / ForcedAligner (Apple Silicon MLX) |
| `silero-vad>=5.1.2` | 음성 활동 감지 (VAD) |
| `torch>=2.0.0` | Silero VAD 런타임 |
| `librosa>=0.10.0` | 오디오 리샘플링 |
| `soundfile>=0.12.0` | WAV 파일 I/O |
| `numpy<2` | 수치 연산 |
| `soynlp` | 한국어 NLP (자막 분할) |

---

## 실행

### Web UI

```bash
./run.sh
```

브라우저가 자동으로 열리며, 다크 테마의 Gradio 인터페이스가 표시됩니다.

#### run.sh 옵션

```bash
./run.sh --port 8080          # 포트 지정 (기본: 7860)
./run.sh --host 127.0.0.1     # 호스트 지정 (기본: 0.0.0.0)
./run.sh --share              # Gradio 공유 링크 생성
./run.sh --no-browser         # 브라우저 자동 열기 비활성화
```

환경 변수로도 설정할 수 있습니다:

```bash
PORT=8080 SHARE=true ./run.sh
```

> 지정한 포트가 사용 중이면 자동으로 다음 빈 포트를 탐색합니다.

### CLI

설치 후 두 가지 방법으로 CLI를 사용할 수 있습니다:

```bash
# 모듈 실행
python -m silence_cutter <command> [options]

# 엔트리포인트 실행 (pip install -e . 이후)
silence-cutter <command> [options]
```

---

## CLI 명령어 상세

### `cut` — 무음 컷 + 자막 FCPXML 생성

영상에서 무음 구간을 제거하고, 자막이 포함된 FCPXML을 생성합니다.

```bash
silence-cutter cut input.mp4
silence-cutter cut input.mp4 -o output.fcpxml
silence-cutter cut input.mp4 -l English --itt
```

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `-o, --output` | `<입력파일>.fcpxml` | 출력 FCPXML 경로 |
| `-l, --language` | `Korean` | 음성 언어 (Korean, English, Japanese, Chinese) |
| `--asr-model` | `mlx-community/Qwen3-ASR-1.7B-8bit` | ASR 모델 ID |
| `--aligner-model` | `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | ForcedAligner 모델 ID |
| `--vad-threshold` | `0.5` | VAD 민감도 0~1 (낮을수록 민감) |
| `--min-speech-ms` | `250` | 최소 음성 구간 길이 (ms) |
| `--min-silence-ms` | `300` | 최소 무음 구간 길이 (ms) — 이보다 짧은 무음은 유지 |
| `--speech-pad-ms` | `100` | 음성 구간 앞뒤 패딩 (ms) |
| `--font-size` | `42` | 자막 폰트 크기 |
| `--max-subtitle-chars` | `20` | 자막 한 줄 최대 글자 수 |
| `--itt` | `false` | iTT 자막 파일 동시 생성 |
| `--project-name` | `SilenceCut` | FCP 프로젝트 이름 |

### `multi` — 멀티 영상 병합

여러 영상을 처리하여 하나의 FCPXML 타임라인으로 합칩니다.

```bash
silence-cutter multi video1.mp4 video2.mp4 video3.mp4
silence-cutter multi *.mp4 -o merged.fcpxml --itt
```

`cut` 명령과 동일한 옵션을 지원합니다.

### `script` — 대본 추출

영상에서 음성을 인식하여 대본 텍스트를 추출합니다.

```bash
silence-cutter script input.mp4                    # 화면 출력
silence-cutter script input.mp4 -o script.txt      # 파일 저장
silence-cutter script input.mp4 -t -o script.txt   # 타임코드 포함
silence-cutter script input.mp4 --itt              # iTT 자막 동시 생성
```

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `-o, --output` | 화면 출력 | 출력 txt 경로 |
| `-t, --timestamps` | `false` | 타임코드 포함 |
| `-l, --language` | `Korean` | 음성 언어 |
| `--asr-model` | `mlx-community/Qwen3-ASR-1.7B-8bit` | ASR 모델 ID |
| `--vad-threshold` | `0.5` | VAD 민감도 |
| `--min-silence-ms` | `300` | 최소 무음 길이 (ms) |
| `--max-subtitle-chars` | `20` | 자막 한 줄 최대 글자 수 |
| `--itt` | `false` | iTT 자막 동시 생성 |

출력 예시 (타임코드 포함):

```
[00:02.3 ~ 00:05.1] 안녕하세요 오늘은
[00:05.1 ~ 00:08.7] 무음 편집에 대해서
[00:08.7 ~ 00:12.0] 알아보겠습니다
```

### `extract` — FCPXML 자막 추출

FCPXML 안에 들어 있는 타이틀 자막 텍스트를 추출합니다. ASR은 수행하지 않습니다.

```bash
silence-cutter extract timeline.fcpxml                    # 화면 출력
silence-cutter extract timeline.fcpxml -o script.txt      # 파일 저장
silence-cutter extract timeline.fcpxml -t                 # 타임코드 포함
```

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `-o, --output` | 화면 출력 | 출력 txt 경로 |
| `-t, --timestamps` | `false` | 타임코드 포함 |

> `.fcpxmld` 번들의 경우 내부 `Info.fcpxml` 파일을 자동으로 인식합니다.

### `resub` — 자막 재생성

편집된 FCPXML을 읽어서 기존 자막을 제거하고 다시 생성합니다. 수동으로 영상을 재편집한 후 자막을 맞추고 싶을 때 사용합니다.

```bash
silence-cutter resub edited.fcpxml
silence-cutter resub edited.fcpxml -o subtitled.fcpxml --itt
```

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `-o, --output` | `<입력파일>_subtitled.fcpxml` | 출력 FCPXML 경로 |
| `-l, --language` | `Korean` | 음성 언어 |
| `--asr-model` | `mlx-community/Qwen3-ASR-1.7B-8bit` | ASR 모델 ID |
| `--aligner-model` | `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | ForcedAligner 모델 ID |
| `--font-size` | `42` | 자막 폰트 크기 |
| `--max-subtitle-chars` | `20` | 자막 한 줄 최대 글자 수 |
| `--itt` | `false` | iTT 자막 동시 생성 |

---

## 출력 파일 포맷

| 포맷 | 확장자 | 설명 |
|------|--------|------|
| **FCPXML** | `.fcpxml` | Final Cut Pro XML (무음 컷 편집 + 자막 타이틀 내장) |
| **SRT** | `.srt` | SubRip 자막 (원본 타임라인 기준) |
| **iTT** | `.itt` | iTunes Timed Text / TTML (FCP 호환 자막) |
| **TXT** | `.txt` | 대본 텍스트 (선택적 타임코드) |

### Final Cut Pro에서 열기

1. Final Cut Pro를 실행합니다
2. **File > Import > XML...** 을 선택합니다
3. 생성된 `.fcpxml` 파일을 선택합니다
4. 무음이 제거된 타임라인과 자막이 자동으로 로드됩니다

---

## 프로젝트 구조

```
Qwen3-TTS-Mac-GeneLab/
├── silence_cutter/           # 메인 패키지
│   ├── __main__.py           # CLI 엔트리포인트 (5개 서브커맨드)
│   ├── app.py                # Gradio Web UI (다크 테마)
│   ├── pipeline.py           # 파이프라인 오케스트레이션
│   ├── vad.py                # Silero VAD 음성 감지 + 오디오 추출
│   ├── transcribe.py         # Qwen3-ASR + ForcedAligner 래퍼
│   ├── fcpxml.py             # FCPXML 1.13 생성 (단일/멀티)
│   ├── subtitles.py          # 자막 청크 정규화
│   ├── srt.py                # SRT 자막 생성
│   ├── itt.py                # iTT (TTML) 자막 생성
│   ├── extract.py            # FCPXML → 텍스트 추출
│   └── retranscribe.py       # 편집된 FCPXML 자막 재생성
├── pyproject.toml            # 패키지 메타데이터 및 의존성
├── requirements-mac.txt      # macOS 의존성
├── setup_mac.sh              # 자동 설치 스크립트
├── run.sh                    # Web UI 실행 스크립트
├── run.command               # macOS 더블 클릭 실행용
└── LICENSE                   # Apache License 2.0
```

---

## 처리 파이프라인

```
영상 파일 (MP4, MOV, MKV, AVI, ...)
  │
  ├─ ffmpeg ──────────────► 16kHz mono WAV 오디오 추출
  │
  ├─ Silero VAD ──────────► 음성/무음 구간 감지
  │                           - 민감도, 최소 음성/무음 길이 조절 가능
  │                           - 긴 구간은 저에너지 지점에서 자동 분할
  │
  ├─ Qwen3-ASR ──────────► 음성 → 텍스트 변환
  │
  ├─ Qwen3-ForcedAligner ► 단어 단위 타임스탬프 생성
  │                           - 커버리지 75% 미만 시 폴백
  │
  ├─ 자막 분할 ──────────► 자연스러운 줄 분할
  │                           - 한국어 종결어미 인식 (요, 다, 까, 죠, ...)
  │                           - 구두점 분할 (. ! ? 。)
  │                           - max_chars 초과 시 강제 분할
  │
  └─ FCPXML 생성 ────────► Final Cut Pro 호환 XML 출력
                              - FCPXML 1.13 (FCP 11 호환)
                              - 프레임 경계 스냅 (Fraction 기반 정밀 계산)
                              - Basic Title 이펙트로 자막 배치
```

---

## 기술 세부 사항

### 프레임레이트 처리

`Fraction` 기반 정밀 계산으로 부동소수점 오차를 방지합니다. 지원하는 프레임레이트:

| 프레임레이트 | FCP 코드 | 프레임 듀레이션 |
|-------------|----------|---------------|
| 23.976 fps | 2398 | 1001/24000s |
| 24 fps | 24 | 100/2400s |
| 25 fps | 25 | 100/2500s |
| 29.97 fps | 2997 | 1001/30000s |
| 30 fps | 30 | 100/3000s |
| 50 fps | 50 | 100/5000s |
| 59.94 fps | 5994 | 1001/60000s |
| 60 fps | 60 | 100/6000s |
| 120 fps | 120 | 100/12000s |

> 60fps 이상의 고프레임레이트 소스는 30fps 시퀀스로 자동 변환됩니다.

### ASR 모델

| 모델 | ID | 크기 | 특징 |
|------|-----|------|------|
| Qwen3-ASR 0.6B | `mlx-community/Qwen3-ASR-0.6B-8bit` | ~600MB | 가벼운 추론 |
| Qwen3-ASR 1.7B | `mlx-community/Qwen3-ASR-1.7B-8bit` | ~1.7GB | 높은 정확도 (기본값) |
| Qwen3-ForcedAligner 0.6B | `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | ~600MB | 단어 타임스탬프 |

모든 모델은 MLX 8-bit 양자화 버전으로, Apple Silicon Neural Engine에서 효율적으로 동작합니다.

### 긴 음성 구간 처리

VAD가 배경 소음으로 인해 긴 덩어리(>15초)로 구간을 잡는 경우, 저에너지 프레임을 찾아 자동으로 세그먼트를 분할합니다:

- 최대 세그먼트 길이: 15초
- 최소 세그먼트 길이: 3초
- 분할 지점 탐색 범위: ±1초
- 프레임 크기: 20ms RMS 에너지 기반

### 자막 분할 알고리즘

1. **1순위**: 구두점 또는 한국어 종결어미에서 분할 (최소 6글자 이상일 때)
   - 종결어미: `요`, `다`, `까`, `죠`, `고`, `서`, `며`, `면`, `지만`, `는데`, `니까`, `거든`, `습니다`, `합니다` 등
   - 구두점: `. ! ? 。 ，`
2. **2순위**: `max_subtitle_chars` 초과 시 강제 분할
3. 분할 후 겹치는 타임스탬프 자동 보정

### iPhone 영상 지원

ffprobe의 회전 메타데이터를 인식하여, 세로 촬영 영상의 해상도를 자동으로 올바르게 처리합니다 (예: 1080x1920 → 올바른 세로 포맷).

---

## Web UI 스크린샷

Web UI는 다크 프로페셔널 테마로 설계되어 있으며, 5개 탭으로 구성됩니다:

- **무음 컷**: 메인 기능. 영상 업로드 → VAD 프리뷰 → 실행
- **VAD 자막 생성**: 원본 타임라인 기준 SRT/iTT 자막 생성
- **자막 재생성**: 편집된 FCPXML 자막 재생성
- **VAD 대본 추출**: 대본 텍스트 추출
- **FCPXML 자막 추출**: FCPXML 내 타이틀 텍스트 추출

고급 설정은 Accordion으로 접혀 있어 기본 인터페이스가 깔끔합니다. 처리 진행률은 프로그레스 바로 실시간 표시됩니다.

---

## 사용 예시

### 기본 워크플로우: 영상 → 무음 컷 편집

```bash
# 1. 영상의 무음을 제거하고 자막 포함 FCPXML 생성
silence-cutter cut interview.mp4

# 2. Final Cut Pro에서 File > Import > XML로 열기
# → interview.fcpxml이 자동 생성됨
```

### 유튜브 자막 생성

```bash
# SRT + iTT 자막 생성 (무음 컷 없이 원본 타임라인 기준)
# Web UI의 "VAD 자막 생성" 탭 사용 또는:
silence-cutter script video.mp4 -t -o subtitles.txt --itt
```

### 멀티 카메라 편집

```bash
# 여러 영상을 하나의 타임라인으로 합치기
silence-cutter multi cam1.mp4 cam2.mp4 cam3.mp4 \
  -o multicam.fcpxml \
  --project-name "Interview" \
  --itt
```

### 편집 후 자막 업데이트

```bash
# 1. 무음 컷 FCPXML 생성
silence-cutter cut raw.mp4

# 2. Final Cut Pro에서 수동 편집 (클립 재배치, 추가 컷 등)
# 3. 편집된 FCPXML 내보내기 (File > Export XML)

# 4. 자막만 재생성
silence-cutter resub edited.fcpxml -o final.fcpxml --itt
```

### 영어 영상 처리

```bash
silence-cutter cut presentation.mp4 -l English --max-subtitle-chars 40
```

---

## 문제 해결

### ffmpeg를 찾을 수 없습니다

```bash
brew install ffmpeg
```

### 모델 다운로드가 느립니다

첫 실행 시 Hugging Face Hub에서 모델을 다운로드합니다. 네트워크 환경에 따라 수 분이 소요될 수 있습니다. 다운로드된 모델은 `~/.cache/huggingface/hub/`에 캐시되어 이후 실행에서는 바로 로드됩니다.

### VAD가 너무 민감하거나 둔합니다

- **민감하게** (작은 소리도 음성으로 인식): `--vad-threshold 0.3`
- **둔하게** (확실한 음성만 인식): `--vad-threshold 0.7`
- **짧은 무음도 제거**: `--min-silence-ms 150`
- **긴 무음만 제거**: `--min-silence-ms 500`

### 포트가 이미 사용 중입니다

`run.sh`는 지정된 포트가 사용 중이면 자동으로 다음 빈 포트를 탐색합니다. 직접 지정하려면:

```bash
./run.sh --port 8080
```

### TOKENIZERS_PARALLELISM 경고

`setup_mac.sh`가 자동으로 `.env` 파일에 `TOKENIZERS_PARALLELISM=false`를 설정합니다. `run.sh`는 이 파일을 자동으로 로드합니다.

---

## 개발

### 개발 환경 설정

```bash
pip install -e ".[dev]"
```

### 테스트 실행

```bash
pytest
```

### 코드 포맷팅

```bash
black --line-length 100 silence_cutter/
ruff check silence_cutter/
```

---

## License

[Apache License 2.0](LICENSE)
