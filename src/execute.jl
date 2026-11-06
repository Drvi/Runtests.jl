# Running a plan: one task per slot. A slot takes its pool's head first, then walks
# its own stretch of the pool's body, takes half of the largest stretch left when
# its own is done, then the pool's tail. When its own pool has nothing left it
# rebinds, restarting its process under another pool's profile: to a pool no slot
# serves, or else to the pool whose slots have the most work left each, when that
# is more than a fresh worker costs there. `workers` caps live processes
# throughout: the run takes longer rather than start a process the caller did not
# authorize.

using Base: SIGKILL

# A slot is its own task's, on the run's thread. The fields other threads read are
# atomic: `worker`, `current` and `collecting`, which the monitor reads, and
# `dying_log`, which the worker's output relay reads. `dying_lines` is the relay's
# while `dying_log` is set, and the slot's again once it has joined the relay.
mutable struct Slot
    const id::SlotIdx
    profile::ProfileIdx      # the profile its process starts with, by its index in the plan
    @atomic worker::Union{Nothing, RuntestsWorkers.Worker}
    started_at::Float64      # when this slot's current process came up
    worker_items::Int        # items the current process has run, for its EXIT line
    @atomic current::ItemIdx      # the item this slot is running, 0 when idle
    # The attempt at `current` in flight. Whoever records that attempt's outcome
    # clears `current`: the slot, or `record_stopped_item!` when the run stops.
    @atomic attempt::Int8
    # A process killed for a timeout prints its signal and backtrace after its item
    # has stopped capturing. Those lines belong in `dying_log`, the log of the item
    # that was running (empty otherwise), and wait in `dying_lines` until the
    # process is gone.
    @atomic dying_log::String
    const dying_lines::Vector{String}
    # Set by the memory guard: replace this slot's worker before its next unit. The
    # slot owns its worker, so the guard asks rather than kills: an item is never
    # stopped for memory the machine may be short of on someone else's account.
    @atomic recycle::Bool
    # The item whose failed attempt's producers this slot's worker is running, 0 when
    # none. Apart from `current`: the attempt's verdict is recorded by then, and nothing
    # that stops the run may record another.
    @atomic collecting::ItemIdx
end

"""
    PoolStats

What the run has measured of one pool, for deciding where a slot whose own pool
has run dry does the most good: how long the pool's workers took to be ready; the
compile time of items that ran first on a fresh process, and of items that ran on
one that had run others; and how long its items took, against their recorded
durations where they had one.
"""
mutable struct PoolStats
    starts::Int
    start_s::Float64
    cold::Int                    # items that ran first on a fresh process
    cold_compile_s::Float64
    warm::Int                    # items that ran on a process that had run others
    warm_compile_s::Float64
    items::Int
    took_s::Float64
    estimated_s::Float64         # the recorded durations of the items that had one
    estimated_took_s::Float64    # and what those items took
end
PoolStats() = PoolStats(0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, 0.0, 0.0)

"""
    Queues

Every cursor a run has, behind one lock: each pool's head and tail, and each slot's
stretch of its pool's body; and what the run has measured of each pool, which the
slots write and a slot whose pool ran dry reads. A run claims a few thousand times,
so an uncontended lock costs nothing, and one lock rules out racing cursors.
"""
mutable struct Queues
    const lock::ReentrantLock
    const pools::Vector{Pool}
    const head::Vector{UnitIdx}      # per pool: its next head unit
    const tail::Vector{UnitIdx}      # per pool: its next tail unit
    const from::Vector{UnitIdx}      # per slot: the next unit of its stretch
    const to::Vector{UnitIdx}        # per slot: the last unit of its stretch
    const pool::Vector{Int32}        # per slot: the pool it serves
    const pending::Vector{Int32}     # pools no slot serves yet, in pickup order
    const claimed::BitVector         # per unit: handed out already
    const serving::Vector{Int}       # per pool: slots working for it
    const est::Vector{Float64}       # per unit: the recorded seconds of its items
    const unrecorded::Vector{Int32}  # per unit: its items without a recorded duration
    const typical::Float64           # an unrecorded item, before its pool has timed any
    const stats::Vector{PoolStats}   # per pool
    const prior::ColdCost            # what a fresh worker cost in earlier runs
    cancelled::Bool
    paused::Bool        # the memory guard is holding new work back
end

Queues(p::Plan) = Queues(
    ReentrantLock(), p.pools,
    UnitIdx[first(k.head) for k in p.pools], UnitIdx[first(k.tail) for k in p.pools],
    UnitIdx[first(r) for r in p.slot_units], UnitIdx[last(r) for r in p.slot_units],
    copy(p.slot_pool), copy(p.pending), falses(length(p.units)),
    [count(==(k), p.slot_pool) for k in eachindex(p.pools)],
    p.units.est_s, Int32[count(i -> p.items.est_s[i] == 0, span) for span in p.units.span],
    typical_estimate(p.items.est_s),
    [PoolStats() for _ in p.pools], p.cold, false, false
)

struct Claim
    kind::Symbol        # :unit, :rebind, :done
    unit::UnitIdx
    pool::Int32
end
Claim(kind::Symbol) = Claim(kind, UnitIdx(0), Int32(0))

# The unit a cursor points at, moving the cursor past it. Every unit is handed out
# exactly once; a second time is a scheduling bug, stopped here rather than run twice.
function next!(q::Queues, cursor::Vector{UnitIdx}, i::Integer)
    u = cursor[i]
    cursor[i] += UnitIdx(1)
    q.claimed[u] && error("Runtests internal error: unit $u was handed out twice")
    q.claimed[u] = true
    return Claim(:unit, u, Int32(0))
end

function claim!(q::Queues, s::Integer)
    @lock q.lock begin
        q.cancelled && return Claim(:done)
        k = q.pool[s]
        q.head[k] <= last(q.pools[k].head) && return next!(q, q.head, k)
        q.from[s] <= q.to[s] && return next!(q, q.from, s)
        # Its own stretch is done: take the second half of the largest stretch left
        # in the pool, so both slots go on walking neighbouring units. A stretch of
        # one gives it up too, so a slow slot's last unit does not wait behind the
        # one it is running. Never across pools: a unit run under another profile's
        # flags is not the test that was declared.
        victim, most = 0, 0
        for v in eachindex(q.pool)
            q.pool[v] == k || continue
            r = q.to[v] - q.from[v] + 1
            r > most && ((victim, most) = (v, r))
        end
        if victim != 0
            q.from[s] = q.from[victim] + UnitIdx(most ÷ 2)
            q.to[s] = q.to[victim]
            q.to[victim] = q.from[s] - UnitIdx(1)
            return next!(q, q.from, s)
        end
        q.tail[k] <= last(q.pools[k].tail) && return next!(q, q.tail, k)
        # Its own pool has nothing left: the slot moves to another, whose profile
        # its next process is started with.
        if !isempty(q.pending)
            j = popfirst!(q.pending)
            q.from[s], q.to[s] = first(q.pools[j].body), last(q.pools[j].body)
        else
            j = neediest_pool(q, k)
            if j == 0
                q.serving[k] -= 1
                return Claim(:done)
            end
            # An empty stretch: it takes what is left of the pool's head, then the
            # second half of the largest stretch, as any of the pool's slots would.
            q.from[s], q.to[s] = UnitIdx(1), UnitIdx(0)
        end
        q.pool[s] = j
        q.serving[k] -= 1
        q.serving[j] += 1
        return Claim(:rebind, UnitIdx(0), j)
    end
end

# The pool a slot whose own pool `k` has run dry does the most good in, or 0 for
# none: of the pools that one more worker makes finish sooner, the one that finishes
# last. Each pool is played out (`finish_time`): its unclaimed units, in the order they
# are handed out, each to whichever of its workers is free first, its own workers free
# now and the new one once it has started its process and compiled what the others
# have (`cold_cost`). Units are whole, so a worker that is ready only after the others
# have claimed the last of them makes the pool finish no sooner.
function neediest_pool(q::Queues, k::Integer)
    best, latest = 0, 0.0
    for j in eachindex(q.pools)
        j == k && continue
        units = unclaimed_work(q, j)
        isempty(units) && continue
        n = q.serving[j]
        without = n == 0 ? Inf : finish_time(units, zeros(n))
        with = finish_time(units, [zeros(n); cold_cost(q, j)])
        with < without && without > latest && ((best, latest) = (j, without))
    end
    return best
end

# When the last of `units`, durations in seconds in the order they are handed out,
# ends, on workers free from the times `free`, each taking the next unit as it is free.
function finish_time(units::Vector{Float64}, free::Vector{Float64})
    free = copy(free)
    for d in units
        _, w = findmin(free)
        free[w] += d
    end
    return maximum(free)
end

# Pool `j`'s unclaimed units, each its estimated seconds, in the order they are handed
# out: its head, its body, its tail, which are consecutive. A recorded duration is
# scaled by how this run's items took against theirs. An item without one counts as
# the pool's average item so far. Before the pool has timed any, it counts as the
# typical recorded item, as in the plan.
function unclaimed_work(q::Queues, j::Integer)
    st = q.stats[j]
    scale = st.estimated_s > 0 ? st.estimated_took_s / st.estimated_s : 1.0
    unknown = st.items > 0 ? st.took_s / st.items : q.typical
    pool = q.pools[j]
    return Float64[q.est[u] * scale + q.unrecorded[u] * unknown for u in first(pool.head):last(pool.tail) if !q.claimed[u]]
end

# What a fresh worker in pool `j` costs before it is as fast as the pool's others:
# starting its process, and compiling what they already have. Measured in the pool
# once the run has seen it there, across the run's pools before that, and taken
# from earlier runs before the run has seen it at all.
function cold_cost(q::Queues, j::Integer)
    st = q.stats[j]
    starts = sum(x -> x.starts, q.stats)
    start = st.starts > 0 ? st.start_s / st.starts :
        starts > 0 ? sum(x -> x.start_s, q.stats) / starts : q.prior.start_s
    excess(cold_s, cold, warm_s, warm) = max(0.0, cold_s / cold - warm_s / warm)
    cold, warm = sum(x -> x.cold, q.stats), sum(x -> x.warm, q.stats)
    compile = st.cold > 0 && st.warm > 0 ? excess(st.cold_compile_s, st.cold, st.warm_compile_s, st.warm) :
        cold > 0 && warm > 0 ?
        excess(sum(x -> x.cold_compile_s, q.stats), cold, sum(x -> x.warm_compile_s, q.stats), warm) :
        q.prior.compile_s
    return start + compile
end

# A worker process of slot `s` took `seconds` to be ready for its first item.
note_start!(q::Queues, s::Integer, seconds::Real) = @lock q.lock begin
    st = q.stats[q.pool[s]]
    st.starts += 1
    st.start_s += seconds
    nothing
end

cancel!(q::Queues) = @lock q.lock (was = q.cancelled; q.cancelled = true; was)
is_cancelled(q::Queues) = @lock q.lock q.cancelled
set_paused!(q::Queues, v::Bool) = @lock q.lock (q.paused = v; nothing)
is_paused(q::Queues) = @lock q.lock q.paused

# Backpressure: hold new work while the machine is short of memory. Bounded,
# because the pressure is often someone else's, and a run that quietly stops making
# progress is worse than one that runs on a busy machine. Cancellation always gets
# through.
const MAX_BACKPRESSURE_SECONDS = 30.0

function wait_while_paused(q::Queues, slot::Slot)
    is_paused(q) || return nothing
    # Between units the worker is idle, and what its items left behind is what the
    # hold waits to see go: a worker left alone may not collect it for a long time.
    (@atomic slot.recycle) || collect_garbage(@atomic slot.worker)
    deadline = time() + MAX_BACKPRESSURE_SECONDS
    # A slot asked to replace its worker does it now, which frees memory sooner
    # than waiting does.
    while is_paused(q) && !is_cancelled(q) && !(@atomic slot.recycle) && time() < deadline
        sleep(0.2)
    end
    if is_paused(q) && !is_cancelled(q) && time() >= deadline
        set_paused!(q, false)
        @warn "Runtests: memory has stayed tight for $(round(Int, MAX_BACKPRESSURE_SECONDS))s; " *
            "continuing rather than stalling the run" maxlog = 1
    end
    return nothing
end

# Asks a worker to collect its garbage, without waiting for it to finish. A worker
# answers requests one at a time, so one running an item gets to it afterwards.
function collect_garbage(w::Union{Nothing, RuntestsWorkers.Worker})
    w === nothing && return nothing
    try
        RuntestsWorkers.remote_eval(w, :(GC.gc(true)))
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

"""
    Statuses

Per-item results, written by whichever slot task owns the item. Arrays rather than
objects so that the run state can be written straight out of them.
"""
struct Statuses
    counted::Vector{Bool}      # an item is counted as finished once, however many attempts
    synthetic::Vector{Bool}      # the outcome was written by the coordinator, not by the item
    state::Vector{ItemState}
    start::Vector{Float32}   # seconds from the start of the run to the item's dispatch
    attempt::Vector{Int8}
    slot::Vector{SlotIdx}
    pid::Vector{Int32}       # the process its last attempt ran in, 0 for none
    # Where its last attempt came among the items its process ran, 1 for a fresh
    # process and 0 for none; a fresh process has yet to compile what the others have.
    seq::Vector{Int16}
    elapsed::Vector{Float32}
    compile::Vector{Float32}
    testsets::Vector{Any}
    # What its last attempt left of evidence, as `ItemResult.artifacts` says it.
    artifacts::Vector{UInt8}
end

Statuses(n::Integer) = Statuses(
    falses(n), falses(n), fill(UNSEEN, n), zeros(Float32, n), zeros(Int8, n), fill(SlotIdx(0), n),
    zeros(Int32, n), zeros(Int16, n), zeros(Float32, n), zeros(Float32, n),
    Vector{Any}(nothing, n), zeros(UInt8, n)
)

mutable struct Run
    const plan::Plan
    const queues::Queues
    const statuses::Statuses
    const slots::Vector{Slot}
    const project_name::String
    const runid::String
    # The run's own temporary directory: coverage counts, which the run merges into
    # `lcov.info`, and the items' logs when there is no run state to keep them by.
    const scratch::String
    # Where the items' logs go: beside the run state, which they share a lifetime with
    # (see `logs_dir`), once it is open; `scratch` until then.
    logdir::String
    logprefix::String   # `logdir` and the part of a log's name that never varies
    # The same for the attempts' evidence (see `artifacts_path`), absolute: `logprefix`
    # once the run state is open; until then, and without one, a directory of the run's
    # own in the system's temporary files, made only if an attempt asks, which outlives
    # the run.
    artifacts_prefix::String
    # Where `RUNTESTS_ARTIFACT_DIR` had the run copy its run state and logs, once it
    # has; empty otherwise.
    exported::String
    # Per package, where its items' logs and evidence go: `logdir`, `logprefix` and
    # `artifacts_prefix` are the first package's, the one of a standalone run. A log is
    # named by the item's index in its package's run state.
    const logdirs::Vector{String}
    const logprefixes::Vector{String}
    const artifacts_prefixes::Vector{String}
    const local_item::Vector{ItemIdx}
    # Per package, once the environment is active: the project its items run in, the
    # test environment of a standalone run, the union environment of a combined one,
    # or an isolated package's own test project.
    const package_projects::Vector{String}
    # The name column, chosen once from every name the run will print, and each
    # item's name as it is written there (see `item_names`).
    const name_width::Int32
    const names::Vector{String}
    const printer::ReentrantLock
    const t0::Float64
    # Opened once the test environment is active, after the monitor, which writes
    # its peaks here, has started.
    @atomic runstate::Union{Nothing, RunStateFile, RunStateSet}
    monitor::Union{Nothing, Monitor}
    # The project directory the workers of a profile run in, by the profile's index.
    # Only a profile that declares preferences or runs in an environment directory has
    # one; the others use the test environment.
    const profile_projects::Dict{ProfileIdx, String}
    @atomic ndone::Int
    # Items whose state does not pass, kept by `set_state!` for the status line,
    # which is drawn from other threads than the one the states are written on.
    @atomic nonpass::Int
    # When an item last finished, or testing started: what the watchdog measures from.
    @atomic last_finish::Float64
    # Set when the watchdog stopped the run because nothing finished in time.
    @atomic stalled::Bool
    # The tasks running items, for the watchdog to interrupt.
    const tasks::Vector{Task}
    # Workers `kill_workers!` took from their slots, for `shutdown!` to wait for.
    const killed::Vector{RuntestsWorkers.Worker}
    # Guards `tasks`, `killed`, `item_pids` and `evidence`, which other tasks use as well.
    const lock::ReentrantLock
    # Every process an attempt ran in: under coverage, each should leave a tracefile.
    const item_pids::Set{Int32}
    # The attempts whose evidence is kept, as (item, attempt), for the closing report.
    const evidence::Vector{Tuple{ItemIdx, Int8}}
    coverage::Union{Nothing, CoverageSummary}
    # An editor's, when it asked for the run: each item's start and end go there.
    const events::Union{Nothing, EventStream}
    # The caller's `on_item`, or nothing: none was given, one call threw, or the
    # process is exiting. Called under `on_item_lock`, so calls never overlap.
    @atomic on_item::Any
    const on_item_lock::ReentrantLock
end

# One at a time in a process: a run, `chores` and a pasted item set the root paths
# are printed against, switch the active project and put the setups on `LOAD_PATH`,
# and a run takes the process's interrupt and exit hook, all of which a second beside
# it, in another task, would change under the first. Each claims the process before
# it touches any of that, so a refused one changes nothing.
const RUN_ACTIVE = Threads.Atomic{Bool}(false)
const BUSY = "Runtests is already at work in this process (a run, `chores` or a pasted " *
    "`@testitem`); wait for it to end, or use another Julia process"

# Whether this call claimed the process; one that did releases it.
claim_process!() = !Threads.atomic_cas!(RUN_ACTIVE, false, true)
release_process!() = (RUN_ACTIVE[] = false; nothing)

function exclusively(f)
    claim_process!() || throw(ConfigError(BUSY))
    try
        return f()
    finally
        release_process!()
    end
end

"""
    execute(plan, target; on_item = nothing) -> Run

Run the plan to completion and return the run, whose `statuses` hold what
happened to every item. Printing and the pass/fail verdict are `report`'s job,
so a caller that wants to inspect the outcome does not have to catch anything.
The caller holds the process (`exclusively`). `on_item` is called with an
[`ItemEvent`](@ref) as each attempt starts and ends.
"""
function execute(p::Plan, target; on_item = nothing)
    cfg = p.cfg
    warn_sandboxed_workers(p)
    project_name = something(project_name_of(target.project), "")
    runid = string(time_ns(); base = 16)
    scratch = mktempdir(; prefix = "runtests_")
    names, column = item_names(p, name_width(p.items.name; columns = terminal_columns(stdout isa Base.TTY)))
    # A package's logs go in a directory of their own until its run state is open.
    npkg = length(p.packages)
    logdirs = npkg == 1 ? [scratch] : [mkpath(joinpath(scratch, string(k))) for k in 1:npkg]
    evidence = joinpath(tempdir(), string("runtests_artifacts_", runid))
    artifacts_prefixes = npkg == 1 ? [joinpath(evidence, "item_")] : [joinpath(evidence, string(k), "item_") for k in 1:npkg]
    local_item = zeros(ItemIdx, nitems(p))
    seen = zeros(Int, npkg)
    for i in 1:nitems(p)
        local_item[i] = (seen[p.items.package[i]] += 1)
    end
    run = Run(
        p, Queues(p), Statuses(nitems(p)), Slot[], project_name, runid, scratch, scratch,
        joinpath(scratch, "item_"), artifacts_prefixes[1], "", logdirs, [joinpath(d, "item_") for d in logdirs],
        artifacts_prefixes, local_item, String[], column, names,
        ReentrantLock(), time(), nothing, nothing, Dict{ProfileIdx, String}(), 0, 0, 0.0, false, Task[],
        RuntestsWorkers.Worker[], ReentrantLock(), Set{Int32}(), Tuple{ItemIdx, Int8}[], nothing, EVENTS[], on_item,
        ReentrantLock()
    )
    run.events === nothing || (run.events.run = run)
    SLOT_LABEL_WIDTH[] = slot_label_width(nslots(p))
    cfg.coverage && mkpath(coverage_dir(scratch))
    # Ctrl-C caught by any task the run starts is thrown into this one, which is
    # where the run knows how to stop.
    outer = @atomic RuntestsWorkers.INTERRUPT_TARGET.task
    @atomic RuntestsWorkers.INTERRUPT_TARGET.task = current_task()
    # The slots, then the monitor: its task walks `run.slots` from another thread,
    # so the vector is complete before that task exists, and is never resized.
    for s in 1:nslots(p)
        push!(
            run.slots, Slot(
                SlotIdx(s), p.pools[p.slot_pool[s]].profile,
                nothing, 0.0, 0, ItemIdx(0), Int8(0), "", String[], false, ItemIdx(0)
            )
        )
    end
    if cfg.monitor
        monitor = Monitor(run; print_interval = cfg.monitor_interval)
        run.monitor = monitor
        start_monitor!(monitor)
    end
    # The setups of each package that does not run apart, on one load path.
    setup_paths = String[joinpath(r, "test", TESTSETUPS_DIR) for (r, isolated) in zip(p.packages.root, p.packages.isolated)
                         if !isolated]
    return try
        run_phases(run, p, target, setup_paths)
    finally
        # Wherever the run stopped: a throw before the first item would otherwise
        # leave the monitor running and the error printed over its line.
        shielded(() -> stop_monitor!(run.monitor))
        @atomic RuntestsWorkers.INTERRUPT_TARGET.task = outer
    end
end

function run_phases(run::Run, p::Plan, target, setup_paths::Vector{String})
    return with_logger(RunLogger(current_logger(), run)) do
        with_run_env(target, run) do
            # Before the run state: an environment directory that does not resolve
            # stops the run before anything has run to record.
            profile_projects!(run, p)
            # Opened once the test environment is active: its manifest is part of
            # what the file records. A run of several packages has one for each.
            @atomic run.runstate = is_combined(p) ? open_runstate_set(p, run.t0, run.runid) : open_runstate(p, run.t0)
            keep_logs_by_runstate!(run)
            # Until the first item can start, a throw ends the run here, and its file
            # must say so: unfinished, its beats would keep it looking alive for as
            # long as this process lasts. Why it ended goes beside it.
            testing = Ref(false)
            try
                run_testing(run, p, target, setup_paths, testing)
            catch e
                if !testing[]
                    shielded() do
                        write_run_log(run, "setup.log", sprint(showerror, e))
                        finish_run_state!(run.runstate; aborted = true)
                        tidy_logs(run)
                        export_run!(run)
                    end
                end
                rethrow()
            end
        end
    end
end

# Setup, then the items. `testing` is set once the items' own `finally` is in place
# to finish the run state.
function run_testing(run::Run, p::Plan, target, setup_paths::Vector{String}, testing::Ref{Bool})
    cfg = p.cfg
    check_replayed_environment(run)
    return with_load_path(setup_paths) do
        precompile_phase(run, p, target)
        # From the start of the run, as the monitor's setup stage is, so the
        # header and the closing block give the same figure.
        p.startup.setup = time() - run.t0
        # Printed once setup is done, so it can say what setup cost.
        print_run_header(run)
        set_phase!(run.monitor, PHASE_TEST)
        interrupted = false
        ensure_exit_report()
        LIVE_RUN[] = run
        limit = stall_limit(p)
        @atomic run.last_finish = time()
        watchdog = start_watchdog(run, limit)
        testing[] = true
        try
            if cfg.workers == 0
                run_in_process(run, target)
            else
                run_on_workers(run, target)
            end
            # Stopped with nothing in flight to interrupt: the slots saw their
            # workers go and ended on their own.
            (@atomic run.stalled) && throw(RunStalled(limit))
        catch e
            stalled = @atomic run.stalled
            if is_interrupt(e) || stalled
                interrupted = true
                shielded(() -> kill_workers!(run))
            end
            stalled ? throw(RunStalled(limit)) : rethrow()
        finally
            # Shielded: after a cancellation every wait in this task throws
            # again, and this has to finish.
            shielded() do
                close(watchdog)
                # Reaching here at all means the run unwound, so the exit
                # hook has nothing left to close.
                LIVE_RUN[] = nothing
                set_phase!(run.monitor, PHASE_REPORT)
                stop_monitor!(run.monitor)
                shutdown!(run)
                record_cpu_end!(run.monitor)
                # Every worker has exited, so every tracefile there will be
                # is written.
                cfg.coverage && (run.coverage = collect_coverage(run))
                run.monitor === nothing || write_memory!(run.runstate, run.monitor.stats)
                finish_run_state!(run.runstate; cancelled = is_cancelled(run.queues))
                tidy_logs(run)
                export_run!(run)
                # A replay deletes no run state, the one it runs least of all. Each
                # package prunes its own.
                if isempty(p.cfg.replayed_from)
                    for k in eachindex(p.packages.root)
                        prune_runstates(p.packages.root[k]; names = Set(p.packages.suite_names[k]))
                    end
                end
                # The exception on its way out stops the report from being
                # made, so what the run got through is said here or nowhere.
                interrupted && print_conclusion(run, (@atomic run.stalled) ? :stalled : :interrupted)
            end
        end
        run
    end
end

"""
    with_test_env(f, target)

Run `f` with the package's test environment active, and restore whatever was
active afterwards. The environment is:

1. the active one, when the call came from `<root>/test/runtests.jl`: that is
   `Pkg.test`, which has built an environment with the test dependencies;
2. the active one, when it is the package's own `test/Project.toml`, because
   activating that is a deliberate choice;
3. the package's `test/Project.toml`, when it is a member of the workspace the
   package is in, which shares its manifest, as `Pkg.test` uses it;
4. otherwise a test environment built by `TestEnv`.

The last two are cached for the session.

Never the package's plain project, which lacks the test-only dependencies.
"""
function with_test_env(f, target, run = nothing)
    # Building it is `Pkg`'s to narrate, and it draws its own progress by moving
    # the cursor. Ours comes down while it does.
    monitor = run === nothing ? nothing : run.monitor
    env = with_status_line_off(monitor) do
        test_env_for(target, run === nothing ? nothing : () -> say(run, "resolving the test environment"))
    end
    env === nothing && return f()
    current = Base.active_project()
    Base.set_active_project(env)
    try
        return f()
    finally
        Base.set_active_project(current)
    end
end

"""
    test_env_for(target) -> Union{Nothing,String}

The environment the target's items resolve against, or `nothing` when the active
one is it. `activate` asks too, and must agree with a run.
"""
function test_env_for(target, announce = nothing)
    current = Base.active_project()
    if current !== nothing
        running_from_runtests(target) && return nothing
        testproj = joinpath(target.testdir, "Project.toml")
        isfile(testproj) && abspath(current) == abspath(testproj) && return nothing
    end
    env = test_env(target, announce)::String
    (current !== nothing && abspath(current) == abspath(env)) && return nothing
    return env
end

# `f(Pkg, TestEnv)`, loading them the first time any call needs them rather than with
# this package: a worker process loads this package too, and Pkg alone would double
# the time a worker takes to start. Loaded during the call, their functions are newer
# than its caller, so `f` runs in the latest world.
const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const TESTENV_ID = Base.PkgId(Base.UUID("1e6cf692-eddd-4d53-88a5-2d735e33781b"), "TestEnv")
with_pkg(f) = Base.invokelatest(f, Base.require(PKG_ID), Base.require(TESTENV_ID))

# Test environments, kept for the session and keyed by project file: building one
# costs a resolve, seconds at the REPL. It costs no compilation: caches are keyed by
# package versions and flags, not by environment, so a new environment with the same
# versions reuses them. The stamp is what it was generated from, so a test dependency
# added mid-session rebuilds it.
const TEST_ENVS = Dict{String, Tuple{String, NTuple{4, Tuple{String, Float64}}}}()
const TEST_ENVS_LOCK = ReentrantLock()

function test_env(target, announce = nothing)
    proj = abspath(target.project)
    return @lock TEST_ENVS_LOCK begin
        cached = get(TEST_ENVS, proj, nothing)
        if cached !== nothing && isfile(cached[1]) && cached[2] == env_stamp(target)
            return cached[1]
        end
        # Announced only when building: a cache hit is immediate, and at the REPL
        # the hit is the point.
        announce === nothing || announce()
        original = Base.active_project()
        try
            # `Pkg` would precompile the new environment for this process's flags
            # only; `precompile_env` does it once for every set of flags the pools
            # use, and the time reported against this stays the resolve's.
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
                testproj = joinpath(target.testdir, "Project.toml")
                if in_package_workspace(testproj, proj)
                    # It shares the package's manifest, so `Pkg.test` runs it as it
                    # is, without a sandbox.
                    with_pkg() do Pkg, _
                        Pkg.activate(testproj; io = devnull)
                        Pkg.instantiate(; allow_autoprecomp = false)
                    end
                else
                    with_pkg() do Pkg, TestEnv
                        Pkg.activate(proj; io = devnull)
                        TestEnv.activate()
                    end
                end
            end
            # What activating made active: a project, or it would have thrown.
            env = Base.active_project()::String
            # Stamped *after* generating it: resolving writes the package's manifest,
            # so a stamp taken beforehand never matches again and every call would
            # rebuild the environment it was supposed to cache.
            TEST_ENVS[proj] = (env, env_stamp(target))
            return env
        catch e
            is_interrupt(e) && rethrow()
            throw(
                ConfigError(
                    "could not build a test environment for $(relpath_or_path(proj)): " *
                        sprint(showerror, e)
                )
            )
        finally
            Base.set_active_project(original)
        end
    end
end

# The package's project and the test project, each with the manifest Julia reads for
# it: `Manifest-v1.x.toml` before `Manifest.toml`, a workspace's shared one. Paths
# as well as times, so a manifest that takes over from another changes the stamp.
function env_stamp(target)
    proj = abspath(target.project)
    testproj = joinpath(target.testdir, "Project.toml")
    stamped(path) = (path, mtime_or_zero(path))
    manifest(project) = something(isfile(project) ? Base.project_file_manifest_path(project) : nothing, "")
    return (stamped(proj), stamped(manifest(proj)), stamped(testproj), stamped(manifest(testproj)))
end

mtime_or_zero(path::AbstractString) = isfile(path) ? mtime(path) : 0.0

# Whether `test/Project.toml` is a member of a workspace, and of the one the package
# is in: the package's own, or one that lists both, as a monorepo's root does,
# directly or through the package's own. Julia's loader finds a member's manifest by
# following its workspace parents, so the outermost roots decide.
function in_package_workspace(testproj, proj)
    isfile(testproj) || return false
    @static if isdefined(Base, :base_project)
        Base.base_project(testproj) === nothing && return false
        return samefile(outermost_workspace(testproj), outermost_workspace(proj))
    else
        return false   # workspaces came with Julia 1.12
    end
end

# The project at the top of the workspaces that `project` is a member of, or
# `project` itself when it is a member of none.
function outermost_workspace(project)
    while true
        parent = Base.base_project(project)
        (parent === nothing || samefile(parent, project)) && return project
        project = parent
    end
end

# `Pkg.test` runs `test/runtests.jl` in an environment it built for the purpose.
# The file being evaluated is how we can tell.
function running_from_runtests(target)
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    source === nothing && return false
    return abspath(String(source)) == abspath(joinpath(target.testdir, "runtests.jl"))
end

# A replay runs against this machine's environment, which may not be the one the
# run state was recorded in. Every package whose version differs is named: it is
# the first thing to rule out when a replay does not fail the way the original did.
function check_replayed_environment(run::Run)
    cfg = run.plan.cfg
    if !isempty(cfg.julia_flags)
        here = join(nondefault_flags(code_flags()), " ")
        say(run, string("the workers compile with the Julia flags the run state recorded, ",
                        join(nondefault_flags(cfg.julia_flags), " "), ", where this process has ",
                        isempty(here) ? "none of them" : here))
        cfg.workers == 0 && @warn "Runtests: the run state was recorded with the Julia flags " *
            "$(join(cfg.julia_flags, " ")), and `workers = 0` runs the items in this process, which has " *
            "$(join(code_flags(), " ")); give it one worker or more to run them as they were run"
    end
    recorded = cfg.replayed_manifest
    isempty(recorded) && return nothing
    env = Base.active_project()
    here = manifest_versions(read_text(env === nothing ? nothing : Base.project_file_manifest_path(env)))
    there = manifest_versions(recorded)
    diffs = String[]
    for name in sort!(collect(union(keys(here), keys(there))))
        h, t = get(here, name, "absent"), get(there, name, "absent")
        h == t || push!(diffs, string(name, ": ", t, " when recorded, ", h, " here"))
    end
    isempty(diffs) && return say(run, "the environment matches the one the run state was recorded in")
    @warn "Runtests: the environment differs from the one the run state was recorded in:\n" *
        join(("  " * d for d in first(diffs, 40)), "\n") * (length(diffs) > 40 ? "\n  …" : "")
    return nothing
end

# Package name => version, from a manifest's text. A package tracked by path is
# `path`: its path is the recording machine's and says nothing here.
function manifest_versions(text::AbstractString)
    out = Dict{String, String}()
    isempty(text) && return out
    toml = try
        TOML.parse(text)
    catch
        return out
    end
    for (name, entries) in get(Dict{String, Any}, toml, "deps")
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict || continue
            out[name] = haskey(entry, "path") ? "path" : string(get(entry, "version", get(entry, "git-tree-sha1", "stdlib")))
        end
    end
    return out
end

# A run state we cannot write is a run state we do without: the tests matter more
# than the record of them.
function open_runstate(p::Plan, start::Float64)
    path = nothing
    try
        path = new_runstate_path(p.root)
        return init_run_state(path, p; start)
    catch e
        # A name claimed and left empty would never be read, nor pruned.
        path === nothing || rm(path; force = true)
        @warn "Runtests: could not open a run state file; continuing without one" exception = e
        return nothing
    end
end

# The items' logs go beside the run state once it is open, so that they last as long
# as it does: each package's beside its own. Without one, or without a directory
# there, they stay in `scratch`.
function keep_logs_by_runstate!(run::Run)
    rs = @atomic run.runstate
    files = rs isa RunStateSet ? rs.files : [rs]
    for (k, rsf) in enumerate(files)
        rsf === nothing && continue
        dir = logs_dir(rsf.path)
        try
            mkpath(dir)
        catch e
            is_interrupt(e) && rethrow()
            @warn "Runtests: could not make $(dir) for the items' logs; they go with the run" exception = e
            continue
        end
        run.logdirs[k] = dir
        run.logprefixes[k] = joinpath(dir, "item_")
        # Absolute: a worker runs in the package's directory, and an item is handed it.
        run.artifacts_prefixes[k] = abspath(run.logprefixes[k])
    end
    run.logdir, run.logprefix, run.artifacts_prefix = run.logdirs[1], run.logprefixes[1], run.artifacts_prefixes[1]
    return nothing
end

# `text` as `name` in each package's log directory; never a reason to fail the run.
function write_run_log(run::Run, name::AbstractString, text::AbstractString)
    for dir in run.logdirs
        try
            write(joinpath(dir, name), text)
        catch e
            is_interrupt(e) && rethrow()
        end
    end
    return nothing
end

# Where attempt `attempt` at item `i` writes what it prints, and its failure report:
# with its package's logs, by its index in its package's run state.
item_log(run::Run, i::Integer, attempt::Integer) =
    item_log_path(run.logprefixes[run.plan.items.package[i]], run.local_item[i], attempt)
failure_log(run::Run, i::Integer, attempt::Integer) =
    failure_path(run.logprefixes[run.plan.items.package[i]], run.local_item[i], attempt)

# Whether a plan is a run of several packages, each with a run state of its own:
# packages other than the one at its root.
is_combined(p::Plan) = length(p.packages) > 1 || p.packages.root[1] != p.root

function write_failure_report(run::Run, i::ItemIdx, attempt::Integer, testset)
    failures = collect_failures(testset)
    isempty(failures) && return nothing
    text = sprint() do io
        for r in failures
            show(io, r)
            println(io)
        end
    end
    try
        write(failure_log(run, i, attempt), strip_root(text, run.plan.root))
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

"""
    export_run!(run)

Copy the run's run state and its logs into the directory `RUNTESTS_ARTIFACT_DIR`
names, when it names one: what a CI job uploads as the evidence of its own run,
apart from the run-state directory, whose history it caches for the next run. Called
once the run state is finished, however the run ended. Never a reason to fail it.
"""
function export_run!(run::Run)
    dir = get(ENV, "RUNTESTS_ARTIFACT_DIR", "")
    rs = @atomic run.runstate
    (isempty(dir) || rs === nothing) && return nothing
    try
        dir = abspath(dir)
        # A run of several packages: each package's in a directory of its name.
        files = rs isa RunStateSet ? collect(zip(rs.files, run.plan.packages.name)) : [(rs, "")]
        for (rsf, sub) in files
            rsf === nothing && continue
            to = joinpath(dir, sub)
            mkpath(to)
            cp(rsf.path, joinpath(to, basename(rsf.path)); force = true)
            logs = logs_dir(rsf.path)
            isdir(logs) && cp(logs, joinpath(to, basename(logs)); force = true)
        end
        run.exported = dir
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not copy the run state and logs to `RUNTESTS_ARTIFACT_DIR` ($dir)" exception = e
    end
    return nothing
end

# A log an attempt left empty says nothing, and a directory of them is noise; what
# is left is what the items printed, and the reports of those that did not pass.
function tidy_logs(run::Run)
    for k in eachindex(run.logdirs)
        logdir, prefix, evidence = run.logdirs[k], run.logprefixes[k], run.artifacts_prefixes[k]
        evidence == abspath(prefix) || remove_if_empty(dirname(evidence))
        startswith(logdir, run.scratch) && continue
        try
            for f in readdir(logdir; join = true)
                isfile(f) && filesize(f) == 0 && rm(f; force = true)
            end
            isempty(readdir(logdir)) && rm(logdir; force = true)
        catch e
            is_interrupt(e) && rethrow()
        end
    end
    return nothing
end

"""
    needs_worker(p, u) -> Bool

Whether this unit needs a process of its own however the run is configured:
`--check-bounds=yes` cannot be applied to a running process, one process cannot
give an item a process to itself, and it loads the packages of one environment.
Such an item gets a worker even under `workers=0`; passing it here would pass a test
that never ran as written.
"""
needs_worker(p::Plan, u::UnitIdx) = p.units.exclusive[u] || !is_plain(p.profiles[p.units.profile[u]])

# The default profile in the test environment: what this process can be.
is_plain(prof::Profile) = prof.name === DEFAULT_PROFILE && isempty(prof.environment)

# Whether any of the run's items runs under a profile other than the default, or in
# an environment other than the test environment.
uses_profiles(p::Plan) = any(i -> p.profiles[i].name !== DEFAULT_PROFILE, p.units.profile)
uses_environments(p::Plan) = any(i -> !isempty(p.profiles[i].environment), p.units.profile)

# How a worker's UP line names profile `j`, "" for not at all. In a run of several
# profiles, every profile is named, the default too, because a slot can move from one
# profile's pool to another's. Otherwise every profile but the default of the run's
# first package is named; that package is the root's when the root runs. In a run of
# several packages, the name comes with the package that declares the profile.
function profile_text(p::Plan, j::Integer)
    k = p.profile_package[j]
    (uses_profiles(p) || k != 1) || return ""
    return string(" · profile ", p.profiles[j].name, is_combined(p) ? string(" of ", p.packages.name[k]) : "")
end

# `workers=0` is a promise about the pool, not about never starting a process.
# Starting one anyway is the right thing and a surprising thing, so it is said out
# loud, once, with the items that caused it.
function warn_sandboxed_workers(p::Plan)
    single_process(p) || return nothing
    names = String[]
    for u in UnitIdx(1):UnitIdx(length(p.units))
        needs_worker(p, u) && append!(names, (p.items.name[i] for i in p.units.span[u]))
    end
    isempty(names) && return nothing
    @warn "Runtests: workers=0, but these items need a process this one cannot be, for a sandbox, " *
        "a profile or an environment, so each one gets a worker of its own that is torn down afterwards:\n" *
        join(("  " * repr(n) for n in names), "\n")
    return nothing
end

function project_name_of(projectfile::AbstractString)
    try
        return get(TOML.parsefile(projectfile), "name", nothing)
    catch
        return nothing
    end
end

# The setups directory is an implicit environment, so putting it on LOAD_PATH is
# all that `using MySetup` needs. Done for the duration of the run rather than
# permanently: a test run should not leave the caller's session changed.
function with_load_path(f, setup_path::AbstractString)
    isdir(setup_path) || return f()
    setup_path in LOAD_PATH && return f()
    push!(LOAD_PATH, setup_path)
    try
        return f()
    finally
        i = findlast(==(setup_path), LOAD_PATH)
        i === nothing || deleteat!(LOAD_PATH, i)
    end
end

with_load_path(f, setup_paths::Vector{String}) =
    isempty(setup_paths) ? f() : with_load_path(() -> with_load_path(f, setup_paths[2:end]), setup_paths[1])

# The environment a run's items resolve against, active for the length of `f`: the
# test environment of a standalone run (`with_test_env`), the union environment of a
# combined one (`with_union_env`). `run.package_projects` says, for each package, the
# project its items run in.
function with_run_env(f, target, run::Run)
    is_combined(run.plan) && return with_union_env(f, run)
    return with_test_env(target, run) do
        push!(run.package_projects, something(Base.active_project(), ""))
        f()
    end
end

"""
    profile_projects!(run, p)

Give every pool's profile that declares preferences, or runs in an environment
directory, a project of its own. A package takes its preferences from the
environment that owns it, and a stacked environment is not consulted, so a profile's
preferences have to arrive as the worker's own project: the test environment's
`Project.toml` and `Manifest.toml`, over a `LocalPreferences.toml` of the
environment's preferences with the profile's on top. Preferences are part of a
cache's identity, so these projects keep caches of their own. A pool in an
environment directory runs in a copy of it instead (see
[`environment_project`](@ref)).
"""
function profile_projects!(run::Run, p::Plan)
    for (j, prof) in enumerate(p.profiles)
        env = run.package_projects[p.profile_package[j]]
        announce = () -> say(run, "resolving the environment of ", relpath_or_path(prof.environment, p.root))
        # An environment directory gets the package of its own suite.
        dir = profile_project(prof, env, p.packages.root[p.profile_package[j]], announce)
        dir === nothing || (run.profile_projects[ProfileIdx(j)] = dir)
    end
    return nothing
end

# The project `prof`'s workers run in, or `nothing` for a profile without
# preferences or an environment, whose workers run in the environment `env` itself.
# For one with an environment, see `environment_project`, which `root`, the package
# under test, and `announce` are for. Otherwise in the system's temporary files,
# keyed by `env`'s path and the preferences file, and never beside `env`, which can
# be the package's own `test/`. The preferences file is in the key because profiles
# of one name in two packages of a combined run share `env` and can name different
# files. Rewritten on every call, so it follows the environment and the preferences
# file.
function profile_project(prof::Profile, env, root = nothing, announce = nothing)
    isempty(prof.environment) || return environment_project(prof, root, announce)
    (env === nothing || isempty(prof.preferences)) && return nothing
    root = dirname(env)
    key = crc32c(string(abspath(env), '\0', abspath(prof.preferences)))
    dir = joinpath(tempdir(), "runtests_profiles", string(key; base = 16, pad = 8), String(prof.name))
    mkpath(dir)
    copy_env_files(dir, root)
    own = joinpath(root, "LocalPreferences.toml")
    merged = isfile(own) ? TOML.parsefile(own) : Dict{String, Any}()
    for (pkg, table) in TOML.parsefile(prof.preferences)
        # Per package, not per key: a half-overridden preferences table is a
        # configuration nobody wrote down.
        merged[pkg] = table
    end
    open(io -> TOML.print(io, merged), joinpath(dir, "LocalPreferences.toml"), "w")
    return dir
end

# The projects of profiles that name an environment, kept for the session as the
# test environment is, and keyed by the environment, the package and the
# preferences: building one is a resolve.
const ENVIRONMENT_PROJECTS = Dict{NTuple{3, String}, Tuple{String, Vector{Float64}}}()
const ENVIRONMENT_PROJECTS_LOCK = ReentrantLock()

"""
    environment_project(prof, root, announce = nothing) -> String

The project the workers of a profile in an environment directory run in. A copy of
that environment, in the system's temporary files so that nothing is written to the
directory, which is the package's own; with the package under
test at `root` developed into it by path, as it is in the test environment, which
brings the packages its `[sources]` name with it; resolved; and with the
environment's `LocalPreferences.toml` under the profile's preferences, as
[`profile_project`](@ref) lays them. Kept for the session, and built again once a
file it was built from changes: the environment's own, the package's project, the
preferences, or the project of a package it holds by path. `announce` is called
before building.
"""
function environment_project(prof::Profile, root, announce = nothing)
    root === nothing && throw(ConfigError(
        "the tests in $(relpath_or_path(prof.environment)) run in an environment of their own, and there is no package here to test in it"
    ))
    key = (prof.environment, String(root), prof.preferences)
    return @lock ENVIRONMENT_PROJECTS_LOCK begin
        cached = get(ENVIRONMENT_PROJECTS, key, nothing)
        if cached !== nothing && isdir(cached[1]) && cached[2] == environment_stamp(cached[1], prof, root)
            return cached[1]
        end
        announce === nothing || announce()
        dir = mktempdir(; prefix = "runtests_environment_")
        write_environment(dir, prof, root)
        resolve_environment(dir, prof)
        # Stamped once resolved: the packages it holds by path are in its manifest.
        ENVIRONMENT_PROJECTS[key] = (dir, environment_stamp(dir, prof, root))
        return dir
    end
end

# The environment `prof` names, written into `dir` with its paths made absolute, the
# package at `root` added by path, and the preferences laid over its own.
function write_environment(dir::AbstractString, prof::Profile, root::AbstractString)
    src = prof.environment
    projfile = something(project_file_in(src), joinpath(src, "Project.toml"))
    project = absolute_paths!(TOML.parsefile(projfile), src)
    own = project_file_in(root)
    pkg = own === nothing ? Dict{String, Any}() : TOML.parsefile(own)
    name, uuid = get(pkg, "name", nothing), get(pkg, "uuid", nothing)
    if name isa String && uuid isa String
        get!(Dict{String, Any}, project, "deps")[name] = uuid
        get!(Dict{String, Any}, project, "sources")[name] = Dict{String, Any}("path" => abspath(root))
    end
    open(io -> TOML.print(io, project; sorted = true), joinpath(dir, "Project.toml"), "w")
    manifest = Base.project_file_manifest_path(projfile)
    if manifest !== nothing && isfile(manifest)
        # A manifest's paths are its own directory's, which for a member of a
        # workspace is the workspace's.
        open(io -> TOML.print(io, absolute_paths!(TOML.parsefile(manifest), dirname(manifest)); sorted = true),
             joinpath(dir, "Manifest.toml"), "w")
    end
    own_prefs = joinpath(src, "LocalPreferences.toml")
    prefs = isfile(own_prefs) ? TOML.parsefile(own_prefs) : Dict{String, Any}()
    if !isempty(prof.preferences)
        for (p, table) in TOML.parsefile(prof.preferences)
            prefs[p] = table   # per package, as in `profile_project`
        end
    end
    isempty(prefs) || open(io -> TOML.print(io, prefs), joinpath(dir, "LocalPreferences.toml"), "w")
    return nothing
end

project_file_in(dir::AbstractString) =
    (i = findfirst(n -> isfile(joinpath(dir, n)), PROJECT_NAMES); i === nothing ? nothing : joinpath(dir, PROJECT_NAMES[i]))

# `Pkg` would precompile for this process's flags only, as for the test environment;
# `precompile_env` does it once for every set the pools use.
function resolve_environment(dir::AbstractString, prof::Profile)
    original = Base.active_project()
    try
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            with_pkg() do Pkg, _
                Pkg.activate(dir; io = devnull)
                Pkg.resolve(; io = devnull)
                Pkg.instantiate(; io = devnull)
            end
        end
    catch e
        is_interrupt(e) && rethrow()
        throw(ConfigError(string(
            "could not build the environment of ", relpath_or_path(prof.environment), ": ", sprint(showerror, e)
        )))
    finally
        Base.set_active_project(original)
    end
    return nothing
end

# When the files an environment directory's copy was built from were last written: the
# environment's own, the package's project, the preferences, and the project of every
# package the built one at `dir` holds by path, which is how a package's siblings in
# a monorepo come in.
function environment_stamp(dir::AbstractString, prof::Profile, root::AbstractString)
    files = String[joinpath(prof.environment, f) for f in
                   ("Project.toml", "JuliaProject.toml", "Manifest.toml", "JuliaManifest.toml", "LocalPreferences.toml")]
    push!(files, joinpath(root, "Project.toml"), joinpath(root, "JuliaProject.toml"))
    isempty(prof.preferences) || push!(files, prof.preferences)
    manifest = joinpath(dir, "Manifest.toml")
    if isfile(manifest)
        for (_, entries) in get(Dict{String, Any}, TOML.parsefile(manifest), "deps")
            entries isa AbstractVector || continue
            for entry in entries
                path = entry isa AbstractDict ? get(entry, "path", nothing) : nothing
                path isa AbstractString || continue
                at = normpath(joinpath(dir, path))
                push!(files, joinpath(at, "Project.toml"), joinpath(at, "JuliaProject.toml"))
            end
        end
    end
    return Float64[mtime_or_zero(f) for f in files]
end

"""
    copy_env_files(dir, root)

Write `root`'s `Project.toml` and `Manifest.toml` into `dir`, every path made
absolute: `dir` is elsewhere, so a relative path would resolve from the wrong
directory, and a worker whose project cannot find a developed package dies before it
is ready.
"""
function copy_env_files(dir::AbstractString, root::AbstractString)
    for file in ("Project.toml", "Manifest.toml")
        src = joinpath(root, file)
        isfile(src) || continue
        open(io -> TOML.print(io, absolute_paths!(TOML.parsefile(src), root); sorted = true),
             joinpath(dir, file), "w")
    end
    return nothing
end

"""
    absolute_paths!(data, root) -> data

Rewrite every `path` in a parsed project or manifest as absolute, reading relative
ones from `root`. The whole table is walked: in these files a `path` is a
filesystem path wherever it appears.
"""
function absolute_paths!(data::AbstractDict, root::AbstractString)
    for (key, value) in data
        if key == "path" && value isa AbstractString
            # A package tracked at the environment's own directory is written `.`,
            # which `abspath` turns into a path with a separator on the end.
            p = abspath(root, value)
            data[key] = isdirpath(p) ? dirname(p) : p
        elseif value isa AbstractDict
            absolute_paths!(value, root)
        elseif value isa AbstractVector
            for entry in value
                entry isa AbstractDict && absolute_paths!(entry, root)
            end
        end
    end
    return data
end

# One process precompiles what every worker is about to need; otherwise the workers
# hit the same cold cache at once and serialize on Julia's precompilation lock.
function precompile_phase(run::Run, p::Plan, target)
    # The environment first: a setup module compiled before it would make its
    # worker build the dependencies itself, one at a time.
    others = precompile_env(run, p)
    precompile_self(run, others)
    precompile_setups(run, p, target, others)
    return nothing
end

# Every field, in order: the set differs between versions (1.14 adds `coverage`).
const CACHE_FLAGS_CODE = "f = Base.CacheFlags(); print(join((getfield(f, i) for i in 1:nfields(f)), ' '))"

"""
    cache_flags_for(julia_args) -> Base.CacheFlags

The cache flags a worker started with `julia_args` will have, asked of a process
started the same way: which arguments reach the cache key is Julia's business and
changes between versions, and a wrong answer precompiles for the wrong key.
"""
function cache_flags_for(julia_args::Cmd)
    out = read(
        `$(Base.julia_cmd()) $julia_args --startup-file=no --history-file=no -e $CACHE_FLAGS_CODE`,
        String
    )
    f = split(out)
    T = Base.CacheFlags
    length(f) == fieldcount(T) || error("Runtests: could not read the cache flags of `julia $julia_args`: $out")
    return T((parse(fieldtype(T, i), f[i]) for i in 1:fieldcount(T))...)
end

"""
    precompile_env(run, p)

Precompile the test environment once for every set of cache flags the run will
use: this process's own, and one per pool with julia arguments of its own. A
package image built under other flags cannot be used, so a worker with other flags
would otherwise compile the package and its dependencies itself, serially and
silently, while the run looks stalled on its first item. `test_env` turns off
`Pkg`'s own precompilation so that this is the one pass.

Returns every set of cache flags the pools' workers have besides this process's, with
the julia arguments that give it, for the setups to be compiled for too.
"""
function precompile_env(run::Run, p::Plan)
    # Each set of flags is asked of a process of its own, so once.
    asked = Dict{Vector{String}, Union{Nothing, Base.CacheFlags}}()
    flags_of(prof) = get!(() -> profile_flags(prof), asked, prof.julia_args)
    # The flags this process runs under lead, because every pool without julia
    # arguments of its own uses them and because `test_env` switched `Pkg`'s own
    # precompilation off.
    configs = Pair{Cmd, Base.CacheFlags}[`` => Base.CacheFlags()]
    names = String[]
    others = Pair{Cmd, Base.CacheFlags}[]
    for pool in p.pools
        prof = p.profiles[pool.profile]
        # Only julia arguments reach the cache key.
        isempty(prof.julia_args) && continue
        flags = flags_of(prof)
        flags === nothing && continue
        flags == Base.CacheFlags() || flags in last.(others) || push!(others, Cmd(prof.julia_args) => flags)
        # A profile with preferences runs in a project of its own, which `configs`
        # cannot carry; it gets a call of its own below.
        (haskey(run.profile_projects, pool.profile) || flags in last.(configs)) && continue
        push!(configs, Cmd(prof.julia_args) => flags)
        push!(names, String(prof.name))
    end
    # One call each: a project is part of a cache's identity, so two profiles with
    # different preferences are two environments, not two configurations of one.
    for (j, dir) in sort!(collect(run.profile_projects); by = first)
        prof = p.profiles[j]
        flags = flags_of(prof)
        flags === nothing && continue
        where_ = isempty(prof.environment) ? "the test environment" :
            string("the environment of ", relpath_or_path(prof.environment, p.root))
        say(run, "precompiling ", where_, " for profile ", prof.name)
        precompile_configs(run, Cmd(prof.julia_args) => flags, joinpath(dir, "Project.toml"), "profile `$(prof.name)` in $where_")
    end
    # Named only when there is something to name: `Pkg` narrates the rest, and says
    # nothing when there is nothing to do.
    isempty(names) || say(run, "precompiling the test environment for ", plural(length(names), "profile"), ": ", join(names, ", "))
    precompile_configs(run, configs, Base.active_project(), join(names, ", "))
    # An isolated package's items run in its own test project, a project of its own.
    for k in eachindex(p.packages.name)
        p.packages.isolated[k] || continue
        say(run, "precompiling the test environment of ", p.packages.name[k])
        precompile_configs(run, configs, run.package_projects[k], p.packages.name[k])
    end
    return others
end

# The cache flags a profile's workers will have, or `nothing` — said once — when
# they cannot be read, in which case the workers compile what they need themselves.
function profile_flags(prof::Profile)
    return try
        isempty(prof.julia_args) ? Base.CacheFlags() : cache_flags_for(Cmd(prof.julia_args))
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not read the cache flags of profile `$(prof.name)`; its \
               workers will compile what they need themselves" exception = e
        nothing
    end
end

# One precompilation of `project`'s dependencies. Work brought forward, not work that
# has to succeed: a worker that finds nothing cached still compiles what it needs, one
# process at a time. The precompiler draws its own progress by moving the cursor, so
# ours comes down while it does. Base's, as `Pkg.precompile` calls it, without the
# `Pkg` context that call builds: making one rewrites the depot's whole manifest
# usage log, most of the step's cost when there is nothing to compile, and records
# the temporary test environment in it.
function precompile_configs(run::Run, configs, project, what::AbstractString)
    original = Base.active_project()
    try
        with_status_line_off(run.monitor) do
            Base.set_active_project(project)
            Base.Precompilation.precompilepkgs(String[]; configs, warn_loaded = false, io = stdout)
        end
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not precompile the test environment for $what; its workers \
               will compile what they need themselves" exception = e
    finally
        Base.set_active_project(original)
    end
    return nothing
end

"""
    precompile_setups(run, p, target, others)

Compile every setup the items load for this process's flags, and each setup that is
a package for `others` too, the other sets of flags the pools' workers have (see
[`precompile_env`](@ref)), wherever there is no valid cache for them. A setup that is
not a package has a single cache file per depot, which a second set of flags would
write over; its workers under other flags compile it for themselves.
"""
function precompile_setups(run::Run, p::Plan, target, others::Vector{Pair{Cmd, Base.CacheFlags}} = Pair{Cmd, Base.CacheFlags}[])
    # An isolated package's setups are not on this process's load path: its workers
    # compile them for themselves.
    setups = any(p.packages.isolated) ?
        sort!(unique!([s for i in 1:nitems(p) if !p.packages.isolated[p.items.package[i]] for s in setups_of(p.items, i)])) :
        p.setups
    isempty(setups) && return nothing
    # A *valid* cache is the question: a cache file left over from another checkout
    # of the same setup would be rebuilt by every worker at once, which is the whole
    # thing this avoids.
    stale = Tuple{Base.PkgId, Pair{Cmd, Base.CacheFlags}}[]
    for name in setups
        pkg = Base.identify_package(String(name))
        if pkg === nothing
            throw(
                ConfigError(
                    "test setup module `$name` is not loadable from " *
                        "$(joinpath(target.testdir, TESTSETUPS_DIR))"
                )
            )
        end
        for config in (pkg.uuid === nothing ? [`` => Base.CacheFlags()] : [`` => Base.CacheFlags(); others])
            has_fresh_cache(pkg, last(config)) || push!(stale, (pkg, config))
        end
    end
    isempty(stale) && return nothing
    say(run, "precompiling ", join(unique(pkg.name for (pkg, _) in stale), ", "))
    for (pkg, (args, flags)) in stale
        # Julia writes why a module would not precompile to the stream it is given,
        # and throws an exception saying only that it failed; both go in the error.
        out = IOBuffer()
        try
            # Given the source path: Julia 1.11's form without it takes no `cacheflags`.
            # Without this process's modules, as in `precompile_self`.
            path = Base.locate_package(pkg)
            path === nothing && throw(ArgumentError("$pkg not found during precompilation"))
            Base.compilecache(pkg, path, out, out, false; flags = args, cacheflags = flags)
        catch e
            is_interrupt(e) && rethrow()
            detail = strip(String(take!(out)))
            throw(
                ConfigError(
                    "test setup module `$(pkg.name)` failed to precompile" *
                        (isempty(args) ? "" : string(" under `", join(args.exec, " "), "`")) * ":\n" *
                        sprint(showerror, e) *
                        (isempty(detail) ? "" : string("\n", detail))
                )
            )
        end
    end
    return nothing
end

# Runtests itself, for each set of flags in `others` it has no cache for. A worker
# loads it, and under flags with no cache compiles it before it can connect, which can
# take longer than a worker is given: 44s on a fast machine. Where the test environment
# lists Runtests, `precompile_env` has done this already. Work brought forward, as
# there: a failure is said, and the workers compile it for themselves.
function precompile_self(run::Run, others::Vector{Pair{Cmd, Base.CacheFlags}})
    pkg = RuntestsWorkers.PKGID
    stale = filter(config -> !has_fresh_cache(pkg, last(config)), others)
    path = Base.locate_package(pkg)
    (isempty(stale) || path === nothing) && return nothing
    say(run, "precompiling Runtests for workers started with ", join(("`$(join(first(c).exec, " "))`" for c in stale), ", "))
    for (args, flags) in stale
        out = IOBuffer()
        try
            # Without this process's modules (`false`): the child would be held to the
            # builds of them loaded here, which are compiled under other flags and so
            # cannot be loaded there. That failure is returned, not thrown.
            r = Base.compilecache(pkg, path, out, out, false; flags = args, cacheflags = flags)
            r isa Exception && throw(r)
        catch e
            is_interrupt(e) && rethrow()
            detail = strip(String(take!(out)))
            @warn "Runtests: could not precompile Runtests under `$(join(args.exec, " "))`; its \
                   workers will compile it themselves$(isempty(detail) ? "" : "\n" * detail)" exception = e
        end
    end
    return nothing
end

# Whether a new process with cache flags `flags` finds a cache of `pkg` it can load.
# Asked as of a fresh session (`ignore_loaded`), as a worker is one: otherwise the
# answer is about the builds this process has loaded, which for other flags is no.
# 1.12's `isprecompiled` takes the flags; from 1.13 it asks for this process's only,
# and the function behind it takes them.
@static if hasmethod(Base.isprecompiled, Tuple{Base.PkgId}, (:flags,))
    has_fresh_cache(pkg::Base.PkgId, flags::Base.CacheFlags) =
        Base.isprecompiled(pkg; flags, ignore_loaded = true)
else
    has_fresh_cache(pkg::Base.PkgId, flags::Base.CacheFlags) =
        Base.compilecache_freshest_path(pkg; flags, ignore_loaded = true, verify_checksums = false) !== nothing
end

### Workers ################################################################

function run_on_workers(run::Run, target)
    # On the run's own thread, as the watchdog is. Interrupting a slot, which an
    # interrupt and a stall both do, schedules its task, and scheduling a task that
    # is running on another thread corrupts the scheduler; a task on this thread
    # cannot be running while the one scheduling it is. A slot's own work is small
    # beside its item's, which runs in the worker: 1200 trivial items on 8 workers
    # take 0.8s. Shielded, so that a cancellation reaches this task alone, which
    # stops the slots itself.
    tasks = shielded() do
        map(run.slots) do slot
            @async begin
                s = $slot
                try
                    run_slot(run, s, target)
                catch e
                    if is_interrupt(e)
                        RuntestsWorkers.forward_interrupt(e)
                        cancel!(run.queues)
                        record_stopped_item!(run, s)
                        rethrow()
                    end
                    # This slot is finished, not the run: its units stay in its
                    # queue for the others to steal, so one bad item does not stop
                    # a suite.
                    @error "Runtests: worker slot $(s.id) stopped; its remaining items are " *
                        "left for the other workers" exception = (e, catch_backtrace())
                end
            end
        end
    end
    @lock run.lock append!(run.tasks, tasks)
    try
        # The garbage the calling session left behind, freed once the workers are
        # starting. Each slot runs until it first waits, which is once its worker's
        # process has been launched; this task runs again after all of them, while
        # those processes boot, which takes longer than the collection. Otherwise
        # that garbage stays resident for the whole run beside the workers, and
        # nothing collects it: a run allocates too little here to trigger it.
        yield()
        GC.gc(true)
        foreach(wait, tasks)
    catch e
        # Ctrl-C lands in whichever task was running, this one included. Stop
        # dispatching and kill the processes rather than wait for them, or an item
        # that sleeps for two minutes holds the interrupt that long. The slot tasks
        # are still waited for: `shutdown!` must not find a slot starting a worker.
        # A slot that caught Ctrl-C and could not hand it on fails with it, which is
        # the interrupt all the same; one the stall watchdog interrupted is not.
        interrupt = is_interrupt(e) ? e :
            e isa TaskFailedException && is_interrupt(e.task.result) && !(@atomic run.stalled) ?
            e.task.result : nothing
        shielded() do
            cancel!(run.queues)
            if interrupt !== nothing
                kill_workers!(run)
                interrupt_slots!(tasks)
            end
            foreach(
                t -> (
                    try
                        wait(t)
                    catch end
                ), tasks
            )
        end
        interrupt === nothing ? rethrow() : throw(interrupt)
    end
    check_finished(run)
    return nothing
end

# Unless the run was stopped, every item ends with an outcome of its own. One that
# did not is a scheduling bug: said here, with the scheduler's cursors, rather than
# reported as an item the run never reached.
function check_finished(run::Run)
    is_cancelled(run.queues) && return nothing
    st = run.statuses
    left = [run.plan.items.name[i] for i in 1:nitems(run.plan) if st.state[i] === UNSEEN || st.state[i] === RUNNING]
    isempty(left) && return nothing
    q = run.queues
    @error "Runtests internal error: $(length(left)) test items have no outcome, though the run was not stopped" items = left head = q.head tail = q.tail from = q.from to = q.to slot_pools = q.pool pending = q.pending unclaimed_units = findall(!, q.claimed)
    return nothing
end

"""
    record_stopped_item!(run, slot)

Record the item this slot was running when the run was stopped: it neither failed
nor finished, and is counted with the items the run never reached.
"""
function record_stopped_item!(run::Run, slot::Slot)
    i = @atomic slot.current
    i == ItemIdx(0) && return nothing
    attempt = max(@atomic(slot.attempt), Int8(1))
    # The slot may have recorded this attempt already, on its way out of a dispatch
    # that failed for a reason of its own; an earlier attempt's outcome is no reason
    # to leave this one unrecorded.
    st = run.statuses
    if !(st.state[i] !== UNSEEN && st.attempt[i] >= attempt)
        if @atomic run.stalled
            record_error!(run, i, slot, attempt, TIMEDOUT, STALLED_NOTE)
        else
            record_error!(run, i, slot, attempt, CANCELLED, "the run was stopped")
        end
    end
    @atomic slot.current = ItemIdx(0)
    return nothing
end

"""
    interrupt_slots!(tasks)

Hand the interrupt to each slot task rather than wait for it to notice. Killing
the workers frees a slot waiting on one and cancelling stops a slot between items,
but a slot starting a worker or held back by the memory guard would wait for
whatever it is waiting on. Called from the run's own thread, where every slot task
is.
"""
function interrupt_slots!(tasks)
    # These interrupts are the run's own. A slot hands back only the user's, and
    # handing these back would cut short the run's wait for its slots.
    @atomic RuntestsWorkers.INTERRUPT_TARGET.task = nothing
    for t in tasks
        (t === current_task() || istaskdone(t)) && continue
        try
            schedule(t, InterruptException(); error = true)
        catch
            # It finished between the two, or was never started: either way there
            # is nothing left in it to interrupt.
        end
    end
    return nothing
end

### Watchdog #################################################################

# What one attempt may spend besides its timeout and its profile's `init` and
# `test_end`: starting a worker, handing the result back, and reporting it.
const STALL_MARGIN_S = 5 * 60
# How often the watchdog looks, at most: the limit is half an hour or more.
const STALL_CHECK_S = 5.0

const STALLED_NOTE = "the run was stopped as hung while this item was running: no test item " *
    "had finished for longer than one attempt at any of them may take"

"""
    STALL_LIMIT_OVERRIDE

What [`stall_limit`](@ref) answers when a test has decided: a real limit is half an
hour or more, and a test cannot wait that long for a run to be declared hung.
"""
const STALL_LIMIT_OVERRIDE = ScopedValue{Union{Nothing, Float64}}(nothing)

"""
    stall_limit(p) -> Float64

The longest a run may go with no test item finishing, in seconds: one attempt at
the item with the largest timeout, on a worker whose profile's `init` and `test_end`
take all they are allowed, or collecting a failed attempt's artifacts for as long
as that may take, whichever is longer, after the longest memory hold, with
`STALL_MARGIN_S` for everything around it. An item that runs past its timeout is
killed, which ends its attempt too, and the end of a collection counts as an item
finishing, so nothing finishing for longer means something that should have stopped
did not.
"""
function stall_limit(p::Plan)
    forced = STALL_LIMIT_OVERRIDE[]
    forced === nothing || return forced
    # Each limit as the item's own package sets it, the largest of them, and never
    # less than a package's own `timeout`.
    item = max(maximum(i -> item_timeout(p, ItemIdx(i)), 1:nitems(p)), maximum(cfg -> cfg.timeout_s, p.packages.cfg))
    package_of(j) = p.packages.cfg[p.profile_package[j]]
    init = maximum(j -> isempty(p.profiles[j].init.args) ? 0 : package_of(j).init_timeout_s, eachindex(p.profiles))
    test_end = maximum(j -> isempty(p.profiles[j].test_end.args) ? 0 : package_of(j).test_end_timeout_s,
                       eachindex(p.profiles))
    artifacts = maximum(cfg -> cfg.artifacts_timeout_s, p.packages.cfg)
    # Summed as floats: three limits of up to 2^31 - 1 seconds each overflow a 32-bit `Int`.
    attempt = max(Float64(item) + init + test_end, Float64(artifacts))
    return attempt + MAX_BACKPRESSURE_SECONDS + STALL_MARGIN_S
end

"""
    start_watchdog(run, limit) -> Timer

Stop the run as hung once no test item has finished for `limit` seconds. Closing the
returned timer ends the watchdog.
"""
function start_watchdog(run::Run, limit::Real)
    every = min(STALL_CHECK_S, limit / 4)
    timer = Timer(every; interval = every)
    # On the run's own thread, so that interrupting the run's task, which a stall does
    # under `workers=0`, happens only while that task waits. Julia throws Ctrl-C into
    # whichever task that thread ran last, and that can be this one: the loop is its
    # own rather than a timer's callback, so the interrupt is caught here and handed
    # on, and the watch goes on. Shielded, as the slots are.
    shielded(() -> @async watch(run, timer, limit))
    return timer
end

function watch(run::Run, timer::Timer, limit::Real)
    while true
        try
            wait(timer)
            (@atomic run.stalled) && continue
            time() - (@atomic run.last_finish) > limit && stall!(run, limit)
        catch e
            e isa EOFError && break   # the timer was closed, so the run is over
            if is_interrupt(e)
                RuntestsWorkers.forward_interrupt(e)
            else
                @error "Runtests: the stall watchdog stopped" exception = (e, catch_backtrace())
                break
            end
        end
    end
    return nothing
end

# Everything the run started comes down: nothing more is handed out, the tasks
# waiting on an item are interrupted (they record it as timed out, with why), the
# workers are killed, and the monitor stops printing.
function stall!(run::Run, limit::Real)
    @atomic run.stalled = true
    say(run, "no test item has finished in ", fmt_seconds(limit),
        ", longer than one attempt at any of them may take; stopping the run as hung")
    cancel!(run.queues)
    interrupt_slots!(@lock run.lock copy(run.tasks))
    kill_workers!(run, "stopped as hung")
    stop_monitor!(run.monitor)
    return nothing
end

function run_slot(run::Run, slot::Slot, target)
    while true
        recycle_worker!(run, slot)
        wait_while_paused(run.queues, slot)
        (@atomic slot.recycle) && continue
        claim = claim!(run.queues, slot.id)
        if claim.kind === :done
            break
        elseif claim.kind === :rebind
            # This slot's own pool is empty and another profile still has work, so
            # the process is replaced instead of the worker cap being exceeded.
            slot.profile = run.plan.pools[claim.pool].profile
            stop_worker!(run, slot)
            continue
        end
        run_unit!(run, slot, claim.unit, target)
    end
    stop_worker!(run, slot)
    return nothing
end

# Between units, never inside one: a chain's later items depend on its process.
function recycle_worker!(run::Run, slot::Slot)
    (; success) = @atomicreplace slot.recycle true => false
    success && stop_worker!(run, slot, "restarted by the memory guard")
    return nothing
end

function ensure_worker!(run::Run, slot::Slot, target, exclusive::Bool)
    slot.worker === nothing || (slot.worker.terminated ? nothing : return slot.worker)
    w = start_worker(run, slot, target, exclusive)
    @atomic slot.worker = w
    return w
end

const WORKER_START_RETRIES = 2

function start_worker(run::Run, slot::Slot, target, exclusive::Bool = false)
    prof = run.plan.profiles[slot.profile]
    last_err = nothing
    for attempt in 1:(WORKER_START_RETRIES + 1)
        began = time()
        w = try
            RuntestsWorkers.Worker(;
                julia_args = run.plan.cfg.coverage ?
                    [prof.julia_args; coverage_flags(run.plan.root, coverage_dir(run.scratch))] : prof.julia_args,
                threads = prof.threads,
                extra_env = worker_env(run.runid, slot.id, worker_project(run, slot.profile), prof;
                                       load_path = worker_load_path(run, slot.profile)),
                dir = worker_dir(run.plan, slot.profile),
                project = worker_project(run, slot.profile),
                redirect_io = stdout,
                # Everything the worker writes: its RUN and DONE records, and under
                # `logs=:eager` whatever its items print.
                redirect_fn = let within = Ref(false)
                    (io, pid, line) -> relay!(run, slot, within, line)
                end,
                on_exit = w -> worker_ended!(run, slot.id, w)
            )
        catch e
            is_interrupt(e) && rethrow()
            last_err = e
            attempt <= WORKER_START_RETRIES && sleep(1)
            continue
        end
        append_event!(run.runstate, EVENT_WORKER_UP, 0, slot.id, w.pid, began - run.t0, time() - run.t0)
        try
            init_worker!(run, slot, w)
            slot.started_at = time()
            note_start!(run.queues, slot.id, slot.started_at - began)
            slot.worker_items = 0
            count_worker_start!(run.monitor)
            print_worker_line(
                run, slot.id, "UP", string(
                    "pid ", w.pid, " · threads ", prof.threads,
                    # Why this process exists: a pool worker runs whatever it is
                    # handed, a sandbox runs one unit and goes away again.
                    exclusive ? " · sandbox" : "",
                    profile_text(run.plan, slot.profile),
                    uses_environments(run.plan) ? string(" · ", isempty(prof.environment) ? "test environment" :
                        string("environment ", relpath_or_path(prof.environment, run.plan.root))) : "",
                    isempty(prof.julia_args) ? "" : string(" · ", join(prof.julia_args, " "))
                )
            )
            return w
        catch e
            # The process is up; it is the `init` expression that failed or hung.
            RuntestsWorkers.terminate!(w, :init_failed)
            wait(w)
            is_interrupt(e) && rethrow()
            if e isa RuntestsWorkers.RemoteException || e isa TimeoutException
                # The expression itself is at fault: another process would only
                # fail the same way. A timeout already names the expression it
                # timed out on, so only a remote error needs saying what failed.
                cancel!(run.queues)
                what = e isa TimeoutException ? sprint(showerror, e) :
                    string(
                        "the `init` expression of profile `", prof.name, "` failed: ",
                        sprint(showerror, e)
                    )
                throw(ErrorException("Runtests: " * what))
            end
            last_err = e   # the worker died while running it: retried like a start failure
            attempt <= WORKER_START_RETRIES && sleep(1)
        end
    end
    # A profile that cannot start is a configuration error, and finding that out
    # once is better than finding it out again on every remaining unit.
    cancel!(run.queues)
    throw(
        ErrorException(
            "Runtests: could not start a worker for profile `$(prof.name)` " *
                "after $(WORKER_START_RETRIES + 1) attempts: " * sprint(showerror, last_err)
        )
    )
end

# Held rather than appended as they arrive: the worker still has that log open, and
# two processes appending to one file keep separate offsets and overwrite each
# other (measured: lines lost and cut in half). Capped, because a process can print
# without limit on its way down.
const MAX_DYING_LINES = 500

function keep_dying_line!(slot::Slot, line::AbstractString)
    length(slot.dying_lines) < MAX_DYING_LINES && push!(slot.dying_lines, String(line))
    return nothing
end

"""
    relay!(run, slot, within, line)

One line of what a worker wrote. Its records of an item starting and finishing
become the item's RUN and DONE lines; anything else is the item talking, between a
RUN and its DONE, or the process itself. `within` follows the worker's own stream,
so it never races with the slot's task. While the process is being put down for a
timeout, the item is already recorded as timed out: a verdict it still manages to
send is dropped, and what it says goes with the item's log.
"""
function relay!(run::Run, slot::Slot, within::Base.RefValue{Bool}, line::AbstractString)
    rec = parse_record(line)
    if !isempty(@atomic slot.dying_log)
        rec === nothing && keep_dying_line!(slot, line)
        return nothing
    end
    if rec !== nothing
        within[] = rec.how === nothing
        return printline(run, item_line(run, slot.id, rec.i, rec.attempt, rec.how))
    end
    return printline(run, string(within[] ? MARK_ITEM : MARK_WORKER, " ", rpad(string("w", slot.id), SLOT_LABEL_WIDTH[]), FIELD, line))
end

# An item's RUN or DONE line, drawn from what this run knows about the item.
item_line(run::Run, slot_id, i::Integer, attempt::Integer, how) = item_line(
    slot_id, i, nitems(run.plan), run.names[i], run.name_width, attempt,
    attempts_for(run.plan, run.plan.items.unit[i]), something(how, run.plan.locations[i]);
    package = is_combined(run.plan) ? run.plan.packages.name[run.plan.items.package[i]] : "",
    package_width = maximum(textwidth, run.plan.packages.name)
)

"""
    flush_dying_log!(slot)

Put what the worker said while being taken down into the log of the item it was
running. Called once the process is gone and its relay task joined, so this is the
file's only writer.
"""
function flush_dying_log!(slot::Slot)
    path = slot.dying_log
    @atomic slot.dying_log = ""
    if !isempty(path) && !isempty(slot.dying_lines)
        try
            open(path, "a") do io
                for l in slot.dying_lines
                    println(io, l)
                end
            end
        catch e
            is_interrupt(e) && rethrow()
            # The log is a convenience; losing a dying process's backtrace is not
            # a reason to disturb the run that is still going.
        end
    end
    empty!(slot.dying_lines)
    return nothing
end

# A worker's environment beyond the coordinator's own: the run and slot it belongs
# to, the load path as it is now (the setups directory included), the project its
# items resolve against, and the profile's own variables. The project is stated
# rather than inherited: a `JULIA_PROJECT` the caller happened to have set would
# otherwise win over the test environment this run just built.
function worker_env(run_id, slot_id, project, prof::Profile;
                    load_path = isempty(prof.environment) ? LOAD_PATH : stacked_load_path(LOAD_PATH, Base.active_project()))
    env = ["RUNTESTS_RUN_ID" => string(run_id), "RUNTESTS_WORKER" => string(slot_id), "JULIA_LOAD_PATH" => join(load_path, PATHSEP)]
    project === nothing || push!(env, "JULIA_PROJECT" => project)
    return append!(env, prof.env)
end

# The project the workers of profile `j` run in: the profile's own (`profile_projects!`),
# or that of its package's items.
worker_project(run::Run, j::Integer) =
    get(run.profile_projects, ProfileIdx(j), run.package_projects[run.plan.profile_package[j]])

# The load path of the workers of profile `j`: this process's, which holds the setups
# of every package that shares workers; for an isolated package, with its own setups
# in their place. In an environment directory, stacked over its package's project.
function worker_load_path(run::Run, j::Integer)
    p = run.plan
    k = p.profile_package[j]
    load_path = copy(LOAD_PATH)
    if p.packages.isolated[k]
        shared = Set(joinpath(r, "test", TESTSETUPS_DIR) for r in p.packages.root)
        filter!(d -> !(d in shared), load_path)
        own = joinpath(p.packages.root[k], "test", TESTSETUPS_DIR)
        isdir(own) && push!(load_path, own)
    end
    isempty(p.profiles[j].environment) && return load_path
    return stacked_load_path(load_path, run.package_projects[k])
end

# Where the workers of profile `j` start: where its `init` runs, for a profile with
# one (`init_dir`), the package's root for an isolated package, and the run's root
# otherwise.
function worker_dir(p::Plan, j::Integer)
    k = p.profile_package[j]
    isempty(p.profiles[j].init.args) || return init_dir(p.profiles[j], p.packages.root[k])
    return p.packages.isolated[k] ? p.packages.root[k] : p.root
end

# The load path of an item in an environment directory: that environment,
# `@`, over the test environment `test_env`, as `Pkg.test` stacks its sandbox over the
# active project. The worker loads RuntestsWorkers through the test environment's
# manifest, and the environment's own packages come first.
function stacked_load_path(load_path::Vector{String}, test_env::Union{Nothing, String})
    out = copy(load_path)
    (test_env === nothing || test_env in out || dirname(test_env) in out) && return out
    at = findfirst(==("@"), out)
    insert!(out, at === nothing ? 1 : at + 1, test_env)
    return out
end

# Every worker's end is recorded once, by the task that sees its process exit,
# whichever way it went: closed by the run, killed, or dead on its own.
function worker_ended!(run::Run, slot::Integer, w::RuntestsWorkers.Worker)
    t = time() - run.t0
    p = w.process
    append_event!(run.runstate, EVENT_WORKER_DOWN, worker_end_code(w.ended_by), slot, w.pid, t, t;
        exitcode = p.exitcode, signal = p.termsignal)
    return nothing
end

function init_worker!(run::Run, slot::Slot, w::RuntestsWorkers.Worker)
    p = run.plan
    prof = p.profiles[slot.profile]
    isempty(prof.init.args) && return nothing
    # Under the `init_timeout` of the package that declares the profile.
    timeout = p.packages.cfg[p.profile_package[slot.profile]].init_timeout_s
    fut = RuntestsWorkers.remote_eval(w, Expr(:block, prof.init.args...))
    fetch_within(
        fut, timeout,
        TimeoutException(timeout, "the `init` expression of profile `$(prof.name)`", "", "init_timeout")
    )
    return nothing
end

function stop_worker!(run::Run, slot::Slot, why::AbstractString = "")
    w = slot.worker
    w === nothing && return nothing
    @atomic slot.worker = nothing
    ran = slot.worker_items
    alive = slot.started_at == 0.0 ? 0.0 : time() - slot.started_at
    try
        close(w)
    catch e
        is_interrupt(e) && rethrow()
        @error "Runtests: could not stop worker $(w.pid)" exception = (e, catch_backtrace())
    end
    p = w.process
    status = !process_exited(p) ? " · still running" :
        p.exitcode == 0 && p.termsignal == 0 ? "" : string(" · ", RuntestsWorkers.exit_description(p))
    print_worker_line(
        run, slot.id, "EXIT", string(
            "pid ", w.pid, " · ", plural(ran, "item"), " · ", fmt_seconds(alive), status,
            isempty(why) ? "" : string(" · ", why)
        )
    )
    return nothing
end

# How a worker that was not asked to stop came to an end: its exit status, and
# what memory looked like when it was last seen, which is most of what an OOM kill
# leaves behind.
function died_how(run::Run, slot::Slot, w::RuntestsWorkers.Worker)
    how = RuntestsWorkers.exit_description(w.process)
    by = w.ended_by
    alone = by === :connection_lost || by === :process_exit
    if alone && w.process.termsignal == 9
        how *= ", which nothing in this run sent: usually the out-of-memory killer"
    elseif !alone
        how *= string(", stopped after ", replace(String(by), '_' => ' '))
    end
    return string(how, memory_note(run.monitor, slot.id, w.pid))
end

"""
    LIVE_RUN

The run this process is part-way through, or nothing. A process runs one at a
time, and [`report_unfinished_run`](@ref) is the only reader.
"""
const LIVE_RUN = Ref{Any}(nothing)

# Registered when a run reaches its test phase; a process that never gets that far
# has nothing to say at exit. Exit hooks run newest first, so registering the one
# that kills leftover workers before it puts the report ahead of that: the report
# stops the workers itself, and says why.
const ensure_exit_report = OncePerProcess{Nothing}() do
    RuntestsWorkers.ensure_cleanup_hook()
    atexit(report_unfinished_run)
    nothing
end

"""
    report_unfinished_run()

Close the books on a run whose process is going down without unwinding. Julia 1.12
delivers an interrupt to whichever task its first thread is running, which between
items is a finished one that cannot catch it, so no `finally` runs; a test item
calling `exit` ends the same way. Best effort: the printer is taken with `trylock`,
so a line of output cannot hang the exit.

Nothing here waits on the event loop. A script exiting on Ctrl-C under Julia 1.12 runs
its exit hooks from wherever its first thread was, and a wait there can last forever.
So the workers are signalled and their connections left to the exit, the run state's
beat is left to its timer, and the closing block is written straight to the
descriptor (see [`write_now`](@ref)).
"""
function report_unfinished_run()
    run = LIVE_RUN[]
    run === nothing && return nothing
    LIVE_RUN[] = nothing
    try
        # First, before anything here can let a slot run: one that found its worker
        # dead would report a death nothing explains, and blame the OOM killer.
        # Taken from its slot and killed here, the worker is one the run stopped.
        cancel!(run.queues)
        for slot in run.slots
            w = slot.worker
            w === nothing && continue
            @atomic slot.worker = nothing
            RuntestsWorkers.kill!(w; exiting = true)
        end
        # Told to stop, not waited for: `stop_monitor!` takes the printer and waits
        # for the monitor's task, and a task frozen by the exit holding either
        # would hang it.
        run.monitor === nothing || (@atomic run.monitor.stop = true)
        # Not called from here: `on_item` is the caller's code, which may wait on the
        # event loop, or on its lock held by a task the exit froze.
        @atomic run.on_item = nothing
        # Nothing unwound, so the slots never recorded what they were holding.
        # They are frozen where they were, and each still names its item.
        foreach(slot -> record_stopped_item!(run, slot), run.slots)
        finish_run_state!(run.runstate; cancelled = true, exiting = true)
        export_run!(run)
        if trylock(run.printer)
            try
                # In one write, the status line erased by it.
                m = run.monitor
                text = conclusion_text(run, :interrupted)
                write_now(stdout, string(m !== nothing && m.tty ? "\r\e[2K" : "", text, endswith(text, "\n") ? "" : "\n"))
            finally
                unlock(run.printer)
            end
        end
    catch
    end
    return nothing
end

"""
    kill_workers!(run)

Kill every worker this run has, now: the orderly teardown takes most of a minute
across a pool, a long time to hold a terminal someone has asked for back. Nothing
is reported for what they were running. `shutdown!` waits for them to be gone.
"""
function kill_workers!(run::Run, why::AbstractString = "interrupted")
    live = 0
    for slot in run.slots
        w = slot.worker
        w === nothing && continue
        @lock run.lock push!(run.killed, w)
        @atomic slot.worker = nothing
        live += 1
        RuntestsWorkers.kill!(w)
    end
    live == 0 || say(run, why, "; killed ", plural(live, "worker"))
    return nothing
end

function shutdown!(run::Run)
    for slot in run.slots
        stop_worker!(run, slot)
    end
    # A killed worker is the run's until its process is reaped and the tasks relaying
    # it have ended, and `kill!` returns before either. The run ends with nothing it
    # started still going, and with how each worker ended in its run state.
    foreach(wait, @lock run.lock copy(run.killed))
    return nothing
end

# The pieces rather than the sentence: one of these is built for every dispatch and
# almost none of them is ever shown. `setting` is what set the limit, so a report
# says which knob to turn.
struct TimeoutException <: Exception
    seconds::Int
    kind::String
    subject::String
    setting::String
end

TimeoutException(seconds::Integer, kind::AbstractString, subject::AbstractString, setting::AbstractString) =
    TimeoutException(Int(seconds), String(kind), String(subject), String(setting))

Base.showerror(io::IO, e::TimeoutException) = print(
    io, e.kind, isempty(e.subject) ? "" : string(" ", repr(e.subject)),
    " timed out after ", e.seconds, "s (", e.setting, ")"
)

# An item's own keyword wins over the run default, the same way `timeout` and
# `failfast` do. A chain is retried as a unit, so the most demanding member sets
# the number of attempts.
attempts_for(p::Plan, u::UnitIdx) = 1 + maximum(p.units.span[u]) do i
    p.items.retries[i] == USE_RUN_DEFAULT ? item_cfg(p, i).retries : Int(p.items.retries[i])
end

# The attempt policy, the same wherever the unit runs: on a pool worker, on a
# sandbox worker, or in this process under `workers=0`.
function run_unit!(run::Run, slot::Slot, u::UnitIdx, target)
    p = run.plan
    max_attempts = attempts_for(p, u)
    for attempt in 1:max_attempts
        broken = run_unit_once!(run, slot, u, target, Int8(attempt), max_attempts)
        note_attempt!(run, slot, u)
        has_non_pass(run, u) || return nothing
        if attempt == max_attempts
            # Out of attempts. A chain cut short by a dead worker has lost the state
            # its remaining items relied on, so they are recorded as broken.
            broken && mark_remaining_broken!(run, u, Int8(attempt))
            # Failfast waits for the last attempt: stopping the run under a retry
            # would record the failure as a cancellation.
            p.cfg.failfast && cancel!(run.queues) === false &&
                print_failfast(run, first(i for i in p.units.span[u] if is_non_pass(run.statuses.state[i])))
            return nothing
        end
        # A run stopped meanwhile, by another item's failfast or a profile whose
        # `init` failed, retries nothing: the attempt's verdict is the item's.
        is_cancelled(run.queues) && return nothing
        # Retrying a chain restarts it from its first item: re-running one item of
        # a sequence that mutates state does not mean anything.
        reset_unit!(run, u)
    end
    return nothing
end

# What one attempt at unit `u` on `slot` measured, for the scheduler: how long each
# item took against its recorded duration, and its compile time, as a fresh process's
# first item or a later one. Only an attempt whose items all ran and timed
# themselves counts: an outcome the run decided took as long as it was allowed.
function note_attempt!(run::Run, slot::Slot, u::UnitIdx)
    st = run.statuses
    span = run.plan.units.span[u]
    any(i -> st.synthetic[i] || st.state[i] === UNSEEN || st.state[i] === CANCELLED, span) && return nothing
    recorded = run.plan.items.est_s
    q = run.queues
    @lock q.lock begin
        ps = q.stats[q.pool[slot.id]]
        for i in span
            took = Float64(st.elapsed[i])
            ps.items += 1
            ps.took_s += took
            if recorded[i] > 0
                ps.estimated_s += recorded[i]
                ps.estimated_took_s += took
            end
            if st.seq[i] == 1
                ps.cold += 1
                ps.cold_compile_s += st.compile[i]
            elseif st.seq[i] > 1
                ps.warm += 1
                ps.warm_compile_s += st.compile[i]
            end
        end
    end
    return nothing
end

has_non_pass(run::Run, u::UnitIdx) =
    any(i -> is_non_pass(run.statuses.state[i]), run.plan.units.span[u])

function reset_unit!(run::Run, u::UnitIdx)
    for i in run.plan.units.span[u]
        set_state!(run, i, UNSEEN)
    end
    return nothing
end

# Every write of an item's state goes through here, so that `run.nonpass`, which
# the status line reads from other threads, is always the count of the states.
function set_state!(run::Run, i::Integer, state::ItemState)
    st = run.statuses
    delta = Int(is_non_pass(state)) - Int(is_non_pass(st.state[i]))
    st.state[i] = state
    delta == 0 || @atomic run.nonpass += delta
    return nothing
end

# One attempt at every item of a unit: on the slot's worker, or here when there is
# no pool and the unit did not ask for a process of its own. `true` when a worker
# was lost part way through, which leaves the rest of the unit unable to run.
function run_unit_once!(run::Run, slot::Slot, u::UnitIdx, target, attempt::Int8, max_attempts::Int)
    p = run.plan
    exclusive = p.units.exclusive[u]
    attempt_item! = single_process(p) && !needs_worker(p, u) ? attempt_here! : attempt_on_worker!
    # A sandbox is a process to itself, and the slot may arrive holding a worker
    # that has already run other items.
    exclusive && slot.worker_items > 0 && stop_worker!(run, slot)
    for i in p.units.span[u]
        # Every item is unseen when the loop reaches it: `reset_unit!` puts them
        # back before each retry.
        is_cancelled(run.queues) && (set_state!(run, i, CANCELLED); continue)
        attempt_item!(run, slot, i, target, attempt, max_attempts) || return true
    end
    exclusive && stop_worker!(run, slot)
    return false
end

# When and in which process an attempt began, marked running before it is sent:
# if this process is killed, the file says which item was in flight, which is the
# truth and usually the answer. An outcome the run decides is timed from here.
function began!(run::Run, i::ItemIdx, slot::SlotIdx, attempt::Int8, pid::Integer)
    st = run.statuses
    now = time()
    st.start[i] = Float32(now - run.t0)
    st.pid[i] = Int32(pid)
    pid == 0 || @lock run.lock push!(run.item_pids, Int32(pid))
    pid == 0 || write_status!(run.runstate, i, RUNNING, attempt, slot; start_off = st.start[i], pid)
    run.events === nothing || event_item_started(run, i, attempt, slot, pid)
    tell_on_item(run, i, :started, RUNNING, attempt, slot, now, 0.0, RuntestsWorkers.PerfStats(), false)
    return nothing
end

# One attempt at item `i` on the slot's worker, starting one when it has none.
# `false` when the worker is gone and the rest of its unit cannot be trusted.
function attempt_on_worker!(run::Run, slot::Slot, i::ItemIdx, target, attempt::Int8, max_attempts::Int)
    p = run.plan
    w = try
        ensure_worker!(run, slot, target, p.units.exclusive[p.items.unit[i]])
    catch e
        is_interrupt(e) && rethrow()
        run.statuses.seq[i] = 0
        began!(run, i, slot.id, attempt, 0)
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e))
        return false
    end
    spec = item_spec(run, i, slot, attempt)
    run.statuses.seq[i] = Int16(min(slot.worker_items + 1, typemax(Int16)))
    began!(run, i, slot.id, attempt, w.pid)
    @atomic slot.attempt = attempt
    @atomic slot.current = i
    result = try
        dispatch(run, w, spec, item_timeout(p, i), slot)
    catch e
        # An interrupt leaves it set: the slot is unwinding, and what it was
        # running is the one thing `record_stopped_item!` needs from it. So does
        # one that comes while the failure is handled, which waits for the worker
        # to exit: the item is the slot's until its outcome is recorded.
        is_interrupt(e) && rethrow()
        survived = handle_dispatch_failure!(run, slot, i, attempt, e, max_attempts)
        @atomic slot.current = ItemIdx(0)
        return survived
    end
    @atomic slot.current = ItemIdx(0)
    slot.worker_items += 1
    record_result!(run, i, slot, attempt, result, max_attempts)
    # Then the evidence, before a retry, the chain's next item or a sandbox's end.
    return finish_attempt!(run, slot, i, attempt, result, w)
end

# One attempt at item `i` in this process. There is no second process to kill, so
# nothing times out, and no worker to lose, so the unit always goes on.
function attempt_here!(run::Run, slot::Slot, i::ItemIdx, _, attempt::Int8, max_attempts::Int)
    spec = item_spec(run, i, slot, attempt)
    began!(run, i, slot.id, attempt, getpid())
    printline(run, item_line(run, nothing, i, attempt, nothing))
    res = try
        r = run_item(spec)
        printline(run, item_line(run, nothing, i, attempt, outcome(r)))
        with_test_end(r, spec, item_profile(run.plan, i).test_end)
    catch e
        if is_interrupt(e)
            (@atomic run.stalled) && record_error!(run, i, slot, attempt, TIMEDOUT, STALLED_NOTE)
            rethrow()
        end
        record_error!(
            run, i, slot, attempt, ERRORED,
            string(sprint(showerror, e), " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues), "in this process"))
        )
        return true
    end
    record_result!(run, i, slot, attempt, res, max_attempts)
    finish_attempt!(run, slot, i, attempt, res, nothing)
    return true
end

# The item, then its profile's `test_end`: two requests to one process, each
# against its own limit, so a `test_end` that hangs is not reported as an item that
# hung. Most profiles have no `test_end` and send one request.
function dispatch(run::Run, w::RuntestsWorkers.Worker, spec::ItemSpec, timeout::Int, slot::Slot)
    fut = RuntestsWorkers.remote_run(w, spec)
    res = fetch_within(fut, timeout, TimeoutException(timeout, "test item", spec.name, timeout_setting(run.plan, spec.index)))::ItemResult
    prof = item_profile(run.plan, spec.index)
    test_end = prof.test_end
    (isempty(test_end.args) || res.state === SKIPPED) && return res
    # Under the `test_end_timeout` of the item's own package.
    seconds = item_cfg(run.plan, spec.index).test_end_timeout_s
    endfut = RuntestsWorkers.remote_end(w, spec, test_end)
    endres = try
        fetch_within(
            endfut, seconds,
            TimeoutException(seconds, "the `test_end` expression of profile `$(prof.name)`", "", "test_end_timeout")
        )::ItemResult
    catch e
        # The item ran; it is the profile's own code that did not come back. Saying
        # "the worker running this item died" here would point at the wrong code.
        (e isa TimeoutException || is_interrupt(e)) && rethrow()
        throw(TestEndFailure(prof.name, e))
    end
    return merge_test_end(res, endres)
end

struct TestEndFailure <: Exception
    profile::Symbol
    cause::Any
end

Base.showerror(io::IO, e::TestEndFailure) = print(
    io, "the `test_end` expression of profile `", e.profile, "` did not complete: ",
    sprint(showerror, e.cause)
)

# A `test_end` that recorded nothing leaves the item's result alone; one that did
# becomes a testset nested in the item's. A testset keeps passes as a count, not in
# its results. The item's timings stay the item's.
function merge_test_end(res::ItemResult, endres::ItemResult)
    isempty(endres.testset.results) && Test.get_test_counts(endres.testset).passes == 0 && return res
    push!(res.testset.results, endres.testset)
    state = severity(endres.state) > severity(res.state) ? endres.state : res.state
    return ItemResult(res.index, state, res.testset, res.stats, res.artifacts)
end

severity(s::ItemState) = s === ERRORED ? 2 : s === FAILED ? 1 : 0

# `fetch(fut)`, or throw `on_timeout` once `seconds` pass without a reply. The timer
# closes the future's own channel, so there is no second channel or task per
# dispatch. A reply that arrived first is buffered, and `fetch` returns a buffered
# value even from a closed channel, so a reply racing its deadline wins.
function fetch_within(fut, seconds::Real, on_timeout::Exception)
    timer = RuntestsWorkers.after(seconds) do
        close(fut.value, on_timeout)
    end
    try
        return fetch(fut)
    finally
        close(timer)
    end
end

# Whether the run's stop recorded the slot's item while the slot waited for its
# worker: the exit hook records what each slot holds, and the run has said how it
# ended by the time the slot goes on.
stopped_meanwhile(slot::Slot) = @atomic(slot.current) == ItemIdx(0)

# Whether the worker survived: `false` when it is gone and the rest of the unit
# cannot be trusted, `true` when the item failed on a process still fit to use.
function handle_dispatch_failure!(
        run::Run, slot::Slot, i::ItemIdx, attempt::Int8, e,
        max_attempts::Int
    )
    w = slot.worker
    item = run.plan.items.name[i]
    if e isa TimeoutException
        ended = time()   # the item held its worker until here; inspecting it is ours
        if w !== nothing
            print_worker_line(run, slot.id, "KILL", string("pid ", w.pid, " · ", sprint(showerror, e)))
            RuntestsWorkers.inspect!(w)   # where was it: every thread's and task's backtrace, into the item's log
            # `wait` below joins the task relaying this worker's output, so
            # everything the process says on its way down has been filed by the
            # time the item is reported.
            @atomic slot.dying_log = item_log(run, i, attempt)
            RuntestsWorkers.terminate!(w, :timeout)
            wait(w)   # a replacement must not overlap the process it replaces
            flush_dying_log!(slot)
        end
        @atomic slot.worker = nothing
        stopped_meanwhile(slot) && return false
        artifacts = evidence_after_loss!(run, i, attempt, sprint(showerror, e))
        record_error!(
            run, i, slot, attempt, TIMEDOUT,
            string(sprint(showerror, e), " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues), "on a new worker"));
            ended, artifacts
        )
        return false
    elseif w !== nothing && !w.terminated
        # The request failed but the process is fine: a result that would not
        # serialize, a `skip` expression that threw. The worker keeps everything
        # it has compiled, and the item is an ordinary error.
        artifacts = evidence_after_loss!(run, i, attempt, "its result could not be read")
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e); artifacts)
        return true
    else
        ended = time()
        how = ""
        if w !== nothing
            wait(w)   # its exit status is known once its process is reaped
            if stopped_meanwhile(slot)
                @atomic slot.worker = nothing
                return false
            end
            how = died_how(run, slot, w)
            print_worker_line(run, slot.id, "LOST", string("pid ", w.pid, " · died while running ", repr(item), ": ", how))
        end
        @atomic slot.worker = nothing
        # A stopped run took this worker away itself: the item neither failed nor
        # ran, and is counted with the ones that never started.
        if is_cancelled(run.queues)
            record_error!(run, i, slot, attempt, CANCELLED, "the run was stopped"; ended)
        else
            what = e isa RuntestsWorkers.WorkerTerminatedException ?
                string("the worker running this item died: ", how) : sprint(showerror, e)
            artifacts = evidence_after_loss!(run, i, attempt, what)
            record_error!(
                run, i, slot, attempt, ERRORED,
                string(what, " · ", retry_note(attempt, max_attempts, false, "on a new worker"));
                ended, artifacts
            )
        end
        return false
    end
end

# The profile of item `i`'s own unit. A pool's workers start with the configuration
# of one of its profiles, which every profile of the pool shares; what differs between
# them, `test_end` and the name an item sees, is the item's own.
item_profile(p::Plan, i::Integer) = p.profiles[p.units.profile[p.items.unit[i]]]

function item_spec(run::Run, i::ItemIdx, slot::Slot, attempt::Int8)
    p = run.plan
    # The directory is this run's own and (item, attempt) is unique within it, so
    # nothing is there to clear first.
    logpath = p.cfg.logs === :eager ? "" : item_log(run, i, attempt)
    return ItemSpec(
        i, p.items.name[i], p.files[p.items.fileidx[i]], p.items.line[i],
        p.items.code[i], p.items.skip[i],
        p.items.failfast[i] == -1 ? item_cfg(p, i).item_failfast : p.items.failfast[i] == 1,
        is_combined(p) ? p.packages.name[p.items.package[i]] : run.project_name,
        item_profile(p, i).name, attempt, p.cfg.full_stacktraces, logpath,
        item_seed(p.items.seed[i], p.items.name[i]), attempt_artifacts(run, i, attempt), item_root(p, i)
    )
end

# The directory item `i` runs in: its package's root, or "" where the worker already
# is, in the root of the run's one package.
item_root(p::Plan, i::Integer) = (r = p.packages.root[p.items.package[i]]) == p.root ? "" : r

# The run's seed and the item's name, mixed so that each item draws its own numbers
# whatever ran before it in the same process. CRC32c rather than `hash`, which may
# change between Julia versions and would make a recorded seed mean something else.
item_seed(seed::UInt64, name::AbstractString) = seed ⊻ (UInt64(crc32c(name)) * 0x9e3779b97f4a7c15)

item_timeout(p::Plan, i::ItemIdx) =
    p.items.timeout_s[i] == USE_RUN_DEFAULT ? item_cfg(p, i).timeout_s : Int(p.items.timeout_s[i])

timeout_setting(p::Plan, i::Integer) =
    p.items.timeout_s[i] == USE_RUN_DEFAULT ? "the run's timeout" : string("its own timeout=", p.items.timeout_s[i])

### Recording ##############################################################

# What happens next, said where the failure is reported: a dead worker is only
# half the story if the reader cannot tell whether the item gets another go, and
# where: `next` is where that go runs, "on a new worker", "on the same worker" or
# "in this process".
function retry_note(attempt::Integer, max_attempts::Integer, cancelled::Bool, next::AbstractString)
    # A stopped run retries nothing, whatever the item asked for. Saying it will is
    # a promise the next line of the log breaks.
    cancelled && return "the run was stopped"
    retries = max_attempts - 1
    retries <= 0 && return "not retried (retries=0)"
    attempt <= retries && return string("retrying ", next, " (retry ", attempt, " of ", retries, ")")
    return string("no retries left (", retries, " of ", retries, " used)")
end

"""
    record!(run, i, slot, attempt, state, testset, stats, synthetic, note)

Everything that follows from one attempt's outcome, in one place: the item's
status in memory and on disk, the count of finished items, and the item's report.
`synthetic` says the run decided the outcome rather than the item — a timeout, a
dead worker, a chain cut short — and `testset` then holds a single error saying so.
"""
function record!(
        run::Run, i::ItemIdx, slot::SlotIdx, attempt::Int8, state::ItemState,
        testset::Test.AbstractTestSet, stats::RuntestsWorkers.PerfStats, synthetic::Bool,
        note::AbstractString; ended::Float64 = time(), artifacts::UInt8 = 0x00
    )
    (state === UNSEEN || state === RUNNING) && error("Runtests internal error: item $i recorded as $state")
    st = run.statuses
    set_state!(run, i, state)
    st.synthetic[i] = synthetic
    st.artifacts[i] = artifacts
    st.attempt[i] = attempt
    st.slot[i] = slot
    # An outcome the item reported took what the item measured; one the run decided
    # took as long as the item held its worker.
    elapsed = synthetic ? max(0.0, ended - run.t0 - st.start[i]) : stats.elapsed_ns / 1.0e9
    st.elapsed[i] = elapsed
    st.compile[i] = stats.compile_ns / 1.0e9
    st.testsets[i] = testset
    # What the run prints of a failure, kept beside the item's output for whoever
    # reads the run state later; a cancel or a skip has nothing of its own to say.
    is_non_pass(state) && state !== CANCELLED && write_failure_report(run, i, attempt, testset)
    write_status!(
        run.runstate, i, state, attempt, slot;
        start_off = st.start[i], elapsed = st.elapsed[i], compile = st.compile[i],
        recompile = stats.recompile_ns / 1.0e9, alloc_mb = stats.bytes / 2^20,
        peak_rss_mb = stats.maxrss / 2^20, pid = st.pid[i]
    )
    append_event!(run.runstate, EVENT_ATTEMPT, UInt8(state), slot, st.pid[i], st.start[i], ended - run.t0;
                  item = i, attempt, seq = st.seq[i])
    @atomic run.last_finish = time()
    report_item!(run, i, state, count_done!(run, i), note)
    run.events === nothing || event_item_finished(run, i, state, attempt, slot, note)
    tell_on_item(run, i, :finished, state, attempt, slot, ended, elapsed, stats, !synthetic)
    return nothing
end

"""
    ItemEvent

What a function given as `runtests(on_item = f)` is called with, in this process:
once as an attempt at a test item starts, `kind = :started`, and once as it ends,
`kind = :finished`. A retry is another attempt, with a call of each.

It says which item it is (`name`, `file`, `line`, `attempt`, and the `package` whose
suite holds it, with its `root`, which tell apart two items of one name in a run of
several packages), where it ran (`worker`,
numbered as the run's lines number them, `w1`, and `pid`, its process), when it
started or ended (`time`, as `time()` gives it), and how it went (`state`: `:running`
as it starts, and then `:passed`, `:failed`, `:errored`, `:timedout`, `:skipped`,
`:broken_chain` or `:cancelled`). `pid` is 0 when no process ran the attempt: the run
could not start a worker for it, or it is an item of a chain whose worker died before
it ran, which has `worker` 0 as well.

As it ends, it says what the attempt cost: `elapsed`, `cpu` (user and system time),
`compile`, `recompile` (of `compile`) and `gc` in seconds, `allocated` in bytes,
`allocations`, how many there were, and `maxrss`, the largest its process has been
resident so far, in bytes. Every figure
but `elapsed` is the whole process's, which runs one item at a time: its worker's,
or with `workers = 0` this process's. `measured` says the item measured them itself.
It is `false` as an attempt starts, and as it ends when the run decided the outcome,
as for a timeout, a lost worker, a chain cut short or a stopped run: the figures are
then 0, and `elapsed` is how long the attempt held its worker.
"""
struct ItemEvent
    kind::Symbol
    name::String
    file::String
    line::Int
    attempt::Int
    worker::Int
    pid::Int
    time::Float64
    state::Symbol
    measured::Bool
    elapsed::Float64
    cpu::Float64
    compile::Float64
    recompile::Float64
    gc::Float64
    # As wide as the worker's counters, which pass 2^31 on 32-bit platforms too: an
    # item's allocations add up, and a 32-bit process can hold over 2 GiB.
    allocated::Int64
    allocations::Int64
    maxrss::Int64
    package::String
    root::String
end

# The caller's `on_item` with one attempt's event, which is built only when there is
# a function to call. A call that throws is reported and is the last: the function
# is the caller's code, and a run goes on whatever its observer does.
function tell_on_item(
        run::Run, i::ItemIdx, kind::Symbol, state::ItemState, attempt::Int8, slot::Integer, at::Float64,
        elapsed::Float64, stats::RuntestsWorkers.PerfStats, measured::Bool
    )
    (@atomic run.on_item) === nothing && return nothing
    p = run.plan
    event = ItemEvent(
        kind, p.items.name[i], p.files[p.items.fileidx[i]], p.items.line[i], attempt, slot, run.statuses.pid[i],
        at, Symbol(state_name(state)), measured, elapsed, stats.cpu_ns / 1.0e9, stats.compile_ns / 1.0e9,
        stats.recompile_ns / 1.0e9, stats.gc_ns / 1.0e9, stats.bytes, stats.allocs, stats.maxrss,
        p.packages.name[p.items.package[i]], p.packages.root[p.items.package[i]]
    )
    @lock run.on_item_lock begin
        # Read again: a call another task made while this one waited may have failed.
        f = @atomic run.on_item
        f === nothing && return nothing
        try
            f(event)
        catch e
            is_interrupt(e) && rethrow()
            @atomic run.on_item = nothing
            @error "Runtests: `on_item` threw for $(repr(event.name)), and is not called again in this run; the tests carry on" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

function record_result!(
        run::Run, i::ItemIdx, slot::Slot, attempt::Int8, res::ItemResult,
        max_attempts::Int = 1
    )
    # Only worth saying when there is a policy to state: a plain failure with no
    # retries configured explains itself.
    note = (is_non_pass(res.state) && max_attempts > 1) ?
        retry_note(attempt, max_attempts, is_cancelled(run.queues), next_attempt_where(run.plan, run.plan.items.unit[i])) : ""
    record!(run, i, slot.id, attempt, res.state, res.testset, res.stats, false, note; artifacts = res.artifacts)
    return nothing
end

# Where a unit's next attempt runs after one that failed with its process intact: a
# sandbox's process runs one unit and goes, while a pool worker, and this process,
# carry on with the next attempt.
next_attempt_where(p::Plan, u::UnitIdx) =
    p.units.exclusive[u] ? "on a new worker" :
    single_process(p) && !needs_worker(p, u) ? "in this process" : "on the same worker"

record_error!(run::Run, i::ItemIdx, slot::Slot, attempt::Int8, state::ItemState, msg::AbstractString;
              ended::Float64 = time(), artifacts::UInt8 = 0x00) =
    record!(run, i, slot.id, attempt, state, error_testset(run, i, msg, ended), RuntestsWorkers.PerfStats(), true, msg;
            ended, artifacts)

# The testset of an outcome the run decided: one error saying why, at the item's
# own line, so the summary and the verdict count it like any other error.
function error_testset(run::Run, i::ItemIdx, msg::AbstractString, ended::Float64)
    p = run.plan
    ts = started_testset(p.items.name[i]; verbose = false, at = run.t0 + run.statuses.start[i])
    finish_quietly(add_error!(ts, msg, source_of(p, i)))
    finished_at!(ts, ended)
    return ts
end

# A retried item is finished once, however many attempts it took.
function count_done!(run::Run, i::ItemIdx)
    run.statuses.counted[i] && return @atomic run.ndone
    run.statuses.counted[i] = true
    n = @atomic run.ndone += 1
    n <= nitems(run.plan) || error("Runtests internal error: $n items counted as finished, of $(nitems(run.plan))")
    return n
end

function finish_quietly(ts::Test.AbstractTestSet)
    without_enclosing_testset() do
        with_testset_printing(false) do
            try
                Test.finish(ts)
            catch e
                e isa Test.TestSetException || rethrow()
            end
        end
    end
    return ts
end

function mark_remaining_broken!(run::Run, u::UnitIdx, attempt::Int8)
    p = run.plan
    for i in p.units.span[u]
        run.statuses.state[i] === UNSEEN || continue
        began!(run, i, SlotIdx(0), attempt, 0)
        ts = error_testset(
            run, i, "the worker running this chain died before this item ran; " *
                "the state it depended on is gone, so it was not run", time()
        )
        # Slot 0: in this attempt the item never ran anywhere.
        record!(
            run, i, SlotIdx(0), attempt, BROKEN_CHAIN, ts, RuntestsWorkers.PerfStats(), true,
            "the worker running this chain died before this item ran"
        )
    end
    return nothing
end

### In-process mode ########################################################

function run_in_process(run::Run, target)
    p = run.plan
    @lock run.lock push!(run.tasks, current_task())
    # The default profile's `init` readies this process for the items that run in it.
    # When every item gets a worker, as one in an environment directory does, each
    # worker runs its own `init` where its items run, and this process has none to run.
    if any(u -> !needs_worker(p, u), UnitIdx(1):UnitIdx(length(p.units)))
        isempty(p.profiles[1].init.args) ||
            @warn "Runtests: the profile's `init` expression is evaluated in this process (workers=0)"
        Core.eval(Main, Expr(:block, p.profiles[1].init.args...))
    end
    slot = run.slots[1]
    # Every unit, not just the one slot's queue: a pool that would have had a
    # worker of its own has none here, and its items still have to run.
    for u in UnitIdx(1):UnitIdx(length(p.units))
        is_cancelled(run.queues) && break
        # A unit that asked for a process gets one here too — `run_unit_once!`
        # decides which do — started and stopped around it.
        slot.profile = p.units.profile[u]
        try
            run_unit!(run, slot, u, target)
        finally
            stop_worker!(run, slot)
        end
    end
    check_finished(run)
    return nothing
end

# The profile's test-end expression after the item, merged the way a worker's two
# replies are. Nothing here can be timed out: there is no second process to kill.
with_test_end(res::ItemResult, spec::ItemSpec, test_end::Expr) =
    isempty(test_end.args) || res.state === SKIPPED ? res :
    merge_test_end(res, RuntestsWorkers.run_test_end(spec, test_end))
