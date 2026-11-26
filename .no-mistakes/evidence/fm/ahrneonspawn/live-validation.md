# Neon launch validation

Host: dell-v100 (Linux). Installed CLI: omp/19.2.1.

- Real fm-spawn ship: antigravity-cli/gemini-4-neon, xhigh; process carried --profile neon and --system-prompt pointing to the tracked replacement. The worker answered 23 × 29 with 667.
- Real fm-spawn scout: same model, profile, prompt, and effort; independently answered 667.
- Real preflight rejected nonexistent models for both antigravity-cli (Neon catalog) and llama.cpp (ambient catalog), exited 1, and created neither task metadata nor worker window. The ambient catalog lists llama.cpp; the Neon catalog lists antigravity-cli. This rejects accidentally using the Neon profile for every provider.
- Additional direct real OMP print request, using the same profile/prompt/model/effort, answered 17 × 19 with 323 and exited 0.
- Targeted tests/fm-omp-harness.test.sh completed with exit 0 on the isolated tmux server, including the new ship/scout checks, other-provider exclusions, and secondmate profile regressions. Its fake vendor interfaces are supporting regression evidence, not live model proof.

Evidence: ship-pane.txt and scout-pane.txt contain actual worker replies; launch-observations.json records host, metadata and actual running command prefixes; model-guards-final.log contains real refusals.

Setup corrections: the first portable run encountered Codex ancestor detection; running on a private tmux server removed that interference. A repository-local temporary root hit the existing secondmate nesting guard; the successful portable run used the suite's normal disposable temporary root. The first long private socket path exceeded the Unix socket limit; a shorter repository-local lab home fixed it. The first alternate-provider guard used an unlisted provider and was replaced with the actually listed llama.cpp provider. Treehouse's pane shell did not inherit the driver shell's TREEHOUSE_ROOT, so its generated synthetic pool used its default location; both exact generated slots were removed through treehouse destroy after stopping the lab.

Cleanup completed: both private tmux servers stopped, both generated Treehouse slots destroyed, all repository-local fixture directories removed, and no matching live worker or driver process remained. Git status was clean. No product or test source changes were made.
