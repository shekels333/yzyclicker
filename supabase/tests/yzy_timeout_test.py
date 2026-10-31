import subprocess,sys,json
db=sys.argv[1] if len(sys.argv)>1 else 't'
S='d'*64
def q(s): 
    p=subprocess.run(["psql","-h","/tmp","-p","5499","-U","postgres","-d",db,"-tAqc",s],capture_output=True,text=True)
    if p.stderr.strip(): print("ERR",p.stderr.strip())
    return p.stdout.strip()
ok=True
def check(label,cond):
    global ok; ok&=bool(cond); print(("PASS " if cond else "FAIL ")+label)
def setup(name):
    k=name.lower()
    q(f"delete from yzy_flags where username='{name}'; delete from yzy_leaderboard where username='{name}'; delete from yzy_names where username_key='{k}'")
    q(f"insert into yzy_names(username_key,display_name,secret_hash,created_at) values('{k}','{name}',encode(extensions.digest('{S}','sha256'),'hex'),now()-interval '1 day')")
    q(f"insert into yzy_leaderboard(username,total_bars,total_clicks,submitted_at,prestige) values('{name}',1000,100,now()-interval '1 minute',0)")
def flags(name,n,trips,start_min=29):
    for i in range(n):
        q(f"""insert into yzy_flags(username,reason,details,created_at) values('{name}','client','{{"flagged":{trips},"reasons":{{"regular":{trips*(i+1)},"strong_d":{trips}}}}}',now()-interval '{start_min-i*2} minutes')""")
def sub(name,bars,clicks):
    q(f"update yzy_leaderboard set submitted_at=least(submitted_at, now()-interval '1 minute') where username='{name}'")
    return json.loads(q(f"set role anon; select yzy_lb_submit('{name}','{S}',{bars},{clicks},null,null,0)"))
def wk(name,bars,clicks):
    return json.loads(q(f"set role anon; select yzy_weekly_submit_v2('{name}','{S}',{bars},{clicks},null,null,0)"))
# legit: worst real player pattern x2 (8 reports, 14 trips in 30 min) -> never timed out
setup('LEGIT'); flags('LEGIT',8,2)
r=sub('LEGIT',2000,200); check(f"legit (8 reports/16 trips in 30m) submit ok {r}", r.get('ok') and r.get('kept') is None)
check("legit weekly ok", wk('LEGIT',2000,200).get('reason')!='timeout')
# old-client reports (regular but no strong_d) never count
setup('OLDCLI')
for i in range(20): q("insert into yzy_flags(username,reason,details,created_at) values('OLDCLI','client','{\"flagged\":5,\"reasons\":{\"regular\":%d}}',now()-interval '%d minutes')"%(5*(i+1),i))
check('regular-only reports (no strong_d) never time out', sub('OLDCLI',2000,200).get('ok'))
# 30+ min old heavy flags don't count
setup('OLD'); flags('OLD',20,3,start_min=80)
check("old flags (>30m ago) ignored", sub('OLD',2000,200).get('ok'))
# clicker: AGENT M-like 15 reports x 2 trips
setup('BOT'); flags('BOT',15,2)
r=sub('BOT',2000,200); check(f"bot submit rejected timeout {r.get('reason')}", r.get('reason')=='timeout')
d=json.loads(q("select details from yzy_flags where username='BOT' and reason='timeout'"))
check(f"strike 1 = 5 min {d['minutes']}", d['minutes']==5)
check("board row kept", q("select total_bars from yzy_leaderboard where username='BOT'")=='1000')
check("weekly rejected", wk('BOT',2000,200).get('reason')=='timeout')
st=json.loads(q(f"set role anon; select yzy_timeout_status('BOT','{S}')")); check(f"status secs ~300 {st['secs']}", 290<=st['secs']<=300)
check("wrong secret status refused", not json.loads(q("set role anon; select yzy_timeout_status('BOT','x')")).get('ok'))
# expire timeout: flags before it no longer count; allowance restarts at end
q("update yzy_flags set details=jsonb_set(details,'{until}',to_jsonb(now()-interval '10 seconds')) where username='BOT' and reason='timeout'")
r=sub('BOT',2000,200); check(f"after timeout, submit allowed {r}", r.get('ok'))
r=sub('BOT',10**12,5000); check(f"bars banked during timeout rejected by rate {r}", r.get('reason')=='rate')
# repeat -> 15 then 60
flags('BOT',13,2,start_min=0)  # newer than the expired timeout
q("update yzy_flags set created_at=now()-interval '1 second' where username='BOT' and reason='client' and created_at>now()")
r=sub('BOT',3000,300); d=q("select details->>'minutes' from yzy_flags where username='BOT' and reason='timeout' order by created_at desc limit 1")
check(f"strike 2 = 15 min ({d})", r.get('reason')=='timeout' and d=='15')
q("update yzy_flags set details=jsonb_set(details,'{until}',to_jsonb(now()-interval '1 second')) where username='BOT' and reason='timeout'")
q("insert into yzy_flags(username,reason,details,created_at) select 'BOT','client','{\"flagged\":2,\"reasons\":{\"regular\":2,\"strong_d\":2}}',now() from generate_series(1,13)")
sub('BOT',3000,300); d=q("select details->>'minutes' from yzy_flags where username='BOT' and reason='timeout' order by created_at desc limit 1")
check(f"strike 3 = 60 min ({d})", d=='60')
# rename carries timeout
q("set role anon; select yzy_rename('BOT','BOT2','"+S+"')")
r=json.loads(q(f"set role anon; select yzy_lb_submit('BOT2','{S}',5000,400,null,null,0)"))
check(f"rename keeps timeout {r.get('reason')}", r.get('reason')=='timeout')
check("anon cannot call yzy__timeout_until", 'denied' in subprocess.run(["psql","-h","/tmp","-p","5499","-U","postgres","-d",db,"-tAqc","set role anon; select yzy__timeout_until('X')"],capture_output=True,text=True).stderr)
for n in ['OLDCLI','LEGIT','OLD','BOT','BOT2']: q(f"delete from yzy_flags where username='{n}'; delete from yzy_leaderboard where username='{n}'; delete from yzy_names where username_key='{n.lower()}'")
print("ALL PASS" if ok else "SOME FAILED")
