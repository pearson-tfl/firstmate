# Domain docs

Before exploring an area, read the root `GLOSSARY.md` if present, or use `GLOSSARY-MAP.md` to find the relevant context glossaries.
Read relevant decisions in `docs/adr/` and any context-specific ADR directories if they exist.
If these files or directories are absent, proceed silently; create them only when their first terms or decisions are resolved, not as empty setup scaffolding.

Use the glossary's vocabulary when naming domain concepts in issues, proposals, code, and tests.
If a needed concept is missing, reconsider the term or note it for domain modeling.

Surface any conflict with an existing ADR explicitly.
Change a recorded decision through a new numbered ADR that names the decision it supersedes.
Keep the old decision text and add a status note linking to its replacement, identifying any partial supersession.
