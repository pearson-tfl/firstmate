import pathlib,subprocess,os,signal,time,json,shutil
E=pathlib.Path('~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA')
ROOT=pathlib.Path('{run-worktree}')
lab=E/'default-control';lab.mkdir()
(lab/'AGENTS.md').write_text('Isolated verification. Reply only with the requested word. Never use tools or change files.\n')
args=['omp','--profile','neon','--config',str(ROOT/'.omp/fm-worker-overlay.yml'),'--model','antigravity-cli/gemini-4-neon','--thinking','xhigh','--no-session','-p','Reply with the single word BASELINE.']
env=os.environ.copy();env['OMP_SKIP_SETUP']='1'
p=None;observed=False
try:
 with (E/'default-prompt-control.log').open('w') as f:
  p=subprocess.Popen(args,cwd=lab,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
  end=time.monotonic()+70
  while time.monotonic()<end:
   output=(E/'default-prompt-control.log').read_text()
   if 'RESOURCE_EXHAUSTED' in output or 'code 429' in output:
    observed=True;break
   if p.poll() is not None:break
   time.sleep(.2)
  if p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try:p.wait(timeout=10)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  result=dict(command=args,default_prompt_429_observed=observed,exit=p.returncode,stopped_after_observation=observed)
  (E/'default-prompt-control-result.json').write_text(json.dumps(result,indent=2)+'\n')
  print(json.dumps(result))
finally:
 if p and p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.wait()
 shutil.rmtree(lab)
