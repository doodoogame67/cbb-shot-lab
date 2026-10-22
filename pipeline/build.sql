-- Builds site/data/players.parquet (one row per player-season-team) from the
-- sportsdataverse ESPN files in raw/. Run from the project root:
--   tools\duckdb.exe -c ".read pipeline/build.sql"
--
-- Scope matches Barttorvik: D1 vs D1 games only, regular season + postseason.
--
-- Shot zones
--   rim    layups, dunks, tips (ESPN shot type, same idea as Bart's "rim")
--   j2     every other 2 (jumpers, floaters, hooks) = "non-rim 2s"
--   close2 / mid2 / far2   j2 split by distance: <8ft, 8-16ft, 16ft+ (NBA.com's
--          "long mid-range" cutoff; only ~12% of college non-rim 2s are 16ft+)
--   three  all 3PA; c3 = corner 3, ab3 = above-the-break 3
-- Distances use ESPN's raw coords (feet, x 0-50 across, y from baseline,
-- hoop at ~(25, 2)). Locations are only reliable for 2026 (~98% of shots);
-- 2025 has ~29%, 2024 ~7%, so band stats carry a loc_cov column.
--
-- "Assisted" only exists on makes, so unast = % of MAKES that were unassisted.

-- D1 teams per season, with short conference names
CREATE OR REPLACE TEMP TABLE d1 AS
SELECT season, team_id::INT AS team_id,
    CASE replace(conference_id, 'mbb:', '')
        WHEN 'acc' THEN 'ACC' WHEN 'big-ten' THEN 'B10' WHEN 'big-12' THEN 'B12'
        WHEN 'big-east' THEN 'BE' WHEN 'sec' THEN 'SEC' WHEN 'pac-12' THEN 'P12'
        WHEN 'american' THEN 'Amer' WHEN 'atlantic-10' THEN 'A10' WHEN 'mountain-west' THEN 'MWC'
        WHEN 'wcc' THEN 'WCC' WHEN 'mvc' THEN 'MVC' WHEN 'cusa' THEN 'CUSA'
        WHEN 'sun-belt' THEN 'SB' WHEN 'mac' THEN 'MAC' WHEN 'caa' THEN 'CAA'
        WHEN 'big-west' THEN 'BW' WHEN 'big-sky' THEN 'BSky' WHEN 'big-south' THEN 'BSth'
        WHEN 'horizon' THEN 'Horz' WHEN 'ivy' THEN 'Ivy' WHEN 'maac' THEN 'MAAC'
        WHEN 'meac' THEN 'MEAC' WHEN 'nec' THEN 'NEC' WHEN 'ovc' THEN 'OVC'
        WHEN 'patriot' THEN 'Pat' WHEN 'socon' THEN 'SC' WHEN 'southland' THEN 'Slnd'
        WHEN 'summit' THEN 'Sum' WHEN 'swac' THEN 'SWAC' WHEN 'wac' THEN 'WAC'
        WHEN 'asun' THEN 'ASun' WHEN 'america-east' THEN 'AE' WHEN 'independents' THEN 'Ind'
        ELSE replace(conference_id, 'mbb:', '')
    END AS conf
FROM 'raw/mbb_team_group_seasons.parquet'
WHERE subdivision_id = 'mbb:d1';

-- Player box rows from D1 vs D1 games
CREATE OR REPLACE TEMP TABLE box AS
SELECT pb.*
FROM read_parquet('raw/player_box_*.parquet', union_by_name = true) pb
JOIN d1 a ON a.season = pb.season AND a.team_id = pb.team_id
JOIN d1 b ON b.season = pb.season AND b.team_id = pb.opponent_team_id
WHERE pb.season_type IN (2, 3);

-- Team totals per game (used for team and opponent context in rate stats)
CREATE OR REPLACE TEMP TABLE tg AS
SELECT season, game_id, team_id,
    sum(minutes) AS mp, sum(field_goals_made) AS fgm, sum(field_goals_attempted) AS fga,
    sum(three_point_field_goals_attempted) AS tpa, sum(free_throws_attempted) AS fta,
    sum(offensive_rebounds) AS orb, sum(defensive_rebounds) AS drb, sum(turnovers) AS tov
FROM box
GROUP BY ALL;

-- Season box totals per player-team, with team/opponent totals over the games he played
CREATE OR REPLACE TEMP TABLE pbox AS
SELECT b.season, b.athlete_id, b.team_id,
    arg_max(b.athlete_display_name, b.game_date) AS name,
    arg_max(b.team_location, b.game_date) AS team,
    count(*) AS g, sum(b.starter::INT) AS gs, sum(b.minutes) AS mp,
    sum(b.points) AS pts, sum(b.field_goals_made) AS fgm, sum(b.field_goals_attempted) AS fga,
    sum(b.three_point_field_goals_made) AS tpm, sum(b.three_point_field_goals_attempted) AS tpa,
    sum(b.free_throws_made) AS ftm, sum(b.free_throws_attempted) AS fta,
    sum(b.offensive_rebounds) AS orb, sum(b.defensive_rebounds) AS drb,
    sum(b.assists) AS ast, sum(b.steals) AS stl, sum(b.blocks) AS blk,
    sum(b.turnovers) AS tov, sum(b.fouls) AS pf,
    sum(t.mp) AS t_mp, sum(t.fgm) AS t_fgm, sum(t.fga) AS t_fga, sum(t.fta) AS t_fta,
    sum(t.tov) AS t_tov, sum(t.orb) AS t_orb, sum(t.drb) AS t_drb,
    sum(o.fga) AS o_fga, sum(o.tpa) AS o_tpa, sum(o.orb) AS o_orb, sum(o.drb) AS o_drb,
    sum(o.fga - o.orb + o.tov + 0.475 * o.fta) AS o_poss
FROM box b
JOIN tg t ON t.season = b.season AND t.game_id = b.game_id AND t.team_id = b.team_id
JOIN tg o ON o.season = b.season AND o.game_id = b.game_id AND o.team_id = b.opponent_team_id
WHERE NOT coalesce(b.did_not_play, false) AND b.minutes > 0
GROUP BY b.season, b.athlete_id, b.team_id;

-- Field goal attempts from PBP, with zone labels
CREATE OR REPLACE TEMP TABLE shots AS
WITH s AS (
    SELECT season, game_id, team_id, athlete_id_1 AS pid, athlete_id_2 AS ast_id,
        scoring_play AS made, score_value AS pv,
        CASE WHEN type_text IN ('LayUpShot', 'DunkShot', 'TipShot') THEN 'rim' END AS rimtype,
        coordinate_x_raw AS x, coordinate_y_raw AS y,
        CASE WHEN coordinate_x_raw BETWEEN 0 AND 50 AND coordinate_y_raw BETWEEN -6 AND 94
                  AND NOT (type_text = 'JumpShot' AND coordinate_x_raw = 25 AND coordinate_y_raw = 0)
             THEN sqrt(pow(coordinate_x_raw - 25, 2) + pow(coordinate_y_raw - 2, 2)) END AS d
    FROM read_parquet('raw/shots_*.parquet', union_by_name = true)
    WHERE type_text <> 'MadeFreeThrow' AND athlete_id_1 IS NOT NULL
      AND game_id IN (SELECT DISTINCT game_id FROM box)
)
SELECT *,
    -- drop locations that contradict ESPN's own 2/3 label (placeholder coords)
    CASE WHEN (pv = 3 AND d < 18) OR (pv = 2 AND d > 23) THEN NULL ELSE d END AS dist,
    CASE WHEN pv = 3 THEN 'three' WHEN rimtype = 'rim' THEN 'rim' ELSE 'j2' END AS zone
FROM s;

-- Long form: one row per player-team-zone. A shot counts in its zone plus its band.
CREATE OR REPLACE TEMP TABLE zlong AS
WITH tagged AS (
    SELECT season, pid, team_id, made, ast_id,
        list_filter([
            'fg', zone,
            CASE WHEN dist IS NOT NULL THEN 'loc' END,
            CASE WHEN zone = 'j2' AND dist IS NOT NULL THEN 'j2loc' END,
            CASE WHEN zone = 'j2' AND dist < 8 THEN 'close2'
                 WHEN zone = 'j2' AND dist < 16 THEN 'mid2'
                 WHEN zone = 'j2' AND dist >= 16 THEN 'far2' END,
            CASE WHEN zone = 'three' AND dist IS NOT NULL THEN 'threeloc' END,
            CASE WHEN zone = 'three' AND dist IS NOT NULL AND abs(x - 25) >= 20 AND y <= 7 THEN 'c3'
                 WHEN zone = 'three' AND dist IS NOT NULL THEN 'ab3' END
        ], lambda z: z IS NOT NULL) AS zones
    FROM shots
)
SELECT season, pid, team_id, z,
    count(*) AS a,
    sum(made::INT) AS m,
    sum((made AND ast_id IS NULL)::INT) AS um,
    round(100.0 * sum(made::INT) / count(*), 1) AS pct,
    round(100.0 * sum((made AND ast_id IS NULL)::INT) / nullif(sum(made::INT), 0), 1) AS unast
FROM tagged, unnest(zones) AS t(z)
GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE zwide AS
PIVOT zlong ON z IN ('fg', 'rim', 'j2', 'close2', 'mid2', 'far2', 'three', 'c3', 'ab3', 'loc', 'j2loc', 'threeloc')
USING first(a) AS a, first(m) AS m, first(um) AS um, first(pct) AS pct, first(unast) AS unast
GROUP BY season, pid, team_id;

-- Passer side: what kind of shots does a player's assists create?
CREATE OR REPLACE TEMP TABLE astz AS
SELECT season, ast_id AS pid, team_id,
    count(*) AS ast_pbp,
    round(100.0 * count(*) FILTER (zone = 'rim') / count(*), 1) AS ast_rim_shr,
    round(100.0 * count(*) FILTER (zone = 'j2') / count(*), 1) AS ast_j2_shr,
    round(100.0 * count(*) FILTER (zone = 'three') / count(*), 1) AS ast_three_shr
FROM shots
WHERE made AND ast_id IS NOT NULL
GROUP BY ALL;

-- Roster info (2025+ only in the source)
CREATE OR REPLACE TEMP TABLE ros AS
SELECT season, athlete_id::INT AS athlete_id,
    any_value(CASE experience_display_value
        WHEN 'Freshman' THEN 'Fr' WHEN 'Sophomore' THEN 'So'
        WHEN 'Junior' THEN 'Jr' WHEN 'Senior' THEN 'Sr' END) AS cls,
    any_value(position_abbreviation) AS pos,
    any_value(TRY_CAST(regexp_extract(height, '(\d+)''', 1) AS INT) * 12
        + TRY_CAST(regexp_extract(height, '(\d+)"', 1) AS INT)) AS ht
FROM read_parquet('raw/rosters_*.parquet', union_by_name = true)
GROUP BY ALL;

CREATE OR REPLACE TABLE players AS
SELECT
    p.athlete_id AS id, p.season, p.name, p.team, d1.conf,
    r.cls, r.pos, r.ht,
    p.g, p.gs,
    round(p.mp / p.g, 1) AS mpg,
    round(100.0 * p.mp / (p.t_mp / 5), 1) AS min_pct,
    round(p.pts / p.g, 1) AS ppg,
    round((p.orb + p.drb) / p.g, 1) AS rpg,
    round(p.ast / p.g, 1) AS apg,

    -- efficiency / usage (Basketball-Reference style, using team & opp totals from games played)
    round(100.0 * (p.fga + 0.44 * p.fta + p.tov) * (p.t_mp / 5)
        / nullif(p.mp * (p.t_fga + 0.44 * p.t_fta + p.t_tov), 0), 1) AS usg,
    round(100.0 * p.pts / nullif(2 * (p.fga + 0.44 * p.fta), 0), 1) AS ts,
    round(100.0 * (p.fgm + 0.5 * p.tpm) / nullif(p.fga, 0), 1) AS efg,
    round(100.0 * p.ast / nullif((p.mp / (p.t_mp / 5)) * p.t_fgm - p.fgm, 0), 1) AS ast_pct,
    round(100.0 * p.tov / nullif(p.fga + 0.44 * p.fta + p.tov, 0), 1) AS to_pct,
    round(p.ast / nullif(p.tov, 0), 2) AS ast_to,
    round(100.0 * p.orb * (p.t_mp / 5) / nullif(p.mp * (p.t_orb + p.o_drb), 0), 1) AS or_pct,
    round(100.0 * p.drb * (p.t_mp / 5) / nullif(p.mp * (p.t_drb + p.o_orb), 0), 1) AS dr_pct,
    round(100.0 * p.stl * (p.t_mp / 5) / nullif(p.mp * p.o_poss, 0), 1) AS stl_pct,
    round(100.0 * p.blk * (p.t_mp / 5) / nullif(p.mp * (p.o_fga - p.o_tpa), 0), 1) AS blk_pct,
    round(100.0 * p.fta / nullif(p.fga, 0), 1) AS ftr,
    round(100.0 * p.tpa / nullif(p.fga, 0), 1) AS tpr,
    round(100.0 * p.ftm / nullif(p.fta, 0), 1) AS ft_pct,
    round(100.0 * (p.fgm - p.tpm) / nullif(p.fga - p.tpa, 0), 1) AS fg2_pct,
    round(100.0 * p.tpm / nullif(p.tpa, 0), 1) AS fg3_pct,
    round(40.0 * p.pts / p.mp, 1) AS pts40,
    round(40.0 * (p.orb + p.drb) / p.mp, 1) AS reb40,
    round(40.0 * p.ast / p.mp, 1) AS ast40,
    round(40.0 * p.stl / p.mp, 1) AS stl40,
    round(40.0 * p.blk / p.mp, 1) AS blk40,
    round(40.0 * p.pf / p.mp, 1) AS pf40,
    round(40.0 * p.fta / p.mp, 1) AS fta40,
    p.fga, p.tpa, p.fta, p.pts, p.ast, p.tov, p.stl, p.blk, p.orb, p.drb,

    -- PBP shot profile
    z.fg_a AS pbp_fga,
    z.fg_unast AS unast,
    round(100.0 * coalesce(z.loc_a, 0) / nullif(z.fg_a, 0), 1) AS loc_cov,
    coalesce(z.rim_a, 0) AS rim_a, coalesce(z.rim_m, 0) AS rim_m, z.rim_pct, z.rim_unast,
    round(100.0 * coalesce(z.rim_a, 0) / nullif(z.fg_a, 0), 1) AS rim_rate,
    round(40.0 * coalesce(z.rim_um, 0) / p.mp, 2) AS rim_um40,
    coalesce(z.j2_a, 0) AS j2_a, coalesce(z.j2_m, 0) AS j2_m, z.j2_pct, z.j2_unast,
    round(100.0 * coalesce(z.j2_a, 0) / nullif(z.fg_a, 0), 1) AS j2_rate,
    round(40.0 * coalesce(z.j2_um, 0) / p.mp, 2) AS j2_um40,
    coalesce(z.three_a, 0) AS three_a, coalesce(z.three_m, 0) AS three_m, z.three_pct, z.three_unast,
    round(100.0 * coalesce(z.three_a, 0) / nullif(z.fg_a, 0), 1) AS three_rate,
    round(40.0 * coalesce(z.three_um, 0) / p.mp, 2) AS three_um40,

    -- distance bands (rate = estimated share of ALL FGA, scaled up from located shots)
    coalesce(z.close2_a, 0) AS close2_a, z.close2_pct, z.close2_unast,
    round(100.0 * coalesce(z.close2_a, 0) / nullif(z.j2loc_a, 0) * z.j2_a / nullif(z.fg_a, 0), 1) AS close2_rate,
    coalesce(z.mid2_a, 0) AS mid2_a, z.mid2_pct, z.mid2_unast,
    round(100.0 * coalesce(z.mid2_a, 0) / nullif(z.j2loc_a, 0) * z.j2_a / nullif(z.fg_a, 0), 1) AS mid2_rate,
    coalesce(z.far2_a, 0) AS far2_a, z.far2_pct, z.far2_unast,
    round(100.0 * coalesce(z.far2_a, 0) / nullif(z.j2loc_a, 0) * z.j2_a / nullif(z.fg_a, 0), 1) AS far2_rate,
    coalesce(z.c3_a, 0) AS c3_a, z.c3_pct, z.c3_unast,
    round(100.0 * coalesce(z.c3_a, 0) / nullif(z.threeloc_a, 0), 1) AS c3_shr,
    coalesce(z.ab3_a, 0) AS ab3_a, z.ab3_pct, z.ab3_unast,

    -- passing
    a.ast_rim_shr, a.ast_j2_shr, a.ast_three_shr
FROM pbox p
JOIN d1 ON d1.season = p.season AND d1.team_id = p.team_id
LEFT JOIN ros r ON r.season = p.season AND r.athlete_id = p.athlete_id
LEFT JOIN zwide z ON z.season = p.season AND z.pid = p.athlete_id AND z.team_id = p.team_id
LEFT JOIN astz a ON a.season = p.season AND a.pid = p.athlete_id AND a.team_id = p.team_id
WHERE p.mp > 0;

COPY players TO 'site/data/players.parquet' (FORMAT parquet, COMPRESSION zstd);

SELECT season, count(*) AS players, round(avg(loc_cov), 1) AS avg_loc_cov FROM players GROUP BY 1 ORDER BY 1;
