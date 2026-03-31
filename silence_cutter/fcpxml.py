"""FCPXML 1.13 생성 - 무음 컷 편집 + 자막 타이틀 (FCP 11 호환)"""

from __future__ import annotations

from fractions import Fraction
from pathlib import Path
from typing import List
from xml.etree.ElementTree import Element, SubElement, ElementTree, indent

from .transcribe import TranscribedSegment, WordTimestamp


# 프레임레이트 → (frame_duration_num, frame_duration_den, FCP fps코드)
FRAME_RATES = {
    23.976: (1001, 24000, "2398"),
    24.0:   (100, 2400,   "24"),
    25.0:   (100, 2500,   "25"),
    29.97:  (1001, 30000, "2997"),
    30.0:   (100, 3000,   "30"),
    50.0:   (100, 5000,   "50"),
    59.94:  (1001, 60000, "5994"),
    60.0:   (100, 6000,   "60"),
    90.0:   (100, 9000,   "90"),
    100.0:  (100, 10000,  "100"),
    119.88: (1001, 120000, "11988"),
    120.0:  (100, 12000,  "120"),
}


def _get_frame_info(fps: float) -> tuple[int, int, str]:
    """프레임레이트 → (num, den, fcp_code)"""
    for rate, info in FRAME_RATES.items():
        if abs(fps - rate) < 0.05:
            return info
    # 폴백: 정수 fps
    ifps = int(round(fps))
    return 100, ifps * 100, str(ifps)


def _snap_to_frame(seconds: float, frame_num: int, frame_den: int) -> Fraction:
    """시간을 프레임 경계에 스냅"""
    frame_dur = Fraction(frame_num, frame_den)
    frames = round(Fraction(seconds) / frame_dur)
    return frames * frame_dur


def _rational_str(frac: Fraction) -> str:
    """Fraction → FCPXML 시간 문자열 (예: '1001/24000s')"""
    if frac == 0:
        return "0s"
    return f"{frac.numerator}/{frac.denominator}s"


import re

# 문장 끝 패턴: 구두점 또는 한국어 종결어미
_SENTENCE_END = re.compile(r'[.!?。，,]$')
_CLAUSE_END = re.compile(r'(요|다|까|죠|고|서|며|면|지만|는데|니까|거든|래요|세요|습니다|합니다|했고|었고|였고|인데|해서|라서|더니|으니|하고)$')


def _is_natural_break(word_text: str) -> bool:
    """단어가 자연스러운 줄바꿈 지점인지 판단"""
    if _SENTENCE_END.search(word_text):
        return True
    if _CLAUSE_END.search(word_text):
        return True
    return False


def _split_subtitle(words: List[WordTimestamp], max_chars: int = 20) -> List[dict]:
    """단어 리스트를 자연스러운 문장 경계에서 분할.

    1순위: 구두점/종결어미에서 분할
    2순위: max_chars 초과 시 강제 분할

    반환: [{"text": str, "start": float, "end": float}, ...]
    """
    if not words:
        return []

    chunks = []
    current_words = []
    current_text = ""
    chunk_start = words[0].start

    for i, word in enumerate(words):
        candidate = (current_text + " " + word.text).strip() if current_text else word.text
        current_words.append(word)
        current_text = candidate

        is_last = (i == len(words) - 1)
        should_break = False

        if is_last:
            should_break = True
        elif _is_natural_break(word.text):
            # 자연스러운 끊김 지점 — 최소 길이 이상이면 분할
            if len(current_text) >= 6:
                should_break = True
        elif len(current_text) >= max_chars:
            # 강제 분할: max_chars 초과 — 단, 다음 단어가 조사/접미사면 붙여서 유지
            # (예: "없었기" 에서 자르면 "때문에"가 혼자 남는 문제 방지)
            # 단, max_chars + 8 초과 시 무조건 분할 (무한 누적 방지)
            next_word = words[i + 1].text if i + 1 < len(words) else ""
            if len(next_word) <= 3 and len(current_text) < max_chars + 8:
                # 짧은 다음 단어는 포함시키고 그 다음에서 자르기
                pass
            else:
                should_break = True

        if should_break and current_text:
            chunks.append({
                "text": current_text,
                "start": chunk_start,
                "end": current_words[-1].end,
            })
            current_words = []
            current_text = ""
            if not is_last:
                chunk_start = words[i + 1].start

    # 겹침 제거: 이전 청크의 end가 다음 청크의 start보다 크면 맞춤
    for i in range(1, len(chunks)):
        if chunks[i]["start"] < chunks[i - 1]["end"]:
            chunks[i - 1]["end"] = chunks[i]["start"]

    return chunks


def _format_name(width: int, height: int, fps_code: str) -> str:
    """FCP 포맷 이름 생성: FFVideoFormat{W}x{H}p{FPS코드}"""
    return f"FFVideoFormat{width}x{height}p{fps_code}"


def generate_fcpxml(
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
    video_path = Path(video_path).resolve()
    output_path = Path(output_path)

    # 소스 에셋 프레임 정보
    asset_fn, asset_fd, asset_fps_code = _get_frame_info(fps)

    # 시퀀스 fps: 고fps 소스는 30fps 시퀀스로 편집
    seq_fps = fps if fps <= 60 else 30.0
    seq_fn, seq_fd, seq_fps_code = _get_frame_info(seq_fps)

    if video_duration is None:
        video_duration = max(s.seg_end for s in segments) if segments else 0.0

    total_dur = Fraction(0)
    for seg in segments:
        dur = _snap_to_frame(seg.seg_end - seg.seg_start, seq_fn, seq_fd)
        total_dur += dur

    # === Root ===
    fcpxml = Element("fcpxml", version="1.13")

    # === Resources ===
    resources = SubElement(fcpxml, "resources")

    # 시퀀스 포맷
    seq_fmt_id = "r1"
    SubElement(resources, "format", {
        "id": seq_fmt_id,
        "name": _format_name(width, height, seq_fps_code),
        "frameDuration": f"{seq_fn}/{seq_fd}s",
        "width": str(width),
        "height": str(height),
        "colorSpace": "1-1-1 (Rec. 709)",
    })

    # 에셋 포맷 (소스와 다를 때만 별도 정의)
    if fps != seq_fps:
        asset_fmt_id = "r4"
        SubElement(resources, "format", {
            "id": asset_fmt_id,
            "name": _format_name(width, height, asset_fps_code),
            "frameDuration": f"{asset_fn}/{asset_fd}s",
            "width": str(width),
            "height": str(height),
            "colorSpace": "1-1-1 (Rec. 709)",
        })
    else:
        asset_fmt_id = seq_fmt_id

    # 에셋
    asset_id = "r2"
    file_url = video_path.as_uri()
    asset_el = SubElement(resources, "asset", {
        "id": asset_id,
        "name": video_path.stem,
        "start": "0s",
        "duration": _rational_str(_snap_to_frame(video_duration, asset_fn, asset_fd)),
        "hasVideo": "1",
        "hasAudio": "1",
        "format": asset_fmt_id,
    })
    SubElement(asset_el, "media-rep", {
        "kind": "original-media",
        "src": file_url,
    })

    # 자막용 effect (Basic Title - FCP 내장)
    effect_id = "r3"
    SubElement(resources, "effect", {
        "id": effect_id,
        "name": "Basic Title",
        "uid": ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti",
    })

    # === Library > Event > Project ===
    library = SubElement(fcpxml, "library")
    event = SubElement(library, "event", name=project_name)
    project = SubElement(event, "project", name=project_name)

    sequence = SubElement(project, "sequence", {
        "format": seq_fmt_id,
        "duration": _rational_str(total_dur),
        "tcStart": "0s",
        "tcFormat": "NDF",
        "audioLayout": "stereo",
        "audioRate": "48k",
    })

    spine = SubElement(sequence, "spine")

    # === Clips + Subtitles ===
    timeline_offset = Fraction(0)

    for idx, seg in enumerate(segments):
        src_start = _snap_to_frame(seg.seg_start, seq_fn, seq_fd)
        src_end = _snap_to_frame(seg.seg_end, seq_fn, seq_fd)
        clip_dur = src_end - src_start

        if clip_dur <= 0:
            continue

        # asset-clip
        clip_el = SubElement(spine, "asset-clip", {
            "ref": asset_id,
            "offset": _rational_str(timeline_offset),
            "name": seg.text[:30] if seg.text else "clip",
            "start": _rational_str(src_start),
            "duration": _rational_str(clip_dur),
            "format": seq_fmt_id,
            "tcFormat": "NDF",
        })

        # 자막 titles (connected clips, lane 1)
        if seg.text and seg.words:
            # 단어 타임스탬프로 자막 분할
            chunks = _split_subtitle(seg.words, max_chars=max_subtitle_chars)

            for ci, chunk in enumerate(chunks):
                ts_id = f"ts{idx + 1}_{ci + 1}"

                chunk_start_snap = _snap_to_frame(chunk["start"], seq_fn, seq_fd)
                chunk_end_snap = _snap_to_frame(chunk["end"], seq_fn, seq_fd)

                # 클립 경계를 넘지 않도록 클램핑
                if chunk_start_snap < src_start:
                    chunk_start_snap = src_start
                if chunk_end_snap > src_end:
                    chunk_end_snap = src_end

                chunk_dur = chunk_end_snap - chunk_start_snap
                if chunk_dur <= 0:
                    chunk_dur = _snap_to_frame(0.5, seq_fn, seq_fd)

                title_el = SubElement(clip_el, "title", {
                    "ref": effect_id,
                    "lane": "1",
                    "offset": _rational_str(chunk_start_snap),
                    "name": chunk["text"][:50],
                    "start": "3600s",
                    "duration": _rational_str(chunk_dur),
                })

                text_el = SubElement(title_el, "text")
                ts = SubElement(text_el, "text-style", ref=ts_id)
                ts.text = chunk["text"]

                ts_def = SubElement(title_el, "text-style-def", id=ts_id)
                SubElement(ts_def, "text-style", {
                    "font": "Helvetica",
                    "fontSize": str(font_size),
                    "fontColor": "1 1 1 1",
                    "bold": "1",
                    "shadowColor": "0 0 0 0.75",
                    "shadowOffset": "3 315",
                    "alignment": "center",
                })

            # Inline captions (iTT) — lane 2, same timing as titles
            for ci, chunk in enumerate(chunks):
                cap_ts_id = f"cts{idx + 1}_{ci + 1}"

                chunk_start_snap = _snap_to_frame(chunk["start"], seq_fn, seq_fd)
                chunk_end_snap = _snap_to_frame(chunk["end"], seq_fn, seq_fd)
                if chunk_start_snap < src_start:
                    chunk_start_snap = src_start
                if chunk_end_snap > src_end:
                    chunk_end_snap = src_end
                chunk_dur = chunk_end_snap - chunk_start_snap
                if chunk_dur <= 0:
                    continue

                caption_el = SubElement(clip_el, "caption", {
                    "lane": "2",
                    "offset": _rational_str(chunk_start_snap),
                    "name": chunk["text"][:50],
                    "start": "3600s",
                    "duration": _rational_str(chunk_dur),
                    "role": "iTT?captionFormat=ITT.ko",
                })
                cap_text_el = SubElement(caption_el, "text", placement="bottom")
                cap_ts = SubElement(cap_text_el, "text-style", ref=cap_ts_id)
                cap_ts.text = chunk["text"]
                cap_ts_def = SubElement(caption_el, "text-style-def", id=cap_ts_id)
                SubElement(cap_ts_def, "text-style", {
                    "font": ".AppleSystemUIFont",
                    "fontSize": "13",
                    "fontFace": "Regular",
                    "fontColor": "1 1 1 1",
                    "backgroundColor": "0 0 0 1",
                })

        elif seg.text:
            # 단어 타임스탬프 없을 때 폴백: 전체 텍스트 한 줄
            ts_id = f"ts{idx + 1}_0"

            title_el = SubElement(clip_el, "title", {
                "ref": effect_id,
                "lane": "1",
                "offset": _rational_str(src_start),
                "name": seg.text[:50],
                "start": "3600s",
                "duration": _rational_str(clip_dur),
            })

            text_el = SubElement(title_el, "text")
            ts = SubElement(text_el, "text-style", ref=ts_id)
            ts.text = seg.text

            ts_def = SubElement(title_el, "text-style-def", id=ts_id)
            SubElement(ts_def, "text-style", {
                "font": "Helvetica",
                "fontSize": str(font_size),
                "fontColor": "1 1 1 1",
                "bold": "1",
                "shadowColor": "0 0 0 0.75",
                "shadowOffset": "3 315",
                "alignment": "center",
            })

            # Fallback caption (no words)
            cap_ts_id = f"cts{idx + 1}_0"
            caption_el = SubElement(clip_el, "caption", {
                "lane": "2",
                "offset": _rational_str(src_start),
                "name": seg.text[:50],
                "start": "3600s",
                "duration": _rational_str(clip_dur),
                "role": "iTT?captionFormat=ITT.ko",
            })
            cap_text_el = SubElement(caption_el, "text", placement="bottom")
            cap_ts = SubElement(cap_text_el, "text-style", ref=cap_ts_id)
            cap_ts.text = seg.text
            cap_ts_def = SubElement(caption_el, "text-style-def", id=cap_ts_id)
            SubElement(cap_ts_def, "text-style", {
                "font": ".AppleSystemUIFont",
                "fontSize": "13",
                "fontFace": "Regular",
                "fontColor": "1 1 1 1",
                "backgroundColor": "0 0 0 1",
            })

        timeline_offset += clip_dur

    # === Write ===
    tree = ElementTree(fcpxml)
    indent(tree, space="    ")

    with open(output_path, "wb") as f:
        f.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(b'<!DOCTYPE fcpxml>\n')
        tree.write(f, encoding="UTF-8", xml_declaration=False)

    return output_path


# === 멀티 영상 지원 ===

from dataclasses import dataclass


@dataclass
class VideoSegments:
    """하나의 영상에 대한 전사 결과 + 메타데이터"""
    video_path: Path
    segments: List[TranscribedSegment]
    fps: float
    width: int
    height: int
    duration: float


def generate_fcpxml_multi(
    videos: List[VideoSegments],
    output_path: str | Path,
    *,
    project_name: str = "SilenceCut",
    font_size: int = 42,
    max_subtitle_chars: int = 20,
) -> Path:
    """여러 영상의 무음 제거 + 자막을 하나의 FCPXML 타임라인으로 생성."""
    output_path = Path(output_path)

    if not videos:
        raise ValueError("영상 목록이 비어 있습니다.")

    # 시퀀스 fps: 첫 영상 기준
    first = videos[0]
    seq_fps = first.fps if first.fps <= 60 else 30.0
    seq_fn, seq_fd, seq_fps_code = _get_frame_info(seq_fps)

    # 전체 타임라인 길이 계산
    total_dur = Fraction(0)
    for v in videos:
        for seg in v.segments:
            dur = _snap_to_frame(seg.seg_end - seg.seg_start, seq_fn, seq_fd)
            total_dur += dur

    # === Root ===
    fcpxml_el = Element("fcpxml", version="1.13")
    resources = SubElement(fcpxml_el, "resources")

    # 시퀀스 포맷
    seq_fmt_id = "r1"
    SubElement(resources, "format", {
        "id": seq_fmt_id,
        "name": _format_name(first.width, first.height, seq_fps_code),
        "frameDuration": f"{seq_fn}/{seq_fd}s",
        "width": str(first.width),
        "height": str(first.height),
        "colorSpace": "1-1-1 (Rec. 709)",
    })

    # 각 영상 에셋 등록
    asset_map = {}  # video_path -> asset_id
    fmt_counter = 10
    for vi, v in enumerate(videos):
        asset_id = f"r_asset{vi}"
        v_fn, v_fd, v_fps_code = _get_frame_info(v.fps)

        # 에셋 포맷 (시퀀스와 다르면 별도 정의)
        if abs(v.fps - seq_fps) > 0.05:
            fmt_id = f"r_fmt{fmt_counter}"
            fmt_counter += 1
            SubElement(resources, "format", {
                "id": fmt_id,
                "name": _format_name(v.width, v.height, v_fps_code),
                "frameDuration": f"{v_fn}/{v_fd}s",
                "width": str(v.width),
                "height": str(v.height),
                "colorSpace": "1-1-1 (Rec. 709)",
            })
        else:
            fmt_id = seq_fmt_id

        vp = Path(v.video_path).resolve()
        asset_el = SubElement(resources, "asset", {
            "id": asset_id,
            "name": vp.stem,
            "start": "0s",
            "duration": _rational_str(_snap_to_frame(v.duration, v_fn, v_fd)),
            "hasVideo": "1",
            "hasAudio": "1",
            "format": fmt_id,
        })
        SubElement(asset_el, "media-rep", {
            "kind": "original-media",
            "src": vp.as_uri(),
        })
        asset_map[str(vp)] = asset_id

    # 자막용 effect
    effect_id = "r_effect"
    SubElement(resources, "effect", {
        "id": effect_id,
        "name": "Basic Title",
        "uid": ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti",
    })

    # === Timeline ===
    library = SubElement(fcpxml_el, "library")
    event = SubElement(library, "event", name=project_name)
    project = SubElement(event, "project", name=project_name)

    sequence = SubElement(project, "sequence", {
        "format": seq_fmt_id,
        "duration": _rational_str(total_dur),
        "tcStart": "0s",
        "tcFormat": "NDF",
        "audioLayout": "stereo",
        "audioRate": "48k",
    })
    spine = SubElement(sequence, "spine")

    # === Clips ===
    timeline_offset = Fraction(0)
    ts_counter = 0

    for v in videos:
        vp = Path(v.video_path).resolve()
        asset_id = asset_map[str(vp)]

        for idx, seg in enumerate(v.segments):
            src_start = _snap_to_frame(seg.seg_start, seq_fn, seq_fd)
            src_end = _snap_to_frame(seg.seg_end, seq_fn, seq_fd)
            clip_dur = src_end - src_start

            if clip_dur <= 0:
                continue

            clip_el = SubElement(spine, "asset-clip", {
                "ref": asset_id,
                "offset": _rational_str(timeline_offset),
                "name": seg.text[:30] if seg.text else vp.stem,
                "start": _rational_str(src_start),
                "duration": _rational_str(clip_dur),
                "tcFormat": "NDF",
            })

            if seg.text and seg.words:
                chunks = _split_subtitle(seg.words, max_chars=max_subtitle_chars)

                for chunk in chunks:
                    ts_counter += 1
                    ts_id = f"ts{ts_counter}"

                    cs = _snap_to_frame(chunk["start"], seq_fn, seq_fd)
                    ce = _snap_to_frame(chunk["end"], seq_fn, seq_fd)
                    if cs < src_start:
                        cs = src_start
                    if ce > src_end:
                        ce = src_end
                    cd = ce - cs
                    if cd <= 0:
                        continue

                    title_el = SubElement(clip_el, "title", {
                        "ref": effect_id,
                        "lane": "1",
                        "offset": _rational_str(cs),
                        "name": chunk["text"][:50],
                        "start": "3600s",
                        "duration": _rational_str(cd),
                    })
                    text_el = SubElement(title_el, "text")
                    ts = SubElement(text_el, "text-style", ref=ts_id)
                    ts.text = chunk["text"]
                    ts_def = SubElement(title_el, "text-style-def", id=ts_id)
                    SubElement(ts_def, "text-style", {
                        "font": "Helvetica",
                        "fontSize": str(font_size),
                        "fontColor": "1 1 1 1",
                        "bold": "1",
                        "shadowColor": "0 0 0 0.75",
                        "shadowOffset": "3 315",
                        "alignment": "center",
                    })

                # Inline captions (iTT) for multi
                for chunk in chunks:
                    ts_counter += 1
                    cap_ts_id = f"cts{ts_counter}"
                    cs = _snap_to_frame(chunk["start"], seq_fn, seq_fd)
                    ce = _snap_to_frame(chunk["end"], seq_fn, seq_fd)
                    if cs < src_start: cs = src_start
                    if ce > src_end: ce = src_end
                    cd = ce - cs
                    if cd <= 0: continue
                    caption_el = SubElement(clip_el, "caption", {
                        "lane": "2",
                        "offset": _rational_str(cs),
                        "name": chunk["text"][:50],
                        "start": "3600s",
                        "duration": _rational_str(cd),
                        "role": "iTT?captionFormat=ITT.ko",
                    })
                    cap_text_el = SubElement(caption_el, "text", placement="bottom")
                    cap_ts = SubElement(cap_text_el, "text-style", ref=cap_ts_id)
                    cap_ts.text = chunk["text"]
                    cap_ts_def = SubElement(caption_el, "text-style-def", id=cap_ts_id)
                    SubElement(cap_ts_def, "text-style", {
                        "font": ".AppleSystemUIFont",
                        "fontSize": "13",
                        "fontFace": "Regular",
                        "fontColor": "1 1 1 1",
                        "backgroundColor": "0 0 0 1",
                    })

            elif seg.text:
                ts_counter += 1
                ts_id = f"ts{ts_counter}"
                title_el = SubElement(clip_el, "title", {
                    "ref": effect_id,
                    "lane": "1",
                    "offset": _rational_str(src_start),
                    "name": seg.text[:50],
                    "start": "3600s",
                    "duration": _rational_str(clip_dur),
                })
                text_el = SubElement(title_el, "text")
                ts = SubElement(text_el, "text-style", ref=ts_id)
                ts.text = seg.text
                ts_def = SubElement(title_el, "text-style-def", id=ts_id)
                SubElement(ts_def, "text-style", {
                    "font": "Helvetica",
                    "fontSize": str(font_size),
                    "fontColor": "1 1 1 1",
                    "bold": "1",
                    "shadowColor": "0 0 0 0.75",
                    "shadowOffset": "3 315",
                    "alignment": "center",
                })

                # Fallback caption for multi (no words)
                cap_ts_id = f"cts{ts_counter}"
                caption_el = SubElement(clip_el, "caption", {
                    "lane": "2",
                    "offset": _rational_str(src_start),
                    "name": seg.text[:50],
                    "start": "3600s",
                    "duration": _rational_str(clip_dur),
                    "role": "iTT?captionFormat=ITT.ko",
                })
                cap_text_el = SubElement(caption_el, "text", placement="bottom")
                cap_ts = SubElement(cap_text_el, "text-style", ref=cap_ts_id)
                cap_ts.text = seg.text
                cap_ts_def = SubElement(caption_el, "text-style-def", id=cap_ts_id)
                SubElement(cap_ts_def, "text-style", {
                    "font": ".AppleSystemUIFont",
                    "fontSize": "13",
                    "fontFace": "Regular",
                    "fontColor": "1 1 1 1",
                    "backgroundColor": "0 0 0 1",
                })

            timeline_offset += clip_dur

    # === Write ===
    tree = ElementTree(fcpxml_el)
    indent(tree, space="    ")
    with open(output_path, "wb") as f:
        f.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(b'<!DOCTYPE fcpxml>\n')
        tree.write(f, encoding="UTF-8", xml_declaration=False)

    return output_path
