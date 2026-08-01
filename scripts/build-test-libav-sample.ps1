# build-test-libav-sample.ps1
#
# Builds the libav in-process-decode feature build, runs the test suite, and
# benchmarks the fixed Preview profile against sample/input.mkv, verifying the
# output stays byte-identical to the established reference (SHA-256
# 3f0fa2be...). Mirrors the workflow in report.md:
#
#   1. cargo build --release --features in-process-decode
#      (PKG_CONFIG_PATH must point at FFmpeg 8.1.2 shared dev libs, gyan
#      build, so the in-process SVT-AV1 matches the CLI subprocess build and
#      the output is byte-identical)
#   2. cargo test --features in-process-decode (needs the FFmpeg DLLs on PATH)
#   3. warm runs of `vimg vcs -c3 -H160 -n9 sample/input.mkv --output ...`
#      with --profile; prints med/min/max per phase
#   4. Get-FileHash check against the reference SHA-256
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\build-test-libav-sample.ps1
#
# Options:
#   -WarmRuns 4        number of warm benchmark runs (default 5)
#   -SkipTests         skip cargo test
#   -SkipBenchmark     skip the benchmark + hash check
#   -MeasureRss        also measure peak working set (needs python +
#                      benchmarks/peak_ws.py, 2 extra runs)
#   -Deploy            copy the fresh exe into the deploy DLL directory

param(
    [string]$RepoRoot = "D:\Repo\Rust\vimg",
    [string]$FfmpegDev = "D:\ffmpeg-dev",
    [string]$FfmpegShared = "",          # default: $FfmpegDev\ffmpeg-8.1.2-full_build-shared
    [string]$DeployDir = "",             # default: $FfmpegDev\libav-deploy
    [int]$WarmRuns = 5,
    [string]$ExpectedSha256 = "3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2",
    [switch]$SkipTests,
    [switch]$SkipBenchmark,
    [switch]$MeasureRss,
    [switch]$Deploy
)

$ErrorActionPreference = "Stop"

if (-not $FfmpegShared) { $FfmpegShared = Join-Path $FfmpegDev "ffmpeg-8.1.2-full_build-shared" }
if (-not $DeployDir) { $DeployDir = Join-Path $FfmpegDev "libav-deploy" }

$PkgConfigDir = Join-Path $FfmpegShared "lib\pkgconfig"
$Sample = Join-Path $RepoRoot "sample\input.mkv"
$Output = Join-Path $RepoRoot "output.avif"
$Exe = Join-Path $RepoRoot "target\release\vimg.exe"

function FailIfMissing($Path, $What) {
    if (-not (Test-Path $Path)) {
        Write-Error "$What not found: $Path" ; exit 1
    }
}

FailIfMissing $PkgConfigDir "FFmpeg 8.1.2 shared pkgconfig"
FailIfMissing $DeployDir "libav deploy DLL directory"
FailIfMissing $Sample "sample/input.mkv (gitignored; must exist locally)"

Write-Host "== libav feature build + sample test ==" -ForegroundColor Cyan
Write-Host "repo       : $RepoRoot"
Write-Host "pkgconfig  : $PkgConfigDir"
Write-Host "deploy DLLs: $DeployDir"
Write-Host "sample     : $Sample"
Write-Host ""

# --- 1. build --------------------------------------------------------------
Write-Host "[1/4] cargo build --release --features in-process-decode ..." -ForegroundColor Yellow
$env:PKG_CONFIG_PATH = $PkgConfigDir
Push-Location $RepoRoot
try {
    cargo build --release --features in-process-decode
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

if ($Deploy) {
    Write-Host "[deploy] copying vimg.exe -> $DeployDir" -ForegroundColor Yellow
    Copy-Item $Exe $DeployDir -Force
}

# --- 2. tests --------------------------------------------------------------
if (-not $SkipTests) {
    Write-Host "[2/4] cargo test --features in-process-decode (DLLs on PATH) ..." -ForegroundColor Yellow
    $env:PATH = "$DeployDir;$env:PATH"
    Push-Location $RepoRoot
    try {
        cargo test --features in-process-decode
        if ($LASTEXITCODE -ne 0) { throw "cargo test failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[2/4] tests skipped (-SkipTests)" -ForegroundColor DarkGray
}

# --- 3. benchmark ----------------------------------------------------------
if (-not $SkipBenchmark) {
    Write-Host "[3/4] benchmark: $WarmRuns warm runs (--profile) ..." -ForegroundColor Yellow
    $env:PATH = "$DeployDir;$env:PATH"
    $logs = @()
    for ($i = 1; $i -le $WarmRuns; $i++) {
        # Run through cmd /c with stderr merged at the cmd layer: PS 5.1
        # wraps any native stderr line as a NativeCommandError under
        # ErrorActionPreference=Stop, and SVT logs to stderr.
        $args = "vcs -c3 -H160 -n9 --profile `"$Sample`" --output `"$Output`""
        $log = @(cmd /c "`"$Exe`" $args 2>&1")
        if ($LASTEXITCODE -ne 0) { throw "benchmark run $i failed (exit $LASTEXITCODE)" }
        $profileLine = $log | Where-Object { $_ -match '^\[profile\] backend=' } | Select-Object -Last 1
        if (-not $profileLine) { throw "run $i produced no [profile] line" }
        $logs += , $profileLine
    }

    function Get-Metric($Line, $Name) {
        if ($Line -match "$Name=([0-9.]+)s") { return [double]$Matches[1] }
        return $null
    }

    $metrics = @("plan_setup", "decode", "first_grid", "receive_wait", "join",
                 "encoder_write", "encoder_tail", "total")
    $cols = @{}
    foreach ($m in $metrics) {
        $vals = @($logs | ForEach-Object { Get-Metric $_ $m } | Where-Object { $null -ne $_ })
        if ($vals.Count -gt 0) {
            $sorted = $vals | Sort-Object
            $mid = [int][math]::Floor($sorted.Count / 2)
            $median = if ($sorted.Count % 2 -eq 1) { $sorted[$mid] } else { ($sorted[$mid - 1] + $sorted[$mid]) / 2 }
            $cols[$m] = [pscustomobject]@{
                Median = $median
                Min    = $sorted[0]
                Max    = $sorted[-1]
            }
        }
    }

    Write-Host ""
    Write-Host ("{0,-15} {1,8} {2,8} {3,8}" -f "phase", "median", "min", "max") -ForegroundColor Cyan
    Write-Host ("{0,-15} {1,8} {2,8} {3,8}" -f "-----", "------", "---", "---")
    foreach ($m in $metrics) {
        if ($cols.ContainsKey($m)) {
            $c = $cols[$m]
            Write-Host ("{0,-15} {1,8:f3} {2,8:f3} {3,8:f3}" -f $m, $c.Median, $c.Min, $c.Max)
        }
    }
    $total = $cols["total"]
    Write-Host ("P95 check: total max {0:f3}s vs 1.3s contract -> {1}" -f $total.Max,
        $(if ($total.Max -le 1.3) { "OK" } else { "EXCEEDED (noise band ~1.2-1.4)" })) -ForegroundColor Cyan

    # --- 4. byte identity -----------------------------------------------------
    Write-Host "[4/4] verifying output SHA-256 ..." -ForegroundColor Yellow
    function Get-Sha256($Path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join ""
        } finally {
            $stream.Dispose()
            $sha.Dispose()
        }
    }
    $hash = Get-Sha256 $Output
    if ($hash -eq $ExpectedSha256) {
        Write-Host "OK: output byte-identical ($hash)" -ForegroundColor Green
    } else {
        Write-Host "FAIL: expected $ExpectedSha256" -ForegroundColor Red
        Write-Host "      actual     $hash" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[3/4] benchmark skipped (-SkipBenchmark)" -ForegroundColor DarkGray
}

# --- optional RSS ----------------------------------------------------------
if ($MeasureRss) {
    Write-Host "[extra] peak working set via benchmarks/peak_ws.py (2 runs) ..." -ForegroundColor Yellow
    $PeakWs = Join-Path $RepoRoot "benchmarks\peak_ws.py"
    if (-not (Test-Path $PeakWs)) { Write-Warning "benchmarks/peak_ws.py missing; skipping RSS" }
    else {
        $env:PATH = "$DeployDir;$env:PATH"
        $rssOut = Join-Path $RepoRoot "output_rss.avif"
        python $PeakWs $Exe vcs -c3 -H160 -n9 $Sample --output $rssOut 2>$null
        python $PeakWs $Exe vcs -c3 -H160 -n9 $Sample --output $rssOut 2>$null
        Remove-Item $rssOut -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "done." -ForegroundColor Green
