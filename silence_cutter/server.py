"""stdin/stdout JSON-RPC 서버 — Swift PythonBridge와 통신.

프로토콜: 한 줄에 하나의 JSON 객체 (newline-delimited JSON-RPC 2.0).
요청:  {"id": 1, "method": "ping", "params": {}}
응답:  {"id": 1, "result": "pong"}
알림:  {"method": "progress", "params": {"phase": "vad", "percent": 50}}
"""

from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------

def _write(obj: dict) -> None:
    """JSON 한 줄을 stdout으로 전송하고 즉시 flush."""
    line = json.dumps(obj, ensure_ascii=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _respond(req_id: Any, result: Any) -> None:
    """성공 응답."""
    _write({"id": req_id, "result": result})


def _error(req_id: Any, code: int, message: str, data: Any = None) -> None:
    """에러 응답."""
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    _write({"id": req_id, "error": err})


def _notify(method: str, params: dict) -> None:
    """서버→클라이언트 알림 (id 없음)."""
    _write({"method": method, "params": params})


def _progress(phase: str, percent: int, detail: str = "") -> None:
    """진행률 알림 축약."""
    params: dict[str, Any] = {"phase": phase, "percent": percent}
    if detail:
        params["detail"] = detail
    _notify("progress", params)


# ---------------------------------------------------------------------------
# JSON-RPC 에러 코드
# ---------------------------------------------------------------------------

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


# ---------------------------------------------------------------------------
# 메서드 핸들러
# ---------------------------------------------------------------------------

def _split_words_into_segments(
    words: list,
    max_seconds: float,
) -> list:
    """단어 리스트를 max_seconds 이내의 세그먼트로 분할.

    반드시 단어의 end_time 경계에서만 자르므로 단어 중간이 잘리지 않는다.
    묵음 간격(단어 간 gap)이 큰 지점을 우선 분할점으로 선택한다.
    """
    from .transcribe import TranscribedSegment, WordTimestamp

    if not words:
        return []

    segments = []
    chunk_start_idx = 0

    while chunk_start_idx < len(words):
        chunk_start_time = words[chunk_start_idx].start

        # 현재 청크에 들어갈 수 있는 마지막 단어 인덱스 찾기
        chunk_end_idx = chunk_start_idx
        for j in range(chunk_start_idx, len(words)):
            if words[j].end - chunk_start_time <= max_seconds:
                chunk_end_idx = j
            else:
                break
        else:
            # 모든 남은 단어가 max_seconds 안에 들어감
            chunk_end_idx = len(words) - 1

        # 최소 1개 단어는 포함
        if chunk_end_idx < chunk_start_idx:
            chunk_end_idx = chunk_start_idx

        # 분할점 최적화: max_seconds 범위 내에서 가장 큰 gap(묵음)을 찾아 거기서 자르기
        if chunk_end_idx < len(words) - 1:
            best_split = chunk_end_idx
            best_gap = 0.0
            # 후반 60% 구간에서 가장 큰 gap 탐색 (너무 앞에서 자르지 않도록)
            search_from = chunk_start_idx + max(1, int((chunk_end_idx - chunk_start_idx) * 0.4))
            for j in range(search_from, chunk_end_idx + 1):
                if j + 1 < len(words):
                    gap = words[j + 1].start - words[j].end
                    if gap > best_gap:
                        best_gap = gap
                        best_split = j
            # gap이 0.1초 이상이면 해당 지점에서 분할
            if best_gap >= 0.1:
                chunk_end_idx = best_split

        chunk_words = words[chunk_start_idx:chunk_end_idx + 1]
        text = " ".join(w.text for w in chunk_words)
        segments.append(TranscribedSegment(
            seg_start=chunk_words[0].start,
            seg_end=chunk_words[-1].end,
            text=text,
            words=chunk_words,
        ))

        chunk_start_idx = chunk_end_idx + 1

    return segments


def handle_ping(params: dict) -> str:
    """연결 테스트."""
    return "pong"


def handle_echo(params: dict) -> Any:
    """params를 그대로 반환."""
    return params


def handle_vad_only(params: dict) -> dict:
    """VAD만 수행 — 음성 구간 반환.

    params:
        video_path: str
        threshold: float (optional, default 0.5)
        min_speech_ms: int (optional, default 250)
        min_silence_ms: int (optional, default 300)
        speech_pad_ms: int (optional, default 100)
    """
    video_path = params.get("video_path")
    if not video_path:
        raise ValueError("video_path is required")

    from .vad import extract_audio, detect_speech

    _progress("vad", 0, "오디오 추출 중")
    audio_path = extract_audio(video_path)

    _progress("vad", 30, "음성 구간 감지 중")
    segments = detect_speech(
        audio_path,
        threshold=params.get("threshold", 0.5),
        min_speech_ms=params.get("min_speech_ms", 250),
        min_silence_ms=params.get("min_silence_ms", 300),
        speech_pad_ms=params.get("speech_pad_ms", 100),
    )

    # 임시 오디오 정리
    try:
        audio_path.unlink()
    except OSError:
        pass

    _progress("vad", 100, f"{len(segments)}개 구간 감지 완료")
    return {
        "segments": [
            {"start": s.start, "end": s.end, "duration": s.duration}
            for s in segments
        ],
    }


def handle_analyze(params: dict) -> dict:
    """전체 파이프라인: VAD → ASR → 세그먼트 반환 (export 없이).

    params:
        video_path: str
        language: str (optional, default "Korean")
        asr_model: str (optional)
        aligner_model: str (optional)
        threshold: float (optional)
        min_speech_ms: int (optional)
        min_silence_ms: int (optional)
        speech_pad_ms: int (optional)
    """
    video_path = params.get("video_path")
    if not video_path:
        raise ValueError("video_path is required")

    import subprocess as _sp

    from .vad import extract_audio, detect_speech, split_long_speech_segments
    from .transcribe import Transcriber, TranscribedSegment, merge_orphan_josa

    # 1. probe
    _progress("analyze", 0, "영상 정보 분석 중")
    probe_result = _sp.run(
        [
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_format", "-show_streams",
            str(video_path),
        ],
        capture_output=True, text=True, check=True,
    )
    probe = json.loads(probe_result.stdout)

    # fps / resolution / duration 추출
    fps = 24.0
    width, height = 1920, 1080
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == "video":
            rfr = stream.get("r_frame_rate", "24/1")
            num, den = map(int, rfr.split("/"))
            if den > 0:
                fps = num / den
            width = int(stream.get("width", 1920))
            height = int(stream.get("height", 1080))
            rotation = 0
            for sd in stream.get("side_data_list", []):
                if "rotation" in sd:
                    rotation = abs(int(sd["rotation"]))
            if rotation in (90, 270):
                width, height = height, width
            break

    duration = float(probe.get("format", {}).get("duration", 0))

    # 2. audio extraction
    _progress("analyze", 5, "오디오 추출 중")
    audio_path = extract_audio(video_path)

    # 3. VAD
    _progress("analyze", 15, "음성 구간 감지 중 (Silero VAD)")
    speech_segments = detect_speech(
        audio_path,
        threshold=params.get("threshold", 0.5),
        min_speech_ms=params.get("min_speech_ms", 250),
        min_silence_ms=params.get("min_silence_ms", 300),
        speech_pad_ms=params.get("speech_pad_ms", 100),
    )

    if not speech_segments:
        try:
            audio_path.unlink()
        except OSError:
            pass
        _progress("analyze", 100, "음성 구간 없음")
        return {
            "segments": [],
            "video_info": {
                "fps": fps, "width": width, "height": height,
                "duration": duration,
            },
        }

    asr_max_seconds = params.get("max_segment_seconds", 15.0)

    # 4. ASR — 2-pass 방식
    #  Pass 1: VAD 구간을 ASR 최대 길이 단위로 대략 분할 → ASR+ForcedAligner
    #  Pass 2: 단어의 end_time 기준으로 max_seconds마다 정확히 분할
    #  → 절대 단어 중간에서 잘리지 않음
    _progress("analyze", 25, "음성 인식 시작")
    transcriber = Transcriber(
        asr_model=params.get("asr_model", "mlx-community/Qwen3-ASR-0.6B-8bit"),
        aligner_model=params.get("aligner_model", "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"),
        language=params.get("language", "Korean"),
        on_progress=lambda phase, pct, detail: _progress(phase, pct, detail),
    )

    # Pass 1: VAD 구간별 ASR — 긴 구간은 ASR용으로 대략 분할 (30초 단위)
    #   ForcedAligner가 30초까지 잘 동작하므로 넉넉하게 잡는다.
    asr_chunk_seconds = 30.0
    asr_chunks = split_long_speech_segments(
        audio_path, speech_segments,
        max_segment_seconds=asr_chunk_seconds,
    )

    all_words: list = []  # WordTimestamp (절대 시간)
    total = len(asr_chunks)
    for i, seg in enumerate(asr_chunks):
        pct = 25 + int(50 * (i / total))
        _progress("analyze", pct, f"전사 중 ({i + 1}/{total})")
        result = transcriber.transcribe_segment(audio_path, seg.start, seg.end)
        if result.words:
            all_words.extend(result.words)
        elif result.text:
            # Aligner 실패 시 세그먼트 전체를 하나의 단어로 취급
            from .transcribe import WordTimestamp as _WT
            all_words.append(_WT(text=result.text, start=result.seg_start, end=result.seg_end))

    if not all_words:
        try:
            audio_path.unlink()
        except OSError:
            pass
        _progress("analyze", 100, "인식된 텍스트 없음")
        return {
            "segments": [],
            "video_info": {
                "fps": fps, "width": width, "height": height,
                "duration": duration,
            },
        }

    # Pass 2: 단어 타임스탬프 기준으로 max_seconds마다 분할
    _progress("analyze", 80, "세그먼트 분할 중")
    results = _split_words_into_segments(all_words, asr_max_seconds)

    # 세그먼트 경계에서 분리된 조사를 이전 세그먼트로 병합
    results = merge_orphan_josa(results)

    try:
        audio_path.unlink()
    except OSError:
        pass

    _progress("analyze", 100, f"분석 완료: {len(results)}개 구간")

    return {
        "segments": [
            {
                "seg_start": s.seg_start,
                "seg_end": s.seg_end,
                "text": s.text,
                "words": [
                    {"text": w.text, "start": w.start, "end": w.end}
                    for w in s.words
                ],
            }
            for s in results
        ],
        "video_info": {
            "fps": fps, "width": width, "height": height,
            "duration": duration,
        },
    }


def handle_export_fcpxml(params: dict) -> dict:
    """세그먼트 데이터 → FCPXML 파일 생성.

    params:
        segments: list — analyze 결과의 segments 배열
        video_path: str
        output_path: str
        fps: float (optional)
        width: int (optional)
        height: int (optional)
        video_duration: float (optional)
        project_name: str (optional)
        font_size: int (optional)
        max_subtitle_chars: int (optional)
    """
    from .transcribe import TranscribedSegment, WordTimestamp
    from .fcpxml import generate_fcpxml

    raw_segments = params.get("segments", [])
    video_path = params.get("video_path")
    output_path = params.get("output_path")
    if not video_path or not output_path:
        raise ValueError("video_path and output_path are required")

    _progress("export_fcpxml", 0, "FCPXML 생성 중")

    segments = _deserialize_segments(raw_segments)

    result = generate_fcpxml(
        segments=segments,
        video_path=video_path,
        output_path=output_path,
        fps=params.get("fps", 23.976),
        width=params.get("width", 1920),
        height=params.get("height", 1080),
        video_duration=params.get("video_duration"),
        project_name=params.get("project_name", "SilenceCut"),
        font_size=params.get("font_size", 42),
        max_subtitle_chars=params.get("max_subtitle_chars", 20),
    )

    _progress("export_fcpxml", 100, "FCPXML 생성 완료")
    return {"output_path": str(result)}


def handle_export_srt(params: dict) -> dict:
    """세그먼트 데이터 → SRT 파일 생성.

    params:
        segments: list
        output_path: str
        max_subtitle_chars: int (optional)
    """
    from .srt import generate_srt

    raw_segments = params.get("segments", [])
    output_path = params.get("output_path")
    if not output_path:
        raise ValueError("output_path is required")

    _progress("export_srt", 0, "SRT 생성 중")
    segments = _deserialize_segments(raw_segments)

    result = generate_srt(
        segments=segments,
        output_path=output_path,
        max_subtitle_chars=params.get("max_subtitle_chars", 20),
    )

    _progress("export_srt", 100, "SRT 생성 완료")
    return {"output_path": str(result)}


def handle_export_itt(params: dict) -> dict:
    """세그먼트 데이터 → iTT 파일 생성.

    params:
        segments: list
        output_path: str
        language: str (optional, default "ko")
        max_subtitle_chars: int (optional)
    """
    from .itt import generate_itt

    raw_segments = params.get("segments", [])
    output_path = params.get("output_path")
    if not output_path:
        raise ValueError("output_path is required")

    _progress("export_itt", 0, "iTT 생성 중")
    segments = _deserialize_segments(raw_segments)

    result = generate_itt(
        segments=segments,
        output_path=output_path,
        language=params.get("language", "ko"),
        max_subtitle_chars=params.get("max_subtitle_chars", 20),
    )

    _progress("export_itt", 100, "iTT 생성 완료")
    return {"output_path": str(result)}


# ---------------------------------------------------------------------------
# 세그먼트 역직렬화 헬퍼
# ---------------------------------------------------------------------------

def _deserialize_segments(raw: list[dict]) -> list:
    """JSON 세그먼트 배열 → TranscribedSegment 리스트."""
    from .transcribe import TranscribedSegment, WordTimestamp

    segments = []
    for s in raw:
        words = [
            WordTimestamp(text=w["text"], start=w["start"], end=w["end"])
            for w in s.get("words", [])
        ]
        segments.append(TranscribedSegment(
            seg_start=s["seg_start"],
            seg_end=s["seg_end"],
            text=s.get("text", ""),
            words=words,
        ))
    return segments


def handle_resub(params: dict) -> dict:
    """편집된 FCPXML을 읽고, 각 클립을 다시 ASR → 세그먼트 반환.

    params:
        fcpxml_path: str — 편집된 FCPXML 경로
        language: str (optional, default "Korean")
        asr_model: str (optional)
        aligner_model: str (optional)
        max_segment_seconds: float (optional, default 8)

    returns:
        segments: list[{start, end, text, words: [{text, start, end}]}]
        video_info: {fps, width, height, duration}
    """
    import subprocess as _sp
    import xml.etree.ElementTree as ET
    from urllib.parse import unquote, urlparse

    from .vad import extract_audio
    from .transcribe import Transcriber, WordTimestamp, merge_orphan_josa

    fcpxml_path = params.get("fcpxml_path")
    if not fcpxml_path:
        raise ValueError("fcpxml_path is required")

    _progress("analyze", 0, "Reading FCPXML…")

    # 1. Parse FCPXML
    tree = ET.parse(str(fcpxml_path))
    root = tree.getroot()

    # Find source video
    video_path = None
    for media_rep in root.iter("media-rep"):
        src = media_rep.get("src", "")
        if src.startswith("file://"):
            parsed = urlparse(src)
            path_str = unquote(parsed.path)
            from pathlib import Path as _P
            p = _P(path_str)
            if p.exists():
                video_path = str(p)
                break

    if not video_path:
        raise FileNotFoundError("Cannot find source video in FCPXML")

    # Probe video info
    _progress("analyze", 5, "Probing video…")
    probe_result = _sp.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json",
         "-show_format", "-show_streams", str(video_path)],
        capture_output=True, text=True, check=True,
    )
    probe = json.loads(probe_result.stdout)
    fps = 24.0
    width, height = 1920, 1080
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == "video":
            rfr = stream.get("r_frame_rate", "24/1")
            num, den = map(int, rfr.split("/"))
            if den > 0:
                fps = num / den
            width = int(stream.get("width", 1920))
            height = int(stream.get("height", 1080))
            rotation = 0
            for sd in stream.get("side_data_list", []):
                if "rotation" in sd:
                    rotation = abs(int(sd["rotation"]))
            if rotation in (90, 270):
                width, height = height, width
            break
    duration = float(probe.get("format", {}).get("duration", 0))

    # 2. Extract audio
    _progress("analyze", 10, "Extracting audio…")
    audio_path = extract_audio(video_path)

    # 3. Parse spine → get clip source time ranges
    def _parse_time(s):
        if s is None:
            return 0.0
        s = s.strip().rstrip("s")
        if "/" in s:
            num, den = s.split("/")
            return int(num) / int(den)
        return float(s)

    spine = root.find(".//spine")
    if spine is None:
        raise ValueError("No spine found in FCPXML")

    clips = []
    for clip in spine.findall("asset-clip"):
        src_start = _parse_time(clip.get("start", "0s"))
        clip_dur = _parse_time(clip.get("duration", "0s"))
        src_end = src_start + clip_dur
        timeline_offset = _parse_time(clip.get("offset", "0s"))
        clips.append({
            "src_start": src_start,
            "src_end": src_end,
            "timeline_offset": timeline_offset,
            "duration": clip_dur,
        })

    if not clips:
        try:
            from pathlib import Path as _P
            _P(audio_path).unlink()
        except OSError:
            pass
        return {
            "segments": [],
            "video_info": {"fps": fps, "width": width, "height": height, "duration": duration},
        }

    _progress("analyze", 15, f"Found {len(clips)} clips")

    # 4. ASR each clip
    max_seg_sec = params.get("max_segment_seconds", 8.0)
    transcriber = Transcriber(
        asr_model=params.get("asr_model", "mlx-community/Qwen3-ASR-0.6B-8bit"),
        aligner_model=params.get("aligner_model", "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"),
        language=params.get("language", "Korean"),
        on_progress=lambda phase, pct, detail: _progress(phase, pct, detail),
    )

    all_words = []
    total = len(clips)
    for i, clip in enumerate(clips):
        pct = 20 + int(60 * (i / total))
        _progress("analyze", pct, f"Transcribing clip ({i + 1}/{total})")

        result = transcriber.transcribe_segment(audio_path, clip["src_start"], clip["src_end"])
        if result.words:
            all_words.extend(result.words)
        elif result.text:
            all_words.append(WordTimestamp(
                text=result.text, start=result.seg_start, end=result.seg_end,
            ))

    if not all_words:
        try:
            from pathlib import Path as _P
            _P(audio_path).unlink()
        except OSError:
            pass
        _progress("analyze", 100, "No speech detected")
        return {
            "segments": [],
            "video_info": {"fps": fps, "width": width, "height": height, "duration": duration},
        }

    # 5. Split words into segments (same as handle_analyze)
    _progress("analyze", 85, "Splitting into segments…")
    raw_segments = _split_words_into_segments(all_words, max_seg_sec)

    # Orphan josa merge (Korean)
    lang = params.get("language", "Korean")
    if lang.lower() in ("korean", "ko"):
        raw_segments = merge_orphan_josa(raw_segments)

    # 6. Build response
    _progress("analyze", 95, "Building response…")
    out_segments = []
    for seg in raw_segments:
        out_segments.append({
            "seg_start": seg.seg_start,
            "seg_end": seg.seg_end,
            "text": seg.text,
            "words": [
                {"text": w.text, "start": w.start, "end": w.end}
                for w in seg.words
            ],
        })

    try:
        from pathlib import Path as _P
        _P(audio_path).unlink()
    except OSError:
        pass

    _progress("analyze", 100, "Done")
    return {
        "segments": out_segments,
        "video_info": {"fps": fps, "width": width, "height": height, "duration": duration},
    }


# ---------------------------------------------------------------------------
# 메서드 라우터
# ---------------------------------------------------------------------------

METHOD_TABLE: dict[str, Any] = {
    "ping": handle_ping,
    "echo": handle_echo,
    "analyze": handle_analyze,
    "resub": handle_resub,
    "vad_only": handle_vad_only,
    "export_fcpxml": handle_export_fcpxml,
    "export_srt": handle_export_srt,
    "export_itt": handle_export_itt,
}


# ---------------------------------------------------------------------------
# 메인 루프
# ---------------------------------------------------------------------------

def serve() -> None:
    """stdin에서 JSON-RPC 요청을 읽고 stdout으로 응답. EOF까지 반복."""
    # stderr로 시작 로그 — stdout은 JSON-RPC 전용
    print("[server] silence_cutter JSON-RPC server started", file=sys.stderr)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        # 1. JSON 파싱
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            _error(None, PARSE_ERROR, f"JSON parse error: {e}")
            continue

        # 2. 기본 필드 검증
        if not isinstance(req, dict):
            _error(None, INVALID_REQUEST, "Request must be a JSON object")
            continue

        method = req.get("method")
        req_id = req.get("id")  # None이면 notification (응답 불필요)
        params = req.get("params", {})

        if not method or not isinstance(method, str):
            _error(req_id, INVALID_REQUEST, "Missing or invalid 'method' field")
            continue

        if not isinstance(params, dict):
            _error(req_id, INVALID_PARAMS, "'params' must be a JSON object")
            continue

        # 3. 메서드 디스패치
        handler = METHOD_TABLE.get(method)
        if handler is None:
            _error(req_id, METHOD_NOT_FOUND, f"Unknown method: {method}")
            continue

        try:
            result = handler(params)
        except Exception as exc:
            tb = traceback.format_exc()
            print(f"[server] error in {method}: {tb}", file=sys.stderr)
            if req_id is not None:
                _error(req_id, INTERNAL_ERROR, str(exc))
            continue

        # 4. 응답 전송 (notification이면 응답 없음)
        if req_id is not None:
            _respond(req_id, result)


if __name__ == "__main__":
    serve()
