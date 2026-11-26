import os, subprocess, pathlib, json, ssl, http.server, threading, time, signal, shutil
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M8C85WNXWSE59XS20Y82Y2SR'); LAB=ROOT/'.merge-stall-validation-lab'
if LAB.exists(): raise RuntimeError('lab already exists')
LAB.mkdir(); subprocess.run(['bin/fm-lab-home.sh','create',str(LAB)],check=True)
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('TASKS_AXI') or k.startswith('GH_') or k.lower() in ['https_proxy','http_proxy','all_proxy','no_proxy']: env.pop(k,None)
env.update(FM_HOME=str(LAB),GH_TOKEN='synthetic-local-only',GH_CONFIG_DIR=str(LAB/'gh'),TMPDIR=str(LAB),XDG_CACHE_HOME=str(LAB/'cache'))
(LAB/'bin').mkdir(); (LAB/'bin/gh').symlink_to(subprocess.check_output(['mise','which','gh'],text=True).strip()); env['PATH']=str(LAB/'bin')+':'+env['PATH']
log=[]
def run(args,check=True,**kw):
 p=subprocess.run(args,env=env,text=True,capture_output=True,**kw)
 log.append({'command':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 if check and p.returncode: raise RuntimeError(log[-1])
 return p
try:
 (LAB/'.tasks.toml').write_text('backend = "markdown"\n')
 run(['bin/fm-tasks-axi.sh','add','held-worker','Await decision'])
 run(['bin/fm-captain-hold.sh','hold','held-worker','--reason','Captain reviews result'])
 (LAB/'state/held-worker.meta').write_text('kind=ship\nmode=direct-PR\nyolo=on\npr=https://github.com/o/r/pull/7\n')
 (LAB/'state/held-worker.status').write_text('paused [at=1795641826]: PR ready; worker endpoint gone\n')
 for now in [1795642426,1795643026,1795645426]:
  p=run(['bin/fm-merge-stall.sh','scan','--now',str(now)]); assert not p.stdout and not p.stderr
 # Reproduce the reported missing-worker notification on the base implementation.
 base=LAB/'base-bin'; base.mkdir()
 for src in (ROOT/'bin').iterdir():
  if src.is_file(): (base/src.name).symlink_to(src)
 for name in ['fm-merge-stall.sh','fm-pr-state.sh']:
  (base/name).unlink(); (base/name).write_bytes(subprocess.check_output(['git','show','dcccab84419fbb51c84add13c6e8ea24d52c315f:bin/'+name])); (base/name).chmod(0o755)
 p=run([str(base/'fm-merge-stall.sh'),'scan','--now','1795645426'])
 assert 'activity unreadable' in p.stdout
 print('HELD_GONE: three scans silent using real captain-hold and crew-state interfaces')
 run(['bin/fm-tasks-axi.sh','unhold','held-worker'])
 p=run(['bin/fm-merge-stall.sh','scan','--now','1795646026']); assert 'activity' in p.stdout, p.stdout
 print('RELEASED_GONE: real missing worker now produces diagnostic:',p.stdout.strip())
 # Local TLS CONNECT proxy: the real gh client talks to this synthetic forge only.
 (LAB/'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=api.github.com\n[ext]\nsubjectAltName=DNS:api.github.com,DNS:github.com\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n')
 run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(LAB/'key.pem'),'-out',str(LAB/'cert.pem'),'-days','1','-config',str(LAB/'cert.cnf')])
 requests=[]; mode={'delay':0,'terminal':False}; ready=threading.Event()
 ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(LAB/'cert.pem',LAB/'key.pem')
 class H(http.server.BaseHTTPRequestHandler):
  protocol_version='HTTP/1.1'
  def log_message(self,*a): pass
  def do_CONNECT(self):
   self.send_response(200); self.end_headers(); self.connection=ctx.wrap_socket(self.connection,server_side=True); self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb'); self.close_connection=False
  def do_POST(self):
   body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0')))); q=body.get('query',''); requests.append(body)
   pr={'id':'PR_local','number':7,'state':'OPEN','mergedAt':None,'isDraft':False,'headRefOid':'a'*40,'author':{'login':'author'},'mergeable':'MERGEABLE','reviewDecision':'APPROVED','url':'https://github.com/o/r/pull/7','baseRefName':'main','headRefName':'fm/test','headRepository':{'name':'r','owner':{'login':'o'}}}
   if mode['terminal']: pr.update(state='MERGED',mergedAt='2026-11-26T12:00:00Z')
   if 'statusCheckRollup' in q:
    ready.set(); time.sleep(mode['delay'])
    pr['statusCheckRollup']={'contexts':{'nodes':[{'__typename':'CheckRun','name':'build','status':'COMPLETED','conclusion':'SUCCESS','detailsUrl':'https://example.invalid/build','isRequired':True,'checkSuite':{'workflowRun':{'workflow':{'name':'CI'}}}}], 'pageInfo':{'hasNextPage':False,'endCursor':None}}}
   result={'data':{'repository':{'pullRequest':pr}}}
   
   if 'PullRequestStatusChecks' in q:
    result={'data':{'node':{'__typename':'PullRequest','statusCheckRollup':{'nodes':[{'commit':{'statusCheckRollup':pr['statusCheckRollup']}}]}}}}
   if '__type(' in q:
    result={'data':{name:{'fields':[{'name':f} for f in fields]} for name,fields in {'PullRequest':['statusCheckRollup'], 'StatusCheckRollupContextConnection':['checkRunCount','statusContextCount'], 'WorkflowRun':['workflow']}.items() if name+':' in q}}
   data=json.dumps(result).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
   try:self.wfile.write(data)
   except (BrokenPipeError,ssl.SSLError):pass
 class Server(http.server.ThreadingHTTPServer):
  def handle_error(self,*a): pass
 server=Server(('127.0.0.1',0),H); server.daemon_threads=True
 thread=threading.Thread(target=server.serve_forever); thread.start()
 env.update(HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',HTTP_PROXY=f'http://127.0.0.1:{server.server_port}',SSL_CERT_FILE=str(LAB/'cert.pem'),NO_PROXY='')
 p=run(['bin/fm-pr-state.sh','https://github.com/o/r/pull/7']); assert not p.stdout and not p.stderr
 # An already recorded waiting episode still reads terminal state while held.
 run(['bin/fm-captain-hold.sh','hold','held-worker','--reason','Captain reviews result'])
 line=(LAB/'state/held-worker.status').read_text().rstrip('\n')
 episode=subprocess.check_output(['cksum'],input=line,text=True).split()[0]
 (LAB/'state/.merge-stall').write_text(f'held-worker\thttps://github.com/o/r/pull/7\t1795641826\t1795642426\t0\t{episode}\n')
 mode['delay']=6
 started=time.monotonic(); before=len(requests)
 p=run(['bin/fm-merge-stall.sh','scan','--now','1795645426']); elapsed=time.monotonic()-started
 assert not p.stdout and not p.stderr and elapsed>=6 and (LAB/'state/.merge-stall').stat().st_size>0
 assert any('PullRequestStatusChecks' in x['query'] for x in requests[before:])
 log.append({'scenario':'six-second checks through real gh under default scan timeout','elapsed_seconds':elapsed,'ledger':(LAB/'state/.merge-stall').read_text()})
 print('SLOW_FORGE: six-second real gh read completed under default timeout; held episode preserved')
 mode['terminal']=True
 p=run(['bin/fm-merge-stall.sh','scan','--now','1795646026']); assert not p.stdout and not p.stderr and not (LAB/'state/.merge-stall').read_text()
 print('TERMINAL_HELD: merged PR retired existing ledger despite missing worker')
 mode['terminal']=False; mode['delay']=2
 for executable,label in [(str(base/'fm-pr-state.sh'),'base'),('bin/fm-pr-state.sh','target')]:
  for sig,expected in [(signal.SIGTERM,143),(signal.SIGINT,130)]:
   ready.clear(); before_files=set(LAB.glob('fm-pr-state.*'))
   proc=subprocess.Popen([executable,'https://github.com/o/r/pull/7'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
   try:
    assert ready.wait(10),'gh checks request did not arrive'
    os.killpg(proc.pid,sig); out,err=proc.communicate(timeout=10)
   finally:
    if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait()
   log.append({'scenario':f'{label} {sig.name} during real gh checks','exit':proc.returncode,'stdout':out,'stderr':err,'temp_files_remaining':[str(x.name) for x in set(LAB.glob('fm-pr-state.*'))-before_files]})
   if label=='target': assert proc.returncode==expected and not out and not err and set(LAB.glob('fm-pr-state.*'))==before_files
   else: assert proc.returncode!=expected and 'No such file' in err
   time.sleep(2.1) # drain this local synthetic response before the next signal case
 print('SIGNALS: target INT=130 TERM=143, no deleted-file reads or leftover temp files; both regress on base')
 (E/'requests.json').write_text(json.dumps(requests,indent=2))

finally:
 if 'server' in globals():server.shutdown();server.server_close();thread.join()
 (E/'live-transcript.json').write_text(json.dumps(log,indent=2)); shutil.rmtree(LAB)
