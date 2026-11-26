import http.server, ssl, threading, subprocess, os, json, pathlib, time, signal, shutil
root=pathlib.Path.cwd(); lab=root/'.test-merge-lab'
mode={'state':'OPEN','delay':0,'failure':False}; ready=threading.Event()
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_CONNECT(self):
  self.send_response(200); self.end_headers(); self.wfile.flush()
  conn=ctx.wrap_socket(self.connection,server_side=True)
  H(conn,self.client_address,self.server)
 def do_POST(self):
  req=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  print('API',req['query'].split('{')[0].strip(),flush=True)
  pr={'state':mode['state'],'mergedAt':None,'isDraft':False,'headRefOid':'a'*40,'author':{'login':'author'},'mergeable':'MERGEABLE','reviewDecision':'APPROVED','id':'PR_lab','number':7,'title':'Synthetic PR','url':f'https://localhost:{self.server.server_port}/o/r/pull/7','baseRefName':'main','headRefName':'test','statusCheckRollup':{'nodes':[]},'commits':{'nodes':[]},'baseRef':{'branchProtectionRule':None}}
  out={'data':{'repository':{'pullRequest':pr,'isFork':False,'name':'r','owner':{'login':'o'}},'viewer':{'login':'lab'}}}
  
  if 'PullRequestStatusChecks' in req['query']:
   ready.set(); time.sleep(mode['delay'])
   if mode['failure']:
    self.send_response(503); self.end_headers(); self.wfile.write(b'unavailable'); return
   out={'data':{'node':{'statusCheckRollup':{'nodes':[{'commit':{'statusCheckRollup':{'contexts':{'nodes':[{'__typename':'CheckRun','name':'build','status':'COMPLETED','conclusion':'SUCCESS','isRequired':True,'checkSuite':{'workflowRun':{'event':'push','workflow':{'name':'ci'}}}}], 'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}]}}}}
  if '__type(' in req['query']:
   out={'data':{k:{'fields':[{'name':n} for n in names]} for k,names in [('WorkflowRun',['event']),('PullRequest',['statusCheckRollup']),('StatusCheckRollupContextConnection',['nodes'])] if k+':' in req['query']}}
  body=json.dumps(out).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); 
  try: self.wfile.write(body)
  except (BrokenPipeError,ssl.SSLError): pass
s=http.server.ThreadingHTTPServer(('localhost',0),H); ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(lab/'cert.pem',lab/'key.pem')
t=threading.Thread(target=s.serve_forever);t.start()
env=os.environ.copy();env['PATH']='~/.local/share/mise/installs/gh/latest/gh_2.101.0_linux_amd64/bin:~/.local/share/mise/installs/node/26.8.2/bin:'+env['PATH'];env.update(GH_HOST='github.com',GH_TOKEN='synthetic-local-token',HTTPS_PROXY=f'http://localhost:{s.server_port}',NO_PROXY='',SSL_CERT_FILE=str(lab/'cert.pem'),GH_PROMPT_DISABLED='1',GH_CONFIG_DIR=str(lab/'gh'),XDG_CACHE_HOME=str(lab/'cache'))
home=lab/'home'
for d in ['data','state','config','tmp']: (home/d).mkdir(parents=True,exist_ok=True)
for k in list(env):
 if k.startswith('FM_') or k.startswith('TASKS_AXI_'): env.pop(k)
env.update(FM_HOME=str(home),TMPDIR=str(home/'tmp'),FM_STATE_OVERRIDE=str(home/'state'),FM_DATA_OVERRIDE=str(home/'data'),FM_CONFIG_OVERRIDE=str(home/'config'))
(home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/archive.md"\n')
url='https://github.com/o/r/pull/7'; t0=1795641826
line=f'paused [at={t0}]: waiting for home'
(home/'state/t.meta').write_text(f'kind=ship\nmode=direct-PR\nyolo=on\npr={url}\nworktree={home}/missing-worker\nbranch=fm/t\nbackend=tmux\nwindow=fm-lab:gone\n')
(home/'state/t.status').write_text(line+'\n')
ledger=home/'state/.merge-stall'
def run(args,expected=0,extra=None):
 e=env.copy();e.update(extra or {});start=time.monotonic()
 p=subprocess.run(args,env=e,text=True,capture_output=True,timeout=35)
 print('CLI',args,'exit',p.returncode,'seconds',round(time.monotonic()-start,2),'stdout',repr(p.stdout),'stderr',repr(p.stderr),flush=True)
 assert p.returncode==expected,(args,p.returncode,p.stderr)
 return p
try:
 run(['bin/fm-captain-hold.sh','hold','t','--title','Synthetic held task','--reason','Await captain review'])
 run(['bin/fm-captain-hold.sh','open','t'])
 run(['bin/fm-crew-state.sh','t'])
 for now in [t0+600,t0+1200,t0+3600]:
  p=run(['bin/fm-merge-stall.sh','scan','--now',str(now)]); assert not p.stdout and not p.stderr
 assert not ledger.read_text()
 print('SCENARIO held missing worker: silent across repeated intervals; no stall ledger',flush=True)
 episode=subprocess.run(['cksum'],input=line,text=True,capture_output=True,check=True).stdout.split()[0]
 def seed(): ledger.write_text(f't\t{url}\t{t0}\t0\t0\t{episode}\n')
 seed();before=ledger.read_text();mode['delay']=6
 start=time.monotonic();p=run(['bin/fm-merge-stall.sh','scan','--now',str(t0+3600)])
 assert time.monotonic()-start>=6 and not p.stdout and not p.stderr and ledger.read_text()==before
 print('SCENARIO real gh six-second checks: no false unreadable diagnostic; held episode preserved',flush=True)
 mode['delay']=0;mode['failure']=True
 p=run(['bin/fm-merge-stall.sh','scan','--now',str(t0+3601)])
 assert 'forge state unreadable' in p.stdout and 'merge it now' not in p.stdout and ledger.read_text()==before
 print('SCENARIO actual local forge failure: diagnostic retained, no merge authorization',flush=True)
 mode['failure']=False
 for state in ['CLOSED','MERGED']:
  seed();mode['state']=state
  p=run(['bin/fm-merge-stall.sh','scan','--now',str(t0+3602)])
  assert not p.stdout and not ledger.read_text()
  print('SCENARIO held terminal PR',state,': ledger retired silently',flush=True)
 mode['state']='OPEN';mode['delay']=2
 for sig,expected in [(signal.SIGTERM,143),(signal.SIGINT,130)]:
  ready.clear()
  p=subprocess.Popen(['bin/fm-pr-state.sh',url],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
  try:
   assert ready.wait(10),'checks not reached'
   os.killpg(p.pid,sig);out,err=p.communicate(timeout=8)
   print('CLI signal',sig.name,'exit',p.returncode,'stdout',repr(out),'stderr',repr(err),'temp_files',[x.name for x in (home/'tmp').iterdir()],flush=True)
   assert p.returncode==expected and not out and not err and not list((home/'tmp').glob('fm-pr-state.*'))
  finally:
   if p.poll() is None: os.killpg(p.pid,signal.SIGKILL);p.communicate()
 print('SCENARIO INT and TERM: expected exits and no deleted-temp reads or leftovers',flush=True)
finally:
 s.shutdown();s.server_close();t.join()
print('ALL LIVE LOCAL SCENARIOS PASSED; emulator stopped',flush=True)
