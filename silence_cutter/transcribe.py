"""Qwen3-ASR + ForcedAligner를 이용한 음성 인식 및 단어별 타임스탬프"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import List

import numpy as np
import soundfile as sf


@dataclass
class WordTimestamp:
    """단어 단위 타임스탬프 (원본 오디오 기준 절대 시간)"""
    text: str
    start: float  # 초
    end: float    # 초


@dataclass
class TranscribedSegment:
    """하나의 음성 구간에 대한 전사 결과"""
    seg_start: float   # VAD 구간 시작 (원본 기준)
    seg_end: float     # VAD 구간 끝 (원본 기준)
    text: str
    words: List[WordTimestamp] = field(default_factory=list)


def _load_segment_audio(audio_path: str | Path, start: float, end: float) -> np.ndarray:
    """오디오 파일에서 특정 구간만 읽기"""
    info = sf.info(str(audio_path))
    sr = info.samplerate
    start_frame = int(start * sr)
    n_frames = int((end - start) * sr)
    data, _ = sf.read(str(audio_path), start=start_frame, frames=n_frames, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    return data


def _compact_text(text: str) -> str:
    """비교용 텍스트 정규화: 공백/문장부호 제거."""
    return "".join(ch for ch in text if ch.isalnum())


class Transcriber:
    """Qwen3-ASR + ForcedAligner 래퍼"""

    def __init__(
        self,
        asr_model: str = "mlx-community/Qwen3-ASR-0.6B-8bit",
        aligner_model: str = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
        language: str = "Korean",
    ):
        self.language = language
        self._asr_model_id = asr_model
        self._aligner_model_id = aligner_model
        self._asr = None
        self._aligner = None

    def _ensure_loaded(self):
        if self._asr is None:
            from mlx_audio.stt import load
            print(f"[transcribe] ASR 모델 로딩: {self._asr_model_id}")
            self._asr = load(self._asr_model_id)
            print(f"[transcribe] ForcedAligner 로딩: {self._aligner_model_id}")
            self._aligner = load(self._aligner_model_id)

    def transcribe_segment(
        self,
        audio_path: str | Path,
        seg_start: float,
        seg_end: float,
    ) -> TranscribedSegment:
        """하나의 음성 구간을 전사하고 단어별 타임스탬프 생성"""
        self._ensure_loaded()

        # 구간 오디오 추출
        segment_audio = _load_segment_audio(audio_path, seg_start, seg_end)

        # ASR: 텍스트 생성
        asr_result = self._asr.generate(segment_audio, language=self.language)
        text = asr_result.text.strip()

        if not text:
            return TranscribedSegment(
                seg_start=seg_start,
                seg_end=seg_end,
                text="",
                words=[],
            )

        # ForcedAligner: 단어별 타임스탬프
        try:
            align_result = self._aligner.generate(
                audio=segment_audio,
                text=text,
                language=self.language,
            )
        except Exception as exc:
            print(
                "[transcribe] aligner fallback "
                f"({seg_start:.1f}s ~ {seg_end:.1f}s): {type(exc).__name__}: {exc}"
            )
            return TranscribedSegment(
                seg_start=seg_start,
                seg_end=seg_end,
                text=text,
                words=[],
            )

        words = []
        for item in align_result:
            words.append(WordTimestamp(
                text=item.text,
                start=seg_start + item.start_time,  # 절대 시간으로 변환
                end=seg_start + item.end_time,
            ))

        text_compact = _compact_text(text)
        words_compact = _compact_text("".join(word.text for word in words))
        coverage = (len(words_compact) / len(text_compact)) if text_compact else 1.0
        if not words or (len(text_compact) >= 6 and coverage < 0.75):
            print(
                "[transcribe] aligner text coverage fallback "
                f"({seg_start:.1f}s ~ {seg_end:.1f}s, coverage={coverage:.2f})"
            )
            return TranscribedSegment(
                seg_start=seg_start,
                seg_end=seg_end,
                text=text,
                words=[],
            )

        return TranscribedSegment(
            seg_start=seg_start,
            seg_end=seg_end,
            text=text,
            words=words,
        )

    def transcribe_all(
        self,
        audio_path: str | Path,
        segments: list,
    ) -> List[TranscribedSegment]:
        """모든 음성 구간을 순차 전사"""
        results = []
        total = len(segments)
        for i, seg in enumerate(segments, 1):
            print(f"[transcribe] ({i}/{total}) {seg.start:.1f}s ~ {seg.end:.1f}s")
            result = self.transcribe_segment(audio_path, seg.start, seg.end)
            if result.text:
                results.append(result)
        return results
