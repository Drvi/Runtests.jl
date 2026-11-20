# Timeouts, and what they are measured against. An item's limit is for the item:
# a profile's `init` and `test_end` expressions are the suite's own code, run on
# the same worker, and each is timed against a limit of its own.

using Runtests.Private: PASSED, FAILED, ERRORED, TIMEDOUT, UNSEEN, collect_failures, report,
            without_enclosing_testset

@testset "timeouts" begin
    @testset "every attempt is timed separately, and a worker past its timeout says where its tasks were" begin
        dir = make_pkg("NeverFinishes", "test/t_test.jl" => """
        @testitem "never finishes" timeout=2 retries=2 begin
            sleep(600)
        end
        """)
        local states, run
        elapsed = @elapsed ((states, run, _), out) = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false)
        end
        @test states["never finishes"] === TIMEDOUT
        @test run.statuses.attempt[1] == 3          # the first go and two retries
        # It held its worker for about its limit, not for nothing. The timer that ends the
        # attempt and the clock that times it can disagree by a hair: 1.9999995 on Windows.
        @test run.statuses.elapsed[1] > 1.9
        # Three attempts of two seconds, not one attempt of two shared between them.
        @test elapsed >= 6
        @test elapsed < 120
        if !Sys.iswindows()
            # The worker is asked where it is before it is killed, and it has to
            # answer before the kill lands: a short timeout is the case that has to
            # work, because it is the one people set.
            @test occursin("live tasks", out)
            @test occursin("KILL", out)
            @test occursin("timed out after 2s (its own timeout=2)", out)
        end
    end

    @testset "init and test_end expressions are not charged to the item" begin
        # Each item's own limit is shorter than its profile's hook spends, and long
        # enough for a fresh worker's first item on a loaded CI runner. Both profiles
        # run side by side on two workers.
        dir = make_pkg(
            "SlowHooks",
            "test/TestItems.toml" => "[profiles.slow_init]\n\n[profiles.slow_end]\n",
            "test/t_test.jl" => """
            @testitem "quick after init" profile=:slow_init timeout=5 begin
                @test true
            end
            @testitem "quick before end" profile=:slow_end timeout=5 begin
                @test true
            end
            """,
            profile_files("slow_init"; init = "sleep(6.5)")...,
            profile_files("slow_end"; test_end = "sleep(6.5)")...,
        )
        states, _, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
        @test states["quick after init"] === PASSED
        @test states["quick before end"] === PASSED
    end

    @testset "an init expression that hangs is stopped by its own limit" begin
        dir = make_pkg(
            "HangingInit",
            "test/t_test.jl" => """
            @testitem "first" begin
                @test true
            end
            @testitem "second" begin
                @test true
            end
            @testitem "third" begin
                @test true
            end
            """,
            profile_files(init = "sleep(600)")...
        )
        (states, run, _), out = with_fast_inspect() do
            capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false, init_timeout=2))
        end
        # The item that asked for the worker is told why it did not get one; the
        # rest never ran, and the run says so rather than passing them over.
        @test count(==(ERRORED), values(states)) == 1
        @test count(==(UNSEEN), values(states)) == 2
        @test occursin("`init` expression of profile `default` timed out after 2s (init_timeout)", out)
        # Said once: the run does not restate what the failure already says.
        @test count("`init` expression of profile", out) == 1
        # An item that never ran is not an item that passed.
        threw = Ref(false)
        _, conclusion = capture_run() do
            try
                without_enclosing_testset(() -> report(run))
            catch e
                threw[] = e isa Test.TestSetException
            end
        end
        @test threw[]
        @test occursin("2 did not run", conclusion)
    end

    @testset "the body's verdict is the item's, whatever its test_end does" begin
        # A body that passes and one that fails, each under a `test_end` that passes, fails
        # an assertion, throws or outlasts its limit. The verdict is the body's: in memory,
        # in the run state and for the next `runtestsf`. Retries follow it too, and a hook
        # in trouble has a line of its own.
        hooks = ["ok" => "@test true", "asserts" => "@test 1 == 2", "throws" => "error(\"hook broke\")", "hangs" => "sleep(60)"]
        items = join(("@testitem \"$body, $h\" profile=:$h retries=1 begin\n    @test $(body == "passes")\nend\n"
                      for (h, _) in hooks for body in ("passes", "fails")))
        dir = make_pkg("HookMatrix",
            "test/TestItems.toml" => "[run]\ntest_end_timeout = 1\n" * join(("\n[profiles.$h]\n" for (h, _) in hooks)),
            "test/t_test.jl" => items,
            (f for (h, code) in hooks for f in profile_files(h; test_end = code))...)
        with_runstate_dir() do _
            (states, run, p), out = with_fast_inspect() do
                capture_run(() -> run_states(dir; workers = 2, logs = :issues, monitor = false))
            end
            rs = Runtests.Private.read_run_state(run.runstate.path)
            for (h, _) in hooks, body in ("passes", "fails")
                name = "$body, $h"
                i = findfirst(==(name), p.items.name)
                verdict = body == "passes" ? PASSED : FAILED
                @test states[name] === verdict && rs.statuses[i].state === verdict
                # Only a body that failed is tried again.
                @test run.statuses.attempt[i] == (body == "passes" ? 1 : 2)
                said = occursin("HOOK · test_end of profile `$h` after \"$name\"", out)
                @test said == (h != "ok")
            end
            @test occursin(r"KILL · pid \d+ · the `test_end` expression of profile `hangs`", out)
            @test occursin(r"HOOK · test_end of profile `hangs` after \"passes, hangs\" · the `test_end` expression", out)
            @test !occursin("test item \"passes, hangs\" timed out", out)
            @test occursin("· 1 did not pass: Test Failed", out)
            @test occursin("· 1 did not pass: Error During Test", out)
            @test Runtests.Private.failing_items(dir) == sort(["fails, $h" for (h, _) in hooks])
        end
    end

    @testset "what a test_end expression finds is said, and in the attempt's log" begin
        # On a worker and in this process: the item's result is its body's alone, and the
        # hook's failure has a line and a place in the attempt's log.
        dir = make_pkg(
            "EndFails",
            "test/t_test.jl" => """@testitem "passes on its own" begin\n    @test true\nend\n""",
            profile_files(test_end = "@test 1 == 2")...
        )
        for workers in (0, 1)
            (states, run, _), out = capture_run(() -> run_states(dir; workers, logs=:issues, monitor=false))
            @test states["passes on its own"] === PASSED
            @test isempty(collect_failures(run.statuses.testsets[1]))
            @test occursin("HOOK · test_end of profile `default` after \"passes on its own\" · 1 did not pass", out)
            @test occursin("1 == 2", read(Runtests.Private.item_log(run, 1, 1), String))
        end
    end

    @testset "what a test_end expression checks adds nothing to the item's result" begin
        dir = make_pkg(
            "EndPasses",
            "test/t_test.jl" => """@testitem "checked once" begin\n    @test true\nend\n""",
            profile_files(test_end = "@test 1 == 1")...
        )
        for workers in (0, 1)
            (states, run, _), out = capture_run(() -> run_states(dir; workers, logs=:issues, monitor=false))
            @test states["checked once"] === PASSED
            tc = Test.get_test_counts(run.statuses.testsets[1])
            @test tc.passes + tc.cumulative_passes == 1
            @test !occursin("HOOK", out)
        end
    end

    @testset "an item that passes is not asked to run test_end twice" begin
        dir = make_pkg(
            "EndCounts",
            "test/t_test.jl" => """
            @testitem "one" begin
                @test true
            end
            @testitem "two" skip=true begin
                @test false
            end
            """,
            profile_files(test_end = "open(ENV[\"RUNTESTS_END_LOG\"], \"a\") do io; println(io, 1); end")...
        )
        mktempdir() do work
            log = joinpath(work, "ends")
            withenv("RUNTESTS_END_LOG" => log) do
                states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                @test states["one"] === PASSED
            end
            # Once for the item that ran, and not at all for the one that was
            # skipped: there is nothing of its to check.
            @test count(==('1'), read(log, String)) == 1
        end
    end
end

@testset "an item that finishes after it was given up on" begin
    # The inspection that follows a timeout leaves the worker alive long enough to
    # finish what it was doing, so its result and its own DONE line arrive after
    # the run has recorded the item as timed out. Neither is welcome: one is a pass
    # for a test nobody accepted, the other is a reply on a channel already closed.
    dir = make_pkg("LateReply", "test/t_test.jl" => """
    @testitem "overruns" timeout=2 retries=0 begin
        sleep(6)
        @test true
    end
    """)
    states, _, _ = nothing, nothing, nothing
    _, out = capture_run() do
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
    end
    @test states["overruns"] === TIMEDOUT
    lines = collect(eachsplit(out, '\n'))
    @test any(l -> occursin("· KILL", l), lines)
    # The worker's own verdict for the abandoned item never reaches the log.
    @test !any(l -> occursin("· DONE", l) && occursin("overruns", l), lines)
    @test !any(l -> occursin("PASS", l) && occursin("overruns", l), lines)
    # ...and a late reply is an expected end to a timeout, not a broken connection.
    @test !occursin("protocol error", out)
    # Whatever the process prints on its way down — a signal, a backtrace — is the
    # worker's, not the item's. This item prints nothing of its own, so a line
    # attributed to it would be a line attributed wrongly.
    @test !any(l -> startswith(l, Runtests.Private.MARK_ITEM * " w"), lines)
    @test any(l -> occursin(Runtests.Private.MARK_WORKER, l) && occursin("KILL", l), lines)
    # It is filed with the item rather than printed across the run: the only worker
    # lines left are the lifecycle words, and the rest went where the report for
    # this item will find it.
    lifecycle = l -> any(w -> occursin(w, l), ("UP", "EXIT", "KILL", "LOST"))
    @test all(lifecycle, filter(l -> occursin(Runtests.Private.MARK_WORKER, l), lines))
    # Windows ends a process with TerminateProcess, which prints nothing on the way.
    Sys.iswindows() || @test occursin("Captured logs", out)
end

@testset "a run in which nothing finishes for too long is stopped as hung" begin
    # An item that outlasts the stall limit before its own timeout would fire stands
    # in for what the limit is there for: something that should have stopped and did
    # not. A real limit is half an hour or more, so the test sets a short one. The
    # clock starts before a worker does, so with one the limit also has to cover
    # starting it before "quick" can finish: seconds on a loaded Windows runner.
    dir = make_pkg("Stalls",
        "test/TestItems.toml" => "[order]\nfirst = [\"quick\"]\n",
        "test/s_test.jl" => """
    @testitem "quick" begin
        @test true
    end
    @testitem "outlasts the limit" timeout=600 begin
        sleep(120)
        @test true
    end
    """)
    for (workers, limit) in ((1, 10.0), (0, 3.0))
        with_runstate_dir() do _
            t0 = time()
            err, out = capture_run() do
                Base.ScopedValues.with(Runtests.Private.STALL_LIMIT_OVERRIDE => limit) do
                    p, target = Runtests.Private.prepare((dir,); workers, logs=:issues, monitor=true, announce=false)
                    try
                        Runtests.Private.execute(p, target)
                        nothing
                    catch e
                        e
                    end
                end
            end
            # Seconds after the last item finished, not the two minutes the other sleeps.
            @test err isa Runtests.Private.RunStalled
            @test time() - t0 < 60
            @test occursin("stopping the run as hung", out)
            @test occursin("stopped as hung after", out)
            # What was running is timed out, and says why; what finished stands.
            rs = Runtests.Private.read_run_state(only(Runtests.Private.runstate_files(dir)))
            state(name) = rs.statuses[findfirst(it -> it.name == name, rs.items)].state
            @test state("quick") === PASSED
            @test state("outlasts the limit") === TIMEDOUT
            @test rs.cancelled
            # Nothing it started is left running, and how the worker ended is on record:
            # the run waited for the process it killed.
            @test isempty(RuntestsWorkers.live_worker_pids())
            workers == 0 || @test any(e -> e.kind === :worker_down && e.ended_by === :interrupt, rs.events)
        end
    end
end

@testset "a timeout holds where there is a process to stop" begin
    # In the calling process (`workers = 0`) nothing can stop an item, so one runs past
    # its timeout and keeps its own verdict. A sandboxed item gets a worker of its own
    # even there, and its timeout holds.
    dir = make_pkg("TimeoutHere", "test/t_test.jl" => """
    @testitem "overruns here" timeout=1 begin
        sleep(2.5)
        @test true
    end
    @testitem "overruns alone" timeout=1 sandbox=true begin
        sleep(60)
        @test true
    end
    """)
    with_runstate_dir() do _
        (states, _, _), _ = with_fast_inspect() do
            capture_run(() -> run_states(dir; workers = 0, logs = :issues, monitor = false))
        end
        @test states["overruns here"] === PASSED
        @test states["overruns alone"] === TIMEDOUT
    end

    if VERSION >= v"1.12"
        # In a combined run, the item of one package is stopped on its worker, the items
        # of every package run on, and only that package's run state has the verdict.
        ws = e2e_workspace(
            "A" => ["test/a_test.jl" => "@testitem \"overruns\" timeout=1 begin\n    sleep(60)\n    @test true\nend\n" *
                                        "@testitem \"a passes\" begin\n    @test true\nend\n"],
            "B" => ["test/b_test.jl" => "@testitem \"b passes\" begin\n    @test true\nend\n"])
        with_runstate_dir() do _
            (states, run, p), out = with_fast_inspect() do
                capture_run(() -> run_mono(ws; workers = 1, logs = :issues, monitor = false))
            end
            @test states == Dict(("A", "overruns") => TIMEDOUT, ("A", "a passes") => PASSED, ("B", "b passes") => PASSED)
            @test occursin("· KILL", out)
            record(name) = Runtests.Private.read_run_state(run.runstate.files[findfirst(==(name), p.packages.name)].path)
            a, b = record("A"), record("B")
            @test a.statuses[findfirst(it -> it.name == "overruns", a.items)].state === TIMEDOUT
            @test [it.name for it in b.items] == ["b passes"]
            @test all(st -> st.state === PASSED, b.statuses)
        end
    end
end
