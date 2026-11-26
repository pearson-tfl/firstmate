import os,ssl,socketserver,http.server,threading,json,subprocess,pathlib,shutil
root=pathlib.Path.cwd(); tmp=root/'.tmp-live-pr'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M8C9AN21WS132YBY8DQE9DE0'); evidence.mkdir(parents=True,exist_ok=True)
head='0123456789abcdef0123456789abcdef01234567'
log=[]; current={'head':head,'merged':False}; results=[]
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(str(tmp/'cert.pem'),str(tmp/'key.pem'))
class API(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_CONNECT(self):
  self.send_response(200); self.end_headers(); self.connection=ctx.wrap_socket(self.connection,server_side=True); self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb'); self.close_connection=False
 def do_GET(self): self.respond()
 def do_POST(self): self.respond()
 def respond(self):
  raw=self.rfile.read(int(self.headers.get('Content-Length',0))); body=json.loads(raw or b'{}'); query=body.get('query',''); log.append({'method':self.command,'path':self.path,'body':body})
  pr={'id':'PR_local_1019','number':1019,'title':'Synthetic remote lane','state':'MERGED' if current['merged'] else 'OPEN','merged':current['merged'],'isInMergeQueue':False,'isDraft':False,'mergeable':'MERGEABLE','mergeStateStatus':'CLEAN','headRefOid':current['head'],'baseRefName':'main','headRefName':'fm/remote','headRepositoryOwner':{'login':'o'},'headRepository':{'name':'r','nameWithOwner':'o/r'},'baseRepository':{'name':'r','nameWithOwner':'o/r','owner':{'login':'o'}},'statusCheckRollup':{'nodes':[{'commit':{'statusCheckRollup':{'contexts':{'nodes':[{'__typename':'CheckRun','name':'ci','status':'COMPLETED','conclusion':'SUCCESS','checkSuite':{'workflowRun':{'workflow':{'name':'CI'}}}}],'pageInfo':{'hasNextPage':False,'endCursor':''}}}}}]},'viewerCanDeleteHeadRef':False,'url':'https://github.com/o/r/pull/1019'}
  if 'query PullRequest_fields2' in query:
   data={'data':{'WorkflowRun':{'fields':[{'name':'workflow'}]}}}
  elif 'query PullRequest_fields' in query:
   data={'data':{'PullRequest':{'fields':[{'name':k} for k in pr]},'StatusCheckRollupContextConnection':{'fields':[{'name':'nodes'},{'name':'pageInfo'}]}}}
  elif 'mergePullRequest' in query:
   current['merged']=True; data={'data':{'mergePullRequest':{'clientMutationId':None}}}
  elif self.path.endswith('/graphql') and 'mutation' in query:
   data={'data':{}}
  elif self.path.endswith('/graphql'):
   data={'data':{'repository':{'id':'R_local','name':'r','nameWithOwner':'o/r','owner':{'login':'o'},'defaultBranchRef':{'name':'main'},'pullRequest':pr,'viewerPermission':'ADMIN','mergeCommitAllowed':True,'squashMergeAllowed':True,'rebaseMergeAllowed':True}}}
  elif '/rules/branches/' in self.path: data=[]
  elif '/branches/' in self.path: data={'protected':False}
  elif '/check-runs' in self.path: data={'total_count':0,'check_runs':[]}
  else: data={}
  payload=json.dumps(data).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(payload))); self.send_header('Connection','close'); self.end_headers(); self.wfile.write(payload); self.close_connection=True
class Server(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
server=Server(('127.0.0.1',0),API); thread=threading.Thread(target=server.serve_forever);thread.start()
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('GH_') or k in ['GITHUB_TOKEN','TMUX','TMUX_PANE']: env.pop(k,None)
env['PATH']=str(tmp/'bin')+':'+env['PATH']
env['XDG_CACHE_HOME']=str(tmp/'cache')
env.update(GH_TOKEN='synthetic-local-only',GH_ENTERPRISE_TOKEN='synthetic-local-only',GH_CONFIG_DIR=str(tmp/'gh'),SSL_CERT_FILE=str(tmp/'cert.pem'),HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',HTTP_PROXY=f'http://127.0.0.1:{server.server_port}',NO_PROXY='',TMPDIR=str(tmp))
def run(name,mode='direct-PR',pathkind='missing',badhead=False,merge=False,host='github.com',baseline=False):
 home=tmp/name; shutil.rmtree(home,ignore_errors=True); (home/'state').mkdir(parents=True);(home/'config').mkdir();(home/'data').mkdir(); wt=home/'remote-dell-copy'
 if pathkind=='file': wt.write_text('sentinel')
 if pathkind=='link': wt.symlink_to(home/'absent')
 if host!='github.com': (home/'config/github-hosts').write_text(host+'\n')
 meta=home/'state/lane.meta'; meta.write_text(f'window=fm-lane\nendpoint_task_id=lane\nworktree={wt if pathkind!="empty" else ""}\nproject={home}/project\nkind=ship\nmode={mode}\n');meta.chmod(0o600)
 current.update(head='not-a-sha' if badhead else head,merged=False); start=len(log)
 e=env.copy();e['FM_HOME']=str(home)
 e['GH_DEBUG']=''
 command=[str(tmp/'base/bin/fm-pr-check.sh') if baseline else ('bin/fm-pr-merge.sh' if merge else 'bin/fm-pr-check.sh'),'lane',f'https://{host}/o/r/pull/1019']
 proc=subprocess.run(command,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
 result={'name':name,'command':' '.join(command),'exit':proc.returncode,'stdout':proc.stdout,'stderr':proc.stderr,'metadata':meta.read_text(),'artifacts':sorted(p.name for p in (home/'state').iterdir()),'api_requests':log[start:]}
 results.append(result); print(name,proc.returncode,proc.stdout,proc.stderr,flush=True)
 return result
try:
 for mode in ['no-mistakes','direct-PR']: run('baseline-'+mode,mode,baseline=True)
 for mode in ['no-mistakes','direct-PR']: run('register-'+mode,mode)
 run('register-enterprise',host='ghe.example.test')
 for mode in ['no-mistakes','direct-PR']: run('invalid-head-'+mode,mode,badhead=True)
 for kind in ['empty','file','link']: run('corrupt-'+kind,pathkind=kind)
 run('local-only',mode='local-only')
 for mode in ['no-mistakes','direct-PR']: run('merge-'+mode,mode,merge=True)
 for mode in ['no-mistakes','direct-PR']: run('merge-invalid-'+mode,mode,merge=True,badhead=True)
finally:
 server.shutdown(); server.server_close();thread.join();(evidence/'live-pr-transcript.json').write_text(json.dumps(results,indent=2))
