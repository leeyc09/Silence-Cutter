"""Silero VAD를 이용한 음성/무음 구간 감지"""

from __future__ import annotations

import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import List

import numpy as np
import soundfile as sf
import torch
from silero_vad import load_silero_vad, get_speech_timestamps


@dataclass
class SpeechSegment:
    """음성 구간 (초 단위)"""
    start: float
    end: float

    @property
    def duration(self) -> float:
        return self.end - self.start


def extract_audio(video_path: str | Path, sample_rate: int = 16000) -> Path:
    """영상에서 16kHz mono WAV 오디오 추출 (ffmpeg)"""
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    subprocess.run(
        [
            "ffmpeg", "-y", "-i", str(video_path),
            "-vn", "-acodec", "pcm_s16le",
            "-ar", str(sample_rate), "-ac", "1",
            tmp.name,
        ],
        capture_output=True,
        check=True,
    )
    return Path(tmp.name)


def detect_speech(
    audio_path: str | Path,
    *,
    threshold: float = 0.5,
    min_speech_ms: int = 250,
    min_silence_ms: int = 300,
    speech_pad_ms: int = 100,
) -> List[SpeechSegment]:
    """Silero VAD로 음성 구간 감지. 반환: 시간순 SpeechSegment 리스트"""
    torch.set_num_threads(1)

    model = load_silero_vad()

    # soundfile로 WAV 읽기 (torchaudio/torchcodec 의존성 회피)
    data, sr = sf.read(str(audio_path), dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    # 16kHz 리샘플링 (ffmpeg에서 이미 16kHz로 추출하지만 안전장치)
    if sr != 16000:
        import librosa
        data = librosa.resample(data, orig_sr=sr, target_sr=16000)
    wav = torch.from_numpy(data)

    raw = get_speech_timestamps(
        wav,
        model,
        threshold=threshold,
        sampling_rate=16000,
        min_speech_duration_ms=min_speech_ms,
        min_silence_duration_ms=min_silence_ms,
        speech_pad_ms=speech_pad_ms,
        return_seconds=True,
    )

    return [SpeechSegment(start=s["start"], end=s["end"]) for s in raw]


def split_long_speech_segments(
    audio_path: str | Path,
    segments: List[SpeechSegment],
    *,
    max_segment_seconds: float = 15.0,
    min_segment_seconds: float = 3.0,
    search_window_seconds: float = 1.0,
    frame_ms: int = 20,
) -> List[SpeechSegment]:
    """긴 음성 구간을 ASR용으로 더 짧게 분할.

    VAD가 배경음/룸톤 때문에 긴 덩어리로 붙는 경우가 있어, 전사용 경로에서만
    저에너지 지점을 찾아 세그먼트를 잘게 나눈다.
    """
    refined: list[SpeechSegment] = []
    for seg in segments:
        refined.extend(
            _split_long_segment(
                audio_path,
                seg,
                max_segment_seconds=max_segment_seconds,
                min_segment_seconds=min_segment_seconds,
                search_window_seconds=search_window_seconds,
                frame_ms=frame_ms,
            )
        )
    return refined


def _split_long_segment(
    audio_path: str | Path,
    segment: SpeechSegment,
    *,
    max_segment_seconds: float,
    min_segment_seconds: float,
    search_window_seconds: float,
    frame_ms: int,
) -> List[SpeechSegment]:
    if segment.duration <= max_segment_seconds or segment.duration < min_segment_seconds * 2:
        return [segment]

    info = sf.info(str(audio_path))
    sr = info.samplerate
    start_frame = int(segment.start * sr)
    n_frames = int(segment.duration * sr)
    data, _ = sf.read(str(audio_path), start=start_frame, frames=n_frames, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    if len(data) == 0:
        return [segment]

    frame_size = max(1, int(sr * frame_ms / 1000))
    usable = len(data) - (len(data) % frame_size)
    if usable < frame_size:
        return [segment]

    frames = data[:usable].reshape(-1, frame_size)
    rms = np.sqrt(np.mean(frames * frames, axis=1) + 1e-12)
    frame_seconds = frame_size / sr

    refined: list[SpeechSegment] = []
    cursor = segment.start
    segment_end = segment.end

    while segment_end - cursor > max_segment_seconds:
        target = cursor + max_segment_seconds
        search_start = max(cursor + min_segment_seconds, target - search_window_seconds)
        search_end = min(segment_end - min_segment_seconds, target + search_window_seconds)
        fallback = min(target, segment_end - min_segment_seconds)

        if search_start >= search_end:
            split_at = fallback
        else:
            idx_start = max(0, int((search_start - segment.start) / frame_seconds))
            idx_end = min(len(rms) - 1, int((search_end - segment.start) / frame_seconds))
            if idx_end <= idx_start:
                split_at = fallback
            else:
                local_min = int(np.argmin(rms[idx_start:idx_end + 1])) + idx_start
                split_at = segment.start + ((local_min + 0.5) * frame_seconds)

        split_at = max(cursor + min_segment_seconds, min(split_at, segment_end - min_segment_seconds))
        if split_at <= cursor:
            split_at = fallback

        refined.append(SpeechSegment(start=cursor, end=split_at))
        cursor = split_at

    refined.append(SpeechSegment(start=cursor, end=segment_end))
    return refined
