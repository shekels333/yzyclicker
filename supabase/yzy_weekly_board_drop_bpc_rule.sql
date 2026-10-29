-- Weekly board view still filtered score/clicks <= 2e9 (rule dropped elsewhere in f5ba20f).
-- Long-term generator-heavy players (e.g. SHEKELS ~1.6e11 bars/click) were hidden.
create or replace view public.yzy_weekly_board as
 select username, score, clicks, current_era, twitter_handle, updated_at
   from public.yzy_weekly
  where week_start = public.yzy_week_start()
    and score > 0
    and not (score > 1e12 and clicks < 5000);
