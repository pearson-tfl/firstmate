# Merge-stall live validation – 26 November 2026

Branch: `fm/ahrmergestall`  
Base: `ea9c0e97dc33182f8908705aab6a1fe699f93eaf`  
Target: `f20a449d53a9f8331eeea990ccc59c5a9f2ccb74`

Six local live scenarios passed. The executable product was `bin/fm-merge-stall.sh` and `bin/fm-watch.sh`, with the real `fm-crew-state.sh`, `fm-captain-hold.sh`, `fm-pr-state.sh`, classifier and parent-channel libraries. The installed GitHub CLI communicated with an isolated localhost HTTPS forge emulator. No product helper was replaced with a stub. PRs, worker lifecycle events and waiting times were synthetic inputs. The worker endpoint was a detached 120 × 40 tmux shell in a private socket. No model or live fleet session was used.

The acceptance oracle was the supplied user intent plus the recorded decisions: the accepted initial threshold is 600 seconds; escalation is at 1800 seconds; unauthorized, busy, held and draft work must not receive merge instructions; confirmed terminal PR identities must retire despite uncertain replacement evidence; discovery must bind the PR head to the task push remote and branch. The retained-PR replacement-registration case described by declined R23 was not changed or added to the acceptance criteria.

| Scenario | Observed product behavior | Wrong behavior rejected |
| --- | --- | --- |
| Reminder timing | Silence at 300 seconds; merge instruction at 600; backoff; main escalation at 1800 | Fresh waits trigger immediately, reminders disappear, or escalation never appears |
| Both parent routes, exercised locally | One keyed blocked event; repeated scans do not duplicate it; canonical merge receipt emits matching resolved event | Duplicate escalation or unresolved blocker after confirmed merge |
| Authorization and activity guards | No instruction for yolo off, busy worker, draft PR or captain hold; terminal evidence retires a held merge-stall blocker while preserving the independent captain hold | Unsafe merge instruction or obsolete merge blocker |
| PR head identity through real GitHub CLI | Own push-remote owner/repository/branch accepted; other owner, repository, branch and ambiguous matches diagnosed; draft ignored; own PR selected among other-fork matches | Another fork receives the merge instruction or hides the correct match |
| Uncertain evidence and retirement | Active unknown evidence retains the blocker; confirmed merge/closure resolves it despite replacement discovery failure; a missing endpoint does not starve a readable sibling; subsequent PR is discovered | False resolution of a live wait, restoration of retired PR, sibling starvation or later PR silence |
| Watcher integration | Real poll emits and durably queues an actionable merge-stall notification | Scanner output never enters the home's notification queue |

## Product output

### First due reminder

```text
worker PR https://github.com/lab-owner/lab-repo/pull/628 unmerged 600s while its worker waits on this home (paused: Ready fix awaits this home); this home merges it without asking: merge it now with bin/fm-pr-merge.sh worker https://github.com/lab-owner/lab-repo/pull/628, and if that refuses, act on the refusal [forge: no blockers seen]
```

### Foreign-head protection

```text
evidence unavailable: PR discovery for worker found 1 open PR(s) on fm/lab with 0 from lab-owner/lab-repo; identity not established
```

### Uncertain replacement evidence

```text
evidence unavailable: PR discovery failed for worker (rc=1): HTTP 503: local emulator intentionally unavailable (https://api.github.com/graphql)
```

### Terminal retirement

```text
resolved [key=merge-stall-worker-38789529] [at=1795665551]: merge stall worker: PR https://github.com/lab-owner/lab-repo/pull/628 is no longer a merge candidate or its worker waiting episode ended
```

### Watcher output

```text
check: merge stall: worker PR https://github.com/lab-owner/lab-repo/pull/628 unmerged 1901s while its worker waits on this home (paused: Ready fix awaits this home); this home merges it without asking: merge it now with bin/fm-pr-merge.sh worker https://github.com/lab-owner/lab-repo/pull/628, and if that refuses, act on the refusal [forge: no blockers seen]; stalled past 1800s: tell the captain now
```

## Limits and cleanup

These are local product checks. The remote parent-channel record format was exercised locally. No real Dell transport, production GitHub data, production PR merge, or supervising model interpretation was exercised. The tested change surfaces the stall; `fm-pr-merge.sh` remains the existing merge executor.

The localhost emulator was shut down and joined. The private tmux server returned exit 0 on shutdown. The disposable `.merge-stall-live` directory was removed. No source edits were required. There is no new rendered UI surface; the reviewer-visible evidence is the actual CLI output and persisted parent-channel/notification records in `live-product-transcript.log`.

`live-driver.py` is the replayable evidence driver. `github-emulator-requests.json` records the real GitHub CLI GraphQL requests, without authorization headers. `targeted-regression.log` is supplemental mocked regression coverage and is not the basis for the live=true results.

The targeted `bash tests/fm-merge-stall.test.sh` run completed with exit 0. The live evidence driver completed with exit 0. Final git status was clean at the target commit. Scoped process checks found no remaining test watcher or live-driver process.
