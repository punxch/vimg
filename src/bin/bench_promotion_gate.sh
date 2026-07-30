#!/usr/bin/env bash
# Auto-promotion performance gate benchmark.
#
# Runs 30+ interleaved warm runs of software libav vs FFmpeg on the
# representative Preview profile, measuring wall time, user CPU, and RSS.
#
# Prerequisites:
#   cargo build --release --features in-process-decode
#
# Usage:
#   bash src/bin/bench_promotion_gate.sh
#
# Output: .scratch/capture-backend-fallback/promotion-gate-report.md

set -euo pipefail

BINARY="${BINARY:-./target/release/vimg}"
VIDEO="${VIDEO:-./sample/input.mkv}"
OUTDIR="${OUTDIR:-/tmp/vimg-promotion-gate}"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-30}"

REPORT=".scratch/capture-backend-fallback/promotion-gate-report.md"

mkdir -p "$OUTDIR" "$(dirname "$REPORT")"

cat > "$REPORT" <<EOF
# Auto Default-Promotion Performance Gate

**Date:** $(date -u +"%Y-%m-%d %H:%M UTC")
**Hardware:** $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
**Binary:** \`cargo build --release --features in-process-decode\`
**Fixture:** \`$VIDEO\`
**Profile:** \`vimg vcs -c3 -H160 -n9 --capture-backend <backend>\`
**Warmup:** $WARMUP runs
**Measurement:** $RUNS interleaved runs

EOF

# --- Warmup ---
echo "Warming up ($WARMUP runs each)..."
for _ in $(seq 1 "$WARMUP"); do
  "$BINARY" vcs -c3 -H160 -n9 --capture-backend libav "$VIDEO" --output "$OUTDIR/warm-libav.avif" > /dev/null 2>&1 || true
  "$BINARY" vcs -c3 -H160 -n9 --capture-backend ffmpeg "$VIDEO" --output "$OUTDIR/warm-ffmpeg.avif" > /dev/null 2>&1 || true
done

# --- Interleaved measurement ---
echo "Measuring ($RUNS interleaved runs)..."

declare -a LIBAV_WALL LIBAV_USER LIBAV_RSS
declare -a FFMPEG_WALL FFMPEG_USER FFMPEG_RSS

measure_one() {
  local backend="$1" output="$2" time_file="$3"
  /usr/bin/time -lp "$BINARY" vcs -c3 -H160 -n9 --capture-backend "$backend" "$VIDEO" --output "$output" \
    > /dev/null 2> "$time_file"
}

for run in $(seq 1 "$RUNS"); do
  # Alternate ordering to avoid systematic bias
  if (( run % 2 == 1 )); then
    # Odd runs: libav first
    measure_one "libav" "$OUTDIR/run${run}-libav.avif" "$OUTDIR/time-${run}-libav.txt"
    local lw luser lrss
    lw=$(grep '^real' "$OUTDIR/time-${run}-libav.txt" | awk '{print $NF}')
    luser=$(grep '^user' "$OUTDIR/time-${run}-libav.txt" | awk '{print $NF}')
    lrss=$(grep 'maximum resident set size' "$OUTDIR/time-${run}-libav.txt" | grep -oE '[0-9]+' || echo "0")

    measure_one "ffmpeg" "$OUTDIR/run${run}-ffmpeg.avif" "$OUTDIR/time-${run}-ffmpeg.txt"
    local fw fuser frss
    fw=$(grep '^real' "$OUTDIR/time-${run}-ffmpeg.txt" | awk '{print $NF}')
    fuser=$(grep '^user' "$OUTDIR/time-${run}-ffmpeg.txt" | awk '{print $NF}')
    frss=$(grep 'maximum resident set size' "$OUTDIR/time-${run}-ffmpeg.txt" | grep -oE '[0-9]+' || echo "0")
  else
    # Even runs: FFmpeg first
    measure_one "ffmpeg" "$OUTDIR/run${run}-ffmpeg.avif" "$OUTDIR/time-${run}-ffmpeg.txt"
    local fw fuser frss
    fw=$(grep '^real' "$OUTDIR/time-${run}-ffmpeg.txt" | awk '{print $NF}')
    fuser=$(grep '^user' "$OUTDIR/time-${run}-ffmpeg.txt" | awk '{print $NF}')
    frss=$(grep 'maximum resident set size' "$OUTDIR/time-${run}-ffmpeg.txt" | grep -oE '[0-9]+' || echo "0")

    measure_one "libav" "$OUTDIR/run${run}-libav.avif" "$OUTDIR/time-${run}-libav.txt"
    local lw luser lrss
    lw=$(grep '^real' "$OUTDIR/time-${run}-libav.txt" | awk '{print $NF}')
    luser=$(grep '^user' "$OUTDIR/time-${run}-libav.txt" | awk '{print $NF}')
    lrss=$(grep 'maximum resident set size' "$OUTDIR/time-${run}-libav.txt" | grep -oE '[0-9]+' || echo "0")
  fi

  LIBAV_WALL+=("$lw"); LIBAV_USER+=("$luser"); LIBAV_RSS+=("$lrss")
  FFMPEG_WALL+=("$fw"); FFMPEG_USER+=("$fuser"); FFMPEG_RSS+=("$frss")

  echo "  run $run: libav=${lw}s/${luser}s CPU, ffmpeg=${fw}s/${fuser}s CPU"
done

# --- Statistics ---
calc_stats() {
  local name="$1"; shift
  local -a vals=("$@")
  local sorted count sum min max p95 p50
  IFS=$'\n' sorted=($(sort -n <<<"${vals[*]}")); unset IFS
  count=${#sorted[@]}
  sum=$(echo "${vals[*]}" | tr ' ' '\n' | paste -sd+ | bc)
  min=${sorted[0]}
  max=${sorted[$((count - 1))]}
  p50=${sorted[$((count * 50 / 100))]}
  p95=${sorted[$((count * 95 / 100))]}
  local avg=$(echo "scale=2; $sum / $count" | bc)
  echo "$name: avg=$avg min=$min max=$max p50=$p50 p95=$p95 count=$count"
}

cat >> "$REPORT" <<EOF

## Software libav

$(calc_stats "libav-wall" "${LIBAV_WALL[@]}")
$(calc_stats "libav-user" "${LIBAV_USER[@]}")

## FFmpeg (current default)

$(calc_stats "ffmpeg-wall" "${FFMPEG_WALL[@]}")
$(calc_stats "ffmpeg-user" "${FFMPEG_USER[@]}")

## Comparison

| Metric | libav | FFmpeg | Improvement |
|--------|------:|------:|-----------:|
| Wall avg | $(echo "scale=2; $(IFS=+; echo "${LIBAV_WALL[*]}" | bc) / $RUNS" | bc)s | $(echo "scale=2; $(IFS=+; echo "${FFMPEG_WALL[*]}" | bc) / $RUNS" | bc)s | |
| User CPU avg | | | |
| P95 wall | | | |

EOF

echo "Report: $REPORT"
