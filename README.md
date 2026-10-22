# CBB Shot Lab Player Finder

A T-Rank-style player finder for D1 men's basketball since 2008, with extra filters:
shot-zone attempts, unassisted rates by zone, 2s by distance, corner 3s, weight, BMI, age, hometown, draft pick.

Live site: https://doodoogame67.github.io/cbb-shot-lab/

## How it works

- `pipeline/build.sql` turns ESPN box scores + play-by-play (via sportsdataverse) into per-season, game-level CSVs
  under `site/data/` (one row per player-game and per team-game).
- `site/index.html` loads one season and aggregates in the browser, so date range, conference-only, venue and
  "games vs top N" filters recompute every stat. All state lives in the URL, so any view is a shareable link.
- `.github/workflows/refresh-and-deploy.yml` rebuilds the data and deploys to GitHub Pages daily Nov–Apr,
  on every push to `main`, and from the Actions tab ("Run workflow"). The data (~225 MB) is never committed.

## On a Mac

```
git clone https://github.com/doodoogame67/cbb-shot-lab.git
cd cbb-shot-lab
bash tools/refresh.sh                              # downloads ~220 MB and builds site/data (about a minute)
python3 -m http.server 8000 --directory site       # then open http://localhost:8000
```

`bash tools/refresh.sh 2025 2026` builds only those seasons. Edit, then `git add -A && git commit -m "..." && git push`;
the live site redeploys in a few minutes.

Windows equivalents: `tools/refresh.ps1` and `tools/serve.ps1`.

## Data caveats

| Seasons | Games with play-by-play | Assists in play-by-play | Shot locations |
|---|---|---|---|
| 2008 | 53% | 58% | none |
| 2009–2011 | ~65% | ~81% | none |
| 2012–2013 | ~63% | ~98% | none |
| 2014–2024 | 87–99% | ~99% | 7–24% |
| 2025 | 98% | 99% | 29% |
| 2026 | 100% | 98% | 100% |

- Box-score stats are complete every season; shot-zone stats only count games with play-by-play.
- ORtg / D-Rtg are Dean Oliver's formulas; PRPG = (ORtg − 88) × usage × Min% × 68. Not opponent-adjusted, so they differ a bit from T-Rank. No BPM.
- Height/weight are each player's final ESPN listing; class is worked back from final class; age is as of Feb 1 of the season.
- TS%, usage and TO% use a 0.475 free-throw weight (matches T-Rank's TS% exactly on sampled players).
