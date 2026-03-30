"""iTT (iTunes Timed Text) 자막 파일 생성"""

from __future__ import annotations

from pathlib import Path
from typing import List
from xml.etree.ElementTree import Element, SubElement, ElementTree, indent

from .subtitles import build_subtitle_chunks
from .transcribe import TranscribedSegment


def _format_tc(seconds: float) -> str:
    """초 → HH:MM:SS.mmm 타임코드"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"


def generate_itt(
    segments: List[TranscribedSegment],
    output_path: str | Path,
    *,
    language: str = "ko",
    max_subtitle_chars: int = 20,
    font_family: str = "Helvetica",
    font_size: str = "100%",
) -> Path:
    """
    iTT (iTunes Timed Text / TTML) 자막 파일 생성.

    Args:
        segments: 전사된 음성 구간 리스트
        output_path: 출력 .itt 파일 경로
        language: 언어 코드 (ko, en, ja, zh 등)
        max_subtitle_chars: 자막 한 줄 최대 글자수
        font_family: 폰트
        font_size: 폰트 크기
    """
    output_path = Path(output_path)

    NSMAP_TT = "http://www.w3.org/ns/ttml"
    NSMAP_TTS = "http://www.w3.org/ns/ttml#styling"
    NSMAP_TTP = "http://www.w3.org/ns/ttml#parameter"
    NSMAP_ITTP = "http://www.w3.org/ns/ttml/profile/imsc1#parameter"

    tt = Element("tt", {
        "xmlns": NSMAP_TT,
        "xmlns:tts": NSMAP_TTS,
        "xmlns:ttp": NSMAP_TTP,
        "xmlns:ittp": NSMAP_ITTP,
        "xml:lang": language,
        "ttp:tickRate": "10000000",
    })

    # Head
    head = SubElement(tt, "head")

    styling = SubElement(head, "styling")
    SubElement(styling, "style", {
        "xml:id": "default",
        "tts:fontFamily": font_family,
        "tts:fontSize": font_size,
        "tts:color": "white",
        "tts:textAlign": "center",
    })

    layout = SubElement(head, "layout")
    SubElement(layout, "region", {
        "xml:id": "bottom",
        "tts:origin": "0% 80%",
        "tts:extent": "100% 20%",
        "tts:displayAlign": "after",
        "tts:writingMode": "lrtb",
    })

    # Body
    body = SubElement(tt, "body")
    div = SubElement(body, "div")

    all_chunks = build_subtitle_chunks(
        segments,
        max_subtitle_chars=max_subtitle_chars,
    )

    for chunk in all_chunks:
        if chunk["end"] <= chunk["start"]:
            continue
        p = SubElement(div, "p", {
            "begin": _format_tc(chunk["start"]),
            "end": _format_tc(chunk["end"]),
            "region": "bottom",
            "style": "default",
        })
        p.text = chunk["text"]

    # Write
    tree = ElementTree(tt)
    indent(tree, space="  ")

    with open(output_path, "wb") as f:
        f.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
        tree.write(f, encoding="UTF-8", xml_declaration=False)

    return output_path
