-- Cap prestige at ★1. A player still needs one 33T run, still gains at most +1 per
-- submit, and still waits 60s between steps (prestige_at). The bar floor used to be
-- least(100, floor(total_bars/33T)); it is now least(1, floor(total_bars/33T)).
-- YzY Tokens are earned from prestige, so they cap at 1 as well.
-- Any row already above 1 is pulled down to 1. Not applied to the live project by this file.
begin;

create or replace function public.yzy__prestige_floor(tb numeric) returns integer
language sql immutable set search_path to 'public' as $$
  select least(1, floor(greatest(coalesce(tb, 0), 0) / 33e12))::int $$;
revoke all on function public.yzy__prestige_floor(numeric) from public, anon, authenticated;

-- +1 per qualifying submit, never past the floor, at most once per 60s.
-- A row that is already above ★1 is clamped to 1 and does not take another step.
create or replace function public.yzy__set_prestige(u text, p integer) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.yzy_leaderboard
     set prestige = 1
   where username = u
     and prestige > 1;
  if p is null then return; end if;
  update public.yzy_leaderboard
     set prestige = coalesce(prestige, 0) + 1, prestige_at = now()
   where username = u
     and least(greatest(p, 0), 1) > coalesce(prestige, 0)
     and coalesce(prestige, 0) < public.yzy__prestige_floor(total_bars)
     and (prestige_at is null or prestige_at <= now() - interval '60 seconds');
end $$;
revoke all on function public.yzy__set_prestige(text, integer) from public, anon, authenticated;

-- Token budget follows the same cap. Owned items are left as they are.
create or replace function public.yzy__cosmetics_state(u text) returns json
language sql stable security definer set search_path to 'public' as $$
  select json_build_object('ok', true,
    'earned', least(1, coalesce(l.prestige, 0)),
    'spent',  coalesce((select sum(price) from public.yzy_cosmetics_owned o where o.username = u), 0),
    'balance', least(1, coalesce(l.prestige, 0)) - coalesce((select sum(price) from public.yzy_cosmetics_owned o where o.username = u), 0),
    'owned',  coalesce((select json_agg(item_id order by item_id) from public.yzy_cosmetics_owned o where o.username = u), '[]'::json),
    'name_fx', l.name_fx, 'frame', l.frame, 'prestige', least(1, coalesce(l.prestige, 0)))
  from (select 1) d left join public.yzy_leaderboard l on l.username = u
$$;
revoke all on function public.yzy__cosmetics_state(text) from public, anon, authenticated;

create or replace function public.yzy_cosmetic_buy(p_username text, p_secret text, p_item text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare a text := public.yzy__auth(p_username, p_secret, false); u text;
  c public.yzy_cosmetics_catalog%rowtype; pr int; bal int;
begin
  if a <> 'ok' then return json_build_object('ok', false, 'reason', a); end if;
  u := public.yzy__canon(p_username);
  select * into c from public.yzy_cosmetics_catalog where item_id = p_item;
  if not found then return json_build_object('ok', false, 'reason', 'item'); end if;
  select least(1, coalesce(prestige, 0)) into pr from public.yzy_leaderboard where username = u for update;
  if not found then return json_build_object('ok', false, 'reason', 'no-board'); end if;
  if exists (select 1 from public.yzy_cosmetics_owned where username = u and item_id = p_item) then
    return public.yzy__cosmetics_state(u)::jsonb || '{"already":true}'::jsonb;
  end if;
  bal := pr - coalesce((select sum(price) from public.yzy_cosmetics_owned where username = u), 0);
  if c.price > bal then return json_build_object('ok', false, 'reason', 'funds', 'balance', bal); end if;
  insert into public.yzy_cosmetics_owned(username, item_id, price) values (u, p_item, c.price);
  return public.yzy__cosmetics_state(u);
end $$;

update public.yzy_leaderboard
   set prestige = least(1, greatest(prestige, 0))
 where prestige is not null and (prestige < 0 or prestige > 1);

alter table public.yzy_leaderboard drop constraint if exists yzy_leaderboard_prestige_cap;
alter table public.yzy_leaderboard add constraint yzy_leaderboard_prestige_cap
  check (prestige is null or prestige between 0 and 1);

commit;
notify pgrst, 'reload schema';
