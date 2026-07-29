#!/usr/bin/env bash
#
# Rebuild the established 11-case H.264/HEVC corpus and compare the shared
# frame schedule with instrumented FFmpeg CFR authority output.
#
# Run:
#   bash src/bin/frame_selection_contract_corpus.sh ./sample/input.mkv

set -euo pipefail

input=${1:-./sample/input.mkv}
temporary_root=${TMPDIR:-/tmp}
corpus_dir=$(mktemp -d "$temporary_root/vimg-frame-selection-corpus.XXXXXX")

case "$(basename "$corpus_dir")" in
  vimg-frame-selection-corpus.*) ;;
  *)
    printf 'Unexpected temporary directory: %s\n' "$corpus_dir" >&2
    exit 1
    ;;
esac

cleanup() {
  if [[ -d "$corpus_dir" ]] && [[ "$(basename "$corpus_dir")" == vimg-frame-selection-corpus.* ]]; then
    rm -r -- "$corpus_dir"
  fi
}
trap cleanup EXIT

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset veryfast -crf 22 \
  -g 240 -keyint_min 240 -sc_threshold 0 -bf 3 \
  -pix_fmt yuv420p -y "$corpus_dir/h264-longgop-b3.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset veryfast -crf 22 \
  -g 12 -keyint_min 12 -sc_threshold 0 -bf 0 \
  -pix_fmt yuv420p -y "$corpus_dir/h264-shortgop-nob.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn \
  -vf "scale=640:360,select='not(eq(mod(n,10),0))'" -fps_mode vfr \
  -c:v libx264 -preset veryfast -crf 22 \
  -g 240 -keyint_min 240 -sc_threshold 0 -bf 3 \
  -pix_fmt yuv420p -y "$corpus_dir/h264-vfr-b3.mkv"

ffmpeg -v error -ss 600 -t 1.6 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset veryfast -crf 22 \
  -g 240 -keyint_min 240 -sc_threshold 0 -bf 3 \
  -pix_fmt yuv420p -y "$corpus_dir/h264-short-b3.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset veryfast -crf 22 \
  -g 360 -keyint_min 360 -sc_threshold 0 -bf 8 \
  -x264-params open-gop=1:b-pyramid=2 \
  -pix_fmt yuv420p -y "$corpus_dir/h264-tail-g360-b8.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 24 \
  -x265-params log-level=error:keyint=240:min-keyint=240:scenecut=0:bframes=4 \
  -pix_fmt yuv420p -y "$corpus_dir/hevc-longgop-b4.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 24 \
  -x265-params log-level=error:keyint=12:min-keyint=12:scenecut=0:bframes=0 \
  -pix_fmt yuv420p -y "$corpus_dir/hevc-shortgop-nob.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn \
  -vf "scale=640:360,select='not(eq(mod(n,10),0))'" -fps_mode vfr \
  -c:v libx265 -preset ultrafast -crf 24 \
  -x265-params log-level=error:keyint=240:min-keyint=240:scenecut=0:bframes=4 \
  -pix_fmt yuv420p -y "$corpus_dir/hevc-vfr-b4.mkv"

ffmpeg -v error -ss 600 -t 1.6 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 24 \
  -x265-params log-level=error:keyint=240:min-keyint=240:scenecut=0:bframes=4 \
  -pix_fmt yuv420p -y "$corpus_dir/hevc-short-b4.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 24 \
  -x265-params log-level=error:keyint=360:min-keyint=360:scenecut=0:bframes=8:rc-lookahead=20:open-gop=1 \
  -pix_fmt yuv420p -y "$corpus_dir/hevc-tail-g360-b8.mkv"

VIMG_FRAME_SELECTION_ORIGINAL="$input" \
VIMG_FRAME_SELECTION_CORPUS="$corpus_dir" \
  cargo test ffmpeg_corpus_matches_shared_schedule -- --ignored --nocapture
