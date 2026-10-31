-- Auto-clicker timeout (server side).
-- A name whose client reported machine-exact clicking (interval CV < 0.035 over 40 clicks,
-- reported as reasons.strong_d = new strong trips since the last report) in >= 12 separate
-- flag reports (throttled to 1/min, so >= 12 different minutes) totalling >= 24 strong trips
-- within the last 30 minutes is timed out: 5 min, then 15, then 60 for repeats within 24h.
-- While timed out, board + weekly submits are rejected ('timeout'); the board row is kept.
-- After a timeout the rate allowance restarts at its end, so bars "earned" during it can't be
-- banked by a hacked client. Timeouts are stored as yzy_flags rows (reason 'timeout'), so a
-- rename carries them along with the other flags.
-- Calibration (live, 2026-10-31): legit max in any 30 min = 4 reports / 7 trips (SLIM J);
-- AGENT M peak = 17 reports / 34 trips.

create or replace function public.yzy__timeout_until(u text) returns timestamptz
language plpgsql security definer set search_path to 'public' as $$
declare last_until timestamptz; rows_n int; trips int; strikes int; mins int; t timestamptz;
begin
  select max((details->>'until')::timestamptz) into last_until
    from public.yzy_flags where username = u and reason = 'timeout';
  if last_until > now() then return last_until; end if;
  select count(*), coalesce(sum(least((details->'reasons'->>'strong_d')::int, 50)), 0) into rows_n, trips
    from public.yzy_flags
   where username = u and reason = 'client'
     and created_at > greatest(now() - interval '30 minutes', coalesce(last_until, '-infinity'::timestamptz))
     and jsonb_typeof(details->'reasons'->'strong_d') = 'number' and (details->'reasons'->>'strong_d')::numeric >= 1;
  if rows_n < 12 or trips < 24 then return null; end if;
  select count(*) into strikes from public.yzy_flags
   where username = u and reason = 'timeout' and created_at > now() - interval '24 hours';
  mins := case when strikes = 0 then 5 when strikes = 1 then 15 else 60 end;
  t := now() + make_interval(mins => mins);
  insert into public.yzy_flags(username, reason, details)
    values (u, 'timeout', jsonb_build_object('until', t, 'minutes', mins, 'strike', strikes + 1, 'reports', rows_n, 'trips', trips));
  return t;
end $$;
revoke all on function public.yzy__timeout_until(text) from public, anon, authenticated;

create or replace function public.yzy__last_timeout_end(u text) returns timestamptz
language sql stable security definer set search_path to 'public' as $$
  select max((details->>'until')::timestamptz) from public.yzy_flags where username = u and reason = 'timeout'
$$;
revoke all on function public.yzy__last_timeout_end(text) from public, anon, authenticated;

-- Read-only status for the client (so a reload shows the remaining time).
create or replace function public.yzy_timeout_status(p_username text, p_secret text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); t timestamptz;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  t := public.yzy__timeout_until(public.yzy__canon(p_username));
  return json_build_object('ok', true, 'until', t, 'secs', greatest(0, ceil(extract(epoch from (t - now())))));
end $$;
revoke all on function public.yzy_timeout_status(text, text) from public;
grant execute on function public.yzy_timeout_status(text, text) to anon, authenticated;

create or replace function public.yzy_weekly_submit_v2(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric, p_era text DEFAULT NULL::text, p_twitter text DEFAULT NULL::text, p_prestige integer DEFAULT NULL::integer)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare a text := public.yzy__auth(p_username, p_secret, true); t timestamptz;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  t := public.yzy__timeout_until(public.yzy__canon(p_username));
  if t is not null then return json_build_object('ok', false, 'reason', 'timeout', 'until', t); end if;
  return public.yzy_weekly_submit(public.yzy__canon(p_username), p_total_bars, p_total_clicks, p_era, p_twitter);
end $function$;

create or replace function public.yzy_lb_submit(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric, p_era text DEFAULT NULL::text, p_twitter text DEFAULT NULL::text, p_prestige integer DEFAULT NULL::integer)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare a text := public.yzy__auth(p_username, p_secret, true);
  u text; n public.yzy_names%rowtype; r public.yzy_leaderboard%rowtype; secs numeric; tu timestamptz; te timestamptz;
  pb numeric := floor(p_total_bars); pc numeric := floor(p_total_clicks);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if pb is null or pc is null or pb < 0 or pc < 0
     or pb > public.yzy__season_cap() or pc > 50000000
     or (pb > 1000000000000 and pc < 5000) then
    return json_build_object('ok', false, 'reason', 'range');
  end if;
  select * into n from public.yzy_names where username_key = public.yzy_name_key(p_username) for update;
  u := n.display_name;
  tu := public.yzy__timeout_until(u);
  if tu is not null then return json_build_object('ok', false, 'reason', 'timeout', 'until', tu); end if;
  te := coalesce(public.yzy__last_timeout_end(u), '-infinity'::timestamptz);
  select * into r from public.yzy_leaderboard where username = u for update;
  if found then
    if pb <= r.total_bars then
      perform public.yzy__set_prestige(u, p_prestige);
      return json_build_object('ok', true, 'kept', true);
    end if;
    secs := extract(epoch from (now() - greatest(r.submitted_at, te)));
    if pc - r.total_clicks > public.yzy__max_click_gain(secs) then
      perform public.yzy__flag_clicks(u, 'lb_click_cap', pc - r.total_clicks, secs);
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
    if pb - r.total_bars > public.yzy__max_gain(secs) then
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
  else
    secs := extract(epoch from (now() - greatest(coalesce(n.last_submit_at, n.created_at, now()), te)));
    if pc > public.yzy__max_click_gain(secs) then
      perform public.yzy__flag_clicks(u, 'lb_click_cap', pc, secs);
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
    if pb > public.yzy__max_gain(secs) then
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
  end if;
  insert into public.yzy_leaderboard(username, total_bars, total_clicks, era, twitter_handle, submitted_at)
    values (u, pb, pc, left(p_era, 64), left(p_twitter, 15), now())
    on conflict (username) do update set total_bars = excluded.total_bars, total_clicks = excluded.total_clicks,
      era = excluded.era, twitter_handle = excluded.twitter_handle, submitted_at = excluded.submitted_at;
  update public.yzy_names set last_submit_at = now(), last_total = pb where username_key = n.username_key;
  perform public.yzy__set_prestige(u, p_prestige);
  return json_build_object('ok', true);
end $function$;
