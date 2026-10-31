-- One Gold Plaque per prestige: the board's prestige ceiling is simply one level per 33T of lifetime bars.
-- The old floor(4*sqrt(bars/33T)) cap (from yzy_integrity) would block a legit player who prestiges
-- at ~33T every run once they pass 16 prestiges (n*33T lifetime -> floor(4*sqrt(n)) < n for n > 16).
-- The +1-per-submit and 60 s gate in yzy__set_prestige are unchanged.
create or replace function public.yzy__prestige_floor(tb numeric) returns integer
language sql immutable set search_path to 'public' as $$
  select least(100, floor(greatest(coalesce(tb, 0), 0) / 33e12))::int $$;
revoke all on function public.yzy__prestige_floor(numeric) from public, anon, authenticated;
