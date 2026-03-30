"""메인 파이프라인: 영상 → 무음 감지 → 전사 → FCPXML 생성"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Optional

from .vad import extract_audio, detect_speech, split_long_speech_segments, SpeechSegment
from .transcribe import Transcriber, TranscribedSegment as _TS, WordTimestamp as _WT
from .fcpxml import generate_fcpxml, generate_fcpxml_multi, VideoSegments
from .itt import generate_itt
from .srt import generate_srt


def _probe_video(video_path: str | Path) -> dict:
    """ffprobe로 영상 정보 추출"""
    result = subprocess.run(
        [
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_format", "-show_streams",
            str(video_path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def _get_fps(probe_info: dict) -> float:
    """ffprobe 결과에서 fps 추출"""
    for stream in probe_info.get("streams", []):
        if stream.get("codec_type") == "video":
            # r_frame_rate: "24000/1001" 등
            rfr = stream.get("r_frame_rate", "24/1")
            num, den = map(int, rfr.split("/"))
            if den > 0:
                return num / den
    return 24.0


def _get_resolution(probe_info: dict) -> tuple[int, int]:
    """ffprobe 결과에서 해상도(width, height) 추출. 회전 메타데이터 반영."""
    for stream in probe_info.get("streams", []):
        if stream.get("codec_type") == "video":
            w = int(stream.get("width", 1920))
            h = int(stream.get("height", 1080))
            # 회전 메타데이터 확인 (iPhone 등)
            rotation = 0
            for sd in stream.get("side_data_list", []):
                if "rotation" in sd:
                    rotation = abs(int(sd["rotation"]))
            if rotation in (90, 270):
                w, h = h, w
            return w, h
    return 1920, 1080


def _get_duration(probe_info: dict) -> float:
    """ffprobe 결과에서 총 길이(초) 추출"""
    dur = probe_info.get("format", {}).get("duration")
    if dur:
        return float(dur)
    for stream in probe_info.get("streams", []):
        dur = stream.get("duration")
        if dur:
            return float(dur)
    return 0.0


def run(
    video_path: str | Path,
    output_path: Optional[str | Path] = None,
    *,
    language: str = "Korean",
    asr_model: str = "mlx-community/Qwen3-ASR-0.6B-8bit",
    aligner_model: str = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
    vad_threshold: float = 0.5,
    min_speech_ms: int = 250,
    min_silence_ms: int = 300,
    speech_pad_ms: int = 100,
    font_size: int = 42,
    max_subtitle_chars: int = 20,
    export_itt: bool = False,
    project_name: str = "SilenceCut",
) -> Path:
    """
    전체 파이프라인 실행.

    Args:
        video_path: 입력 영상 파일
        output_path: 출력 FCPXML 경로 (None이면 영상 옆에 .fcpxml 생성)
        language: 음성 언어 (Korean, English, Japanese, Chinese 등)
        asr_model: Qwen3-ASR 모델 ID
        aligner_model: ForcedAligner 모델 ID
        vad_threshold: VAD 민감도 (0~1, 낮을수록 민감)
        min_speech_ms: 최소 음성 구간 길이 (ms)
        min_silence_ms: 최소 무음 구간 길이 (ms) — 이보다 짧은 무음은 유지
        speech_pad_ms: 음성 구간 앞뒤 패딩 (ms)
        font_size: 자막 폰트 크기
        project_name: FCP 프로젝트 이름

    Returns:
        생성된 FCPXML 파일 경로
    """
    video_path = Path(video_path).resolve()
    if not video_path.exists():
        raise FileNotFoundError(f"영상 파일을 찾을 수 없습니다: {video_path}")

    if output_path is None:
        output_path = video_path.with_suffix(".fcpxml")
    output_path = Path(output_path)

    # 1. 영상 정보 추출
    print(f"[pipeline] 영상 분석: {video_path.name}")
    probe = _probe_video(video_path)
    fps = _get_fps(probe)
    duration = _get_duration(probe)
    width, height = _get_resolution(probe)
    print(f"[pipeline] {width}x{height} @ {fps:.3f}fps, 길이: {duration:.1f}s")

    # 2. 오디오 추출
    print("[pipeline] 오디오 추출 중...")
    audio_path = extract_audio(video_path)
    print(f"[pipeline] 오디오 저장: {audio_path}")

    # 3. VAD: 음성 구간 감지
    print("[pipeline] 음성 구간 감지 중 (Silero VAD)...")
    speech_segments = detect_speech(
        audio_path,
        threshold=vad_threshold,
        min_speech_ms=min_speech_ms,
        min_silence_ms=min_silence_ms,
        speech_pad_ms=speech_pad_ms,
    )
    print(f"[pipeline] 음성 구간 {len(speech_segments)}개 감지")

    if not speech_segments:
        print("[pipeline] 음성 구간이 없습니다. 종료합니다.")
        return output_path

    # 통계
    speech_total = sum(s.duration for s in speech_segments)
    silence_total = duration - speech_total
    print(f"[pipeline] 음성: {speech_total:.1f}s / 무음: {silence_total:.1f}s "
          f"({silence_total / duration * 100:.0f}% 제거)")

    # 4. ASR: 전사 + 단어별 타임스탬프
    print("[pipeline] 음성 인식 중 (Qwen3-ASR + ForcedAligner)...")
    transcriber = Transcriber(
        asr_model=asr_model,
        aligner_model=aligner_model,
        language=language,
    )
    transcribed = transcriber.transcribe_all(audio_path, speech_segments)
    print(f"[pipeline] 전사 완료: {len(transcribed)}개 구간")

    # 5. FCPXML 생성
    print("[pipeline] FCPXML 생성 중...")
    generate_fcpxml(
        segments=transcribed,
        video_path=video_path,
        output_path=output_path,
        fps=fps,
        width=width,
        height=height,
        video_duration=duration,
        project_name=project_name,
        font_size=font_size,
        max_subtitle_chars=max_subtitle_chars,
    )
    print(f"[pipeline] 완료! → {output_path}")

    # iTT 자막 파일 생성 (타임라인 기준 시간으로 변환)
    if export_itt:
        lang_code = {"Korean": "ko", "English": "en", "Japanese": "ja", "Chinese": "zh"}.get(language, "ko")
        itt_path = output_path.with_suffix(".itt")
        print("[pipeline] iTT 자막 생성 중...")

        # 소스 시간 → 타임라인 시간 변환 (무음 제거 후 누적 오프셋)
        timeline_segments = []
        tl_offset = 0.0
        for seg in transcribed:
            seg_dur = seg.seg_end - seg.seg_start
            tl_words = []
            for w in seg.words:
                tl_words.append(_WT(
                    text=w.text,
                    start=tl_offset + (w.start - seg.seg_start),
                    end=tl_offset + (w.end - seg.seg_start),
                ))
            timeline_segments.append(_TS(
                seg_start=tl_offset,
                seg_end=tl_offset + seg_dur,
                text=seg.text,
                words=tl_words,
            ))
            tl_offset += seg_dur

        generate_itt(
            segments=timeline_segments,
            output_path=itt_path,
            language=lang_code,
            max_subtitle_chars=max_subtitle_chars,
        )
        print(f"[pipeline] iTT → {itt_path}")

    print(f"[pipeline] Final Cut Pro에서 File > Import > XML로 열어주세요.")

    # 임시 오디오 파일 정리
    try:
        audio_path.unlink()
    except OSError:
        pass

    return output_path


def run_multi(
    video_paths: list[str | Path],
    output_path: str | Path,
    *,
    language: str = "Korean",
    asr_model: str = "mlx-community/Qwen3-ASR-1.7B-8bit",
    aligner_model: str = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
    vad_threshold: float = 0.5,
    min_speech_ms: int = 250,
    min_silence_ms: int = 300,
    speech_pad_ms: int = 100,
    font_size: int = 42,
    max_subtitle_chars: int = 20,
    export_itt: bool = False,
    project_name: str = "SilenceCut",
) -> Path:
    """여러 영상을 처리하여 하나의 FCPXML 타임라인으로 생성."""
    output_path = Path(output_path)

    transcriber = Transcriber(
        asr_model=asr_model,
        aligner_model=aligner_model,
        language=language,
    )

    all_videos: list[VideoSegments] = []

    for vi, vp in enumerate(video_paths):
        vp = Path(vp).resolve()
        if not vp.exists():
            print(f"[multi] 경고: 파일 없음 — {vp}, 건너뜀")
            continue

        print(f"\n[multi] === ({vi + 1}/{len(video_paths)}) {vp.name} ===")

        probe = _probe_video(vp)
        fps = _get_fps(probe)
        duration = _get_duration(probe)
        width, height = _get_resolution(probe)
        print(f"[multi] {width}x{height} @ {fps:.3f}fps, 길이: {duration:.1f}s")

        print("[multi] 오디오 추출 중...")
        audio_path = extract_audio(vp)

        print("[multi] 음성 구간 감지 중...")
        speech_segments = detect_speech(
            audio_path,
            threshold=vad_threshold,
            min_speech_ms=min_speech_ms,
            min_silence_ms=min_silence_ms,
            speech_pad_ms=speech_pad_ms,
        )
        print(f"[multi] 음성 구간 {len(speech_segments)}개 감지")

        if not speech_segments:
            print("[multi] 음성 없음, 건너뜀")
            try:
                audio_path.unlink()
            except OSError:
                pass
            continue

        speech_total = sum(s.duration for s in speech_segments)
        silence_total = duration - speech_total
        print(f"[multi] 음성: {speech_total:.1f}s / 무음: {silence_total:.1f}s "
              f"({silence_total / duration * 100:.0f}% 제거)")

        print("[multi] 음성 인식 중...")
        transcribed = transcriber.transcribe_all(audio_path, speech_segments)
        print(f"[multi] 전사 완료: {len(transcribed)}개 구간")

        all_videos.append(VideoSegments(
            video_path=vp,
            segments=transcribed,
            fps=fps,
            width=width,
            height=height,
            duration=duration,
        ))

        try:
            audio_path.unlink()
        except OSError:
            pass

    if not all_videos:
        print("[multi] 처리할 영상이 없습니다.")
        return output_path

    print(f"\n[multi] FCPXML 생성 중... (영상 {len(all_videos)}개)")
    generate_fcpxml_multi(
        videos=all_videos,
        output_path=output_path,
        project_name=project_name,
        font_size=font_size,
        max_subtitle_chars=max_subtitle_chars,
    )
    print(f"[multi] 완료! → {output_path}")

    if export_itt:
        lang_code = {"Korean": "ko", "English": "en", "Japanese": "ja", "Chinese": "zh"}.get(language, "ko")
        itt_path = output_path.with_suffix(".itt")
        print("[multi] iTT 자막 생성 중...")

        timeline_segments = []
        tl_offset = 0.0
        for v in all_videos:
            for seg in v.segments:
                seg_dur = seg.seg_end - seg.seg_start
                tl_words = [
                    _WT(text=w.text,
                        start=tl_offset + (w.start - seg.seg_start),
                        end=tl_offset + (w.end - seg.seg_start))
                    for w in seg.words
                ]
                timeline_segments.append(_TS(
                    seg_start=tl_offset,
                    seg_end=tl_offset + seg_dur,
                    text=seg.text,
                    words=tl_words,
                ))
                tl_offset += seg_dur

        generate_itt(
            segments=timeline_segments,
            output_path=itt_path,
            language=lang_code,
            max_subtitle_chars=max_subtitle_chars,
        )
        print(f"[multi] iTT → {itt_path}")

    print(f"[multi] Final Cut Pro에서 File > Import > XML로 열어주세요.")
    return output_path


def run_subtitle_only(
    video_path: str | Path,
    output_dir: str | Path,
    *,
    language: str = "Korean",
    asr_model: str = "mlx-community/Qwen3-ASR-1.7B-8bit",
    aligner_model: str = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
    vad_threshold: float = 0.5,
    min_speech_ms: int = 250,
    min_silence_ms: int = 300,
    speech_pad_ms: int = 100,
    max_subtitle_chars: int = 20,
    export_srt: bool = True,
    export_itt: bool = True,
) -> list[Path]:
    """영상에서 자막만 생성 (무음 컷 없음). SRT/iTT 출력."""
    video_path = Path(video_path).resolve()
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not video_path.exists():
        raise FileNotFoundError(f"영상 파일을 찾을 수 없습니다: {video_path}")

    stem = video_path.stem
    lang_code = {"Korean": "ko", "English": "en", "Japanese": "ja", "Chinese": "zh"}.get(language, "ko")

    # 1. 오디오 추출
    print(f"[subtitle] 영상: {video_path.name}")
    print("[subtitle] 오디오 추출 중...")
    audio_path = extract_audio(video_path)

    # 2. VAD
    print("[subtitle] 음성 구간 감지 중...")
    speech_segments = detect_speech(
        audio_path,
        threshold=vad_threshold,
        min_speech_ms=min_speech_ms,
        min_silence_ms=min_silence_ms,
        speech_pad_ms=speech_pad_ms,
    )
    print(f"[subtitle] 음성 구간 {len(speech_segments)}개 감지")

    asr_segments = split_long_speech_segments(audio_path, speech_segments)
    if len(asr_segments) != len(speech_segments):
        print(
            "[subtitle] 긴 음성 구간 자동 분할: "
            f"VAD {len(speech_segments)}개 → 전사용 {len(asr_segments)}개"
        )

    if not asr_segments:
        print("[subtitle] 음성 구간이 없습니다.")
        return []

    # 3. ASR
    print("[subtitle] 음성 인식 중...")
    transcriber = Transcriber(
        asr_model=asr_model,
        aligner_model=aligner_model,
        language=language,
    )
    transcribed = transcriber.transcribe_all(audio_path, asr_segments)
    print(f"[subtitle] 전사 완료: {len(transcribed)}개 구간")

    # 4. 자막 파일 생성 (원본 타임라인 기준 — 무음 컷 없음)
    output_files = []

    if export_srt:
        srt_path = output_dir / f"{stem}.srt"
        print("[subtitle] SRT 생성 중...")
        generate_srt(
            segments=transcribed,
            output_path=srt_path,
            max_subtitle_chars=max_subtitle_chars,
        )
        output_files.append(srt_path)
        print(f"[subtitle] SRT → {srt_path}")

    if export_itt:
        itt_path = output_dir / f"{stem}.itt"
        print("[subtitle] iTT 생성 중...")
        generate_itt(
            segments=transcribed,
            output_path=itt_path,
            language=lang_code,
            max_subtitle_chars=max_subtitle_chars,
        )
        output_files.append(itt_path)
        print(f"[subtitle] iTT → {itt_path}")

    # 정리
    try:
        audio_path.unlink()
    except OSError:
        pass

    print(f"[subtitle] 완료! {len(output_files)}개 파일 생성")
    return output_files
