# Issue tracker: GitHub

Tickets for John's Firstmate fork live in [`pearson-tfl/Agent-Harness-Reconfig`](https://github.com/pearson-tfl/Agent-Harness-Reconfig/issues?q=label%3Afirstmate-fork), labelled `firstmate-fork`.
Use `gh-axi` with an explicit repository because this checkout's remote points to the fork, not the ticket tracker.

## Conventions

- List fork tickets: `gh-axi issue list -R pearson-tfl/Agent-Harness-Reconfig --label firstmate-fork --state open`.
- Read a ticket: `gh-axi issue view <number> -R pearson-tfl/Agent-Harness-Reconfig --full`.
  Read its comments separately with `gh-axi api repos/pearson-tfl/Agent-Harness-Reconfig/issues/<number>/comments --paginate --full`.
- Publish a ticket to the tracker: `gh-axi issue create -R pearson-tfl/Agent-Harness-Reconfig --label firstmate-fork --title "..." --body-file <path>`.
- Apply triage labels according to [triage-labels.md](triage-labels.md).

Pull requests for John's own work target `pearson-tfl/firstmate` `main`, as described in [CONTRIBUTING.md](../../CONTRIBUTING.md#work-on-johns-fork).
Link the AHR ticket from the fork pull request using its full URL so the repository is unambiguous.

## Pull requests as a triage surface

**PRs as a request surface: no.**
Requests belong in the ticket tracker above.
