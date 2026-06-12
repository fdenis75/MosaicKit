#!/bin/bash

# ffprobe_compare.sh
#
# Runs ffprobe on every video file in a directory and prints a comparison
# table of the key encoding settings (codec, profile, level, resolution,
# fps, bitrate, pixel format, duration, file size, audio codec/bitrate).
#
# Usage:
#   scripts/ffprobe_compare.sh <directory> [--csv]
#
#   --csv   Emit CSV instead of an aligned table (useful for spreadsheets).

set -euo pipefail

DIR="${1:-}"
FORMAT="table"
if [ "${2:-}" = "--csv" ]; then
    FORMAT="csv"
fi

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
    echo "Usage: $0 <directory> [--csv]" >&2
    exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Error: ffprobe not found in PATH" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found in PATH" >&2
    exit 1
fi

HEADER="File\tCodec\tProfile\tLevel\tResolution\tFPS\tPixFmt\tVideoBitrate\tAudioCodec\tAudioBitrate\tDuration\tFileSize"

rows=()
while IFS= read -r -d '' file; do
    info=$(ffprobe -v quiet -print_format json -show_format -show_streams "$file")

    name=$(basename "$file")

    vstream=$(echo "$info" | jq -c '.streams | map(select(.codec_type=="video")) | .[0]')
    astream=$(echo "$info" | jq -c '.streams | map(select(.codec_type=="audio")) | .[0]')
    fmt=$(echo "$info" | jq -c '.format')

    codec=$(echo "$vstream" | jq -r '.codec_name // "-"')
    profile=$(echo "$vstream" | jq -r '.profile // "-"')
    level_raw=$(echo "$vstream" | jq -r '.level // "-"')
    width=$(echo "$vstream" | jq -r '.width // 0')
    height=$(echo "$vstream" | jq -r '.height // 0')
    pix_fmt=$(echo "$vstream" | jq -r '.pix_fmt // "-"')
    fps_raw=$(echo "$vstream" | jq -r '.r_frame_rate // "-"')
    vbitrate=$(echo "$vstream" | jq -r '.bit_rate // "-"')

    acodec=$(echo "$astream" | jq -r '.codec_name // "none"')
    abitrate=$(echo "$astream" | jq -r '.bit_rate // "-"')

    duration=$(echo "$fmt" | jq -r '.duration // "-"')
    size_bytes=$(echo "$fmt" | jq -r '.size // 0')

    # Level: AVFoundation/ffmpeg report H.264/HEVC levels as integers (e.g. 40 -> "4.0")
    if [[ "$level_raw" =~ ^[0-9]+$ ]] && [ "$level_raw" -gt 0 ] 2>/dev/null; then
        level=$(awk -v l="$level_raw" 'BEGIN { printf "%.1f", l/10 }')
    else
        level="$level_raw"
    fi

    resolution="${width}x${height}"

    # FPS: convert "30000/1001" style fractions to a decimal
    if [[ "$fps_raw" == *"/"* ]]; then
        fps=$(awk -F'/' -v f="$fps_raw" 'BEGIN { split(f, a, "/"); if (a[2] != 0) printf "%.2f", a[1]/a[2]; else print "-" }')
    else
        fps="$fps_raw"
    fi

    # Video bitrate in kbps
    if [[ "$vbitrate" =~ ^[0-9]+$ ]]; then
        vbitrate_k="$(( vbitrate / 1000 ))k"
    else
        vbitrate_k="-"
    fi

    # Audio bitrate in kbps
    if [[ "$abitrate" =~ ^[0-9]+$ ]]; then
        abitrate_k="$(( abitrate / 1000 ))k"
    else
        abitrate_k="-"
    fi

    # Duration, rounded to 1 decimal
    if [[ "$duration" =~ ^[0-9.]+$ ]]; then
        duration_s="$(awk -v d="$duration" 'BEGIN { printf "%.1fs", d }')"
    else
        duration_s="-"
    fi

    # File size, human readable
    if [[ "$size_bytes" =~ ^[0-9]+$ ]] && [ "$size_bytes" -gt 0 ]; then
        size_h=$(awk -v b="$size_bytes" 'BEGIN {
            split("B KB MB GB", units)
            i = 1
            while (b >= 1024 && i < 4) { b /= 1024; i++ }
            printf "%.1f%s", b, units[i]
        }')
    else
        size_h="-"
    fi

    rows+=("$name\t$codec\t$profile\t$level\t$resolution\t$fps\t$pix_fmt\t$vbitrate_k\t$acodec\t$abitrate_k\t$duration_s\t$size_h")
done < <(find "$DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.avi" -o -iname "*.mkv" \) -print0 | sort -z)

if [ ${#rows[@]} -eq 0 ]; then
    echo "No video files found in $DIR" >&2
    exit 1
fi

if [ "$FORMAT" = "csv" ]; then
    echo -e "$HEADER" | tr '\t' ','
    for row in "${rows[@]}"; do
        echo -e "$row" | tr '\t' ','
    done
else
    {
        echo -e "$HEADER"
        for row in "${rows[@]}"; do
            echo -e "$row"
        done
    } | column -t -s $'\t'
fi
