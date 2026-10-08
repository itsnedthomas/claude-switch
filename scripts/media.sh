#!/bin/bash
# Renders the README and landing-page media from the real UI with made-up demo
# data (no real accounts are read). Writes docs/media/*.png, tour.mp4/gif and
# menubar.mp4/gif.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
OUT=$(mktemp -d)
./.build/release/ClaudeSwitch --film "$OUT"
mkdir -p docs/media
cp "$OUT"/*.png docs/media/
enc() { ffmpeg -loglevel error -y -framerate 60 -i "$OUT/$1/%05d.png" -c:v libx264 -preset slower -crf 16 -pix_fmt yuv420p -movflags +faststart "docs/media/$1.mp4"; }
gif() { ffmpeg -loglevel error -y -framerate 60 -i "$OUT/$1/%05d.png" -vf "fps=$2,scale=$3:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" "docs/media/$1.gif"; }
enc tour; gif tour 30 1000
enc menubar; gif menubar 30 780
rm -rf "$OUT"
echo "media written to docs/media"
