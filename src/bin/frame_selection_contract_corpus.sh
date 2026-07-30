#!/usr/bin/env bash
#
# Rebuild the established frame-selection corpus plus the hardware-boundary
# corpus. Valid fixtures are recorded through the production FFmpeg authority;
# damaged fixtures must fail without publishing authority artifacts.
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

authority_dir="$corpus_dir/authority"
failures_dir="$corpus_dir/failures"
mkdir -p "$authority_dir" "$failures_dir"

record_authority() {
  local name=$1
  local media=$2

  cargo run --quiet -- authority record -c3 -H160 -n9 "$media" \
    --output "$authority_dir/$name.avif" \
    --manifest "$authority_dir/$name.json"
}

expect_authority_failure() {
  local name=$1
  local media=$2
  local output="$authority_dir/$name.avif"
  local manifest="$authority_dir/$name.json"
  local log="$failures_dir/$name.log"

  if cargo run --quiet -- authority record -c3 -H160 -n9 "$media" \
    --output "$output" --manifest "$manifest" >"$log" 2>&1; then
    printf '%s unexpectedly produced authority output\n' "$name" >&2
    exit 1
  fi
  if [[ -e "$output" || -e "$manifest" || ! -s "$log" ]]; then
    printf '%s did not fail without publishing artifacts\n' "$name" >&2
    exit 1
  fi
}

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

# VideoToolbox hardware-boundary fixtures. Each declaration in
# tests/fixtures/hardware-boundary/declarations.json identifies whether a
# future hardware adapter is expected to handle the media or select backend
# fallback. The production FFmpeg authority remains the validation oracle.
ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset ultrafast -crf 24 -pix_fmt yuv420p -color_range tv \
  -x264-params colorprim=smpte170m:transfer=smpte170m:colormatrix=smpte170m \
  -y "$corpus_dir/h264-8-bt601-limited.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p -color_range pc \
  -x265-params log-level=error:colorprim=bt709:transfer=bt709:colormatrix=bt709 \
  -y "$corpus_dir/hevc-8-bt709-full.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset ultrafast -crf 24 -pix_fmt yuv420p10le -color_range tv \
  -x264-params colorprim=bt2020:transfer=bt2020-10:colormatrix=bt2020nc \
  -y "$corpus_dir/h264-10-bt2020-limited.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p10le -color_range pc \
  -x265-params log-level=error:colorprim=bt2020:transfer=bt2020-10:colormatrix=bt2020nc \
  -y "$corpus_dir/hevc-10-bt2020-full.mkv"

ffmpeg -v error -display_rotation:v:0 90 \
  -i "$corpus_dir/h264-8-bt601-limited.mkv" -map 0:v:0 -c copy -movflags +faststart \
  -y "$corpus_dir/h264-rotation-90.mp4"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf 'scale=640:360,setsar=4/3' \
  -c:v libx264 -preset ultrafast -crf 24 -pix_fmt yuv420p \
  -y "$corpus_dir/h264-sar-4x3.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf 'scale=640:360,tinterlace=mode=interleave_top' \
  -c:v libx264 -preset ultrafast -crf 24 -pix_fmt yuv420p -flags +ilme+ildct \
  -x264-params tff=1 -y "$corpus_dir/h264-interlaced-tff.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx264 -preset ultrafast -crf 24 -pix_fmt yuv422p \
  -y "$corpus_dir/h264-422.mkv"

ffmpeg -v error -ss 600 -t 12 -i "$input" \
  -map 0:v:0 -an -sn -dn -vf scale=640:360 \
  -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv444p \
  -x265-params log-level=error -y "$corpus_dir/hevc-444.mkv"

printf 'This is deliberately corrupt media.\n' > "$corpus_dir/corrupt-container.mkv"
dd if="$corpus_dir/h264-8-bt601-limited.mkv" \
  of="$corpus_dir/truncated-container.mkv" bs=1 count=4096 status=none

record_authority h264-8-bt601-limited "$corpus_dir/h264-8-bt601-limited.mkv"
record_authority hevc-8-bt709-full "$corpus_dir/hevc-8-bt709-full.mkv"
record_authority h264-10-bt2020-limited "$corpus_dir/h264-10-bt2020-limited.mkv"
record_authority hevc-10-bt2020-full "$corpus_dir/hevc-10-bt2020-full.mkv"
record_authority h264-rotation-90 "$corpus_dir/h264-rotation-90.mp4"
record_authority h264-sar-4x3 "$corpus_dir/h264-sar-4x3.mkv"
record_authority h264-interlaced-tff "$corpus_dir/h264-interlaced-tff.mkv"
record_authority h264-422 "$corpus_dir/h264-422.mkv"
record_authority hevc-444 "$corpus_dir/hevc-444.mkv"

expect_authority_failure corrupt-container "$corpus_dir/corrupt-container.mkv"
expect_authority_failure truncated-container "$corpus_dir/truncated-container.mkv"

VIMG_FRAME_SELECTION_ORIGINAL="$input" \
VIMG_FRAME_SELECTION_CORPUS="$corpus_dir" \
  cargo test ffmpeg_corpus_matches_shared_schedule -- --ignored --nocapture

VIMG_HARDWARE_BOUNDARY_CORPUS="$corpus_dir" \
  cargo test hardware_boundary_corpus_records_ffmpeg_authority -- --ignored --nocapture
