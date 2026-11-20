using Runtests.Private: prepare, execute, report, ItemState, UNSEEN, PASSED, FAILED, ERRORED, TIMEDOUT,
            SKIPPED, CANCELLED, ConfigError, nitems, is_non_pass
using Logging: Logging
using Random: Random

const FAULTY = fixture("Faulty.jl")
const BASICPKG = fixture("Basic.jl")

# Named as the REPL names the functions it evaluates input from, and global: a local
# function's name is mangled.
@noinline __repl_entry_simulated(f) = f()

@testset "every item draws from the run's seed, whatever ran before it" begin
    with_journal() do jdir
        pkg = make_pkg("Seeded", "test/s_test.jl" => """
        @testitem "one" begin
            write(joinpath(ENV["RUNTESTS_JOURNAL"], "one-" * string(time_ns())), string(rand(UInt64)))
        end
        @testitem "two" begin
            write(joinpath(ENV["RUNTESTS_JOURNAL"], "two-" * string(time_ns())), string(rand(UInt64)))
        end
        """)
        Random.seed!(42); expected = rand(UInt64); Random.seed!(42)
        run_states(pkg; workers=0, seed=7, logs=:issues, monitor=false)
        @test rand(UInt64) == expected   # the caller's own stream, untouched by the items
        run_states(pkg; workers=1, seed=7, name="two", logs=:issues, monitor=false)
        draws(prefix) = [read(f, String) for f in readdir(jdir; join=true) if startswith(basename(f), prefix)]
        @test length(draws("two-")) == 2 && allequal(draws("two-"))   # after "one", or alone on a worker
        @test only(draws("one-")) != first(draws("two-"))
    end
end

@testset "execute" begin
    @testset "a passing suite passes, on workers and in-process" begin
        for workers in (0, 1, 2)
            states, _, _ = run_states(BASICPKG; workers, logs=:issues)
            @test all(==(PASSED), values(states))
            @test length(states) == 6
        end
    end

    @testset "an item on a worker has `Test`, and the worker has loaded neither `Pkg` nor `TestEnv`" begin
        # A worker loads Runtests, which loads `Pkg` and `TestEnv` only to build an
        # environment, which a worker never does: `Pkg` alone would nearly double the
        # time a worker takes to start.
        pkg = make_pkg("Lean", "test/l_test.jl" => """
        @testitem "lean" begin
            @test Test isa Module
            loaded(uuid, name) = Base.root_module_exists(Base.PkgId(Base.UUID(uuid), name))
            @test loaded("632efd68-cd41-4e05-bd25-b86dc2150078", "Runtests")
            @test !loaded("44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "Pkg")
            @test !loaded("1e6cf692-eddd-4d53-88a5-2d735e33781b", "TestEnv")
        end
        """)
        states, _, _ = run_states(pkg; workers=1, logs=:issues)
        @test states["lean"] === PASSED
    end

    @testset "results are reported as a Test summary and failures throw" begin
        p, target = prepare((BASICPKG,); workers=1, logs=:issues)
        run = execute(p, target)
        ts = report(run)
        @test ts isa Test.AbstractTestSet
        # Nested inside this @testset, `report` records into the parent; outside
        # one it throws, which is what makes `runtests()` fail a CI job.
        p2, target2 = prepare((FAULTY,); workers=1, tags=:fail, logs=:issues)
        run2 = execute(p2, target2)
        threw = try
            Runtests.Private.without_enclosing_testset(() -> report(run2))
            false
        catch e
            e isa Test.TestSetException
        end
        @test threw
    end

    @testset "runs under one @testset are recorded in it, side by side" begin
        # Two calls under one `@testset`, as a user writes them. Each run is recorded
        # into it instead of throwing, so the second runs after the first failed, and
        # the enclosing testset is what fails. It is outside this file's testsets, so
        # that failure is its own and not this file's.
        outer = failing = passing = nothing
        err = try
            Runtests.Private.without_enclosing_testset() do
                @testset "both runs" begin
                    outer = Test.get_testset()
                    failing = Runtests.runtests(FAULTY; workers=1, tags=:fail, logs=:issues, monitor=false,
                                            testset_name="faulty")
                    passing = Runtests.runtests(BASICPKG; workers=1, logs=:issues, monitor=false,
                                            testset_name="basic")
                end
            end
            nothing
        catch e
            e
        end
        @test err isa Test.TestSetException
        # Each run's testset, told apart by the names the calls gave them.
        @test outer.results[1] === failing.testset && outer.results[2] === passing.testset
        @test [ts.description for ts in outer.results] == ["faulty", "basic"]
        @test !isempty(Runtests.Private.collect_failures(failing.testset))
        @test isempty(Runtests.Private.collect_failures(passing.testset))
        @test Test.get_test_counts(outer).cumulative_passes >= 6   # one or more from each of Basic's items
    end

    @testset "what runtests returns prints as one line, and is a testset like any other" begin
        ts = Runtests.runtests(BASICPKG; workers=1, logs=:issues, monitor=false, testset_name="basic")
        @test ts isa Runtests.RunTestSet && ts isa Test.AbstractTestSet
        shown = sprint(show, MIME"text/plain"(), ts)
        @test occursin(r"^\"basic\" testset: \d+ passed · \S+$", shown)
        @test ts.description == "basic"                    # its fields read through
        @test Test.get_test_counts(ts).cumulative_passes >= 6
        # The type a `@testset` makes, with another inside it.
        made = Runtests.Private.without_enclosing_testset() do
            @testset Runtests.RunTestSet "made" begin
                @test true
                @testset "inner" begin
                    @test true
                end
            end
        end
        @test made isa Runtests.RunTestSet
        counts = Test.get_test_counts(made)
        @test counts.passes == 1 && counts.cumulative_passes == 1
        @test only(made.results) isa Test.DefaultTestSet   # the only kind a tree holds
        # A failure in it throws at the top, as any testset's does.
        @test_throws Test.TestSetException Runtests.Private.without_enclosing_testset() do
            @testset Runtests.RunTestSet "failing" begin
                @test false
            end
        end
        # Recorded into a parent, what goes in is the testset it holds.
        parent = Test.DefaultTestSet("parent")
        Test.record(parent, ts)
        @test only(parent.results) === ts.testset
    end

    @testset "a dry run prints the plan and returns nothing" begin
        returned, out = capture_run(() -> Runtests.runtests(BASICPKG; dry_run=true))
        @test returned === nothing
        @test occursin("uses setup", out)
    end

    # One worker run of the non-crashing Faulty items covers failure, error, skip, and
    # scoped-value checks without booting four separate workers.
    faulty_states, _, _ = run_states(FAULTY; workers=1, logs=:issues,
        name=r"^(fails|errors|throws outside a test|skipped statically|skipped dynamically|knows it is in a test item)$")

    @testset "a failing item is recorded, not fatal" begin
        @test faulty_states["fails"] === FAILED
    end

    @testset "an erroring item is recorded" begin
        @test faulty_states["errors"] === ERRORED
        @test faulty_states["throws outside a test"] === ERRORED
    end

    @testset "a worker that dies is replaced and the run continues" begin
        # File order puts `kills its worker` before `its own log lines go through the
        # coordinator` on one worker, so the second only runs on a replacement process.
        after = "its own log lines go through the coordinator"
        states, run, p = run_states(FAULTY; workers=1, tags=nothing,
                                    name=Regex("^(kills its worker|$after)\$"), logs=:issues)
        @test states["kills its worker"] === ERRORED
        @test states[after] === PASSED
        @test run.statuses.pid[findfirst(==("kills its worker"), p.items.name)] !=
              run.statuses.pid[findfirst(==(after), p.items.name)]
    end

    @testset "a hung item times out and its worker is killed" begin
        t = @elapsed ((states, _, _) = with_fast_inspect(() -> run_states(FAULTY; workers=1, tags=[:hang], logs=:issues)))
        @test states["hangs"] === TIMEDOUT
        @test t < 60          # the item sleeps for 600s; the timeout is 3s
    end

    @testset "a worker that dies hard is retried, and the run carries on" begin
        # `ccall(:abort)` kills the process where it stands: no exit, no unwinding,
        # no message. The item asks for two retries and passes on the third
        # attempt, and the items around it must be unaffected.
        with_marker_dir() do dir
            states, run, _ = run_states(FAULTY; workers=1, logs=:issues,
                                        name=r"^(survives two dead workers|passes|fails)$")
            @test states["survives two dead workers"] === PASSED
            @test states["passes"] === PASSED          # the run was not cancelled
            @test states["fails"] === FAILED
            # The status line's count: the attempts that errored are not failures.
            @test run.nonpass == count(is_non_pass, run.statuses.state) == 1
            @test parse(Int, read(joinpath(dir, "runtests_abort_count"), String)) == 3
        end
    end

    @testset "retries re-run a failing item" begin
        with_marker_dir() do dir
            (states, run, _), out = capture_run(() -> run_states(FAULTY; workers=1, tags=[:retry], logs=:issues))
            @test states["passes on the second try"] === PASSED
            @test isfile(joinpath(dir, "runtests_retry"))
            @test run.nonpass == count(is_non_pass, run.statuses.state) == 0
            # A plain failure leaves its worker fit to use, and the retry runs there.
            @test occursin("retrying on the same worker (retry 1 of 1)", out)
            @test !occursin("on a new worker", out)
        end
        # An item's own `retries` wins over the run default, in both directions.
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, name="passes on the second try",
                                      logs=:issues, retries=0)
            @test states["passes on the second try"] === PASSED   # the item asked for 1 retry
        end
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, name="fails", logs=:issues, retries=2)
            @test states["fails"] === FAILED                      # no amount of retrying helps
        end
    end

    @testset "retries work the same way in this process" begin
        # An attempt in this process goes through the same attempt loop as one on a
        # worker; what differs is only how the item is run.
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=0, tags=[:retry], logs=:issues)
            @test states["passes on the second try"] === PASSED
            @test parse(Int, read(joinpath(dir, "runtests_retry"), String) |> length |> string) >= 1
        end
    end

    @testset "a failing item's stacktrace stops at the test's own frames" begin
        p, target = prepare((FAULTY,); workers=1, logs=:issues, monitor=false, name="errors")
        run = execute(p, target)
        rm(run.scratch; force=true, recursive=true)
        trimmed = sprint(show, first(Runtests.Private.collect_failures(run.statuses.testsets[1])))
        @test occursin("faults_test.jl", trimmed)        # the item's own frame is kept
        @test !occursin("runitem.jl", trimmed)           # the framework's are not
        @test !occursin("serve_requests", trimmed)

        p2, target2 = prepare((FAULTY,); workers=1, logs=:issues, monitor=false, name="errors",
                              full_stacktraces=true)
        run2 = execute(p2, target2)
        rm(run2.scratch; force=true, recursive=true)
        full = sprint(show, first(Runtests.Private.collect_failures(run2.statuses.testsets[1])))
        @test occursin("runitem.jl", full)               # kept when asked for
        @test length(split(full, '\n')) > length(split(trimmed, '\n'))
    end

    @testset "so does every one a testset inside the item records" begin
        # `Test` formats these backtraces itself, and cuts them only where Julia's
        # REPL entered the code, so each way an error reaches a report is its own case.
        dir = make_pkg("NestedErrors", "test/n_test.jl" => """
        @testitem "outside any test" begin
            @testset "inner" begin
                error("thrown outside any test")
            end
        end
        @testitem "inside a test" begin
            @testset "inner" begin
                @test error("thrown inside a test")
            end
        end
        @testitem "in a task" begin
            @testset "inner" begin
                wait(Threads.@spawn error("thrown in a task"))
            end
        end
        @testitem "while handling another" begin
            @testset "inner" begin
                try
                    error("the first")
                catch
                    error("thrown while handling another")
                end
            end
        end
        """)
        function reports(; kw...)
            _, run, p = run_states(dir; logs=:issues, monitor=false, kw...)
            return Dict(p.items.name[i] => sprint(show, only(Runtests.Private.collect_failures(run.statuses.testsets[i])))
                        for i in 1:nitems(p))
        end
        # A worker's frames lie beneath the item's; with no workers, this process's do.
        beneath = ("runitem.jl", "serve_requests", "execute.jl", "_start")
        # At the REPL, the REPL's own entry frame lies beneath all of this process's,
        # and `Test` cuts there.
        at_the_repl() = __repl_entry_simulated(() -> reports(; workers=0))
        for shown in (reports(; workers=1), reports(; workers=0), at_the_repl())
            for (item, message) in ("outside any test" => "thrown outside any test",
                                    "inside a test" => "thrown inside a test",
                                    "in a task" => "thrown in a task",
                                    "while handling another" => "thrown while handling another")
                @test occursin(message, shown[item])
                @test occursin("n_test.jl", shown[item])   # the item's own frames stay
                @test !any(f -> occursin(f, shown[item]), beneath)
            end
            # The task's own frames are shown under the failure that waited on it,
            # and the first error under the second, each with frames of its own.
            @test occursin("nested task error", shown["in a task"])
            @test occursin(r"caused by: the first(.|\n)*n_test\.jl", shown["while handling another"])
        end
        # Asked for, the worker's frames are kept. Not under an error inside a `@test`:
        # `Test` cuts that one at the test itself, whatever runs beneath; and from
        # 1.14 it cuts an error outside any `@test` at the item's file too.
        full = reports(; workers=1, full_stacktraces=true)
        VERSION < v"1.14-" &&
            @test occursin("runitem.jl", full["outside any test"]) && occursin("runitem.jl", full["in a task"])
    end

    @testset "skip sees the package, and an error in it is the item's" begin
        dir = make_pkg("SkipByPkg", "src/SkipByPkg.jl" => "module SkipByPkg\nflag() = true\nend\n",
            "test/s_test.jl" => """
                @testitem "skipped by the package" skip = SkipByPkg.flag() begin
                    @test false
                end
                @testitem "skip throws" skip = error("no skipping today") begin
                    @test true
                end
                """)
        (states, _, _), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["skipped by the package"] === SKIPPED
        @test states["skip throws"] === ERRORED
        @test occursin("no skipping today", out)
        @test !occursin("could not run this test item", out) && !occursin("handle_request", out)
    end

    @testset "skip is honoured, statically and dynamically" begin
        @test faulty_states["skipped statically"] === SKIPPED
        @test faulty_states["skipped dynamically"] === SKIPPED
    end

    @testset "a result that cannot be serialized is an error, not a lost worker" begin
        # File order puts `returns something unserializable` before `its own log lines
        # go through the coordinator`, so the second item runs on the same worker process.
        after = "its own log lines go through the coordinator"
        states_f, run_f, p_f = run_states(FAULTY; workers=1, logs=:issues,
                                          name=Regex("^(returns something unserializable|$after)\$"))
        @test states_f["returns something unserializable"] === ERRORED
        @test states_f[after] === PASSED
        @test run_f.statuses.pid[findfirst(==("returns something unserializable"), p_f.items.name)] ==
              run_f.statuses.pid[findfirst(==(after), p_f.items.name)]
    end

    @testset "the scoped value is set inside an item and inherited by its tasks" begin
        @test faulty_states["knows it is in a test item"] === PASSED
    end

    @testset "failfast stops the run" begin
        states, _, _ = run_states(FAULTY; workers=1, failfast=true, retries=1, logs=:issues,
                                  name=r"^(fails|passes|errors)$")
        # The item that stopped the run is still the failure it was once its retry
        # has failed too: stopping under the retry would record it as cancelled.
        @test count(s -> s === FAILED || s === ERRORED, values(states)) == 1
        @test any(==(UNSEEN), values(states)) || length(states) == 1
    end

    @testset "a retry another item's failfast stops leaves the failure it was" begin
        marks = mktempdir()
        slow_started = joinpath(marks, "slow_started")
        quick_done = joinpath(marks, "quick_done")
        dir = make_pkg("FailfastRetry", "test/t_test.jl" => """
            @testitem "fails slowly, retries" retries=1 begin
                touch($(repr(slow_started)))
                deadline = time() + 60
                while !isfile($(repr(quick_done))) && time() < deadline
                    sleep(0.02)
                end
                sleep(0.2)
                @test false
            end
            @testitem "fails quickly" begin
                deadline = time() + 60
                while !isfile($(repr(slow_started))) && time() < deadline
                    sleep(0.02)
                end
                touch($(repr(quick_done)))
                @test false
            end
            """)
        states, run, p = run_states(dir; workers=2, failfast=true, logs=:issues, monitor=false)
        # The quick failure stops the run while the slow one's first attempt runs: that
        # attempt's failure is its verdict, in memory and on disk, and nothing ran less.
        @test states["fails slowly, retries"] === FAILED && states["fails quickly"] === FAILED
        rs = Runtests.Private.read_run_state(run.runstate.path)
        @test all(st -> st.state === FAILED, rs.statuses)
    end

    @testset "a retry that decides nothing leaves the verdict of the attempt before it" begin
        # A skip, or a stop of the run, decides no verdict: the item keeps its failure, in
        # memory, in its run state and for the next `runtestsf`, and is not tried again.
        # Every attempt keeps its event. A retry that passes decides the item.
        marks = mktempdir()
        once(name) = "(m = $(repr(joinpath(marks, name))); first = !isfile(m); first && touch(m); first)"
        attempts(rs, i) = [e.state for e in rs.events if e.kind === :attempt && e.item == i]
        dir = make_pkg("UndecidedRetry", "test/t_test.jl" => """
            @testitem "fails, then skips" retries=2 skip=isfile($(repr(joinpath(marks, "skip_my_retry")))) begin
                touch($(repr(joinpath(marks, "skip_my_retry"))))
                @test false
            end
            @testitem "fails, then passes" retries=1 begin
                @test !$(once("passed_once"))
            end
            """)
        for workers in (1, 0)
            foreach(f -> rm(joinpath(marks, f)), readdir(marks))
            with_runstate_dir() do _
                (states, run, p), _ = capture_run(() -> run_states(dir; workers, logs = :issues, monitor = false))
                skips, passes = findfirst(==("fails, then skips"), p.items.name), findfirst(==("fails, then passes"), p.items.name)
                @test states["fails, then skips"] === FAILED && run.statuses.attempt[skips] == 1
                @test states["fails, then passes"] === PASSED
                @test run.nonpass == 1
                rs = Runtests.Private.read_run_state(run.runstate.path)
                @test rs.statuses[skips].state === FAILED && rs.statuses[skips].attempt == 1
                @test attempts(rs, skips) == [FAILED, SKIPPED]
                @test rs.statuses[passes].state === PASSED && attempts(rs, passes) == [FAILED, PASSED]
                @test Runtests.Private.failing_items(dir) == ["fails, then skips"]
            end
        end
        # A stop while the retry runs: the retry interrupts the run. (Another item's
        # failfast lets an attempt in flight finish, and decides by it.)
        stopped = make_pkg("StoppedRetry", "test/t_test.jl" => """
            @testitem "fails, then is stopped" retries=1 begin
                $(once("failed_once")) || throw(InterruptException())
                @test false
            end
            """)
        with_runstate_dir() do _
            thrown = try
                capture_run(() -> run_states(stopped; workers = 0, logs = :issues, monitor = false))
                nothing
            catch e
                e
            end
            @test thrown isa InterruptException
            rs = Runtests.Private.read_run_state(only(Runtests.Private.runstate_files(stopped)))
            @test rs.cancelled && attempts(rs, 1) == [FAILED, CANCELLED]
            @test rs.statuses[1].state === FAILED && rs.statuses[1].attempt == 1
            @test "fails, then is stopped" in Runtests.Private.failing_items(stopped)
        end
        # An interrupt from `on_event` as the skip is told: the run state holds the
        # failure before anything is told of the skip.
        foreach(f -> rm(joinpath(marks, f)), readdir(marks))
        with_runstate_dir() do _
            on_event(ev) = (ev.kind === :finished && ev.state === :skipped && throw(InterruptException()); nothing)
            thrown = try
                capture_run() do
                    exclusively() do
                        p, target = prepare((dir,); workers = 1, name = "fails, then skips", logs = :issues, monitor = false)
                        execute(p, target; on_event)
                    end
                end
                nothing
            catch e
                e
            end
            @test thrown isa InterruptException
            rs = Runtests.Private.read_run_state(only(Runtests.Private.runstate_files(dir)))
            @test rs.cancelled && attempts(rs, 1) == [FAILED, SKIPPED]
            @test rs.statuses[1].state === FAILED && rs.statuses[1].attempt == 1
            @test Runtests.Private.failing_items(dir) == ["fails, then skips"]
        end
    end

    @testset "an attempt is reported with what its `test_end` printed" begin
        dir = make_pkg("HookOutput", profile_files(; test_end = "println(\"HOOK OUTPUT\")")...,
            "test/t_test.jl" => """
            @testitem "prints" begin
                println("BODY OUTPUT")
                @test true
            end
            @testitem "quiet" begin
                @test true
            end
            """)
        for workers in (0, 1)
            with_runstate_dir() do _
                buf = IOBuffer()
                (states, _, _), out = capture_run() do
                    Runtests.Private.with(Runtests.Private.EVENTS => Runtests.Private.EventStream(buf)) do
                        run_states(dir; workers, logs = :batched, monitor = false)
                    end
                end
                @test states["prints"] === PASSED && states["quiet"] === PASSED
                @test occursin("BODY OUTPUT", out) && occursin("HOOK OUTPUT", out)
                # A quiet body's log is the hook's: an editor is given it.
                quiet = only(l for l in split(String(take!(buf)), '\n') if occursin("item_finished", l) && occursin("\"quiet\"", l))
                @test !occursin("\"log\":null", quiet)
            end
        end
    end

    @testset "a second run in the same process is refused, and the first goes on" begin
        release = joinpath(mktempdir(), "release")
        dir = make_pkg("OneAtATime", "test/t_test.jl" => """
            @testitem "takes a while" begin
                deadline = time() + 60
                while !isfile($(repr(release))) && time() < deadline
                    sleep(0.02)
                end
                @test true
            end
            """)
        first_run = @async run_states(dir; workers=1, logs=:issues, monitor=false)
        try
            timedwait(() -> RuntestsWorkers.INTERRUPT_TARGET.task !== nothing, 120)
            target = RuntestsWorkers.INTERRUPT_TARGET.task
            @test Runtests.Private.RUN_ACTIVE[] && target !== nothing
            busy = "Runtests is already at work in this process"
            @test_throws busy run_states(dir; workers=1, logs=:issues, monitor=false)
            # Refused before it touches anything the run has set: not the root its paths
            # print against, not where Ctrl-C goes.
            @test_throws busy Runtests.runtests(BASICPKG; workers=1, logs=:issues, monitor=false)
            @test_throws busy Runtests.runtests(BASICPKG; dry_run=true)
            @test_throws busy Runtests.chores(BASICPKG; dry_run=true)
            @test_throws busy @eval @testitem "pasted" begin
                @test true
            end
            @test Runtests.Private.PROJECT_ROOT[] == dir
            @test RuntestsWorkers.INTERRUPT_TARGET.task === target
        finally
            touch(release)
        end
        states, _, _ = fetch(first_run)
        @test states["takes a while"] === PASSED && !Runtests.Private.RUN_ACTIVE[]
    end

    # Julia 1.12 and later have an interactive thread unless told otherwise.
    Threads.nthreads(:interactive) > 0 &&
    @testset "a run called from the interactive thread runs on the default pool, and its items in this process stay" begin
        # The slots, whose tasks call `on_event`, are on the run's thread.
        dir = make_pkg("PoolOfTheRun", "test/t_test.jl" => """
            @testitem "a" begin
                @test true
            end
            @testitem "b" begin
                @test true
            end
            """)
        pools(workers) = fetch(Threads.@spawn :interactive exclusively() do
            seen = Symbol[]
            p, target = prepare((dir,); workers, logs=:issues, monitor=false)
            run = execute(p, target; on_event = _ -> push!(seen, Threads.threadpool()))
            rm(run.scratch; force=true, recursive=true)
            (; seen, passed = all(==(PASSED), run.statuses.state))
        end)
        on_workers = pools(1)
        @test on_workers.passed && length(on_workers.seen) == 4 && all(==(:default), on_workers.seen)
        in_process = pools(0)
        @test in_process.passed && length(in_process.seen) == 4 && all(==(:interactive), in_process.seen)
    end

    @testset "an item's RUN and DONE lines are drawn by the coordinator, on a worker or not" begin
        for workers in (0, 1)
            (states, _, _), out = capture_run() do
                run_states(FAULTY; workers, tags=[:routing], logs=:issues)
            end
            @test states["its own log lines go through the coordinator"] === PASSED
            @test count("· RUN ", out) == 1
            @test count("· DONE ", out) == 1
            # What a worker writes about an item is data for the coordinator.
            @test !occursin(RuntestsWorkers.RECORD_MARK, out)
        end
    end

    @testset "what an item prints from C is in its log, not after it as the worker's" begin
        # C's stdio keeps a buffer of its own, which a pipe empties only when it fills
        # or the process exits: left there, the line came out after the item ended.
        dir = make_pkg("PrintsFromC", "test/c_test.jl" => """
            @testitem "prints from C" begin
                ccall(:puts, Cint, (Cstring,), "printed from C")
                @test false
            end
            """)
        # Captured on a worker and in this process, and relayed as it comes.
        for (workers, logs) in ((1, :issues), (0, :issues), (1, :eager))
            (states, _, _), out = capture_run(() -> run_states(dir; workers, logs, monitor=false))
            @test states["prints from C"] === FAILED
            printed = findfirst("printed from C", out)
            @test printed !== nothing
            @test !occursin("⚫ w1 · printed from C", out)
            # Relayed as it comes, it is between the item's RUN and DONE lines.
            if logs === :eager && printed !== nothing
                @test findfirst("· RUN ", out).start < printed.start < findfirst("· DONE ", out).start
            end
        end
    end

    @testset "logs = :eager keeps relayed item output in log files without creating empty files" begin
        dir = make_pkg("EagerLogs", "test/e_test.jl" => """
            @testitem "talks" begin
                println("hello from eager")
                @test true
            end
            @testitem "quiet" begin
                @test true
            end
            """)
        with_runstate_dir() do _
            (states, run, p), out = capture_run(() -> run_states(dir; workers = 1, logs = :eager, monitor = false))
            @test states["talks"] === PASSED && states["quiet"] === PASSED
            @test occursin("hello from eager", out)
            @test !occursin("Captured logs", out)
            i_talks = findfirst(==("talks"), p.items.name)
            i_quiet = findfirst(==("quiet"), p.items.name)
            talks_log = Runtests.Private.item_log(run, i_talks, 1)
            quiet_log = Runtests.Private.item_log(run, i_quiet, 1)
            @test isfile(talks_log) && occursin("hello from eager", read(talks_log, String))
            @test !isfile(quiet_log)
        end
    end

    @testset "what loading the package prints while `skip` is decided is in the item's log" begin
        # A `skip` that is not a literal loads the package to be evaluated, and a
        # package can print as it loads.
        dir = make_pkg("PrintsOnLoad", "test/p_test.jl" => """
            @testitem "skip by an expression" skip=(VERSION < v"1.0") begin
                @test false
            end
            """)
        write(joinpath(dir, "src", "PrintsOnLoad.jl"),
              "module PrintsOnLoad\n__init__() = println(stderr, \"printed as it loads\")\nend\n")
        (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
        @test states["skip by an expression"] === FAILED
        @test occursin("printed as it loads", out)
        @test !occursin("w1 · printed as it loads", out)
    end

    @testset "workers=0 still gives a sandboxed item its process" begin
        # `workers=0` is a promise about the pool, not about never starting a
        # process. An item that asked for its own `--check-bounds` is testing
        # something that depends on it, so running it here and reporting a pass
        # would report a pass for a test that never ran the way it was written.
        dir = make_pkg(
            "Sandboxed",
            "test/a_test.jl" => """
            @testitem "bounded" profile=:bounds begin
                @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)  # what it asked for
                @test Main.FROM_PROFILE_INIT == 7                             # and its profile's init
                @test getpid() != parse(Int, ENV["RUNTESTS_SOLO_PID"])
            end
            @testitem "alone" sandbox=true begin
                @test getpid() != parse(Int, ENV["RUNTESTS_SOLO_PID"])
            end
            @testitem "ordinary" begin
                @test Base.JLOptions().check_bounds == $(Base.JLOptions().check_bounds)
                @test getpid() == parse(Int, ENV["RUNTESTS_SOLO_PID"])
            end
            """,
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n",
            profile_files("bounds"; init = "const FROM_PROFILE_INIT = 7")...,
        )
        before = live_worker_processes()
        out = Ref("")
        logs = Test.collect_test_logs() do
            withenv("RUNTESTS_SOLO_PID" => string(getpid())) do
                (states, _, _), printed = capture_run() do
                    run_states(dir; workers=0, logs=:issues, monitor=false)
                end
                out[] = printed
                # Every item runs, including the ones in a pool of their own —
                # those are not in the single slot's queue.
                @test length(states) == 3
                @test all(==(PASSED), values(states))
            end
        end
        # Each sandbox worker announces itself and its teardown, and each ran
        # exactly the one item it was started for.
        lifecycle = filter(l -> occursin("· UP ", l) || occursin("· EXIT", l), worker_lines(out[]))
        @test count(l -> occursin("· UP ", l), lifecycle) == 2
        @test count(l -> occursin("· EXIT", l), lifecycle) == 2
        @test all(l -> occursin("1 item ", l), filter(l -> occursin("· EXIT", l), lifecycle))
        @test any(l -> occursin(OTHER_BOUNDS.arg, l), lifecycle)

        # ...and the processes it started are gone again.
        @test timedwait(() -> live_worker_processes() <= before, 10) === :ok

        warnings = filter(r -> r.level == Logging.Warn, first(logs))
        @test length(warnings) == 1
        msg = first(warnings).message
        @test occursin("workers=0", msg)
        @test occursin("a worker of its own", msg)
        @test occursin("\"bounded\"", msg)
        @test occursin("\"alone\"", msg)
        @test !occursin("\"ordinary\"", msg)   # it asked for nothing, so it ran here
    end

    @testset "workers=0 says nothing when nothing asked for a sandbox" begin
        logs = Test.collect_test_logs() do
            run_states(BASICPKG; workers=0, logs=:issues, monitor=false)
        end
        @test isempty(filter(r -> r.level == Logging.Warn, first(logs)))
    end

    @testset "a profile really changes the worker's julia flags" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"), "name = \"Flagged\"\nuuid = \"1a2b3c4d-0000-4000-8000-000000000004\"\n")
        mkpath(joinpath(dir, "src")); write(joinpath(dir, "src", "Flagged.jl"), "module Flagged end\n")
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "default flags" begin
            @test Base.JLOptions().check_bounds == $(Base.JLOptions().check_bounds)
        end
        @testitem "checked flags" profile=:bounds begin
            @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
        end
        """)
        write(joinpath(dir, "test", "TestItems.toml"),
              "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n")
        states, _, _ = run_states(dir; workers=2, logs=:issues)
        @test states["default flags"] === PASSED
        @test states["checked flags"] === PASSED
    end

    @testset "the call's worker_init and test_end are the default profile's, in place of its files" begin
        dir = make_pkg("CallCode",
            "test/t_test.jl" => "@testitem \"sees the call's init\" begin\n    @test Main.FROM === :call\nend\n",
            profile_files(; init = "global FROM = :file", test_end = "@test false")...)
        states, _, _ = run_states(dir; workers = 1, logs = :issues, monitor = false,
                                  worker_init = :(global FROM = :call), test_end = :(@test true))
        @test states["sees the call's init"] === PASSED
        # The files alone: the body sees the file's `init`, and fails.
        states, _, _ = run_states(dir; workers = 1, logs = :issues, monitor = false)
        @test states["sees the call's init"] === FAILED
        @test_throws ArgumentError run_states(dir; workers = 1, logs = :issues, monitor = false, worker_init = "global FROM = 1")
    end

    @testset "profiles that differ only in test_end share workers, each item running its own" begin
        # A `test_end` that leaves an entry in the journal, as the items do.
        end_mark(tag) = string("open(joinpath(ENV[\"RUNTESTS_JOURNAL\"], string(time_ns(), \"-\", getpid())), ",
                               "\"w\") do io; println(io, \"end ", tag, "\\t\", getpid(), \"\\t\", time()); end")
        dir = make_pkg(
            "EndOnly",
            "test/a_test.jl" => journal_item("a1"; opts = "profile=:a", body = "@test Main.Runtests.current_testitem().profile === :a") *
                                journal_item("skipped"; opts = "profile=:a skip=true"),
            "test/b_test.jl" => journal_item("b1"; opts = "profile=:b", body = "@test Main.Runtests.current_testitem().profile === :b") *
                                journal_item("b2"; opts = "profile=:b retries=1", body = """
                                    flag = joinpath(ENV["RUNTESTS_JOURNAL"], "b2 tried")
                                    tried = isfile(flag)
                                    touch(flag)
                                    @test tried
                                    """),
            "test/TestItems.toml" => "[profiles.a]\n\n[profiles.b]\n",
            profile_files("a"; test_end = end_mark("a"))..., profile_files("b"; test_end = end_mark("b"))...,
        )
        with_journal() do journal_dir
            (states, _, p), _ = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
            @test (states["a1"], states["b1"], states["b2"], states["skipped"]) == (PASSED, PASSED, PASSED, SKIPPED)
            @test length(p.pools) == 1
            rows = journal(journal_dir)
            names = [r.name for r in rows]
            # One process ran both profiles' items.
            @test length(unique(r.pid for r in rows)) == 1
            # Each attempt that ran, a failed one before its retry too, ran its own
            # profile's `test_end` right after it; the skipped item ran none.
            @test count(==("end a"), names) == 1
            @test count(==("end b"), names) == 3
            for (k, name) in enumerate(names)
                startswith(name, "end") && continue
                @test names[k + 1] == (name == "a1" ? "end a" : "end b")
            end
        end
        # In this process, with `workers = 0`, the default profile's own `test_end`.
        solo = make_pkg("EndInProcess", "test/a_test.jl" => journal_item("d1"),
                        profile_files(; test_end = end_mark("d"))...)
        with_journal() do journal_dir
            states, _, _ = run_states(solo; workers = 0, logs = :issues, monitor = false)
            @test states["d1"] === PASSED
            rows = journal(journal_dir)
            @test [r.name for r in rows] == ["d1", "end d"]
            @test all(r -> r.pid == getpid(), rows)
        end
    end

    @testset "no worker processes are left behind, and the worker count is a cap" begin
        # 6 units, 2 workers: this run must never have a third process alive, and once
        # it ends no worker it started is left behind. Counted against a snapshot taken
        # first, because workers an earlier test is still reaping are not this run's doing.
        p, target = prepare((BASICPKG,); workers=2)
        before_count = live_worker_processes()
        before = live_worker_pids()
        peak = Ref(0)
        done = Threads.Atomic{Bool}(false)
        watcher = Threads.@spawn begin
            while !done[]
                peak[] = max(peak[], length(setdiff(live_worker_pids(), before)))
                sleep(0.01)
            end
        end
        run = try
            execute(p, target)
        finally
            done[] = true
            wait(watcher)
        end
        rm(run.scratch; force=true, recursive=true)
        @test peak[] <= 2
        @test timedwait(() -> live_worker_processes() <= before_count, 10) === :ok
    end

    @testset "on_event" begin
        # Through `runtests`, outside any testset: the failures are the fixture's.
        function heard(on_event, pkg; kwargs...)
            return capture_run() do
                try
                    Runtests.Private.without_enclosing_testset() do
                        Runtests.runtests(pkg; logs = :issues, monitor = false, on_event, kwargs...)
                    end
                catch e
                    e isa Test.TestSetException || rethrow()
                end
            end
        end

        @testset "is called as each attempt starts and as it ends, with what the item measured" begin
            events = Runtests.TestItemEvent[]
            with_marker_dir() do _
                heard(ev -> push!(events, ev), FAULTY; workers = 1,
                      name = r"^(passes|passes on the second try|kills its worker)$")
            end
            kinds = Dict{Tuple{String, Int}, Vector{Symbol}}()
            for ev in events
                push!(get!(kinds, (ev.name, ev.attempt), Symbol[]), ev.kind)
            end
            @test length(kinds) == 4   # the retried item twice
            @test all(==([:started, :finished]), values(kinds))
            @test all(ev -> ev.state === :running && !ev.measured && ev.elapsed == 0, filter(ev -> ev.kind === :started, events))
            ended = Dict((ev.name, ev.attempt) => ev for ev in events if ev.kind === :finished)
            @test ended[("passes on the second try", 1)].state === :failed
            @test ended[("passes on the second try", 2)].state === :passed
            passed = ended[("passes", 1)]
            @test passed.state === :passed && passed.measured
            @test passed.file == joinpath(FAULTY, "test", "faults_test.jl") && passed.line == 1
            @test passed.worker == 1 && passed.pid > 0
            @test passed.elapsed > 0 && passed.compile >= passed.recompile >= 0 && passed.maxrss > 0
            # An outcome the run decided has nothing the item measured.
            died = ended[("kills its worker", 1)]
            @test died.state === :errored && !died.measured && died.pid > 0
            @test died.cpu == died.compile == died.recompile == died.gc == 0 && died.allocated == died.allocations == died.maxrss == 0
        end

        @testset "each event names the events directory of its run, made only for a run given a function" begin
            events = Runtests.TestItemEvent[]
            heard(ev -> push!(events, ev), BASICPKG; workers = 0)
            dir = only(unique(ev.events_dir for ev in events))
            newest = last(Runtests.Private.runstate_files(BASICPKG))
            @test dir == joinpath(dirname(newest), "events") && isdir(dir)
            heard(nothing, BASICPKG; workers = 0)
            newest = last(Runtests.Private.runstate_files(BASICPKG))
            @test !ispath(joinpath(dirname(newest), "events"))
        end

        @testset "finished events carry log and artifacts paths when present" begin
            pkg = make_pkg("EventPaths", "test/ep_test.jl" => """
                @testitem "fails with evidence" begin
                    println("loud failure")
                    write(joinpath(Main.Runtests.artifacts_dir(), "note.txt"), "kept")
                    @test false
                end
                @testitem "passes quietly" begin
                    @test true
                end
                """)
            events = Runtests.TestItemEvent[]
            heard(ev -> push!(events, ev), pkg; workers = 1)
            started = filter(ev -> ev.kind === :started, events)
            @test all(ev -> isempty(ev.log) && isempty(ev.artifacts), started)
            fin = Dict(ev.name => ev for ev in events if ev.kind === :finished)
            @test isfile(fin["fails with evidence"].log) && occursin("loud failure", read(fin["fails with evidence"].log, String))
            @test isdir(fin["fails with evidence"].artifacts) && isfile(joinpath(fin["fails with evidence"].artifacts, "files", "note.txt"))
            @test isempty(fin["passes quietly"].log) && isempty(fin["passes quietly"].artifacts)
        end

        @testset "hears what an attempt cost, on a worker and in this process" begin
            pkg = make_pkg("Costs", "test/costs_test.jl" => """
                @testitem "works" begin
                    function spin(n)
                        s = 0.0
                        for i in 1:n
                            s += sqrt(i)
                        end
                        return s
                    end
                    @test spin(2 * 10^8) > 0
                    @test length(zeros(10^7)) == 10^7
                    @test length([Ref(i) for i in 1:10^5]) == 10^5
                    GC.gc()
                end
                @testitem "waits" begin
                    sleep(1.0)
                    @test true
                end
                """)
            for workers in (0, 1)
                events = Runtests.TestItemEvent[]
                heard(ev -> ev.kind === :finished && push!(events, ev), pkg; workers)
                works, waits = (only(filter(ev -> ev.name == n, events)) for n in ("works", "waits"))
                @test all(ev -> ev.state === :passed && ev.measured && ev.maxrss > 0, events)
                @test works.cpu > 0.05 && works.compile > 0 && works.gc > 0
                @test works.allocated >= 8 * 10^7 && works.allocations >= 10^5
                # CPU time, not the time that passed.
                @test waits.elapsed >= 0.9 && waits.cpu < waits.elapsed / 2
                workers == 0 && @test all(ev -> ev.pid == getpid(), events)
            end
        end

        @testset "calls come one at a time" begin
            inside, overlapped, calls = Ref(false), Ref(false), Ref(0)
            heard(BASICPKG; workers = 2) do _
                inside[] && (overlapped[] = true)
                inside[] = true
                calls[] += 1
                sleep(0.02)  # yields: another slot's call would run meanwhile
                inside[] = false
            end
            @test calls[] == 2 * 6
            @test !overlapped[]
        end

        @testset "a call that throws is reported, and the run goes on without it" begin
            calls = Ref(0)
            _, out = heard(_ -> (calls[] += 1; error("the observer broke")), BASICPKG; workers = 0)
            @test calls[] == 1
            @test count("`on_event` threw", out) == 1
            @test occursin("the observer broke", out)
            @test occursin("all passed", out)
        end

        @testset "a value that cannot take a TestItemEvent is refused before anything runs" begin
            for bad in (1, (x::Int) -> x)
                e = try
                    Runtests.runtests(BASICPKG; on_event = bad)
                catch e
                    e
                end
                @test e isa ArgumentError && occursin("`on_event` must be a function that takes a `Runtests.TestItemEvent`", e.msg)
            end
        end
    end
end

# What a run returns, what it allows alongside it, and what an item draws, in the
# other ways a suite runs: in this process, and across the packages of a workspace.
@testset "a run in this process and a combined run behave as one on workers" begin
    outside(f) = Runtests.Private.without_enclosing_testset() do
        try
            f()
        catch e
            e
        end
    end
    passing(name) = "@testitem $(repr(name)) begin\n    @test true\nend\n"
    failing(name) = "@testitem $(repr(name)) begin\n    @test 1 == 2\nend\n"
    combined = VERSION >= v"1.12"

    @testset "a run returns a RunTestSet, and throws outside a testset when an item did not pass" begin
        with_runstate_dir() do _
            ts, _ = capture_run(() -> outside(() -> Runtests.runtests(BASICPKG; workers = 0, logs = :issues, monitor = false)))
            @test ts isa Runtests.RunTestSet
            err, _ = capture_run(() -> outside(() -> Runtests.runtests(FAULTY; workers = 0, tags = :fail, logs = :issues,
                                                                       monitor = false)))
            @test err isa Test.TestSetException
            if combined
                ws = e2e_workspace("A" => ["test/a_test.jl" => passing("a")], "B" => ["test/b_test.jl" => failing("b")])
                ts, _ = capture_run(() -> outside(() -> Runtests.runtests_mono(ws; packages = ["A"], workers = 1,
                                                                                logs = :issues, monitor = false)))
                @test ts isa Runtests.RunTestSet
                err, _ = capture_run(() -> outside(() -> Runtests.runtests_mono(ws; workers = 1, logs = :issues,
                                                                                 monitor = false)))
                @test err isa Test.TestSetException
            end
        end
    end

    @testset "a retry draws the numbers the first attempt drew, and reseeds from its attempt as documented" begin
        dir = make_pkg("RetrySeeds", "test/r_test.jl" => """
            @testitem "draws again" retries=1 begin
                import Runtests
                attempt = Runtests.current_testitem().attempt
                write(joinpath(ENV["RUNTESTS_JOURNAL"], "same-\$attempt"), string(rand(UInt64)))
                @test attempt == 2
            end
            @testitem "reseeds" retries=1 begin
                import Random, Runtests
                attempt = Runtests.current_testitem().attempt
                attempt > 1 && Random.seed!(rand(UInt64) + attempt)
                write(joinpath(ENV["RUNTESTS_JOURNAL"], "reseeded-\$attempt"), string(rand(UInt64)))
                @test attempt == 2
            end
            """)
        for workers in (0, 1)
            with_journal() do jdir
                with_runstate_dir() do _
                    (states, _, _), _ = capture_run(() -> run_states(dir; workers, logs = :issues, monitor = false))
                    @test states["draws again"] === PASSED && states["reseeds"] === PASSED
                end
                drawn(name) = read(joinpath(jdir, name), String)
                @test drawn("same-1") == drawn("same-2")
                @test drawn("reseeded-1") != drawn("reseeded-2")
            end
        end
    end

    @testset "failfast stops a run in this process before the items after the failure" begin
        dir = make_pkg("FailfastHere",
            "test/TestItems.toml" => "[order]\nfirst = [\"first fails\"]\n",
            "test/t_test.jl" => failing("first fails") * passing("never starts"))
        with_runstate_dir() do _
            (states, _, _), _ = capture_run(() -> run_states(dir; workers = 0, failfast = true, logs = :issues,
                                                             monitor = false))
            @test states["first fails"] === FAILED
            @test states["never starts"] in (UNSEEN, CANCELLED)
        end
    end

    if combined
        @testset "a combined run holds the process as a run does, against either kind of call" begin
            release = joinpath(mktempdir(), "release")
            ws = e2e_workspace("A" => ["test/a_test.jl" => """
                @testitem "waits" begin
                    deadline = time() + 60
                    while !isfile($(repr(release))) && time() < deadline
                        sleep(0.02)
                    end
                    @test true
                end
                """])
            with_runstate_dir() do _
                # The run's output is captured while it runs, this task's included: what
                # this task finds is tested once the run is over.
                running = Threads.@spawn capture_run(() -> outside(() -> Runtests.runtests_mono(ws; workers = 1,
                                                                                                 logs = :issues,
                                                                                                 monitor = false)))
                started, errs = try
                    s = timedwait(() -> Runtests.Private.RUN_ACTIVE[], 120.0)
                    e = [outside(() -> Runtests.runtests(BASICPKG; workers = 1)), outside(() -> Runtests.runtests_mono(ws)),
                         outside(() -> Runtests.chores_mono(ws; dry_run = true))]
                    s, e
                finally
                    touch(release)
                end
                ts, _ = fetch(running)
                @test started === :ok
                for err in errs
                    @test err isa ConfigError && occursin("already at work in this process", err.msg)
                end
                @test ts isa Runtests.RunTestSet
                @test !Runtests.Private.RUN_ACTIVE[]
            end
        end

        @testset "every item draws from the run's seed, whatever ran before it, across packages too" begin
            with_journal() do jdir
                # `tag` names the journal file, so that items of one name in two packages
                # write files of their own.
                draw(name, tag = name) = "@testitem $(repr(name)) begin\n" *
                             "    write(joinpath(ENV[\"RUNTESTS_JOURNAL\"], $(repr(tag)) * \"-\" * string(time_ns())), " *
                             "string(rand(UInt64)))\nend\n"
                ws = e2e_workspace("A" => ["test/a_test.jl" => draw("a one") * draw("a two") * draw("same", "A same")],
                                   "B" => ["test/b_test.jl" => draw("b one") * draw("same", "B same")])
                with_runstate_dir() do _
                    capture_run(() -> run_mono(ws; workers = 1, seed = 7, logs = :issues, monitor = false))
                    capture_run(() -> run_mono(ws; workers = 2, seed = 7, name = "a two", logs = :issues, monitor = false))
                    capture_run(() -> run_states(joinpath(ws, "lib", "A"); workers = 0, seed = 7, name = "same",
                                                 logs = :issues, monitor = false))
                end
                draws(prefix) = [read(f, String) for f in readdir(jdir; join = true) if startswith(basename(f), prefix)]
                @test length(draws("a two-")) == 2 && allequal(draws("a two-"))
                @test only(draws("a one-")) != first(draws("a two-"))
                # The name of the package is part of the item's seed: one item name in two
                # packages draws two streams, and the package's own run draws what the
                # combined run drew.
                @test only(draws("B same-")) != first(draws("A same-"))
                @test length(draws("A same-")) == 2 && allequal(draws("A same-"))
            end
        end

        @testset "a retry runs on the same worker, and its package's run state counts both attempts" begin
            flaky = """
            @testitem "flaky" retries=1 begin
                marker = joinpath(ENV["RUNTESTS_JOURNAL"], "flaky")
                again = isfile(marker)
                touch(marker)
                @test again
            end
            """
            ws = e2e_workspace("A" => ["test/a_test.jl" => flaky], "B" => ["test/b_test.jl" => passing("b")])
            with_journal() do _
                with_runstate_dir() do _
                    (states, run, p), out = capture_run(() -> run_mono(ws; workers = 1, logs = :issues, monitor = false))
                    @test states[("A", "flaky")] === PASSED && states[("B", "b")] === PASSED
                    @test occursin("retrying on the same worker (retry 1 of 1)", out)
                    a = Runtests.Private.read_run_state(run.runstate.files[findfirst(==("A"), p.packages.name)].path)
                    st = a.statuses[findfirst(it -> it.name == "flaky", a.items)]
                    @test st.state === PASSED && st.attempt == 2
                end
            end
        end
    end
end
