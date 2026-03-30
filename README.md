# Silence Cutter

`silence_cutter`는 영상에서 무음 구간을 감지해 Final Cut Pro용 편집 XML과 자막 파일을 생성하는 도구입니다.

현재 저장소는 `silence_cutter` 실행에 필요한 코드만 남긴 상태로 정리되어 있습니다. 음성 합성용 앱 코드는 포함하지 않으며, 음성 인식은 `mlx-audio`를 통해 Qwen3 ASR/Forced Aligner 모델을 호출합니다.

## 기능

- 영상에서 음성 구간만 추출해 무음 컷 편집용 FCPXML 생성
- 원본 타임라인 기준 SRT / iTT 자막 생성
- 편집된 FCPXML 기준 자막 재생성
- 여러 영상을 하나의 FCPXML 타임라인으로 병합
- Gradio 기반 Web UI 제공

## 요구 사항

- macOS Apple Silicon 환경 권장
- Python 3.10+
- `ffmpeg`, `ffprobe`

## 설치

```bash
./setup_mac.sh
```

수동 설치가 필요하면 다음 순서로 진행하면 됩니다.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements-mac.txt
pip install -e .
```

## 실행

Web UI:

```bash
./run.sh
```

CLI:

```bash
python -m silence_cutter cut input.mp4
python -m silence_cutter multi a.mp4 b.mp4 -o merged.fcpxml
python -m silence_cutter script input.mp4 -o script.txt
python -m silence_cutter extract timeline.fcpxml -o script.txt
python -m silence_cutter resub edited.fcpxml -o subtitled.fcpxml
```

설치 후에는 엔트리포인트도 사용할 수 있습니다.

```bash
silence-cutter cut input.mp4
silence-cutter-web --port 7861
```

## 주요 출력물

- `.fcpxml`: 무음 컷 편집 결과
- `.srt`: 원본 영상 기준 자막
- `.itt`: Final Cut Pro용 자막

## 프로젝트 구조

```text
.
├── silence_cutter/
├── pyproject.toml
├── requirements-mac.txt
├── run.sh
├── run.command
└── setup_mac.sh
```

## 참고

- 모델 다운로드는 첫 실행 시점에 발생할 수 있습니다.
- `ffmpeg`가 없으면 오디오 추출 단계가 실패합니다.

## License

[Apache License 2.0](LICENSE)
