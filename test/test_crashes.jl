# A worker process can die at any point a worker does anything: while evaluating a
# profile's `init` expression, while running an item, and while running the
# profile's `test_end` expression. None of those may lose the run, and each has to
# say which of the three it was.

using Runtests.Private: PASSED, FAILED, ERRORED, TIMEDOUT, UNSEEN, CANCELLED, ItemState, history, read_run_state, nitems

# Code that kills the process where it stands the first `n` times it is reached,
# counting in the file `RUNTESTS_CRASH_MARKER` names.
crash_until(n) = string(
    "let p = ENV[\"RUNTESTS_CRASH_MARKER\"]; ",
    "k = isfile(p) ? parse(Int, read(p, String)) : 0; write(p, string(k + 1)); ",
    "k < ", n, " && ccall(:abort, Cvoid, ()); end"
)

# The files of the default profile, with that code as its `init` or its `test_end`.
init_crashes(n) = profile_files(; init = crash_until(n))
end_crashes(n) = profile_files(; test_end = crash_until(n))

const ONE_ITEM = """
@testitem "the item" begin
    @test true
end
"""

@testset "crashes" begin
    @testset "a worker that dies says how its process ended" begin
        with_runstate_dir() do dir
            (states, _, _), out = capture_run() do
                run_states(fixture("Faulty.jl"); workers=1, tags=nothing, name=Set(["kills its worker"]),
                           logs=:issues, monitor=false)
            end
            @test states["kills its worker"] === ERRORED
            @test occursin("died while running \"kills its worker\": exited with code 7", out)
            @test occursin("the worker running this item died: exited with code 7", out)
            rs = read_run_state(only(records_in(dir)))
            down = only(e for e in rs.events if e.kind === :worker_down)
            @test down.ended_by in (:connection_lost, :process_exit)
            @test (down.exitcode, down.signal) == (7, 0)
            @test only(e for e in rs.events if e.kind === :attempt).pid == down.pid == only(rs.statuses).pid
        end
    end

    if !Sys.iswindows()
        @testset "what an item printed survives its worker being killed" begin
            dir = make_pkg("KilledMidway", "test/k_test.jl" => """
            @testitem "killed" begin
                println("the last line before the kill")
                run(`kill -9 \$(getpid())`)
                sleep(10)
            end
            """)
            (states, _, _), out = capture_run() do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            @test states["killed"] === ERRORED
            @test occursin("the last line before the kill", out)
            @test occursin("killed by signal 9", out)
            @test occursin("which nothing in this run sent", out)
        end
    end

    @testset "a worker that dies in its init expression is replaced" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("FlakyInit", "test/t_test.jl" => ONE_ITEM,
                           init_crashes(2)...)
            states, _, _ = withenv("RUNTESTS_CRASH_MARKER" => marker) do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            @test states["the item"] === PASSED
            # Two processes died in `init` and the third came up: a worker that
            # dies is a worker to replace, not a reason to stop.
            @test parse(Int, read(marker, String)) == 3
        end
    end

    @testset "an init expression that always kills its worker stops the run" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("DeadInit", "test/t_test.jl" => ONE_ITEM,
                           init_crashes(99)...)
            (states, _, _), out = withenv("RUNTESTS_CRASH_MARKER" => marker) do
                capture_run() do
                    run_states(dir; workers=1, logs=:issues, monitor=false)
                end
            end
            @test states["the item"] === ERRORED
            @test occursin("could not start a worker for profile `default`", out)
            @test occursin("after 3 attempts", out)
            # Tried three times and then stopped, rather than once per item forever.
            @test parse(Int, read(marker, String)) == 3
        end
    end

    @testset "a worker that dies in test_end is the test_end's fault, not the item's" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("DeadEnd", "test/t_test.jl" => ONE_ITEM,
                           end_crashes(99)...)
            (states, run, _), out = withenv("RUNTESTS_CRASH_MARKER" => marker) do
                capture_run() do
                    run_states(dir; workers=1, logs=:issues, monitor=false, retries=1)
                end
            end
            # The item ran and passed: that is its verdict, and nothing retries it. The
            # hook that took its worker has lines of its own.
            @test states["the item"] === PASSED
            @test run.statuses.attempt[1] == 1
            @test occursin("died in the `test_end` after \"the item\"", out)
            @test occursin(r"HOOK · test_end of profile `default` after \"the item\" · the worker died", out)
            @test !occursin("the worker running this item died", out)
        end
    end

    @testset "a test_end that dies still leaves the other items runnable" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("HalfDeadEnd", "test/t_test.jl" => """
            @testitem "first" begin
                @test true
            end
            @testitem "second" begin
                @test true
            end
            """, end_crashes(1)...)
            states, _, _ = withenv("RUNTESTS_CRASH_MARKER" => marker) do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            # The first item's hook lost its worker, which its verdict does not show; the
            # other ran on the replacement.
            @test all(==(PASSED), values(states))
        end
    end

    @testset "the run state survives a worker dying" begin
        with_runstate_dir() do _
            dir = make_pkg("DeadItem", "test/t_test.jl" => """
            @testitem "aborts" begin
                ccall(:abort, Cvoid, ())
            end
            @testitem "fine" begin
                @test true
            end
            """)
            states, run, p = run_states(dir; workers=1, logs=:issues, monitor=false)
            rs = read_run_state(run.runstate.path)
            @test rs !== nothing
            @test rs.complete
            @test !rs.cancelled
            @test !rs.truncated
            @test length(rs.statuses) == nitems(p)
            # What the file says matches what the run recorded, item for item.
            for (i, it) in enumerate(rs.items)
                @test rs.statuses[i].state === states[it.name]
            end
        end
    end

    @testset "an attempt whose worker dies or is stopped keeps the memory the monitor saw of it" begin
        dir = make_pkg("HeldMemory", "test/t_test.jl" => """
        @testitem "dies holding memory" begin
            wait_s = parse(Float64, get(ENV, "RUNTESTS_HELD_WAIT", "1.0"))
            wait_s > 0 && (x = ones(UInt8, 200 * 2^20); sleep(wait_s))
            ccall(:abort, Cvoid, ())
        end
        @testitem "times out holding memory" timeout=3 begin
            wait_s = parse(Float64, get(ENV, "RUNTESTS_HELD_WAIT", "1.0"))
            wait_s > 0 && (x = ones(UInt8, 200 * 2^20))
            sleep(60)
        end
        """)
        with_runstate_dir() do _
            for monitor in (true, false)
                states, run, p = with_fast_inspect() do
                    withenv("RUNTESTS_HELD_WAIT" => monitor ? "1.0" : "0.0") do
                        run_states(dir; workers=2, logs=:issues, monitor)
                    end
                end
                @test states["dies holding memory"] === ERRORED && states["times out holding memory"] === TIMEDOUT
                rs = read_run_state(run.runstate.path)
                for name in ("dies holding memory", "times out holding memory")
                    i = findfirst(==(name), p.items.name)
                    event = only(e for e in rs.events if e.kind === :attempt && e.item == i)
                    # The monitor's sample, in the statuses and the run state; without a
                    # monitor nothing was sampled, and nothing is made up.
                    if monitor
                        @test run.statuses.rss_mb[i] > 150 && event.peak_rss_mb > 150
                    else
                        @test run.statuses.rss_mb[i] == 0 && event.peak_rss_mb == 0
                    end
                end
            end
        end
    end

    @testset "failfast is recorded as a cancellation, and everything it did not reach is retried" begin
        with_runstate_dir() do _
            dir = make_pkg("FailFast",
                "test/TestItems.toml" => "[order]\nfirst = [\"a fails\"]\n",
                "test/t_test.jl" => """
            @testitem "a fails" begin
                @test 1 == 2
            end
            @testitem "b never runs" begin
                @test true
            end
            @testitem "c never runs" begin
                @test true
            end
            """)
            states, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false, failfast=true)
            @test states["a fails"] === FAILED
            rs = read_run_state(run.runstate.path)
            @test rs.complete
            @test rs.cancelled   # one flag reinterprets every item that has no result
            # The items that never ran are not passes, and after a run that stopped
            # early they are what to run again.
            unrun = [it.name for (i, it) in enumerate(rs.items)
                     if rs.statuses[i].state === UNSEEN || rs.statuses[i].state === CANCELLED]
            @test length(unrun) == 2
            h = history(dir; nruns=1)
            # The failure and the items that never got a turn, all of them.
            @test haskey(h.failed, "a fails")
            @test haskey(h.failed, "b never runs")
            @test haskey(h.failed, "c never runs")
        end
    end

    @testset "a run that finishes is not recorded as cancelled" begin
        with_runstate_dir() do _
            dir = make_pkg("Complete", "test/t_test.jl" => ONE_ITEM)
            _, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            rs = read_run_state(run.runstate.path)
            @test rs.complete
            @test !rs.cancelled
            # Stamped when it started and again when it finished, in that order.
            @test 0 < rs.start_unix <= rs.end_unix
            # From the moment every offset in it counts from, so the start plus an
            # attempt's offset is when that attempt began.
            @test rs.start_unix == run.t0
        end
    end

    @testset "a run state that cannot be written is done without" begin
        # A directory beneath an ordinary file cannot be created on any platform.
        blocker = touch(tempname())
        try
            dir = make_pkg("NoRunState", "test/t_test.jl" => ONE_ITEM)
            # Said through the run's own printer, like every record raised during a run.
            (states, run, _), out = withenv("RUNTESTS_RUNSTATE_DIR" => joinpath(blocker, "runs")) do
                capture_run(() -> run_states(dir; workers=0, logs=:issues, monitor=false))
            end
            @test occursin("could not open a run state", out)
            @test run.runstate === nothing
            @test states["the item"] === PASSED
        finally
            rm(blocker; force=true)
        end
    end
end

# The checkout, for a child process that has to find the same one.
const REPO_ROOT = dirname(@__DIR__)

# Forward the temp test depot and offline flag so child coordinators neither pollute
# `~/.julia/compiled/` nor talk to registries.
function child_env(extra::Pair{String, String}...)
    env = Pair{String, String}[extra...]
    for k in ("JULIA_DEPOT_PATH", "JULIA_PKG_OFFLINE")
        haskey(ENV, k) && push!(env, k => ENV[k])
    end
    return env
end

# One shared package for every `interrupted_run` subprocess so the package is compiled
# once in the temp depot rather than rebuilt from scratch on every signal test.
const INTERRUPTED_PKG = make_pkg("Interrupted", "test/t_test.jl" => join(
    ["""
    @testitem "slow $i" begin
        touch(joinpath(ENV["RUNTESTS_READY_DIR"], "ready$i"))
        if get(ENV, "RUNTESTS_CUT", "") == "1"
            for fd in 3:1023
                ccall(:shutdown, Cint, (Cint, Cint), fd, 2)
            end
        end
        sleep(600)
        @test true
    end
    """ for i in 1:4], "\n"))

# Windows has no signal to send: `kill` there terminates the process outright, so
# there is no teardown to watch.

"""
    interrupted_run(; items, julia_args, monitor, delay, repl, cut) -> NamedTuple

Run `items` items that each sleep for ten minutes, on as many workers, in a
coordinator of its own started with `julia_args`, and send it SIGINT `delay` seconds
after every item is running, and again 15 seconds later should it still be running.
With `repl`, the coordinator raises the interrupt as a
REPL does; without, it exits on it, as a script and `Pkg.test` do. With `cut`, each
item first cuts its worker's connection to the coordinator and goes on sleeping, so
the interrupt finds every slot waiting for a worker it has lost. Returns whether
the items got running, how long the coordinator took to end, what it printed and
said on stderr, and the pids of the workers it started.
"""
function interrupted_run(; items = 4, julia_args = String[], monitor = false, delay, repl = true, cut = false)
    tmp = mktempdir()
    ready = joinpath(tmp, "ready")
    ignored = joinpath(tmp, "sigint_ignored")
    selected = Set(["slow $i" for i in 1:items])
    script = """
    # Julia 1.11 and 1.12 on macOS can come up ignoring SIGINT: its signal thread sets
    # it to SIG_IGN, racing the handler the main thread installs, and when it lands
    # second the runtime drops every Ctrl-C before any Julia code sees it (fixed in 1.13
    # by JuliaLang/julia#62471). Looked at before Runtests is loaded, and again just
    # before the run: on a busy machine the signal thread can land seconds late.
    # Runtests never changes how SIGINT is handled.
    function sigint_ignored()
        act = zeros(UInt8, 256)   # a `struct sigaction`, whose first field is the handler
        ccall(:sigaction, Cint, (Cint, Ptr{Cvoid}, Ptr{UInt8}), 2, C_NULL, act) == 0 || error("sigaction")
        return reinterpret(UInt, act[1:sizeof(UInt)])[1] == 1
    end
    sigint_ignored() && (touch($(repr(ignored))); exit())
    # A script exits on SIGINT unless told otherwise; a REPL raises it.
    $(repl ? "Base.exit_on_sigint(false)" : "")
    using Runtests
    include(joinpath($(repr(REPO_ROOT)), "test", "helpers.jl"))
    const FIXTURES = joinpath($(repr(REPO_ROOT)), "test", "testfixtures")
    fixture(name) = joinpath(FIXTURES, name)
    sigint_ignored() && (touch($(repr(ignored))); exit())
    # From 1.14 Ctrl-C cancels this script's scope, where every later wait throws
    # again: what it says afterwards is said shielded.
    try
        run_states($(repr(INTERRUPTED_PKG)); workers=$items, name=$(repr(selected)), logs=:issues, monitor=$monitor)
    catch e
        RuntestsWorkers.shielded(() -> println(stderr, "CAUGHT \$(typeof(e))"))
    end
    RuntestsWorkers.shielded() do
        alive_count() = @lock RuntestsWorkers.LIVE_LOCK count(Base.process_running, RuntestsWorkers.LIVE_PROCESSES)
        timedwait(() -> alive_count() == 0, 5.0)
        println(stderr, "ALIVE \$(alive_count())")
    end
    """
    path, io = mktemp()
    write(io, script)
    close(io)
    # The items say when they are running, so the interrupt lands with all of them
    # mid-item: not during an environment build that can take minutes, and not
    # while a worker is still starting and has yet to print the pid looked for below.
    running() = all(i -> isfile(ready * string(i)), 1:items)
    deadline = time() + 300
    # A coordinator that came up ignoring SIGINT is started again, until the deadline:
    # the runtime, not the run, is what would lose its Ctrl-C. On a machine with many
    # more busy processes than CPUs, Julia 1.11 and 1.12 lose that race most times,
    # and an attempt that loses it at once ends before it loads Runtests.
    local proc, err, log
    attempts = 0
    while true
        attempts += 1
        err = Base.BufferStream()
        log = Base.BufferStream()
        proc = run(pipeline(
            setenv(`$(Base.julia_cmd()) $julia_args --project=$(REPO_ROOT) --startup-file=no $path`,
                   child_env(
                       "JULIA_LOAD_PATH" => string(REPO_ROOT, ":", joinpath(REPO_ROOT, "test"), ":"),
                       "RUNTESTS_RUNSTATE_DIR" => mktempdir(),
                       "RUNTESTS_READY_DIR" => dirname(ready),
                       "RUNTESTS_CUT" => cut ? "1" : "0",
                   )...),
            stdout = log, stderr = err,
        ); wait = false)
        while time() < deadline && process_running(proc) && !running()
            sleep(0.1)
        end
        isfile(ignored) || break
        wait(proc)
        rm(ignored)
        time() < deadline ||
            error("Julia $VERSION came up ignoring SIGINT on all $attempts attempts before the deadline: JuliaLang/julia#62471")
    end
    got_running = running()
    sleep(delay)
    t0 = time()
    kill(proc, Base.SIGINT)
    # Pressed again when nothing has come of it, as a person would: under load, Julia
    # can leave a Ctrl-C undelivered, with every task of the run still waiting where
    # it waits and none of them handed the interrupt. The second press reaches the
    # run through the same tasks, and the time is still counted from the first.
    again = timedwait(() -> process_exited(proc), 15) !== :ok
    again && kill(proc, Base.SIGINT)
    # Bounded: an interrupt that is lost would hold the test for the items' ten
    # minutes, and the time it took is what is checked. SIGQUIT first, on which Julia
    # prints every task's backtrace to stderr, which is said below. The workers go
    # too, by process group: each is in a group of its own, holds the coordinator's
    # stderr, and would keep the output from ending until its item did. They are
    # found as the coordinator's children, so while it is still there.
    hung = timedwait(() -> process_exited(proc), 105) !== :ok
    if hung
        workers = [parse(Cint, l) for l in readlines(ignorestatus(`pgrep -P $(getpid(proc))`))]
        kill(proc, 3)
        timedwait(() -> process_exited(proc), 5)
        foreach(w -> ccall(:kill, Cint, (Cint, Cint), -w, 9), workers)
        process_running(proc) && kill(proc, Base.SIGKILL)
    end
    wait(proc)
    elapsed = time() - t0
    close(err)
    close(log)
    out = read(err, String)
    printed = read(log, String)
    again && !hung && @warn "the coordinator did nothing on the first Ctrl-C for 15s, and ended on the second"
    hung && @warn "the coordinator did not end on Ctrl-C; its stderr:\n$out"
    started = [parse(Int, m.captures[1]) for l in worker_lines(printed) for m in eachmatch(r"· pid (\d+)", l)]
    rm(path; force=true)
    return (; got_running, elapsed, out, printed, started)
end

# What the coordinator catches: an `InterruptException`, or from 1.14 the
# `CancellationRequest` that Ctrl-C has become.
const CAUGHT_INTERRUPT = r"CAUGHT (InterruptException|(Base\.)?CancellationRequest)$"m

Sys.iswindows() ||
@testset "an interrupt takes the workers with it, at once" begin
    # Ctrl-C is someone asking for their terminal back: the run goes down without
    # waiting for the item each slot has in flight, which here sleeps for ten
    # minutes. A real interrupt comes long after the stall watchdog first looked:
    # it has to reach the run whatever has run by then.
    r = interrupted_run(; items = 4, delay = Runtests.Private.STALL_CHECK_S + 1)
    @test r.got_running
    # Generously above the second it takes, and far below the ten minutes an item
    # here sleeps for: what is checked is that it does not wait for them.
    @test r.elapsed < 30
    @test length(r.started) == 4
    @test all_gone(r.started)
    # The report never happens — the exception takes the run out before it — so the
    # run says what it got through on its way past. The items it took a worker away
    # from did not fail and are counted, not reported one by one. On 1.12 nothing
    # unwinds to say this, and the exit hook is what says it instead.
    @test occursin("interrupted after 0 of 4 test items", r.printed)
    @test occursin("4 cancelled", r.printed)
    @test !occursin("the worker running this item died", r.printed)
    @test !occursin("ERR ", r.printed)
    # The run itself sees the exception from 1.13. On 1.12 it is delivered to
    # whichever task thread 1 is running, which between items is one that has
    # already finished and has nothing left to catch it; the process dies there.
    if VERSION >= v"1.13"
        @test occursin(CAUGHT_INTERRUPT, r.out)
        @test occursin("ALIVE 0", r.out)
    end
end

Sys.iswindows() ||
@testset "an interrupt reaches the run whichever of its tasks catches it" begin
    # Without an interactive thread every task the run starts shares the thread
    # Ctrl-C is thrown into: the monitor's, which wakes five times a second, or
    # with no monitor a worker's output relay or message reader. Sent a second
    # after the items start, before the stall watchdog first looks.
    for monitor in (true, false)
        # No interactive thread: Julia 1.11 has none unless asked, and refuses a count of
        # zero; from 1.12 there is one unless the count says zero.
        r = interrupted_run(; items = 2, julia_args = [VERSION >= v"1.12" ? "--threads=1,0" : "--threads=1"], monitor, delay = 0.3)
        @test r.got_running
        @test r.elapsed < 30
        @test all_gone(r.started)
        @test occursin("interrupted after 0 of 2 test items", r.printed)
        @test !occursin("could not relay", r.printed * r.out)
        @test !occursin("resource monitor stopped", r.printed * r.out)
        VERSION >= v"1.13" && @test occursin(CAUGHT_INTERRUPT, r.out)
    end
end

Sys.iswindows() ||
@testset "an interrupt while a slot waits for its lost worker counts the item as cancelled" begin
    # A worker whose connection is gone is given a few seconds to exit before it is
    # signalled, and its slot waits for it with the item still in hand. Stopped then,
    # the run records the item as cancelled, as it does one in flight, and the slot
    # neither records it again nor reports its worker as lost after the run has
    # said how it ended.
    for repl in (true, false)
        r = interrupted_run(; items = 1, delay = 0.5, repl, cut = true)
        @test r.got_running
        @test occursin("interrupted after 0 of 1 test item", r.printed)
        @test occursin("1 cancelled", r.printed)
        @test !occursin("did not run", r.printed)
        @test !occursin("LOST", r.printed)
    end
end

Sys.iswindows() ||
@testset "a script stopped by Ctrl-C blames its workers' deaths on nothing else" begin
    # A script, and `Pkg.test`, exit on SIGINT: the exit hooks close the run. The
    # run's own hook stops the workers before anything lets the slots run, so no
    # slot finds its worker gone and puts it down to the out-of-memory killer.
    r = interrupted_run(; items = 2, delay = 0.3, repl = false)
    @test r.got_running
    @test r.elapsed < 30
    @test all_gone(r.started)
    @test occursin("interrupted after 0 of 2 test items", r.printed)
    @test occursin("2 cancelled", r.printed)
    @test !occursin("out-of-memory", r.printed)
    @test !occursin("LOST", r.printed)
end

const EXIT_DURING_PKG = make_pkg("ExitDuring", "test/t_test.jl" => """
    @testitem "first" begin
        sleep(600)
    end
    @testitem "second" begin
        sleep(600)
    end
    """)

"""
    exit_during(; on_event, stall_editor, deadline) -> NamedTuple

Run two items that each sleep for ten minutes, "first" and "second", on two workers,
in a coordinator of its own, and have a task of its main thread call `exit` once the
file `when` names is there. `on_event` is the code of the run's `on_event`, which
can make that file; with `stall_editor`, the run's editor stream makes it as it
writes the `item_started` of "second", and then waits a minute holding the stream.
Returns how long the coordinator took to end after `exit` was called, at most
`deadline` seconds, what it printed, and the run state it left.
"""
function exit_during(; on_event = "_ -> nothing", stall_editor = false, deadline = 60)
    tmp = mktempdir()
    when = joinpath(tmp, "exit_now")
    called = joinpath(tmp, "exit_called")
    runs = mktempdir()
    script = """
    using Runtests
    include(joinpath($(repr(REPO_ROOT)), "test", "helpers.jl"))
    const P = Runtests.Private
    const WHEN = $(repr(when))
    struct StallingIO <: IO end
    function Base.unsafe_write(::StallingIO, p::Ptr{UInt8}, n::UInt)
        line = unsafe_string(p, n)
        if occursin("item_started", line) && occursin("\\"second\\"", line)
            touch(WHEN)
            sleep(60)
        end
        return n
    end
    Base.flush(::StallingIO) = nothing
    @async begin
        while !isfile(WHEN)
            sleep(0.05)
        end
        for i in eachindex(Base.atexit_hooks)
            h = Base.atexit_hooks[i]
            label = string("atexit[", i, "]=", typeof(h))
            Base.atexit_hooks[i] = () -> begin
                P.write_now(stderr, string("[exit-trace] start ", label, "\\n"))
                try
                    hasmethod(h, (Cint,)) ? h(Cint(0)) : h()
                finally
                    P.write_now(stderr, string("[exit-trace] done  ", label, "\\n"))
                end
            end
        end
        touch($(repr(called)))
        exit(0)
    end
    stream = $(stall_editor ? "P.EventStream(StallingIO())" : "nothing")
    P.with(P.EVENTS => stream) do
        P.exclusively() do
            p, target = P.prepare(($(repr(EXIT_DURING_PKG)),); workers = 2, logs = :issues, monitor = false)
            P.execute(p, target; on_event = $on_event)
        end
    end
    """
    path = joinpath(tmp, "run.jl")
    write(path, script)
    log = Base.BufferStream()
    # The empty entry at the end stands for the default load path.
    load_path = join([REPO_ROOT, joinpath(REPO_ROOT, "test"), ""], Runtests.Private.PATHSEP)
    proc = run(pipeline(setenv(`$(Base.julia_cmd()) --project=$(REPO_ROOT) --startup-file=no $path`,
                               child_env("JULIA_LOAD_PATH" => load_path, "RUNTESTS_RUNSTATE_DIR" => runs)...);
                        stdout = log, stderr = log); wait = false)
    timedwait(() -> isfile(called) || process_exited(proc), 600)
    t0 = time()
    ended = timedwait(() -> process_exited(proc), deadline) === :ok
    elapsed = time() - t0
    ended || (kill(proc, Base.SIGKILL); wait(proc))
    close(log)
    printed = read(log, String)
    isfile(called) || @info "the coordinator never got to its exit; it printed:\n$printed"
    isfile(called) && (!ended || elapsed > 15) &&
        @info "the coordinator took $(round(elapsed; digits = 1))s to end$(ended ? "" : ", and was killed"); it printed:\n$printed"
    files = [joinpath(r, f) for (r, _, fs) in walkdir(runs) for f in fs if f == "run.runstate"]
    rs = length(files) == 1 ? read_run_state(only(files)) : nothing
    return (; called = isfile(called), ended, elapsed, printed, rs)
end

# The facts the run state gives each item: its status and the states of its attempts.
item_record(rs, name) = let i = findfirst(it -> it.name == name, rs.items)
    (rs.statuses[i].state, [e.state for e in rs.events if e.kind === :attempt && e.item == i])
end

@testset "an exit closes the run whatever its tasks hold" begin
    ENDING_EXITED = Runtests.Private.ENDING_EXITED
    @testset "an editor stream held by a task the exit stops" begin
        # The exit hook records the items in flight in the run state alone: telling the
        # editor would wait for the stream the stalled writer holds.
        r = exit_during(; stall_editor = true)
        @test r.called && r.ended
        @test r.rs !== nothing && r.rs.ending === ENDING_EXITED && r.rs.closed
        # `second` is in flight: its slot holds it while its start is told. `first` is
        # in flight too, or still waiting for its worker to start, and then unseen.
        @test item_record(r.rs, "second") == (CANCELLED, [CANCELLED])
        @test item_record(r.rs, "first") in ((CANCELLED, [CANCELLED]), (UNSEEN, ItemState[]))
    end
    @testset "a callback of `on_event` waiting as its attempt starts" begin
        # The slot holds its item before anything is told the attempt began, so the
        # exit records it.
        r = exit_during(; on_event = """ev -> (ev.kind === :started && ev.name == "first" && (touch(WHEN); sleep(60)); nothing)""")
        @test r.called && r.ended
        @test r.rs !== nothing && r.rs.ending === ENDING_EXITED && r.rs.closed
        @test item_record(r.rs, "first") == (CANCELLED, [CANCELLED])
    end
    @testset "a run's thread that does not let go" begin
        # The hold gives up after two seconds: the run state is closed with its ending,
        # which says what an item it leaves running means.
        r = exit_during(; on_event = """ev -> begin
                if ev.kind === :started && ev.name == "first"
                    touch(WHEN)
                    t = time()
                    while time() - t < 8
                    end
                end
                nothing
            end""")
        @test r.called
        @test r.ended
        @test r.elapsed < 30
        @test r.rs !== nothing && r.rs.ending === ENDING_EXITED && r.rs.closed
    end
end
