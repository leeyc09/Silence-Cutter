"""Qwen3-ASR + ForcedAligner를 이용한 음성 인식 및 단어별 타임스탬프"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import List

import numpy as np
import soundfile as sf


@contextlib.contextmanager
def _noop_ctx():
    """No-op context manager — used when no progress callback is provided."""
    yield


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
        on_progress=None,
    ):
        self.language = language
        self._asr_model_id = asr_model
        self._aligner_model_id = aligner_model
        self._asr = None
        self._aligner = None
        self._on_progress = on_progress

    def _ensure_loaded(self):
        if self._asr is None:
            from mlx_audio.stt import load

            patch_factory = self._patch_tqdm() if self._on_progress else None

            if self._on_progress:
                self._on_progress("model_download", 0, f"ASR 모델 준비 중: {self._asr_model_id}")
            print(f"[transcribe] ASR 모델 로딩: {self._asr_model_id}", file=__import__('sys').stderr)
            with (patch_factory() if patch_factory else _noop_ctx()):
                self._asr = load(self._asr_model_id)

            if self._on_progress:
                self._on_progress("model_download", 50, f"Aligner 모델 준비 중: {self._aligner_model_id}")
            print(f"[transcribe] ForcedAligner 로딩: {self._aligner_model_id}", file=__import__('sys').stderr)
            with (patch_factory() if patch_factory else _noop_ctx()):
                self._aligner = load(self._aligner_model_id)

            if self._on_progress:
                self._on_progress("model_download", 100, "모델 로딩 완료")

    def _patch_tqdm(self):
        """huggingface_hub.snapshot_download에 커스텀 tqdm_class를 monkey-patch.

        tqdm을 상속하되, 자체적으로 downloaded 바이트를 추적하여
        on_progress 콜백으로 바이트 단위 진행률을 전달한다.
        """
        import contextlib
        import threading
        cb = self._on_progress

        from tqdm.auto import tqdm as base_tqdm

        class _ProgressTqdm(base_tqdm):
            """tqdm subclass that forwards download progress via callback."""
            _lock = threading.Lock()
            _downloaded = 0
            _total_size = 0

            def __init__(self, *args, **kwargs):
                # Don't disable — huggingface_hub accesses self.total directly
                super().__init__(*args, **kwargs)

            def update(self, n=1):
                super().update(n)
                if n and n > 0:
                    with _ProgressTqdm._lock:
                        _ProgressTqdm._downloaded += n
                    self._report_progress()

            def refresh(self, *args, **kwargs):
                # huggingface_hub calls bytes_progress.total += file_size then refresh()
                if self.total and self.total > _ProgressTqdm._total_size:
                    _ProgressTqdm._total_size = self.total
                self._report_progress()

            def _report_progress(self):
                downloaded = _ProgressTqdm._downloaded
                total = _ProgressTqdm._total_size
                if total > 1024 * 1024:  # 1MB 이상일 때만 (메타데이터 스킵)
                    pct = min(int(downloaded * 100 / total), 100)
                    mb_done = downloaded / (1024 * 1024)
                    mb_total = total / (1024 * 1024)
                    cb("model_download", pct, f"Downloading… {mb_done:.0f} / {mb_total:.0f} MB")

            def display(self, *args, **kwargs):
                # Suppress tqdm visual output
                pass

            def close(self):
                pass

        @contextlib.contextmanager
        def _patch():
            import huggingface_hub._snapshot_download as _sd
            original = _sd.hf_tqdm
            _ProgressTqdm._downloaded = 0
            _ProgressTqdm._total_size = 0
            _sd.hf_tqdm = _ProgressTqdm
            try:
                yield
            finally:
                _sd.hf_tqdm = original

        return _patch

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


# ---------------------------------------------------------------------------
# 세그먼트 경계 후처리 — 조사/접미사 분리 복구
# ---------------------------------------------------------------------------

# 세그먼트 시작에 위치할 경우 이전 세그먼트로 옮겨야 하는 한국어 조사/어미 패턴.
# 1~2음절 조사, 어미 접미사.
_JOSA_SET = frozenset([
    # 주격/목적격/보격
    "이", "가", "을", "를", "은", "는", "도", "만",
    # 부사격/관형격 등
    "에", "에서", "에게", "의", "와", "과", "로", "으로",
    "까지", "부터", "마저", "조차", "밖에", "처럼", "같이",
    "보다", "한테", "더러", "라고", "이라고",
    # 접속 어미
    "고", "며", "면", "서",
    # 기타 자주 분리되는 접미사
    "들", "것", "중",
])


def merge_orphan_josa(segments: List[TranscribedSegment]) -> List[TranscribedSegment]:
    """세그먼트 경계에서 분리된 조사를 이전 세그먼트로 병합.

    ForcedAligner가 형태소 단위로 단어를 분리하기 때문에,
    split_long_speech_segments의 시간 기반 분할 경계에서
    "맛집" | "을 검색을..." 처럼 조사가 다음 세그먼트로 넘어가는 현상을 보정.

    동작:
    - 세그먼트의 첫 번째 단어(word)가 조사이면 이전 세그먼트의 마지막에 붙임
    - 여러 조사가 연속(e.g. "을", "은")이면 모두 이동
    - 단어가 없는(words==[]) 세그먼트는 텍스트 기준으로 판단
    """
    if len(segments) <= 1:
        return segments

    result = [segments[0]]
    for seg in segments[1:]:
        if not seg.words:
            # words가 없으면 텍스트의 첫 토큰으로 판단
            first_token = seg.text.strip().split()[0] if seg.text.strip() else ""
            if first_token in _JOSA_SET and result:
                prev = result[-1]
                result[-1] = TranscribedSegment(
                    seg_start=prev.seg_start,
                    seg_end=seg.seg_end,
                    text=(prev.text + " " + seg.text).strip(),
                    words=prev.words,
                )
                continue
            result.append(seg)
            continue

        # words가 있는 경우: 앞쪽 조사 단어들을 이전 세그먼트로 이동
        move_count = 0
        for w in seg.words:
            if w.text in _JOSA_SET:
                move_count += 1
            else:
                break

        if move_count > 0 and result and move_count < len(seg.words):
            moving_words = seg.words[:move_count]
            remaining_words = seg.words[move_count:]

            prev = result[-1]
            merged_words = prev.words + moving_words
            merged_text = " ".join(w.text for w in merged_words)
            result[-1] = TranscribedSegment(
                seg_start=prev.seg_start,
                seg_end=moving_words[-1].end,
                text=merged_text,
                words=merged_words,
            )

            remaining_text = " ".join(w.text for w in remaining_words)
            result.append(TranscribedSegment(
                seg_start=remaining_words[0].start,
                seg_end=seg.seg_end,
                text=remaining_text,
                words=remaining_words,
            ))
        else:
            result.append(seg)

    return result
