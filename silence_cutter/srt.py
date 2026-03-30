"""SRT 자막 파일 생성"""

from __future__ import annotations

from pathlib import Path
from typing import List

from .subtitles import build_subtitle_chunks
from .transcribe import TranscribedSegment


def _format_srt_tc(seconds: float) -> str:
    """초 → HH:MM:SS,mmm (SRT 형식)"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def generate_srt(
    segments: List[TranscribedSegment],
    output_path: str | Path,
    *,
    max_subtitle_chars: int = 20,
) -> Path:
    """SRT 자막 파일 생성."""
    output_path = Path(output_path)

    all_chunks = build_subtitle_chunks(
        segments,
        max_subtitle_chars=max_subtitle_chars,
    )

    lines = []
    idx = 0
    for chunk in all_chunks:
        if chunk["end"] <= chunk["start"]:
            continue
        idx += 1
        lines.append(str(idx))
        lines.append(f"{_format_srt_tc(chunk['start'])} --> {_format_srt_tc(chunk['end'])}")
        lines.append(chunk["text"])
        lines.append("")

    output_path.write_text("\n".join(lines), encoding="utf-8")
    return output_path
