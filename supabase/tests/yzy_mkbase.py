import re
txt=open('/workspace/live_dump.txt').read()
blocks=re.split(r'^===== (.*)$',txt,flags=re.M)[1:]
fn=[];trg=[];con=[];view=''
for h,b in zip(blocks[::2],blocks[1::2]):
    b=b.strip()
    if h.startswith('TRG'): trg.append(b)
    elif h.startswith('CON'): con.append(b)
    elif h=='VIEW': view=b+';'
    else: fn.append(b)
pre='''
set check_function_bodies=off;
do $$begin create role anon nologin; exception when others then null; end$$;
do $$begin create role authenticated nologin; exception when others then null; end$$;
create schema extensions; create extension pgcrypto schema extensions;
create table yzy_cosmetics_catalog(item_id text primary key, kind text not null, price integer not null);
create table yzy_cosmetics_owned(username text not null, item_id text not null, price integer not null, bought_at timestamptz not null default now(), primary key(username,item_id));
create table yzy_flags(id bigserial primary key, username text not null, reason text not null, details jsonb not null default '{}', created_at timestamptz not null default now());
create index yzy_flags_user_idx on yzy_flags(username, created_at desc);
create table yzy_leaderboard(username text primary key, total_bars numeric default 0, total_clicks bigint default 0, era text, submitted_at timestamptz default now(), twitter_handle text, prestige integer, name_fx text, frame text);
create table yzy_names(username_key text primary key, display_name text not null, secret_hash text not null, created_at timestamptz not null default now());
create table yzy_saves(username text primary key, save_data text not null, saved_at timestamptz);
create table yzy_trillionbear_firsts(username text primary key, reached_at timestamptz not null default now(), total_bars numeric, prestige integer, twitter_handle text, notified_at timestamptz);
create table yzy_weekly(username text not null, week_start date not null, start_total numeric not null, clicks_start numeric not null, banked numeric not null default 0, banked_clicks numeric not null default 0, last_total numeric not null, last_clicks numeric not null, score numeric not null default 0, clicks numeric not null default 0, current_era text, twitter_handle text, updated_at timestamptz not null default now(), primary key(username,week_start));
insert into yzy_cosmetics_catalog values ('fx_cream','fx',0),('fx_gold','fx',1),('fx_silver','fx',1),('fx_red','fx',2),('fx_sunset','fx',3),('fx_glow','fx',4),('fx_shimmer','fx',6),('fx_glitch','fx',8),('fx_rainbow','fx',12),('fr_concrete','frame',0),('fr_gold','frame',2),('fr_808','frame',4),('fr_yeezus','frame',9),('fr_trillion','frame',15),('fr_glow','frame',6);
'''
post='''
grant usage on schema public to anon, authenticated;
grant all on yzy_cosmetics_catalog to anon, authenticated;
alter table yzy_cosmetics_catalog enable row level security;
create policy cat_read on yzy_cosmetics_catalog for select using (true);
grant select on yzy_leaderboard, yzy_weekly, yzy_weekly_board to anon, authenticated;
do $$declare f record; begin for f in select p.oid::regprocedure s from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'yzy\\_\\_%' and p.proname<>'yzy__cosmetics_on_lb_delete' loop execute 'revoke execute on function '||f.s||' from public'; end loop; end$$;
revoke execute on function yzy_weekly_submit(text,numeric,numeric,text,text) from public;
grant execute on all functions in schema public to anon, authenticated;
do $$declare f record; begin for f in select p.oid::regprocedure s from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and (p.proname like 'yzy\\_\\_%' and p.proname<>'yzy__cosmetics_on_lb_delete' or p.proname='yzy_weekly_submit') loop execute 'revoke execute on function '||f.s||' from anon, authenticated'; end loop; end$$;
'''
open('base.sql','w').write(pre+'\n'.join(fn)+'\n'+'\n'.join(trg)+'\n'+'\n'.join(con)+'\n'+view+'\n'+post)
