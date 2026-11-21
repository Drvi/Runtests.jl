# Running a plan: one task per slot, worker lifecycle, stall watchdog, attempt
# recording, and in-process execution. Scheduling lives in `scheduler.jl` and
# test/profile environment setup in `environments.jl`.

# A slot is its own task's, on the run's thread. The fields other threads read are
# atomic: `worker`, `current`, `attempt`, `started` and `collecting`, which the monitor
# reads, and `dying_log`, which the worker's output relay reads. `dying_lines` is the
# relay's while `dying_log` is set, and the slot's again once it has joined the relay.
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
    # When the attempt in flight began, seconds from `run.t0` (0 when idle), read by
    # the monitor without touching `Statuses.start`, which keeps any earlier verdict.
    @atomic started::Float32
    attempt_pid::Int32       # process running `current` (run's thread only)
    attempt_seq::Int16       # 1-based item sequence on that worker (run's thread only)
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

Slot(id::SlotIdx, profile::ProfileIdx, worker, started_at::Float64, worker_items::Int,
     current::ItemIdx, attempt::Int8, dying_log::String, dying_lines::Vector{String},
     recycle::Bool, collecting::ItemIdx) =
    Slot(id, profile, worker, started_at, worker_items, current, attempt, 0.0f0, Int32(0), Int16(0),
         dying_log, dying_lines, recycle, collecting)

# The run stops, for `ending`: said in its run state before anything else, since how a
# run ended tells what every item it leaves running or unseen means, and then nothing
# more is handed out. Whether it had been stopped already, as `cancel!` says.
function stop!(run, ending::RunEnding)
    mark_ending!(@atomic(run.runstate), ending)
    return cancel!(run.queues)
end

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

Per-item committed verdicts, written by whichever slot task owns the item. Arrays
rather than objects so that the run state can be written straight out of them.
Once an item has a decisive verdict, a later retry that is skipped or cancelled does
not overwrite these columns.
"""
struct Statuses
    counted::Vector{Bool}      # an item is counted as finished once, however many attempts
    synthetic::Vector{Bool}    # the outcome was written by the coordinator, not by the item
    state::Vector{ItemState}
    start::Vector{Float32}     # seconds from the start of the run to the item's dispatch
    attempt::Vector{Int8}
    slot::Vector{SlotIdx}
    pid::Vector{Int32}         # the process its committed attempt ran in, 0 for none
    # Where its committed attempt came among the items its process ran, 1 for a fresh
    # process and 0 for none; a fresh process has yet to compile what the others have.
    seq::Vector{Int16}
    elapsed::Vector{Float32}
    compile::Vector{Float32}
    testsets::Vector{Union{Nothing, Test.AbstractTestSet}}
    # What its committed attempt left of evidence, as `ItemResult.artifacts` says it.
    artifacts::Vector{UInt8}
    # The rest of its status row: recompile seconds, MiB allocated and peak resident MiB:
    # of its worker and the processes under it during the attempt, as the monitor
    # sampled them, or else the process's largest so far (`maxrss`).
    recompile::Vector{Float32}
    alloc_mb::Vector{Float32}
    rss_mb::Vector{Float32}
    # The latest attempt whose outcome is recorded, 0 for none: a skip after a failure
    # leaves `attempt` at the failure's, and is recorded all the same.
    recorded::Vector{Int8}
end

Statuses(n::Integer) = Statuses(
    falses(n), falses(n), fill(UNSEEN, n), zeros(Float32, n), zeros(Int8, n), fill(SlotIdx(0), n),
    zeros(Int32, n), zeros(Int16, n), zeros(Float32, n), zeros(Float32, n),
    Vector{Union{Nothing, Test.AbstractTestSet}}(nothing, n), zeros(UInt8, n),
    zeros(Float32, n), zeros(Float32, n), zeros(Float32, n), zeros(Int8, n)
)

# A verdict an attempt decided: passed, failed, errored, timed out or broken. A skip or
# a cancel decides nothing, and leaves an item the verdict of an earlier attempt.
is_decisive(s::ItemState) = !(s === SKIPPED || s === CANCELLED || s === UNSEEN || s === RUNNING)

# Everything observers (`report_item!`, `tell_on_event`, `event_item_finished`) need for
# one completed attempt, carried explicitly so `Statuses` never needs temporary
# overwrite-and-rollback when a retry is skipped or cancelled after a decisive attempt.
struct AttemptOutcome
    i::ItemIdx
    slot::SlotIdx
    attempt::Int8
    state::ItemState
    verdict::ItemState
    pid::Int32
    elapsed::Float64
    stats::RuntestsWorkers.PerfStats
    testset::Test.AbstractTestSet
    synthetic::Bool
    artifacts::UInt8
    note::String
    ended::Float64
    n::Int
end

mutable struct Run
    const plan::Plan
    const queues::Queues
    const statuses::Statuses
    const slots::Vector{Slot}
    const project_name::String
    const runid::String
    # The run's own temporary directory: coverage counts, which the run merges into
    # `lcov.info`, and the items' logs when there is no run state to keep them by.
    # Empty if `mktempdir` failed (forcing `logs = :eager` and disabling coverage).
    const scratch::String
    # Where the items' logs go: in the run's directory, beside its record, which they
    # share a lifetime with (see `rundata_dir`), once it is open; `scratch` until then
    # (or empty if no temporary directory could be created).
    logdir::String
    # Where `RUNTESTS_ARTIFACT_DIR` had the run copy its run state and logs, once it
    # has; empty otherwise.
    exported::String
    # Per package, where its items' logs go, the part of a log's name that never varies,
    # and where the attempts' evidence goes (see `artifacts_path`), absolute: the log
    # prefix once the run state is open; until then, and without one, a directory of the
    # run's own in the system's temporary files, made only if an attempt asks, which
    # outlives the run (all empty if `mktempdir` failed and no run state opened).
    # `logdir` is the first package's, the one of a standalone run. A log is named by
    # the item's index in its package's run state.
    const logdirs::Vector{String}
    const logprefixes::Vector{String}
    const artifacts_prefixes::Vector{String}
    const local_item::Vector{ItemIdx}
    # Per package, once the environment is active: the project its items run in, the
    # test environment of a standalone run, the union environment of a combined one,
    # or an isolated package's own test project.
    const package_projects::Vector{String}
    # Precomputed per-profile skip flags (`skips_environment`) and package name width.
    const skipped_profiles::BitVector
    const package_width::Int32
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
    # Per-slot pre-spawned worker processes started before `with_run_env` (claimed once).
    const prespawned::Vector{Union{Nothing, RuntestsWorkers.WorkerProcess}}
    # Guards `tasks`, `killed`, `prespawned`, `item_pids` and `evidence`, which other tasks use as well.
    const lock::ReentrantLock
    # Every process an attempt ran in: under coverage, each should leave a tracefile.
    const item_pids::Set{Int32}
    # The attempts whose evidence is kept, as (item, attempt), for the closing report.
    const evidence::Vector{Tuple{ItemIdx, Int8}}
    coverage::Union{Nothing, CoverageSummary}
    # An editor's, when it asked for the run: each item's start and end go there.
    const events::Union{Nothing, EventStream}
    # The caller's `on_event`, or nothing: none was given, one call threw, or the
    # process is exiting. Called under `on_event_lock`, so calls never overlap.
    @atomic on_event::Any
    const on_event_lock::ReentrantLock
    # The thread the run's task and every task it starts with `@async` are stuck to.
    const thread::Int
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
    execute(plan, target; on_event = nothing) -> Run

Run the plan to completion and return the run, whose `statuses` hold what
happened to every item. Printing and the pass/fail verdict are `report`'s job,
so a caller that wants to inspect the outcome does not have to catch anything.
The caller holds the process (`exclusively`). `on_event` is called with a
[`TestItemEvent`](@ref) as each attempt starts and ends.
"""
function execute(p::Plan, target; on_event = nothing)
    # Items that run in this process run on the caller's thread, as the code around
    # the call would run them.
    single_process(p) && return execute_here(p, target, on_event)
    return in_default_pool(() -> execute_here(p, target, on_event))
end

"""
    in_default_pool(f)

`f()`, in a task stuck to a thread of the default pool when this task runs in
another pool. The run starts its slots with `@async`, which sticks them to the thread
of the task that starts them, and from Julia 1.12 the main task runs on the
interactive thread, which is for the REPL and an editor's requests. Ctrl-C lands on
that thread, in this task as it waits: it is handed on to `f`'s task, and this task
waits on until that one ends. Returns what `f` returns, and throws what it throws.
"""
function in_default_pool(f)
    Threads.threadpool() === :default && return f()
    outer = @atomic RuntestsWorkers.INTERRUPT_TARGET.task
    pinned = Threads.Event()
    # `runtests` reads which file called it from here (`running_from_runtests`).
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    t = Threads.@spawn :default begin
        # Before its first wait, so it never moves.
        current_task().sticky = true
        @atomic RuntestsWorkers.INTERRUPT_TARGET.task = current_task()
        notify(pinned)
        try
            source === nothing ? f() : task_local_storage(f, :SOURCE_PATH, source)
        finally
            @atomic RuntestsWorkers.INTERRUPT_TARGET.task = outer
        end
    end
    # Shielded: from Julia 1.14 a cancellation reaches `t` itself, which inherits this
    # task's scope, and every wait here would throw it again.
    caught = nothing
    while !istaskdone(t)
        try
            if caught !== nothing
                # `t` is the target once it is stuck to its thread.
                shielded(() -> wait(pinned))
                RuntestsWorkers.forward_interrupt(caught)
                caught = nothing
            end
            shielded(() -> wait(t))
        catch e
            istaskdone(t) && break
            is_interrupt(e) || rethrow()
            caught = e
        end
    end
    # What it threw, alone, as a run in this task would throw it: thrown while the
    # `TaskFailedException` is handled, Julia would print both.
    istaskfailed(t) && throw(t.result)
    return fetch(t)
end

function execute_here(p::Plan, target, on_event)
    cfg = p.cfg
    warn_sandboxed_workers(p)
    project_name = something(project_name_of(target.project), "")
    runid = string(time_ns(); base = 16)
    npkg = length(p.packages)
    scratch, logdirs, logprefixes, artifacts_prefixes = try
        dir = mktempdir(; prefix = "runtests_")
        dirs = npkg == 1 ? [dir] : [mkpath(joinpath(dir, string(k))) for k in 1:npkg]
        prefixes = [joinpath(d, "item_") for d in dirs]
        evidence = joinpath(tempdir(), string("runtests_artifacts_", runid))
        art = npkg == 1 ? [joinpath(evidence, "item_")] : [joinpath(evidence, string(k), "item_") for k in 1:npkg]
        dir, dirs, prefixes, art
    catch e
        is_interrupt(e) && rethrow()
        @warn string(
            "Runtests: could not create temporary directory for logs; falling back to `logs = :eager`",
            cfg.coverage ? " and disabling coverage" : ""
        ) exception = e
        cfg = with_config(cfg; logs = :eager, coverage = false)
        p = with_plan_cfg(p, cfg)
        "", fill("", npkg), fill("", npkg), fill("", npkg)
    end
    names, column = item_names(p, run_name_width(p))
    local_item = zeros(ItemIdx, nitems(p))
    seen = zeros(Int, npkg)
    for i in 1:nitems(p)
        local_item[i] = (seen[p.items.package[i]] += 1)
    end
    # Precompute once per run rather than walking `.git` on every item or taking
    # `maximum(textwidth, ...)` on every printed RUN/DONE line.
    root_for_names = any(k -> !isempty(p.packages.cfg[k].skip_environment), 1:npkg) ? naming_root(p.root) : ""
    skipped_profiles = BitVector(
        !isempty(p.profiles[j].environment) &&
        !isempty(p.packages.cfg[p.profile_package[j]].skip_environment) &&
        (rel_slash(p.profiles[j].environment, root_for_names) in p.packages.cfg[p.profile_package[j]].skip_environment)
        for j in eachindex(p.profiles)
    )
    package_width = Int32(maximum(textwidth, p.packages.name; init = 0))
    # As its first `@async` would: the run's tasks share this thread from here.
    current_task().sticky = true
    run = Run(
        p, Queues(p), Statuses(nitems(p)), Slot[], project_name, runid, scratch, scratch, "", logdirs, logprefixes,
        artifacts_prefixes, local_item, String[], skipped_profiles, package_width, column, names,
        ReentrantLock(), time(), nothing, nothing, Dict{ProfileIdx, String}(), 0, 0, 0.0, false, Task[],
        RuntestsWorkers.Worker[], Vector{Union{Nothing, RuntestsWorkers.WorkerProcess}}(nothing, nslots(p)), ReentrantLock(),
        Set{Int32}(), Tuple{ItemIdx, Int8}[], nothing, EVENTS[], on_event, ReentrantLock(), Threads.threadid()
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
        # Overlap worker process startup with test environment resolution and precompilation
        # when Runtests itself is already precompiled in this depot. Inside `try` so an
        # interrupt mid-spawn still reaps every already-launched process in `finally`.
        try
            prespawn_workers!(run, p)
            # Asked of git while the environments are made ready (`worktree_state`), on any
            # thread: started after `prespawn_workers!` so git's `uv_spawn` does not race
            # worker process spawn on Windows.
            worktree = Threads.@spawn worktree_state(p.root)
            with_run_env(target, run) do
                # Before the run state: an environment directory that does not resolve
                # stops the run before anything has run to record.
                profile_projects!(run, p)
                # Opened once the test environment is active: its manifest is part of
                # what the file records. A run of several packages has one for each.
                state = fetch(worktree)
                @atomic run.runstate = is_combined(p) ?
                    open_runstate_set(p, run.t0, run.runid; worktree = state,
                                      worker_projects = [worker_projects(run, k) for k in eachindex(p.packages.name)]) :
                    open_runstate(p, run.t0; worktree = state, worker_projects = worker_projects(run, 1))
                keep_logs_by_runstate!(run)
                # Until the first item can start, a throw ends the run here, and its file
                # must say so: unfinished, its beats would keep it looking alive for as
                # long as this process lasts. Why it ended goes beside it.
                testing = Ref(false)
                try
                    run_testing(run, p, setup_paths, testing)
                catch e
                    if !testing[]
                        shielded() do
                            close_prespawned!(run)
                            write_run_log(run, "setup.log", sprint(showerror, e))
                            finish_run_state!(run.runstate, ENDING_SETUP_FAILED)
                            tidy_logs(run)
                            export_run!(run)
                        end
                    end
                    rethrow()
                end
            end
        catch e
            # Stopped before its run state opened, as by an environment that does not
            # resolve: no directory of the run keeps why, so a job's artifacts do.
            (@atomic run.runstate) === nothing && !is_interrupt(e) && write_job_setup_log(run, e)
            rethrow()
        finally
            shielded(() -> close_prespawned!(run))
        end
    end
end

# The project each profile of package `k` starts its workers in, in the order of the
# package's plan (`package_plan`), for the package's run state to keep a snapshot of.
# Empty for an environment the run skips, which starts no worker.
worker_projects(run::Run, k::Integer) = String[
    run.skipped_profiles[j] ? "" : worker_project(run, j)
    for j in eachindex(run.plan.profiles) if run.plan.profile_package[j] == k]

# Why a run stopped before it opened its run state, as `setup-<run>.log` in
# `RUNTESTS_ARTIFACT_DIR`, where its directory would have been copied. A run that
# opened one says why in that directory's `setup.log` instead.
function write_job_setup_log(run::Run, e)
    dir = get(ENV, "RUNTESTS_ARTIFACT_DIR", "")
    isempty(dir) && return nothing
    try
        mkpath(dir)
        write(joinpath(abspath(dir), string("setup-", run.runid, ".log")),
              string("the run stopped before it opened its run state: ", sprint(showerror, e), "\n"))
    catch err
        is_interrupt(err) && rethrow()
        @warn "Runtests: could not write why the run stopped to `RUNTESTS_ARTIFACT_DIR` ($dir)" exception = err
    end
    return nothing
end

# Setup, then the items. `testing` is set once the items' own `finally` is in place
# to finish the run state.
function run_testing(run::Run, p::Plan, setup_paths::Vector{String}, testing::Ref{Bool})
    cfg = p.cfg
    check_replayed_environment(run)
    return with_load_path(setup_paths) do
        precompile_phase(run, p)
        # From the start of the run, as the monitor's setup stage is, so the
        # header and the closing block give the same figure.
        p.startup.setup = time() - run.t0
        # Printed once setup is done, so it can say what setup cost.
        print_run_header(run)
        set_phase!(run.monitor, PHASE_TEST)
        cfg.workers == 0 && init_in_process!(run)
        interrupted = false
        ensure_exit_report()
        @atomic LIVE_RUN.run = run
        limit = stall_limit(p)
        @atomic run.last_finish = time()
        watchdog = start_watchdog(run, limit)
        testing[] = true
        try
            if cfg.workers == 0
                run_in_process(run)
            else
                run_on_workers(run)
            end
            # Stopped with nothing in flight to interrupt: the slots saw their
            # workers go and ended on their own.
            (@atomic run.stalled) && throw(RunStalled(limit))
        catch e
            stalled = @atomic run.stalled
            if is_interrupt(e) || stalled
                interrupted = true
                shielded() do
                    # Stopped, by Ctrl-C, the watchdog or an item that threw an interrupt.
                    # In this process, the item it was running is recorded as stopped; a
                    # worker's slot records its own.
                    stop!(run, stalled ? ENDING_STALLED : ENDING_INTERRUPTED)
                    cfg.workers == 0 && record_stopped_item!(run, run.slots[1])
                    kill_workers!(run)
                end
            else
                # An error of the run itself.
                shielded(() -> stop!(run, ENDING_ERRORED))
            end
            stalled ? throw(RunStalled(limit)) : rethrow()
        finally
            # Shielded: after a cancellation every wait in this task throws
            # again, and this has to finish.
            shielded() do
                close(watchdog)
                # The exit hook closes the run when it takes it first: the process
                # is going down, and this task's thread was held while it did.
                (@atomicswap LIVE_RUN.run = nothing) === run || return nothing
                set_phase!(run.monitor, PHASE_REPORT)
                stop_monitor!(run.monitor)
                shutdown!(run)
                record_cpu_end!(run.monitor)
                # Every worker has exited, so every tracefile there will be
                # is written.
                cfg.coverage && (run.coverage = collect_coverage(run))
                run.monitor === nothing || write_memory!(run.runstate, run.monitor.stats)
                # What stopped the run said how it ended as it did (`stop!`).
                finish_run_state!(run.runstate, ENDING_FINISHED)
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

# A run state we cannot write is a run state we do without: the tests matter more
# than the record of them.
function open_runstate(p::Plan, start::Float64; worktree::AbstractString = "unknown",
                       worker_projects::Vector{String} = String[])
    path = nothing
    try
        path = new_runstate_path(p.root)
        return init_run_state(path, p; start, meta = ["worktree" => String(worktree)], worker_projects)
    catch e
        # A directory claimed and left without a record would never be read, nor pruned.
        path === nothing || remove_runstate(path)
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
        dir = rundata_dir(rsf.path)
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
    run.logdir = run.logdirs[1]
    # Only for a caller that gave `on_event`: a run without one leaves no empty directory.
    if (@atomic run.on_event) !== nothing
        for k in eachindex(run.logdirs)
            isempty(run.logdirs[k]) && continue
            try
                mkpath(events_dir(run, k))
            catch e
                is_interrupt(e) && rethrow()
                @warn "Runtests: could not make $(events_dir(run, k)) for `on_event`" exception = e
            end
        end
    end
    return nothing
end

# `text` as `name` in each package's log directory; never a reason to fail the run.
function write_run_log(run::Run, name::AbstractString, text::AbstractString)
    for dir in run.logdirs
        isempty(dir) && continue
        try
            write(joinpath(dir, name), text)
        catch e
            is_interrupt(e) && rethrow()
        end
    end
    return nothing
end

# Where attempt `attempt` at item `i` writes what it prints, and its failure report:
# with its package's logs, by its index in its package's run state. Empty when no log
# directory could be made.
function item_log(run::Run, i::Integer, attempt::Integer)
    prefix = run.logprefixes[run.plan.items.package[i]]
    return isempty(prefix) ? "" : item_log_path(prefix, run.local_item[i], attempt)
end
function failure_log(run::Run, i::Integer, attempt::Integer)
    prefix = run.logprefixes[run.plan.items.package[i]]
    return isempty(prefix) ? "" : failure_path(prefix, run.local_item[i], attempt)
end

# Whether a plan is a run of several packages, each with a run state of its own:
# packages other than the one at its root.
is_combined(p::Plan) = length(p.packages) > 1 || p.packages.root[1] != p.root

function write_failure_report(run::Run, i::ItemIdx, attempt::Integer, testset)
    path = failure_log(run, i, attempt)
    isempty(path) && return nothing
    failures = collect_failures(testset)
    isempty(failures) && return nothing
    text = sprint() do io
        for r in failures
            show(io, r)
            println(io)
        end
    end
    try
        write(path, strip_root(text, run.plan.root))
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

"""
    export_run!(run)

When `RUNTESTS_ARTIFACT_DIR` names a directory, copy the run's `<run>.rundata`
bundle there, with its record and logs. A combined run copies one bundle under
each package's name. Called after the run state is finished, however the run ended;
a copy failure is reported without changing the test verdict.
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
            # The run's directory: its record and its logs, as one.
            rundata = rundata_dir(rsf.path)
            cp(rundata, joinpath(to, basename(rundata)); force = true)
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
        if !isempty(evidence)
            (isempty(prefix) || evidence != abspath(prefix)) && remove_if_empty(dirname(evidence))
        end
        isempty(logdir) && continue
        !isempty(run.scratch) && startswith(logdir, run.scratch) && continue
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
    needs_worker(p, i) -> Bool

Whether item `i` needs a process of its own however the run is configured:
`--check-bounds=yes` cannot be applied to a running process, one process cannot
give an item a process to itself, and it loads the packages of one environment.
Such an item gets a worker even under `workers=0`; passing it here would pass a test
that never ran as written.
"""
needs_worker(p::Plan, i::ItemIdx) = p.items.exclusive[i] || !is_plain(p.profiles[p.items.profile[i]])

"""
    skips_environment(p, j) -> Bool

Whether the run skips the environment of profile `j`: an environment directory that
`skip_environment` of the profile's package names, by its path from the root of the
repository (`naming_root`). The run does not build such an environment and starts no
worker in it, and it records the items there as skipped itself (`attempt_skipped!`).
"""
function skips_environment(p::Plan, j::Integer)
    dir = p.profiles[j].environment
    isempty(dir) && return false
    k = p.profile_package[j]
    names = p.packages.cfg[k].skip_environment
    isempty(names) && return false
    # From the run's root, the workspace of a combined run, as `prepare` names them.
    return rel_slash(dir, naming_root(p.root)) in names
end

# The default profile in the test environment: what this process can be.
is_plain(prof::Profile) = prof.name === DEFAULT_PROFILE && isempty(prof.environment)

# Whether any of the run's items runs under a profile other than the default, or in
# an environment other than the test environment.
uses_profiles(p::Plan) = any(j -> p.profiles[j].name !== DEFAULT_PROFILE, p.items.profile)
uses_environments(p::Plan) = any(j -> !isempty(p.profiles[j].environment), p.items.profile)

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
    for i in ItemIdx(1):ItemIdx(nitems(p))
        needs_worker(p, i) && push!(names, p.items.name[i])
    end
    isempty(names) && return nothing
    @warn "Runtests: workers=0, but these items need a process this one cannot be, for a sandbox, " *
        "a profile or an environment, so each one gets a worker of its own that is torn down afterwards:\n" *
        join(("  " * repr(n) for n in names), "\n")
    return nothing
end

### Workers ################################################################

function run_on_workers(run::Run)
    # When workers were pre-spawned, they are already booting/booted, so collect
    # before launching slot tasks rather than concurrently with `connect_worker`.
    has_prespawned = @lock run.lock any(!isnothing, run.prespawned)
    has_prespawned && GC.gc(true)
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
                    run_slot(run, s)
                catch e
                    if is_interrupt(e)
                        RuntestsWorkers.forward_interrupt(e)
                        stop!(run, (@atomic run.stalled) ? ENDING_STALLED : ENDING_INTERRUPTED)
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
        has_prespawned || GC.gc(true)
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
            stop!(run, interrupt !== nothing ? ENDING_INTERRUPTED : (@atomic run.stalled) ? ENDING_STALLED : ENDING_ERRORED)
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
    @error "Runtests internal error: $(length(left)) test items have no outcome, though the run was not stopped" items = left head = q.head tail = q.tail from = q.from to = q.to slot_pools = q.pool pending = q.pending parked = q.parked set_aside = q.set_aside unclaimed_units = findall(!, q.claimed)
    return nothing
end

"""
    record_stopped_item!(run, slot; observe = true)

Record the item this slot was running when the run was stopped: it neither failed
nor finished, and is counted with the items the run never reached. With `observe =
false`, from the exit hook, the outcome goes to the statuses and the run state only,
and not to the report, an editor or `on_event`, whose locks a task the exit froze may
hold.
"""
function record_stopped_item!(run::Run, slot::Slot; observe::Bool = true)
    i = @atomic slot.current
    i == ItemIdx(0) && return nothing
    attempt = max(@atomic(slot.attempt), Int8(1))
    # The slot may have recorded this attempt already, on its way out of a dispatch
    # that failed for a reason of its own; an earlier attempt's outcome is no reason
    # to leave this one unrecorded.
    if run.statuses.recorded[i] < attempt
        state, note = (@atomic run.stalled) ? (TIMEDOUT, STALLED_NOTE) : (CANCELLED, "the run was stopped")
        start_off, pid, seq = (@atomic slot.started), slot.attempt_pid, slot.attempt_seq
        if observe
            record_error!(run, i, slot, attempt, state, note, start_off, pid, seq)
        else
            ended = time()
            persist_attempt!(run, i, slot.id, attempt, state, error_testset(run, i, note, start_off, ended),
                             RuntestsWorkers.PerfStats(), true, start_off, pid, seq, note; ended)
        end
    end
    release_item!(slot)
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
    stop!(run, ENDING_STALLED)
    say(run, "no test item has finished in ", fmt_seconds(limit),
        ", longer than one attempt at any of them may take; stopping the run as hung")
    interrupt_slots!(@lock run.lock copy(run.tasks))
    kill_workers!(run, "stopped as hung")
    stop_monitor!(run.monitor)
    return nothing
end

function run_slot(run::Run, slot::Slot)
    while true
        recycle_worker!(run, slot)
        wait_while_paused(run.queues, slot)
        (@atomic slot.recycle) && continue
        claim = claim!(run.queues, slot.id)
        if claim.kind === :done
            break
        elseif claim.kind === :wait
            continue
        elseif claim.kind === :rebind
            # Either this slot's own pool is empty and another profile still has work,
            # or exact replay's next recorded item belongs to another pool; replace the
            # process rather than exceeding the worker cap.
            slot.profile = run.plan.pools[claim.pool].profile
            stop_worker!(run, slot)
            continue
        end
        try
            run_item!(run, slot, claim.item)
        finally
            item_ended!(run.queues, claim.item)
        end
    end
    stop_worker!(run, slot)
    return nothing
end

# Between units, never while one runs.
function recycle_worker!(run::Run, slot::Slot)
    (; success) = @atomicreplace slot.recycle true => false
    success && stop_worker!(run, slot, "restarted by the memory guard")
    return nothing
end

function ensure_worker!(run::Run, slot::Slot, exclusive::Bool)
    # Read once: a second read could find what another task stored since.
    w = @atomic slot.worker
    (w === nothing || w.terminated) || return w
    w = start_worker(run, slot, exclusive)
    @atomic slot.worker = w
    return w
end

const WORKER_START_RETRIES = 2
# Generous connect timeout for pre-spawned workers so long cold precompilation phases
# do not expire them before `run_on_workers` claims them (`watch_coordinator` / Windows
# JobObject still terminate them immediately if the coordinator exits).
const PRESPAWN_CONNECT_TIMEOUT = 600

# Spawn eligible slots' OS worker processes synchronously on the coordinator thread
# *before* `with_run_env` and `precompile_phase` so Julia boot + `Runtests` load happens
# in the kernel during environment setup — with zero background tasks racing against
# `withenv` / `Base.require(Pkg)`. Once setup finishes, `start_worker` connects to the
# already-ready pipe/socket and switches the worker to its resolved test environment via
# `remote_activate`.
function prespawn_workers!(run::Run, p::Plan)
    (single_process(p) || isempty(run.slots)) && return nothing
    # Julia 1.12 on Windows intermittently aborts with 0xC0000005 when pre-spawned
    # worker processes sit open across environment setup/precompilation (observed on
    # 1.12.7 only; 1.11, 1.13, and 1.14 are unaffected). Start workers on demand there.
    (Sys.iswindows() && v"1.12" <= VERSION < v"1.13") && return nothing
    # If `Runtests` has no fresh cache in the current depot (e.g. a fresh temp depot),
    # let `precompile_phase` compile it once instead of N workers racing to compile it.
    precompiled = try
        Base.isprecompiled(RuntestsWorkers.PKGID; ignore_loaded = true)
    catch
        false
    end
    precompiled || return nothing
    boot_project = Base.active_project()
    boot_load_path = join(LOAD_PATH, PATHSEP)
    # Strip any caller `JULIA_PROJECT`/`JULIA_LOAD_PATH` so the worker boots with the
    # coordinator's actual project and load path, not a stale environment variable.
    boot_env = Dict{String, String}(k => v for (k, v) in ENV if k != "JULIA_PROJECT" && k != "JULIA_LOAD_PATH")
    color = get(stdout, :color, false)
    for slot in run.slots
        run.skipped_profiles[slot.profile] && continue
        !isempty(p.replay_slots) && isempty(p.replay_slots[slot.id]) && continue
        prof = p.profiles[slot.profile]
        # Workers with custom julia flags or coverage may need `precompile_phase` to
        # build a matching cache of `Runtests` first; start them after precompilation.
        isempty(worker_julia_args(run, prof)) || continue
        extra = Pair{String, String}[
            "RUNTESTS_RUN_ID" => run.runid,
            "RUNTESTS_WORKER" => string(slot.id),
            "JULIA_LOAD_PATH" => boot_load_path,
        ]
        append!(extra, prof.env)
        wp = try
            RuntestsWorkers.spawn_worker_process(;
                julia_args = String[],
                threads = prof.threads,
                env = boot_env,
                extra_env = extra,
                dir = worker_dir(p, slot.profile),
                project = boot_project,
                connect_timeout = PRESPAWN_CONNECT_TIMEOUT,
                color,
            )
        catch e
            is_interrupt(e) && rethrow()
            nothing
        end
        wp === nothing || @lock run.lock (run.prespawned[slot.id] = wp)
    end
    return nothing
end

function claim_prespawned!(run::Run, slot_id::SlotIdx)
    return @lock run.lock begin
        wp = run.prespawned[slot_id]
        run.prespawned[slot_id] = nothing
        wp
    end
end

function close_prespawned!(run::Run)
    pending = @lock run.lock begin
        out = RuntestsWorkers.WorkerProcess[]
        for i in eachindex(run.prespawned)
            wp = run.prespawned[i]
            if wp !== nothing
                run.prespawned[i] = nothing
                push!(out, wp)
            end
        end
        out
    end
    isempty(pending) && return nothing
    for wp in pending
        RuntestsWorkers.abort_worker_process!(wp)
    end
    return nothing
end

function start_worker(run::Run, slot::Slot, exclusive::Bool = false)
    prof = run.plan.profiles[slot.profile]
    last_err = nothing
    for attempt in 1:(WORKER_START_RETRIES + 1)
        began = time()
        ready = began
        w = nothing
        from_prespawn = false
        relay_state = RelayState()
        if attempt == 1
            wp = claim_prespawned!(run, slot.id)
            if wp !== nothing
                try
                    w, ready = RuntestsWorkers.connect_worker(
                        wp;
                        redirect_io = stdout,
                        redirect_fn = (io, pid, line) -> relay!(run, slot, relay_state, line),
                        on_exit = w -> worker_ended!(run, slot.id, w),
                        on_output_done = () -> close_relay_log!(relay_state),
                    )
                    began = wp.began
                    from_prespawn = true
                catch e
                    is_interrupt(e) && rethrow()
                    # Pre-spawn failed or exited during a very long setup; fall through
                    # to a normal start attempt below.
                    relay_state = RelayState()
                end
            end
        end
        if w === nothing
            began = time()
            w = try
                RuntestsWorkers.Worker(;
                    julia_args = worker_julia_args(run, prof),
                    threads = prof.threads,
                    extra_env = worker_env(run.runid, slot.id, worker_project(run, slot.profile), prof;
                                           load_path = worker_load_path(run, slot.profile)),
                    dir = worker_dir(run.plan, slot.profile),
                    project = worker_project(run, slot.profile),
                    redirect_io = stdout,
                    # Everything the worker writes: its RUN and DONE records, and under
                    # `logs=:eager` whatever its items print.
                    redirect_fn = (io, pid, line) -> relay!(run, slot, relay_state, line),
                    on_exit = w -> worker_ended!(run, slot.id, w),
                    on_output_done = () -> close_relay_log!(relay_state)
                )
            catch e
                is_interrupt(e) && rethrow()
                last_err = e
                attempt <= WORKER_START_RETRIES && sleep(1)
                continue
            end
            ready = time()
        end
        append_event!(run.runstate, EVENT_WORKER_UP, 0, slot.id, w.pid, began - run.t0, ready - run.t0)
        init_began = time()
        try
            if from_prespawn
                fut = RuntestsWorkers.remote_activate(w, worker_project(run, slot.profile), worker_load_path(run, slot.profile))
                fetch_within(
                    fut, 30,
                    TimeoutException(30, "activating the test environment on worker $(w.pid)", "", "init_timeout")
                )
            end
            init_worker!(run, slot, w)
            slot.started_at = time()
            note_start!(run.queues, slot.id, max(0.0, ready - began) + max(0.0, slot.started_at - init_began))
            slot.worker_items = 0
            count_worker_start!(run.monitor)
            print_worker_line(
                run, slot.id, "UP", string(
                    "pid ", w.pid, " · threads ", prof.threads,
                    # Why this process exists: a pool worker runs whatever it is
                    # handed, a sandbox runs one unit and goes away again.
                    exclusive ? " · sandbox" : "",
                    profile_text(run.plan, slot.profile),
                    uses_environments(run.plan) ? string(" · ", isempty(prof.environment) ? "env test" :
                        string("env ", relpath_or_path(prof.environment, run.plan.root))) : "",
                    isempty(prof.julia_args) ? "" : string(" · ", join(prof.julia_args, " "))
                )
            )
            return w
        catch e
            # The process is up; it is activation or the `init` expression that failed or hung.
            if is_interrupt(e)
                shielded() do
                    RuntestsWorkers.kill!(w)
                    wait(w)
                end
                rethrow()
            end
            RuntestsWorkers.terminate!(w, :init_failed)
            wait(w)
            if e isa RuntestsWorkers.RemoteException || e isa TimeoutException
                # The expression itself is at fault: another process would only
                # fail the same way. A timeout already names the expression it
                # timed out on, so only a remote error needs saying what failed.
                stop!(run, ENDING_INIT_FAILED)
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
    stop!(run, ENDING_START_FAILED)
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

# Per-worker relay state, touched only on that worker's `redirect_worker_output` task.
# Under `logs = :eager`, lines between RUN and DONE are also written lazily to the
# attempt's log file so the run's directory and exports keep them without extra files
# for silent items.
mutable struct RelayState
    within::Bool
    log_path::String
    log_io::Union{Nothing, IOStream}
end
RelayState() = RelayState(false, "", nothing)

function close_relay_log!(state::RelayState)
    io = state.log_io
    if io !== nothing
        state.log_io = nothing
        try
            close(io)
        catch e
            is_interrupt(e) && rethrow()
        end
    end
    return nothing
end

function write_relay_log!(state::RelayState, line::AbstractString)
    isempty(state.log_path) && return nothing
    try
        io = state.log_io
        if io === nothing
            io = open(state.log_path, "a")
            state.log_io = io
        end
        println(io, line)
        flush(io)
    catch e
        is_interrupt(e) && rethrow()
        close_relay_log!(state)
        state.log_path = ""
    end
    return nothing
end

"""
    relay!(run, slot, state, line)

One line of what a worker wrote. Its records of an item starting and finishing
become the item's RUN and DONE lines; anything else is the item talking, between a
RUN and its DONE, or the process itself. `state` follows the worker's own stream,
so it never races with the slot's task. While the process is being put down for a
timeout, the item is already recorded as timed out: a verdict it still manages to
send is dropped, and what it says goes with the item's log.
"""
function relay!(run::Run, slot::Slot, state::RelayState, line::AbstractString)
    rec = parse_record(line)
    if !isempty(@atomic slot.dying_log)
        close_relay_log!(state)
        rec === nothing && keep_dying_line!(slot, line)
        return nothing
    end
    if rec !== nothing
        close_relay_log!(state)
        state.within = rec.how === nothing
        state.log_path = (state.within && run.plan.cfg.logs === :eager) ? item_log(run, rec.i, rec.attempt) : ""
        how = rec.how
        if how !== nothing
            # The memory of the worker and of what it started, as the monitor saw it,
            # in place of what the worker's own process has held since it started.
            w = @atomic slot.worker
            tree = w === nothing ? Int64(0) : attempt_tree_rss(run.monitor, slot.id, rec.i, rec.attempt, w.pid)
            tree > 0 && (how = (; how..., maxrss = tree, tree = true))
        end
        return printline(run, item_line(run, slot.id, rec.i, rec.attempt, how))
    end
    state.within && write_relay_log!(state, line)
    return printline(run, string(state.within ? MARK_ITEM : MARK_WORKER, " ", rpad(string("w", slot.id), SLOT_LABEL_WIDTH[]), FIELD, line))
end

# An item's RUN or DONE line, drawn from what this run knows about the item.
item_line(run::Run, slot_id, i::Integer, attempt::Integer, how) = item_line(
    slot_id, i, nitems(run.plan), run.names[i], run.name_width, attempt,
    attempts_for(run.plan, i), something(how, itemlocation(run.plan, i));
    package = is_combined(run.plan) ? run.plan.packages.name[run.plan.items.package[i]] : "",
    package_width = run.package_width
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
                    load_path = isempty(prof.environment) ? LOAD_PATH : isolated_load_path(LOAD_PATH, Base.active_project()))
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
# in their place. In an environment directory, stacked over the minimal `Runtests`-only
# base environment so undeclared dependencies from the test environment do not leak in.
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
    return isolated_load_path(load_path, run.package_projects[k])
end

# Where the workers of profile `j` start: where its `init` runs, for a profile with
# one (`init_dir`), the package's root for an isolated package, and the run's root
# otherwise.
function worker_dir(p::Plan, j::Integer)
    k = p.profile_package[j]
    isempty(p.profiles[j].init.args) || return init_dir(p.profiles[j], p.packages.root[k])
    return p.packages.isolated[k] ? p.packages.root[k] : p.root
end

# Insert a base environment (normally the minimal `Runtests`-only base for isolated
# environment directories, or `test_env` as a fallback) directly after `"@"` in
# `load_path`, so the active project's own packages come first while `RuntestsWorkers`
# remains loadable.
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

# Distinguish a blocked/deadlocked worker from one actively computing at the moment of
# a timeout. Samples CPU time over a short window before `inspect!` signals the worker;
# returns "" if the OS does not expose per-process CPU time.
const TIMEOUT_CPU_PROBE_S = 0.15

function worker_activity_note(pid::Integer; probe_s::Float64 = TIMEOUT_CPU_PROBE_S)
    c0 = Platform.tree_cpu_time(pid)
    c0 < 0 && return ""
    t0 = time()
    sleep(probe_s)
    t1 = time()
    c1 = Platform.tree_cpu_time(pid)
    (c1 < 0 || t1 <= t0) && return ""
    ratio = max(0.0, c1 - c0) / (t1 - t0)
    return ratio < 0.05 ?
        "worker was idle (likely blocked or deadlocked)" :
        string("worker was active (", round(Int, 100 * ratio), "% CPU; slow or looping)")
end

# Shared worker teardown after a failed remote RPC (item dispatch, `test_end`, or
# artifact collection). Returns `:timeout`, `:died`, or `:alive` (worker still usable).
function resolve_worker_failure!(run::Run, slot::Slot, w::Union{Nothing, RuntestsWorkers.Worker}, e,
                                 dying_log::String; is_worker::Bool = w !== nothing,
                                 activity_out::Union{Nothing, Base.RefValue{String}} = nothing)
    if e isa TimeoutException
        if w !== nothing
            activity = worker_activity_note(w.pid)
            activity_out === nothing || (activity_out[] = activity)
            note = isempty(activity) ? "" : string(" · ", activity)
            print_worker_line(run, slot.id, "KILL", string("pid ", w.pid, " · ", sprint(showerror, e), note))
            RuntestsWorkers.inspect!(w)
            @atomic slot.dying_log = dying_log
            RuntestsWorkers.terminate!(w, :timeout)
            wait(w)   # a replacement must not overlap the process it replaces
            flush_dying_log!(slot)
            (@atomic slot.worker) === w && (@atomic slot.worker = nothing)
        end
        return :timeout
    elseif w !== nothing && w.terminated
        wait(w)   # its exit status is known once its process is reaped
        (@atomic slot.worker) === w && (@atomic slot.worker = nothing)
        return :died
    elseif w === nothing && is_worker
        return :died
    end
    return :alive
end

mutable struct LiveRun
    @atomic run::Any
end

"""
    LIVE_RUN

`LIVE_RUN.run` is the run this process is part-way through, or nothing. A process
runs one at a time. Whichever of the run's own teardown and
[`report_unfinished_run`](@ref) takes it from here closes the run, and the other
leaves it be.
"""
const LIVE_RUN = LiveRun(nothing)

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
descriptor (see [`write_now`](@ref)). The run's own thread, when it is another, is
held meanwhile ([`RuntestsWorkers.hold_thread`](@ref)): a slot there whose worker
this kills would wake, and record and report its item again.
"""
function report_unfinished_run()
    run = @atomicswap LIVE_RUN.run = nothing
    run === nothing && return nothing
    # The run's tasks, on a thread other than this one, would go on while this closes
    # the run, and record and say again what this records and says. A task that runs
    # on there for longer than the hold waits leaves them running: then the items in
    # flight stay `running` in the run state, which its ending explains.
    hold = RuntestsWorkers.hold_thread(run.thread)
    held = hold === nothing || hold[] == 1
    try
        # First, before anything here can let a slot run: one that found its worker
        # dead would report a death nothing explains, and blame the OOM killer.
        # Taken from its slot and killed here, the worker is one the run stopped.
        stop!(run, ENDING_EXITED)
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
        # Not called from here: `on_event` is the caller's code, which may wait on the
        # event loop, or on its lock held by a task the exit froze.
        @atomic run.on_event = nothing
        # Nothing unwound, so the slots never recorded what they were holding.
        # They are frozen where they were, and each still names its item. Only the
        # run state is told: the report, an editor and `on_event` each take a lock
        # that a frozen task may hold.
        held && foreach(slot -> record_stopped_item!(run, slot; observe = false), run.slots)
        finish_run_state!(run.runstate, ENDING_EXITED; exiting = true)
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
    finally
        RuntestsWorkers.release_thread(hold)
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
    close_prespawned!(run)
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
    close_prespawned!(run)
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
# `failfast` do.
attempts_for(p::Plan, i::Integer) =
    1 + (p.items.retries[i] == USE_RUN_DEFAULT ? item_cfg(p, i).retries : Int(p.items.retries[i]))

# The attempt policy, the same wherever the item runs: on a pool worker, on a
# sandbox worker, or in this process under `workers=0`.
function run_item!(run::Run, slot::Slot, i::ItemIdx)
    p = run.plan
    max_attempts = attempts_for(p, i)
    for attempt in 1:max_attempts
        run_item_once!(run, slot, i, Int8(attempt), max_attempts)
        note_attempt!(run, slot, i)
        st = run.statuses
        state = st.state[i]
        is_non_pass(state) || return nothing
        # Another attempt only for an item that failed in this one. An item this attempt
        # skipped or cancelled keeps an earlier attempt's verdict (`persist_attempt!`),
        # which another attempt would not change.
        failed_now = is_decisive(state) && st.attempt[i] == attempt
        if attempt == max_attempts || !failed_now
            # Failfast waits for the last attempt: stopping the run under a retry
            # would record the failure as a cancellation.
            p.cfg.failfast && stop!(run, ENDING_FAILFAST) === false &&
                print_failfast(run, i)
            return nothing
        end
        # A run stopped meanwhile, by another item's failfast or a profile whose
        # `init` failed, retries nothing: the attempt's verdict is the item's.
        is_cancelled(run.queues) && return nothing
    end
    return nothing
end

# What one attempt at item `i` on `slot` measured, for the scheduler: how long it
# took against its recorded duration, and its compile time, as a fresh process's
# first item or a later one. Only an attempt that ran and timed itself counts:
# an outcome the run decided took as long as it was allowed.
function note_attempt!(run::Run, slot::Slot, i::ItemIdx)
    st = run.statuses
    (st.synthetic[i] || st.state[i] === UNSEEN || st.state[i] === CANCELLED) && return nothing
    recorded = run.plan.items.est_s[i]
    took = Float64(st.elapsed[i])
    q = run.queues
    @lock q.lock begin
        ps = q.stats[q.pool[slot.id]]
        ps.items += 1
        ps.took_s += took
        if recorded > 0
            ps.estimated_s += recorded
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

# One attempt at item `i`: on the slot's worker, or here when there is no pool
# and the item did not ask for a process of its own.
function run_item_once!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, max_attempts::Int)
    p = run.plan
    skipped = run.skipped_profiles[p.items.profile[i]]
    exclusive = p.items.exclusive[i] && !skipped
    attempt_item! = skipped ? attempt_skipped! :
        single_process(p) && !needs_worker(p, i) ? attempt_here! : attempt_on_worker!
    # A sandbox is a process to itself, and the slot may arrive holding a worker
    # that has already run other items.
    exclusive && slot.worker_items > 0 && stop_worker!(run, slot)
    if is_cancelled(run.queues)
        is_decisive(run.statuses.state[i]) || set_state!(run, i, CANCELLED)
    else
        attempt_item!(run, slot, i, attempt, max_attempts) || return nothing
    end
    exclusive && stop_worker!(run, slot)
    return nothing
end

# The slot holds the item from before anything is told the attempt began until its
# outcome is recorded: a stop that unwinds through it, or an exit while `on_event` is
# told, leaves the item for `record_stopped_item!`.
function hold_item!(slot::Slot, i::ItemIdx, attempt::Int8)
    @atomic slot.attempt = attempt
    @atomic slot.current = i
    return nothing
end

function release_item!(slot::Slot)
    @atomic slot.started = 0.0f0
    @atomic slot.current = ItemIdx(0)
    return nothing
end

# When and in which process an attempt began, marked running before it is sent:
# if this process is killed, the file says which item was in flight, which is the
# truth and usually the answer. An outcome the run decides is timed from here.
function began!(run::Run, slot::Union{Nothing, Slot}, i::ItemIdx, slot_id::SlotIdx, attempt::Int8,
                pid::Int32, seq::Int16)
    now = time()
    start_off = Float32(now - run.t0)
    if slot !== nothing
        @atomic slot.started = start_off
        slot.attempt_pid = pid
        slot.attempt_seq = seq
    end
    if pid != 0
        run.plan.cfg.coverage && @lock run.lock push!(run.item_pids, pid)
        write_status!(run.runstate, i, RUNNING, attempt, slot_id; start_off, pid)
    end
    run.events === nothing || event_item_started(run, i, attempt, slot_id, pid)
    tell_on_event(run, i, :started, RUNNING, attempt, slot_id, pid, now, 0.0, RuntestsWorkers.PerfStats(), false)
    return start_off
end

# Post-body completion shared by worker and in-process attempts: persist the body's
# verdict, run `test_end`, notify observers, release the slot, and finish artifacts.
function complete_attempt!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, max_attempts::Int,
                           spec::ItemSpec, res::ItemResult, w::Union{Nothing, RuntestsWorkers.Worker},
                           start_off::Float32, pid::Int32, seq::Int16)
    recorded = persist_result!(run, i, slot, attempt, res, start_off, pid, seq, max_attempts)
    survived = run_test_end!(run, slot, i, attempt, spec, res, w)
    observe_attempt!(run, recorded)
    release_item!(slot)
    if !survived
        # The hook took the worker: no producer can run, and what the attempt wrote goes
        # as its verdict says.
        if res.artifacts != 0
            res.state === PASSED ? discard_evidence(attempt_artifacts(run, i, attempt)) :
                evidence_after_loss!(run, i, attempt, "the worker was lost in the profile's `test_end`")
        end
        return false
    end
    # Then the evidence, before a retry or a sandbox's end.
    return finish_attempt!(run, slot, i, attempt, res, w)
end

# One attempt at item `i` on the slot's worker, starting one when it has none.
# `false` when the worker is gone and the rest of its unit cannot be trusted.
function attempt_on_worker!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, max_attempts::Int)
    p = run.plan
    w = try
        ensure_worker!(run, slot, p.items.exclusive[i])
    catch e
        is_interrupt(e) && rethrow()
        hold_item!(slot, i, attempt)
        start_off = began!(run, slot, i, slot.id, attempt, Int32(0), Int16(0))
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e), start_off, Int32(0), Int16(0))
        release_item!(slot)
        return false
    end
    spec = item_spec(run, i, attempt)
    pid = Int32(w.pid)
    seq = Int16(min(slot.worker_items + 1, typemax(Int16)))
    hold_item!(slot, i, attempt)
    start_off = began!(run, slot, i, slot.id, attempt, pid, seq)
    result = try
        dispatch(run, w, spec, item_timeout(p, i))
    catch e
        # An interrupt leaves `slot.current` set: the slot is unwinding, and what it was
        # running is what `record_stopped_item!` needs from it.
        is_interrupt(e) && rethrow()
        survived = handle_dispatch_failure!(run, slot, i, attempt, e, max_attempts, start_off, pid, seq)
        release_item!(slot)
        return survived
    end
    slot.worker_items += 1
    return complete_attempt!(run, slot, i, attempt, max_attempts, spec, result, w, start_off, pid, seq)
end

# One attempt at item `i` of an environment the run skips (`skips_environment`): the
# run records the item as skipped itself. No process runs it, so none is started.
function attempt_skipped!(run::Run, _, i::ItemIdx, attempt::Int8, _)
    p = run.plan
    start_off = began!(run, nothing, i, SlotIdx(0), attempt, Int32(0), Int16(0))
    ts = started_testset(p.items.name[i]; verbose = false, at = run.t0 + start_off)
    Test.record(ts, Test.Broken(:skipped, p.items.name[i]))
    ended = time()
    finished_at!(ts, ended)
    printline(run, item_line(run, nothing, i, attempt, (; state = SKIPPED, elapsed_ns = 0, compile_ns = 0, maxrss = 0)))
    record!(run, i, SlotIdx(0), attempt, SKIPPED, ts, RuntestsWorkers.PerfStats(), true,
            start_off, Int32(0), Int16(0),
            string("the run skips ", environment_name(p.profiles[p.items.profile[i]].environment)); ended)
    return true
end

# One attempt at item `i` in this process. There is no second process to kill, so
# nothing times out, and no worker to lose, so the unit always goes on.
function attempt_here!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, max_attempts::Int)
    spec = item_spec(run, i, attempt)
    pid = Int32(getpid())
    hold_item!(slot, i, attempt)
    start_off = began!(run, slot, i, slot.id, attempt, pid, Int16(0))
    printline(run, item_line(run, nothing, i, attempt, nothing))
    res = try
        r = run_item(spec)
        printline(run, item_line(run, nothing, i, attempt, outcome(r)))
        r
    catch e
        is_interrupt(e) && rethrow()
        record_error!(
            run, i, slot, attempt, ERRORED,
            string(sprint(showerror, e), " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues), "in this process")),
            start_off, pid, Int16(0)
        )
        release_item!(slot)
        return true
    end
    return complete_attempt!(run, slot, i, attempt, max_attempts, spec, res, nothing, start_off, pid, Int16(0))
end

# The item on the slot's worker, within the item's limit. Its profile's `test_end`
# runs once the verdict is recorded (`run_test_end!`), against a limit of its own.
function dispatch(run::Run, w::RuntestsWorkers.Worker, spec::ItemSpec, timeout::Int)
    fut = RuntestsWorkers.remote_run(w, spec)
    return fetch_within(fut, timeout, TimeoutException(timeout, "test item", spec.name, timeout_setting(run.plan, spec.index)))::ItemResult
end

"""
    run_test_end!(run, slot, i, attempt, spec, res, w) -> Bool

The `test_end` of item `i`'s profile after attempt `attempt`, whose verdict `res` is
recorded: on worker `w`, within the `test_end_timeout` of the item's package, or in this
process when `w` is `nothing`. It never changes the verdict. A failure, an error or a
timeout is said on a `HOOK` line and written in the attempt's log (`say_test_end`).
Returns whether the worker is still fit to use: one that does not finish in time is
ended, and one that dies is gone.
"""
function run_test_end!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, spec::ItemSpec, res::ItemResult,
                       w::Union{Nothing, RuntestsWorkers.Worker})
    prof = item_profile(run.plan, i)
    (isempty(prof.test_end.args) || res.state === SKIPPED) && return true
    endres = try
        if w === nothing
            RuntestsWorkers.run_test_end(spec, prof.test_end)
        else
            seconds = item_cfg(run.plan, i).test_end_timeout_s
            fetch_within(
                RuntestsWorkers.remote_end(w, spec, prof.test_end), seconds,
                TimeoutException(seconds, "the `test_end` expression of profile `$(prof.name)`", "", "test_end_timeout")
            )::ItemResult
        end
    catch e
        is_interrupt(e) && rethrow()
        return test_end_lost!(run, slot, i, attempt, e, w)
    end
    is_non_pass(endres.state) && say_test_end(run, w === nothing ? nothing : slot.id, i, attempt, test_end_failures(endres.testset)...)
    return true
end

# A `test_end` that did not come back. On a worker past its limit, the worker is ended;
# one that died is gone, and one still fit failed to run or reply. Returns whether the
# worker is still fit to use.
function test_end_lost!(run::Run, slot::Slot, i::ItemIdx, attempt::Int8, e, w::Union{Nothing, RuntestsWorkers.Worker})
    slot_id = w === nothing ? nothing : slot.id
    outcome = resolve_worker_failure!(run, slot, w, e, item_log(run, i, attempt); is_worker = w !== nothing)
    if outcome === :timeout
        say_test_end(run, slot_id, i, attempt, sprint(showerror, e), "")
        return false
    elseif outcome === :alive
        msg = e isa RuntestsWorkers.RemoteException ? e.msg : sprint(showerror, e)
        say_test_end(run, slot_id, i, attempt, string("did not complete: ", first(eachsplit(msg, '\n'))), msg)
        return true
    end
    # A stopped run took the worker away itself: the hook did nothing wrong.
    (stopped_meanwhile(slot) || is_cancelled(run.queues)) && return false
    how = died_how(run, slot, w)
    print_worker_line(run, slot.id, "LOST", string("pid ", w.pid, " · died in the `test_end` after ",
                                                   repr(run.plan.items.name[i]), ": ", how))
    say_test_end(run, slot_id, i, attempt, string("the worker died: ", how), "")
    return false
end

# What a `test_end` that recorded failures or errors says: how many did not pass, with
# the first one's first line, and then all of them.
function test_end_failures(ts::Test.AbstractTestSet)
    failures = collect_failures(ts)
    head = isempty(failures) ? "" : string(": ", first(eachsplit(sprint(show, first(failures)), '\n')))
    return string(length(failures), " did not pass", head), join((sprint(show, r) for r in failures), '\n')
end

# A `test_end` that did not complete cleanly after attempt `attempt` at item `i`: said on
# a `HOOK` line of the slot that ran it, and written with `detail` in the attempt's log.
function say_test_end(run::Run, slot_id, i::ItemIdx, attempt::Int8, cause::AbstractString, detail::AbstractString)
    prof = item_profile(run.plan, i)
    log = item_log(run, i, attempt)
    if !isempty(log)
        try
            mkpath(dirname(log))
            open(log, "a") do io
                println(io, "test_end of profile `", prof.name, "`: ", cause)
                isempty(detail) || println(io, detail)
            end
        catch e
            is_interrupt(e) && rethrow()
            @warn "Runtests: could not write what the `test_end` of profile `$(prof.name)` said to $(log)" exception = e
        end
    end
    print_worker_line(run, slot_id, "HOOK", string(
        "test_end of profile `", prof.name, "` after ", repr(run.plan.items.name[i]),
        attempt > 1 ? string(" (attempt ", attempt, ")") : "", " · ", cause, isempty(detail) || isempty(log) ? "" : " · in its log"))
    return nothing
end

# The same in a session, where an item pasted at the REPL or `debug` prints its own
# result: said under it, and the result stands.
function say_session_test_end(prof::Profile, cause::AbstractString, detail::AbstractString)
    printstyled(stdout, "test_end of profile `", prof.name, "`: ", cause, "\n"; color = Base.warn_color())
    isempty(detail) || println(stdout, detail)
    return nothing
end

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
        max_attempts::Int, start_off::Float32, pid::Int32, seq::Int16
    )
    w = @atomic slot.worker
    item = run.plan.items.name[i]
    # What the monitor saw the attempt's worker and its children hold, taken while the
    # slot and the pid still name the attempt: the worker reports no figures of its own.
    tree = w === nothing ? Int64(0) : attempt_tree_rss(run.monitor, slot.id, i, attempt, w.pid)
    peak_rss = tree > 0 ? tree : nothing
    ended = time()   # the item held its worker until here; inspecting/reaping is ours
    activity = Ref("")
    outcome = resolve_worker_failure!(run, slot, w, e, item_log(run, i, attempt); is_worker = true, activity_out = activity)
    if outcome === :timeout
        stopped_meanwhile(slot) && return false
        artifacts = evidence_after_loss!(run, i, attempt, sprint(showerror, e))
        act_note = isempty(activity[]) ? "" : string(" · ", activity[])
        record_error!(
            run, i, slot, attempt, TIMEDOUT,
            string(sprint(showerror, e), act_note, " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues), "on a new worker")),
            start_off, pid, seq; ended, artifacts, peak_rss
        )
        return false
    elseif outcome === :alive
        # The request failed but the process is fine (e.g. a result that would not
        # serialize). The worker keeps everything it has compiled, and the item is an
        # ordinary error. If the attempt registered `on_failure` producers before its
        # reply was lost, run them now.
        dir = attempt_artifacts(run, i, attempt)
        flags = isempty(dir) ? 0x00 :
            ((isdir(dir) ? ARTIFACT_FILES : 0x00) | (isfile(artifacts_log_path(dir)) ? ARTIFACT_PRODUCERS : 0x00))
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e), start_off, pid, seq; artifacts = flags, peak_rss)
        release_item!(slot)
        flags == 0 && return true
        return collect_failed_evidence!(run, slot, i, attempt, flags, w)
    end
    # Whatever took the worker recorded the item already (`record_stopped_item!`).
    stopped_meanwhile(slot) && return false
    how = ""
    if w !== nothing
        how = died_how(run, slot, w)
        print_worker_line(run, slot.id, "LOST", string("pid ", w.pid, " · died while running ", repr(item), ": ", how))
    end
    # A stopped run took this worker away itself: the item neither failed nor
    # ran, and is counted with the ones that never started.
    if is_cancelled(run.queues)
        record_error!(run, i, slot, attempt, CANCELLED, "the run was stopped", start_off, pid, seq; ended, peak_rss)
    else
        what = e isa RuntestsWorkers.WorkerTerminatedException ?
            string("the worker running this item died: ", how) : sprint(showerror, e)
        artifacts = evidence_after_loss!(run, i, attempt, what)
        record_error!(
            run, i, slot, attempt, ERRORED,
            string(what, " · ", retry_note(attempt, max_attempts, false, "on a new worker")),
            start_off, pid, seq; ended, artifacts, peak_rss
        )
    end
    return false
end

# The profile of item `i`'s own unit. A pool's workers start with the configuration
# of one of its profiles, which every profile of the pool shares; what differs between
# them, `test_end` and the name an item sees, is the item's own.
item_profile(p::Plan, i::Integer) = p.profiles[p.items.profile[i]]

function item_spec(run::Run, i::ItemIdx, attempt::Int8)
    p = run.plan
    # The directory is this run's own and (item, attempt) is unique within it, so
    # nothing is there to clear first.
    logpath = p.cfg.logs === :eager ? "" : item_log(run, i, attempt)
    return ItemSpec(
        i, p.items.name[i], p.files[p.items.fileidx[i]], p.items.line[i],
        p.items.code[i], p.items.skip[i], item_failfast(p, i),
        is_combined(p) ? p.packages.name[p.items.package[i]] : run.project_name,
        item_profile(p, i).name, attempt, p.cfg.full_stacktraces, logpath,
        item_seed(p.items.seed[i], p.packages.name[p.items.package[i]], p.items.name[i]),
        attempt_artifacts(run, i, attempt), item_root(p, i)
    )
end

# The directory item `i` runs in, with its `skip`, `test_end` and failure producers:
# the root of its package, whichever process runs it, so that a relative path means
# the same in this process as on a worker, and in a combined run as in the package's own.
item_root(p::Plan, i::Integer) = p.packages.root[p.items.package[i]]

# The run's seed, the name of the item's package ("" when its project has none) and
# the item's name, mixed so that each item draws its own numbers whatever ran before
# it in the same process, and the same numbers in its package's own run as in a
# combined run. A package name holds no NUL, so the NUL keeps package "A" with item
# "BC" apart from "AB" with "C". CRC32c rather than `hash`, which may change between
# Julia versions and would make a recorded seed mean something else.
item_seed(seed::UInt64, package::AbstractString, name::AbstractString) =
    seed ⊻ (UInt64(crc32c(name, crc32c("\0", crc32c(package)))) * 0x9e3779b97f4a7c15)

    # Whether a failure of item `i` stops the item at its first failing test: its own
    # `failfast`, or else its package's `item_failfast`.
item_failfast(p::Plan, i::Integer) = p.items.failfast[i] == -1 ? item_cfg(p, i).item_failfast : p.items.failfast[i] == 1

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

# Why attempt `attempt` at item `i` was skipped, in its log: the run's `note`, as for an
# environment the run skips, or else the item's own `skip`.
function note_skip(run::Run, i::ItemIdx, attempt::Int8, note::AbstractString)
    log = item_log(run, i, attempt)
    isempty(log) && return nothing
    skip = run.plan.items.skip[i]
    why = !isempty(note) ? note : skip === true ? "`skip = true`" :
        string("its `skip` expression, `", skip isa Expr ? expr_text(skip) : string(skip), "`, was true")
    try
        open(io -> println(io, "skipped: ", why), log, "a")
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

"""
    record!(run, i, slot, attempt, state, testset, stats, synthetic, start_off, pid, seq, note)

Everything that follows from one attempt's outcome, in one place: the item's
status in memory and on disk, the count of finished items, and the item's report.
`synthetic` says the run decided the outcome rather than the item — a timeout, a
dead worker, a stopped run — and `testset` then holds a single error saying so.
The run state has the outcome before anything is told of it (`persist_attempt!`): the
report, an editor and `on_event` can each stop the run.
"""
function record!(
        run::Run, i::ItemIdx, slot::SlotIdx, attempt::Int8, state::ItemState,
        testset::Test.AbstractTestSet, stats::RuntestsWorkers.PerfStats, synthetic::Bool,
        start_off::Float32, pid::Int32, seq::Int16, note::AbstractString;
        ended::Float64 = time(), artifacts::UInt8 = 0x00, peak_rss::Union{Nothing, Int64} = nothing
    )
    o = persist_attempt!(run, i, slot, attempt, state, testset, stats, synthetic, start_off, pid, seq, note;
                         ended, artifacts, peak_rss)
    observe_attempt!(run, o)
    return nothing
end

# Everything that is told of an attempt once it is recorded: the report, the attempt's
# log for a skip, `on_event` and an editor.
function observe_attempt!(run::Run, o::AttemptOutcome)
    report_item!(run, o)
    # After the item's report, which shows its log: the reason is for whoever reads
    # the run's directory later, and a skip has no block to show it in.
    o.state === SKIPPED && note_skip(run, o.i, o.attempt, o.note)
    log_path = item_log(run, o.i, max(o.attempt, 1))
    log = isfile(log_path) && filesize(log_path) > 0 ? log_path : ""
    art = is_non_pass(o.state) && o.artifacts != 0 ? attempt_artifacts(run, o.i, max(o.attempt, 1)) : ""
    tell_on_event(run, o.i, :finished, o.state, o.attempt, o.slot, o.pid, o.ended, o.elapsed, o.stats, !o.synthetic;
                  log, artifacts = art)
    run.events === nothing || event_item_finished(run, o)
    return nothing
end

"""
    persist_attempt!(run, i, slot, attempt, state, testset, stats, synthetic, start_off, pid, seq, note;
                     ended, artifacts, peak_rss) -> AttemptOutcome

An attempt's outcome in the statuses and in the run state: its status row and its
attempt event. A skip or a cancel after an attempt that decided the item leaves
`Statuses[i]` untouched and restores its status row in the run state (overwriting the
`RUNNING` marker written by `began!`). Takes no lock that reporting does, so the exit
hook can use it.
"""
function persist_attempt!(
        run::Run, i::ItemIdx, slot::SlotIdx, attempt::Int8, state::ItemState,
        testset::Test.AbstractTestSet, stats::RuntestsWorkers.PerfStats, synthetic::Bool,
        start_off::Float32, pid::Int32, seq::Int16, note::AbstractString;
        ended::Float64 = time(), artifacts::UInt8 = 0x00, peak_rss::Union{Nothing, Int64} = nothing
    )
    (state === UNSEEN || state === RUNNING) && error("Runtests internal error: item $i recorded as $state")
    st = run.statuses
    st.recorded[i] = attempt
    # An outcome the item reported took what the item measured; one the run decided
    # took as long as the item held its worker.
    elapsed = synthetic ? max(0.0, ended - run.t0 - start_off) : stats.elapsed_ns / 1.0e9
    compile = Float32(stats.compile_ns / 1.0e9)
    recompile = Float32(stats.recompile_ns / 1.0e9)
    alloc_mb = Float32(stats.bytes / 2^20)
    rss_mb = Float32(something(peak_rss, Int64(stats.maxrss)) / 2^20)
    # What the run prints of a failure, kept beside the item's output for whoever
    # reads the run state later; a cancel or a skip has nothing of its own to say.
    is_non_pass(state) && state !== CANCELLED && write_failure_report(run, i, attempt, testset)
    # Commit to `Statuses[i]` unless an earlier attempt already decided this item and
    # this attempt decided nothing (skip/cancel).
    if is_decisive(state) || !is_decisive(st.state[i])
        set_state!(run, i, state)
        st.synthetic[i] = synthetic
        st.artifacts[i] = artifacts
        st.attempt[i] = attempt
        st.slot[i] = slot
        st.pid[i] = pid
        st.seq[i] = seq
        st.start[i] = start_off
        st.elapsed[i] = Float32(elapsed)
        st.compile[i] = compile
        st.recompile[i] = recompile
        st.alloc_mb[i] = alloc_mb
        st.rss_mb[i] = rss_mb
        st.testsets[i] = testset
    end
    write_status!(
        run.runstate, i, st.state[i], st.attempt[i], st.slot[i];
        start_off = st.start[i], elapsed = st.elapsed[i], compile = st.compile[i],
        recompile = st.recompile[i], alloc_mb = st.alloc_mb[i], peak_rss_mb = st.rss_mb[i], pid = st.pid[i]
    )
    append_event!(run.runstate, EVENT_ATTEMPT, UInt8(state), slot, pid, start_off, ended - run.t0;
                  item = i, attempt, seq, compile, recompile, alloc_mb, peak_rss_mb = rss_mb)
    @atomic run.last_finish = time()
    n = count_done!(run, i)
    return AttemptOutcome(i, slot, attempt, state, st.state[i], pid, elapsed, stats, testset,
                          synthetic, artifacts, String(note), ended, n)
end

"""
    TestItemEvent

The event passed to `on_event` by `runtests` or `runtests_mono`, in this process:
once as an attempt at a test item starts, `kind = :started`, and once as it ends,
`kind = :finished`. A retry is another attempt, with a call of each.

It says which item it is (`name`, `file`, `line`, `attempt`, and the `package` and
`root` of its suite), where it ran (`worker`, numbered as the run's lines number
them, `w1`, and `pid`, its process), when it started or ended (`time`, as `time()`
gives it), and how it went (`state`: `:running`
as it starts, and then `:passed`, `:failed`, `:errored`, `:timedout`, `:skipped` or
`:cancelled`). `pid` is 0 when no process ran the attempt: the run could not start a
worker for it, or it is an item of an environment the run skips, which has `worker`
0 as well.

As it ends, it says what the attempt cost: `elapsed`, `cpu` (user and system time),
`compile`, `recompile` (of `compile`) and `gc` in seconds, `allocated` in bytes,
`allocations`, how many there were, and `maxrss`, the largest its process has been
resident so far, in bytes. Every figure but `elapsed` is the whole process's,
which runs one item at a time: its worker's, or with `workers = 0` this process's.
`measured` says the item measured them itself.
It is `false` as an attempt starts, and as it ends when the run decided the outcome,
as for a timeout, a lost worker or a stopped run: the figures are
then 0, and `elapsed` is how long the attempt held its worker.

`events_dir` is a directory for files that the function writes: `events` in the
directory of the run of the item's package, next to the run's record and logs. The
files go where that directory goes: `RUNTESTS_ARTIFACT_DIR` copies them, and retention
deletes them with the run. The run makes the directory only when it is given a function.

On `kind = :finished`, `log` is the attempt's log file when the attempt wrote one (empty
otherwise), and `artifacts` is the attempt's evidence directory when a failed attempt
kept files or registered producers (empty otherwise; `on_failure` producers run right
after `on_event` returns). Both are empty on `kind = :started`.
"""
struct TestItemEvent
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
    events_dir::String
    log::String
    artifacts::String
end

# Where the caller's `on_event` keeps files for package `k` of the run: beside its logs.
events_dir(run::Run, k::Integer) = joinpath(run.logdirs[k], "events")

# The caller's `on_event` with one attempt's event, which is built only when there is
# a function to call. A call that throws is reported and is the last: the function
# is the caller's code, and a run goes on whatever its observer does.
function tell_on_event(
        run::Run, i::ItemIdx, kind::Symbol, state::ItemState, attempt::Int8, slot::Integer, pid::Integer,
        at::Float64, elapsed::Float64, stats::RuntestsWorkers.PerfStats, measured::Bool;
        log::String = "", artifacts::String = ""
    )
    (@atomic run.on_event) === nothing && return nothing
    p = run.plan
    event = TestItemEvent(
        kind, p.items.name[i], p.files[p.items.fileidx[i]], p.items.line[i], attempt, slot, pid,
        at, Symbol(state_name(state)), measured, elapsed, stats.cpu_ns / 1.0e9, stats.compile_ns / 1.0e9,
        stats.recompile_ns / 1.0e9, stats.gc_ns / 1.0e9, stats.bytes, stats.allocs, stats.maxrss,
        p.packages.name[p.items.package[i]], p.packages.root[p.items.package[i]], events_dir(run, p.items.package[i]),
        log, artifacts
    )
    @lock run.on_event_lock begin
        # Read again: a call another task made while this one waited may have failed.
        f = @atomic run.on_event
        f === nothing && return nothing
        try
            f(event)
        catch e
            is_interrupt(e) && rethrow()
            @atomic run.on_event = nothing
            @error "Runtests: `on_event` threw for $(repr(event.name)), and is not called again in this run; the tests carry on" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

# The body's outcome, in the statuses and the run state, as soon as the body ended. What
# is told of it (`observe_attempt!`) waits for the profile's `test_end`, which writes to
# the attempt's log as well.
function persist_result!(
        run::Run, i::ItemIdx, slot::Slot, attempt::Int8, res::ItemResult,
        start_off::Float32, pid::Int32, seq::Int16, max_attempts::Int = 1
    )
    # Only worth saying when there is a policy to state: a plain failure with no
    # retries configured explains itself.
    note = (is_non_pass(res.state) && max_attempts > 1) ?
        retry_note(attempt, max_attempts, is_cancelled(run.queues), next_attempt_where(run.plan, i)) : ""
    ended = time()
    w = @atomic slot.worker
    tree = w === nothing ? Int64(0) : attempt_tree_rss(run.monitor, slot.id, i, attempt, w.pid)
    return persist_attempt!(run, i, slot.id, attempt, res.state, res.testset, res.stats, false,
                            start_off, pid, seq, note;
                            ended, artifacts = res.artifacts, peak_rss = tree > 0 ? tree : nothing)
end

# Where a unit's next attempt runs after one that failed with its process intact: a
# sandbox's process runs one unit and goes, while a pool worker, and this process,
# carry on with the next attempt.
next_attempt_where(p::Plan, i::ItemIdx) =
    p.items.exclusive[i] ? "on a new worker" :
    single_process(p) && !needs_worker(p, i) ? "in this process" : "on the same worker"

# `peak_rss`: what the monitor sampled of the attempt, which no worker reported.
record_error!(run::Run, i::ItemIdx, slot::Slot, attempt::Int8, state::ItemState, msg::AbstractString,
              start_off::Float32, pid::Int32, seq::Int16;
              ended::Float64 = time(), artifacts::UInt8 = 0x00, peak_rss::Union{Nothing, Int64} = nothing) =
    record!(run, i, slot.id, attempt, state, error_testset(run, i, msg, start_off, ended),
            RuntestsWorkers.PerfStats(), true, start_off, pid, seq, msg; ended, artifacts, peak_rss)

# The testset of an outcome the run decided: one error saying why, at the item's
# own line, so the summary and the verdict count it like any other error.
function error_testset(run::Run, i::ItemIdx, msg::AbstractString, start_off::Float32, ended::Float64)
    p = run.plan
    ts = started_testset(p.items.name[i]; verbose = false, at = run.t0 + start_off)
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

### In-process mode ########################################################

# The default profile's `init`, which readies this process for the items that run in it
# (`workers = 0`). When every item gets a worker, as one in an environment directory
# does, each worker runs its own `init` where its items run, and this process has none to
# run. Part of setup: one that throws ends the run before its first item.
function init_in_process!(run::Run)
    p = run.plan
    any(i -> !needs_worker(p, i), ItemIdx(1):ItemIdx(nitems(p))) || return nothing
    isempty(p.profiles[1].init.args) && return nothing
    @warn "Runtests: the profile's `init` expression is evaluated in this process (workers=0)"
    # In the directory a worker of the profile would evaluate it in.
    cd(() -> Core.eval(Main, Expr(:block, p.profiles[1].init.args...)), init_dir(p.profiles[1], p.packages.root[1]))
    return nothing
end

function run_in_process(run::Run)
    p = run.plan
    @lock run.lock push!(run.tasks, current_task())
    slot = run.slots[1]
    # Every item, not just the one slot's queue: a pool that would have had a
    # worker of its own has none here, and its items still have to run. Under exact
    # replay, follow the recorded slot sequence (`p.replay_slots[1]`).
    order = isempty(p.replay_slots) ? (ItemIdx(1):ItemIdx(nitems(p))) : p.replay_slots[1]
    for i in order
        is_cancelled(run.queues) && break
        # An item that asked for a process gets one here too — `run_item_once!`
        # decides which do — started and stopped around it.
        slot.profile = p.items.profile[i]
        try
            run_item!(run, slot, i)
        finally
            stop_worker!(run, slot)
        end
    end
    check_finished(run)
    return nothing
end
