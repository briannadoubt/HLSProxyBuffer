#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
fixture_directory="${repository_directory}/Tests/ProxyPlayerKitTests/Fixtures"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is required to regenerate the feed fixtures" >&2
    exit 1
fi

generate_fixture() {
    local name="$1"
    local color="$2"
    local frequency="$3"
    local duration="$4"
    local output_directory="${fixture_directory}/${name}"

    mkdir -p "${output_directory}"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "color=c=${color}:s=160x90:r=24" \
        -f lavfi -i "sine=frequency=${frequency}:sample_rate=48000" \
        -t "${duration}" \
        -map 0:v:0 -map 1:a:0 \
        -c:v libx264 -preset veryslow -profile:v main -level 3.0 \
        -pix_fmt yuv420p -g 24 -keyint_min 24 -sc_threshold 0 -threads 1 \
        -c:a aac -b:a 48k -ac 1 \
        -f hls -hls_time 1 -hls_playlist_type vod \
        -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \
        -hls_segment_filename "${output_directory}/segment-%03d.m4s" \
        -hls_flags independent_segments \
        "${output_directory}/playlist.m3u8"
}

generate_fixture "short-a" "0xE4572E" "440" "3"
generate_fixture "short-b" "0x3A86FF" "660" "3"
generate_fixture "long-form" "0x2A9D8F" "330" "8"

echo "Generated feed fixtures in ${fixture_directory}"
