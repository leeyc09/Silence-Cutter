"""CLI 엔트리포인트: python -m silence_cutter <command> [options]"""

import argparse
import sys
from pathlib import Path


def cmd_cut(args):
    """영상 → 무음 컷 + 자막 FCPXML 생성"""
    video_path = Path(args.video)
    if not video_path.exists():
        print(f"오류: 파일을 찾을 수 없습니다 — {video_path}", file=sys.stderr)
        sys.exit(1)

    from .pipeline import run

    result = run(
        video_path=video_path,
        output_path=args.output,
        language=args.language,
        asr_model=args.asr_model,
        aligner_model=args.aligner_model,
        vad_threshold=args.vad_threshold,
        min_speech_ms=args.min_speech_ms,
        min_silence_ms=args.min_silence_ms,
        speech_pad_ms=args.speech_pad_ms,
        font_size=args.font_size,
        max_subtitle_chars=args.max_subtitle_chars,
        export_itt=args.itt,
        project_name=args.project_name,
    )
    print(f"\n생성 완료: {result}")


def cmd_multi(args):
    """여러 영상 → 하나의 FCPXML 타임라인"""
    from .pipeline import run_multi

    result = run_multi(
        video_paths=args.videos,
        output_path=args.output,
        language=args.language,
        asr_model=args.asr_model,
        aligner_model=args.aligner_model,
        vad_threshold=args.vad_threshold,
        min_speech_ms=args.min_speech_ms,
        min_silence_ms=args.min_silence_ms,
        speech_pad_ms=args.speech_pad_ms,
        font_size=args.font_size,
        max_subtitle_chars=args.max_subtitle_chars,
        export_itt=args.itt,
        project_name=args.project_name,
    )
    print(f"\n생성 완료: {result}")


def cmd_script(args):
    """영상에서 직접 대본 추출 (영상 → ASR → 텍스트)"""
    video_path = Path(args.video)
    if not video_path.exists():
        print(f"오류: 파일을 찾을 수 없습니다 — {video_path}", file=sys.stderr)
        sys.exit(1)

    from .itt import generate_itt
    from .subtitles import build_subtitle_chunks
    from .transcribe import Transcriber
    from .vad import extract_audio, detect_speech, split_long_speech_segments

    # 1. 오디오 추출
    print(f"[script] 영상: {video_path.name}")
    print("[script] 오디오 추출 중...")
    audio_path = extract_audio(video_path)

    # 2. VAD
    print("[script] 음성 구간 감지 중...")
    segments = detect_speech(
        audio_path,
        threshold=args.vad_threshold,
        min_speech_ms=250,
        min_silence_ms=args.min_silence_ms,
        speech_pad_ms=100,
    )
    print(f"[script] 음성 구간 {len(segments)}개")

    asr_segments = split_long_speech_segments(audio_path, segments)
    if len(asr_segments) != len(segments):
        print(
            "[script] 긴 음성 구간 자동 분할: "
            f"VAD {len(segments)}개 → 전사용 {len(asr_segments)}개"
        )

    transcribed = []
    if asr_segments:
        # 3. ASR
        print("[script] 음성 인식 중...")
        transcriber = Transcriber(
            asr_model=args.asr_model,
            aligner_model="mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
            language=args.language,
        )
        transcribed = transcriber.transcribe_all(audio_path, asr_segments)
    else:
        print("[script] 음성이 없어 빈 대본으로 저장합니다.")

    # 4. 텍스트 출력
    lines = []
    chunks = build_subtitle_chunks(
        transcribed,
        max_subtitle_chars=args.max_subtitle_chars,
    )
    for chunk in chunks:
        if args.timestamps:
            m1, s1 = divmod(chunk["start"], 60)
            m2, s2 = divmod(chunk["end"], 60)
            lines.append(
                f"[{int(m1):02d}:{s1:04.1f} ~ {int(m2):02d}:{s2:04.1f}] {chunk['text']}"
            )
        else:
            lines.append(chunk["text"])

    result = "\n".join(lines)

    if args.output:
        Path(args.output).write_text(result, encoding="utf-8")
        print(f"[script] 저장 완료: {args.output}")
    else:
        print("\n" + result)

    if args.itt:
        lang_code = {
            "Korean": "ko",
            "English": "en",
            "Japanese": "ja",
            "Chinese": "zh",
        }.get(args.language, "ko")
        itt_path = Path(args.output).with_suffix(".itt") if args.output else video_path.with_suffix(".itt")
        generate_itt(
            segments=transcribed,
            output_path=itt_path,
            language=lang_code,
            max_subtitle_chars=args.max_subtitle_chars,
        )
        print(f"[script] iTT 저장 완료: {itt_path}")

    # 정리
    try:
        audio_path.unlink()
    except OSError:
        pass


def cmd_extract(args):
    """FCPXML에서 대본/스크립트 텍스트 추출"""
    fcpxml_path = Path(args.fcpxml)
    if not fcpxml_path.exists():
        print(f"오류: 파일을 찾을 수 없습니다 — {fcpxml_path}", file=sys.stderr)
        sys.exit(1)

    from .extract import extract_script

    result = extract_script(
        fcpxml_path=fcpxml_path,
        output_path=args.output,
        with_timestamps=args.timestamps,
    )

    if args.output:
        print(f"저장 완료: {args.output}")
    else:
        print(result)


def cmd_resub(args):
    """편집된 FCPXML/FCPXMLD → 자막 재생성"""
    fcpxml_path = Path(args.fcpxml)
    if not fcpxml_path.exists():
        print(f"오류: 파일을 찾을 수 없습니다 — {fcpxml_path}", file=sys.stderr)
        sys.exit(1)

    from .retranscribe import retranscribe

    lang_code = {"Korean": "ko", "English": "en", "Japanese": "ja", "Chinese": "zh"}.get(args.language, "ko")
    result = retranscribe(
        fcpxml_path=fcpxml_path,
        output_path=args.output,
        language=args.language,
        asr_model=args.asr_model,
        aligner_model=args.aligner_model,
        font_size=args.font_size,
        max_subtitle_chars=args.max_subtitle_chars,
        export_itt=args.itt,
        language_code=lang_code,
    )
    print(f"\n생성 완료: {result}")


def main():
    parser = argparse.ArgumentParser(
        prog="silence_cutter",
        description="영상 무음 컷 편집 + 자막 생성 도구",
    )
    subparsers = parser.add_subparsers(dest="command")

    # --- cut 커맨드 (기본) ---
    cut_parser = subparsers.add_parser(
        "cut",
        help="영상의 무음 구간을 제거하고 자막을 생성하여 FCPXML로 출력",
    )
    cut_parser.add_argument("video", type=str, help="입력 영상 파일 경로")
    cut_parser.add_argument("-o", "--output", type=str, default=None, help="출력 FCPXML 경로")
    cut_parser.add_argument("-l", "--language", type=str, default="Korean", help="음성 언어 (기본: Korean)")
    cut_parser.add_argument("--asr-model", type=str, default="mlx-community/Qwen3-ASR-1.7B-8bit",
                            help="ASR 모델 ID (기본: Qwen3-ASR-1.7B-8bit)")
    cut_parser.add_argument("--aligner-model", type=str, default="mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
                            help="ForcedAligner 모델 ID")
    cut_parser.add_argument("--vad-threshold", type=float, default=0.5, help="VAD 민감도 0~1 (기본: 0.5)")
    cut_parser.add_argument("--min-speech-ms", type=int, default=250, help="최소 음성 구간 ms (기본: 250)")
    cut_parser.add_argument("--min-silence-ms", type=int, default=300, help="최소 무음 구간 ms (기본: 300)")
    cut_parser.add_argument("--speech-pad-ms", type=int, default=100, help="음성 앞뒤 패딩 ms (기본: 100)")
    cut_parser.add_argument("--font-size", type=int, default=42, help="자막 폰트 크기 (기본: 42)")
    cut_parser.add_argument("--max-subtitle-chars", type=int, default=20, help="자막 한 줄 최대 글자수 (기본: 20)")
    cut_parser.add_argument("--itt", action="store_true", help="iTT 자막 파일도 함께 생성")
    cut_parser.add_argument("--project-name", type=str, default="SilenceCut", help="FCP 프로젝트 이름")

    # --- script 커맨드 ---
    script_parser = subparsers.add_parser(
        "script",
        help="영상에서 직접 대본 추출 (영상 → ASR → 텍스트)",
    )
    script_parser.add_argument("video", type=str, help="입력 영상 파일 경로")
    script_parser.add_argument("-o", "--output", type=str, default=None, help="출력 txt 경로 (생략 시 화면 출력)")
    script_parser.add_argument("-t", "--timestamps", action="store_true", help="타임코드 포함")
    script_parser.add_argument("-l", "--language", type=str, default="Korean", help="음성 언어 (기본: Korean)")
    script_parser.add_argument("--asr-model", type=str, default="mlx-community/Qwen3-ASR-1.7B-8bit",
                               help="ASR 모델 ID")
    script_parser.add_argument("--vad-threshold", type=float, default=0.5, help="VAD 민감도 (기본: 0.5)")
    script_parser.add_argument("--min-silence-ms", type=int, default=300, help="최소 무음 길이 ms (기본: 300)")
    script_parser.add_argument("--max-subtitle-chars", type=int, default=20, help="자막 한 줄 최대 글자수 (기본: 20)")
    script_parser.add_argument("--itt", action="store_true", help="Final Cut Pro용 iTT 자막 파일도 함께 생성")

    # --- extract 커맨드 ---
    extract_parser = subparsers.add_parser(
        "extract",
        help="FCPXML에서 대본/스크립트 텍스트 추출",
    )
    extract_parser.add_argument("fcpxml", type=str, help="FCPXML 또는 FCPXMLD 경로")
    extract_parser.add_argument("-o", "--output", type=str, default=None, help="출력 txt 경로 (생략 시 화면 출력)")
    extract_parser.add_argument("-t", "--timestamps", action="store_true", help="타임코드 포함")

    # --- resub 커맨드 ---
    resub_parser = subparsers.add_parser(
        "resub",
        help="편집된 FCPXML/FCPXMLD를 읽어서 자막만 재생성",
    )
    resub_parser.add_argument("fcpxml", type=str, help="편집된 FCPXML 또는 FCPXMLD 경로")
    resub_parser.add_argument("-o", "--output", type=str, default=None, help="출력 FCPXML 경로")
    resub_parser.add_argument("-l", "--language", type=str, default="Korean", help="음성 언어 (기본: Korean)")
    resub_parser.add_argument("--asr-model", type=str, default="mlx-community/Qwen3-ASR-1.7B-8bit",
                            help="ASR 모델 ID (기본: Qwen3-ASR-1.7B-8bit)")
    resub_parser.add_argument("--aligner-model", type=str, default="mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
                            help="ForcedAligner 모델 ID")
    resub_parser.add_argument("--font-size", type=int, default=42, help="자막 폰트 크기 (기본: 42)")
    resub_parser.add_argument("--max-subtitle-chars", type=int, default=20, help="자막 한 줄 최대 글자수 (기본: 20)")
    resub_parser.add_argument("--itt", action="store_true", help="iTT 자막 파일도 함께 생성")

    # --- multi 커맨드 ---
    multi_parser = subparsers.add_parser(
        "multi",
        help="여러 영상을 처리하여 하나의 FCPXML 타임라인으로 합침",
    )
    multi_parser.add_argument("videos", nargs="+", type=str, help="입력 영상 파일들")
    multi_parser.add_argument("-o", "--output", type=str, default="multi_output.fcpxml", help="출력 FCPXML 경로 (기본: multi_output.fcpxml)")
    multi_parser.add_argument("-l", "--language", type=str, default="Korean", help="음성 언어 (기본: Korean)")
    multi_parser.add_argument("--asr-model", type=str, default="mlx-community/Qwen3-ASR-1.7B-8bit",
                              help="ASR 모델 ID")
    multi_parser.add_argument("--aligner-model", type=str, default="mlx-community/Qwen3-ForcedAligner-0.6B-8bit",
                              help="ForcedAligner 모델 ID")
    multi_parser.add_argument("--vad-threshold", type=float, default=0.5, help="VAD 민감도 0~1")
    multi_parser.add_argument("--min-speech-ms", type=int, default=250, help="최소 음성 구간 ms")
    multi_parser.add_argument("--min-silence-ms", type=int, default=300, help="최소 무음 구간 ms")
    multi_parser.add_argument("--speech-pad-ms", type=int, default=100, help="음성 앞뒤 패딩 ms")
    multi_parser.add_argument("--font-size", type=int, default=42, help="자막 폰트 크기")
    multi_parser.add_argument("--max-subtitle-chars", type=int, default=20, help="자막 한 줄 최대 글자수")
    multi_parser.add_argument("--itt", action="store_true", help="iTT 자막 파일도 함께 생성")
    multi_parser.add_argument("--project-name", type=str, default="SilenceCut", help="FCP 프로젝트 이름")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        print("\n사용법:")
        print("  python -m silence_cutter cut <영상>            # 무음 컷 + 자막")
        print("  python -m silence_cutter multi <영상1> <영상2>  # 여러 영상 합침")
        print("  python -m silence_cutter resub <fcpxml>        # 자막 재생성")
        sys.exit(0)

    try:
        if args.command == "cut":
            cmd_cut(args)
        elif args.command == "multi":
            cmd_multi(args)
        elif args.command == "script":
            cmd_script(args)
        elif args.command == "extract":
            cmd_extract(args)
        elif args.command == "resub":
            cmd_resub(args)
    except KeyboardInterrupt:
        print("\n중단되었습니다.", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"\n오류: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
