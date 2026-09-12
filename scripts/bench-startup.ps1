param(
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$Candidate,
    [string]$Video = "sample/input.mkv",
    [string]$OutputDirectory = ".scratch/startup/comparison",
    [ValidateRange(1, 1000)][int]$Runs = 12
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$results = @()
# Every invocation starts a new process. First means first observation of this
# binary in this batch, NOT a reboot or an OS page-cache purge. Alternate order
# to avoid attributing background load / thermal drift to either binary.
foreach ($round in 0..$Runs) {
    $order = if ($round % 2 -eq 0) { @("baseline", "candidate") } else { @("candidate", "baseline") }
    foreach ($arm in $order) {
        $exe = if ($arm -eq "baseline") { $Baseline } else { $Candidate }
        $output = Join-Path $OutputDirectory "$arm.avif"
        $log = Join-Path $OutputDirectory "$arm-$round.log"
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & $exe vcs -c3 -H160 -n9 $Video --output $output --profile 2> $log
        $exitCode = $LASTEXITCODE
        $timer.Stop()
        if ($exitCode -ne 0) { throw "$arm round $round failed: see $log" }
        $profile = Get-Content $log | Where-Object { $_ -match '^\[profile\] backend=' } | Select-Object -Last 1
        if (-not $profile) { throw "No phase profile: $log" }
        $row = [ordered]@{
            Arm = $arm; Round = $round
            State = $(if ($round -eq 0) { "first-observation" } else { "warm" })
            Wall = $timer.Elapsed.TotalSeconds
            Sha256 = (Get-FileHash $output -Algorithm SHA256).Hash
        }
        foreach ($metric in @("plan_setup", "decode", "first_grid", "join", "encoder_tail", "total")) {
            if ($profile -match "\b$metric=([0-9.]+)s") {
                $row[$metric] = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            }
        }
        $results += [pscustomobject]$row
        $results | Export-Csv (Join-Path $OutputDirectory "results.csv") -NoTypeInformation
        Write-Host ("{0} {1}: {2:F3}s" -f $arm, $round, $timer.Elapsed.TotalSeconds)
    }
}
if (@($results.Sha256 | Select-Object -Unique).Count -ne 1) {
    throw "Output hashes differ between runs/binaries; optimization must not be promoted."
}
$results | Group-Object Arm | ForEach-Object {
    $warm = @($_.Group | Where-Object State -eq "warm" | Sort-Object Wall)
    $middle = [int][math]::Floor($warm.Count / 2)
    $median = if ($warm.Count % 2) { $warm[$middle].Wall } else { ($warm[$middle - 1].Wall + $warm[$middle].Wall) / 2 }
    [pscustomobject]@{
        Arm = $_.Name
        First = ($_.Group | Where-Object Round -eq 0).Wall
        WarmMedian = $median
        WarmP95 = $warm[[math]::Ceiling(0.95 * $warm.Count) - 1].Wall
    }
} | Format-Table
