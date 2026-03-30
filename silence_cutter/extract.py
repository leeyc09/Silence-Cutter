"""FCPXML에서 자막 텍스트/대본 추출"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional


def _parse_time(s: str) -> float:
    """FCPXML 시간 문자열 → 초"""
    if s is None:
        return 0.0
    s = s.strip()
    if s.endswith("s"):
        s = s[:-1]
    if "/" in s:
        num, den = s.split("/")
        return int(num) / int(den)
    return float(s)


def _format_tc(seconds: float) -> str:
    """초 → MM:SS.s"""
    m = int(seconds // 60)
    s = seconds % 60
    return f"{m:02d}:{s:04.1f}"


def extract_script(
    fcpxml_path: str | Path,
    output_path: Optional[str | Path] = None,
    *,
    with_timestamps: bool = False,
) -> str:
    """
    FCPXML/FCPXMLD에서 자막 텍스트를 추출.

    부모 asset-clip의 타임라인 위치를 기반으로 각 타이틀의
    실제 타임라인 시간을 계산합니다.
    """
    fcpxml_path = Path(fcpxml_path)

    if fcpxml_path.is_dir():
        info_path = fcpxml_path / "Info.fcpxml"
        if not info_path.exists():
            raise FileNotFoundError(f"Info.fcpxml을 찾을 수 없습니다: {info_path}")
        xml_path = info_path
    else:
        xml_path = fcpxml_path

    tree = ET.parse(str(xml_path))

    entries = []  # (timeline_start, timeline_end, text)

    # spine 내의 asset-clip을 순회하며 타이틀 추출
    for spine in tree.iter("spine"):
        for clip in spine:
            if clip.tag not in ("asset-clip", "clip", "ref-clip", "sync-clip"):
                continue

            # 클립의 타임라인 위치와 소스 시작점
            clip_timeline_offset = _parse_time(clip.get("offset", "0s"))
            clip_src_start = _parse_time(clip.get("start", "0s"))
            clip_duration = _parse_time(clip.get("duration", "0s"))

            # 클립 내 모든 타이틀 수집
            clip_titles = []
            for title in clip.findall("title"):
                title_offset = _parse_time(title.get("offset", "0s"))
                title_duration = _parse_time(title.get("duration", "0s"))

                texts = []
                for ts in title.iter("text-style"):
                    if ts.text and ts.text.strip():
                        texts.append(ts.text.strip())

                if texts:
                    text = " ".join(texts)
                    clip_titles.append((title_offset, title_duration, text))

            if not clip_titles:
                continue

            clip_tl_end = clip_timeline_offset + clip_duration

            # 같은 offset을 공유하는 그룹을 찾아 균등 분배
            from collections import defaultdict
            groups = defaultdict(list)
            for title_offset, title_duration, text in clip_titles:
                groups[title_offset].append((title_offset, title_duration, text))

            # offset 순으로 정렬
            sorted_offsets = sorted(groups.keys())

            for oi, offset_val in enumerate(sorted_offsets):
                group = groups[offset_val]
                tl_base = clip_timeline_offset + (offset_val - clip_src_start)

                if len(group) == 1:
                    # 단일 타이틀
                    _, dur, text = group[0]
                    tl_start = max(tl_base, clip_timeline_offset)
                    tl_end = min(tl_start + dur, clip_tl_end)
                    entries.append((tl_start, tl_end, text))
                else:
                    # 같은 offset 그룹 → 다음 offset까지 균등 분배
                    if oi + 1 < len(sorted_offsets):
                        next_tl = clip_timeline_offset + (sorted_offsets[oi + 1] - clip_src_start)
                    else:
                        next_tl = clip_tl_end
                    span = max(next_tl - tl_base, 0.1)
                    step = span / len(group)
                    for gi, (_, _, text) in enumerate(group):
                        tl_start = max(tl_base + gi * step, clip_timeline_offset)
                        tl_end = min(tl_base + (gi + 1) * step, clip_tl_end)
                        entries.append((tl_start, tl_end, text))

    # 시간순 정렬
    entries.sort(key=lambda e: e[0])

    # 텍스트 생성
    lines = []
    for tl_start, tl_end, text in entries:
        if with_timestamps:
            lines.append(f"[{_format_tc(tl_start)} ~ {_format_tc(tl_end)}] {text}")
        else:
            lines.append(text)

    result = "\n".join(lines)

    if output_path:
        output_path = Path(output_path)
        output_path.write_text(result, encoding="utf-8")

    return result
