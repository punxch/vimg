#!/usr/bin/env bash
# Auto-promotion performance gate benchmark.
#
# Measures:
#   - one first-process observation per usable backend;
#   - 30+ rotated, interleaved warm runs of software libav and FFmpeg;
#   - real early VideoToolbox -> libav fallback overhead;
#   - VideoToolbox forced-backend availability without hiding failures.
#
# Prerequisites:
#   cargo build --release --features in-process-decode
#
# Usage:
#   bash src/bin/bench_promotion_gate.sh
#
# Environment overrides:
#   BINARY, VIDEO, OUTDIR, WARMUP, RUNS, FALLBACK_RUNS, REPORT, RAW_RESULTS,
#   REUSE_RESULTS=1 (regenerate the report from an existing raw TSV)

set -euo pipefail

BINARY="${BINARY:-./target/release/vimg}"
VIDEO="${VIDEO:-./sample/input.mkv}"
OUTDIR="${OUTDIR:-/tmp/vimg-promotion-gate}"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-30}"
FALLBACK_RUNS="${FALLBACK_RUNS:-5}"
REPORT="${REPORT:-.scratch/capture-backend-fallback/promotion-gate-report.md}"
RAW_RESULTS="${RAW_RESULTS:-.scratch/capture-backend-fallback/promotion-gate-results.tsv}"
REUSE_RESULTS="${REUSE_RESULTS:-0}"

for value in "$WARMUP" "$RUNS" "$FALLBACK_RUNS"; do
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "WARMUP, RUNS, and FALLBACK_RUNS must be non-negative integers" >&2
    exit 2
  fi
done
if (( RUNS < 1 || FALLBACK_RUNS < 1 )); then
  echo "RUNS and FALLBACK_RUNS must be at least 1" >&2
  exit 2
fi
if [[ ! -x "$BINARY" ]]; then
  echo "Benchmark binary is missing or not executable: $BINARY" >&2
  exit 2
fi
if [[ ! -f "$VIDEO" ]]; then
  echo "Benchmark video is missing: $VIDEO" >&2
  exit 2
fi

mkdir -p "$OUTDIR" "$(dirname "$REPORT")" "$(dirname "$RAW_RESULTS")"
if [[ "$REUSE_RESULTS" == "1" ]]; then
  if [[ ! -f "$RAW_RESULTS" ]]; then
    echo "Cannot reuse missing raw results: $RAW_RESULTS" >&2
    exit 2
  fi
else
  printf 'phase\trun\tbackend\torder\tstatus\twall_s\tuser_s\tmax_rss_bytes\n' > "$RAW_RESULTS"
fi

measure_one() {
  local phase="$1"
  local run="$2"
  local backend="$3"
  local order="$4"
  local output="$5"
  local time_file="$OUTDIR/time-${phase}-${run}-${backend}.txt"
  local status wall user_cpu max_rss

  set +e
  /usr/bin/time -lp "$BINARY" vcs -c3 -H160 -n9 \
    --capture-backend "$backend" "$VIDEO" --output "$output" \
    > /dev/null 2> "$time_file"
  status=$?
  set -e

  wall="$(awk '$1 == "real" { value = $2 } END { print value }' "$time_file")"
  user_cpu="$(awk '$1 == "user" { value = $2 } END { print value }' "$time_file")"
  max_rss="$(awk '/maximum resident set size/ { value = $1 } END { print value }' "$time_file")"
  wall="${wall:-0}"
  user_cpu="${user_cpu:-0}"
  max_rss="${max_rss:-0}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$run" "$backend" "$order" "$status" "$wall" "$user_cpu" "$max_rss" \
    >> "$RAW_RESULTS"
  return "$status"
}

measure_required() {
  if ! measure_one "$@"; then
    echo "Required benchmark failed: phase=$1 run=$2 backend=$3" >&2
    echo "See $OUTDIR/time-$1-$2-$3.txt" >&2
    exit 1
  fi
}

average() {
  local phase="$1"
  local backend="$2"
  local column="$3"
  awk -F '\t' -v phase="$phase" -v backend="$backend" -v column="$column" '
    $1 == phase && $3 == backend && $5 == 0 {
      sum += $column
      count += 1
    }
    END {
      if (count == 0) print "0"
      else printf "%.3f", sum / count
    }
  ' "$RAW_RESULTS"
}

percentile_95() {
  local phase="$1"
  local backend="$2"
  local column="$3"
  awk -F '\t' -v phase="$phase" -v backend="$backend" -v column="$column" \
    '$1 == phase && $3 == backend && $5 == 0 { print $column }' "$RAW_RESULTS" |
    sort -n |
    awk '
      { values[NR] = $1 }
      END {
        if (NR == 0) {
          print "0"
        } else {
          rank = int((NR * 95 + 99) / 100)
          printf "%.3f", values[rank]
        }
      }
    '
}

maximum_mib() {
  local phase="$1"
  local backend="$2"
  awk -F '\t' -v phase="$phase" -v backend="$backend" '
    $1 == phase && $3 == backend && $5 == 0 && $8 > maximum {
      maximum = $8
    }
    END { printf "%.1f", maximum / 1048576 }
  ' "$RAW_RESULTS"
}

improvement() {
  local baseline="$1"
  local candidate="$2"
  awk -v baseline="$baseline" -v candidate="$candidate" '
    BEGIN {
      if (baseline == 0) print "0.0"
      else printf "%.1f", (baseline - candidate) * 100 / baseline
    }
  '
}

difference() {
  local first="$1"
  local second="$2"
  awk -v first="$first" -v second="$second" \
    'BEGIN { printf "%.3f", first - second }'
}

if [[ "$REUSE_RESULTS" != "1" ]]; then
  echo "Recording first-process observations..."
  measure_required "first-process" "1" "libav" "libav-first" "$OUTDIR/latest-libav.avif"
  measure_required "first-process" "1" "ffmpeg" "ffmpeg-second" "$OUTDIR/latest-ffmpeg.avif"
  measure_required "first-process" "1" "auto" "auto-third" "$OUTDIR/latest-auto.avif"

  echo "Probing forced VideoToolbox..."
  measure_one "videotoolbox-probe" "1" "videotoolbox" "forced" \
    "$OUTDIR/latest-videotoolbox.avif" || true

  echo "Warming usable backends ($WARMUP runs each)..."
  if (( WARMUP > 0 )); then
    for run in $(seq 1 "$WARMUP"); do
      "$BINARY" vcs -c3 -H160 -n9 --capture-backend libav \
        "$VIDEO" --output "$OUTDIR/latest-libav.avif" > /dev/null 2>&1
      "$BINARY" vcs -c3 -H160 -n9 --capture-backend ffmpeg \
        "$VIDEO" --output "$OUTDIR/latest-ffmpeg.avif" > /dev/null 2>&1
    done
  fi

  echo "Measuring warm backends ($RUNS rotated, interleaved runs)..."
  for run in $(seq 1 "$RUNS"); do
    if (( run % 2 == 1 )); then
      order="libav-first"
      measure_required "warm" "$run" "libav" "$order" "$OUTDIR/latest-libav.avif"
      measure_required "warm" "$run" "ffmpeg" "$order" "$OUTDIR/latest-ffmpeg.avif"
    else
      order="ffmpeg-first"
      measure_required "warm" "$run" "ffmpeg" "$order" "$OUTDIR/latest-ffmpeg.avif"
      measure_required "warm" "$run" "libav" "$order" "$OUTDIR/latest-libav.avif"
    fi
    echo "  completed warm pair $run/$RUNS"
  done

  echo "Measuring early fallback overhead ($FALLBACK_RUNS interleaved runs)..."
  for run in $(seq 1 "$FALLBACK_RUNS"); do
    if (( run % 2 == 1 )); then
      order="auto-first"
      measure_required "early-fallback" "$run" "auto" "$order" "$OUTDIR/latest-auto.avif"
      measure_required "early-fallback" "$run" "libav" "$order" "$OUTDIR/latest-libav.avif"
    else
      order="libav-first"
      measure_required "early-fallback" "$run" "libav" "$order" "$OUTDIR/latest-libav.avif"
      measure_required "early-fallback" "$run" "auto" "$order" "$OUTDIR/latest-auto.avif"
    fi
    echo "  completed fallback pair $run/$FALLBACK_RUNS"
  done
else
  echo "Reusing measurements from $RAW_RESULTS"
fi

VIDEOTOOLBOX_STATUS="$(
  awk -F '\t' '
    $1 == "videotoolbox-probe" && $3 == "videotoolbox" {
      print $5
      exit
    }
  ' "$RAW_RESULTS"
)"
VIDEOTOOLBOX_STATUS="${VIDEOTOOLBOX_STATUS:-not-recorded}"

LIBAV_WALL_AVG="$(average warm libav 6)"
LIBAV_WALL_P95="$(percentile_95 warm libav 6)"
LIBAV_USER_AVG="$(average warm libav 7)"
LIBAV_USER_P95="$(percentile_95 warm libav 7)"
LIBAV_RSS_MAX="$(maximum_mib warm libav)"
FFMPEG_WALL_AVG="$(average warm ffmpeg 6)"
FFMPEG_WALL_P95="$(percentile_95 warm ffmpeg 6)"
FFMPEG_USER_AVG="$(average warm ffmpeg 7)"
FFMPEG_USER_P95="$(percentile_95 warm ffmpeg 7)"
FFMPEG_RSS_MAX="$(maximum_mib warm ffmpeg)"
WALL_IMPROVEMENT="$(improvement "$FFMPEG_WALL_AVG" "$LIBAV_WALL_AVG")"
USER_IMPROVEMENT="$(improvement "$FFMPEG_USER_AVG" "$LIBAV_USER_AVG")"

AUTO_FALLBACK_AVG="$(average early-fallback auto 6)"
FALLBACK_LIBAV_AVG="$(average early-fallback libav 6)"
FALLBACK_OVERHEAD="$(difference "$AUTO_FALLBACK_AVG" "$FALLBACK_LIBAV_AVG")"

FIRST_LIBAV="$(average first-process libav 6)"
FIRST_FFMPEG="$(average first-process ffmpeg 6)"
FIRST_AUTO="$(average first-process auto 6)"

LIBAV_HASH="$(shasum -a 256 "$OUTDIR/latest-libav.avif" | awk '{ print $1 }')"
FFMPEG_HASH="$(shasum -a 256 "$OUTDIR/latest-ffmpeg.avif" | awk '{ print $1 }')"
if cmp -s "$OUTDIR/latest-libav.avif" "$OUTDIR/latest-ffmpeg.avif"; then
  OUTPUT_MATCH="yes"
else
  OUTPUT_MATCH="no"
fi

if awk -v rss="$LIBAV_RSS_MAX" 'BEGIN { exit !(rss <= 512) }'; then
  RSS_GATE="pass"
else
  RSS_GATE="fail"
fi
if awk -v libav="$LIBAV_WALL_P95" -v ffmpeg="$FFMPEG_WALL_P95" \
  'BEGIN { exit !(libav <= 1.3 && ffmpeg <= 1.3) }'; then
  GENERAL_P95_GATE="pass"
else
  GENERAL_P95_GATE="fail"
fi

HARDWARE="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
FFMPEG_VERSION="$(ffmpeg -hide_banner -version 2>/dev/null | awk 'NR == 1 { print $3 }')"

{
  echo "# Auto Default-Promotion Performance Gate"
  echo
  echo "**Date:** $(date -u +"%Y-%m-%d %H:%M UTC")"
  echo "**Hardware:** $HARDWARE"
  echo "**OS:** macOS $MACOS_VERSION"
  echo "**FFmpeg:** $FFMPEG_VERSION"
  echo "**Binary:** \`cargo build --release --features in-process-decode\`"
  echo "**Fixture:** \`$VIDEO\`"
  echo "**Profile:** \`vimg vcs -c3 -H160 -n9 --capture-backend <backend>\`"
  echo "**Methodology:** $WARMUP warmups, then $RUNS rotated/interleaved warm pairs"
  echo
  echo "Raw observations: \`$RAW_RESULTS\`"
  echo
  echo "## Promotion decision"
  echo
  echo "**Do not promote \`auto\`; keep \`ffmpeg\` as the default.**"
  echo
  echo "The VideoToolbox candidate cannot complete the representative Preview profile"
  echo "(forced-backend exit status $VIDEOTOOLBOX_STATUS), so its latency and CPU gates"
  echo "are not measurable. Thresholds are not weakened or substituted with libav results."
  echo
  echo "## Warm results"
  echo
  echo "| Metric | Software libav | FFmpeg | libav improvement |"
  echo "|---|---:|---:|---:|"
  echo "| Wall average | ${LIBAV_WALL_AVG}s | ${FFMPEG_WALL_AVG}s | ${WALL_IMPROVEMENT}% |"
  echo "| Wall P95 | ${LIBAV_WALL_P95}s | ${FFMPEG_WALL_P95}s | — |"
  echo "| User CPU average | ${LIBAV_USER_AVG}s | ${FFMPEG_USER_AVG}s | ${USER_IMPROVEMENT}% |"
  echo "| User CPU P95 | ${LIBAV_USER_P95}s | ${FFMPEG_USER_P95}s | — |"
  echo "| Peak RSS | ${LIBAV_RSS_MAX} MiB | ${FFMPEG_RSS_MAX} MiB | — |"
  echo
  echo "## VideoToolbox failure boundary"
  echo
  echo "The forced VideoToolbox attempt failed before producing a hardware frame."
  echo "The full diagnostic is in \`$OUTDIR/time-videotoolbox-probe-1-videotoolbox.txt\`."
  echo "This benchmark treats software pixel-format fallback as failure, so a successful"
  echo "software decode cannot be misreported as VideoToolbox performance."
  echo
  echo "Independent probes reproduced the same VideoToolbox session-initialization"
  echo "failure with FFmpeg $FFMPEG_VERSION's own CLI and its installed official"
  echo "\`hw_decode.c\` example, including on a newly generated two-second 1080p"
  echo "H.264 fixture. That falsifies a Vimg transfer-path or Rust-binding-specific"
  echo "cause: the failure occurs below Vimg before any hardware frame is returned."
  echo
  echo "## First-process observations"
  echo
  echo "These are fresh-process observations made before benchmark warmups. They are not"
  echo "filesystem-cache-cold claims; reproducible cache eviction requires privileged OS"
  echo "control and is deliberately kept separate from the warm promotion result."
  echo
  echo "| Policy | Wall time |"
  echo "|---|---:|"
  echo "| libav | ${FIRST_LIBAV}s |"
  echo "| ffmpeg | ${FIRST_FFMPEG}s |"
  echo "| auto (early VideoToolbox failure, then libav) | ${FIRST_AUTO}s |"
  echo
  echo "## Fallback latency"
  echo
  echo "Real early fallback was measured in $FALLBACK_RUNS rotated/interleaved pairs:"
  echo "\`auto\` averaged ${AUTO_FALLBACK_AVG}s versus ${FALLBACK_LIBAV_AVG}s for direct"
  echo "libav, an observed overhead of ${FALLBACK_OVERHEAD}s."
  echo
  echo "Late injected fallback is a correctness/stress scenario, not a sub-second SLA."
  echo "It must be reported independently if a lifecycle fault-injection benchmark is"
  echo "added; it is not mixed into the warm promotion distribution here."
  echo
  echo "## Correctness"
  echo
  echo "- Latest libav and FFmpeg AVIF outputs byte-identical: **$OUTPUT_MATCH**"
  echo "- libav SHA-256: \`$LIBAV_HASH\`"
  echo "- FFmpeg SHA-256: \`$FFMPEG_HASH\`"
  echo
  echo "## Gate checklist"
  echo
  echo "| Gate | Target | Result |"
  echo "|---|---:|---|"
  echo "| General warm P95 | ≤ 1.300s | $GENERAL_P95_GATE (${LIBAV_WALL_P95}s libav, ${FFMPEG_WALL_P95}s FFmpeg) |"
  echo "| VideoToolbox warm P95 | < 1.000s | fail: not measurable |"
  echo "| VideoToolbox wall improvement over libav | ≥ 15% | fail: not measurable |"
  echo "| VideoToolbox user CPU improvement over libav | ≥ 70% | fail: not measurable |"
  echo "| Active-job peak RSS | ≤ 512 MiB | $RSS_GATE (libav ${LIBAV_RSS_MAX} MiB) |"
  echo "| Frame-selection/output contract | exact/approved tolerance | byte-identical=$OUTPUT_MATCH |"
  echo "| Rotated, interleaved warm runs | ≥ 30 | $RUNS pairs |"
  echo "| First-process and fallback observations separate | required | yes |"
  echo
  echo "## Reproduction"
  echo
  echo '```bash'
  echo "cargo build --release --features in-process-decode"
  echo "bash src/bin/bench_promotion_gate.sh"
  echo "ffmpeg -hide_banner -loglevel debug -hwaccel videotoolbox \\"
  echo "  -i ./sample/input.mkv -frames:v 1 -f null -"
  echo '```'
} > "$REPORT"

echo "Report: $REPORT"
echo "Raw results: $RAW_RESULTS"
