-- YEEZY CLICKER leaderboard integrity (C1, C2, C3, M2, M3 + catalog/trigger revokes).
-- Every public RPC keeps its exact signature, so the live client works before and after deploy.
-- Idempotent: safe to re-run.

-- ── New bookkeeping columns ──────────────────────────────────────────────
alter table public.yzy_names       add column if not exists last_submit_at timestamptz;
alter table public.yzy_names       add column if not exists last_total     numeric;
alter table public.yzy_leaderboard add column if not exists prestige_at    timestamptz;

-- ── Helpers (internal, not callable by clients) ──────────────────────────
-- C3: the one canonical spelling of a claimed name.
create or replace function public.yzy__canon(p text) returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select display_name from public.yzy_names where username_key = public.yzy_name_key(p)),
                  upper(btrim(coalesce(p, '')))) $$;

-- M2: allowed characters for newly claimed / renamed names (matches the client sanitizer).
create or replace function public.yzy__name_ok(p text) returns boolean
language sql immutable set search_path to 'public' as $$
  select coalesce(btrim(p) ~ '^[A-Za-z0-9_.\- ]{2,24}$', false) $$;

-- C2: highest prestige lifetime bars can justify. Every prestige needs a fresh run of >= 33T
-- (Trillionbear) and earns >= 1 plaque, plaques = floor(4*sqrt(banked/33T)), banked <= lifetime.
create or replace function public.yzy__prestige_floor(tb numeric) returns integer
language sql immutable set search_path to 'public' as $$
  select least(100,
               floor(greatest(coalesce(tb, 0), 0) / 33e12),
               floor(4 * sqrt(greatest(coalesce(tb, 0), 0) / 33e12) + 1e-9))::int $$;

-- C2: +1 per call at most, never above what the board total justifies, and at most one step
-- per 60 s. (33T of new bars needs >= 82.5 s under the 4e14/s server rate cap, so a legit
-- prestige can never arrive faster than that; 60 s never blocks a real player.)
create or replace function public.yzy__set_prestige(u text, p integer) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if p is null then return; end if;
  update public.yzy_leaderboard
     set prestige = coalesce(prestige, 0) + 1, prestige_at = now()
   where username = u
     and least(greatest(p, 0), 100) > coalesce(prestige, 0)
     and coalesce(prestige, 0) < public.yzy__prestige_floor(total_bars)
     and (prestige_at is null or prestige_at <= now() - interval '60 seconds');
end $$;

-- C1: only a real 33T board total counts as reaching Trillionbear (prestige alone no longer does).
create or replace function public.yzy__log_trillionbear() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(new.total_bars, 0) >= 33e12 then
    insert into public.yzy_trillionbear_firsts(username, reached_at, total_bars, prestige, twitter_handle)
    values (new.username, now(), new.total_bars, new.prestige, new.twitter_handle)
    on conflict (username) do nothing;
  end if;
  return new;
end $$;

-- M2: new claims must use the allowed charset (existing names still authenticate).
create or replace function public.yzy__auth(p_username text, p_secret text, p_claim boolean default true) returns text
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare k text; h text; r public.yzy_names%rowtype;
begin
  if p_username is null or length(btrim(p_username)) < 2 or length(p_username) > 24 then return 'bad'; end if;
  if p_secret is null or p_secret !~ '^[0-9a-f]{64}$' then return 'bad'; end if;
  k := public.yzy_name_key(p_username);
  h := encode(extensions.digest(p_secret, 'sha256'), 'hex');
  select * into r from public.yzy_names where username_key = k;
  if found then return case when r.secret_hash = h then 'ok' else 'taken' end; end if;
  if not p_claim then return 'free'; end if;
  if not public.yzy__name_ok(p_username) then return 'bad'; end if;
  insert into public.yzy_names(username_key, display_name, secret_hash)
    values (k, upper(btrim(p_username)), h) on conflict do nothing;
  select * into r from public.yzy_names where username_key = k;
  return case when r.secret_hash = h then 'ok' else 'taken' end;
end $$;

-- ── Write RPCs: all keyed by the canonical display_name (C3) ─────────────
create or replace function public.yzy_lb_submit(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric,
  p_era text default null, p_twitter text default null, p_prestige integer default null) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
  u text; n public.yzy_names%rowtype; r public.yzy_leaderboard%rowtype; secs numeric;
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
    -- No board row (new, or deleted): allowance runs from the last submit/delete, not the claim date.
    secs := extract(epoch from (now() - coalesce(n.last_submit_at, n.created_at, now())));
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
end $$;

create or replace function public.yzy_weekly_submit_v2(p_username text, p_secret text, p_total_bars numeric, p_total_clicks numeric,
  p_era text default null, p_twitter text default null, p_prestige integer default null) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  return public.yzy_weekly_submit(public.yzy__canon(p_username), p_total_bars, p_total_clicks, p_era, p_twitter);
end $$;

create or replace function public.yzy_save_get(p_username text, p_secret text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, true); s public.yzy_saves%rowtype;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  select * into s from public.yzy_saves where username = public.yzy__canon(p_username);
  if not found then return json_build_object('ok', true, 'save_data', null); end if;
  return json_build_object('ok', true, 'save_data', s.save_data, 'saved_at', s.saved_at);
end $$;

create or replace function public.yzy_save_put(p_username text, p_secret text, p_save_data text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, true);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  if p_save_data is null or length(p_save_data) > 200000 then return json_build_object('ok', false, 'reason', 'size'); end if;
  insert into public.yzy_saves(username, save_data, saved_at) values (public.yzy__canon(p_username), p_save_data, now())
    on conflict (username) do update set save_data = excluded.save_data, saved_at = excluded.saved_at;
  return json_build_object('ok', true);
end $$;

create or replace function public.yzy_cosmetics_get(p_username text, p_secret text) returns json
language plpgsql stable security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false);
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  return public.yzy__cosmetics_state(public.yzy__canon(p_username));
end $$;

create or replace function public.yzy_cosmetic_buy(p_username text, p_secret text, p_item text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text;
  c public.yzy_cosmetics_catalog%rowtype; pr int; bal int;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  u := public.yzy__canon(p_username);
  select * into c from public.yzy_cosmetics_catalog where item_id = p_item;
  if not found then return json_build_object('ok', false, 'reason', 'item'); end if;
  select least(100, coalesce(prestige, 0)) into pr from public.yzy_leaderboard where username = u for update;
  if not found then return json_build_object('ok', false, 'reason', 'no-board'); end if;
  if exists (select 1 from public.yzy_cosmetics_owned where username = u and item_id = p_item) then
    return public.yzy__cosmetics_state(u)::jsonb || '{"already":true}'::jsonb;
  end if;
  bal := pr - coalesce((select sum(price) from public.yzy_cosmetics_owned where username = u), 0);
  if c.price > bal then return json_build_object('ok', false, 'reason', 'funds', 'balance', bal); end if;
  insert into public.yzy_cosmetics_owned(username, item_id, price) values (u, p_item, c.price);
  return public.yzy__cosmetics_state(u);
end $$;

create or replace function public.yzy_cosmetic_equip(p_username text, p_secret text, p_kind text, p_item text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text;
  c public.yzy_cosmetics_catalog%rowtype;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  u := public.yzy__canon(p_username);
  if p_kind not in ('fx','frame') then return json_build_object('ok', false, 'reason', 'kind'); end if;
  if p_item is not null then
    select * into c from public.yzy_cosmetics_catalog where item_id = p_item and kind = p_kind;
    if not found then return json_build_object('ok', false, 'reason', 'item'); end if;
    if c.price > 0 and not exists (select 1 from public.yzy_cosmetics_owned where username = u and item_id = p_item) then
      return json_build_object('ok', false, 'reason', 'not-owned');
    end if;
  end if;
  if p_kind = 'fx' then update public.yzy_leaderboard set name_fx = p_item where username = u;
  else update public.yzy_leaderboard set frame = p_item where username = u; end if;
  if not found then return json_build_object('ok', false, 'reason', 'no-board'); end if;
  return public.yzy__cosmetics_state(u);
end $$;

create or replace function public.yzy_contest_place(p_username text, p_secret text) returns integer
language plpgsql stable security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text; r integer;
begin
  if a <> 'ok' then return null; end if;
  u := public.yzy__canon(p_username);
  select t.place into r from (
    select username, row_number() over (order by reached_at asc, username asc)::int as place
    from public.yzy_trillionbear_firsts where username not like 'ZZ%'
    order by reached_at asc, username asc limit 5) t
  where t.username = u;
  return r;
end $$;

create or replace function public.yzy_flag_report(p_username text, p_secret text, p_flagged integer, p_details jsonb default null) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  u := public.yzy__canon(p_username);
  if coalesce(p_flagged, 0) <= 0 then return json_build_object('ok', true); end if;
  if exists (select 1 from public.yzy_flags where username = u and created_at > now() - interval '1 minute') then
    return json_build_object('ok', true, 'throttled', true);
  end if;
  insert into public.yzy_flags(username, reason, details)
    values (u, 'client', jsonb_build_object('flagged', least(p_flagged, 100000),
      'reasons', case when jsonb_typeof(p_details) = 'object' and length(p_details::text) < 500 then p_details else null end));
  return json_build_object('ok', true);
end $$;

-- Delete keeps the claim (unless released) and restarts the rate allowance from now,
-- so a resubmit right after a delete gets no free "since claim date" allowance.
create or replace function public.yzy_delete(p_username text, p_secret text, p_release boolean default false) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  u := public.yzy__canon(p_username);
  delete from public.yzy_saves where username = u;
  delete from public.yzy_leaderboard where username = u;   -- trigger also clears owned cosmetics
  delete from public.yzy_weekly where username = u;
  if p_release then delete from public.yzy_names where username_key = public.yzy_name_key(p_username);
  else update public.yzy_names set last_submit_at = now(), last_total = 0 where username_key = public.yzy_name_key(p_username); end if;
  return json_build_object('ok', true);
end $$;

-- M2 + M3 + C3: rename checks the charset, uses the canonical old name, and moves
-- every per-name table (saves, board, weekly, owned cosmetics, Trillionbear entry, flags).
create or replace function public.yzy_rename(p_old text, p_new text, p_secret text) returns json
language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare a text; ko text; kn text; o text; n text; h text; r public.yzy_names%rowtype; old_r public.yzy_names%rowtype;
begin
  if p_new is null or length(btrim(p_new)) < 2 or length(p_new) > 24 or p_secret is null or p_secret !~ '^[0-9a-f]{64}$' then
    return json_build_object('ok', false, 'reason', 'bad'); end if;
  if not public.yzy__name_ok(p_new) then return json_build_object('ok', false, 'reason', 'bad'); end if;
  ko := public.yzy_name_key(p_old); kn := public.yzy_name_key(p_new);
  n := upper(btrim(p_new));
  h := encode(extensions.digest(p_secret,'sha256'),'hex');
  a := public.yzy__auth(p_old, p_secret, false);
  if kn <> ko or a <> 'ok' then
    select * into r from public.yzy_names where username_key = kn;
    if found and r.secret_hash <> h then return json_build_object('ok', false, 'reason', 'taken'); end if;
    if not found and public.yzy__has_data(kn) then return json_build_object('ok', false, 'reason', 'taken'); end if;
  end if;
  if a <> 'ok' then
    return json_build_object('ok', public.yzy__auth(p_new, p_secret, true) = 'ok', 'moved', false);
  end if;
  select * into old_r from public.yzy_names where username_key = ko for update;
  o := old_r.display_name;
  if kn <> ko then
    insert into public.yzy_names(username_key, display_name, secret_hash, created_at, last_submit_at, last_total)
      values (kn, n, h, old_r.created_at, old_r.last_submit_at, old_r.last_total)
      on conflict (username_key) do update set display_name = excluded.display_name,
        last_submit_at = greatest(public.yzy_names.last_submit_at, excluded.last_submit_at);
    delete from public.yzy_names where username_key = ko;
  else
    update public.yzy_names set display_name = n where username_key = ko;
  end if;
  if n <> o then
    delete from public.yzy_saves where username = n;
    update public.yzy_saves set username = n where username = o;
    delete from public.yzy_leaderboard where username = n;
    delete from public.yzy_cosmetics_owned where username = n;
    update public.yzy_leaderboard set username = n where username = o;
    update public.yzy_cosmetics_owned set username = n where username = o;
    delete from public.yzy_weekly w where w.username = n and exists(select 1 from public.yzy_weekly x where x.username = o and x.week_start = w.week_start);
    update public.yzy_weekly set username = n where username = o;
    delete from public.yzy_trillionbear_firsts f where f.username = n and exists(select 1 from public.yzy_trillionbear_firsts x where x.username = o);
    update public.yzy_trillionbear_firsts set username = n where username = o;
    update public.yzy_flags set username = n where username = o;
  end if;
  return json_build_object('ok', true, 'moved', true);
end $$;

-- ── Privileges ───────────────────────────────────────────────────────────
revoke all on function public.yzy__canon(text) from public, anon, authenticated;
revoke all on function public.yzy__name_ok(text) from public, anon, authenticated;
revoke all on function public.yzy__prestige_floor(numeric) from public, anon, authenticated;
revoke all on function public.yzy__set_prestige(text, integer) from public, anon, authenticated;
revoke all on function public.yzy__log_trillionbear() from public, anon, authenticated;
revoke all on function public.yzy__auth(text, text, boolean) from public, anon, authenticated;
revoke all on function public.yzy__cosmetics_on_lb_delete() from public, anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.yzy_cosmetics_catalog from anon, authenticated;
