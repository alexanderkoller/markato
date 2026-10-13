# Repository agent instructions

- Never request or use computer-control or UI-automation access for this repository. The user has explicitly declined that access permanently.
- Verify application behavior with command-line builds, tests, and purpose-built automated test harnesses instead.
- Avoid O(document size) work when a change can be handled incrementally or by reprocessing only the affected range. Preserve retained layout, parse, and render state wherever possible; use a full-document pass only when correctness genuinely requires it.
- When the user says only “commit”, stage the completed task's source and supporting files and create a commit without rerunning safety checks. Preserve unrelated working-tree changes.
