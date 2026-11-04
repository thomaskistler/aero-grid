# Blind Budgeted Callback Scheduler: Design

| | |
|---|---|
| **Status** | Proposed; validated in simulation |
| **Date** | 2026-11-03 |
| **Companion files** | `blind_scheduler_sim.py` (core scheduler) and `priority_scheduler_sim.py` (priorities and self-declared releases), in the same folder as this document |

## Summary

An embedded system runs scheduled tasks inside periodic callbacks. Each callback may execute at most **T** instructions; exceeding T crashes the system. Nothing can be measured while a callback runs: the only feedback is each callback's total, after it finishes.

The scheduler plans every callback up front using per-task cost **upper bounds**, learns those bounds from the callback totals, and treats a **near-miss** (a total above the plan's own predicted upper bound) as its failure signal. It approaches T from below instead of discovering the limit by crashing. Priority classes decide **who** gets the budget, never **how much risk** is taken. Tasks declare when they next need to run, and a **guarded due-first** order keeps urgent work on time while letting lower-priority work use the slack.

In simulation (§12):

- The recommended configurations had **zero overruns** across 2.5 million simulated callbacks, including a sudden +40% cost step and overload bursts at up to 2.4× capacity.
- They used **74.6%** of T in strict mode and **81.8%** in adaptive mode, against 91.5% for an ideal planner that knows every task's true worst case.
- **Critical tasks were never late** in about 1.06 million runs, including during overload.

## 1. Problem

- **Callbacks** arrive at a steady frequency. Each one should run as many scheduled tasks as possible.
- **Hard budget.** A callback may execute at most T instructions. Exceeding T crashes the system.
- **Blind execution.** No instruction counter is available while a callback runs. The only feedback is the total executed by each completed callback, `Y_k`.
- **Goal.** Maximize the instructions executed per callback without ever exceeding T.
- **Priorities.** Some tasks are more urgent than others.
- **Self-scheduling.** Tasks run at different frequencies. After each run, a task declares when it needs to run next.

## 2. Assumptions

| # | Assumption | Why it matters |
|---|---|---|
| A1 | Tasks run to completion inside one callback, without preemption. Long work is split into resumable chunks, each well below T. | Small chunks pack tightly and keep any single estimation error small. |
| A2 | `Y_k` is known before callback k+1 is planned. A one-callback lag also works (§13). | Learning and the safety loop run only on `Y_k`. |
| A3 | Each task declares a conservative upper bound `B` on one run's cost, from static analysis or offline profiling. Mandatory for critical and high-priority tasks, strongly recommended for all (§6.1). | Tasks are planned at `B` until their cost has been learned. |
| A4 | Each callback has a roughly fixed overhead `c0` (callback entry and exit, the scheduler itself, interrupts) that can be calibrated while no tasks run. | The overhead is present in every callback, so it can't be learned online (§10). |
| A5 | Optionally, an elastic **filler** exists: background work divisible into small units of nearly constant cost. | It absorbs leftover budget and is what brings usage close to T. |
| A6 | Task costs are stationary or drift slowly; sudden changes are rare. | Learned bounds are statistical (§11). |

Non-goals: provable worst-case guarantees for learned bounds, preemption within a callback, and per-task instruction measurement.

## 3. Design principles

1. **Decide everything up front.** At the start of a callback, choose every task to run using upper-bound cost estimates. Nothing depends on measurement during the callback.
2. **Learn only from totals.** Use `Y_k` afterwards to tighten estimates, track drift, and size the safety margin.
3. **Approach T from below.** A near-miss, not a crash, is the failure signal.
4. **Priority decides who gets the budget, never how much risk is taken.** An overrun crashes everything regardless of which task caused it, so every task is planned under the same safety rules.
5. **Overload degrades rates, not safety.** When work exceeds capacity, lower-priority tasks run later or less often; the plan never exceeds the safe budget.

## 4. Architecture

```
           ┌─────────────────────────── callback k ───────────────────────────┐
calendar ──┼─► PLAN ───────────────────► EXECUTE (blind) ──────────────────────┼──► total Y_k
   ▲       │   order, bounds, budget     admitted tasks, then filler           │       │
   │       └───────────────────────────────────────────────────────────────────┘       ▼
   └───── tasks declare their next release                     LEARN: attribute the residual,
                                                                update means, track drift
                                                                          │
                                                                SAFETY LOOP: near-miss →
                                                                margin M, allowance scale λ
```

| Component | Responsibility |
|---|---|
| Task table | Static data per task: priority class, tolerance, declared bound `B`, and whether it must always be planned at `B`. |
| Calendar | Exactly one pending release per task: `(release, deadline)`. |
| Estimator | Per task: probe statistics, learned mean `μ` and allowance `d`, and trust state. The same for the filler's per-unit cost. |
| Planner | Orders the ready tasks, admits them against the budget, sizes the filler, and records the plan's upper bound `U_k`. |
| Learner | Attributes `Y_k` to tasks and updates estimates. |
| Safety loop | Maintains the margin `M` and, optionally, the allowance scale `λ`. |

## 5. Notation

| Symbol | Meaning |
|---|---|
| `T` | Hard instruction budget per callback |
| `k` | Callback index |
| `Y_k` | Total instructions observed for callback k |
| `ĉ0`, `e0` | Calibrated overhead and its allowance |
| `B_i` | Declared upper bound of task i |
| `μ_i`, `d_i` | Learned mean cost and allowance of task i |
| `b_i` | Bound used when planning task i |
| `λ` | Allowance scale, 0.1 to 1 (always 1 in strict mode) |
| `M`, `M_min` | Safety margin and its floor |
| `C_k` | Capacity: the budget available to tasks and filler in callback k |
| `U_k` | The plan's predicted upper bound for `Y_k` |
| `n_k` | Filler units planned for callback k |

## 6. Core scheduler

### 6.1 Cost bounds

A task is **untrusted** until it has `N_PROBE` = 20 attributed cost samples (§6.4), and **trusted** after that:

```
b_i = B_i                          untrusted, or flagged "always plan at B" (§7.4)
b_i = min(B_i, μ_i + λ·d_i)        trusted
d_i = 1.5·(max_i − mean_i) + 0.03·mean_i      fixed when the task becomes trusted
```

The allowance covers 1.5× the spread observed while probing, plus a 3% floor so that tasks which never varied still keep some headroom.

- **Provisional bound (optional, non-critical tasks only).** After its first sample, an untrusted task may be planned at `min(B, max·(1 + 1/√n))`, which shrinks as samples accumulate. Simulation 1 used this rule; Simulation 2 planned untrusted tasks at `B`.
- **Tasks without a declared bound.** Simulation 1 included two such tasks. Each was planned at the entire capacity, so it ran alone, then switched to the provisional bound after its first sample. When critical tasks run every callback, no task can ever run alone, so in the full design every task should declare a bound. At minimum, restrict bound-less tasks to best-effort classes and give their first run all the budget left after critical work. Either way the first run is a genuine risk: if its true cost exceeds the budget it was given, the callback overruns.

### 6.2 Overhead calibration

At startup, run `BOOT` = 50 callbacks with no tasks:

```
ĉ0 = mean(Y)        e0 = 1.5·(max(Y) − ĉ0) + 0.03·ĉ0
```

Don't adapt `ĉ0` afterwards. It's present in every callback, so it can't be separated from tasks that also run every callback (§10).

### 6.3 Filler

The filler is planned last, in whatever budget remains:

```
n = min(N_MAX, ⌊remaining budget / b_unit⌋)
```

Its per-unit cost is learned like a task's, with two differences: a probe needs at least 100 units, because smaller samples are dominated by noise from the other tasks; and no untrusted task may run in the same callback. Until it's trusted, the filler runs only in its own probe callbacks.

### 6.4 Learner

After callback k, compute the residual against what the trusted estimates predict:

```
pred = ĉ0 + Σ μ_i over trusted tasks that ran + n·μ_unit (if the filler is trusted)
r    = Y_k − pred
```

| What ran in the callback | Update |
|---|---|
| Exactly one untrusted task (filler trusted or absent) | `r` is one cost sample for that task. |
| A filler probe (no untrusted tasks, n ≥ 100) | `r / n` is one per-unit sample. |
| Two or more untrusted tasks | None: the costs can't be attributed. The near-miss check still applies. |
| Only trusted tasks | Drift tracking, below. |

Drift tracking is a normalized least-mean-squares (NLMS) step over the regressor φ = (1 for each task that ran, `n/N_MAX` for the filler):

```
step    = η·r / (#tasks + (n/N_MAX)²)          η = 0.02
μ_i    += step   (floored at 0), for each task that ran
μ_unit += step·(n/N_MAX) / N_MAX
```

Allowances stay fixed. Drift moves the means, and the safety loop catches anything faster.

### 6.5 Safety loop

The plan's own upper bound for callback k is

```
U_k = ĉ0 + λ·e0 + Σ b_i (admitted tasks) + n·b_unit
```

- **Near-miss** (`Y_k > U_k`): at least one bound was wrong. Raise the margin to `M = max(M, M_min + 2·(Y_k − U_k))`. In adaptive mode, also reset `λ = 1` and hold it for one window (§6.6).
- **Otherwise**, decay the margin: `M = max(M_min, M·0.5^(1/5000))`, a half-life of 5,000 callbacks.

`M_min` is 1% of T.

### 6.6 Adaptive allowance scaling (optional)

Allowances rarely all peak in the same callback, so summing them is pessimistic. Adaptive mode scales them by `λ`:

1. In every callback where only trusted tasks ran, record `z = r / (e0 + Σ d_i + n·d_unit)`: the fraction of the unscaled allowances actually used.
2. Keep the maximum `z` per block of 128 callbacks, over a window of 16 blocks (2,048 callbacks).
3. When the window is full and no hold is active, set `λ = min(1, max(0.1, 1.5·max z + 0.1))`.
4. On any near-miss, set `λ = 1` and hold it for 2,048 callbacks.

In Simulation 1 this raised usage from 74.6% to 81.8% of T, still with zero overruns. It hasn't been simulated together with priorities (§14).

## 7. Priorities and self-declared releases

### 7.1 Task contract

| Field | Meaning |
|---|---|
| Class | `CRITICAL`, `HIGH`, `NORMAL` or `BACKGROUND`. This is importance: who gets cut first under overload. Critical and high are the *guaranteed* classes; normal and background are *best-effort*. |
| Tolerance | Urgency: how many callbacks a release may wait before it's late. Simulated defaults: 0, 1, 4 and 20 for the four classes. A task may also choose it per release. |
| Next release | Returned by the task after each run, as a delay counted from the callback in which the task **actually** ran. |

- **Deadline** = release + tolerance. A run after its deadline is late.
- **One pending release per task.** Waiting never stacks up extra releases.
- **No catch-up bursts.** Because the next release counts from the actual run, a delayed task simply runs less often for a while. In Simulation 2, ready work averaged 1.8× capacity during mild bursts, yet no critical, high or normal run was late: the overload showed up as tasks running less often within their tolerance.
- **Backlog draining.** A task with leftover work requests a delay of 1: "run me again next callback".

### 7.2 Admission order: guarded due-first

```
urgent = Σ b_i over ready CRITICAL and HIGH tasks
if urgent ≤ C_k:     # room to spare: guaranteed tasks may wait until their deadline
    order = due or late tasks, by (class, deadline)
            then not-yet-due tasks, by (class, deadline)
else:                # overloaded: protect guaranteed work first
    order = CRITICAL by deadline, then HIGH by deadline,
            then due or late NORMAL/BACKGROUND tasks, by (class, deadline),
            then not-yet-due NORMAL/BACKGROUND tasks, by (class, deadline)
```

Admit tasks in that order. A task whose bound fits the remaining budget is admitted; one that doesn't fit is skipped, and scanning continues. Budget doesn't carry over between callbacks, so skipping a large task never delays it; it only lets smaller tasks use the leftover. The filler goes last.

Each simpler order failed in simulation (§12.2):

| Order | Failure |
|---|---|
| Earliest deadline first (EDF) | Under overload, late low-priority tasks have the earliest deadlines and push out critical work: 455 critical runs were late. |
| Strict priority | High-priority tasks run as soon as released even when they could wait, so background work starved for entire bursts (up to 1,501 callbacks), even mild ones. |
| Due-first without the guard | When guaranteed work saturates capacity, deferring high-priority tasks piles them up past their deadlines: 1,121 high-priority runs were late. |
| Strict for guaranteed classes, due-first for the rest | Background work still starved during mild bursts (up to 1,496 callbacks), as with strict priority. |

The guard lets guaranteed tasks lend their slack only when all of their ready work would fit in one callback anyway.

### 7.3 Safety-loop changes

- **Cap the margin.** The margin may shed everything except critical work that is due:
  ```
  room = T − ĉ0 − λ·e0
  C_k  = room − min(M, max(M_min, room − Σ b_i over due CRITICAL tasks))
  ```
  Without this cap, one large near-miss in an early version pushed `M` above capacity, which locked out critical tasks too: usage fell to 4% of T and 17% of critical runs were late.
- **Verified bounds for critical tasks.** Critical tasks run from the first callback and must keep running after a near-miss, so their declared bounds must be trustworthy, not merely learned.
- **Design-time admission test.** Require `ĉ0 + e0 + M_min + Σ B_i ≤ T`, summed over the critical tasks that can be due in the same callback. With self-declared releases, assume they can all coincide unless that's provably impossible. Add high-priority tasks to the sum if they must be guaranteed too. When the margin has shed everything else, the remaining plan is then safe by construction, provided the overhead and critical bounds are true bounds.
- **Probes never displace critical work.** Untrusted tasks are ordered by class like any other task and are admitted only at their declared bound.
- **Compare with a small tolerance** (`b_i ≤ budget + ε`). At the margin cap, the critical bounds fill the capacity exactly, and floating-point rounding can otherwise drop the last critical task.

### 7.4 Hazard: cost that grows with waiting

Self-declared frequencies and overload deferral introduce a new failure mode. A task that processes accumulated work (queues, logs, buffers) costs more the longer it waited. Its learned bound reflects typical waits, so after a long deferral its cost is far above the bound, and the whole bill lands in a single callback right **after** the overload, when the task finally runs. The near-miss loop can't help: the first oversized run is itself the overrun.

In Simulation 2, an uncapped background log uploader crashed the system 1 to 3 callbacks after the first burst ended, in all 5 seeds, with no near-miss beforehand. In an earlier version, the same effect crashed the system on the task's very first run, right after boot calibration, because records had piled up while no tasks ran.

Rules for any task whose cost depends on accumulated work:

1. **Cap the work per run** (the simulation used 120 records) and declare `B` as the cost at the cap.
2. **Plan it at `B`, never at a learned bound**, or have it report its pending work so the bound can be computed per run (§14).
3. **Drain with a delay of 1.** While backlog remains, request the next callback.
4. **Apply the cap from the first run.** Backlog builds up whenever the task doesn't run, including during boot.

With these rules, the same workload had zero overruns and zero near-misses.

### 7.5 Overload policy

- Overload shows up as lateness and reduced rates, shed from the bottom: background first, then normal.
- During severe bursts in Simulation 2, background work waited up to 374 callbacks. If that's unacceptable, add a minimum budget share or aging for the best-effort classes (not simulated).

## 8. Reference algorithm

### 8.1 State

```c
typedef enum { CRITICAL, HIGH, NORMAL, BACKGROUND } task_class_t;

/* Runs one bounded chunk of work; returns the delay until the next release (>= 1). */
typedef uint32_t (*task_fn)(void *ctx);

typedef struct {
    /* static */
    task_fn      run;
    void        *ctx;
    task_class_t cls;
    uint32_t     tolerance;        /* callbacks a release may wait before it is late */
    uint32_t     declared_bound;   /* B, required */
    bool         always_declared;  /* accumulating tasks: always plan at B (§7.4) */
    /* calendar */
    uint32_t     release, deadline;
    /* estimator */
    uint16_t     samples;          /* attributed probe samples */
    float        mean, max;        /* probe statistics */
    float        mu, allowance;    /* μ and d, once trusted */
    bool         trusted;
} task_t;
```

Global state: `ĉ0`, `e0`, `M`, `λ`, the filler's estimator, the λ window (16 block maxima and a hold counter), and one plan record per callback still awaiting its total: the admitted tasks, `n`, the probe, whether several untrusted tasks ran, and `U_k`.

### 8.2 Plan (start of callback k)

```
plan(k):
    if k < BOOT: return nothing                          # overhead calibration (§6.2)
    ready  = tasks with release ≤ k
    room   = T − ĉ0 − λ·e0
    crit   = Σ bound(t) for t in ready with class CRITICAL
    C      = room − min(M, max(M_min, room − crit))       # margin cap (§7.3)
    urgent = Σ bound(t) for t in ready with class ≤ HIGH
    sort ready by key(t, k, lend = (urgent ≤ C))          # §7.2
    budget = C;  admitted = [];  untrusted = []
    for t in ready:
        if bound(t) ≤ budget + ε:
            admitted += t;  budget −= bound(t)
            if not t.trusted: untrusted += t
    n = min(N_MAX, ⌊budget / bound(filler)⌋)
    if not filler.trusted and (untrusted is not empty or n < 100): n = 0
    probe = the untrusted task   if exactly one
            FILLER               if there are none, n > 0 and the filler is untrusted
            none                 otherwise
    U = ĉ0 + λ·e0 + (C − budget) + n·bound(filler)
    record[k] = (admitted, n, probe, |untrusted| > 1, U)
    return admitted, n

bound(t):
    if t.always_declared or not t.trusted: return t.declared_bound
    return min(t.declared_bound, t.mu + λ·t.allowance)

key(t, k, lend):                                         # smaller sorts first
    due = (t.deadline ≤ k)
    if lend:            return (0 if due else 1, t.class, t.deadline)
    if t.class ≤ HIGH:  return (t.class, 0, t.deadline)
    return (2 if due else 3, t.class, t.deadline)
```

Run the admitted tasks, then `n` filler units. When task t returns `delay` in callback k:

```
t.release  = k + delay
t.deadline = t.release + t.tolerance
```

### 8.3 Observe (after callback k, with total Y)

```
observe(k, Y):
    if k < BOOT:
        collect Y; after the last boot callback, set ĉ0 and e0 (§6.2); return
    (admitted, n, probe, multi, U) = record.pop(k)
    r = Y − (ĉ0 + Σ t.mu for trusted t in admitted
               + (n·filler.mu if filler.trusted else 0))
    if probe is FILLER:     add_sample(filler, r / n)
    elif probe is a task:   add_sample(probe, r)
    elif not multi:
        nlms_update(admitted, n, r)                       # §6.4
        if adaptive: track_lambda(admitted, n, r)          # §6.6
    if Y > U:                                              # near-miss
        M = max(M, M_min + γ·(Y − U))
        if adaptive: λ = 1, and hold it for one window
    else:
        M = max(M_min, M·decay)

add_sample(t, x):
    t.samples += 1
    t.mean    += (x − t.mean) / t.samples
    t.max      = max(t.max, x)
    if t.samples ≥ N_PROBE:
        t.trusted   = true
        t.mu        = t.mean
        t.allowance = (1 + α)·(t.max − t.mean) + floor·t.mean
```

## 9. Parameters

| Parameter | Simulated value | Effect |
|---|---|---|
| `BOOT` | 50 callbacks | Empty callbacks used to calibrate the overhead. |
| `N_PROBE` | 20 samples | More samples give more reliable allowances but slower learning. |
| `α` (allowance gain) | 0.5, i.e. 1.5× the observed spread | Larger is safer and uses less of T. |
| Allowance floor | 3% of the mean | Headroom for tasks that didn't vary while probed. |
| `M_min` | 1% of T | Absorbs small unexplained noise. |
| `γ` (margin jump) | 2× the excess | How hard a near-miss pushes the margin up. |
| Margin half-life | 5,000 callbacks | How long the system stays cautious after a near-miss. |
| `η` (drift step) | 0.02 | Higher tracks drift faster but is noisier. |
| Filler probe minimum | 100 units | Below this, per-unit samples are mostly noise. |
| λ window | 16 blocks of 128 callbacks | Longer is more conservative. |
| λ gain and floor | 1.5 and 0.1 | `λ = min(1, max(0.1, 1.5·max z + 0.1))`. |
| Tolerances | 0 / 1 / 4 / 20 callbacks | Critical / high / normal / background. |
| Accumulating-task cap | 120 records per run | Choose it so the capped cost fits comfortably in the typical leftover budget. |

## 10. Lessons from the simulations

Each of these was a problem found in an earlier iteration of the design:

1. **Don't adapt the overhead online.** An early learner adjusted `ĉ0` together with the task means. Because the overhead and the every-callback tasks always appear together, the split between them wandered: one every-callback task was learned at 288 instructions against a true 900. Calibrating `ĉ0` at boot and then freezing it fixed this.
2. **Filler probes need enough units.** With small samples, the filler's learned allowance was so wide that it stayed at its declared per-unit bound of 25 (true cost 12), wasting 16% of T. Requiring at least 100 units per probe cut the waste to 5.5%.
3. **The margin must never lock out critical work** (§7.3).
4. **Floating-point ties at the capacity edge** can drop the last critical task (§7.3).
5. **Backlog builds up whenever a task doesn't run**, including during boot (§7.4).
6. **Tasks that always run together can't be told apart** from totals, and tasks that run every callback can't be told apart from the overhead. Learn them as one block, or rely on their declared bounds.
7. **Large urgent tasks need tight declared bounds.** An untrusted task is planned at `B`. If `B` doesn't fit beside the critical load, the task never runs, so it never gets learned.

## 11. Limits and risks

- **Learned bounds are statistical.** Only true worst-case bounds guarantee safety, and a rare spike may never occur during the 20 probe samples. Plan tasks with known rare spikes at their declared bound.
- **Sudden cost increases.** A jump larger than the remaining allowance plus the margin causes one overrun before feedback can react. A sudden +40% step on one task was absorbed in simulation; larger or simultaneous jumps may not be.
- **Accumulating work** must be capped (§7.4).
- **High-priority guarantees** hold only while critical plus high work fits. Under severe overload, 4 of 342,473 high-priority runs were late.
- **The simulations are synthetic.** Validate with recorded cost traces from the real system (§13).
- **Remaining gap.** Strict mode uses 74.6% of T and adaptive mode 81.8%, against 91.5% for a planner that knows every true worst case. The difference is the cost of learning: allowances, margin, and filler uncertainty.

## 12. Evaluation

Both simulators use a hard budget of T = 10,000 instructions and give the scheduler only each callback's total. Every overrun is counted as a crash; the simulation then keeps running, so that all variants cover the same callbacks. All schedulers in a run see identical workloads.

### 12.1 Simulation 1: core scheduler

`blind_scheduler_sim.py`. The workload:

- 18 tasks with periods of 1 to 20 callbacks. Costs are fixed, vary uniformly (by up to +60%), or spike (a 2–3% chance per run of a 1.8–2× spike).
- Declared bounds are 1.5–2.5× each task's true maximum; 2 tasks have no declared bound.
- An overhead of 300–360 instructions, which steps up by 80 at callback 70,000 (for example, a new interrupt).
- One task's cost drifts +40% between callbacks 40,000 and 60,000.
- A filler of up to 1,000 units of about 12 instructions (±3%), declared at 25.

This simulation predates priorities: tasks are ordered by deadline, untrusted tasks are admitted first, at most one untrusted task runs per callback, and untrusted bounds use the provisional rule (§6.1).

| Scheduler | Knowledge |
|---|---|
| Oracle | The exact cost of every task in every callback: an upper limit. |
| Ideal worst-case | Each task's true worst case: the best any provably safe planner could do. |
| Static | Declared bounds only; never learns. |
| Naive | Learns mean costs from totals and fills right up to T. |
| Strict | This design with λ = 1. |
| Adaptive | This design with adaptive λ. |

Results over 10 seeds × 100,000 callbacks:

| Scheduler | Overruns | Mean use of T | 1st-percentile use | Tasks per callback | Deadline misses |
|---|---|---|---|---|---|
| Oracle | 0 | 99.9% | 99.9% | 6.76 | 0 |
| Ideal worst-case | 0 | 91.5% | 79.9% | 6.76 | 0 |
| Static | 0 | 46.0% | 37.6% | 5.86 | 880,721 |
| Naive | 463,121 (46% of callbacks) | 99.9% | 94.2% | 6.76 | 0 |
| **Strict** | **0** | **74.6%** | **64.9%** | **6.76** | **0** |
| **Adaptive** | **0** | **81.8%** | **72.0%** | **6.76** | **0** |

A deadline miss here means a task was released again before its previous release had run. The 1st-percentile use is the usage that 99% of callbacks exceed.

**Stress test** (`STEP_DRIFT=1`: the +40% drift happens instantly): strict had 0 overruns at 74.6% usage, adaptive 0 overruns at 81.6%, and naive 463,035 overruns. Neither strict nor adaptive had a single near-miss in either run; the margin stayed at its floor.

**Where strict mode leaves budget unused** (seed 1, first 30,000 callbacks): task allowances about 19.7% of T, the gap between the filler's bound and its actual cost 5.5%, the margin 1.0%, and the overhead allowance 0.5%. Adaptive λ recovers part of the task allowances.

### 12.2 Simulation 2: priorities and self-declared releases

`priority_scheduler_sim.py`. 14 tasks with declared bounds 1.2–1.6× each true maximum, an overhead of 300–360 instructions, and the same filler:

| Class (tolerance) | Tasks and release patterns |
|---|---|
| Critical (0) | Control loop (every callback); radio (every callback while active, otherwise every 4th; always active during bursts); safety monitor (every 2nd); fault isolation (every callback, severe bursts only) |
| High (1) | Sensor fusion (every 2–3); actuator planning (every 3–5); burst handler (every callback during bursts) |
| Normal (4) | Telemetry (every 5th; every callback during bursts); log flush (every 3–6; every 2nd during bursts); routing (every 3rd) |
| Background (20) | Diagnostics (every 20–40); garbage collection (every 7th, with rare 1.8× spikes); CRC scan (every 10th); log uploader (accumulating: 150 + 25 per record, about 8 new records per callback, every 10th; the capped version handles at most 120 records per run) |

- **Overload bursts** of 1,500 callbacks every 20,000, alternating mild and severe. Ready work relative to capacity averaged 47% when calm (2% of callbacks over capacity), 176% in mild bursts, and 235% in severe bursts (every burst callback over capacity).
- The first 3,000 callbacks, including one learning burst, are excluded from the lateness statistics.
- Untrusted tasks are planned at their declared bound. Several may run in one callback; costs are attributed only when exactly one did.
- All variants use the strict safety layer (λ = 1) with the margin cap.

Results over 5 seeds × 100,000 callbacks. Late-run columns are counts out of about 1.06 million critical, 343,000 high, 378,000 normal and 175,000 background runs per variant:

| Order | Overruns | Use of T | Critical late | High late | Normal late | Background late | Background max wait: calm / mild / severe |
|---|---|---|---|---|---|---|---|
| EDF | 0 | 85.4% | 455 | 1,692 | 1,132 | 878 | 2 / 21 / 22 |
| Strict priority | 0 | 84.7% | 0 | 1 | 1,717 | 309 | 2 / 1,501 / 1,500 |
| Due-first, no guard | 0 | 84.7% | 0 | 1,121 | 1,294 | 1,027 | 20 / 21 / 1,431 |
| Strict for guaranteed, due-first for the rest | 0 | 84.8% | 0 | 9 | 2,094 | 1,466 | 2 / 1,496 / 1,499 |
| **Guarded due-first (§7.2)** | **0** | **84.8%** | **0** | **4** | **1,841** | **894** | **3 / 21 / 374** |
| Guarded, uncapped log uploader | 15 | | | | | | Crashed 1–3 callbacks after the first burst, in all seeds |

"Late" means run after its deadline; "wait" is the number of callbacks from release to run. Late counts understate starvation: a starved task has only one pending release, so even a 1,500-callback wait counts as a single late run. The max-wait column shows it. The uncapped row's other statistics aren't meaningful after its first crash, so they're omitted.

Guarded due-first, late runs by load level:

| Load | Critical | High | Normal | Background |
|---|---|---|---|---|
| Calm | 0 of 948,832 | 0 of 290,747 | 0 of 337,895 | 0 of 168,645 |
| Mild bursts | 0 of 56,244 | 0 of 35,891 | 0 of 29,686 | 12 of 4,632 |
| Severe bursts | 0 of 52,489 | 4 of 15,835 | 1,841 of 10,054 | 882 of 2,124 |

### 12.3 Reproducing

```bash
python3 blind_scheduler_sim.py 1 2 3 4 5 6 7 8 9 10                 # §12.1, about 90 s
STEP_DRIFT=1 python3 blind_scheduler_sim.py 1 2 3 4 5 6 7 8 9 10    # stress test
python3 priority_scheduler_sim.py 1 2 3 4 5                          # §12.2, about 50 s
CALLBACKS=20000 python3 priority_scheduler_sim.py 1                  # quick check
```

Both scripts need only the Python 3 standard library. The arguments are random seeds.

## 13. Implementation notes for the embedded target

- **The scheduler's own cost counts against T.** Calibrate `ĉ0` with the scheduler running, and keep its work per callback bounded: planning is O(N log N) for N tasks (or O(N) with per-class buckets), and learning is O(N).
- **No dynamic allocation.** Use a fixed task table and a small ring buffer of plan records indexed by `k mod depth`.
- **Feedback lag.** If `Y_k` arrives only after callback k+1 has been planned, look up the plan record by k when the total arrives. The safety loop then reacts one callback later, so consider a larger `M_min`.
- **Counter wraparound.** Compare release and deadline values with wrap-safe arithmetic, such as `(int32_t)(a − b) ≤ 0`, or use 64-bit counters.
- **Arithmetic.** Instruction counts are integers. `μ`, `d`, `λ` and `M` fit in fixed point, such as Q16.16. Precompute the decay factor `0.5^(1/5000) ≈ 0.999861`.
- **Telemetry.** Log `Y_k`, `U_k`, `M`, `λ`, near-misses, per-class lateness, the number of untrusted tasks, and the filler's `n`. A near-miss in the field is the earliest warning that a bound is wrong.
- **Testing.** Replay recorded per-task cost traces through the simulators before changing parameters. Inject faults (cost steps, spikes, overload bursts) and require zero overruns.

## 14. Future work

1. **Work-count reporting (the biggest lever).** Tasks report their pending or processed items, so that cost ≈ fixed + per-item × items can be learned. That gives exact per-run bounds, including for accumulating tasks (instead of always planning at the cap), and would let the scheduler top up a callback when tasks report doing less work than planned.
2. **Adaptive λ together with priorities.** Each has been validated separately; the combination hasn't been simulated.
3. **Starvation control** for the best-effort classes: a minimum budget share, or aging.
4. **Load leveling.** Place releases that have wide tolerances into the least-loaded upcoming callbacks.
5. **Better learning for tasks that rarely run alone**, for example regression over which tasks ran (recursive least squares) instead of single-untrusted probes, and explicit grouping of tasks that always run together.
