-- Anti-bot: server click-rate cap + private review table. DO NOT APPLY without approval.
-- Built on live definitions (2026-10-30). Only changes: click cap 75/s+500 -> 20/s+300,
-- yzy_flags logging on click-cap trips, new yzy_flag_report RPC. Bars cap (yzy__max_gain) unchanged.
begin;

create table if not exists public.yzy_flags (
  id bigserial primary key,
  username text not null,
  reason text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists yzy_flags_user_idx on public.yzy_flags (username, created_at desc);
alter table public.yzy_flags enable row level security;   -- no policies: anon/authenticated see nothing
revoke all on public.yzy_flags from anon, authenticated;
revoke all on sequence public.yzy_flags_id_seq from anon, authenticated;

-- Click cap: 20 clicks per elapsed second + 300 burst (was 75/s + 500). Used by yzy_lb_submit and yzy_weekly_submit.
create or replace function public.yzy__max_click_gain(secs numeric)
 returns numeric language sql immutable
as $function$ select 20 * greatest(secs, 0) + 300 $function$;

-- Client-reported flags (pattern/untrusted clicks). Throttled to 1 row/min/user, values clamped.
create or replace function public.yzy_flag_report(p_username text, p_secret text, p_flagged integer, p_details jsonb default null)
 returns json language plpgsql security definer set search_path to 'public'
as $function$
declare a text := public.yzy__auth(p_username, p_secret, false); u text := upper(btrim(p_username));
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if coalesce(p_flagged, 0) <= 0 then return json_build_object('ok', true); end if;
  if exists (select 1 from public.yzy_flags where username = u and created_at > now() - interval '1 minute') then
    return json_build_object('ok', true, 'throttled', true);
  end if;
  insert into public.yzy_flags(username, reason, details)
    values (u, 'client', jsonb_build_object('flagged', least(p_flagged, 100000),
      'reasons', case when jsonb_typeof(p_details) = 'object' and length(p_details::text) < 500 then p_details else null end));
  return json_build_object('ok', true);
end $function$;
revoke all on function public.yzy_flag_report(text, text, integer, jsonb) from public;
grant execute on function public.yzy_flag_report(text, text, integer, jsonb) to anon, authenticated;

create or replace function public.yzy__flag_clicks(u text, src text, dc numeric, secs numeric)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
begin
  if exists (select 1 from public.yzy_flags where username = u and reason = src and created_at > now() - interval '1 minute') then return; end if;
  insert into public.yzy_flags(username, reason, details)
    values (u, src, jsonb_build_object('clicks', dc, 'secs', round(secs, 1), 'cap', public.yzy__max_click_gain(secs)));
end $function$;
revoke all on function public.yzy__flag_clicks(text, text, numeric, numeric) from public, anon, authenticated;

-- yzy_lb_submit: identical to live, plus a yzy_flags row when the click cap rejects.
CREATE OR REPLACE FUNCTION public.yzy_lb_submit(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric, p_era text DEFAULT NULL::text, p_twitter text DEFAULT NULL::text, p_prestige integer DEFAULT NULL::integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    if pc - r.total_clicks > public.yzy__max_click_gain(secs) then
      perform public.yzy__flag_clicks(u, 'lb_click_cap', pc - r.total_clicks, secs);
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
    if pb - r.total_bars > public.yzy__max_gain(secs) then
      return json_build_object('ok', false, 'reason', 'rate');
    end if;
  else
    select created_at into since from public.yzy_names where username_key = public.yzy_name_key(p_username);
    secs := extract(epoch from (now() - coalesce(since, now())));
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
  perform public.yzy__set_prestige(u, p_prestige);
  return json_build_object('ok', true);
end $function$;

-- yzy_weekly_submit: identical to live, plus a yzy_flags row when the click cap forces a rebaseline.
CREATE OR REPLACE FUNCTION public.yzy_weekly_submit(p_username text, p_total_bars numeric, p_total_clicks numeric, p_era text DEFAULT NULL::text, p_twitter text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if dc > public.yzy__max_click_gain(secs) then
    perform public.yzy__flag_clicks(p_username, 'weekly_click_cap', dc, secs);
  end if;
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

commit;
notify pgrst, 'reload schema';
