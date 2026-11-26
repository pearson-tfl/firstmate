import os, subprocess as sp, pathlib, ssl, socketserver, threading, json, time, signal
root=pathlib.Path.cwd(); lab=root/'.test-merge-lab'; home=lab/'home'
for p in ['state','data','config']: (home/p).mkdir(parents=True,exist_ok=True)
sp.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(lab/'key.pem'),'-out',str(lab/'cert.pem'),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com,DNS:github.com'],stdout=sp.DEVNULL,stderr=sp.DEVNULL,check=True)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(lab/'cert.pem',lab/'key.pem')
mode={'delay':0,'terminal':False}; calls=[]; ready=threading.Event()
class Handler(socketserver.StreamRequestHandler):
 def handle(self):
  try:
   line=self.rfile.readline()
   while self.rfile.readline() not in [b'\r\n',b'']: pass
   self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n'); self.wfile.flush()
   s=ctx.wrap_socket(self.connection,server_side=True); f=s.makefile('rb')
   line=f.readline(); headers={}
   while True:
    h=f.readline()
    if h in [b'\r\n',b'']: break
    k,v=h.decode().split(':',1); headers[k.lower()]=v.strip()
   body=f.read(int(headers.get('content-length','0'))).decode(); calls.append(line.decode()+body)
   checks='statusCheckRollup' in body
   if checks: ready.set(); time.sleep(mode['delay'])
   pr={'id':'PR_test','number':7,'url':'https://github.com/o/r/pull/7','state':'MERGED' if mode['terminal'] else 'OPEN','mergedAt':'2026-11-26T00:00:00Z' if mode['terminal'] else None,'isDraft':False,'headRefOid':'a'*40,'author':{'login':'author','__typename':'User'},'mergeable':'MERGEABLE','reviewDecision':'APPROVED','baseRefName':'main','baseRef':{'branchProtectionRule':{'requiresStatusChecks':True,'requiredStatusCheckContexts':['ci']}},'statusCheckRollup':{'contexts':{'nodes':[{'__typename':'CheckRun','name':'ci','status':'COMPLETED','conclusion':'SUCCESS','isRequired':True,'checkSuite':{'workflowRun':{'workflow':{'name':'CI'}}}}],'pageInfo':{'hasNextPage':False,'endCursor':None}}}}
   data={'data':{'repository':{'pullRequest':pr,'defaultBranchRef':{'name':'main'}}}}
   if 'number,headRefName,id' in body: data={'data':{'repository':{'pullRequest':{'number':7,'headRefName':'test','id':'PR_test'}}}}
   if '__type' in body: data={'data':{k:{'fields':[{'name':n} for n in ['statusCheckRollup','isRequired','workflow','workflowRun','event']]} for k in ['PullRequest','StatusCheckRollupContextConnection','WorkflowRun'] if k+': __type' in body}}
   if 'node(' in body: data={'data':{'node':{'__typename':'PullRequest','statusCheckRollup':{'nodes':[{'commit':{'statusCheckRollup':pr['statusCheckRollup']}}]}}}}
   if line.startswith(b'GET '): data={'required_status_checks':{'contexts':['ci'],'checks':[{'context':'ci','app_id':None}]}}
   out=json.dumps(data).encode(); s.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: '+str(len(out)).encode()+b'\r\n\r\n'+out); s.close()
  except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass
class Server(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
server=Server(('127.0.0.1',0),Handler); thread=threading.Thread(target=server.serve_forever);thread.start()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','GH_','GITHUB_'))}
env['PATH']=str(lab/'tools')+':'+env['PATH']
env.update(XDG_CACHE_HOME=str(lab/'cache'),MISE_OFFLINE='1',FM_HOME=str(home),GH_CONFIG_DIR=str(lab/'ghconfig'),GH_TOKEN='synthetic-local-only',HTTPS_PROXY=f'http://127.0.0.1:{server.server_address[1]}',HTTP_PROXY=f'http://127.0.0.1:{server.server_address[1]}',NO_PROXY='',SSL_CERT_FILE=str(lab/'cert.pem'),TMPDIR=str(lab))
def run(args,**kw):
 p=sp.run(args,env=env,text=True,capture_output=True,**kw); print('$',' '.join(map(str,args)), '\nexit=',p.returncode,'stdout=',repr(p.stdout),'stderr=',repr(p.stderr),flush=True);return p
try:
 url='https://github.com/o/r/pull/7'
 (home/'.tasks.toml').write_text('[storage]\nbackend = "markdown"\n')
 p=run(['bin/fm-captain-hold.sh','hold','held','--title','Synthetic pending decision','--reason','Await approval','--repo','synthetic'],timeout=30); assert p.returncode==0
 (home/'state/held.meta').write_text('kind=ship\nyolo=on\npr='+url+'\n')
 line='paused [at=1000000000]: PR ready'
 (home/'state/held.status').write_text(line+'\n')
 p=run(['bin/fm-crew-state.sh','held'],timeout=30); assert 'unknown' in p.stdout
 for now in [1000000600,1000001200]:
  p=run(['bin/fm-merge-stall.sh','scan','--now',str(now)],timeout=30); assert p.returncode==0 and p.stdout=='' and p.stderr==''
 print('SCENARIO held missing worker: two scans silent',flush=True)
 episode=sp.check_output(['cksum'],input=line.encode()).decode().split()[0]
 (home/'state/.merge-stall').write_text('held\t'+url+'\t1000000000\t0\t0\t'+episode+'\n')
 mode['delay']=6
 t=time.monotonic(); p=run(['bin/fm-merge-stall.sh','scan','--now','1000001800'],timeout=30)
 elapsed=time.monotonic()-t
 assert p.returncode==0 and not p.stdout and not p.stderr and elapsed>=6
 assert (home/'state/.merge-stall').stat().st_size>0
 print('SCENARIO six-second healthy forge read: silent, episode preserved; elapsed',round(elapsed,2),flush=True)
 mode['delay']=0;mode['terminal']=True
 p=run(['bin/fm-merge-stall.sh','scan','--now','1000002400'],timeout=30)
 assert p.returncode==0 and not p.stdout and not p.stderr and (home/'state/.merge-stall').stat().st_size==0
 print('SCENARIO merged held PR: episode retired',flush=True)
 mode['terminal']=False; mode['delay']=2
 for sig,expected in [(signal.SIGTERM,143),(signal.SIGINT,130)]:
  ready.clear()
  p=sp.Popen(['bin/fm-pr-state.sh',url],env=env,text=True,stdout=sp.PIPE,stderr=sp.PIPE,start_new_session=True)
  assert ready.wait(10), 'checks request did not start'
  os.killpg(p.pid,sig);out,err=p.communicate(timeout=10)
  print('SCENARIO signal',sig.name,'exit',p.returncode,'stdout',repr(out),'stderr',repr(err),'temp files',list(lab.glob('fm-pr-state.*')),flush=True)
  assert p.returncode==expected and not err and not list(lab.glob('fm-pr-state.*'))
 print('API REQUESTS',json.dumps(calls),flush=True)
finally:
 server.shutdown();server.server_close();thread.join()
