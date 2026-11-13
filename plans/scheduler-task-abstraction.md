# Scheduler task abstraction

Goal: every piece of widget work runs through one scheduler that grants it
nominal slots (2,000 instructions each) and shares them fairly, so the
per-callback budget can be raised in one place.

Today only panel refreshes and service updates are slotted, in `dispatchDue`
(`main.lua`). Flight polling, session reset, loading, reflow, the menu, model
settings, the log viewer, the editor and input handling run outside it, and
nothing in the queue can run twice in one callback.

## Decision: a new scheduler module, keeping the slot semantics

Extending `dispatchDue` in place is rejected. It hard-codes two kinds of work
(`registry.order` services and `context.panels`), each with its own copy of the
grant, consumption check, deferral and stats code, and host work fits neither.
Multi-pass fairness changes its loop anyway.

Add `lib/scheduler.lua`: pure Lua with no EdgeTX or panel knowledge, so it is
unit tested on its own. Panels, services and host work become tasks. What is
kept from the current queue is its slot behavior, not its code: fixed and
variable costs, free (zero-cost) tasks, the deferred task keeping its turn,
consumption validation, and utilization stats.

## Task

A task is a table. For each callback the host enrols its work with
`scheduler.add(task)` in ring order, calls `scheduler.run`, then
`scheduler.clear()`. The scheduler keeps nothing between callbacks except the
cursor, an index, so a retired panel is collectable at once and the cursor
holds its place while membership changes. Hosts build the ring from the
structures they already own (the service registry, the panel list, their own
host tasks), so a panel added, replaced or retired needs no registration.
Calls are `scheduler.add`, `scheduler.run`, with a dot.

| Field | Meaning |
| --- | --- |
| `name` | Label for diagnostics and errors. |
| `step(task, now, slots, ctx)` | One bounded unit of work. Returns `used, again`. Required. |
| `cost` | Integer `0..capacity`, or `"variable"`. Default 1. Read before every step, so a step may change it for the next one. |
| `due` | Tick from which the task is eligible. The task owns it and updates it itself. Default 0. |
| `ready(task, now, ctx)` | Optional extra gate. Return false to skip the task this pass. |

The scheduler sets `failed`, `error`, `pending` and `spent` (cumulative slots
charged). `ctx` is an opaque value the host passes to `run`; the scheduler only
forwards it.

**Cost.**
- A fixed task runs only if `cost` fits in the remaining slots, and is charged
  exactly `cost` whatever `step` returns.
- A `"variable"` task is granted all remaining slots, and `step` returns how
  many it used (`0..slots`, whole numbers). The rest stays available to others.
- A cost of 0 is an ordinary task that costs nothing; it still runs after
  charged work is deferred.
- A task that needs the whole callback declares `cost = capacity`. There is no
  separate "exclusive" kind.

**Again.** `step` returns `again = true` when more work is ready right now. The
task becomes `pending`: it ignores `due` until a step returns without `again`,
and it may run again in this callback (below) or first thing in the next. This
replaces `refreshOwner`'s cross-callback continuation.

**Gating.** Hosts express "only while the dashboard is live", "not while a modal
is open" and "only when hidden" in `ready` and `ctx`. Panels that must not
overlap (the chart's same-type rule) do it in their `ready` closure.

## Running a callback

`scheduler.run(now, slots, ctx)` returns `used, requested, denied`. `now` is
read once per callback.

```text
callback += 1
repeat
  progressed = false
  for each task in ring order, starting at the cursor:
    eligible = not failed
               and (pending or (now >= due and task not stepped this callback))
               and (ready == nil or ready(task, now, ctx))
    if eligible:
      granted = deferred and 0 or fit(cost, remaining)
      if granted == 0 and cost ~= 0:
        deferred = deferred or task            -- keeps the next first turn
      else
        used, again = pcall(step)              -- validate, charge, record
        remaining -= used
        pending = again
        progressed = progressed or again
until not progressed
cursor = deferred or cursor
```

- **Fairness.** A task runs at most once per pass, and a task that asks for
  more goes to the back: every other eligible task gets a turn before it runs
  again. With A (again), B and C due, the order is A, B, C, A.
  A task that is only due again, such as an every-frame panel, does not run
  twice; only a task that returned `again` does.
- **No special loop guard.** The callback ends when a pass produces no
  `again`, so a free task that keeps asking runs again. A task that never stops
  asking runs until EdgeTX aborts the callback; tasks are trusted not to.
- **Deferral.** The first task that does not fit becomes the cursor, so it goes
  first next callback. Nothing charged runs after it in the same callback,
  including later passes; free tasks still do. This is the existing
  head-of-line rule, and it is what lets a `cost = capacity` task eventually
  run.
- **Order is stable.** Without a deferral the cursor does not move; deferral is
  the only thing that rotates it.
- **Changing the set.** Membership changes between callbacks, when the host
  next enrols its work, so a step can retire its own panel safely. A task that
  returned `again` and then disappears simply stops.
- **Cursor.** The cursor is a ring index, not a task reference, so tests and
  diagnostics can read and set it.

## Errors and stats

- `step` runs under `pcall`. An error, or `used` outside `0..granted` for a
  variable task, marks the task failed, charges the whole grant, and calls the
  scheduler's `fail(task, message)` once so the host can report it. A fixed
  task is charged its cost whatever `step` returns. Failure is the owner's
  state: the host copies `failed` onto the task before each run.
- The scheduler reports `used, requested` (eligible tasks with non-zero cost)
  and `denied` (refused for lack of slots, once per task per callback) from
  each run, and calls `charge(task, spent)` for every non-zero charge. Per-task
  totals are `task.spent`.

## Input

Native callbacks do no real work. `event` (and the `widgetEvent` passed to
`refresh`) only records the event and returns. An `input` task handles it. The
route events actually take under LVGL, and whether the exported `event` is
called at all, must be checked against the firmware before the input
conversion; the design needs only that recording is O(1) and unbudgeted.

## How today's work maps on

| Today | Task |
| --- | --- |
| Service update | One per service. `cost` = `updateCost`, `ready` = has subscribers and not failed. |
| Panel `refresh` | One per panel. `cost` = instance or module `refreshCost`; `ready` = dashboard live and the same-type rule; interval is the panel's `due`. |
| Panel `background` | A second per-panel task for hidden callbacks, cost 1, always due. |
| Flight pump, reset, loader, reflow, rebuild, menu, settings, log viewer, editor, input | Host tasks, `cost = capacity` at first, lowered once measured. |

Existing panels and services move first with no behavior change: adapters map
`unfinished` to the existing `refreshOwner` behavior and return `again = false`.
Multi-step is then adopted per task, starting with the loader.

## Risks

- **Capacity seen by large tasks.** While the flight pump is still outside the
  queue and deducts a slot first, a `cost = capacity` task never fits. Either
  the pump converts first, or the host passes the full capacity and the
  outside charge separately.
- **Runaway tasks.** See "No special loop guard".
- **Memory.** One more module and one task table per panel, service and host
  task; check Lua memory on a radio.
- **Lua width.** `scheduler.lua` and its tests must work on int32 Lua and be
  ASCII only.
