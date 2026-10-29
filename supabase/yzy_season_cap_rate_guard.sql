-- Season cap 1.5e21, drop the 2e9 bars-per-click rule, add a rate-of-gain guard.
-- Max income (all 17 gens x 250 owned, every upgrade + fashion): 2.605e14 b/s gens + 4.41e11 b/s clicks (50/s, era bonus).
-- Max rate used by the guard: 1.5 x max = 4e14 b/s, plus offline bump 0.5 x 2.61e14 x min(elapsed, 8h).
-- No data is deleted. total_bars widens from bigint to numeric (1.5e21 > bigint max).

create or replace function public.yzy__season_cap() returns numeric language sql immutable as $$ select 1.5e21::numeric $$;
create or replace function public.yzy__max_gain(secs numeric) returns numeric language sql immutable as $$
  select 4e14 * greatest(secs, 0) + 0.5 * 2.61e14 * least(greatest(secs, 0), 28800) + 1e9 $$;
create or replace function public.yzy__max_click_gain(secs numeric) returns numeric language sql immutable as $$
  select 75 * greatest(secs, 0) + 500 $$;
revoke all on function public.yzy__season_cap(), public.yzy__max_gain(numeric), public.yzy__max_click_gain(numeric) from public, anon, authenticated;

alter table public.yzy_leaderboard alter column total_bars type numeric using total_bars::numeric;

drop function if exists public.yzy_lb_submit(text, text, bigint, bigint, text, text);
create or replace function public.yzy_lb_submit(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric,
  p_era text default null, p_twitter text default null)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare a text := public.yzy__auth(p_username, p_secret, true);
  u text := upper(btrim(p_username)); r public.yzy_leaderboard%rowtype; since timestamptz; secs numeric;
  pb numeric := floor(p_total_bars); pc numeric := floor(p_total_clicks);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if pb is null or pc is null or pb < 0 or pc < 0
     or pb > public.yzy__season_cap() or pc > 50000000
     or (pb > 1000000000000 and pc < 5000) then
    return json_build_object('ok', false, 'reason', 'range');
  end if;
  select * into r from public.yzy_leaderboard where username = u for update;
  if found then
    if pb <= r.total_bars then return json_build_object('ok', true, 'kept', true); end if;
    secs := extract(epoch from (now() - r.submitted_at));
    if pb - r.total_bars > public.yzy__max_gain(secs)
       or pc - r.total_clicks > public.yzy__max_click_gain(secs) then
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
  else
    select created_at into since from public.yzy_names where username_key = public.yzy_name_key(p_username);
    secs := extract(epoch from (now() - coalesce(since, now())));
    if pb > public.yzy__max_gain(secs) or pc > public.yzy__max_click_gain(secs) then
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
  end if;
  insert into public.yzy_leaderboard(username, total_bars, total_clicks, era, twitter_handle, submitted_at)
    values (u, pb, pc, left(p_era, 64), left(p_twitter, 15), now())
    on conflict (username) do update set total_bars = excluded.total_bars, total_clicks = excluded.total_clicks,
      era = excluded.era, twitter_handle = excluded.twitter_handle, submitted_at = excluded.submitted_at;
  return json_build_object('ok', true);
end $function$;
revoke all on function public.yzy_lb_submit(text, text, numeric, numeric, text, text) from public;
grant execute on function public.yzy_lb_submit(text, text, numeric, numeric, text, text) to anon, authenticated;

create or replace function public.yzy_weekly_submit(p_username text, p_total_bars numeric, p_total_clicks numeric, p_era text default null, p_twitter text default null)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare
  ws date := public.yzy_week_start();
  r public.yzy_weekly%rowtype;
  secs numeric; db numeric; dc numeric; need numeric;
begin
  if p_username is null or length(p_username) < 2 or length(p_username) > 24 then return json_build_object('ok',false,'reason','name'); end if;
  if p_total_bars is null or p_total_clicks is null or p_total_bars < 0 or p_total_clicks < 0
     or p_total_bars > public.yzy__season_cap() or p_total_clicks > 5e7 then return json_build_object('ok',false,'reason','range'); end if;
  select * into r from public.yzy_weekly where username = p_username and week_start = ws for update;
  if not found then
    insert into public.yzy_weekly(username, week_start, start_total, clicks_start, last_total, last_clicks, current_era, twitter_handle)
    values (p_username, ws, p_total_bars, p_total_clicks, p_total_bars, p_total_clicks, p_era, p_twitter);
    return json_build_object('ok',true,'score',0,'clicks',0,'need_clicks',0,'baseline',true);
  end if;
  secs := extract(epoch from (now() - r.updated_at));
  if secs < 15 then return json_build_object('ok',false,'reason','throttle','score',r.score,'clicks',r.clicks); end if;
  db := p_total_bars - r.last_total;
  dc := p_total_clicks - r.last_clicks;
  if db < 0 or dc < 0 or db > public.yzy__max_gain(secs) or dc > public.yzy__max_click_gain(secs) then
    update public.yzy_weekly set banked = r.score, banked_clicks = r.clicks,
      start_total = p_total_bars, clicks_start = p_total_clicks,
      last_total = p_total_bars, last_clicks = p_total_clicks,
      current_era = coalesce(p_era, current_era), twitter_handle = coalesce(p_twitter, twitter_handle), updated_at = now()
      where username = p_username and week_start = ws;
    return json_build_object('ok',true,'score',r.score,'clicks',r.clicks,'rebaselined',true);
  end if;
  r.score := least(r.banked + (p_total_bars - r.start_total), p_total_bars);
  r.clicks := least(r.banked_clicks + (p_total_clicks - r.clicks_start), p_total_clicks);
  update public.yzy_weekly set score = r.score, clicks = r.clicks, last_total = p_total_bars, last_clicks = p_total_clicks,
    current_era = coalesce(p_era, current_era), twitter_handle = coalesce(p_twitter, twitter_handle), updated_at = now()
    where username = p_username and week_start = ws;
  need := greatest(case when r.score > 1e12 then 5000 - r.clicks else 0 end, 0);
  return json_build_object('ok',true,'score',r.score,'clicks',r.clicks,'need_clicks',need);
end $function$;
revoke all on function public.yzy_weekly_submit(text, numeric, numeric, text, text) from public, anon, authenticated;
