# Task System Protocol

## Purpose

This directory makes project state recoverable without chat history. `INDEX.md` routes a new agent; task briefs hold stable feature intent; handoffs hold volatile session state.

## Naming

```text
tasks/TASK-YYYYMMDD-kebab-case-name.md
tasks/HANDOFF-YYYYMMDD-HHMMSS-kebab-case-name.md
```

- Date: `YYYYMMDD`.
- Time: `HHMMSS`, local project timezone (`US/Pacific`) unless the handoff states otherwise.
- Name: lowercase words separated by hyphens.
- Task filenames are stable after creation.
- Each material resume checkpoint gets a new handoff filename.

## Three Levels

### L0 — INDEX

Contains project overview, canonical document map, active tasks, current source checkpoint and handoff registry. It must remain short enough for every new agent to read first.

### L1 — TASK

One feature-level object. It changes as the feature moves through planning, implementation, review and completion. It owns:

- goal and non-goals;
- exact repositories/branches;
- plan and acceptance criteria;
- dependencies/blockers;
- `current_handoff` pointer;
- required canonical context.

### L2 — HANDOFF

One timestamped checkpoint. It records facts needed to resume safely:

- exact SHA and dirty files;
- completed changes and verification evidence;
- failed attempts and environment limitations;
- unresolved decisions and risks;
- smallest exact next step.

Handoffs are append-only history. Correct factual mistakes in place only within the same session; otherwise create a new handoff that supersedes the prior checkpoint.

## New Session

1. Silently read `tasks/INDEX.md` when the request is about this project.
2. Route the direct request to the relevant task; do not require task selection first.
3. Read that task and its current handoff only when their context is needed.
4. Answer the user's direct question or request first.
5. End the final response with a concise `任务进展：<task> — <status>；下一门槛：<gate>。` line.
6. Recheck live Git state before making code/state claims or edits.

Show the full active-task list only if the user explicitly asks for task status, task selection, or task management.

## Starting A New Task

1. Copy `_templates/TASK.md` to `TASK-<date>-<name>.md`.
2. Add it to INDEX Active Tasks with a linked name.
3. Set `current_handoff: null` until material work begins.
4. Create the first handoff before pausing or after the first material result.

## Ending Or Pausing Work

After a material change, result, blocker or decision:

1. Create `HANDOFF-<date>-<time>-<name>.md` from the template.
2. Record live Git status, exact SHA, changed/untouched files, verification and limitations.
3. Update the task's `current_handoff`, checklist and Current State.
4. Update INDEX source checkpoint and handoff registry.
5. If completed/cancelled, remove the task from Active Tasks and add it to Completed Task Registry.

Do not create a handoff for a discussion that changed no project state and introduced no durable decision.

## Status Rules

- `planning`: scope exists but implementation cannot yet be claimed.
- `in-progress`: someone can execute the named next step now.
- `blocked`: the blocker and unblock action must be explicit.
- `review`: implementation exists; review/approval remains.
- `completed`: every acceptance criterion is met.
- `cancelled`: intentionally stopped; reason preserved.

At most one task should claim the same source file as actively edited unless both task briefs explicitly document concurrency ownership.
