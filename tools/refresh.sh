#!/usr/bin/env bash
# Re-downloads the sportsdataverse ESPN files and rebuilds site/data (macOS / Linux / GitHub Actions).
# Usage: tools/refresh.sh [season ...]   default: 2024 through the current season
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=https://github.com/sportsdataverse/sportsdataverse-data/releases/download
DUCKDB_VERSION=v2.0.0

if [ $# -gt 0 ]; then
  SEASONS="$*"
else
  # a season is named for the year it ends: Oct 2026 onward is the 2027 season
  y=$(date -u +%Y); m=$((10#$(date -u +%m)))
  cur=$(( m >= 10 ? y + 1 : y ))
  SEASONS=$(seq 2024 "$cur")
fi

fetch() {
  curl -sfL -o "$2" "$1" || { echo "missing: $1"; rm -f "$2"; }
}

mkdir -p raw site/data
rm -f raw/*.parquet  # stale seasons would be globbed into the build
for s in $SEASONS; do
  echo "season $s"
  fetch "$BASE/espn_mens_college_basketball_shots/shots_$s.parquet" "raw/shots_$s.parquet"
  fetch "$BASE/espn_mens_college_basketball_player_boxscores/player_box_$s.parquet" "raw/player_box_$s.parquet"
  fetch "$BASE/espn_mens_college_basketball_rosters/rosters_$s.parquet" "raw/rosters_$s.parquet"
done
fetch "$BASE/mbb_groups/mbb_team_group_seasons.parquet" "raw/mbb_team_group_seasons.parquet"

# pinned DuckDB so the SQL behaves the same everywhere
DUCK=tools/bin/duckdb
if [ ! -x "$DUCK" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-*) asset=duckdb-cli-osx-universal.tar.gz ;;
    Linux-aarch64|Linux-arm64) asset=duckdb-cli-linux-arm64.tar.gz ;;
    *) asset=duckdb-cli-linux-amd64.tar.gz ;;
  esac
  mkdir -p tools/bin
  curl -sfL "https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VERSION/$asset" | tar -xz -C tools/bin
fi

"$DUCK" -no-agent -c ".read pipeline/build.sql"
"$DUCK" -no-agent -c "COPY (SELECT * FROM 'site/data/players.parquet' ORDER BY season DESC, ppg DESC, id, team) TO 'site/data/players.csv' (HEADER)"
echo "done: site/data/players.csv"
