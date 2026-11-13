# Scheduler task abstraction

Goal: every piece of widget work runs through one scheduler that grants it
nominal slots (2,000 instructions each) and shares them fairly, so the
per-callback budget can be raised in one place.

The production budget is set by `SLOTS` and `INSTRUCTIONS_PER_SLOT` in
`lib/scheduler.lua` (eight slots of 2,000 instructions by default). The host
passes this budget to service and panel validation, chart work and diagnostics.
The chart retains a 20% per-slot safety margin and its callback reserve.
Changing slot capacity does not change EdgeTX's hard instruction limit, and
outside-queue work must still be migrated before higher limits are safe.

At the start of this effort only panel refreshes and service updates were slotted, in `dispatchDue`
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

## Bypass inventory after the abstraction migration

This inventory records the baseline before flight/callback migration.
Only `dispatchDue` enrolled work then. Its service updates, panel refreshes and
hidden panel backgrounds are queued; the paths below are not. "Exclusive"
means the host returns without calling `dispatchDue`, not that the path
currently reserves slots. Conditions and order are taken from `main.lua`'s
`refresh`, `background`, `event`, `create` and `update`.

| Work outside the queue | When it runs | What follows today | Direct service update |
| --- | --- | --- | --- |
| Flight identity/reset and model document/store loading (`pumpFlight`) | First in foreground/hidden callbacks when a broker exists; document loading when not loaded. Also called from `configureFlight`. | Document/store load attempts return exclusively. Identity errors and ordinary no-work gates fall through. | No; the broker is called directly. |
| Flight reset polling and detection tick (`pumpFlight`) | After the document is loaded; subject to dormant, construction and Smart timing/input gates. | Ordinary ticks deduct one slot afterward, then fall through. Smart ticks reserve construction/modal/reflow callbacks and return exclusively; `flightDashboardDue` yields the next turn to dashboard work. | No; `pollReset` and `tick` bypass service dispatch. |
| Arming-driven editor suspension (`suspendArmingEditor`) | `modelArmingReload` set. | An in-progress save advances exclusively. Otherwise editor close/preview restore falls through. | No. |
| Session reset (`pumpSessionReset`) | Reset pending, but not during loading/reload. | Exclusive, including the completion callback. Up to eight reset items for one service, or one panel reset turn. | Direct `resetSession` calls, not normal updates. |
| Menu preparation (`prepareAeroMenu`) | Foreground callbacks; chrome visibility checked even before dashboard readiness. | Module load or new mask construction without input is exclusive. Ensure/reposition/advance normally falls through; `menu.advance`'s busy result is ignored. | No. |
| Menu input (`aeroMenuModule.handle`) | Foreground callback before normal input, and again through `event`. | Consumed foreground input returns exclusively. State changes can be processed by a later menu advance. | No. |
| Menu actions/model settings open (`menu.advance`, `openModelSettings`) | Pending menu action during preparation. | Can read the model store, replace the broker document, suspend the editor and open a modal in the same callback; subsequent modal branch returns exclusively. | No. |
| Model settings handle/build/save/close | Modal present. | Foreground handle then advance is exclusive. If advance reports no work, one legacy service update runs. Hidden callbacks advance exclusively with no service update. | Foreground only, through `updateServices`. |
| Runtime-failure geometry/error presentation | Foreground and runtime incomplete. | Exclusive; no scheduler may exist. | No. |
| Location-details close | Foreground, overlay present and leaving fullscreen or reloading. | Falls through. | No. |
| Log-viewer close | Foreground, viewer present and leaving fullscreen, reloading or resizing. | Exclusive. | No. |
| Editor leave/resume and preview restore | Foreground fullscreen transition with editor/draft present. | Falls through unless resulting editor work takes an exclusive branch. | No. |
| Reload retirement | `reloadState == "clear"`, foreground or hidden. | Exclusive: destroys all panels and clears/hides the page or root. | No. |
| Reload reconstruction and `beginLoad` | `reloadState == "rebuild"`, foreground or hidden. | Exclusive: constructs the new page and initializes staged loading. | No. |
| Loader stage | `context.stage`, foreground or hidden. | Exclusive even when the stage finishes. Theme/layout read, validation/migration, services and panel construction are staged internally. The last stage calls `configureFlight`, which currently calls `pumpFlight` synchronously. | Service construction/registration only; flight configuration can pump directly. |
| Empty-dashboard hint | Loaded foreground callback. Also called when opening the editor. | Falls through; may create/update/hide LVGL objects. | No. |
| Long-press editor entry | Loaded foreground, fullscreen, no modal; held touch crosses the threshold. | Opening the editor returns exclusively. | No. |
| Editor build/drawer/save/exit/preview advancement | Foreground editor has pending work; hidden editor has a save running. | Exclusive. Preview work calls panel create/update/destroy directly; panel construction performs its initial refresh. Saved-layout adoption calls `configureFlight`, which can pump directly. | No normal service update. |
| Fullscreen input (`event`) | Nonzero foreground input, plus exported `event` entry point. | Directly handles modal/editor input, opens log/location overlays, or dispatches panel events. Reload/editor/log input returns exclusively; log input runs one legacy service update. Other input may fall through to queued panel/service work. | Log-viewer input only, through `updateServices`. |
| Log preparation/rendering | Foreground viewer open. | One legacy service update, then optional wrapping/preparation; exclusive. Hidden callbacks do not prepare the log and can reach `dispatchDue`. | Yes, through `updateServices`. |
| Geometry/reflow | Loaded foreground zone/fullscreen changed, or reflow pending. | Begin reflow and one batch of panel `update` calls; exclusive even on completion. Hidden callbacks with reflow pending return without advancing it. | No. |
| App-mode panel rebuild | Loaded foreground discovers a fullscreen-built panel, or rebuild pending. | One retire or build step, exclusive. Hidden callbacks do not advance it. | No. |
| Native `create` | Widget instantiation. | Loads mandatory runtime modules, registers shared flight membership, creates root/page/canvas and initializes loading before returning the context. | No. |
| Native `update` | Host options change. | May close editor/restore preview, change shared flight membership and request reload; returns directly to EdgeTX. | No. |
| Native LVGL callbacks | Firmware invokes object callbacks, independently of the host's queue. | Some callbacks only record commands; others do work immediately. For example, the log viewer's Close button directly hides/clears its overlay. These must be audited with the input conversion, not treated as already queued. | No central slot gate. |

`updateServices` is a separate bypass, not an adapter into the new scheduler:
it calls `services.update` directly using the remaining allowance. Its three
foreground call sites are idle model settings, log input (open/current/just
closed), and the normal log-viewer branch. It is never called by the hidden
callback. Removing it must preserve these modal service opportunities through
task readiness rather than suppressing them.

### Migration constraints exposed by the inventory

- Flight must move first. A full-capacity reservation cannot fit after its
  current outside-queue one-slot deduction. Both the callback pump and the
  synchronous pump in `configureFlight` (loader completion and saved-layout
  adoption) must be removed as bypasses.
- Keep the existing Smart input/timing and dashboard-turn gates when introducing
  pre-grants. Shared broker ownership across widgets is not a per-widget task
  reset.
- Loader, reload, reflow, rebuild and editor tasks initially reserve the whole
  configured capacity, not a literal eight. Flight document loading likewise
  starts with a whole-capacity reservation; ordinary flight ticks start at one
  slot. These are reservations, not measured instruction claims.
- Do not return `again` across an LVGL retirement/reconstruction barrier.
  Repeated scheduler passes occur inside the same native callback and therefore
  do not perform firmware deferred cleanup. Page and panel rebuild phases must
  retain their cross-callback separation.
- Re-enrol or gate live work using current host state after transitions. A modal,
  reload or retired panel must not accidentally allow stale dashboard tasks
  later in the same callback.
- Native callbacks should record intent; host tasks perform input/UI operations.
  Creation still needs a minimal bootstrap to instantiate the scheduler and
  return a valid context; defer substantive initialization after that bootstrap.
- Include location-details UI, empty hints, error presentation and editor
  suspension/restore in the relevant UI/lifecycle conversions. They are not
  covered merely by moving the large `advance` calls.

## Risks

- **Native entry points.** `create`, `update`, exported `event` and native LVGL
  callbacks still need intent-only conversion. Runtime-failure presentation
  must work when the scheduler itself could not be created.
- **Runaway tasks.** See "No special loop guard".
- **Memory.** One more module and one task table per panel, service and host
  task; check Lua memory on a radio.
- **Lua width.** `scheduler.lua` and its tests must work on int32 Lua and be
  ASCII only.

## Flight and callback migration

Foreground and hidden callbacks now run one ring: flight, pending host work,
then live services/panels when no host mutation is pending. The existing host
flow is a conservative full-capacity task; it does not request another pass.
This preserves reload/rebuild cleanup barriers and prevents stale owners from
running after a host transition. Individual host paths still need extraction
and smaller measured costs before multiple loader/UI steps can share a callback.

Flight identity, reset polling and ticks request one slot. Document/store
loading requests the full capacity. A model identity change discovered during
a one-slot turn requests a full-capacity continuation for document loading.
The synchronous pump in `configureFlight` is removed. Smart timing/input and
dashboard-turn gates remain inside the flight task.

Fullscreen refresh input is copied with its arrival tick and retained until
handled; deferred turns must neither drop releases nor turn scheduling delay
into a long press. Native/exported input routes remain a later conversion.

`updateServices` is removed. Idle foreground model settings and log viewers
allow normal queued service turns without panel refreshes. Their pending UI
work initially reserves the full capacity. Hidden model settings and pending
reflow retain their previous suppression of ordinary dashboard work.

Navigation previews defer their initial drawing to the next editor preview
turn so the newly charged callback routing stays within the existing ceiling.
Production navigation construction is unchanged.

Session reset now has its own full-capacity task instead of running inside
the combined host task. Each turn retains the existing slice: up to eight
items of one service, one panel reset step, or job completion. The task requests
`again` while the job remains pending; at the default capacity that next step
cannot fit until another callback. Loading/reload and arming-driven editor
suspension take precedence. Foreground and hidden turns share the same job,
and dashboard work resumes only after the completion callback.

Loading, page retirement/reconstruction, reflow and App-mode reconstruction
now have distinct full-capacity tasks. The host routes eligible work to them;
loading and reflow request `again` while their existing stages remain pending.
Foreground input and due long-press handling can preempt those tasks.
Retirement/reconstruction phases do not request same-callback continuations.
Hidden callbacks can load and reload, but do not advance reflow or App-mode
reconstruction. Other UI work still runs in the combined host task.

Model-settings input/build/save/close and log preparation now have separate
full-capacity tasks. Settings advance in foreground or hidden callbacks;
log preparation is foreground-only and yields to retained input and modal
transitions. Log preparation requests `again` while wrapping remains pending.
Settings phases keep native callback separation instead of requesting another
pass. Closed modals are released from cached tasks. Menu actions, log opening,
scrolling/closing and editor work remain in the combined host task or native
routes and still need extraction.

Editor build/drawer/save/preview advancement now has a separate full-capacity
task. Each existing stage retains its native callback boundary; it does not
request `again`, including preview retirement/reconstruction. Hidden callbacks
only advance saves already in progress. Saves required by arming-driven
suspension finish before reset or editor teardown. Editor entry, exit/restore
transitions, and exported/native input routes still need extraction.

Menu module loading, chrome visibility/geometry, popup preparation and pending
actions now run in a dedicated full-capacity task. Idle menus enroll no task;
hidden callbacks do not advance menus. Menu construction and actions retain
input until the host route receives its own grant. Input handling still records
menu commands through the host/exported event path and needs native-route
conversion.
