from pathlib import Path
import subprocess,json,os,datetime,html
E=Path('~/.no-mistakes/evidence/01M87Y5E24QJM9D7GRZBS9GVZA')
ROOT=Path('{run-worktree}')
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()=='e7e4e20a0d56bb8d973736e24d0c7d98fdae6879'
assert subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True)==''
assert (E/'live2/omp-portable-isolated.exit').read_text().strip()=='0'
assert (E/'live2/spawn.exit').read_text().strip()=='0'
assert (E/'live2/relaunch.exit').read_text().strip()=='0'
spawn=(E/'live2/spawn-pane.txt').read_text(); relaunch=(E/'live2/relaunch-pane.txt').read_text()
assert any(l.strip()=='NEON_READY COPPER-COMET-9146' for l in spawn.splitlines())
assert any(l.strip()=='NEON_READY SILVER-ORBIT-6829' for l in relaunch.splitlines())
assert 'RESOURCE_EXHAUSTED' not in spawn+relaunch and 'code 429' not in spawn+relaunch
assert 'phase=complete' in (E/'live2/relaunch-transaction.txt').read_text()
def agent_args(name):
 lines=(E/f'live2/{name}-process.txt').read_text().splitlines()
 return [l for l in lines if '/omp --profile neon ' in l and '--cwd ' in l]
a=agent_args('spawn'); b=agent_args('relaunch'); assert len(a)==len(b)==1
assert a[0].strip().split()[0]!=b[0].strip().split()[0]
for line in a+b:
 assert '--system-prompt '+str(ROOT/'.omp/fm-antigravity-system-prompt.md') in line
 assert '--model antigravity-cli/gemini-4-neon --thinking xhigh' in line
boundary=[]
for name,expected in [('alternate',True),('other',False),('scout',False)]:
 rows=json.loads((E/f'scope-{name}-process.json').read_text())
 assert rows
 for row in rows: assert ('--system-prompt ' in row['args'])==expected
 boundary.append({'case':name,'system_prompt_present':expected,'real_omp_processes':rows})
(E/'scope-results.json').write_text(json.dumps(boundary,indent=2)+'\n')
# Verify only processes attributable to this run. ACP cwd is checked because its
# argv names the profile, not the throwaway working directory.
remaining=[]
for line in subprocess.check_output(['ps','-axo','pid=,ppid=,args='],text=True).splitlines():
 bits=line.strip().split(None,2)
 if len(bits)!=3:continue
 pid,ppid,args=bits
 if args.startswith('~/.bun/bin/omp ') and str(E) in args:
  remaining.append({'pid':int(pid),'args':args})
 elif '/antigravity-cli/bin/' in args and 'agy acp ' in args:
  cwd=subprocess.run(['lsof','-a','-p',pid,'-d','cwd','-Fn'],capture_output=True,text=True).stdout
  if str(E) in cwd: remaining.append({'pid':int(pid),'args':args,'cwd':cwd})
assert not remaining,remaining
removed={str(p.relative_to(E)):not p.exists() for p in [E/'l',E/'b',E/'default-control',E/'live2/l']}
assert all(removed.values())
cleanup={'time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scratch_paths_removed':removed,'remaining_owned_omp_or_acp_processes':remaining,'source_worktree_clean':True}
(E/'cleanup-verification.json').write_text(json.dumps(cleanup,indent=2)+'\n')
report=f'''# Neon secondmate launch evidence

Verified on 2026-11-24. Target: `e7e4e20a0d56bb8d973736e24d0c7d98fdae6879`. Real omp: `19.1.1`.

## Oracle and scope

The author's intent requires a replacement system prompt for omp secondmates on every `antigravity-cli/` model. Other omp providers and worker kinds retain omp's prompt. The independent context oracle is a synthetic token stored only in the disposable home's AGENTS.md. A different token is written before relaunch. These checks reject a Neon-only implementation, a flag applied to every provider or kind, lost context loading, and a relaunch that merely repeats earlier output.

## Spawn – passed

Executed `bin/fm-spawn.sh sm <scratch-home> --secondmate` on a private tmux socket, with real omp and the existing neon login. The scratch parent's durable pin selected `omp antigravity-cli/gemini-4-neon xhigh` and its per-secondmate profile pin selected `neon`. The observed real process carried `--profile neon`, the tracked `--system-prompt`, and `--thinking xhigh`.

The live terminal returned:

```text
NEON_READY COPPER-COMET-9146
```

No RESOURCE_EXHAUSTED or code 429 appeared. The terminal had a nonzero 180 by 55 grid. Files: `live2/spawn.log`, `live2/spawn-process.txt`, `live2/spawn-terminal.txt`, `live2/spawn-pane.txt`.

## Relaunch – passed

Changed only the scratch context token, then executed `bin/fm-control.sh sm relaunch`. The transaction reached `phase=complete`, the omp process changed, and the replacement retained the profile, model, thinking level, and replacement prompt. The fresh reply was:

```text
NEON_READY SILVER-ORBIT-6829
```

This token was absent from the charter and previous terminal reply. No RESOURCE_EXHAUSTED or code 429 appeared. Files: `live2/relaunch.log`, `live2/relaunch-process.txt`, `live2/relaunch-transaction.txt`, `live2/relaunch-pane.txt`.

## Provider and kind boundary – passed

Real `fm-spawn.sh` launched real omp processes on private tmux, with synthetic disposable homes and records. The boundary oracle is the author's command-line contract; model responses are not claimed for these cases.

| Launch | Observed replacement prompt |
| --- | --- |
| Secondmate, antigravity-cli/gemini-4-argon | Present |
| Secondmate, google/gemini-4-neon | Absent |
| Scout relaunch, antigravity-cli/gemini-4-neon | Absent |

Files: `scope-results.json`, `scope-alternate-process.json`, `scope-other-process.json`, `scope-scout-process.json` and corresponding launch logs. The first scout fixture was correctly refused because its worktree equalled its project. A separate scratch git worktree corrected that setup, and the retry exited zero.

## Targeted regression and baseline attempts

`bash tests/fm-omp-harness.test.sh` exited zero inside private tmux. The first direct invocation stopped at an ancestry assertion because the enclosing agent is Codex; running under the private tmux server removed that setup interference. No source was changed. Files: `omp-portable.log`, `live2/omp-portable-isolated.log`, `live2/omp-portable-isolated.exit`.

A separate real `omp --profile neon --model antigravity-cli/gemini-4-neon --thinking xhigh --no-session -p ...` control used omp's default system prompt and the same posture overlay. It produced no completed answer or 429 within 70 seconds, then was stopped and reaped. This run does not reproduce the original 429. Files: `default-prompt-control.log`, `default-prompt-control-result.json`.

The initial relaunch capture could still contain earlier scrollback. The final proof above uses a fresh token to reject that false positive.

## Cleanup

All private tmux servers and attributable omp and agy ACP processes stopped. All four scratch roots were removed. The source worktree is unchanged. Evidence is retained only here. The earlier cleanup encountered read-only generated git-hook directories; their permissions were restored inside the scratch root before removal. File: `cleanup-verification.json`.

No linter, formatter, static analysis, full repository suite, publication, PR mutation, or CI phase ran. The requested private operator report path is outside this Test phase's write boundary; this run's transcript excerpts are retained in this evidence directory.
'''
(E/'neon-live-evidence.md').write_text(report)
# Render the captured end-user terminal text as a reviewer-visible standalone
# artifact. This is a transcript rendering, not a native screenshot.
parts=[]
for title,body in [('Spawn: token from the scratch AGENTS.md',spawn),('Relaunch: fresh token from the scratch AGENTS.md',relaunch)]:
 parts.append('<section><h2>'+html.escape(title)+'</h2><pre>'+html.escape(body)+'</pre></section>')
(E/'neon-terminal-transcripts.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><title>Neon launch terminal transcripts</title><style>body{background:#15191f;color:#e5e9ef;font:16px system-ui;margin:32px}h1,h2{font-weight:550}pre{background:#080d13;padding:24px;white-space:pre-wrap;font:13px/1.5 ui-monospace,monospace}section{margin-bottom:40px}</style><h1>Neon secondmate launch and relaunch</h1><p>Captured from real omp 19.1.1 on 2026-11-24. Transcript rendering; this is not a screenshot.</p>'+''.join(parts)+'</html>')
print(json.dumps({'required_scenarios':'all passed','cleanup':cleanup,'report':str(E/'neon-live-evidence.md')},indent=2))
