# PR #324 Review: Waiting Room regeneration

**Repo:** Panenco/qiv · **Author:** ruthsavchenko · **Branch:** `feature/waiting-room-regeneration` → `main` · **Size:** 59 files, +3,682 / −15

## Context

A drag-and-drop waiting-room prototype, gated behind `<Prototype>` / `@UseGuards(PrototypeGuard)`. Wires up a real (interim) API: check-in / move / undo via TanStack Query mutations, walk-in dialog, room-visibility settings persisted in `localStorage`, plus `GET /api/prototype/patients` extensions (locationIds, dob year range, sortBy/sortDir, richer `search`). Integration tests for the API extensions are in place. Implementation is internally consistent and follows the project's prototype conventions (`// PROTOTYPE` markers, `prototype/` URL prefix, generated SDK calls).

Prior automated reviewers (cursor[bot], panenco-claude-reviewer) flagged several items; **the worst of those (seed wiping assignments, walk-ins sorting on top, empty visible-rooms selection persistence) have already been fixed in this PR**. The findings below are what remains after re-reading the current head against the project's conventions.

> **Note on screenshots:** the PR description has no screenshots/GIFs for a 3,682-line UI feature. Worth requesting at least one screenshot of the populated waiting room + the walk-in dialog + the appointment filter dialog before merge — visual regressions in a prototype this large can't be caught from the diff alone, and the prototype is the demo surface.

## Bugs

| File | Line | Comment |
|------|------|---------|
| `apps/web/src/features/waiting-room/components/waiting-room-page-content.tsx` | 101-105, 152 | `patientIdsInRooms` is computed and passed to `WaitingRoomSchedulePanel` but **not** to `WaitingRoomPatientSearchPanel` — the patient search panel will happily let you drag a patient who is already in a waiting room into another room, creating a duplicate assignment. The schedule panel filters such patients out (correct); search must do the same. |
| `apps/web/src/features/waiting-room/components/waiting-room-patient-search-panel.tsx` | 34, 78-100 | Same bug, downstream: accept a `patientIdsInRooms: Set<string>` prop and filter `visible` before rendering. |
| `apps/web/src/features/waiting-room/components/waiting-room-patient-search-panel.tsx` | 34, 78 | Search query goes straight into the React Query key on every keystroke, and the empty/skeleton branches key off `isLoading` instead of `isFetching` — typing into the box clears the table between keystrokes. Debounce the query (~300 ms) or pass `placeholderData: keepPreviousData` to `useSearchPatients` and gate the empty state on `!isFetching`. |
| `apps/web/src/features/waiting-room/components/drag-handle-button.tsx` | 20-25 | Drag handle is `opacity-0 group-hover:opacity-100` only — keyboard-tab focus lands on a fully invisible button (the Button primitive otherwise stays focusable). Add `focus-visible:opacity-100` (and `group-focus-within:opacity-100` on the row) so keyboard users can see and target it. |
| `apps/web/src/features/waiting-room/api.ts` | 38-47 | `parseNotesMeta` silently falls back to `EMPTY_META` on `JSON.parse` failure or a missing `wr-meta:` prefix — meaning any external edit to `notes` (or a schema drift) will silently reset `queueStatus`/scheduled-times/doctor in the UI without any signal. At minimum log a warning; ideally surface a "stale data" badge so the prototype doesn't quietly lose state during dogfooding. |

## Code Quality

| File | Line | Comment |
|------|------|---------|
| `apps/web/src/features/waiting-room/api.ts` | 23-33, 70-72 | `notes` column is being overloaded as a JSON blob (`wr-meta:` prefix) to carry `queueStatus`, `scheduledStart/End`, `doctor*`, `appointmentType`, and `freeText`. Code comments call it "until dedicated columns exist," but the PR description and PRD link don't mention a follow-up issue — file one and reference it in both `api.ts` and `seed.ts` so this doesn't outlive its intended lifetime. |
| `apps/web/src/features/waiting-room/api.ts` | 70 | `encodeNotesMeta` is exported but only used inside this module — drop the `export`. |
| `apps/web/src/features/waiting-room/types.ts` | 1, 83-86 | `WalkInPayload` (and its `import type { Patient }`) is dead — no references anywhere in the diff. Delete both. |
| `apps/web/src/features/waiting-room/hooks/use-visible-waiting-rooms.ts` | 1-58 | 58 lines — violates `.claude/rules/web.md` "Hooks ≤ 50 lines." Inline the storage helpers into the hook or move them to a sibling `lib/visible-rooms-storage.ts` and keep the hook itself under the limit. |
| `apps/web/src/features/waiting-room/hooks/use-waiting-room-drag-drop.ts` | 1-57 | 57 lines — same hook-size rule. The branchy `handleDragEnd` body can move to `lib/drag-drop-handlers.ts` (which already exists). |
| `apps/web/src/features/waiting-room/components/waiting-rooms-panel.tsx` | 17-29 | `localeCompare` on ISO 8601 strings — they're already lexicographically ordered, plain `<`/`>` is faster and matches what the rest of this PR uses for date comparisons. |
| `apps/web/src/features/waiting-room/components/waiting-room-page-content.tsx` | 55, `hooks/use-waiting-room-drag-drop.ts:14` | `useCreateAssignment` is instantiated twice — once in page-content (walk-in path), once inside the drag-drop hook (appointment-to-room path). Each carries its own `isPending`/toast lifecycle. Move the mutation up to the page (or pass `mutate` down) so there's one source of truth — otherwise an in-flight appointment drop won't disable the walk-in confirm button, and vice versa. |

## Maintainability / Spec

| File | Line | Comment |
|------|------|---------|
| `apps/web/src/features/waiting-room/hooks/use-create-assignment.ts` + walk-in flow | — | Walk-in creates a `WaitingRoomAssignment` only — no `Appointment` / `Consultation` row, even though the PRD implies one. Documented in code comments as the prototype shortcut, but worth a TODO/issue link in `use-create-assignment.ts` so the gap is tracked. |
| `apps/web/src/features/waiting-room/api.ts` | 173-184 | `listTodayAppointments` builds the day window in UTC; `seed.ts:daysAgo`/`todayAt` build dates in **local** time. In CET this is fine for now, but if anyone runs the prototype outside a positive-UTC offset around midnight the today-list will silently drop appointments. Cheap fix: build the window in local time (`new Date(y, m, d)`/`+1 day`) to match the seed and the user's mental model. |
| PR description | — | No screenshots/GIFs and no link to the rendered preview. For a UI prototype of this size, add: (a) populated waiting room, (b) empty room drop state, (c) walk-in dialog, (d) settings dialog with selectAll indeterminate state. |

## Notes

- Already-fixed in this PR (no comment needed): seed `deleteMany` wipe, walk-in sort-on-top, visible-rooms empty-selection persistence, UTC midnight in `listTodayAppointments` of the prior round, Checkbox `data-[state=checked]` selector fix.
- Test coverage: API extensions have a 207-line integration spec (`apps/api/test/patients/list-patients.spec.ts`) that covers sort, location filter, dob range, and the new search formats — good. No web tests for the drag-drop flows, which is acceptable for a prototype but worth noting in the promotion checklist.
