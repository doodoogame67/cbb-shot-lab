-- Builds the per-season game-level files the site aggregates in the browser.
-- Run from the project root:  duckdb -c ".read pipeline/build.sql"
--
-- Output (one folder per season, hive-style):
--   site/data/teams/season=YYYY/part0.csv    tid, team, conf, rank
--   site/data/players/season=YYYY/part0.csv  pid, name, ht, wt, cls, age, st, pos, dy, dp
--   site/data/tgames/season=YYYY/part0.csv   one row per team-game: box totals + date/venue/conf flag/opponent
--   site/data/pgames/season=YYYY/part0.csv   one row per player-game: box line + play-by-play shot zones
--   site/data/seasons.csv                    season list with data-quality notes
--
-- Scope matches Barttorvik: D1 vs D1 games, regular season + postseason.
--
-- Shot zones (play-by-play; ESPN labels changed over the years, both spellings handled)
--   rim (Bart's "Close 2") = layups, dunks, tips;  j2 (Bart's "Far 2") = every other 2;  3 = threes
--   distance bands need shot coordinates: lt8 / mid (8-16ft) / long (16ft+) 2s, corner vs above-break 3s
-- "Unassisted" counts made shots with no assist credited (PBP only records assists on makes).

-- ---------- teams ----------
CREATE OR REPLACE TEMP TABLE d1 AS
SELECT season, team_id::INT AS team_id,
    CASE replace(conference_id, 'mbb:', '')
        WHEN 'acc' THEN 'ACC' WHEN 'big-ten' THEN 'B10' WHEN 'big-12' THEN 'B12'
        WHEN 'big-east' THEN 'BE' WHEN 'sec' THEN 'SEC' WHEN 'pac-12' THEN 'P12' WHEN 'pac-10' THEN 'P10'
        WHEN 'american' THEN 'Amer' WHEN 'atlantic-10' THEN 'A10' WHEN 'mountain-west' THEN 'MWC'
        WHEN 'wcc' THEN 'WCC' WHEN 'mvc' THEN 'MVC' WHEN 'cusa' THEN 'CUSA'
        WHEN 'sun-belt' THEN 'SB' WHEN 'mac' THEN 'MAC' WHEN 'caa' THEN 'CAA'
        WHEN 'big-west' THEN 'BW' WHEN 'big-sky' THEN 'BSky' WHEN 'big-south' THEN 'BSth'
        WHEN 'horizon' THEN 'Horz' WHEN 'ivy' THEN 'Ivy' WHEN 'maac' THEN 'MAAC'
        WHEN 'meac' THEN 'MEAC' WHEN 'nec' THEN 'NEC' WHEN 'ovc' THEN 'OVC'
        WHEN 'patriot' THEN 'Pat' WHEN 'socon' THEN 'SC' WHEN 'southland' THEN 'Slnd'
        WHEN 'summit' THEN 'Sum' WHEN 'swac' THEN 'SWAC' WHEN 'wac' THEN 'WAC'
        WHEN 'asun' THEN 'ASun' WHEN 'america-east' THEN 'AE' WHEN 'independents' THEN 'ind'
        WHEN 'great-west' THEN 'GWC'
        ELSE upper(replace(conference_id, 'mbb:', ''))
    END AS conf
FROM 'raw/mbb_team_group_seasons.parquet'
WHERE subdivision_id = 'mbb:d1';

CREATE OR REPLACE TEMP TABLE ratings AS
SELECT season::INT AS season, team_id::INT AS team_id, rank::INT AS rank
FROM read_parquet('raw/mbb_ratings_*.parquet', union_by_name = true);

-- ---------- box score rows from D1 vs D1 games ----------
CREATE OR REPLACE TEMP TABLE box AS
SELECT pb.*
FROM read_parquet('raw/player_box_*.parquet', union_by_name = true) pb
JOIN d1 a ON a.season = pb.season AND a.team_id = pb.team_id
JOIN d1 b ON b.season = pb.season AND b.team_id = pb.opponent_team_id
WHERE pb.season_type IN (2, 3);

CREATE OR REPLACE TEMP TABLE sched AS
SELECT DISTINCT ON (game_id) game_id, coalesce(neutral_site, false) AS neutral,
    coalesce(conference_competition, false) AS conf_game
FROM read_parquet('raw/mbb_schedule_*.parquet', union_by_name = true);

-- team names: most recent display per season
CREATE OR REPLACE TEMP TABLE tnames AS
SELECT season, team_id, arg_max(team_location, game_date) AS team
FROM box GROUP BY ALL;

-- ---------- team-game totals ----------
CREATE OR REPLACE TEMP TABLE tg AS
SELECT b.season, b.game_id, b.team_id,
    any_value(b.opponent_team_id) AS opp,
    strftime(any_value(b.game_date), '%Y%m%d')::INT AS dt,
    CASE WHEN any_value(s.neutral) THEN 0 WHEN any_value(b.home_away) = 'home' THEN 1 ELSE -1 END AS loc,
    any_value(s.conf_game)::INT AS cg,
    round(sum(b.minutes))::INT AS min,
    sum(b.field_goals_made) AS fgm, sum(b.field_goals_attempted) AS fga,
    sum(b.three_point_field_goals_made) AS tpm, sum(b.three_point_field_goals_attempted) AS tpa,
    sum(b.free_throws_made) AS ftm, sum(b.free_throws_attempted) AS fta,
    sum(b.offensive_rebounds) AS orb, sum(b.defensive_rebounds) AS drb,
    sum(b.assists) AS ast, sum(b.turnovers) AS tov, sum(b.steals) AS stl,
    sum(b.blocks) AS blk, sum(b.fouls) AS pf, sum(b.points) AS pts
FROM box b
LEFT JOIN sched s ON s.game_id = b.game_id
GROUP BY b.season, b.game_id, b.team_id
-- drop games with broken box scores (no minutes recorded)
HAVING sum(b.minutes) >= 150;

-- ---------- play-by-play shots ----------
CREATE OR REPLACE TEMP TABLE shots AS
WITH s AS (
    SELECT game_id, team_id, athlete_id_1 AS pid, athlete_id_2 AS ast_id,
        coalesce(scoring_play, false) AS made,
        (score_value = 3 OR type_text = 'Three Point Jump Shot') AS is3,
        type_text IN ('LayUpShot', 'LayupShot', 'DunkShot', 'TipShot') AS rimtype,
        type_text = 'DunkShot' AS dunk,
        coordinate_x_raw AS x, coordinate_y_raw AS y,
        CASE WHEN coordinate_x_raw BETWEEN 0 AND 50 AND coordinate_y_raw BETWEEN -6 AND 94
                  AND NOT (type_text = 'JumpShot' AND coordinate_x_raw = 25 AND coordinate_y_raw = 0)
             THEN sqrt(pow(coordinate_x_raw - 25, 2) + pow(coordinate_y_raw - 2, 2)) END AS d
    FROM read_parquet('raw/shots_*.parquet', union_by_name = true)
    WHERE type_text IN ('JumpShot', 'LayUpShot', 'LayupShot', 'DunkShot', 'TipShot', 'Three Point Jump Shot', 'Shot')
      AND athlete_id_1 IS NOT NULL
      AND game_id IN (SELECT game_id FROM tg)
)
SELECT *,
    CASE WHEN is3 THEN 'three' WHEN rimtype THEN 'rim' ELSE 'j2' END AS zone,
    -- drop locations that contradict the 2/3 label (placeholder coordinates)
    CASE WHEN (is3 AND d < 18) OR (NOT is3 AND d > 23) THEN NULL ELSE d END AS dist
FROM s;

CREATE OR REPLACE TEMP TABLE pbp_games AS SELECT DISTINCT game_id FROM shots;

CREATE OR REPLACE TEMP TABLE shotpg AS
SELECT game_id, team_id, pid,
    count(*) FILTER (zone = 'rim' AND made) AS rm, count(*) FILTER (zone = 'rim') AS ra,
    count(*) FILTER (zone = 'rim' AND made AND ast_id IS NULL) AS rum,
    count(*) FILTER (dunk AND made) AS dm, count(*) FILTER (dunk) AS da,
    count(*) FILTER (zone = 'j2' AND made) AS jm, count(*) FILTER (zone = 'j2') AS ja,
    count(*) FILTER (zone = 'j2' AND made AND ast_id IS NULL) AS jum,
    count(*) FILTER (zone = 'three' AND made) AS t3m, count(*) FILTER (zone = 'three') AS t3a,
    count(*) FILTER (zone = 'three' AND made AND ast_id IS NULL) AS t3um,
    count(*) FILTER (dist IS NOT NULL) AS lf,
    count(*) FILTER (zone = 'j2' AND dist IS NOT NULL) AS jl,
    count(*) FILTER (zone = 'three' AND dist IS NOT NULL) AS tl,
    count(*) FILTER (zone = 'j2' AND dist < 8 AND made) AS sm, count(*) FILTER (zone = 'j2' AND dist < 8) AS sa,
    count(*) FILTER (zone = 'j2' AND dist >= 8 AND dist < 16 AND made) AS mm,
    count(*) FILTER (zone = 'j2' AND dist >= 8 AND dist < 16) AS ma,
    count(*) FILTER (zone = 'j2' AND dist >= 8 AND dist < 16 AND made AND ast_id IS NULL) AS mum,
    count(*) FILTER (zone = 'j2' AND dist >= 16 AND made) AS lm, count(*) FILTER (zone = 'j2' AND dist >= 16) AS la,
    count(*) FILTER (zone = 'j2' AND dist >= 16 AND made AND ast_id IS NULL) AS lum,
    count(*) FILTER (zone = 'three' AND dist IS NOT NULL AND abs(x - 25) >= 20 AND y <= 7 AND made) AS cm,
    count(*) FILTER (zone = 'three' AND dist IS NOT NULL AND abs(x - 25) >= 20 AND y <= 7) AS ca,
    count(*) FILTER (zone = 'three' AND dist IS NOT NULL AND NOT (abs(x - 25) >= 20 AND y <= 7) AND made) AS bm,
    count(*) FILTER (zone = 'three' AND dist IS NOT NULL AND NOT (abs(x - 25) >= 20 AND y <= 7)) AS ba
FROM shots
GROUP BY ALL;

-- passer side: assists by the zone of the shot they created
CREATE OR REPLACE TEMP TABLE astpg AS
SELECT game_id, team_id, ast_id AS pid,
    count(*) FILTER (zone = 'rim') AS ar, count(*) FILTER (zone = 'j2') AS aj, count(*) FILTER (zone = 'three') AS a3
FROM shots WHERE made AND ast_id IS NOT NULL
GROUP BY ALL;

-- ---------- player-game rows ----------
CREATE OR REPLACE TEMP TABLE pg AS
SELECT b.season, b.athlete_id AS pid, b.game_id AS gid, b.team_id AS tid,
    coalesce(b.starter, false)::INT AS gs, round(b.minutes)::INT AS min,
    b.field_goals_made AS fgm, b.field_goals_attempted AS fga,
    b.three_point_field_goals_made AS tpm, b.three_point_field_goals_attempted AS tpa,
    b.free_throws_made AS ftm, b.free_throws_attempted AS fta,
    b.offensive_rebounds AS orb, b.defensive_rebounds AS drb, b.assists AS ast,
    b.turnovers AS tov, b.steals AS stl, b.blocks AS blk, b.fouls AS pf, b.points AS pts,
    (p.game_id IS NOT NULL)::INT AS pbp,
    s.rm, s.ra, s.rum, s.dm, s.da, s.jm, s.ja, s.jum, s.t3m, s.t3a, s.t3um,
    s.lf, s.jl, s.tl, s.sm, s.sa, s.mm, s.ma, s.mum, s.lm, s.la, s.lum, s.cm, s.ca, s.bm, s.ba,
    a.ar, a.aj, a.a3
FROM box b
JOIN tg t ON t.game_id = b.game_id AND t.team_id = b.team_id
LEFT JOIN pbp_games p ON p.game_id = b.game_id
LEFT JOIN shotpg s ON s.game_id = b.game_id AND s.team_id = b.team_id AND s.pid = b.athlete_id
LEFT JOIN astpg a ON a.game_id = b.game_id AND a.team_id = b.team_id AND a.pid = b.athlete_id
WHERE NOT coalesce(b.did_not_play, false) AND b.minutes > 0;

-- ---------- player bios ----------
-- ESPN's player_core holds each player's LATEST listing (height, weight, class, age),
-- so class per season = final class minus seasons remaining.
CREATE OR REPLACE TEMP TABLE seasons_played AS
SELECT pid, min(season) AS first_season, max(season) AS last_season FROM pg GROUP BY pid;

CREATE OR REPLACE TEMP TABLE core AS
SELECT athlete_id::INT AS pid,
    arg_max(height, season) AS ht, arg_max(weight, season) AS wt,
    arg_max(experience_years, season) AS exp,
    arg_max(TRY_CAST(left(date_of_birth, 10) AS DATE), season) AS dob,
    arg_max(birth_state, season) AS st, arg_max(position_abbreviation, season) AS pos,
    arg_max(draft_year, season) AS dy, arg_max(draft_selection, season) AS dp
FROM read_parquet('raw/player_core_*.parquet', union_by_name = true)
GROUP BY 1;

CREATE OR REPLACE TEMP TABLE bio AS
WITH ps AS (
    SELECT pg.season, pg.pid, arg_max(b.athlete_display_name, b.game_date) AS name
    FROM pg JOIN box b ON b.game_id = pg.gid AND b.athlete_id = pg.pid
    GROUP BY pg.season, pg.pid
)
SELECT ps.season, ps.pid, ps.name,
    round(c.ht)::INT AS ht, round(c.wt)::INT AS wt,
    CASE
        WHEN c.exp IS NOT NULL AND c.exp - (sp.last_season - ps.season) BETWEEN 1 AND 99
            THEN least(c.exp - (sp.last_season - ps.season), 4)
        -- no ESPN class: count seasons seen, only when the first one is not cut off by the data window
        WHEN sp.first_season > 2008 THEN least(ps.season - sp.first_season + 1, 4)
    END AS cls,
    CASE WHEN c.dob IS NOT NULL THEN round(date_diff('day', c.dob, make_date(ps.season, 2, 1)) / 365.25, 1) END AS age,
    c.st, c.pos, c.dy, c.dp
FROM ps
JOIN seasons_played sp ON sp.pid = ps.pid
LEFT JOIN core c ON c.pid = ps.pid;

-- ---------- write ----------
COPY (
    SELECT DISTINCT t.season, t.team_id AS tid, n.team, d1.conf, r.rank
    FROM tg t
    JOIN d1 ON d1.season = t.season AND d1.team_id = t.team_id
    LEFT JOIN tnames n ON n.season = t.season AND n.team_id = t.team_id
    LEFT JOIN ratings r ON r.season = t.season AND r.team_id = t.team_id
    ORDER BY t.season, tid
) TO 'site/data/teams' (FORMAT csv, HEADER, PARTITION_BY (season), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part{i}');

COPY (SELECT * FROM bio ORDER BY season, pid)
TO 'site/data/players' (FORMAT csv, HEADER, PARTITION_BY (season), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part{i}');

COPY (
    SELECT season, game_id AS gid, team_id AS tid, opp, dt, loc, cg, min,
        fgm, fga, tpm, tpa, ftm, fta, orb, drb, ast, tov, stl, blk, pf, pts
    FROM tg ORDER BY season, gid, tid
) TO 'site/data/tgames' (FORMAT csv, HEADER, PARTITION_BY (season), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part{i}');

COPY (SELECT * FROM pg ORDER BY season, gid, tid, pid)
TO 'site/data/pgames' (FORMAT csv, HEADER, PARTITION_BY (season), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part{i}');

-- season list + data-quality notes the site shows
COPY (
    WITH bx AS (SELECT season, sum(ast) AS ast, count(DISTINCT gid) AS games,
                       count(DISTINCT gid) FILTER (pbp = 1) AS pbp_games,
                       sum(ast) FILTER (pbp = 1) AS pbp_box_ast,
                       sum(coalesce(rum, 0) + coalesce(jum, 0) + coalesce(t3um, 0)) AS um,
                       sum(coalesce(rm, 0) + coalesce(jm, 0) + coalesce(t3m, 0)) AS pm,
                       sum(coalesce(ra, 0) + coalesce(ja, 0) + coalesce(t3a, 0)) AS pfga,
                       sum(coalesce(lf, 0)) AS lf
                FROM pg GROUP BY season)
    SELECT season, games,
        round(100.0 * pbp_games / games) AS pbp_pct,
        round(100.0 * (pm - um) / nullif(pbp_box_ast, 0)) AS ast_pct,
        round(100.0 * lf / nullif(pfga, 0)) AS loc_pct
    FROM bx ORDER BY season DESC
) TO 'site/data/seasons.csv' (FORMAT csv, HEADER);

SELECT * FROM 'site/data/seasons.csv';
