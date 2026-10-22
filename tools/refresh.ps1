# Downloads the sportsdataverse ESPN files and rebuilds site/data (Windows).
# Usage: powershell -ExecutionPolicy Bypass -File tools\refresh.ps1 [-Seasons 2008,2009,...]
param([int[]]$Seasons)
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path (Join-Path $PSScriptRoot ".."))
if (-not $Seasons) {
    $now = (Get-Date).ToUniversalTime()
    $cur = if ($now.Month -ge 10) { $now.Year + 1 } else { $now.Year }
    $Seasons = 2008..$cur
}
$base = "https://github.com/sportsdataverse/sportsdataverse-data/releases/download"
New-Item -ItemType Directory -Force raw, site\data | Out-Null
Remove-Item raw\*.parquet -ErrorAction SilentlyContinue  # stale seasons would be globbed into the build

function Get-File($url, $out) {
    curl.exe -sfL --retry 3 -o $out $url
    if ($LASTEXITCODE -ne 0) { Write-Warning "missing: $url"; Remove-Item $out -ErrorAction SilentlyContinue }
}
foreach ($s in $Seasons) {
    Write-Host "season $s"
    Get-File "$base/espn_mens_college_basketball_shots/shots_$s.parquet" "raw\shots_$s.parquet"
    Get-File "$base/espn_mens_college_basketball_player_boxscores/player_box_$s.parquet" "raw\player_box_$s.parquet"
    Get-File "$base/espn_mens_college_basketball_player_core/player_core_$s.parquet" "raw\player_core_$s.parquet"
    Get-File "$base/espn_mens_college_basketball_schedules/mbb_schedule_$s.parquet" "raw\mbb_schedule_$s.parquet"
    Get-File "$base/mbb_ratings/mbb_ratings_$s.parquet" "raw\mbb_ratings_$s.parquet"
}
Get-File "$base/mbb_groups/mbb_team_group_seasons.parquet" "raw\mbb_team_group_seasons.parquet"

if (-not (Test-Path tools\duckdb.exe)) {
    curl.exe -sL -o tools\duckdb.tgz "https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-cli-windows-amd64.tar.gz"
    tar -xzf tools\duckdb.tgz -C tools; Remove-Item tools\duckdb.tgz
}
.\tools\duckdb.exe -no-agent -c ".read pipeline/build.sql"
Write-Host "done: site/data/"
