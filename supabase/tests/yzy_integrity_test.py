import subprocess, json, sys
DB=sys.argv[1]; res=[]
def q(sql, role=None):
    s=(f"set role {role};" if role else "")+sql
    p=subprocess.run(["psql","-h","/tmp","-p","5499","-U","postgres","-d",DB,"-tAq","-c",s],capture_output=True,text=True)
    return (p.stdout.strip() if p.returncode==0 else "ERR:"+p.stderr.strip().splitlines()[-1])
def rpc(f,*a):
    args=",".join("null" if x is None else (str(x) if isinstance(x,(int,float)) and not isinstance(x,bool) else ("true" if x is True else "false" if x is False else "'"+str(x).replace("'","''")+"'")) for x in a)
    return q(f"select {f}({args})", "anon")
def j(s):
    try: return json.loads(s)
    except: return {"raw":s}
def check(name, cond, info=""):
    res.append((name,bool(cond))); print(("PASS " if cond else "FAIL ")+name+("" if cond else "  -> "+str(info)))
def ago(table, col, secs, where): q(f"update {table} set {col}=now()-interval '{secs} seconds' where {where}")
S1="a"*64; S2="b"*64; S3="c"*64
LB=lambda n,s,b,c,p=None: j(rpc("yzy_lb_submit",n,s,b,c,"era",None,p))
row=lambda n: q(f"select total_bars||'|'||total_clicks||'|'||coalesce(prestige,0) from yzy_leaderboard where username='{n}'")
pres=lambda n: int(q(f"select coalesce(prestige,0) from yzy_leaderboard where username='{n}'") or -1)

# ── legit: claim + normal submits over time
check("claim name", j(rpc("yzy_claim_name","Shekels",S1)).get("ok"))
ago("yzy_names","created_at",600,"username_key='shekels'")
r=LB("Shekels",S1,1e9,6000,0); check("first submit after 10min", r.get("ok"), r)
for i in range(3):
    ago("yzy_leaderboard","submitted_at",60,"username='SHEKELS'")
    r=LB("shekels",S1,1e9+(i+1)*1e13,6000+(i+1)*500,0)
check("normal submits over time (lowercase spelling)", r.get("ok") and row("SHEKELS").startswith("30001000000000"), (r,row("SHEKELS")))

# ── exploit C2/C1: prestige without bars
check("C2 prestige 100 with no 33T stays 0", (LB("Shekels",S1,1e9,6000,100), pres("SHEKELS"))[1]==0, pres("SHEKELS"))
check("C1 not logged before 33T", q("select count(*) from yzy_trillionbear_firsts")=="0", q("select * from yzy_trillionbear_firsts"))
# ── legit: reach 33T -> logged; prestige 1 -> 2 at realistic pace
ago("yzy_leaderboard","submitted_at",120,"username='SHEKELS'")
r=LB("Shekels",S1,34e12,8000,0); check("reach 33T submit ok", r.get("ok"), r)
check("C1 logged at real 33T", q("select total_bars from yzy_trillionbear_firsts where username='SHEKELS'")=="34000000000000", q("select * from yzy_trillionbear_firsts"))
check("contest place 1", rpc("yzy_contest_place","Shekels",S1)=="1")
r=LB("Shekels",S1,34e12,8000,1); check("prestige 0->1 (kept path, right after prestige)", pres("SHEKELS")==1, (r,pres("SHEKELS")))
r=LB("Shekels",S1,34e12,8000,2); check("C2 prestige 2 refused without 66T", pres("SHEKELS")==1)
ago("yzy_leaderboard","submitted_at",300,"username='SHEKELS'")
r=LB("Shekels",S1,70e12,10000,1)  # second run reaching 33T again
r=LB("Shekels",S1,70e12,10000,2); check("C2 time gate: 2nd step inside 60s refused", pres("SHEKELS")==1)
ago("yzy_leaderboard","prestige_at",61,"username='SHEKELS'")
r=LB("Shekels",S1,70e12,10000,2); check("prestige 1->2 after 66T and >60s", pres("SHEKELS")==2, pres("SHEKELS"))
ago("yzy_leaderboard","prestige_at",61,"username='SHEKELS'")
r=LB("Shekels",S1,70e12,10000,5); check("C2 +1 max per event / floor caps", pres("SHEKELS")==2, pres("SHEKELS"))

# ── shop buy + equip
r=j(rpc("yzy_cosmetic_buy","shekels",S1,"fx_gold")); check("shop buy", r.get("ok") and "fx_gold" in r.get("owned",[]), r)
r=j(rpc("yzy_cosmetic_equip","SHE KELS",S1,"fx","fx_gold")); check("equip (variant spelling maps to same row)", r.get("ok") and r.get("name_fx")=="fx_gold", r)
r=j(rpc("yzy_cosmetic_buy","Shekels",S1,"fx_rainbow")); check("buy beyond tokens refused", r.get("reason")=="funds", r)

# ── C3: variant spelling cannot create a 2nd board row / fresh allowance
r=LB("SHE-KELS",S1,1e18,10500,0); check("C3 variant spelling huge jump rate-limited", r.get("reason")=="rate", r)
check("C3 only one board row", q("select count(*) from yzy_leaderboard")=="1", q("select username from yzy_leaderboard"))
rpc("yzy_save_put","she.kels",S1,"{}"); check("C3 save stored under canonical name", q("select string_agg(username,',') from yzy_saves")=="SHEKELS", q("select username from yzy_saves"))

# ── weekly submit
r=j(rpc("yzy_weekly_submit_v2","Shekels",S1,70e12,10000,"era",None,2)); check("weekly baseline", r.get("baseline"), r)
ago("yzy_weekly","updated_at",60,"username='SHEKELS'")
r=j(rpc("yzy_weekly_submit_v2","shekels",S1,71e12,10100,"era",None,2)); check("weekly progress (variant spelling same row)", r.get("ok") and float(r.get("score",0))==1e12, r)
check("weekly single row", q("select count(*) from yzy_weekly")=="1")

# ── M3: rename keeps cosmetics
r=j(rpc("yzy_rename","Shekels","YZYKING",S1)); check("rename ok", r.get("ok"), r)
c=j(rpc("yzy_cosmetics_get","YZYKING",S1)); check("M3 rename keeps cosmetics + equip", "fx_gold" in c.get("owned",[]) and c.get("name_fx")=="fx_gold" and c.get("prestige")==2, c)
check("rename moved trillionbear entry", q("select username from yzy_trillionbear_firsts")=="YZYKING")
check("rename moved weekly", q("select username from yzy_weekly")=="YZYKING")
# ── M2 charset
r=j(rpc("yzy_claim_name","ЅHEKELS",S2)); check("M2 cyrillic claim refused", r.get("reason")=="bad", r)
r=j(rpc("yzy_rename","YZYKING","YZY\u200bKING2",S1)); check("M2 rename to zero-width refused", r.get("reason")=="bad", r)
check("M2 normal punctuation ok", j(rpc("yzy_claim_name","Mr. Wes-T_1",S2)).get("ok"))

# ── delete keeps name, resubmit gets no free allowance
ago("yzy_names","created_at",86400*30,"username_key='yzyking'")
r=j(rpc("yzy_delete","yzyking",S1,False)); check("delete ok", r.get("ok"))
check("delete keeps name", q("select display_name from yzy_names where username_key='yzyking'")=="YZYKING")
r=LB("YZYKING",S1,1e17,6000,0); check("C3 resubmit after delete: no free allowance", r.get("reason")=="rate", r)
check("cosmetics cleared on delete", q("select count(*) from yzy_cosmetics_owned")=="0")
ago("yzy_names","last_submit_at",30,"username_key='yzyking'")
r=LB("YZYKING",S1,1e9,100,0); check("fresh restart after delete submits fine", r.get("ok"), r)

# ── new player, no row: allowance from claim
check("claim 2nd player", j(rpc("yzy_claim_name","SAM",S3)).get("ok"))
r=LB("SAM",S3,1e16,6000,3); check("new player huge first submit refused", r.get("reason")=="rate", r)

# ── revokes
check("anon cannot truncate catalog", q("truncate yzy_cosmetics_catalog cascade","anon").startswith("ERR"))
check("anon cannot insert catalog", q("insert into yzy_cosmetics_catalog values('x','fx',0)","anon").startswith("ERR"))
check("anon cannot update catalog", q("update yzy_cosmetics_catalog set price=0","anon") .startswith("ERR"))
check("anon can read catalog", q("select count(*) from yzy_cosmetics_catalog","anon")=="15")
check("anon cannot run trigger fn", q("select has_function_privilege('anon','yzy__cosmetics_on_lb_delete()','execute')")=="f")
check("anon cannot run internal helpers", q("select bool_or(has_function_privilege('anon',p.oid,'execute')) from pg_proc p where proname like 'yzy\\_\\_%'")=="f")
check("anon can still run public RPCs", q("select bool_and(has_function_privilege('anon',p.oid,'execute')) from pg_proc p where proname in ('yzy_lb_submit','yzy_rename','yzy_delete','yzy_save_put','yzy_cosmetic_buy','yzy_weekly_submit_v2')")=="t")
print(f"\n{sum(o for _,o in res)}/{len(res)} passed on {DB}")
