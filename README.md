# CBB Shot Lab

A queryable D1 men's player database built from ESPN play-by-play (via sportsdataverse/hoopR),
focused on shot zones and self-creation (unassisted rate by zone).

Live site: https://doodoogame67.github.io/cbb-shot-lab/

## Layout

- `pipeline/build.sql`: all the stat logic (zones, distance bands, unassisted %, usage/TS/rates). DuckDB SQL.
- `tools/refresh.sh`: downloads the raw files and runs the build (macOS / Linux). Pass seasons to override, e.g. `tools/refresh.sh 2026 2027`.
- `tools/refresh.ps1` / `tools/serve.ps1`: Windows equivalents of the refresh script and a local web server.
- `site/index.html` + `site/data/players.csv`: the app. Static, no build step.
- `.github/workflows/refresh-and-deploy.yml`: rebuilds the data daily Nov–Apr, commits the CSV, deploys to GitHub Pages.
  Also runs on every push to `main`, and from the Actions tab ("Run workflow").

## On a Mac

```
git clone https://github.com/doodoogame67/cbb-shot-lab.git
cd cbb-shot-lab
python3 -m http.server 8000 --directory site    # then open http://localhost:8000
bash tools/refresh.sh                           # optional: rebuild the data locally (downloads DuckDB into tools/bin)
```

Edit, then `git add -A && git commit -m "..." && git push`; the site redeploys in about 2 minutes.
Run `git pull` first if the daily data bot has committed since your last pull.

## Definitions and caveats

- D1 vs. D1 games only, regular season + postseason (same scope as Barttorvik).
- rim = layups/dunks/tips; j2 = all other 2s; far2 = located 2s 16ft+; c3 = corner 3.
- Unassisted % is share of MAKES (PBP only records assists on makes).
- Shot coordinates exist for ~98% of 2026 shots, ~26% of 2025, ~5% of 2024. Distance bands are only
  meaningful for 2026 onward; rim / j2 / 3 splits are complete every season.
- Validated against T-Rank: zone makes/attempts/percentages match exactly on sampled players.
