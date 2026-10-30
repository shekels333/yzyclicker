-- Prestige: nullable prestige level on the board, optional p_prestige on submit RPCs.
-- Old clients (no p_prestige) keep working: the param defaults to null = leave as is.
begin;
alter table public.yzy_leaderboard add column if not exists prestige int;

-- Sanity: 0..500, never decreases, rises at most +3 per accepted submit.
create or replace function public.yzy__set_prestige(u text, p int)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if p is null then return; end if;
  update public.yzy_leaderboard
     set prestige = greatest(coalesce(prestige, 0), least(greatest(p, 0), 500, coalesce(prestige, 0) + 3))
   where username = u;
end $$;
revoke all on function public.yzy__set_prestige(text, int) from public, anon, authenticated;

drop function if exists public.yzy_lb_submit(text, text, numeric, numeric, text, text);
create function public.yzy_lb_submit(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric,
  p_era text default null, p_twitter text default null, p_prestige int default null)
 returns json language plpgsql security definer set search_path to 'public'
as $function$
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
    if pb <= r.total_bars then
      perform public.yzy__set_prestige(u, p_prestige);
      return json_build_object('ok', true, 'kept', true);
    end if;
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
  perform public.yzy__set_prestige(u, p_prestige);
  return json_build_object('ok', true);
end $function$;
revoke all on function public.yzy_lb_submit(text, text, numeric, numeric, text, text, int) from public;
grant execute on function public.yzy_lb_submit(text, text, numeric, numeric, text, text, int) to anon, authenticated, service_role;

drop function if exists public.yzy_weekly_submit_v2(text, text, numeric, numeric, text, text);
create function public.yzy_weekly_submit_v2(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric,
  p_era text default null, p_twitter text default null, p_prestige int default null)
 returns json language plpgsql security definer set search_path to 'public'
as $function$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  -- prestige lives on yzy_leaderboard (set by yzy_lb_submit); accepted here for API symmetry.
  return public.yzy_weekly_submit(upper(btrim(p_username)), p_total_bars, p_total_clicks, p_era, p_twitter);
end $function$;
grant execute on function public.yzy_weekly_submit_v2(text, text, numeric, numeric, text, text, int) to public, anon, authenticated, service_role;

create or replace view public.yzy_weekly_board as
  select w.username, w.score, w.clicks, w.current_era, w.twitter_handle, w.updated_at, l.prestige
    from public.yzy_weekly w left join public.yzy_leaderboard l on l.username = w.username
   where w.week_start = public.yzy_week_start() and w.score > 0 and not (w.score > 1e12 and w.clicks < 5000);
grant select on public.yzy_weekly_board to anon, authenticated;
commit;
notify pgrst, 'reload schema';
