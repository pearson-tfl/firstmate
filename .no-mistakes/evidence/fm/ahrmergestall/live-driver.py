import os, pathlib, subprocess, json, time, ssl, threading, http.server, shutil, traceback
ROOT=pathlib.Path.cwd(); E=pathlib.Path('~/.no-mistakes/evidence/01M8AYJ2TEPPTC98229VQ33V9H'); LAB=ROOT/'.merge-stall-live'
LAB.mkdir(exist_ok=True)
LOG=open(E/'live-product-transcript.log','w',buffering=1)
def log(s): LOG.write(str(s)+'\n'); print(s,flush=True)
def cmd(args,env=None,ok=True,timeout=25):
    p=subprocess.run(args,cwd=ROOT,env=env or ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log('$ '+' '.join(map(str,args))+'\n'+p.stdout.rstrip()+'\nexit='+str(p.returncode))
    if ok and p.returncode: raise AssertionError(p.stdout)
    return p
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith(('FM_','GH_','GITHUB_','HERDR_','NO_MISTAKES','TASKS_AXI')) or k in ['TMUX','TMUX_PANE']: ENV.pop(k,None)
ENV.update(TMPDIR=str(LAB),GH_CONFIG_DIR=str(LAB/'gh-config'),GH_TOKEN='synthetic-local-emulator-token',GH_PROMPT_DISABLED='1',XDG_CACHE_HOME=str(LAB/'cache'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
state={'prs':{},'list':[],'fault':None}; requests=[]
class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def do_CONNECT(self):
        if self.path not in ('api.github.com:443','github.com:443'):
            self.send_error(403); return
        self.send_response(200); self.end_headers()
        self.connection=TLS.wrap_socket(self.connection,server_side=True); self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb'); self.close_connection=False
        while not self.close_connection:
            self.handle_one_request()
    def do_POST(self): self.answer()
    def do_GET(self): self.answer()
    def answer(self):
        data=self.rfile.read(int(self.headers.get('content-length','0'))).decode(); obj=json.loads(data) if data else {}; q=obj.get('query',''); v=obj.get('variables',{})
        requests.append({'method':self.command,'path':self.path,'query':q,'variables':v})
        if state['fault']=='timeout': time.sleep(3)
        if state['fault']=='error':
            self.send_response(503); body=b'{"message":"local emulator intentionally unavailable"}'
        else:
            number=v.get('number') or v.get('pr_number') or 628
            p=state['prs'].get(int(number),{})
            core={'id':'PR_local','number':int(number),'url':f'https://github.com/lab-owner/lab-repo/pull/{number}','state':'OPEN','mergedAt':None,'isDraft':False,'headRefOid':'a'*40,'author':{'__typename':'User','login':'lab-worker','id':'U_local','name':'Local Worker'},'mergeable':'MERGEABLE','reviewDecision':'APPROVED','headRefName':'fm/lab','headRepository':{'name':'lab-repo'},'headRepositoryOwner':{'login':'lab-owner'},'baseRefName':'main','baseRepository':{'name':'lab-repo','owner':{'login':'lab-owner'}},'baseRef':{'branchProtectionRule':{'requiredStatusCheckContexts':['tests']}},'commits':{'nodes':[{'commit':{'statusCheckRollup':{'contexts':{'nodes':[{'__typename':'CheckRun','name':'tests','status':'COMPLETED','conclusion':'SUCCESS','detailsUrl':'https://example.invalid/tests','isRequired':True,'checkSuite':{'app':{'name':'Local CI'},'workflowRun':{'workflow':{'name':'Local CI'}}}}],'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}]}}
            core.update(p)
            if 'statusCheckRollup: commits' in q: core['statusCheckRollup']=core['commits']
            repo={'id':'R_local','name':'lab-repo','nameWithOwner':'lab-owner/lab-repo','owner':{'login':'lab-owner'},'hasIssuesEnabled':True,'defaultBranchRef':{'name':'main'},'pullRequest':core,'pullRequests':{'nodes':state['list'],'pageInfo':{'hasNextPage':False,'endCursor':None},'totalCount':len(state['list'])}}
            result={'data':{'node':core,'repository':repo,'search':{'nodes':state['list'],'issueCount':len(state['list']),'pageInfo':{'hasNextPage':False,'endCursor':None}}}}
            import re
            def project(o):
                if isinstance(o,dict): return {k:project(value) for k,value in o.items() if k=='__typename' or re.search(r'\b'+re.escape(k)+r'\b',q)}
                if isinstance(o,list): return [project(x) for x in o]
                return o
            result={'data':project(result['data'])}
            if '__type(' in q:
                import re
                names=re.findall(r'(\w+): __type',q)
                result={'data':{n:{'fields':[{'name':x} for x in ['number','headRefName','statusCheckRollup','commits','checkSuites','contexts','isRequired','workflowRun']]} for n in names}}
            if self.command=='GET': result=[] if '/reviews' in self.path else {}
            body=json.dumps(result).encode(); self.send_response(200)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError,ssl.SSLError): pass
server=None; results=[]; homes=[]
def home(name,route=None):
    h=LAB/name; cmd(['bash','bin/fm-lab-home.sh','create',str(h)]); homes.append(h)
    (h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')
    if route:
        (h/'.fm-secondmate-home').write_text(name+'\n')
        (h/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute='+route+'\n'+('parent_home='+str(main)+'\n' if route=='local' else ''))
    return h
def env(h):
    e=ENV.copy(); e['FM_HOME']=str(h); return e
def task(h,id='worker',pr=628,yolo='on',verb='paused',at=1000,branch=False):
    copy=LAB/'copy'
    s=h/'state'; meta=f'kind=ship\nmode=direct-PR\nyolo={yolo}\nworktree={copy}\nharness=claude\nbackend=tmux\nwindow=fm-lab-merge:fm-worker\n'
    if pr: meta+=f'pr=https://github.com/lab-owner/lab-repo/pull/{pr}\n'
    if branch: meta+='branch=fm/lab\n'
    (s/(id+'.meta')).write_text(meta); (s/(id+'.status')).write_text(f'{verb} [at={at}]: Ready fix awaits this home\n')
    cmd(['bash','bin/fm-busy-event.sh','arm',str(s),id,'--state','idle','--source','claude-hook','--event','Stop'],env(h))
def scan(h,now=2800): return cmd(['bash','bin/fm-merge-stall.sh','scan','--now',str(now)],env(h)).stdout
def channel(h,route): return main/'state'/(h.name+'.status') if route=='local' else h/'state/parent-replies.status'
def openkeys(path):
    return cmd(['bash','-c','. bin/fm-classify-lib.sh; status_open_decisions "$1"','_',str(path)]).stdout.strip()
def mark(h,number=628):
    cmd(['bash','-c','. bin/fm-pr-lib.sh; fm_pr_url_parse "$2" && fm_pr_poll_merge_mark_notified "$1/state" worker "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"','_',str(h),f'https://github.com/lab-owner/lab-repo/pull/{number}'],env(h))
def check(name,fn):
    log('\nSCENARIO '+name)
    state.update(prs={},list=[],fault=None)
    try: fn(); results.append({'name':name,'result':'pass','live':True}); log('OBSERVED RESULT: PASS')
    except Exception as ex: results.append({'name':name,'result':'fail','live':True,'error':str(ex)}); log('OBSERVED RESULT: FAIL '+str(ex)); traceback.print_exc(file=LOG)
def pr(number=629,owner='lab-owner',repo='lab-repo',branch='fm/lab',draft=False): return {'url':f'https://github.com/lab-owner/lab-repo/pull/{number}','number':number,'isDraft':draft,'headRefName':branch,'headRepository':{'name':repo},'headRepositoryOwner':{'login':owner}}
try:
    cmd(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(LAB/'key.pem'),'-out',str(LAB/'cert.pem'),'-days','1','-subj','/CN=api.github.com','-addext','subjectAltName=DNS:api.github.com,DNS:github.com'])
    TLS=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); TLS.load_cert_chain(str(LAB/'cert.pem'),str(LAB/'key.pem'))
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy); server.daemon_threads=True; thread=threading.Thread(target=server.serve_forever); thread.start()
    ENV.update(HTTPS_PROXY=f'http://127.0.0.1:{server.server_port}',HTTP_PROXY=f'http://127.0.0.1:{server.server_port}',ALL_PROXY=f'http://127.0.0.1:{server.server_port}',NO_PROXY='',SSL_CERT_FILE=str(LAB/'cert.pem'))
    cmd(['tmux','-S','.merge-stall-live/socket','new-session','-d','-s','fm-lab-merge','-n','fm-worker','-x','120','-y','40','-c',str(ROOT)])
    ENV['TMUX']=cmd(['tmux','-S','.merge-stall-live/socket','display-message','-p','#{socket_path},#{pid},0']).stdout.strip()
    copy=LAB/'copy'; copy.mkdir(); cmd(['git','init','-q',str(copy)]); cmd(['git','-C',str(copy),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','--allow-empty','-qm','Synthetic lab input']); cmd(['git','-C',str(copy),'checkout','--detach','-q']); cmd(['git','-C',str(copy),'remote','add','origin','https://github.com/lab-owner/lab-repo.git'])
    main=home('main')
    # Verify real gh protocol and product reconciliation before scenario assertions.
    cmd(['gh','pr','view','https://github.com/lab-owner/lab-repo/pull/628','--json','state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision'])
    cmd(['bash','bin/fm-pr-state.sh','https://github.com/lab-owner/lab-repo/pull/628'])
    def reminders():
        task(main); cmd(['bash','bin/fm-crew-state.sh','worker'],env(main))
        assert not scan(main,1300).strip()
        out=scan(main,1600); assert 'unmerged 600s' in out and 'merge it now with bin/fm-pr-merge.sh worker' in out
        assert not scan(main,1900).strip()
        out=scan(main,2800); assert 'tell the captain now' in out
        assert not scan(main,3000).strip()
    check('Local CLI: paused authorized worker receives timed reminders and main escalation',reminders)
    def routes():
        for route in ('local','remote'):
            h=home('route-'+route,route); task(h); out=scan(h); assert 'reported to the captain through the parent channel' in out
            c=channel(h,route); assert 'merge-stall-worker-' in openkeys(c)
            scan(h,4600); assert c.read_text().count('blocked ')==1
            mark(h); assert not scan(h,6400).strip(); assert not openkeys(c); assert c.read_text().count('resolved ')==1
            log('PERSISTED PARENT CHANNEL '+str(c)+'\n'+c.read_text())
    check('Local and remote-route disposable homes escalate once and resolve after canonical merge evidence',routes)
    def guards():
        h=home('guards'); task(h,yolo='off'); assert not scan(h).strip()
        task(h); cmd(['bash','bin/fm-busy-event.sh','apply',str(h/'state'),'worker','busy','--current-gen','--source','claude-hook','--event','UserPromptSubmit'],env(h)); assert not scan(h).strip()
        task(h); state['prs'][628]={'isDraft':True}; assert not scan(h).strip(); state['prs'][628]={}
        cmd(['bash','bin/fm-captain-hold.sh','hold','worker','--title','Synthetic approval','--reason','Await explicit approval'],env(h)); assert not scan(h).strip()
        # Positive terminal evidence must retire a prior escalation even when later held.
        h2=home('held-terminal','remote'); task(h2); scan(h2); cmd(['bash','bin/fm-captain-hold.sh','hold','worker','--title','Synthetic approval','--reason','Await explicit approval'],env(h2))
        state['prs'][628]={'state':'CLOSED'}; scan(h2,4600); assert 'merge-stall-' not in openkeys(channel(h2,'remote')); state['prs'][628]={}
    check('Local CLI guards: no authority, busy worker, draft and captain hold suppress merge instructions',guards)
    def discovery():
        for kind,items,expected in [('own',[pr()],True),('other-owner',[pr(owner='someone-else')],False),('other-repo',[pr(repo='other-repo')],False),('other-branch',[pr(branch='fm/other')],False),('ambiguous',[pr(),pr(630)],False),('draft',[pr(draft=True)],False),('mixed',[pr(630,owner='someone-else'),pr()],True)]:
            h=home('discover-'+kind); task(h,pr=None,branch=True); state['list']=items; out=scan(h)
            assert ('merge it now' in out)==expected
            if kind not in ('own','draft','mixed'): assert 'identity not established' in out
        state['list']=[]
    check('Real GitHub CLI against localhost forge: discover only the task push-remote owner, repository and branch',discovery)
    def recovery():
        for route in ('local','remote'):
            for terminal in ('marker','merged','closed'):
                h=home('retire-'+route+'-'+terminal,route); task(h,branch=True); state['list']=[]; scan(h); assert 'merge-stall-' in openkeys(channel(h,route))
                if terminal=='marker': mark(h)
                elif terminal=='merged': state['prs'][628]={'state':'MERGED','mergedAt':'2026-11-26T00:00:00Z'}
                else: state['prs'][628]={'state':'CLOSED'}
                # Reject branch discovery at the real local GitHub endpoint.
                state['fault']='error' if terminal=='marker' else None
                if terminal!='marker': state['list']=[pr(629),pr(630)]
                out=scan(h,4600); assert 'evidence unavailable' in out and 'merge it now' not in out
                assert not (h/'state/.merge-stall').read_text().strip(); assert not openkeys(channel(h,route))
                log('RETIRED CHANNEL\n'+channel(h,route).read_text()); state['fault']=None; state['prs'][628]={}; state['list']=[]
        h=home('uncertain-siblings','remote'); task(h,'a-unknown'); task(h,'z-readable',pr=629)
        # Missing endpoint makes real crew-state unknown. Healthy sibling must progress.
        m=h/'state/a-unknown.meta'; m.write_text(m.read_text().replace('window=fm-lab-merge:fm-worker','window=fm-lab-merge:gone'))
        out=scan(h); assert 'current activity unreadable for a-unknown' in out and 'z-readable PR' in out and 'merge it now' in out
        # Active unknown forge evidence retains an existing blocker, then recovery clears it.
        h=home('preserve-uncertain','remote'); task(h); scan(h); before=(h/'state/.merge-stall').read_text(); state['fault']='error'; out=scan(h,4600); assert 'forge state unreadable' in out; assert (h/'state/.merge-stall').read_text()==before; assert openkeys(channel(h,'remote')); state['fault']=None
        # A later PR from this same task is discovered after the recorded PR retires.
        h=home('later-pr'); task(h,branch=True); mark(h); state['list']=[pr()]; out=scan(h); assert '/pull/629' in out and 'merge it now' in out and '/pull/628' not in out; state['list']=[]
    check('Local CLI recovery: retired PR blockers close despite replacement uncertainty, live unknowns persist and siblings progress',recovery)
    def watcher():
        h=home('watcher'); now=int(time.time()); task(h,at=now-1900)
        e=env(h); e.update(FM_POLL='1',FM_CHECK_INTERVAL='1',FM_SIGNAL_GRACE='1',FM_HEARTBEAT='999999',FM_MERGE_STALL_READ_TIMEOUT='1')
        out=cmd(['bash','bin/fm-watch.sh'],e,timeout=35).stdout
        q=h/'state/.wake-queue'; assert q.exists() and 'check: merge stall: worker PR' in q.read_text(); log('PERSISTED HOME NOTIFICATION\n'+q.read_text())
    check('Real watcher: local polling queues an actionable merge-stall notification',watcher)
except Exception as ex:
    log('SETUP OR DRIVER FAILURE: '+repr(ex)); traceback.print_exc(file=LOG); results.append({'name':'live setup','result':'fail','live':False,'error':repr(ex)})
finally:
    if server: server.shutdown(); server.server_close(); thread.join(timeout=5)
    cmd(['tmux','-S','.merge-stall-live/socket','kill-server'],ok=False)
    (E/'github-emulator-requests.json').write_text(json.dumps(requests,indent=2))
    (E/'live-results.json').write_text(json.dumps(results,indent=2))
    log('CLEANUP: stopped localhost forge emulator and isolated tmux server; disposable lab removed')
    shutil.rmtree(LAB)
    LOG.close()
if any(r['result']!='pass' for r in results): raise SystemExit(1)
