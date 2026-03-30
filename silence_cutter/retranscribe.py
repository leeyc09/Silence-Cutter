"""편집된 FCPXML을 읽어서 자막만 재생성"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from copy import deepcopy
from fractions import Fraction
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlparse

from .transcribe import Transcriber, TranscribedSegment
from .fcpxml import _snap_to_frame, _rational_str, _split_subtitle, _get_frame_info
from .itt import generate_itt
from .vad import extract_audio


def _parse_time(s: str) -> float:
    """FCPXML 시간 문자열 → 초 (float)"""
    if s is None:
        return 0.0
    s = s.strip()
    if s.endswith("s"):
        s = s[:-1]
    if "/" in s:
        num, den = s.split("/")
        return int(num) / int(den)
    return float(s)


def _find_source_video(tree: ET.ElementTree) -> Optional[Path]:
    """FCPXML에서 원본 영상 경로 추출"""
    for media_rep in tree.iter("media-rep"):
        src = media_rep.get("src", "")
        if src.startswith("file://"):
            parsed = urlparse(src)
            path = Path(unquote(parsed.path))
            if path.exists():
                return path
    return None


def retranscribe(
    fcpxml_path: str | Path,
    output_path: Optional[str | Path] = None,
    *,
    language: str = "Korean",
    asr_model: str = "mlx-community/Qwen3-ASR-1.7B-8bit",
    aligner_model: str = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
    font_size: int = 42,
    max_subtitle_chars: int = 20,
    export_itt: bool = False,
    language_code: str = "ko",
) -> Path:
    """
    편집된 FCPXML/FCPXMLD를 읽어서 자막을 재생성.

    기존 타이틀을 제거하고, 각 asset-clip의 시간 범위로 ASR을 다시 실행하여
    새 자막을 생성합니다.
    """
    fcpxml_path = Path(fcpxml_path)

    # .fcpxmld 번들이면 내부 Info.fcpxml 사용
    if fcpxml_path.is_dir():
        info_path = fcpxml_path / "Info.fcpxml"
        if not info_path.exists():
            raise FileNotFoundError(f"Info.fcpxml을 찾을 수 없습니다: {info_path}")
        xml_path = info_path
    else:
        xml_path = fcpxml_path

    if output_path is None:
        output_path = fcpxml_path.parent / (fcpxml_path.stem + "_subtitled.fcpxml")
    output_path = Path(output_path)

    # 1. FCPXML 파싱
    print(f"[retranscribe] FCPXML 읽기: {xml_path}")
    tree = ET.parse(str(xml_path))
    root = tree.getroot()

    # 2. 원본 영상 찾기
    video_path = _find_source_video(tree)
    if video_path is None:
        raise FileNotFoundError("FCPXML에서 원본 영상 경로를 찾을 수 없습니다.")
    print(f"[retranscribe] 원본 영상: {video_path}")

    # 3. 오디오 추출
    print("[retranscribe] 오디오 추출 중...")
    audio_path = extract_audio(video_path)

    # 4. spine에서 asset-clip 목록 추출 + 기존 title 제거
    spine = root.find(".//spine")
    if spine is None:
        raise ValueError("FCPXML에 spine이 없습니다.")

    # effect id 찾기 (기존 title의 ref)
    effect_id = None
    for effect in root.iter("effect"):
        if "Title" in (effect.get("name") or ""):
            effect_id = effect.get("id")
            break

    if effect_id is None:
        # effect가 없으면 추가
        resources = root.find(".//resources")
        effect_id = "r_title"
        ET.SubElement(resources, "effect", {
            "id": effect_id,
            "name": "Basic Title",
            "uid": ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti",
        })

    # 시퀀스 포맷 정보 가져오기
    sequence = root.find(".//sequence")
    seq_format_id = sequence.get("format")
    fmt_el = None
    for f in root.iter("format"):
        if f.get("id") == seq_format_id:
            fmt_el = f
            break

    if fmt_el is not None:
        fd_str = fmt_el.get("frameDuration", "1001/30000s")
        fd_val = _parse_time(fd_str)
        seq_fn = Fraction(fd_str.rstrip("s")).numerator
        seq_fd = Fraction(fd_str.rstrip("s")).denominator
    else:
        seq_fn, seq_fd = 1001, 30000

    # 5. ASR 준비
    transcriber = Transcriber(
        asr_model=asr_model,
        aligner_model=aligner_model,
        language=language,
    )

    # 6. 각 asset-clip 처리
    clips = list(spine.findall("asset-clip"))
    print(f"[retranscribe] 클립 {len(clips)}개 발견")

    ts_counter = 0
    all_transcribed_timeline = []  # iTT용 (타임라인 기준 시간)

    for clip_idx, clip in enumerate(clips):
        # 기존 title 제거
        for title in list(clip.findall("title")):
            clip.remove(title)

        # 클립 시간 정보
        timeline_offset = _parse_time(clip.get("offset", "0s"))
        src_start = _parse_time(clip.get("start", "0s"))
        clip_dur = _parse_time(clip.get("duration", "0s"))
        src_end = src_start + clip_dur

        print(f"[retranscribe] ({clip_idx + 1}/{len(clips)}) {src_start:.1f}s ~ {src_end:.1f}s")

        # ASR 실행
        result = transcriber.transcribe_segment(audio_path, src_start, src_end)

        if not result.text:
            continue

        # iTT용: 소스 시간 → 타임라인 시간으로 변환
        from .transcribe import WordTimestamp
        timeline_words = []
        for w in result.words:
            tl_start = timeline_offset + (w.start - src_start)
            tl_end = timeline_offset + (w.end - src_start)
            timeline_words.append(WordTimestamp(text=w.text, start=tl_start, end=tl_end))

        all_transcribed_timeline.append(TranscribedSegment(
            seg_start=timeline_offset,
            seg_end=timeline_offset + clip_dur,
            text=result.text,
            words=timeline_words,
        ))

        # 자막 분할 + title 생성
        if result.words:
            from .fcpxml import _split_subtitle
            chunks = _split_subtitle(result.words, max_chars=max_subtitle_chars)
        else:
            chunks = [{"text": result.text, "start": src_start, "end": src_end}]

        # 클립 경계 (소스 기준)
        clip_src_start = _snap_to_frame(src_start, seq_fn, seq_fd)
        clip_src_end = _snap_to_frame(src_end, seq_fn, seq_fd)

        for chunk in chunks:
            ts_counter += 1
            ts_id = f"rts{ts_counter}"

            chunk_start = _snap_to_frame(chunk["start"], seq_fn, seq_fd)
            chunk_end = _snap_to_frame(chunk["end"], seq_fn, seq_fd)

            # 클립 경계를 넘지 않도록 클램핑
            if chunk_start < clip_src_start:
                chunk_start = clip_src_start
            if chunk_end > clip_src_end:
                chunk_end = clip_src_end

            chunk_dur = chunk_end - chunk_start
            if chunk_dur <= 0:
                chunk_dur = Fraction(seq_fn, seq_fd)

            title_el = ET.SubElement(clip, "title", {
                "ref": effect_id,
                "lane": "1",
                "offset": _rational_str(chunk_start),
                "name": chunk["text"][:50],
                "start": "3600s",
                "duration": _rational_str(chunk_dur),
            })

            text_el = ET.SubElement(title_el, "text")
            ts = ET.SubElement(text_el, "text-style", ref=ts_id)
            ts.text = chunk["text"]

            ts_def = ET.SubElement(title_el, "text-style-def", id=ts_id)
            ET.SubElement(ts_def, "text-style", {
                "font": "Helvetica",
                "fontSize": str(font_size),
                "fontColor": "1 1 1 1",
                "bold": "1",
                "shadowColor": "0 0 0 0.75",
                "shadowOffset": "3 315",
                "alignment": "center",
            })

    # 7. 저장
    ET.indent(tree, space="    ")
    with open(output_path, "wb") as f:
        f.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
        f.write(b'<!DOCTYPE fcpxml>\n')
        tree.write(f, encoding="UTF-8", xml_declaration=False)

    print(f"[retranscribe] 완료! → {output_path}")

    # iTT 생성
    if export_itt and all_transcribed_timeline:
        itt_path = output_path.with_suffix(".itt")
        print("[retranscribe] iTT 자막 생성 중...")
        generate_itt(
            segments=all_transcribed_timeline,
            output_path=itt_path,
            language=language_code,
            max_subtitle_chars=max_subtitle_chars,
        )
        print(f"[retranscribe] iTT → {itt_path}")

    # 임시 오디오 정리
    try:
        audio_path.unlink()
    except OSError:
        pass

    return output_path
