#!/usr/bin/env python3
"""
Prototype for the proposed `ffmpegFull` PreviewExportMode.

Reproduces, with ffmpeg only (no AVFoundation composition/export), the same
extraction + concatenation + speed-change + encode pipeline that
PreviewVideoGenerator builds via AVMutableComposition — minus the timestamp
overlay (skipped, matching how the existing `.ffmpeg` passthrough mode already
ignores it).

Math ported 1:1 from:
  - PreviewConfiguration.extractCount(forVideoDuration:)
  - PreviewConfiguration.calculateExtractParameters(forVideoDuration:)
  - PreviewGenerationLogic.calculateExtractTimestamps(...)   (biased distribution)

Usage:
    python3 ffmpeg_full_prototype.py /path/to/input.mp4 [output.mp4]

Defaults below mirror the requested test combo:
    targetDuration=60, density=S (base=24), includeAudio=True,
    minimumExtractDuration=2.0, maximumPlaybackSpeed=1.0
    encode: hevc_videotoolbox / speedPreset=medium (q:v=72, no -realtime) / 1080p / aac 128k
"""

import json
import math
import subprocess
import sys
import time
from pathlib import Path

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"

# ── Test combo parameters (mirrors PreviewCombinationTests matrix entry) ─────
TARGET_DURATION = 60.0
DENSITY_BASE_COUNT = 24          # DensityConfig.s -> baseExtractCount
INCLUDE_AUDIO = True
MINIMUM_EXTRACT_DURATION = 2.0
MAXIMUM_PLAYBACK_SPEED = 1.0

# ── Encode settings: hevc_videotoolbox / speedPreset = .medium ───────────────
# SpeedPreset.medium -> videoToolboxRealtime=false, videoToolboxQuality=72
VT_QUALITY = 72
VT_REALTIME = False
MAX_RES_FILTER = "scale=1920:1080:force_original_aspect_ratio=decrease"
AUDIO_CODEC = "aac"
AUDIO_BITRATE = "128k"


def probe_duration(path: Path) -> float:
    out = subprocess.check_output([
        FFPROBE, "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(path)
    ])
    return float(out.strip())


def probe_has_audio(path: Path) -> bool:
    out = subprocess.check_output([
        FFPROBE, "-v", "error", "-select_streams", "a",
        "-show_entries", "stream=index", "-of", "json", str(path)
    ])
    return bool(json.loads(out).get("streams"))


# ── Ported math: PreviewConfiguration.extractCount(forVideoDuration:) ────────
def extract_count(video_duration: float) -> int:
    duration_adjustment = (8.0 if video_duration > 1800.0 else 4.0) * math.log(video_duration)
    total = DENSITY_BASE_COUNT + duration_adjustment
    return max(1, round(total))


# ── Ported math: PreviewConfiguration.calculateExtractParameters(forVideoDuration:) ──
def calculate_extract_parameters(video_duration: float):
    count = extract_count(video_duration)
    base_extract_duration = TARGET_DURATION / count

    if base_extract_duration >= MINIMUM_EXTRACT_DURATION:
        return base_extract_duration, 1.0, count

    minimum_total_duration = MINIMUM_EXTRACT_DURATION * count
    required_speed = minimum_total_duration / TARGET_DURATION
    capped_speed = min(required_speed, MAXIMUM_PLAYBACK_SPEED)
    actual_extract_duration = TARGET_DURATION * capped_speed / count
    return actual_extract_duration, capped_speed, count


# ── Ported math: PreviewGenerationLogic.calculateExtractTimestamps ───────────
def calculate_extract_timestamps(total_duration: float, count: int, extract_duration: float):
    skip_start = total_duration * 0.05
    skip_end = total_duration * 0.05
    usable_duration = total_duration - skip_start - skip_end

    first_third_end = skip_start + (usable_duration * 0.333)
    second_third_end = skip_start + (usable_duration * 0.667)

    first_third_count = int(count * 0.2)
    middle_third_count = int(count * 0.6)
    last_third_count = count - first_third_count - middle_third_count

    timestamps = []

    def add_timestamps(n: int, section_start: float, section_end: float):
        if n <= 0:
            return
        section_duration = section_end - section_start
        step = section_duration / n
        max_start_time = total_duration - extract_duration
        for i in range(n):
            start_time = section_start + (step * i)
            clamped = min(start_time, max_start_time)
            timestamps.append(clamped)

    add_timestamps(first_third_count, skip_start, first_third_end)
    add_timestamps(middle_third_count, first_third_end, second_third_end)
    add_timestamps(last_third_count, second_third_end, total_duration - skip_end)

    timestamps.sort()

    deduplicated = []
    for ts in timestamps:
        if deduplicated and abs(ts - deduplicated[-1]) < 0.01:
            continue
        deduplicated.append(ts)

    return deduplicated


# ── atempo chaining: each link must be in [0.5, 2.0] ─────────────────────────
def atempo_chain(speed: float):
    if abs(speed - 1.0) < 1e-9:
        return []
    factors = []
    remaining = speed
    if remaining > 2.0:
        while remaining > 2.0:
            factors.append(2.0)
            remaining /= 2.0
        factors.append(remaining)
    elif remaining < 0.5:
        while remaining < 0.5:
            factors.append(0.5)
            remaining /= 0.5
        factors.append(remaining)
    else:
        factors.append(remaining)
    return factors


def build_filter_complex(starts, extract_duration: float, speed: float, include_audio: bool):
    n = len(starts)
    v_labels = []
    a_labels = []
    parts = []

    for i, start in enumerate(starts):
        v_label = f"v{i}"
        parts.append(
            f"[0:v]trim=start={start:.6f}:duration={extract_duration:.6f},"
            f"setpts=PTS-STARTPTS[{v_label}]"
        )
        v_labels.append(v_label)
        if include_audio:
            a_label = f"a{i}"
            parts.append(
                f"[0:a]atrim=start={start:.6f}:duration={extract_duration:.6f},"
                f"asetpts=PTS-STARTPTS[{a_label}]"
            )
            a_labels.append(a_label)

    # Concatenate
    if include_audio:
        concat_inputs = "".join(f"[{v}][{a}]" for v, a in zip(v_labels, a_labels))
        parts.append(f"{concat_inputs}concat=n={n}:v=1:a=1[vcat][acat]")
    else:
        concat_inputs = "".join(f"[{v}]" for v in v_labels)
        parts.append(f"{concat_inputs}concat=n={n}:v=1:a=0[vcat]")

    # Speed change (applied across the whole assembled timeline, matching
    # composition.scaleTimeRange being applied post-concatenation)
    video_src = "vcat"
    if abs(speed - 1.0) > 1e-9:
        parts.append(f"[vcat]setpts=PTS/{speed:.6f}[vsp]")
        video_src = "vsp"

    parts.append(f"[{video_src}]{MAX_RES_FILTER}[vout]")

    audio_src = None
    if include_audio:
        chain = atempo_chain(speed)
        if chain:
            chained = ",".join(f"atempo={f:.6f}" for f in chain)
            parts.append(f"[acat]{chained}[aout]")
            audio_src = "aout"
        else:
            audio_src = "acat"

    return ";".join(parts), audio_src


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    input_path = Path(sys.argv[1]).expanduser().resolve()
    if not input_path.exists():
        print(f"Input not found: {input_path}")
        sys.exit(1)

    output_path = Path(sys.argv[2]).expanduser().resolve() if len(sys.argv) > 2 else (
        input_path.parent / f"{input_path.stem}_ffmpegFull_proto.mp4"
    )

    print(f"Input  : {input_path}")
    print(f"Output : {output_path}")

    total_duration = probe_duration(input_path)
    has_audio = probe_has_audio(input_path)
    include_audio = INCLUDE_AUDIO and has_audio
    print(f"Source duration : {total_duration:.2f}s   has_audio={has_audio}")

    extract_duration, speed, count = calculate_extract_parameters(total_duration)
    print(f"extractCount     = {count}")
    print(f"extractDuration  = {extract_duration:.4f}s")
    print(f"playbackSpeed    = {speed:.4f}x")

    starts = calculate_extract_timestamps(total_duration, count, extract_duration)
    print(f"timestamps ({len(starts)}): " + ", ".join(f"{s:.2f}" for s in starts))

    expected_output_duration = (len(starts) * extract_duration) / speed
    print(f"expected output duration ≈ {expected_output_duration:.2f}s "
          f"(target {TARGET_DURATION:.0f}s)")

    filter_complex, audio_label = build_filter_complex(starts, extract_duration, speed, include_audio)

    args = [FFMPEG, "-y", "-i", str(input_path), "-filter_complex", filter_complex,
            "-map", "[vout]"]
    if audio_label:
        args += ["-map", f"[{audio_label}]"]
    else:
        args += ["-an"]

    args += ["-c:v", "hevc_videotoolbox"]
    if VT_REALTIME:
        args += ["-realtime", "1"]
    args += ["-q:v", str(VT_QUALITY), "-tag:v", "hvc1"]

    if audio_label:
        args += ["-c:a", AUDIO_CODEC, "-b:a", AUDIO_BITRATE]

    args.append(str(output_path))

    print("\nffmpeg command:")
    print(" ".join(args))
    print()

    start_time = time.time()
    result = subprocess.run(args)
    elapsed = time.time() - start_time

    if result.returncode != 0:
        print(f"\n❌ ffmpeg failed (exit {result.returncode}) after {elapsed:.1f}s")
        sys.exit(result.returncode)

    actual_duration = probe_duration(output_path)
    size_mb = output_path.stat().st_size / 1_048_576
    print(f"\n✅ Done in {elapsed:.1f}s")
    print(f"   Output duration : {actual_duration:.2f}s  (expected ≈ {expected_output_duration:.2f}s)")
    print(f"   Output size     : {size_mb:.2f} MB")
    print(f"   Output path     : {output_path}")


if __name__ == "__main__":
    main()
