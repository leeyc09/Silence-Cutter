"""Silence Cutter — Gradio Web UI

실행 방법:
    python -m silence_cutter.app
    또는
    gradio silence_cutter/app.py
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Generator

import gradio as gr

# ── 언어 매핑 ────────────────────────────────────────────────────────────────
LANGUAGE_MAP = {
    "한국어": "Korean",
    "영어": "English",
    "일본어": "Japanese",
    "중국어": "Chinese",
}

# 언어 코드 (iTT)
LANG_CODE_MAP = {
    "Korean": "ko",
    "English": "en",
    "Japanese": "ja",
    "Chinese": "zh",
}

# ── ASR 모델 ──────────────────────────────────────────────────────────────────
ASR_MODELS = {
    "Qwen3-ASR-1.7B-8bit (고품질)": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "Qwen3-ASR-0.6B-8bit (빠름)": "mlx-community/Qwen3-ASR-0.6B-8bit",
}

ALIGNER_MODEL = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"

# ── 패딩 프리셋 ───────────────────────────────────────────────────────────────
PADDING_PRESETS = {
    "타이트 (50ms)": 50,
    "보통 (100ms)": 100,
    "여유 (200ms)": 200,
}


# ── stdout 캡처 컨텍스트 ──────────────────────────────────────────────────────
@contextlib.contextmanager
def _capture_stdout() -> Generator[io.StringIO, None, None]:
    """파이프라인의 print() 출력을 캡처."""
    buf = io.StringIO()
    old_stdout = sys.stdout
    sys.stdout = buf
    try:
        yield buf
    finally:
        sys.stdout = old_stdout


def _single_file_path(file_value) -> Path:
    """Gradio File 입력값을 Path로 정규화."""
    if isinstance(file_value, Path):
        return file_value
    if isinstance(file_value, str):
        return Path(file_value)
    if isinstance(file_value, list) and file_value:
        return Path(file_value[0])
    raise TypeError(f"지원하지 않는 파일 입력 형식: {type(file_value)!r}")


def _format_elapsed(start_time: float) -> str:
    """경과 시간을 MM:SS 또는 HH:MM:SS로 포맷."""
    elapsed = int(time.monotonic() - start_time)
    hours, rem = divmod(elapsed, 3600)
    minutes, seconds = divmod(rem, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def _render_progress_status(
    *,
    start_time: float,
    phase: str,
    logs: list[str],
    progress_label: str | None = None,
) -> str:
    """진행 상태 요약 + 최근 로그 렌더링."""
    lines = [
        f"경과 시간: {_format_elapsed(start_time)}",
        f"현재 단계: {phase}",
    ]
    if progress_label:
        lines.append(f"구간 진행: {progress_label}")
    if logs:
        lines.append("")
        lines.append("최근 로그:")
        lines.extend(logs[-12:])
    return "\n".join(lines)


# ── 공통 파라미터 수집 헬퍼 ──────────────────────────────────────────────────
def _collect_params(
    language_kr: str,
    asr_model_label: str,
    padding_preset: str,
    vad_threshold: float,
    min_silence_ms: int,
    max_subtitle_chars: int,
    font_size: int,
    export_itt: bool,
    project_name: str,
) -> dict:
    return dict(
        language=LANGUAGE_MAP[language_kr],
        asr_model=ASR_MODELS[asr_model_label],
        aligner_model=ALIGNER_MODEL,
        speech_pad_ms=PADDING_PRESETS[padding_preset],
        vad_threshold=vad_threshold,
        min_speech_ms=250,
        min_silence_ms=int(min_silence_ms),
        font_size=int(font_size),
        max_subtitle_chars=int(max_subtitle_chars),
        export_itt=export_itt,
        project_name=project_name or "SilenceCut",
    )


# ─────────────────────────────────────────────────────────────────────────────
# Tab 1: 무음 컷 — 프리뷰 (VAD only)
# ─────────────────────────────────────────────────────────────────────────────
def preview_vad(
    video_file,
    vad_threshold: float,
    padding_preset: str,
    min_silence_ms: int,
    status_text: str,
) -> tuple[list[list], str]:
    """VAD만 실행하여 감지된 음성 구간 반환 (빠른 프리뷰)."""
    if video_file is None:
        return [], "오류: 영상 파일을 업로드해 주세요."

    from .vad import extract_audio, detect_speech

    status_lines: list[str] = []

    try:
        video_path = Path(video_file)
        status_lines.append(f"[VAD] 오디오 추출 중: {video_path.name}")
        audio_path = extract_audio(video_path)

        speech_pad_ms = PADDING_PRESETS[padding_preset]
        status_lines.append(
            f"[VAD] 음성 구간 감지 중 (threshold={vad_threshold}, "
            f"min_silence={min_silence_ms}ms, pad={speech_pad_ms}ms)..."
        )
        segments = detect_speech(
            audio_path,
            threshold=vad_threshold,
            min_speech_ms=250,
            min_silence_ms=int(min_silence_ms),
            speech_pad_ms=speech_pad_ms,
        )

        try:
            audio_path.unlink()
        except OSError:
            pass

        rows = [
            [f"{s.start:.3f}", f"{s.end:.3f}", f"{s.duration:.3f}"]
            for s in segments
        ]
        total_speech = sum(s.duration for s in segments)
        status_lines.append(
            f"[VAD] 완료: 음성 구간 {len(segments)}개 / "
            f"총 음성 {total_speech:.1f}초"
        )
        return rows, "\n".join(status_lines)

    except Exception as exc:
        return [], f"오류 발생:\n{exc}"


# ─────────────────────────────────────────────────────────────────────────────
# Tab 1: 무음 컷 — 전체 실행
# ─────────────────────────────────────────────────────────────────────────────
def run_silence_cut(
    video_files,
    language_kr: str,
    asr_model_label: str,
    padding_preset: str,
    vad_threshold: float,
    min_silence_ms: int,
    max_subtitle_chars: int,
    font_size: int,
    export_itt: bool,
    project_name: str,
) -> tuple[list[str] | None, str]:
    """전체 파이프라인 실행 → 생성된 FCPXML (+ iTT) 반환. 단일/멀티 영상 자동 처리."""
    if video_files is None or (isinstance(video_files, list) and len(video_files) == 0):
        yield None, "오류: 영상 파일을 업로드해 주세요."
        return

    from . import pipeline as _pipeline
    from .fcpxml import VideoSegments, generate_fcpxml, generate_fcpxml_multi
    from .itt import generate_itt
    from .transcribe import Transcriber, TranscribedSegment, WordTimestamp
    from .vad import detect_speech, extract_audio, split_long_speech_segments

    params = _collect_params(
        language_kr, asr_model_label, padding_preset,
        vad_threshold, min_silence_ms, max_subtitle_chars,
        font_size, export_itt, project_name,
    )

    tmp_dir = Path(tempfile.mkdtemp(prefix="silencecut_"))
    language = params["language"]
    asr_model = params["asr_model"]
    aligner_model = params["aligner_model"]
    speech_pad_ms = params["speech_pad_ms"]
    is_multi = isinstance(video_files, list) and len(video_files) > 1

    if isinstance(video_files, str):
        normalized_files = [video_files]
    elif not isinstance(video_files, list):
        normalized_files = [video_files]
    else:
        normalized_files = video_files

    start_time = time.monotonic()
    logs: list[str] = []
    phase = "준비 중"
    progress_label: str | None = None
    temp_audio_paths: list[Path] = []
    all_videos: list[VideoSegments] = []
    transcriber = Transcriber(
        asr_model=asr_model,
        aligner_model=aligner_model,
        language=language,
    )
    transcriber_loaded = False

    def log(message: str) -> None:
        logs.append(f"[{_format_elapsed(start_time)}] {message}")

    def emit(files: list[Path] | None = None):
        file_list = [str(f) for f in files] if files else None
        return (
            file_list,
            _render_progress_status(
                start_time=start_time,
                phase=phase,
                logs=logs,
                progress_label=progress_label,
            ),
        )

    def build_cut_timeline_segments(
        segments: list[TranscribedSegment],
        *,
        start_offset: float = 0.0,
    ) -> list[TranscribedSegment]:
        timeline_segments: list[TranscribedSegment] = []
        tl_offset = start_offset
        for seg in segments:
            seg_dur = seg.seg_end - seg.seg_start
            tl_words = [
                WordTimestamp(
                    text=w.text,
                    start=tl_offset + (w.start - seg.seg_start),
                    end=tl_offset + (w.end - seg.seg_start),
                )
                for w in seg.words
            ]
            timeline_segments.append(
                TranscribedSegment(
                    seg_start=tl_offset,
                    seg_end=tl_offset + seg_dur,
                    text=seg.text,
                    words=tl_words,
                )
            )
            tl_offset += seg_dur
        return timeline_segments

    try:
        phase = "입력 확인"
        log(f"입력 영상 {len(normalized_files)}개 확인")
        yield emit()

        total_files = len(normalized_files)
        for file_idx, raw_video in enumerate(normalized_files, 1):
            video_path = Path(raw_video).resolve()
            if not video_path.exists():
                log(f"파일 없음, 건너뜀: {video_path}")
                yield emit()
                continue

            phase = f"영상 분석 ({file_idx}/{total_files})"
            progress_label = None
            log(f"영상 분석 시작: {video_path.name}")
            yield emit()

            probe = _pipeline._probe_video(video_path)
            fps = _pipeline._get_fps(probe)
            duration = _pipeline._get_duration(probe)
            width, height = _pipeline._get_resolution(probe)
            log(f"영상 정보: {width}x{height} @ {fps:.3f}fps, 길이 {duration:.1f}s")
            yield emit()

            phase = f"오디오 추출 ({file_idx}/{total_files})"
            log("오디오 추출 시작")
            yield emit()
            audio_path = extract_audio(video_path)
            temp_audio_paths.append(audio_path)
            log(f"오디오 추출 완료: {audio_path.name}")
            yield emit()

            phase = f"VAD 분석 ({file_idx}/{total_files})"
            log("음성 구간 감지 시작")
            yield emit()
            speech_segments = detect_speech(
                audio_path,
                threshold=vad_threshold,
                min_speech_ms=250,
                min_silence_ms=int(min_silence_ms),
                speech_pad_ms=speech_pad_ms,
            )
            progress_label = f"파일 {file_idx}/{total_files} | 구간 0/{len(speech_segments)}"
            log(f"음성 구간 {len(speech_segments)}개 감지")
            if speech_segments:
                speech_total = sum(s.duration for s in speech_segments)
                silence_total = duration - speech_total
                remove_pct = (silence_total / duration * 100) if duration > 0 else 0
                log(
                    f"음성 {speech_total:.1f}s / 무음 {silence_total:.1f}s "
                    f"({remove_pct:.0f}% 제거)"
                )
            yield emit()

            if not speech_segments:
                progress_label = None
                log("음성 구간이 없어 이 파일은 건너뜁니다.")
                yield emit()
                continue

            if not transcriber_loaded:
                phase = "ASR 준비"
                progress_label = None
                log("ASR 모델 로딩 시작")
                yield emit()
                transcriber._ensure_loaded()
                transcriber_loaded = True
                log("ASR 모델 로딩 완료")
                yield emit()

            phase = f"대본 추출 ({file_idx}/{total_files})"
            transcribed: list[TranscribedSegment] = []
            total_segments = len(speech_segments)
            for seg_idx, seg in enumerate(speech_segments, 1):
                progress_label = f"파일 {file_idx}/{total_files} | 구간 {seg_idx - 1}/{total_segments}"
                log(f"구간 전사 시작 ({seg_idx}/{total_segments}) {seg.start:.1f}s ~ {seg.end:.1f}s")
                yield emit()

                result = transcriber.transcribe_segment(audio_path, seg.start, seg.end)
                if result.text:
                    transcribed.append(result)

                progress_label = f"파일 {file_idx}/{total_files} | 구간 {seg_idx}/{total_segments}"
                log(f"구간 전사 완료 ({seg_idx}/{total_segments})")
                yield emit()

            log(f"전사 완료: {len(transcribed)}개 구간")
            progress_label = None
            yield emit()

            all_videos.append(
                VideoSegments(
                    video_path=video_path,
                    segments=transcribed,
                    fps=fps,
                    width=width,
                    height=height,
                    duration=duration,
                )
            )

        if not all_videos:
            phase = "완료"
            progress_label = None
            log("처리 가능한 영상이 없습니다.")
            yield emit()
            return

        output_files: list[Path] = []
        if not is_multi and len(all_videos) == 1:
            video = all_videos[0]
            output_path = tmp_dir / f"{video.video_path.stem}.fcpxml"

            phase = "FCPXML 생성"
            log(f"FCPXML 생성 시작: {output_path.name}")
            yield emit()
            generate_fcpxml(
                segments=video.segments,
                video_path=video.video_path,
                output_path=output_path,
                fps=video.fps,
                width=video.width,
                height=video.height,
                video_duration=video.duration,
                project_name=params["project_name"],
                font_size=int(font_size),
                max_subtitle_chars=int(max_subtitle_chars),
            )
            output_files.append(output_path)
            log(f"FCPXML 생성 완료: {output_path.name}")
            yield emit()

            if export_itt:
                phase = "iTT 생성"
                itt_path = output_path.with_suffix(".itt")
                log(f"iTT 생성 시작: {itt_path.name}")
                yield emit()
                generate_itt(
                    segments=build_cut_timeline_segments(video.segments),
                    output_path=itt_path,
                    language=LANG_CODE_MAP[language],
                    max_subtitle_chars=int(max_subtitle_chars),
                )
                output_files.append(itt_path)
                log(f"iTT 생성 완료: {itt_path.name}")
                yield emit()
        else:
            output_path = tmp_dir / f"{params['project_name']}_multi.fcpxml"

            phase = "멀티 FCPXML 생성"
            log(f"멀티 FCPXML 생성 시작: {output_path.name}")
            yield emit()
            generate_fcpxml_multi(
                videos=all_videos,
                output_path=output_path,
                project_name=params["project_name"],
                font_size=int(font_size),
                max_subtitle_chars=int(max_subtitle_chars),
            )
            output_files.append(output_path)
            log(f"멀티 FCPXML 생성 완료: {output_path.name}")
            yield emit()

            if export_itt:
                phase = "멀티 iTT 생성"
                itt_path = output_path.with_suffix(".itt")
                log(f"iTT 생성 시작: {itt_path.name}")
                yield emit()
                timeline_segments: list[TranscribedSegment] = []
                timeline_offset = 0.0
                for video in all_videos:
                    built_segments = build_cut_timeline_segments(
                        video.segments,
                        start_offset=timeline_offset,
                    )
                    timeline_segments.extend(built_segments)
                    if built_segments:
                        timeline_offset = built_segments[-1].seg_end
                generate_itt(
                    segments=timeline_segments,
                    output_path=itt_path,
                    language=LANG_CODE_MAP[language],
                    max_subtitle_chars=int(max_subtitle_chars),
                )
                output_files.append(itt_path)
                log(f"iTT 생성 완료: {itt_path.name}")
                yield emit()

        phase = "완료"
        progress_label = None
        log("Final Cut Pro에서 File > Import > XML로 열 수 있습니다.")
        yield emit(output_files)
        return

    except Exception:
        import traceback
        yield None, f"오류 발생:\n{traceback.format_exc()}"
        return
    finally:
        for audio_path in temp_audio_paths:
            try:
                if audio_path.exists():
                    audio_path.unlink()
            except OSError:
                pass


# ─────────────────────────────────────────────────────────────────────────────
# Tab 2: 자막 재생성 (Resub)
# ─────────────────────────────────────────────────────────────────────────────
def run_resub(
    fcpxml_file,
    language_kr: str,
    asr_model_label: str,
    max_subtitle_chars: int,
    font_size: int,
    export_itt: bool,
) -> tuple[list[str] | None, str]:
    """FCPXML 자막 재생성."""
    if fcpxml_file is None:
        return None, "오류: FCPXML 파일을 업로드해 주세요."

    from .retranscribe import retranscribe

    language = LANGUAGE_MAP[language_kr]
    asr_model = ASR_MODELS[asr_model_label]
    lang_code = LANG_CODE_MAP[language]

    fcpxml_path = Path(fcpxml_file)
    tmp_dir = tempfile.mkdtemp(prefix="resub_")
    output_path = Path(tmp_dir) / (fcpxml_path.stem + "_subtitled.fcpxml")

    try:
        with _capture_stdout() as buf:
            result_path = retranscribe(
                fcpxml_path=fcpxml_path,
                output_path=output_path,
                language=language,
                asr_model=asr_model,
                aligner_model=ALIGNER_MODEL,
                font_size=int(font_size),
                max_subtitle_chars=int(max_subtitle_chars),
                export_itt=export_itt,
                language_code=lang_code,
            )

        log = buf.getvalue()
        output_files = [str(result_path)]

        if export_itt:
            itt_path = result_path.with_suffix(".itt")
            if itt_path.exists():
                output_files.append(str(itt_path))

        status = log if log else f"완료! → {result_path.name}"
        return output_files, status

    except Exception as exc:
        import traceback
        return None, f"오류 발생:\n{traceback.format_exc()}"


# ─────────────────────────────────────────────────────────────────────────────
# Tab 3: 멀티 영상
# ─────────────────────────────────────────────────────────────────────────────
def run_multi(
    video_files: list,
    language_kr: str,
    asr_model_label: str,
    padding_preset: str,
    vad_threshold: float,
    min_silence_ms: int,
    max_subtitle_chars: int,
    font_size: int,
    export_itt: bool,
    project_name: str,
) -> tuple[list[str] | None, str]:
    """여러 영상 → 단일 FCPXML 타임라인."""
    if not video_files:
        return None, "오류: 영상 파일을 하나 이상 업로드해 주세요."

    from .pipeline import run_multi as _run_multi

    params = _collect_params(
        language_kr, asr_model_label, padding_preset,
        vad_threshold, min_silence_ms, max_subtitle_chars,
        font_size, export_itt, project_name,
    )

    tmp_dir = tempfile.mkdtemp(prefix="silencecut_multi_")
    output_path = Path(tmp_dir) / f"{params['project_name']}_multi.fcpxml"

    video_paths = [Path(f) for f in video_files]

    try:
        with _capture_stdout() as buf:
            result_path = _run_multi(
                video_paths=video_paths,
                output_path=output_path,
                **params,
            )

        log = buf.getvalue()
        output_files = [str(result_path)]

        if export_itt:
            itt_path = result_path.with_suffix(".itt")
            if itt_path.exists():
                output_files.append(str(itt_path))

        status = log if log else f"완료! → {result_path.name}"
        return output_files, status

    except Exception as exc:
        import traceback
        return None, f"오류 발생:\n{traceback.format_exc()}"


# ─────────────────────────────────────────────────────────────────────────────
# Tab: 자막 생성 (무음 컷 없이 자막만)
# ─────────────────────────────────────────────────────────────────────────────
def run_subtitle_only(
    video_file,
    language_kr: str,
    asr_model_label: str,
    padding_preset: str,
    vad_threshold: float,
    min_silence_ms: int,
    max_subtitle_chars: int,
    export_srt: bool,
    export_itt: bool,
) -> tuple[list[str] | None, str]:
    """영상에서 자막만 생성 (SRT / iTT)."""
    if video_file is None:
        yield None, "오류: 영상 파일을 업로드해 주세요."
        return

    from .itt import generate_itt
    from .srt import generate_srt
    from .transcribe import Transcriber, TranscribedSegment
    from .vad import detect_speech, extract_audio

    language = LANGUAGE_MAP[language_kr]
    asr_model = ASR_MODELS[asr_model_label]
    speech_pad_ms = PADDING_PRESETS[padding_preset]

    video_path = _single_file_path(video_file)
    tmp_dir = Path(tempfile.mkdtemp(prefix="subtitle_"))
    audio_path: Path | None = None
    output_files: list[Path] = []

    start_time = time.monotonic()
    logs: list[str] = []
    phase = "준비 중"
    progress_label: str | None = None

    def log(message: str) -> None:
        logs.append(f"[{_format_elapsed(start_time)}] {message}")

    def emit(files: list[Path] | None = None):
        file_list = [str(f) for f in files] if files else None
        return (
            file_list,
            _render_progress_status(
                start_time=start_time,
                phase=phase,
                logs=logs,
                progress_label=progress_label,
            ),
        )

    try:
        phase = "입력 확인"
        log(f"영상 확인: {video_path.name}")
        yield emit()

        phase = "오디오 추출"
        log("오디오 추출 시작")
        yield emit()
        audio_path = extract_audio(video_path)
        log(f"오디오 추출 완료: {audio_path.name}")
        yield emit()

        phase = "VAD 분석"
        log("음성 구간 감지 시작")
        yield emit()
        speech_segments = detect_speech(
            audio_path,
            threshold=vad_threshold,
            min_speech_ms=250,
            min_silence_ms=int(min_silence_ms),
            speech_pad_ms=speech_pad_ms,
        )
        log(f"음성 구간 {len(speech_segments)}개 감지")

        asr_segments = split_long_speech_segments(audio_path, speech_segments)
        if len(asr_segments) != len(speech_segments):
            log(
                "긴 음성 구간 자동 분할: "
                f"VAD {len(speech_segments)}개 → 전사용 {len(asr_segments)}개"
            )
        progress_label = f"0/{len(asr_segments)}" if asr_segments else None
        yield emit()

        if not asr_segments:
            phase = "완료"
            progress_label = None
            log("음성 구간이 없어 자막 파일을 생성하지 않았습니다.")
            yield emit()
            return

        phase = "ASR 준비"
        progress_label = None
        log("ASR 모델 로딩 시작")
        yield emit()
        transcriber = Transcriber(
            asr_model=asr_model,
            aligner_model=ALIGNER_MODEL,
            language=language,
        )
        transcriber._ensure_loaded()
        log("ASR 모델 로딩 완료")
        yield emit()

        phase = "자막 추출"
        transcribed: list[TranscribedSegment] = []
        total_segments = len(asr_segments)
        for idx, seg in enumerate(asr_segments, 1):
            progress_label = f"{idx - 1}/{total_segments}"
            log(f"구간 전사 시작 ({idx}/{total_segments}) {seg.start:.1f}s ~ {seg.end:.1f}s")
            yield emit()

            result = transcriber.transcribe_segment(audio_path, seg.start, seg.end)
            if result.text:
                transcribed.append(result)

            progress_label = f"{idx}/{total_segments}"
            log(f"구간 전사 완료 ({idx}/{total_segments})")
            yield emit()

        progress_label = None
        log(f"전사 완료: {len(transcribed)}개 구간")
        yield emit()

        stem = video_path.stem
        if export_srt:
            phase = "SRT 저장"
            srt_path = tmp_dir / f"{stem}.srt"
            log(f"SRT 저장 시작: {srt_path.name}")
            yield emit()
            generate_srt(
                segments=transcribed,
                output_path=srt_path,
                max_subtitle_chars=int(max_subtitle_chars),
            )
            output_files.append(srt_path)
            log(f"SRT 저장 완료: {srt_path.name}")
            yield emit()

        if export_itt:
            phase = "iTT 저장"
            itt_path = tmp_dir / f"{stem}.itt"
            log(f"iTT 저장 시작: {itt_path.name}")
            yield emit()
            generate_itt(
                segments=transcribed,
                output_path=itt_path,
                language=LANG_CODE_MAP[language],
                max_subtitle_chars=int(max_subtitle_chars),
            )
            output_files.append(itt_path)
            log(f"iTT 저장 완료: {itt_path.name}")
            yield emit()

        phase = "완료"
        log(f"자막 파일 {len(output_files)}개 생성 완료")
        yield emit(output_files)
        return

    except Exception:
        import traceback
        yield None, f"오류 발생:\n{traceback.format_exc()}"
        return
    finally:
        if audio_path is not None:
            try:
                audio_path.unlink()
            except OSError:
                pass


# ─────────────────────────────────────────────────────────────────────────────
# Tab: 대본 추출 (영상 -> VAD -> ASR -> 텍스트)
# ─────────────────────────────────────────────────────────────────────────────
def run_script_extract(
    video_file,
    language_kr: str,
    asr_model_label: str,
    vad_threshold: float,
    min_silence_ms: int,
    max_subtitle_chars: int,
    with_timestamps: bool,
    export_itt: bool,
) -> tuple[list[str] | None, str, str]:
    """영상에서 대본 txt와 선택적 iTT 자막을 추출."""
    if video_file is None:
        yield None, "", "오류: 영상 파일을 업로드해 주세요."
        return

    from .itt import generate_itt
    from .subtitles import build_subtitle_chunks
    from .transcribe import Transcriber
    from .vad import detect_speech, extract_audio, split_long_speech_segments

    video_path = _single_file_path(video_file)
    language = LANGUAGE_MAP[language_kr]
    asr_model = ASR_MODELS[asr_model_label]

    tmp_dir = Path(tempfile.mkdtemp(prefix="script_"))
    output_path = tmp_dir / f"{video_path.stem}_script.txt"
    audio_path: Path | None = None
    start_time = time.monotonic()
    logs: list[str] = []
    transcript_lines: list[str] = []
    transcribed_segments = []
    phase = "준비 중"
    progress_label: str | None = None

    def log(message: str) -> None:
        logs.append(f"[{_format_elapsed(start_time)}] {message}")

    def emit(files: list[Path] | None = None):
        file_list = [str(f) for f in files] if files else None
        return (
            file_list,
            "\n".join(transcript_lines),
            _render_progress_status(
                start_time=start_time,
                phase=phase,
                logs=logs,
                progress_label=progress_label,
            ),
        )

    try:
        phase = "입력 확인"
        log(f"영상 확인: {video_path.name}")
        yield emit()

        phase = "오디오 추출"
        log("오디오 추출 시작")
        yield emit()
        audio_path = extract_audio(video_path)
        log(f"오디오 추출 완료: {audio_path.name}")
        yield emit()

        phase = "VAD 분석"
        log("음성 구간 감지 시작")
        yield emit()
        segments = detect_speech(
            audio_path,
            threshold=vad_threshold,
            min_speech_ms=250,
            min_silence_ms=int(min_silence_ms),
            speech_pad_ms=100,
        )
        log(f"음성 구간 {len(segments)}개 감지")

        asr_segments = split_long_speech_segments(audio_path, segments)
        if len(asr_segments) != len(segments):
            log(
                "긴 음성 구간 자동 분할: "
                f"VAD {len(segments)}개 → 전사용 {len(asr_segments)}개"
            )
        progress_label = f"0/{len(asr_segments)}" if asr_segments else None
        yield emit()

        if asr_segments:
            phase = "ASR 준비"
            log("ASR 모델 로딩 시작")
            yield emit()
            transcriber = Transcriber(
                asr_model=asr_model,
                aligner_model=ALIGNER_MODEL,
                language=language,
            )
            transcriber._ensure_loaded()
            log("ASR 모델 로딩 완료")
            yield emit()

            phase = "대본 추출"
            total = len(asr_segments)
            for idx, seg in enumerate(asr_segments, 1):
                progress_label = f"{idx - 1}/{total}"
                log(f"구간 전사 시작 ({idx}/{total}) {seg.start:.1f}s ~ {seg.end:.1f}s")
                yield emit()

                result = transcriber.transcribe_segment(audio_path, seg.start, seg.end)
                if result.text:
                    transcribed_segments.append(result)
                    chunks = build_subtitle_chunks(
                        [result],
                        max_subtitle_chars=int(max_subtitle_chars),
                    )
                    if not chunks:
                        chunks = [{
                            "text": result.text,
                            "start": result.seg_start,
                            "end": result.seg_end,
                        }]

                    for chunk in chunks:
                        if with_timestamps:
                            m1, s1 = divmod(chunk["start"], 60)
                            m2, s2 = divmod(chunk["end"], 60)
                            transcript_lines.append(
                                f"[{int(m1):02d}:{s1:04.1f} ~ {int(m2):02d}:{s2:04.1f}] {chunk['text']}"
                            )
                        else:
                            transcript_lines.append(chunk["text"])

                progress_label = f"{idx}/{total}"
                log(f"구간 전사 완료 ({idx}/{total})")
                yield emit()
        else:
            log("음성이 없어 빈 대본으로 저장합니다.")
            yield emit()

        phase = "파일 저장"
        log(f"txt 저장 중: {output_path.name}")
        yield emit()
        output_path.write_text("\n".join(transcript_lines), encoding="utf-8")
        output_files = [output_path]
        log(f"txt 저장 완료: {output_path.name}")
        yield emit(output_files)

        if export_itt:
            phase = "iTT 저장"
            itt_path = tmp_dir / f"{video_path.stem}.itt"
            log(f"iTT 저장 중: {itt_path.name}")
            yield emit(output_files)
            generate_itt(
                segments=transcribed_segments,
                output_path=itt_path,
                language=LANG_CODE_MAP[language],
                max_subtitle_chars=int(max_subtitle_chars),
            )
            output_files.append(itt_path)
            log(f"iTT 저장 완료: {itt_path.name}")
            yield emit(output_files)

        phase = "완료"
        progress_label = None
        log(f"파일 {len(output_files)}개 생성 완료")
        yield emit(output_files)
        return

    except Exception:
        import traceback
        yield None, "\n".join(transcript_lines), f"오류 발생:\n{traceback.format_exc()}"
        return
    finally:
        if audio_path is not None:
            try:
                audio_path.unlink()
            except OSError:
                pass


# ─────────────────────────────────────────────────────────────────────────────
# Tab: FCPXML 텍스트 추출
# ─────────────────────────────────────────────────────────────────────────────
def run_fcpxml_extract(
    fcpxml_file,
    with_timestamps: bool,
) -> tuple[str | None, str, str]:
    """FCPXML에서 자막/스크립트 텍스트 추출."""
    if fcpxml_file is None:
        return None, "", "오류: FCPXML 파일을 업로드해 주세요."

    from .extract import extract_script

    fcpxml_path = _single_file_path(fcpxml_file)
    tmp_dir = Path(tempfile.mkdtemp(prefix="extract_"))
    output_path = tmp_dir / f"{fcpxml_path.stem}_extract.txt"

    try:
        result = extract_script(
            fcpxml_path=fcpxml_path,
            output_path=output_path,
            with_timestamps=with_timestamps,
        )
        status = f"[extract] 저장 완료: {output_path.name}"
        return str(output_path), result, status

    except Exception:
        import traceback
        return None, "", f"오류 발생:\n{traceback.format_exc()}"


# ─────────────────────────────────────────────────────────────────────────────
# 공통 파라미터 위젯 팩토리
# ─────────────────────────────────────────────────────────────────────────────
def _make_common_params(include_vad: bool = True):
    """언어/모델/자막 파라미터 위젯 반환 (딕셔너리)."""
    language = gr.Dropdown(
        choices=list(LANGUAGE_MAP.keys()),
        value="한국어",
        label="언어",
    )
    asr_model = gr.Dropdown(
        choices=list(ASR_MODELS.keys()),
        value=list(ASR_MODELS.keys())[0],
        label="ASR 모델",
    )

    vad_widgets = {}
    if include_vad:
        padding = gr.Radio(
            choices=list(PADDING_PRESETS.keys()),
            value="보통 (100ms)",
            label="패딩 프리셋",
        )
        vad_threshold = gr.Slider(
            minimum=0.1, maximum=0.9, value=0.5, step=0.05,
            label="VAD 임계값 (낮을수록 민감)",
        )
        min_silence = gr.Slider(
            minimum=100, maximum=1000, value=300, step=50,
            label="최소 무음 길이 (ms) — 이보다 짧은 무음은 유지",
        )
        vad_widgets = {
            "padding": padding,
            "vad_threshold": vad_threshold,
            "min_silence": min_silence,
        }

    max_chars = gr.Slider(
        minimum=10, maximum=40, value=20, step=1,
        label="자막 최대 글자 수",
    )
    font_size = gr.Slider(
        minimum=20, maximum=80, value=42, step=2,
        label="자막 폰트 크기",
    )
    export_itt = gr.Checkbox(value=False, label="iTT 자막 파일 내보내기")
    project_name = gr.Textbox(
        value="SilenceCut",
        label="프로젝트 이름",
        placeholder="FCP 프로젝트 이름",
    )

    return {
        "language": language,
        "asr_model": asr_model,
        **vad_widgets,
        "max_chars": max_chars,
        "font_size": font_size,
        "export_itt": export_itt,
        "project_name": project_name,
    }


# ─────────────────────────────────────────────────────────────────────────────
# UI 레이아웃
# ─────────────────────────────────────────────────────────────────────────────
def build_ui() -> gr.Blocks:
    with gr.Blocks(title="Silence Cutter") as demo:

        gr.Markdown(
            """
# Silence Cutter
**Final Cut Pro용 무음 자동 편집 도구** — Silero VAD + Qwen3-ASR 기반

영상에서 무음 구간을 감지·제거하고, 자막이 포함된 FCPXML을 생성합니다.

- `무음 컷`: VAD 기반 무음 제거 + FCPXML 생성
- `VAD 자막 생성`: VAD로 음성 구간을 찾은 뒤 원본 타임라인 기준 자막만 생성
- `자막 재생성`: 편집된 FCPXML 기준으로 자막 다시 만들기
- `VAD 대본 추출`: 영상에서 대본 txt만 추출
- `FCPXML 자막 추출`: FCPXML 안의 title 텍스트를 txt로 추출
            """.strip()
        )

        # ── Tab 1: 무음 컷 ────────────────────────────────────────────────
        with gr.Tab("무음 컷"):
            with gr.Row():
                with gr.Column(scale=1):
                    t1_video = gr.File(
                        label="영상 파일 업로드 (여러 개 가능)",
                        file_types=[".mp4", ".mov", ".mkv", ".avi", ".m4v"],
                        file_count="multiple",
                    )

                    gr.Markdown("### 파라미터")
                    w = _make_common_params(include_vad=True)
                    t1_language = w["language"]
                    t1_asr_model = w["asr_model"]
                    t1_padding = w["padding"]
                    t1_vad_threshold = w["vad_threshold"]
                    t1_min_silence = w["min_silence"]
                    t1_max_chars = w["max_chars"]
                    t1_font_size = w["font_size"]
                    t1_export_itt = w["export_itt"]
                    t1_project_name = w["project_name"]

                    with gr.Row():
                        t1_preview_btn = gr.Button("프리뷰 (VAD만)", variant="secondary")
                        t1_run_btn = gr.Button("실행", variant="primary")

                with gr.Column(scale=1):
                    gr.Markdown("### 프리뷰: 감지된 음성 구간")
                    t1_preview_df = gr.Dataframe(
                        headers=["시작 (초)", "끝 (초)", "길이 (초)"],
                        datatype=["str", "str", "str"],
                        label="음성 구간 목록",
                        interactive=False,
                        wrap=False,
                    )

                    gr.Markdown("### 출력 파일")
                    t1_output_files = gr.File(
                        label="다운로드",
                        file_count="multiple",
                        interactive=False,
                    )
                    t1_status = gr.Textbox(
                        label="진행 상황",
                        lines=16,
                        interactive=False,
                        elem_classes=["status-box"],
                    )

            # 프리뷰 버튼
            t1_preview_btn.click(
                fn=preview_vad,
                inputs=[
                    t1_video,
                    t1_vad_threshold,
                    t1_padding,
                    t1_min_silence,
                    t1_status,
                ],
                outputs=[t1_preview_df, t1_status],
            )

            # 실행 버튼
            t1_run_btn.click(
                fn=run_silence_cut,
                inputs=[
                    t1_video,
                    t1_language,
                    t1_asr_model,
                    t1_padding,
                    t1_vad_threshold,
                    t1_min_silence,
                    t1_max_chars,
                    t1_font_size,
                    t1_export_itt,
                    t1_project_name,
                ],
                outputs=[t1_output_files, t1_status],
            )

        # ── Tab 2: VAD 자막 생성 ─────────────────────────────────────────
        with gr.Tab("VAD 자막 생성"):
            with gr.Row():
                with gr.Column(scale=1):
                    ts_video = gr.File(
                        label="영상 파일 업로드",
                        file_types=[".mp4", ".mov", ".mkv", ".avi", ".m4v"],
                        file_count="single",
                    )
                    gr.Markdown(
                        "_VAD로 음성 구간을 먼저 감지한 뒤, 원본 영상 타임라인 기준으로 "
                        "SRT/iTT 자막만 생성합니다. 무음 컷 FCPXML은 만들지 않습니다._"
                    )

                    gr.Markdown("### 파라미터")
                    ws = _make_common_params(include_vad=True)
                    ts_language = ws["language"]
                    ts_asr_model = ws["asr_model"]
                    ts_padding = ws["padding"]
                    ts_vad_threshold = ws["vad_threshold"]
                    ts_min_silence = ws["min_silence"]
                    ts_max_chars = ws["max_chars"]

                    ts_export_srt = gr.Checkbox(value=True, label="SRT 내보내기")
                    ts_export_itt = gr.Checkbox(value=True, label="iTT 내보내기")

                    ts_run_btn = gr.Button("실행", variant="primary")

                with gr.Column(scale=1):
                    gr.Markdown("### 출력 파일")
                    ts_output_files = gr.File(
                        label="다운로드",
                        file_count="multiple",
                        interactive=False,
                    )
                    ts_status = gr.Textbox(
                        label="진행 상황",
                        lines=16,
                        interactive=False,
                        elem_classes=["status-box"],
                    )

            ts_run_btn.click(
                fn=run_subtitle_only,
                inputs=[
                    ts_video,
                    ts_language,
                    ts_asr_model,
                    ts_padding,
                    ts_vad_threshold,
                    ts_min_silence,
                    ts_max_chars,
                    ts_export_srt,
                    ts_export_itt,
                ],
                outputs=[ts_output_files, ts_status],
            )

        # ── Tab 3: 자막 재생성 ────────────────────────────────────────────
        with gr.Tab("자막 재생성"):
            with gr.Row():
                with gr.Column(scale=1):
                    t2_file = gr.File(
                        label="FCPXML 파일 업로드 (.fcpxml 또는 .fcpxmld 내부 Info.fcpxml)",
                        file_types=[".fcpxml", ".xml"],
                        file_count="single",
                    )
                    gr.Markdown(
                        "_※ `.fcpxmld` 번들의 경우 번들 내부 `Info.fcpxml` 파일을 직접 선택하세요._"
                    )

                    gr.Markdown("### 파라미터")
                    w2 = _make_common_params(include_vad=False)
                    t2_language = w2["language"]
                    t2_asr_model = w2["asr_model"]
                    t2_max_chars = w2["max_chars"]
                    t2_font_size = w2["font_size"]
                    t2_export_itt = w2["export_itt"]

                    t2_run_btn = gr.Button("실행", variant="primary")

                with gr.Column(scale=1):
                    gr.Markdown("### 출력 파일")
                    t2_output_files = gr.File(
                        label="다운로드",
                        file_count="multiple",
                        interactive=False,
                    )
                    t2_status = gr.Textbox(
                        label="진행 상황",
                        lines=12,
                        interactive=False,
                        elem_classes=["status-box"],
                    )

            t2_run_btn.click(
                fn=run_resub,
                inputs=[
                    t2_file,
                    t2_language,
                    t2_asr_model,
                    t2_max_chars,
                    t2_font_size,
                    t2_export_itt,
                ],
                outputs=[t2_output_files, t2_status],
            )

        # ── Tab 4: VAD 대본 추출 ─────────────────────────────────────────
        with gr.Tab("VAD 대본 추출"):
            with gr.Row():
                with gr.Column(scale=1):
                    sc_video = gr.File(
                        label="영상 파일 업로드",
                        file_types=[".mp4", ".mov", ".mkv", ".avi", ".m4v"],
                        file_count="single",
                    )
                    gr.Markdown(
                        "_영상에서 오디오를 추출한 뒤 VAD로 음성 구간만 골라 ASR을 수행하고, "
                        "원본 시간축 기준의 자막 라인 txt를 생성합니다. "
                        "필요하면 Final Cut Pro용 iTT 자막도 함께 만들 수 있습니다. "
                        "무음 구간은 전사 구간 분할에만 사용하고 타임코드는 자르지 않습니다._"
                    )

                    sc_language = gr.Dropdown(
                        choices=list(LANGUAGE_MAP.keys()),
                        value="한국어",
                        label="언어",
                    )
                    sc_asr_model = gr.Dropdown(
                        choices=list(ASR_MODELS.keys()),
                        value=list(ASR_MODELS.keys())[0],
                        label="ASR 모델",
                    )
                    sc_vad_threshold = gr.Slider(
                        minimum=0.1, maximum=0.9, value=0.5, step=0.05,
                        label="VAD 임계값 (낮을수록 민감)",
                    )
                    sc_min_silence = gr.Slider(
                        minimum=100, maximum=1000, value=300, step=50,
                        label="최소 무음 길이 (ms)",
                    )
                    sc_max_subtitle_chars = gr.Slider(
                        minimum=8, maximum=40, value=20, step=1,
                        label="자막 한 줄 최대 글자수",
                    )
                    sc_timestamps = gr.Checkbox(value=True, label="타임코드 포함")
                    sc_export_itt = gr.Checkbox(value=False, label="Final Cut용 iTT 자막 동시 생성")
                    sc_run_btn = gr.Button("실행", variant="primary")

                with gr.Column(scale=1):
                    sc_output_file = gr.File(
                        label="다운로드",
                        file_count="multiple",
                        interactive=False,
                    )
                    sc_text = gr.Textbox(
                        label="추출된 대본",
                        lines=14,
                        interactive=False,
                    )
                    sc_status = gr.Textbox(
                        label="진행 상황",
                        lines=14,
                        interactive=False,
                        elem_classes=["status-box"],
                    )

            sc_run_btn.click(
                fn=run_script_extract,
                inputs=[
                    sc_video,
                    sc_language,
                    sc_asr_model,
                    sc_vad_threshold,
                    sc_min_silence,
                    sc_max_subtitle_chars,
                    sc_timestamps,
                    sc_export_itt,
                ],
                outputs=[sc_output_file, sc_text, sc_status],
            )

        # ── Tab 5: FCPXML 자막 추출 ─────────────────────────────────────
        with gr.Tab("FCPXML 자막 추출"):
            with gr.Row():
                with gr.Column(scale=1):
                    ex_file = gr.File(
                        label="FCPXML 파일 업로드 (.fcpxml 또는 .fcpxmld 내부 Info.fcpxml)",
                        file_types=[".fcpxml", ".xml"],
                        file_count="single",
                    )
                    gr.Markdown(
                        "_FCPXML 안에 들어 있는 `title` 자막 텍스트를 읽어 txt로 추출합니다. "
                        "영상 ASR은 수행하지 않습니다._"
                    )
                    ex_timestamps = gr.Checkbox(value=True, label="타임코드 포함")
                    ex_run_btn = gr.Button("실행", variant="primary")

                with gr.Column(scale=1):
                    ex_output_file = gr.File(
                        label="다운로드",
                        file_count="single",
                        interactive=False,
                    )
                    ex_text = gr.Textbox(
                        label="추출된 텍스트",
                        lines=14,
                        interactive=False,
                    )
                    ex_status = gr.Textbox(
                        label="진행 상황",
                        lines=10,
                        interactive=False,
                        elem_classes=["status-box"],
                    )

            ex_run_btn.click(
                fn=run_fcpxml_extract,
                inputs=[ex_file, ex_timestamps],
                outputs=[ex_output_file, ex_text, ex_status],
            )

    return demo


# ─────────────────────────────────────────────────────────────────────────────
# 엔트리포인트
# ─────────────────────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(description="Silence Cutter Web UI")
    parser.add_argument("--host", default=os.getenv("HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.getenv("PORT", "7860")))
    parser.add_argument("--share", action="store_true", help="Gradio 공유 링크 생성")
    parser.add_argument("--no-browser", action="store_true", help="브라우저 자동 열기 비활성화")
    args = parser.parse_args()

    demo = build_ui()
    demo.launch(
        server_name=args.host,
        server_port=args.port,
        share=args.share,
        inbrowser=not args.no_browser,
        theme=gr.themes.Soft(primary_hue="blue"),
        css=".status-box textarea { font-family: monospace; font-size: 12px; }",
    )


if __name__ == "__main__":
    main()
