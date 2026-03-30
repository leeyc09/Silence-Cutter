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

    asr_segments = split_long_speech_segments(
        audio_path, speech_segments,
        max_segment_seconds=params.get("max_segment_seconds", 15.0),
    )

    # 4. ASR — 세그먼트에 overlap padding 적용 후 전사
    #    분할 경계에서 단어가 잘리지 않도록 인접 세그먼트와 0.5초 겹침.
    _progress("analyze", 25, "음성 인식 시작")
    transcriber = Transcriber(
        asr_model=params.get("asr_model", "mlx-community/Qwen3-ASR-0.6B-8bit"),
        aligner_model=params.get("aligner_model", "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"),
        language=params.get("language", "Korean"),
        on_progress=lambda phase, pct, detail: _progress(phase, pct, detail),
    )

    OVERLAP = 0.5  # 초 — 각 세그먼트 경계에 추가할 여유
    results = []
    total = len(asr_segments)
    for i, seg in enumerate(asr_segments):
        pct = 25 + int(70 * (i / total))
        _progress("analyze", pct, f"전사 중 ({i + 1}/{total})")

        # overlap 적용: 시작을 조금 앞으로, 끝을 조금 뒤로
        padded_start = max(0, seg.start - (OVERLAP if i > 0 else 0))
        padded_end = seg.end + (OVERLAP if i < total - 1 else 0)
        result = transcriber.transcribe_segment(audio_path, padded_start, padded_end)

        if result.text and result.words:
            # overlap 구간의 단어 제거: 원래 seg.start ~ seg.end 범위만 남김
            trimmed_words = [
                w for w in result.words
                if w.start >= seg.start - 0.05 and w.end <= seg.end + 0.05
            ]
            if trimmed_words:
                trimmed_text = " ".join(w.text for w in trimmed_words)
                results.append(TranscribedSegment(
                    seg_start=trimmed_words[0].start,
                    seg_end=trimmed_words[-1].end,
                    text=trimmed_text,
                    words=trimmed_words,
                ))
        elif result.text:
            results.append(result)

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


# ---------------------------------------------------------------------------
# 메서드 라우터
# ---------------------------------------------------------------------------

METHOD_TABLE: dict[str, Any] = {
    "ping": handle_ping,
    "echo": handle_echo,
    "analyze": handle_analyze,
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
