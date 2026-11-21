# Project Tracking Rules (mandatory)

Project state lives in `tasks/`, not in chat history. If a result, decision or running job is not written in `tasks/`, treat it as lost.
Full protocol: `tasks/README.md`. Hierarchy: `INDEX.md` (L0 route) → `TASK-*.md` (L1 feature) → `HANDOFF-*.md` (L2 checkpoint).

## 1. Session start
- For any request about this project, silently read `tasks/INDEX.md` first; route to the relevant TASK and its `current_handoff` only as needed.
- Recorded SHA/state is historical. Run `git status --short --branch` and `git rev-parse HEAD` in the target worktree before any code/state claim or edit.
- Answer the user's direct request first. Show the full task list only when asked.

## 2. Write-back triggers: record when it happens, not "at the end"
Write a checkpoint (Section 3) as soon as any of these occurs:
- a commit, or source changes you are about to leave or hand off;
- a long-running job is launched: record command, host/GPU, tmux/PID, log and exit-file paths, completion gate;
- a job finishes or fails, or any "running/pending" state already recorded becomes false;
- a verification/numerical result, a new blocker, or a user decision/authorization;
- you are about to end the turn with any of the above unrecorded.
Not a trigger: pure Q&A or discussion that changed no state and made no durable decision.

## 3. Checkpoint checklist (all four, in the same turn)
1. **HANDOFF**: new `tasks/HANDOFF-YYYYMMDD-HHMMSS-kebab-name.md` from `_templates/`. Include live branch/SHA, dirty files, what changed, evidence (paths, numbers, exit codes), failed attempts, open risks, one exact next step. Never edit a previous session's handoff; supersede it with a new one.
2. **TASK**: update `current_handoff`, checklist, Current State, status.
3. **INDEX Active Tasks**: replace (do not append to) the task's one-line status so it matches the newest handoff. Completed/cancelled → move to Completed Task Registry.
4. **INDEX bookkeeping**: `Last updated`, Latest checkpoint, affected Source Checkpoint row, and a new Handoff Registry row at the top (newest first).

## 4. Invariants
- Every HANDOFF belongs to exactly one TASK listed in INDEX. New workstream → create the TASK first (`_templates/TASK.md`), then its handoffs. No orphan handoffs.
- INDEX must never contradict the newest handoff. Whenever you touch a task, re-verify or update every "running / active / pending" claim about it.
- Filenames follow the format exactly (date + HHMMSS + kebab name). Handoff bodies state the timezone; use the project timezone from `tasks/README.md`.
- Claims match evidence: use "running", "passed", "failed", "unverified" literally. `completed` requires evidence for every acceptance criterion.
- INDEX stays short: one line per active task, no free text outside defined sections. Details go to TASK/HANDOFF.
- Never delete or overwrite delivered packages, other users' artifacts, or historical handoffs.

## 5. Final response footer (self-check)
End every project-related response with exactly one line:
`任务进展：<task> — <status>；下一门槛：<gate>；记录：<HANDOFF filename|无状态变更>`
If you cannot truthfully fill `记录`, complete Section 3 before replying.

## 6. Current Project Entries

<!-- OCR boundary: The supplied screenshots end at this heading; subsequent content is not visible. -->
