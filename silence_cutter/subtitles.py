"""전사 결과를 자막 라인 청크로 정규화."""

from __future__ import annotations

from typing import List

from .fcpxml import _split_subtitle
from .transcribe import TranscribedSegment


def build_subtitle_chunks(
    segments: List[TranscribedSegment],
    *,
    max_subtitle_chars: int = 20,
) -> list[dict]:
    """전사 결과를 원본 시간축 기준 자막 청크 리스트로 변환."""
    all_chunks: list[dict] = []

    for seg in segments:
        if not seg.text:
            continue

        if seg.words:
            chunks = _split_subtitle(seg.words, max_chars=max_subtitle_chars)
        else:
            chunks = [{
                "text": seg.text,
                "start": seg.seg_start,
                "end": seg.seg_end,
            }]

        for chunk in chunks:
            start = max(chunk["start"], seg.seg_start)
            end = min(chunk["end"], seg.seg_end)
            text = chunk["text"].strip()
            if text and end > start:
                all_chunks.append({
                    "text": text,
                    "start": start,
                    "end": end,
                })

    all_chunks.sort(key=lambda c: c["start"])

    for i in range(1, len(all_chunks)):
        if all_chunks[i]["start"] < all_chunks[i - 1]["end"]:
            all_chunks[i - 1]["end"] = all_chunks[i]["start"]

    return [chunk for chunk in all_chunks if chunk["end"] > chunk["start"]]
