-- Replace the MBDTF profile frame (fr_mbdtf) with the neon "Glow" frame (fr_glow), same price 6.
-- NOT YET APPLIED — apply after approval. RPCs validate against the catalog, so no function changes needed.
-- At authoring time (2026-10-30): 0 players own fr_mbdtf, 0 have it equipped.
begin;
insert into public.yzy_cosmetics_catalog(item_id, kind, price) values ('fr_glow','frame',6)
  on conflict (item_id) do update set kind = excluded.kind, price = excluded.price;
-- Move ownership (keep the price they paid); skip anyone who somehow already owns fr_glow.
insert into public.yzy_cosmetics_owned(username, item_id, price, bought_at)
  select username, 'fr_glow', price, bought_at from public.yzy_cosmetics_owned where item_id = 'fr_mbdtf'
  on conflict (username, item_id) do nothing;
delete from public.yzy_cosmetics_owned where item_id = 'fr_mbdtf';
update public.yzy_leaderboard set frame = 'fr_glow' where frame = 'fr_mbdtf';
delete from public.yzy_cosmetics_catalog where item_id = 'fr_mbdtf';
commit;
notify pgrst, 'reload schema';
