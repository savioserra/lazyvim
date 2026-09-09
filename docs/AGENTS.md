# Documentation instructions

- Write reference documentation, not chronological or decision-process narrative.
- Prefer tables, invariants, commands, paths, and dependency diagrams.
- Describe current behavior; label historical rationale explicitly and keep repair receipts in Backlog/Git.
- Keep installation/daily use in `README.md`, detailed checks in `testing.md`, lifecycle/package contracts in `capabilities.md`, backend/cutover in `chezmoi.md`, and pins in `tools.md`.
- Root `AGENTS.md` is the short operating contract; scoped files add local rules only. `index.md` is navigation, not another policy list.
- Link to the owning reference instead of copying long lists.
- Update path references in the same change as code moves.
- Do not preserve obsolete architecture reports in active docs; Git history is the archive.
