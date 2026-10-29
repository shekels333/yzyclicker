-- Follow-up to yzy_season_cap_rate_guard: the table check still had the old 50T cap and 2e9 ratio.
alter table public.yzy_leaderboard drop constraint if exists yzy_leaderboard_sane_scores;
alter table public.yzy_leaderboard add constraint yzy_leaderboard_sane_scores check (
  total_bars >= 0 and total_clicks >= 0 and total_bars <= 1.5e21 and total_clicks <= 50000000
  and not (total_bars > 1000000000000 and total_clicks < 5000));
