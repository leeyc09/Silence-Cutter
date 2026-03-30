<div align="center">

<img src="docs/logo.svg" width="200" alt="Silenci logo"/>

# 🎬 Silenci

**Automatically remove silence from videos and generate perfectly synced subtitles**

Drop a video → AI detects & cuts silence → Export to Final Cut Pro with word-level subtitles

[![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-Optimized-FF6B35?style=flat-square&logo=apple&logoColor=white)](#)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=flat-square)](LICENSE)
[![Stars](https://img.shields.io/github/stars/leeyc09/Silence-Cutter?style=flat-square&color=yellow)](https://github.com/leeyc09/Silenci/stargazers)

[한국어 문서](README.ko.md)

<br/>

<img src="docs/waveform.svg" width="680" alt="Waveform before and after silence removal"/>

</div>

---

## Why Silenci?

Most silence-removal tools split audio **by time**, which cuts words in half.
Silenci uses a **2-Pass ASR** approach — first transcribe, then split only at **word boundaries**.
No mid-word cuts. Ever.

| | Other tools | Silenci |
|:--|:-----------|:---------------|
| Split method | Time-based → words get chopped | Word-boundary → clean cuts |
| Subtitles | Separate tool needed | Built-in, word-level synced |
| Runs on | Cloud / GPU server | 100% local on your Mac |
| Cost | Subscription / API fees | Free & open source |
| Privacy | Upload to cloud | Offline — nothing leaves your Mac |

---

## ✨ Features

<table>
<tr>
<td width="50%">

### 🔇 Smart Silence Removal
- Silero VAD for precise speech detection
- Automatic silence removal → compact timeline
- FCPXML output (import directly to Final Cut Pro)
- Multi-video merge support

</td>
<td width="50%">

### 🗣️ AI Speech Recognition
- **Qwen3-ASR** — high-quality speech-to-text (0.6B / 1.7B)
- **Qwen3-ForcedAligner** — word-level timestamps
- Multi-language: Korean · English · Japanese · Chinese
- MLX 8-bit quantized — Apple Silicon optimized

</td>
</tr>
<tr>
<td>

### ✂️ Word-Level Subtitle Splitting
- Split at sentence endings & punctuation
- Timestamps synced to exact word boundaries
- FCPXML inline titles, SRT, iTT formats
- Customizable font size & max characters per line

</td>
<td>

### 📱 Two Interfaces
- **macOS native app** — drag & drop, real-time preview
- **CLI** — scriptable, automation-friendly

</td>
</tr>
</table>

---

## 🔬 How It Works — 2-Pass ASR Pipeline

<div align="center">
<img src="docs/pipeline.svg" width="800" alt="Processing pipeline diagram"/>
</div>

```
Pass 1:  VAD → chunk audio (30s) → ASR + ForcedAligner → word-level timestamps
Pass 2:  Split only at word end_time boundaries → never cuts mid-word
```

When splitting, the algorithm prefers the **largest silence gap** between words,
producing natural sentence-like segments.

---

## 🏗️ Architecture

<div align="center">
<img src="docs/architecture.svg" width="800" alt="Architecture diagram"/>
</div>

A Swift macOS app communicates with a Python subprocess via **JSON-RPC 2.0** over stdin/stdout.
Progress notifications stream in real-time.

---

## 🖥️ macOS App

Native SwiftUI app — load a video, configure settings, analyze, edit, and export in one window.

<div align="center">

### 📋 Analysis Settings
<img src="docs/app-settings.jpg" width="720" alt="Analysis settings dialog"/>

<br/>

### 📊 Real-time Progress
<img src="docs/app-progress.jpg" width="720" alt="Analysis progress view"/>

<br/>

### ✂️ Word-level Editing
<img src="docs/app-main.jpg" width="720" alt="Main editing screen with word-level editing"/>

</div>

### App Features

| Feature | Description |
|:--------|:------------|
| 🎬 **Load video** | Drag & drop or File → Open |
| ⚙️ **Analysis settings** | Auto-popup on load — language, model, VAD sensitivity |
| 📊 **Real-time progress** | Separate progress for analysis & model download |
| ⛔ **Cancel analysis** | Stop anytime with cancel button |
| ✂️ **Word-level editing** | Delete/restore words, split/merge clips |
| 🔍 **Find & Replace** | Cmd+F to batch-edit subtitle text |
| 📤 **Export** | FCPXML, SRT, iTT — all word-boundary split |

### Analysis Settings

| Category | Setting | Default | Description |
|:--------:|:--------|:-------:|:------------|
| Speech | Language | Korean | Korean / English / Japanese / Chinese |
| | ASR Model | 0.6B | 0.6B (fast) / 1.7B (accurate) |
| Silence | VAD Sensitivity | 0.50 | 0.1–0.9 (lower = more sensitive) |
| | Min Silence | 200ms | Shorter silences are ignored |
| | Padding | 100ms | Buffer around speech segments |
| Subtitle | Max Clip Length | 8s | 3–20s slider |
| | Max Chars/Line | 20 | Subtitle line break threshold |
| | Font Size | 42pt | FCPXML subtitle font |

> Settings are persisted via UserDefaults across app restarts.

### Build & Run

```bash
./build-release.sh                # Build → dist/SilenciApp.app
open dist/SilenciApp.app    # Launch
```

### First Launch — Auto Setup

<div align="center">
<img src="docs/setup-flow.svg" width="640" alt="First launch setup flow"/>
</div>

On first launch, the app **automatically creates a Python venv** and installs dependencies (~45 seconds).
ASR models are downloaded on first analysis with byte-level progress tracking.

| Item | Path | Size |
|:----:|------|:----:|
| 🐍 Python venv | `~/Library/Application Support/Silenci/venv/` | ~1.5 GB |
| 🤖 ASR model cache | `~/.cache/huggingface/hub/` | ~1-2 GB |

### Complete Uninstall

**Option 1 — From the app:**
> Menu bar → **Silenci** → **Python 환경 삭제**

**Option 2 — Manual:**
```bash
rm -rf ~/Library/Application\ Support/Silenci/
rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen3-*
```

---

## ⌨️ CLI Usage

```bash
python -m silence_cutter <command> [options]
silence-cutter <command> [options]      # after pip install -e .
```

### `cut` — Silence removal + subtitles

```bash
silence-cutter cut input.mp4                        # basic
silence-cutter cut input.mp4 -o output.fcpxml       # custom output
silence-cutter cut input.mp4 -l English --itt       # English + iTT
```

<details>
<summary><b>📋 All options</b></summary>

| Option | Default | Description |
|:-------|:-------:|:------------|
| `-o, --output` | `<input>.fcpxml` | Output path |
| `-l, --language` | `Korean` | Speech language |
| `--asr-model` | `Qwen3-ASR-1.7B-8bit` | ASR model |
| `--aligner-model` | `Qwen3-ForcedAligner-0.6B-8bit` | Alignment model |
| `--vad-threshold` | `0.5` | VAD sensitivity (0–1) |
| `--min-speech-ms` | `250` | Min speech duration (ms) |
| `--min-silence-ms` | `300` | Min silence duration (ms) |
| `--speech-pad-ms` | `100` | Speech padding (ms) |
| `--font-size` | `42` | Subtitle font size |
| `--max-subtitle-chars` | `20` | Max chars per subtitle line |
| `--itt` | `false` | Also generate iTT subtitles |

</details>

### `multi` — Multi-video merge

```bash
silence-cutter multi video1.mp4 video2.mp4 -o merged.fcpxml --itt
```

### `script` — Script extraction

```bash
silence-cutter script input.mp4 -t -o script.txt    # with timecodes
```

### `resub` — Regenerate subtitles

```bash
silence-cutter resub edited.fcpxml -o final.fcpxml --itt
```

### `extract` — Extract FCPXML subtitles

```bash
silence-cutter extract timeline.fcpxml -t -o script.txt
```

---

## 📦 Output Formats

| Format | Extension | Use Case | Subtitle Splitting |
|:------:|:---------:|:---------|:------------------:|
| **FCPXML** | `.fcpxml` | Final Cut Pro (silence cuts + inline subtitles) | ✅ Word-based |
| **SRT** | `.srt` | Universal subtitles (YouTube, VLC, etc.) | ✅ Word-based |
| **iTT** | `.itt` | iTunes Timed Text (FCP compatible) | ✅ Word-based |
| **TXT** | `.txt` | Plain text script (optional timecodes) | — |

> All subtitle formats use **word-level timestamps for precise splitting**.

### Import to Final Cut Pro

> **File** → **Import** → **XML...** → select the `.fcpxml` file
>
> The silence-removed timeline with embedded subtitles loads automatically.

---

## 📥 Installation

### Requirements

| Item | Requirement |
|:----:|:------------|
| **OS** | macOS 14.0+ (Apple Silicon) |
| **Python** | 3.10+ |
| **ffmpeg** | ffmpeg, ffprobe |
| **Disk** | ~2-4 GB for ASR models |

### Quick Install

```bash
./setup_mac.sh
```

### Manual Install

```bash
brew install ffmpeg
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
```

### Dependencies

| Package | Purpose |
|:--------|:--------|
| `mlx-audio` | Qwen3-ASR / ForcedAligner (MLX backend) |
| `silero-vad` | Voice Activity Detection |
| `torch` | Silero VAD runtime |
| `soundfile` | WAV I/O |
| `numpy<2` | Numerical computation |
| `soynlp` | Korean tokenization (ForcedAligner) |

---

## 🔧 Technical Details

### ASR Models

| Model | Size | Notes |
|:------|:----:|:------|
| `mlx-community/Qwen3-ASR-0.6B-8bit` | ~600MB | Lightweight inference |
| `mlx-community/Qwen3-ASR-1.7B-8bit` | ~1.7GB | Higher accuracy |
| `mlx-community/Qwen3-ForcedAligner-0.6B-8bit` | ~600MB | Word timestamps |

> All models are MLX 8-bit quantized for efficient Apple Silicon inference.
> Auto-downloaded from Hugging Face on first use → cached in `~/.cache/huggingface/hub/`.
> The app shows **byte-level download progress** in real-time.

### Subtitle Splitting Algorithm

```
Priority 1  Split at punctuation or Korean sentence endings (min 6 chars)
            Endings: 요, 다, 까, 죠, 고, 서, 며, 면, 습니다, 합니다 …
            Punctuation: . ! ? 。，

Priority 2  Force-split when exceeding max_subtitle_chars
            - Include next word if ≤3 chars (prevents particle separation)
            - Hard limit at max_chars + 8

Priority 3  Auto-correct overlapping timestamps after splitting
```

### Frame Rate Handling

`Fraction`-based precision to avoid floating-point drift:

| fps | FCP Code | Frame Duration |
|:---:|:--------:|:--------------:|
| 23.976 | 2398 | 1001/24000s |
| 24 | 24 | 100/2400s |
| 29.97 | 2997 | 1001/30000s |
| 30 | 30 | 100/3000s |
| 59.94 | 5994 | 1001/60000s |
| 60 | 60 | 100/6000s |
| 120 | 120 | 100/12000s |

---

## 🗂️ Project Structure

```
Silenci/
├── silence_cutter/                  # Python package
│   ├── server.py                    # JSON-RPC server (2-pass ASR)
│   ├── vad.py                       # Silero VAD + silence-based splitting
│   ├── transcribe.py                # Qwen3-ASR + ForcedAligner + josa merge
│   ├── fcpxml.py                    # FCPXML generation + subtitle splitting
│   ├── srt.py / itt.py              # SRT, iTT subtitles
│   ├── pipeline.py                  # CLI pipeline
│   └── ...
├── SilenciApp/                # Swift macOS app
│   ├── Package.swift
│   └── Sources/
│       ├── App.swift                # Entry point + menu (env cleanup)
│       ├── ContentView.swift        # Main layout + analysis popup
│       ├── Models/
│       │   ├── AnalysisService.swift    # Analysis runner + Python bridge
│       │   ├── AnalysisSettings.swift   # Settings model (UserDefaults)
│       │   └── ...
│       ├── Services/
│       │   ├── PythonBridge.swift        # JSON-RPC communication
│       │   ├── PythonEnvironment.swift   # Auto venv install/cleanup
│       │   └── ExportService.swift       # FCPXML/SRT/iTT (word-based split)
│       └── Views/
│           ├── AnalyzeDialogView.swift   # Pre-analysis settings popup
│           ├── AnalysisProgressView.swift # Progress + model download + cancel
│           ├── ClipCardView.swift        # Clip card (video edit + subtitle)
│           ├── WordFlowView.swift        # Word-level editing UI
│           └── SettingsView.swift        # Settings sheet
├── build-release.sh                 # Release build → dist/SilenciApp.app
├── setup_mac.sh                     # Auto Python environment setup
└── docs/                            # Diagrams & screenshots
```

---

## 🛠️ Troubleshooting

<details>
<summary><b>ffmpeg/ffprobe not found</b></summary>

```bash
brew install ffmpeg
```

The app automatically adds `/opt/homebrew/bin` to PATH.
</details>

<details>
<summary><b>Model download is slow</b></summary>

ASR models are downloaded from Hugging Face on first analysis.
Byte-level progress is shown in the app. After download, models are cached in `~/.cache/huggingface/hub/`.
</details>

<details>
<summary><b>VAD is too sensitive / not sensitive enough</b></summary>

**App:** Adjust **VAD Sensitivity** slider in the analysis popup.

**CLI:**

| Direction | Parameter |
|:----------|:----------|
| More sensitive (catch quiet speech) | `--vad-threshold 0.3` |
| Less sensitive (only clear speech) | `--vad-threshold 0.7` |
| Remove short silences too | `--min-silence-ms 150` |
| Only remove long silences | `--min-silence-ms 500` |
</details>

<details>
<summary><b>Subtitles are too short / too long</b></summary>

**App:** Adjust **Max Chars** in the analysis popup (default: 20).

**CLI:** `--max-subtitle-chars 30` for longer lines.
</details>

<details>
<summary><b>Words are cut in the middle of subtitles</b></summary>

The 2-Pass ASR approach prevents mid-word cuts.
If it still happens, try increasing `--max-segment-seconds` (default 8s → 15s).
</details>

---

## 🧑‍💻 Contributing

```bash
pip install -e ".[dev]"          # Install dev dependencies
pytest                           # Run tests
black --line-length 100 .        # Format
ruff check silence_cutter/       # Lint
```

Contributions are welcome! Please feel free to submit issues and pull requests.

---

## ⭐ Support

If you find this project useful, please consider giving it a **star** ⭐

It helps others discover the project and motivates continued development.

[![Star History Chart](https://api.star-history.com/svg?repos=leeyc09/Silence-Cutter&type=Date)](https://star-history.com/#leeyc09/Silence-Cutter&Date)

---

## 📄 License

[Apache License 2.0](LICENSE)
