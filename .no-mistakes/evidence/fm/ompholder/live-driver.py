import os, subprocess, tempfile, pathlib, time, shutil, json
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M887R9HA940RAKYQ2PZMDASH')
results=[]
for label,holder,lock in [('different','other','holder:omp'),('missing',None,'holder:omp'),('invalid','omp bad','holder:omp bad'),('matching','omp','holder:omp'),('numeric',None,'PID')]:
 lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=os.environ.get('TMPDIR','/tmp')))
 env=os.environ.copy()
 for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_LOCK_HOLDER']:
  env.pop(k,None)
 env.update(TMUX_TMPDIR=str(lab/'tmux'),FM_HOME=str(lab),FM_OMP_HARNESS='omp',OMP_SKIP_SETUP='1')
 if holder is not None: env['FM_LOCK_HOLDER']=holder
 def tm(*args,check=True): return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=check)
 try:
  subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
  (lab/'tmux').mkdir(); (lab/'config/backend').write_text('tmux\n')
  if lock!='PID': (lab/'state/.lock').write_text(lock+'\n')
  launch=tm('new-session','-d','-s','primary','-x','120','-y','36','-c',str(root),'-e',f'FM_HOME={lab}','omp --no-session --no-title --no-lsp --no-skills --no-context-files --no-rules')
  time.sleep(12)
  if lock=='PID':
   pid=tm('display-message','-p','-t','primary','#{pane_pid}').stdout.strip()
   (lab/'state/.lock').write_text(pid+'\n')
  before=tm('capture-pane','-p','-t','primary',check=False)
  marks={name:(lab/'state'/name).exists() for name in ['.omp-watch-extension-loaded','.omp-turnend-extension-loaded']}
  tm('send-keys','-t','primary','/fm-watch-arm-omp','Enter',check=False)
  time.sleep(4)
  after=tm('capture-pane','-p','-t','primary',check=False)
  (evidence/f'live-{label}.txt').write_text('omp 18.16.0\n'+json.dumps({'case':label,'holder':holder,'lock':lock,'markers':marks})+'\nBEFORE\n'+before.stdout+before.stderr+'\nAFTER COMMAND\n'+after.stdout+after.stderr)
  results.append({'case':label,'markers':marks,'capture_exit':after.returncode})
  tm('send-keys','-t','primary','/quit','Enter',check=False); time.sleep(2)
 finally:
  tm('kill-server',check=False)
  # Only lab-scoped child processes; extensions may have started a detached worker.
  rows=subprocess.run(['ps','-axo','pid=,command='],text=True,capture_output=True).stdout.splitlines()
  for row in rows:
   if str(lab) in row:
    try: os.kill(int(row.strip().split(None,1)[0]),15)
    except ProcessLookupError: pass
  time.sleep(1)
  shutil.rmtree(lab)
(evidence/'live-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results))
