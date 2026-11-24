import os, subprocess, pathlib, json, time, shutil
ROOT=pathlib.Path('{run-worktree}')
E=pathlib.Path('~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA')
lab=E/'b'; assert not lab.exists(); lab.mkdir()
env=os.environ.copy()
for k in list(env):
 if k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','FM_LOCK_HOLDER','FM_LOCK_RECEIPT','TMUX','TMUX_PANE'] or (k.startswith('FM_') and k.endswith('_OVERRIDE')):
  env.pop(k,None)
env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab/'h'),FM_SKIP_SECONDMATE_SYNC='1',FM_SKIP_SECONDMATE_INHERIT='1',FM_BACKEND='tmux',OMP_PROFILE='neon')
(lab/'tmux').mkdir()
def run(args, **kw): return subprocess.run(args,env=env,cwd=ROOT,check=True,text=True,**kw)
def tm(*args,**kw): return run(['tmux','-L','fm-lab',*args],**kw)
def snapshot(home,model):
 rows=[]
 for line in subprocess.check_output(['ps','-axo','pid=,ppid=,args='],text=True).splitlines():
  bits=line.strip().split(None,2)
  if len(bits)!=3:continue
  pid,ppid,args=bits
  if '--cwd '+str(home) in args and '--model '+model in args and ('/omp ' in args or 'pi-coding-agent' in args):
   rows.append(dict(pid=int(pid),ppid=int(ppid),args=args))
 return rows
results=[]
try:
 run(['bash','bin/fm-lab-home.sh','create',str(lab/'h')],stdout=subprocess.DEVNULL)
 for name,value in [('backend','tmux'),('backlog-backend','manual'),('secondmate-harness','omp')]: (lab/'h/config'/name).write_text(value+'\n')
 (lab/'h/config/keep-ai-trailers').touch()
 tm('new-session','-d','-s','lab','-n','control','-x','180','-y','55','-c',str(ROOT),'/bin/bash')
 env['TMUX']=tm('display-message','-p','-t','lab:control','#{socket_path},#{pid},0',stdout=subprocess.PIPE).stdout.strip()
 for ident,model,kind,expected in [('alternate','antigravity-cli/gemini-4-argon','secondmate',True),('other','google/gemini-4-neon','secondmate',False),('scout','antigravity-cli/gemini-4-neon','scout',False)]:
  home=lab/ident
  if kind=='secondmate':
   run(['bash','bin/fm-lab-home.sh','create',str(home)],stdout=subprocess.DEVNULL)
   (home/'bin').mkdir()
   (home/'AGENTS.md').write_text('Isolated launch boundary verification. Reply only BOUNDARY. Do not use tools, change files, or start supervision.\n')
   (home/'.fm-secondmate-home').write_text(ident+'\n')
   (home/'data/charter.md').write_text('Reply only BOUNDARY. Do not use tools or start work.\n')
   pin=lab/'h/config/secondmate-accounts'/ident; pin.mkdir(parents=True); (pin/'omp-profile').write_text('neon\n')
   run(['git','-C',str(home),'init','-q','-b','main'])
   args=['bash','bin/fm-spawn.sh',ident,str(home),'--secondmate','--harness','omp','--model',model,'--effort','xhigh']
  else:
   home.mkdir()
   run(['git','-C',str(home),'init','-q','-b','main'])
   run(['git','-C',str(home),'-c','user.name=Lab','-c','user.email=lab@example.invalid','-c','core.hooksPath=/dev/null','commit','-q','--allow-empty','-m','Isolated test fixture'])
   data=lab/'h/data'/ident; data.mkdir(); (data/'brief.md').write_text('# Task\nReply only BOUNDARY. Do not use tools, change files, or start work.\n')
   tm('new-window','-d','-t','lab:','-n','fm-scout','-c',str(home),'/bin/bash')
   (lab/'h/state/scout.meta').write_text(f'window=lab:fm-scout\nendpoint_task_id=scout\nworktree={home}\nproject={home}\nharness=omp\nkind=scout\nmode=scout\nyolo=off\n')
   args=['bash','bin/fm-spawn.sh','scout','--relaunch','--harness','omp','--model',model,'--effort','xhigh']
  log=E/f'scope-{ident}.log'
  with log.open('w') as f:
   p=subprocess.Popen(args,env=env,cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,text=True)
   try:
    rows=[]; deadline=time.monotonic()+65
    while time.monotonic()<deadline:
     rows=snapshot(home,model)
     if rows:break
     if p.poll() not in [None,0]:break
     time.sleep(.1)
    rc=p.wait(timeout=20)
   except BaseException:
    p.terminate(); p.wait(timeout=10); raise
  (E/f'scope-{ident}-process.json').write_text(json.dumps(rows,indent=2)+'\n')
  assert rc==0,(ident,'spawn exit',rc,log.read_text())
  assert rows,(ident,'no real omp process observed',log.read_text())
  for row in rows:
   assert ('--system-prompt ' in row['args'])==expected,(ident,'wrong replacement flag',row)
   if expected: assert str(ROOT/'.omp/fm-antigravity-system-prompt.md') in row['args']
  target='lab:fm-'+ident
  pane=tm('capture-pane','-p','-S','-','-t',target,stdout=subprocess.PIPE).stdout
  (E/f'scope-{ident}-pane.txt').write_text(pane)
  tm('kill-window','-t',target)
  results.append(dict(case=ident,model=model,kind=kind,system_prompt=expected,spawn_exit=rc,observed_agent_pids=[r['pid'] for r in rows]))
  print(json.dumps(results[-1]),flush=True)
finally:
 subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 time.sleep(1)
 for d,ds,fs in os.walk(lab):os.chmod(d,os.stat(d).st_mode|0o700)
 shutil.rmtree(lab)
 (E/'scope-cleanup.txt').write_text('Private scope tmux server stopped; all boundary scratch homes removed.\n')
(E/'scope-results.json').write_text(json.dumps(results,indent=2)+'\n')
