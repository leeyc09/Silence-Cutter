"""CapCut 호환 FCP7 XML 생성 — 무음 컷 편집 + 자막

CapCut Desktop은 Final Cut Pro 7 XML(.xml) import를 지원합니다.
(File → Import → XML File)

FCP7 XML은 FCPXML 1.13과 완전히 다른 포맷으로,
Premiere Pro, DaVinci Resolve, CapCut 등 여러 NLE에서 호환됩니다.
"""

from __future__ import annotations

import uuid
from fractions import Fraction
from pathlib import Path
from typing import List
from xml.etree.ElementTree import Element, SubElement, ElementTree, indent

from .transcribe import TranscribedSegment
from .fcpxml import _split_subtitle, VideoSegments


# ── 프레임레이트 유틸 ────────────────────────────────────────────────────────

def _ntsc_timebase(fps: float) -> tuple[int, bool]:
    """FPS → (timebase, ntsc bool).

    FCP7 XML은 <timebase>와 <ntsc>TRUE/FALSE로 프레임레이트를 표현.
    예: 23.976fps → timebase=24, ntsc=True
        30fps     → timebase=30, ntsc=False
    """
    ntsc_map = {
        23.976: (24, True),
        29.97:  (30, True),
        59.94:  (60, True),
        119.88: (120, True),
    }
    for rate, info in ntsc_map.items():
        if abs(fps - rate) < 0.05:
            return info
    ifps = int(round(fps))
    return ifps, False


def _seconds_to_frames(seconds: float, timebase: int, ntsc: bool) -> int:
    """시간(초) → 프레임 수."""
    actual_fps = timebase * 1000 / 1001 if ntsc else float(timebase)
    return int(round(seconds * actual_fps))


def _make_timecode(frames: int, timebase: int, ntsc: bool) -> str:
    """프레임 수 → HH:MM:SS:FF 타임코드 문자열."""
    fps = timebase
    f = frames % fps
    total_seconds = frames // fps
    s = total_seconds % 60
    total_minutes = total_seconds // 60
    m = total_minutes % 60
    h = total_minutes // 60
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"


# ── 공통 XML 헬퍼 ────────────────────────────────────────────────────────────

def _add_rate(parent: Element, timebase: int, ntsc: bool) -> Element:
    """<rate> 요소 추가."""
    rate = SubElement(parent, "rate")
    SubElement(rate, "timebase").text = str(timebase)
    SubElement(rate, "ntsc").text = "TRUE" if ntsc else "FALSE"
    return rate


def _add_timecode(parent: Element, timebase: int, ntsc: bool, frame: int = 0) -> None:
    """<timecode> 요소 추가."""
    tc = SubElement(parent, "timecode")
    _add_rate(tc, timebase, ntsc)
    SubElement(tc, "string").text = _make_timecode(frame, timebase, ntsc)
    SubElement(tc, "frame").text = str(frame)
    SubElement(tc, "displayformat").text = "NDF"


def _unique_id() -> str:
    """짧은 고유 ID 생성."""
    return uuid.uuid4().hex[:8]


# ── FCP7 XML 생성 (단일 영상) ─────────────────────────────────────────────────

def generate_capcut_xml(
    segments: List[TranscribedSegment],
    video_path: str | Path,
    output_path: str | Path,
    *,
    fps: float = 23.976,
    width: int = 1920,
    height: int = 1080,
    video_duration: float | None = None,
    project_name: str = "SilenceCut",
    font_size: int = 42,
    max_subtitle_chars: int = 20,
) -> Path:
    """무음 제거 + 자막이 포함된 CapCut 호환 FCP7 XML 생성."""
    video_path = Path(video_path).resolve()
    output_path = Path(output_path)

    timebase, ntsc = _ntsc_timebase(fps)

    if video_duration is None:
        video_duration = max(s.seg_end for s in segments) if segments else 0.0

    # 총 타임라인 길이 (프레임)
    total_frames = 0
    for seg in segments:
        dur_frames = _seconds_to_frames(seg.seg_end - seg.seg_start, timebase, ntsc)
        total_frames += dur_frames

    dur_total_frames = _seconds_to_frames(video_duration, timebase, ntsc)

    # ── Root: <xmeml> ──
    xmeml = Element("xmeml", version="5")

    # ── <sequence> ──
    sequence = SubElement(xmeml, "sequence")
    SubElement(sequence, "name").text = project_name
    SubElement(sequence, "duration").text = str(total_frames)
    _add_rate(sequence, timebase, ntsc)
    _add_timecode(sequence, timebase, ntsc, frame=0)

    # ── <media> ──
    media = SubElement(sequence, "media")

    # ── Video Track ──
    video_section = SubElement(media, "video")
    _add_format(video_section, width, height, timebase, ntsc)
    video_track = SubElement(video_section, "track")

    timeline_offset_frames = 0
    file_id = f"file-{_unique_id()}"
    file_url = video_path.as_uri()

    for idx, seg in enumerate(segments):
        src_start_frames = _seconds_to_frames(seg.seg_start, timebase, ntsc)
        src_end_frames = _seconds_to_frames(seg.seg_end, timebase, ntsc)
        clip_dur_frames = src_end_frames - src_start_frames

        if clip_dur_frames <= 0:
            continue

        clipitem = SubElement(video_track, "clipitem", id=f"clipitem-{idx + 1}")
        SubElement(clipitem, "name").text = (seg.text[:30] if seg.text else "clip")
        SubElement(clipitem, "duration").text = str(dur_total_frames)
        _add_rate(clipitem, timebase, ntsc)

        SubElement(clipitem, "in").text = str(src_start_frames)
        SubElement(clipitem, "out").text = str(src_end_frames)
        SubElement(clipitem, "start").text = str(timeline_offset_frames)
        SubElement(clipitem, "end").text = str(timeline_offset_frames + clip_dur_frames)

        # <file> 참조
        _add_file_ref(clipitem, file_id, video_path, file_url,
                      dur_total_frames, timebase, ntsc, width, height,
                      is_first=(idx == 0))

        timeline_offset_frames += clip_dur_frames

    # ── Audio Track ──
    audio_section = SubElement(media, "audio")
    _add_audio_format(audio_section)
    audio_track = SubElement(audio_section, "track")

    timeline_offset_frames = 0
    for idx, seg in enumerate(segments):
        src_start_frames = _seconds_to_frames(seg.seg_start, timebase, ntsc)
        src_end_frames = _seconds_to_frames(seg.seg_end, timebase, ntsc)
        clip_dur_frames = src_end_frames - src_start_frames

        if clip_dur_frames <= 0:
            continue

        clipitem = SubElement(audio_track, "clipitem", id=f"audio-clipitem-{idx + 1}")
        SubElement(clipitem, "name").text = (seg.text[:30] if seg.text else "clip")
        SubElement(clipitem, "duration").text = str(dur_total_frames)
        _add_rate(clipitem, timebase, ntsc)

        SubElement(clipitem, "in").text = str(src_start_frames)
        SubElement(clipitem, "out").text = str(src_end_frames)
        SubElement(clipitem, "start").text = str(timeline_offset_frames)
        SubElement(clipitem, "end").text = str(timeline_offset_frames + clip_dur_frames)

        # <file> 참조 (같은 file_id)
        file_el = SubElement(clipitem, "file", id=file_id)

        timeline_offset_frames += clip_dur_frames

    # ── Subtitle Track (자막) ──
    if any(seg.text for seg in segments):
        sub_track = SubElement(video_section, "track")
        SubElement(sub_track, "enabled").text = "TRUE"
        SubElement(sub_track, "locked").text = "FALSE"

        tl_offset = 0
        sub_idx = 0
        for seg in segments:
            src_dur_frames = _seconds_to_frames(
                seg.seg_end - seg.seg_start, timebase, ntsc
            )
            if src_dur_frames <= 0:
                continue

            if seg.text and seg.words:
                chunks = _split_subtitle(seg.words, max_chars=max_subtitle_chars)
            elif seg.text:
                chunks = [{
                    "text": seg.text,
                    "start": seg.seg_start,
                    "end": seg.seg_end,
                }]
            else:
                chunks = []

            for chunk in chunks:
                chunk_start = _seconds_to_frames(
                    chunk["start"] - seg.seg_start, timebase, ntsc
                )
                chunk_end = _seconds_to_frames(
                    chunk["end"] - seg.seg_start, timebase, ntsc
                )
                # 클램핑
                chunk_start = max(0, min(chunk_start, src_dur_frames))
                chunk_end = max(chunk_start, min(chunk_end, src_dur_frames))
                chunk_dur = chunk_end - chunk_start
                if chunk_dur <= 0:
                    continue

                sub_idx += 1
                _add_generator_text(
                    sub_track,
                    text=chunk["text"],
                    start_frame=tl_offset + chunk_start,
                    end_frame=tl_offset + chunk_end,
                    duration_frames=chunk_dur,
                    timebase=timebase,
                    ntsc=ntsc,
                    idx=sub_idx,
                    font_size=font_size,
                )

            tl_offset += src_dur_frames

    # ── 출력 ──
    tree = ElementTree(xmeml)
    indent(tree, space="    ")
    with open(output_path, "wb") as f:
        f.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(b'<!DOCTYPE xmeml>\n')
        tree.write(f, encoding="UTF-8", xml_declaration=False)

    return output_path


# ── FCP7 XML 생성 (멀티 영상) ─────────────────────────────────────────────────

def generate_capcut_xml_multi(
    videos: List[VideoSegments],
    output_path: str | Path,
    *,
    project_name: str = "SilenceCut",
    font_size: int = 42,
    max_subtitle_chars: int = 20,
) -> Path:
    """여러 영상의 무음 제거 + 자막을 하나의 CapCut 호환 FCP7 XML로 생성."""
    output_path = Path(output_path)

    if not videos:
        raise ValueError("영상 목록이 비어 있습니다.")

    first = videos[0]
    fps = first.fps if first.fps <= 60 else 30.0
    timebase, ntsc = _ntsc_timebase(fps)

    # 총 프레임 수 계산
    total_frames = 0
    for v in videos:
        for seg in v.segments:
            dur_frames = _seconds_to_frames(seg.seg_end - seg.seg_start, timebase, ntsc)
            total_frames += dur_frames

    # ── Root ──
    xmeml = Element("xmeml", version="5")
    sequence = SubElement(xmeml, "sequence")
    SubElement(sequence, "name").text = project_name
    SubElement(sequence, "duration").text = str(total_frames)
    _add_rate(sequence, timebase, ntsc)
    _add_timecode(sequence, timebase, ntsc, frame=0)

    media = SubElement(sequence, "media")

    # ── Video Track ──
    video_section = SubElement(media, "video")
    _add_format(video_section, first.width, first.height, timebase, ntsc)
    video_track = SubElement(video_section, "track")

    # 각 영상별 file_id
    file_ids = {}
    for vi, v in enumerate(videos):
        file_ids[vi] = f"file-{_unique_id()}"

    timeline_offset_frames = 0
    clip_idx = 0
    for vi, v in enumerate(videos):
        vp = Path(v.video_path).resolve()
        file_id = file_ids[vi]
        file_url = vp.as_uri()
        dur_frames = _seconds_to_frames(v.duration, timebase, ntsc)

        for seg_idx, seg in enumerate(v.segments):
            src_start = _seconds_to_frames(seg.seg_start, timebase, ntsc)
            src_end = _seconds_to_frames(seg.seg_end, timebase, ntsc)
            clip_dur = src_end - src_start
            if clip_dur <= 0:
                continue

            clip_idx += 1
            clipitem = SubElement(video_track, "clipitem", id=f"clipitem-{clip_idx}")
            SubElement(clipitem, "name").text = (seg.text[:30] if seg.text else vp.stem)
            SubElement(clipitem, "duration").text = str(dur_frames)
            _add_rate(clipitem, timebase, ntsc)

            SubElement(clipitem, "in").text = str(src_start)
            SubElement(clipitem, "out").text = str(src_end)
            SubElement(clipitem, "start").text = str(timeline_offset_frames)
            SubElement(clipitem, "end").text = str(timeline_offset_frames + clip_dur)

            is_first_for_file = (seg_idx == 0)
            _add_file_ref(clipitem, file_id, vp, file_url,
                          dur_frames, timebase, ntsc,
                          v.width, v.height, is_first=is_first_for_file)

            timeline_offset_frames += clip_dur

    # ── Audio Track ──
    audio_section = SubElement(media, "audio")
    _add_audio_format(audio_section)
    audio_track = SubElement(audio_section, "track")

    timeline_offset_frames = 0
    clip_idx = 0
    for vi, v in enumerate(videos):
        file_id = file_ids[vi]
        dur_frames = _seconds_to_frames(v.duration, timebase, ntsc)

        for seg in v.segments:
            src_start = _seconds_to_frames(seg.seg_start, timebase, ntsc)
            src_end = _seconds_to_frames(seg.seg_end, timebase, ntsc)
            clip_dur = src_end - src_start
            if clip_dur <= 0:
                continue

            clip_idx += 1
            clipitem = SubElement(audio_track, "clipitem", id=f"audio-clipitem-{clip_idx}")
            SubElement(clipitem, "name").text = (seg.text[:30] if seg.text else "clip")
            SubElement(clipitem, "duration").text = str(dur_frames)
            _add_rate(clipitem, timebase, ntsc)

            SubElement(clipitem, "in").text = str(src_start)
            SubElement(clipitem, "out").text = str(src_end)
            SubElement(clipitem, "start").text = str(timeline_offset_frames)
            SubElement(clipitem, "end").text = str(timeline_offset_frames + clip_dur)

            SubElement(clipitem, "file", id=file_id)
            timeline_offset_frames += clip_dur

    # ── Subtitle Track ──
    has_text = any(seg.text for v in videos for seg in v.segments)
    if has_text:
        sub_track = SubElement(video_section, "track")
        SubElement(sub_track, "enabled").text = "TRUE"
        SubElement(sub_track, "locked").text = "FALSE"

        tl_offset = 0
        sub_idx = 0
        for v in videos:
            for seg in v.segments:
                src_dur_frames = _seconds_to_frames(
                    seg.seg_end - seg.seg_start, timebase, ntsc
                )
                if src_dur_frames <= 0:
                    continue

                if seg.text and seg.words:
                    chunks = _split_subtitle(seg.words, max_chars=max_subtitle_chars)
                elif seg.text:
                    chunks = [{
                        "text": seg.text,
                        "start": seg.seg_start,
                        "end": seg.seg_end,
                    }]
                else:
                    chunks = []

                for chunk in chunks:
                    chunk_start = _seconds_to_frames(
                        chunk["start"] - seg.seg_start, timebase, ntsc
                    )
                    chunk_end = _seconds_to_frames(
                        chunk["end"] - seg.seg_start, timebase, ntsc
                    )
                    chunk_start = max(0, min(chunk_start, src_dur_frames))
                    chunk_end = max(chunk_start, min(chunk_end, src_dur_frames))
                    chunk_dur = chunk_end - chunk_start
                    if chunk_dur <= 0:
                        continue

                    sub_idx += 1
                    _add_generator_text(
                        sub_track,
                        text=chunk["text"],
                        start_frame=tl_offset + chunk_start,
                        end_frame=tl_offset + chunk_end,
                        duration_frames=chunk_dur,
                        timebase=timebase,
                        ntsc=ntsc,
                        idx=sub_idx,
                        font_size=font_size,
                    )

                tl_offset += src_dur_frames

    # ── 출력 ──
    tree = ElementTree(xmeml)
    indent(tree, space="    ")
    with open(output_path, "wb") as f:
        f.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(b'<!DOCTYPE xmeml>\n')
        tree.write(f, encoding="UTF-8", xml_declaration=False)

    return output_path


# ── 내부 헬퍼 ─────────────────────────────────────────────────────────────────

def _add_format(
    video_section: Element,
    width: int,
    height: int,
    timebase: int,
    ntsc: bool,
) -> None:
    """<format> 요소를 비디오 섹션에 추가."""
    fmt = SubElement(video_section, "format")
    sc = SubElement(fmt, "samplecharacteristics")
    _add_rate(sc, timebase, ntsc)
    SubElement(sc, "width").text = str(width)
    SubElement(sc, "height").text = str(height)
    SubElement(sc, "anamorphic").text = "FALSE"
    SubElement(sc, "pixelaspectratio").text = "square"
    SubElement(sc, "fielddominance").text = "none"


def _add_audio_format(audio_section: Element) -> None:
    """오디오 <format> 요소 추가."""
    fmt = SubElement(audio_section, "format")
    sc = SubElement(fmt, "samplecharacteristics")
    SubElement(sc, "depth").text = "16"
    SubElement(sc, "samplerate").text = "48000"


def _add_file_ref(
    parent: Element,
    file_id: str,
    video_path: Path,
    file_url: str,
    duration_frames: int,
    timebase: int,
    ntsc: bool,
    width: int,
    height: int,
    *,
    is_first: bool = False,
) -> None:
    """<file> 참조를 clipitem에 추가.

    첫 참조만 전체 정보를 포함하고, 이후는 id만 참조.
    """
    if is_first:
        file_el = SubElement(parent, "file", id=file_id)
        SubElement(file_el, "name").text = video_path.stem
        SubElement(file_el, "pathurl").text = file_url
        SubElement(file_el, "duration").text = str(duration_frames)
        _add_rate(file_el, timebase, ntsc)
        _add_timecode(file_el, timebase, ntsc, frame=0)

        fmedia = SubElement(file_el, "media")
        fvideo = SubElement(fmedia, "video")
        fvsc = SubElement(fvideo, "samplecharacteristics")
        _add_rate(fvsc, timebase, ntsc)
        SubElement(fvsc, "width").text = str(width)
        SubElement(fvsc, "height").text = str(height)
        SubElement(fvsc, "anamorphic").text = "FALSE"
        SubElement(fvsc, "pixelaspectratio").text = "square"
        SubElement(fvsc, "fielddominance").text = "none"

        faudio = SubElement(fmedia, "audio")
        fasc = SubElement(faudio, "samplecharacteristics")
        SubElement(fasc, "depth").text = "16"
        SubElement(fasc, "samplerate").text = "48000"
    else:
        SubElement(parent, "file", id=file_id)


def _add_generator_text(
    track: Element,
    *,
    text: str,
    start_frame: int,
    end_frame: int,
    duration_frames: int,
    timebase: int,
    ntsc: bool,
    idx: int,
    font_size: int = 42,
) -> None:
    """FCP7 XML 텍스트 제너레이터 (자막) 추가.

    CapCut/Premiere에서 인식 가능한 Text 제너레이터 형식.
    """
    gen = SubElement(track, "generatoritem", id=f"subtitle-{idx}")
    SubElement(gen, "name").text = text[:50]
    SubElement(gen, "duration").text = str(duration_frames)
    _add_rate(gen, timebase, ntsc)

    SubElement(gen, "in").text = "0"
    SubElement(gen, "out").text = str(duration_frames)
    SubElement(gen, "start").text = str(start_frame)
    SubElement(gen, "end").text = str(end_frame)

    SubElement(gen, "enabled").text = "TRUE"
    SubElement(gen, "anamorphic").text = "FALSE"
    SubElement(gen, "alphatype").text = "black"

    # <effect> — Text generator
    effect = SubElement(gen, "effect")
    SubElement(effect, "name").text = "Text"
    SubElement(effect, "effectid").text = "Text"
    SubElement(effect, "effectcategory").text = "Text"
    SubElement(effect, "effecttype").text = "generator"
    SubElement(effect, "mediatype").text = "video"

    # 파라미터: str (텍스트 내용)
    p_str = SubElement(effect, "parameter")
    SubElement(p_str, "parameterid").text = "str"
    SubElement(p_str, "name").text = "Text"
    SubElement(p_str, "value").text = text

    # 파라미터: fontsize
    p_fs = SubElement(effect, "parameter")
    SubElement(p_fs, "parameterid").text = "fontsize"
    SubElement(p_fs, "name").text = "Size"
    SubElement(p_fs, "valuemin").text = "0"
    SubElement(p_fs, "valuemax").text = "1000"
    SubElement(p_fs, "value").text = str(font_size)

    # 파라미터: font
    p_font = SubElement(effect, "parameter")
    SubElement(p_font, "parameterid").text = "font"
    SubElement(p_font, "name").text = "Font"
    SubElement(p_font, "value").text = "Helvetica"

    # 파라미터: fontstyle (Bold)
    p_style = SubElement(effect, "parameter")
    SubElement(p_style, "parameterid").text = "fontstyle"
    SubElement(p_style, "name").text = "Style"
    SubElement(p_style, "valuemin").text = "1"
    SubElement(p_style, "valuemax").text = "4"
    SubElement(p_style, "value").text = "1"  # Bold

    # 파라미터: fontcolor (white)
    p_color = SubElement(effect, "parameter")
    SubElement(p_color, "parameterid").text = "fontcolor"
    SubElement(p_color, "name").text = "Font Color"
    value_el = SubElement(p_color, "value")
    SubElement(value_el, "alpha").text = "255"
    SubElement(value_el, "red").text = "255"
    SubElement(value_el, "green").text = "255"
    SubElement(value_el, "blue").text = "255"

    # 파라미터: alignment (center)
    p_align = SubElement(effect, "parameter")
    SubElement(p_align, "parameterid").text = "alignment"
    SubElement(p_align, "name").text = "Alignment"
    SubElement(p_align, "valuemin").text = "1"
    SubElement(p_align, "valuemax").text = "3"
    SubElement(p_align, "value").text = "2"  # Center

    # 파라미터: origin (하단 중앙)
    p_origin = SubElement(effect, "parameter")
    SubElement(p_origin, "parameterid").text = "origin"
    SubElement(p_origin, "name").text = "Origin"
    value_origin = SubElement(p_origin, "value")
    SubElement(value_origin, "horiz").text = "0"
    SubElement(value_origin, "vert").text = "-0.35"  # 화면 하단 쪽
