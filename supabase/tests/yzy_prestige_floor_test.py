import os, subprocess, sys
def q(db,s):
    p=subprocess.run(["psql","-h","/tmp","-p","5499","-U","postgres","-d",db,"-tAqc",s],capture_output=True,text=True)
    if p.returncode!=0:
        return "ERR:"+p.stderr.strip().replace("\n"," ")
    return p.stdout.strip()
def check(res, name, cond, info=""):
    res.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ")+name+("" if cond else "  -> "+str(info)))

def client_copy(res):
    root=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    html=open(os.path.join(root,"index.html"),encoding="utf-8").read()
    low=html.lower()
    check(res, "client PRESTIGE_MAX is 1", "const PRESTIGE_MAX = 1;" in html)
    check(res, "client does not promise ★100", "PRESTIGE_MAX = 100" not in html and "★100" not in html and "★ 100" not in html)
    check(res, "client does not promise 100 tokens", "100 yzy" not in low and "100 token" not in low)
    check(res, "shop copy states the ★1 token", "earns ${PER_PRESTIGE} YzY Token" in html and "per prestige level" not in html)
    check(res, "prestige rules state the ★1 cap", "★1 is the cap" in html)

def run(db, label):
    res=[]
    client_copy(res)
    sec="d"*64
    def sub(bars, clicks, p):
        return q(db, f"set role anon; select yzy_lb_submit('RUNNER','{sec}',{bars},{clicks},null,null,{p})")
    q(db,"delete from yzy_cosmetics_owned; delete from yzy_leaderboard; delete from yzy_names;")
    q(db, f"insert into yzy_names(username_key,display_name,secret_hash,created_at) values('runner','RUNNER',encode(extensions.digest('{sec}','sha256'),'hex'),now()-interval '1 year')")
    q(db,"insert into yzy_leaderboard(username,total_bars,total_clicks,submitted_at,prestige) values('RUNNER',0,0,now()-interval '1 day',0)")
    # Just under one 33T run: floor is 0, so a claim of 1 does not move.
    # 5000 clicks needs ~4 min under the 20/s click cap; 5 min is inside that cap and the bar cap.
    q(db,"update yzy_leaderboard set submitted_at=now()-interval '5 minutes', prestige_at=null, prestige=0, total_bars=0, total_clicks=0 where username='RUNNER'")
    r=sub("33e12 - 1", 5000, 1)
    check(res, f"{label}: under-33T submit accepted", '"ok" : true' in r or '"ok": true' in r, r)
    check(res, f"{label}: under 33T stays 0", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="0", q(db,"select prestige,total_bars from yzy_leaderboard"))
    # The next bar crosses 33T. prestige_at is still null, so the single +1 step is allowed.
    r=sub("33e12", 5000, 1)
    check(res, f"{label}: 33T submit accepted", '"ok" : true' in r or '"ok": true' in r, r)
    check(res, f"{label}: 33T allows 0→1", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="1", q(db,"select prestige,total_bars from yzy_leaderboard"))
    # Second run, gate open, still cannot reach 2. Same click total so only the bar gain is checked.
    q(db,"update yzy_leaderboard set submitted_at=now()-interval '2 minutes', prestige_at=now()-interval '2 minutes' where username='RUNNER'")
    r=sub("66e12", 5000, 2)
    check(res, f"{label}: 66T submit accepted", '"ok" : true' in r or '"ok": true' in r, r)
    check(res, f"{label}: second prestige stays 1", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="1", q(db,"select prestige from yzy_leaderboard"))
    # 60s gate still blocks the first step.
    q(db,"update yzy_leaderboard set prestige=0, total_bars=66e12, total_clicks=8000, prestige_at=now(), submitted_at=now()-interval '2 minutes' where username='RUNNER'")
    sub("66e12", 8000, 1)
    check(res, f"{label}: 60s gate holds 0", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="0", q(db,"select prestige from yzy_leaderboard"))
    q(db,"update yzy_leaderboard set prestige_at=now()-interval '2 minutes' where username='RUNNER'")
    sub("66e12", 8000, 1)
    check(res, f"{label}: 60s gate then 0→1", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="1")
    # Huge lifetime total. 1e21 needs ~29 days under the 4e14/s gain cap; backdate, don't touch the cap.
    q(db,"update yzy_leaderboard set prestige=0, total_bars=0, total_clicks=0, submitted_at=now()-interval '40 days', prestige_at=null where username='RUNNER'")
    sub("1e21", 5000, 100)
    check(res, f"{label}: 1e21 bars caps at 1", q(db,"select prestige::text||'|'||total_bars::text from yzy_leaderboard where username='RUNNER'")=="1|1000000000000000000000", q(db,"select prestige,total_bars from yzy_leaderboard"))
    q(db,"update yzy_leaderboard set prestige_at=now()-interval '2 minutes' where username='RUNNER'")
    sub("1e21", 5000, 100)
    check(res, f"{label}: second claim at 1e21 stays 1", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="1")
    # Floor itself never returns more than 1.
    check(res, f"{label}: floor(0)=0", q(db,"select yzy__prestige_floor(0)")=="0")
    check(res, f"{label}: floor(33T-1)=0", q(db,"select yzy__prestige_floor(33e12 - 1)")=="0")
    check(res, f"{label}: floor(33T)=1", q(db,"select yzy__prestige_floor(33e12)")=="1")
    check(res, f"{label}: floor(1e21)=1", q(db,"select yzy__prestige_floor(1e21)")=="1")
    # Setter clamps a stray row above 1; tokens follow the cap even before the column moves.
    q(db,"alter table yzy_leaderboard drop constraint yzy_leaderboard_prestige_cap")
    q(db,"update yzy_leaderboard set prestige=5, prestige_at=now() where username='RUNNER'")
    st=q(db,"select yzy__cosmetics_state('RUNNER')::jsonb->>'earned' || '|' || (yzy__cosmetics_state('RUNNER')::jsonb->>'prestige')")
    check(res, f"{label}: tokens cap at 1 while row is 5", st=="1|1", st)
    sub("1e21", 5000, 1)
    check(res, f"{label}: setter clamps 5 down to 1", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="1", q(db,"select prestige from yzy_leaderboard"))
    q(db,"alter table yzy_leaderboard add constraint yzy_leaderboard_prestige_cap check (prestige is null or prestige between 0 and 1)")
    bad=q(db,"update yzy_leaderboard set prestige=2 where username='RUNNER'")
    check(res, f"{label}: constraint rejects prestige 2", bad.startswith("ERR") and "yzy_leaderboard_prestige_cap" in bad, bad)
    check(res, f"{label}: row still 1 after rejected write", q(db,"select prestige from yzy_leaderboard where username='RUNNER'")=="1")
    # One token buys a 1-price effect and refuses a 2-price effect.
    q(db,"delete from yzy_cosmetics_owned where username='RUNNER'")
    bought=q(db, f"set role anon; select yzy_cosmetic_buy('RUNNER','{sec}','fx_gold')")
    check(res, f"{label}: 1 token buys fx_gold", "fx_gold" in bought and "funds" not in bought, bought)
    refused=q(db, f"set role anon; select yzy_cosmetic_buy('RUNNER','{sec}','fx_red')")
    check(res, f"{label}: 2-price item refused at ★1", "funds" in refused, refused)
    q(db,"delete from yzy_cosmetics_owned where username='RUNNER'; delete from yzy_trillionbear_firsts where username='RUNNER'; delete from yzy_leaderboard where username='RUNNER'; delete from yzy_names where username_key='runner';")
    n=sum(1 for _,ok in res if ok)
    print(f"\n{n}/{len(res)} passed on {db}")
    return n==len(res)

if __name__=="__main__":
    ok=run(sys.argv[1], sys.argv[2] if len(sys.argv)>2 else sys.argv[1])
    sys.exit(0 if ok else 1)
