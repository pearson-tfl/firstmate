schema=fm-task-inbox.v1
at=2026-11-26T18:48:13Z
body-terminator=1
--
[fm-from-firstmate]⁣corr=8944f117ea5646cc Hill-climb the synthetic wiki

# Required skills
Required skills: poteto-mode,tdd
The request named these skills, so each one must shape this work, and firstmate checks the record mechanically.
1. Before any other status line, load each skill (`read and follow the complete SKILL.md for /poteto-mode`, `read and follow the complete SKILL.md for /tdd`) through the skill tool or read its complete SKILL.md, then report one start proof per skill: `bin/fm-secondmate-report.sh working "skill-start <name> path=<SKILL.md path you read> route=<your first routing decision under it>"`
   Firstmate keeps ringing this request until every start proof is present, even after you acknowledge it.
2. Before reporting done, report one line per skill saying how it shaped the work: `bin/fm-secondmate-report.sh working "skill-shaped <name>: <how the skill shaped the work>"`
   A done without one is refused, naming the missing skill.
