# SilenceCutter Swift Editor — 구현 계획

## 개요

Vrew 스타일의 **텍스트 기반 영상 편집기**를 SwiftUI 네이티브 앱으로 구현한다.
기존 Python 파이프라인(Silero VAD + Qwen3-ASR)을 백엔드로 호출하고,
영상 프리뷰 + 자막 텍스트 편집을 실시간 연동하는 데스크톱 앱을 만든다.

## 아키텍처

```
┌─────────────────────────────────────────────────┐
│              SwiftUI macOS App                  │
│                                                 │
│  ┌───────────┐  ┌────────────────────────────┐  │
│  │  AVPlayer  │  │  Transcript Editor        │  │
│  │  영상 프리뷰 │  │  (클립별 텍스트 블록)       │  │
│  │           │  │                            │  │
│  │  ▶ ■ ◀   │  │  [✓] 안녕하세요 여러분      │  │
│  │  타임라인   │  │  [✓] 오늘은 Swift를 ...    │  │
│  │           │  │  [✗] 음... 그러니까        │  │ ← 삭제된 클립
│  │           │  │  [✓] 결론적으로 말하면      │  │
│  └───────────┘  └────────────────────────────┘  │
│                                                 │
│  ┌────────────────────────────────────────────┐  │
│  │  타임라인 바 (유지/삭제 구간 시각화)           │  │
│  └────────────────────────────────────────────┘  │
│                                                 │
│  [내보내기: FCPXML / SRT / iTT]                  │
└─────────────────────────────────────────────────┘
        │
        │ JSON-RPC (stdin/stdout)
        │
┌───────▼──────────────────────────────┐
│  Python Backend (subprocess)         │
│                                      │
│  silence_cutter.server               │
│  ├── extract_audio()                 │
│  ├── detect_speech()    (VAD)        │
│  ├── transcribe()       (ASR)        │
│  └── export_fcpxml()    (FCPXML)     │
└──────────────────────────────────────┘
```

## 디렉토리 구조

```
SilenceCutterApp/
├── SilenceCutterApp.xcodeproj   (또는 Package.swift)
├── SilenceCutterApp/
│   ├── App.swift                 # @main 엔트리포인트
│   ├── ContentView.swift         # 메인 레이아웃 (3패널)
│   │
│   ├── Models/
│   │   ├── Project.swift         # 프로젝트 상태 (영상, 세그먼트 목록)
│   │   ├── Segment.swift         # TranscribedSegment 대응
│   │   └── ExportFormat.swift    # FCPXML / SRT / iTT enum
│   │
│   ├── Views/
│   │   ├── VideoPlayerView.swift     # AVPlayer 래퍼 (프리뷰)
│   │   ├── TranscriptEditorView.swift # 클립별 텍스트 편집기
│   │   ├── TimelineBarView.swift     # 타임라인 시각화
│   │   ├── SegmentRowView.swift      # 개별 세그먼트 행
│   │   └── ExportView.swift          # 내보내기 설정 시트
│   │
│   ├── ViewModels/
│   │   ├── ProjectViewModel.swift    # 프로젝트 로직 + 백엔드 통신
│   │   └── PlayerViewModel.swift     # AVPlayer 제어, seek, 재생
│   │
│   ├── Services/
│   │   ├── PythonBridge.swift        # Python subprocess JSON-RPC
│   │   └── AudioExtractor.swift      # ffmpeg/AVAsset 오디오 추출
│   │
│   └── Resources/
│       └── Assets.xcassets
│
silence_cutter/
├── server.py                     # JSON-RPC 서버 (stdin/stdout)
├── vad.py                        # (기존)
├── transcribe.py                 # (기존)
├── fcpxml.py                     # (기존)
├── srt.py                        # (기존)
└── itt.py                        # (기존)
```

## Python ↔ Swift 통신 프로토콜

Swift가 Python을 subprocess로 실행하고, stdin/stdout으로 JSON-RPC 메시지를 주고받는다.

### 요청 형식
```json
{"id": 1, "method": "analyze", "params": {"video_path": "/path/to/video.mp4", "language": "Korean"}}
```

### 응답 형식
```json
{"id": 1, "result": {"segments": [...]}}
```

### 진행률 알림 (서버 → 클라이언트)
```json
{"id": null, "method": "progress", "params": {"phase": "ASR", "current": 3, "total": 10, "message": "구간 전사 중..."}}
```

### RPC 메서드 목록

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `analyze` | VAD + ASR 전체 파이프라인 | video_path, language, vad_threshold, ... |
| `vad_only` | VAD만 실행 (프리뷰용) | video_path, vad_threshold, ... |
| `export_fcpxml` | FCPXML 내보내기 | segments, video_path, fps, ... |
| `export_srt` | SRT 내보내기 | segments, output_path, ... |
| `export_itt` | iTT 내보내기 | segments, output_path, ... |

## 구현 슬라이스

### S01: 프로젝트 스캐폴딩 + Python Bridge
- Swift Package 프로젝트 생성 (macOS App)
- `PythonBridge.swift` — subprocess 실행, JSON-RPC 프로토콜
- `silence_cutter/server.py` — stdin/stdout JSON-RPC 서버
- **검증:** Swift에서 Python 호출 → echo 응답 왕복 확인

### S02: 영상 프리뷰어
- `VideoPlayerView` — AVPlayer + AVPlayerLayer SwiftUI 래퍼
- 재생/일시정지, 시간 표시, seek 바
- 프레임 단위 스텝 (← →)
- **검증:** 영상 파일 드래그앤드롭 → 재생/seek 동작

### S03: VAD + ASR 파이프라인 연동
- `ProjectViewModel.analyze()` → PythonBridge → VAD + ASR 결과 수신
- 진행률 표시 (프로그레스 바)
- `Segment` 모델로 변환
- **검증:** 영상 로드 → 분석 → 세그먼트 리스트 표시

### S04: 전사 편집기 (핵심)
- `TranscriptEditorView` — 세그먼트별 텍스트 블록 리스트
- 각 블록: 체크박스(유지/삭제) + 시간 표시 + 편집 가능 텍스트
- 클릭 시 AVPlayer를 해당 시간으로 seek
- 삭제된 블록은 취소선 + 반투명 처리
- **검증:** 텍스트 클릭 → 영상 해당 위치 재생, 체크 해제 → 시각적 삭제

### S05: 타임라인 바
- 전체 영상 길이 대비 음성/무음/삭제 구간 시각화
- 클릭 → seek
- 현재 재생 위치 인디케이터
- **검증:** 타임라인 클릭 → seek, 구간 색상 표시

### S06: 내보내기
- FCPXML / SRT / iTT 선택 내보내기
- 유지된 세그먼트만 PythonBridge를 통해 생성
- 파일 저장 다이얼로그
- **검증:** 편집 후 내보내기 → FCP에서 import 확인

## 기술 결정

| 항목 | 선택 | 이유 |
|------|------|------|
| UI 프레임워크 | SwiftUI | macOS 네이티브, AVPlayer 통합 용이 |
| 최소 macOS | 14.0 (Sonoma) | SwiftUI Observable 매크로 사용 |
| 영상 재생 | AVKit / AVFoundation | 프레임 단위 seek, 네이티브 성능 |
| Python 통신 | subprocess + JSON-RPC | 단순, 디버깅 용이, 기존 코드 재활용 |
| 빌드 | Xcode project | 코드 사이닝, 앱 번들링 필요 |

## 리스크

| 리스크 | 대응 |
|--------|------|
| Python 환경 탐색 (venv, conda 등) | 앱 번들에 Python 경로 설정 UI 제공, 또는 시스템 python3 + pip 자동 탐색 |
| ASR 모델 첫 로딩 시간 (수십 초) | 진행률 UI 표시, 모델 캐싱 상태 확인 |
| 대용량 영상 메모리 | AVPlayer는 스트리밍 재생이라 문제 없음, 오디오 추출만 주의 |
| ffmpeg 의존성 | brew install ffmpeg 안내, 또는 AVAssetExportSession으로 대체 |
