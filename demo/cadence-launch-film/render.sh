#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
npx --yes hyperframes@0.4.34 lint
npx --yes hyperframes@0.4.34 render --fps 60 --quality high --workers 4 --output cadence-launch-visuals.mp4 --strict
ffmpeg -y -v error -i cadence-launch-visuals.mp4 -i assets/soundtrack.wav \
  -map 0:v:0 -map 1:a:0 -c:v copy -af loudnorm=I=-16:TP=-1.5:LRA=16 \
  -c:a aac -b:a 192k -ar 48000 -t 52 -movflags +faststart cadence-launch-60fps.mp4
ffmpeg -y -v error -i cadence-launch-60fps.mp4 -map 0:v:0 -c copy -an \
  -movflags +faststart cadence-launch-silent-60fps.mp4
ffmpeg -y -v error -ss 3 -i cadence-launch-60fps.mp4 -frames:v 1 poster.png
ffmpeg -y -v error -i cadence-launch-60fps.mp4 \
  -vf "select='eq(n,180)+eq(n,900)+eq(n,1230)+eq(n,1788)+eq(n,2190)+eq(n,2580)+eq(n,2940)',scale=640:360,tile=3x3:padding=12:margin=12:color=0xf5f3ee" \
  -frames:v 1 contact-sheet.png
