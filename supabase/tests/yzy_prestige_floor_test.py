import subprocess,sys
def q(db,s): return subprocess.run(["psql","-h","/tmp","-p","5499","-U","postgres","-d",db,"-tAqc",s],capture_output=True,text=True).stdout.strip()
def run(db,label):
    q(db,"delete from yzy_leaderboard; delete from yzy_names;")
    q(db,"insert into yzy_names values('runner','RUNNER',encode(extensions.digest('"+"d"*64+"','sha256'),'hex'),now()-interval '1 year')")
    q(db,"insert into yzy_leaderboard(username,total_bars,total_clicks,submitted_at,prestige) values('RUNNER',0,0,now()-interval '1 day',0)")
    lvl=0; stuck=None
    for n in range(1,101):
        tb=n*33.5e12; clicks=5000+n*1000
        q(db,f"update yzy_leaderboard set submitted_at=now()-interval '1 hour', prestige_at=now()-interval '2 minutes' where username='RUNNER'")
        q(db,f"set role anon; select yzy_lb_submit('RUNNER','{'d'*64}',{tb},{clicks},null,null,{n-1})")  # reach 33T this run
        q(db,f"update yzy_leaderboard set prestige_at=now()-interval '2 minutes' where username='RUNNER'")
        q(db,f"set role anon; select yzy_lb_submit('RUNNER','{'d'*64}',{tb},{clicks},null,null,{n})")   # prestige
        lvl=int(q(db,"select prestige from yzy_leaderboard where username='RUNNER'"))
        if lvl!=n and stuck is None: stuck=(n,lvl)
    print(f"{label}: final prestige {lvl}/100, first blocked at {stuck}")
    # exploit still blocked: prestige 100 claim with only 2*33T
    q(db,"update yzy_leaderboard set prestige=0,total_bars=66e12,prestige_at=null where username='RUNNER'")
    for i in range(5):
        q(db,"update yzy_leaderboard set prestige_at=now()-interval '2 minutes' where username='RUNNER'")
        q(db,f"set role anon; select yzy_lb_submit('RUNNER','{'d'*64}',66e12,200000,null,null,100)")
    print(f"{label}: 66T bars + 5 spam submits claiming 100 -> prestige {q(db,'select prestige from yzy_leaderboard')} (want 2)")
    q(db,"update yzy_leaderboard set prestige=0,total_bars=66e12,prestige_at=now() where username='RUNNER'")
    q(db,f"set role anon; select yzy_lb_submit('RUNNER','{'d'*64}',66e12,200000,null,null,1)")
    print(f"{label}: 60s gate (step right after another) -> prestige {q(db,'select prestige from yzy_leaderboard')} (want 0)")
run(sys.argv[1],sys.argv[2])
