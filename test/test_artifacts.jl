# Evidence from failed attempts: what an item writes into `Runtests.artifacts_dir()`,
# and what the producers it registers with `Runtests.on_failure` write once its attempt
# has failed. Kept for an attempt that fails, deleted for one that passes, and never a
# reason for a verdict to change.

using Runtests.Private: prepare, execute, exclusively, nitems, read_config, read_run_state, runstate_files,
    logs_dir, attempt_artifacts, stall_limit, STALL_LIMIT_OVERRIDE, RunStalled, ConfigError, plan, run_item,
    ItemSpec, PASSED, FAILED, ERRORED, SKIPPED, BROKEN_CHAIN, EVENT_ATTEMPT
using Runtests.RuntestsWorkers: RuntestsWorkers, artifacts_log_path, ARTIFACT_FILES, ARTIFACT_PRODUCERS,
    PENDING_ARTIFACTS, finish_artifacts
using Base.ScopedValues: with

# The items of one run, each a case the run must get right; `ENV["RUNTESTS_ART_MARKS"]`
# is where an item leaves word of what it saw, and where a producer that must not run
# would say it did.
const ART_ITEMS = raw"""
@testitem "passes with files and a producer" begin
    write(joinpath(Main.Runtests.artifacts_dir(), "out.txt"), "written")
    Main.Runtests.on_failure(d -> touch(joinpath(ENV["RUNTESTS_ART_MARKS"], "passes")))
    @test Main.Runtests.artifacts_dir() == Main.Runtests.artifacts_dir()
end

@testitem "registers and passes" begin
    Main.Runtests.on_failure(d -> touch(joinpath(ENV["RUNTESTS_ART_MARKS"], "registers")))
    @test true
end

@testitem "fails an assertion" begin
    values = collect(1:10)
    write(joinpath(Main.Runtests.artifacts_dir(), "out.txt"), "written")
    Main.Runtests.on_failure(d -> write(joinpath(d, "sum.txt"), string(sum(values))))
    push!(values, 100)
    @test false
end

@testitem "fails in a nested testset" begin
    Main.Runtests.on_failure(d -> touch(joinpath(d, "nested")))
    @testset "inner" begin
        @test 1 == 2
    end
end

@testitem "throws" begin
    Main.Runtests.on_failure(d -> touch(joinpath(d, "threw")))
    error("thrown by the item")
end

@testitem "fails fast" failfast=true begin
    Main.Runtests.on_failure(d -> touch(joinpath(d, "fast")))
    @test false
    @test false
end

@testitem "is broken" begin
    Main.Runtests.on_failure(d -> touch(joinpath(ENV["RUNTESTS_ART_MARKS"], "broken")))
    @test_broken false
end

@testitem "is skipped" skip=true begin
    Main.Runtests.on_failure(d -> touch(joinpath(ENV["RUNTESTS_ART_MARKS"], "skipped")))
end

@testitem "registers in order, from tasks" begin
    order(k) = d -> open(io -> println(io, k), joinpath(ENV["RUNTESTS_ART_MARKS"], "order"), "a")
    Main.Runtests.on_failure(order(1))
    wait(Threads.@spawn Main.Runtests.on_failure(order(2)))
    Main.Runtests.on_failure(order(3))
    @test false
end

@testitem "calls what it defined" begin
    Main.Runtests.on_failure(d -> defined_later(d))
    defined_later(d) = write(joinpath(d, "later.txt"), "defined in the item")
    struct Note
        text::String
    end
    Base.show(io::IO, n::Note) = print(io, "Note: ", n.text)
    Main.Runtests.on_failure(d -> write(joinpath(d, "shown.txt"), repr(Note("kept"))))
    @test false
end

@testitem "producers that fail" begin
    Main.Runtests.on_failure(d -> error("the first producer fails"))
    Main.Runtests.on_failure(d -> (touch(joinpath(d, "second")); @test 1 == 2))
    Main.Runtests.on_failure(d -> touch(joinpath(d, "third")))
    @test false
end

@testitem "asks too late" chain=:late begin
    Threads.@spawn begin
        sleep(0.5)
        msg = try
            Main.Runtests.on_failure(identity)
            "registered"
        catch e
            sprint(showerror, e)
        end
        write(joinpath(ENV["RUNTESTS_ART_MARKS"], "late"), msg)
    end
    @test true
end

@testitem "after the one that asks too late" chain=:late begin
    path = joinpath(ENV["RUNTESTS_ART_MARKS"], "late")
    deadline = time() + 30
    while !isfile(path) && time() < deadline
        sleep(0.05)
    end
    @test occursin("after the test item's body returned", read(path, String))
end

@testitem "asks where it may not" skip=(try
        Main.Runtests.artifacts_dir()
        false
    catch e
        e isa ArgumentError || rethrow()
        touch(joinpath(ENV["RUNTESTS_ART_MARKS"], "skip refused"))
        false
    end) begin
    Main.Runtests.on_failure(function (d)
        msg = try
            Main.Runtests.artifacts_dir()
            "allowed"
        catch e
            sprint(showerror, e)
        end
        write(joinpath(d, "during.txt"), msg)
    end)
    @test false
end

@testitem "fails in test_end" begin
    Main.Runtests.on_failure(d -> touch(joinpath(d, "after test_end")))
    @test true
end

@testitem "passes on a retry" retries=1 begin
    attempt = Main.Runtests.current_testitem().attempt
    write(joinpath(Main.Runtests.artifacts_dir(), "attempt.txt"), string(attempt))
    Main.Runtests.on_failure(d -> write(joinpath(d, "attempt.txt"), string(attempt)))
    @test attempt == 2
end

@testitem "chain passes first" chain=:evidence begin
    write(joinpath(Main.Runtests.artifacts_dir(), "first.txt"), "first")
    @test true
end

@testitem "chain fails second" chain=:evidence begin
    write(joinpath(Main.Runtests.artifacts_dir(), "second.txt"), "second")
    @test false
end

@testitem "in a sandbox" sandbox=true begin
    Main.Runtests.on_failure(d -> write(joinpath(d, "pid.txt"), string(getpid())))
    @test false
end

@testitem "holds a reference and passes" chain=:release begin
    mutable struct Held
        x::Int
    end
    held = Held(1)
    finalizer(h -> (ENV["RUNTESTS_ART_RELEASED"] = "yes"), held)
    Main.Runtests.on_failure(d -> held.x)
    @test true
end

@testitem "sees it let go of" chain=:release begin
    for _ in 1:50
        GC.gc(true)
        haskey(ENV, "RUNTESTS_ART_RELEASED") && break
        sleep(0.05)
    end
    @test get(ENV, "RUNTESTS_ART_RELEASED", "") == "yes"
end
"""

# A profile's `test_end` that may not register, and that fails one item on its own.
const ART_TEST_END = raw"""
[profiles.default]
test_end = '''
try
    Main.Runtests.on_failure(identity)
catch e
    e isa ArgumentError && touch(joinpath(ENV["RUNTESTS_ART_MARKS"], "test_end refused"))
end
Main.Runtests.current_testitem().name == "fails in test_end" && @test false
'''
"""

# Run `pkg` with `kwargs`, `marks` as the items' marker directory, and hand back the
# states by name, the run, its plan and what it printed.
function art_run(pkg, marks; kwargs...)
    (states, run, p), out = withenv("RUNTESTS_ART_MARKS" => marks, "RUNTESTS_ART_RELEASED" => nothing) do
        capture_run(() -> run_states(pkg; monitor = false, kwargs...))
    end
    return states, run, p, out
end

art_index(p, name) = findfirst(==(name), p.items.name)
art_dir(run, p, name; attempt = 1) = attempt_artifacts(run, art_index(p, name), attempt)
art_log(run, p, name; attempt = 1) = artifacts_log_path(art_dir(run, p, name; attempt))
art_read(path) = isfile(path) ? read(path, String) : ""

# What every run of `ART_ITEMS` must have done, wherever it ran them.
function check_art_run(states, run, p, out, marks)
    dir(name; kw...) = art_dir(run, p, name; kw...)
    produced(name, file; k = 1) = joinpath(dir(name), "producer_$k", file)

    @testset "an attempt that passes leaves nothing, and its producers never run" begin
        for name in ("passes with files and a producer", "registers and passes", "is broken", "is skipped",
                     "chain passes first", "holds a reference and passes", "asks too late")
            @test states[name] in (PASSED, SKIPPED)
            @test !ispath(dir(name))
            @test !ispath(artifacts_log_path(dir(name)))
        end
        @test states["is skipped"] === SKIPPED
        @test !any(isfile, joinpath.(marks, ("passes", "registers", "broken", "skipped")))
        # And what its producers held is let go of before the next item.
        @test states["sees it let go of"] === PASSED
    end

    @testset "an attempt that fails keeps what it wrote, and its producers run once, in order" begin
        @test states["fails an assertion"] === FAILED
        @test art_read(joinpath(dir("fails an assertion"), "files", "out.txt")) == "written"
        # A producer sees values as they are when it runs, not when it was registered.
        @test art_read(produced("fails an assertion", "sum.txt")) == "155"
        @test occursin("collected: 1 producer, 0 failed", art_read(art_log(run, p, "fails an assertion")))
        @test (states["fails in a nested testset"], states["throws"], states["fails fast"]) == (FAILED, ERRORED, FAILED)
        @test isfile(produced("fails in a nested testset", "nested"))
        @test isfile(produced("throws", "threw"))
        @test isfile(produced("fails fast", "fast"))
        @test readlines(joinpath(marks, "order")) == ["1", "2", "3"]
        @test all(k -> isdir(joinpath(dir("registers in order, from tasks"), "producer_$k")), 1:3)
        @test art_read(produced("calls what it defined", "later.txt")) == "defined in the item"
        @test art_read(produced("calls what it defined", "shown.txt"; k = 2)) == "Note: kept"
        @test isfile(produced("in a sandbox", "pid.txt"))
        # A `test_end` that fails is the attempt failing.
        @test states["fails in test_end"] === FAILED
        @test isfile(produced("fails in test_end", "after test_end"))
        # Only what opted in has a directory.
        listed = filter(n -> endswith(n, ".artifacts"), readdir(dirname(run.artifacts_prefix)))
        @test length(listed) == 12
    end

    @testset "a producer that fails is reported beside the evidence, and changes no verdict" begin
        i = art_index(p, "producers that fail")
        @test states["producers that fail"] === FAILED
        counts = Test.get_test_counts(run.statuses.testsets[i])
        @test (counts.fails, counts.errors) == (1, 0)
        log = art_read(art_log(run, p, "producers that fail"))
        @test occursin("the first producer fails", log)
        @test occursin("producer 2 (producer_2/): a test in it did not pass", log)
        @test occursin("collected: 3 producers, 2 failed", log)
        @test isfile(produced("producers that fail", "third"; k = 3))
        # Paths in it are the bundle's own, so a copy elsewhere reads the same.
        @test !occursin(dirname(run.artifacts_prefix), log)
    end

    @testset "registering is for the item's body alone" begin
        @test occursin("after the test item's body returned", art_read(joinpath(marks, "late")))
        @test isfile(joinpath(marks, "skip refused"))
        @test isfile(joinpath(marks, "test_end refused"))
        @test occursin("in a producer", art_read(produced("asks where it may not", "during.txt")))
    end

    @testset "each attempt has its own, and a retry that passes keeps the one that failed" begin
        @test states["passes on a retry"] === PASSED
        @test art_read(joinpath(dir("passes on a retry"), "files", "attempt.txt")) == "1"
        @test art_read(produced("passes on a retry", "attempt.txt")) == "1"
        @test !ispath(dir("passes on a retry"; attempt = 2))
        @test states["chain fails second"] === FAILED
        @test art_read(joinpath(dir("chain fails second"), "files", "second.txt")) == "second"
    end

    @testset "the failure and the closing block say where it is" begin
        # Without colour, which a run under `--color=yes` gives the paths.
        plain(text) = replace(text, r"\e\[[0-9;]*m" => "")
        @test occursin("artifacts: $(dir("fails an assertion"))", plain(out))
        closing = plain(Runtests.Private.conclusion_text(run))
        @test occursin("artifacts of 12 failed attempts:", closing)
        @test occursin("\"passes on a retry\" attempt 1: $(dir("passes on a retry"))", closing)
    end
end

@testset "artifacts" begin
    withenv("RUNTESTS_GROUP" => nothing) do; with_runstate_dir() do states_dir

    pkg = make_pkg("Evidence", "test/evidence_tests.jl" => ART_ITEMS, "test/TestItems.toml" => ART_TEST_END)

    @testset "on workers, with eager logs, copied for CI" begin
        marks, exported = mktempdir(), mktempdir()
        states, run, p, out = withenv("RUNTESTS_ARTIFACT_DIR" => exported) do
            art_run(pkg, marks; workers = 2, logs = :eager)
        end
        check_art_run(states, run, p, out, marks)
        # The copy of the run's logs holds the evidence too, at the same place.
        rel = relpath(art_dir(run, p, "fails an assertion"), dirname(run.logdir))
        @test read(joinpath(exported, rel, "producer_1", "sum.txt"), String) == "155"
        # The run state, read later, points at it.
        rs = read_run_state(run.runstate.path)
        @test occursin(art_dir(run, p, "fails an assertion"), sprint(show, MIME("text/plain"), rs))
    end

    @testset "in this process" begin
        marks = mktempdir()
        check_art_run(art_run(pkg, marks; workers = 0)..., marks)
    end

    @testset "a producer that hangs or dies ends its worker, and nothing else" begin
        bad = make_pkg("BadProducers", "test/bad_tests.jl" => raw"""
            @testitem "hangs in a producer" begin
                Main.Runtests.on_failure(function (d)
                    write(joinpath(d, "partial.txt"), "before the hang")
                    sleep(600)
                end)
                @test false
            end

            @testitem "dies in a producer" begin
                Main.Runtests.on_failure(function (d)
                    write(joinpath(d, "partial.txt"), "before the exit")
                    exit(3)
                end)
                @test false
            end

            @testitem "chained into a hang" chain=:hang begin
                Main.Runtests.on_failure(d -> sleep(600))
                @test false
            end

            @testitem "after the hang in its chain" chain=:hang begin
                @test true
            end

            @testitem "runs on whatever worker is left" begin
                @test true
            end
            """)
        states, run, p, out = art_run(bad, mktempdir(); workers = 1, artifacts_timeout = 3)
        @test states["hangs in a producer"] === FAILED
        @test states["dies in a producer"] === FAILED
        @test states["chained into a hang"] === FAILED
        @test states["after the hang in its chain"] === BROKEN_CHAIN
        @test states["runs on whatever worker is left"] === PASSED
        for name in ("hangs in a producer", "dies in a producer")
            @test isfile(joinpath(art_dir(run, p, name), "producer_1", "partial.txt"))
        end
        @test occursin("timed out after 3s (artifacts_timeout)", art_read(art_log(run, p, "hangs in a producer")))
        @test occursin("the worker died while the producers ran", art_read(art_log(run, p, "dies in a producer")))
        # The time the item took is the item's, not its producers'.
        @test run.statuses.elapsed[art_index(p, "hangs in a producer")] < 3
        # One attempt, recorded once; and a new worker after each that was lost.
        rs = read_run_state(run.runstate.path)
        attempts = [e.item for e in rs.events if e.kind === :attempt]
        @test sort(attempts) == sort(unique(attempts))
        @test count(e -> e.kind === :worker_up, rs.events) >= 3
        @test occursin("collecting the artifacts of \"hangs in a producer\" timed out", out)
    end

    @testset "a run stopped while producers run keeps the verdict" begin
        stalled = make_pkg("StalledProducer", "test/s_tests.jl" => raw"""
            @testitem "collects as the run is stopped" begin
                Main.Runtests.on_failure(function (d)
                    write(joinpath(d, "partial.txt"), "started")
                    sleep(600)
                end)
                @test false
            end
            """)
        path = with_runstate_dir() do _
            err = with(STALL_LIMIT_OVERRIDE => 15.0) do
                try
                    capture_run(() -> Runtests.runtests(stalled; workers = 1, monitor = false))
                    nothing
                catch e
                    e
                end
            end
            @test err isa RunStalled
            path = only(runstate_files(stalled))
            # Out of the directory that is deleted on the way out.
            keep = mktempdir()
            cp(path, joinpath(keep, basename(path)))
            cp(logs_dir(path), logs_dir(joinpath(keep, basename(path))))
            joinpath(keep, basename(path))
        end
        rs = read_run_state(path)
        @test only(rs.statuses).state === FAILED
        dir = joinpath(logs_dir(path), "item_1_1.artifacts")
        @test read(joinpath(dir, "producer_1", "partial.txt"), String) == "started"
        @test occursin("the run was stopped while the producers ran", read(artifacts_log_path(dir), String))
        @test live_worker_processes() == 0
    end

    @testset "artifacts_timeout: a setting like the other timeouts, recorded and replayed" begin
        testdir = joinpath(pkg, "test")
        @test read_config(testdir; timeout = 60).artifacts_timeout_s == 60
        @test read_config(testdir; timeout = 60, artifacts_timeout = 5.5).artifacts_timeout_s == 6
        withenv("RUNTESTS_ARTIFACTS_TIMEOUT" => "7") do
            @test read_config(testdir).artifacts_timeout_s == 7
            @test read_config(testdir; artifacts_timeout = 9).artifacts_timeout_s == 9
        end
        for bad in (0, -1, true, "x")
            @test_throws ArgumentError read_config(testdir; artifacts_timeout = bad)
        end
        withenv("RUNTESTS_ARTIFACTS_TIMEOUT" => "0") do
            @test_throws ConfigError read_config(testdir)
        end
        # Longer than any item may take, it is what the run's stall limit allows.
        p = first(prepare((pkg,); announce = false, timeout = 60, artifacts_timeout = 7200))
        @test stall_limit(p) >= 7200
        path = joinpath(states_dir, "recorded.runstate")
        Runtests.Private.finish_run_state!(Runtests.Private.init_run_state(path, first(prepare((pkg,); announce = false, artifacts_timeout = 11))))
        @test read_run_state(path).meta["artifacts_timeout"] == "11"
        @test first(prepare((pkg,); announce = false, replay = path)).cfg.artifacts_timeout_s == 11
    end

    @testset "outside a run" begin
        @testset "in this process, a call from anywhere but an item's body is refused" begin
            @test_throws ArgumentError Runtests.on_failure(identity)
            @test_throws ArgumentError Runtests.artifacts_dir()
        end

        @testset "an item run here keeps evidence for its result to decide" begin
            dir = joinpath(mktempdir(), "item_1_1.artifacts")
            spec(code) = ItemSpec(Int32(1), "here", @__FILE__, Int32(1), code, false, false, "", :default, Int8(1),
                                  false, "", UInt64(1), dir)
            res = run_item(spec(quote
                write(joinpath($(Runtests).artifacts_dir(), "a.txt"), "a")
                $(Runtests).on_failure(d -> write(joinpath(d, "b.txt"), "b"))
                @test false
            end))
            @test res.artifacts == ARTIFACT_FILES | ARTIFACT_PRODUCERS
            @test PENDING_ARTIFACTS[] !== nothing
            @test !isdir(joinpath(dir, "producer_1"))
            @test finish_artifacts(1, 1, true).producers == 1
            @test read(joinpath(dir, "producer_1", "b.txt"), String) == "b"
            @test PENDING_ARTIFACTS[] === nothing
            @test_throws ErrorException finish_artifacts(1, 1, true)
            # Producers left waiting go when the process runs its next item.
            run_item(spec(quote
                $(Runtests).on_failure(d -> touch(joinpath(d, "never")))
            end))
            @test PENDING_ARTIFACTS[] !== nothing
            run_item(spec(quote @test true end))
            @test PENDING_ARTIFACTS[] === nothing
        end

        @testset "a directory that cannot be made fails the call that asks for it" begin
            if !Sys.iswindows()
                locked = mktempdir()
                chmod(locked, 0o555)
                try
                    spec = ItemSpec(Int32(1), "locked", @__FILE__, Int32(1),
                                    quote $(Runtests).artifacts_dir() end, false, false, "", :default, Int8(1),
                                    false, "", UInt64(1), joinpath(locked, "item_1_1.artifacts"))
                    res = run_item(spec)
                    @test res.state === ERRORED
                    @test occursin("item_1_1.artifacts", sprint(show, only(res.testset.results)))
                finally
                    chmod(locked, 0o755)
                end
            end
        end

        @testset "storage a producer cannot write to fails that producer, and no verdict" begin
            if !Sys.iswindows()
                locked = make_pkg("LockedEvidence", "test/l_tests.jl" => raw"""
                    @testitem "locks its own evidence" begin
                        dir = dirname(Main.Runtests.artifacts_dir())
                        Main.Runtests.on_failure(d -> touch(joinpath(d, "never")))
                        Main.Runtests.on_failure(d -> touch(joinpath(d, "never either")))
                        chmod(dir, 0o555)
                        @test false
                    end
                    """)
                states, run, p, _ = art_run(locked, mktempdir(); workers = 0)
                dir = art_dir(run, p, "locks its own evidence")
                chmod(dir, 0o755)
                @test states["locks its own evidence"] === FAILED
                log = art_read(art_log(run, p, "locks its own evidence"))
                @test occursin("producer 1 (producer_1/) threw", log)
                @test occursin("collected: 2 producers, 2 failed", log)
            end
        end

        @testset "a pasted item keeps a failure's evidence in a directory it names" begin
            with_activated(pkg) do _
                _, out = withenv("RUNTESTS_ART_MARKS" => mktempdir()) do
                    capture_run() do
                        @testitem "pasted and failing" begin
                            write(joinpath(Main.Runtests.artifacts_dir(), "out.txt"), "pasted")
                            Main.Runtests.on_failure(d -> write(joinpath(d, "p.txt"), "collected"))
                            @test false
                        end
                    end
                end
                m = match(r"artifacts: (\S+\.artifacts)", out)
                @test m !== nothing
                dir = m.captures[1]
                @test read(joinpath(dir, "files", "out.txt"), String) == "pasted"
                @test read(joinpath(dir, "producer_1", "p.txt"), String) == "collected"
                rm(dirname(dir); recursive = true)
                _, out = withenv("RUNTESTS_ART_MARKS" => mktempdir()) do
                    capture_run() do
                        @testitem "pasted and passing" begin
                            write(joinpath(Main.Runtests.artifacts_dir(), "out.txt"), "pasted")
                            @test true
                        end
                    end
                end
                @test !occursin("artifacts:", out)
            end
        end

        @testset "a sandboxed pasted item collects on its worker" begin
            with_activated(pkg) do _
                _, out = withenv("RUNTESTS_ART_MARKS" => mktempdir()) do
                    capture_run() do
                    @testitem "pasted into a sandbox" sandbox=true begin
                        Main.Runtests.on_failure(d -> write(joinpath(d, "pid.txt"), string(getpid())))
                        @test false
                    end
                    end
                end
                m = match(r"artifacts: (\S+\.artifacts)", out)
                @test m !== nothing
                pid = parse(Int, read(joinpath(m.captures[1], "producer_1", "pid.txt"), String))
                @test pid != getpid()
                rm(dirname(m.captures[1]); recursive = true)
            end
        end

        @testset "an item stepped through keeps its state, and its producers run" begin
            stepped = make_pkg("SteppedEvidence", "test/s_tests.jl" => raw"""
                @testitem "stepped and failing" begin
                    kept = [1, 2, 3]
                    Main.Runtests.on_failure(d -> write(joinpath(d, "kept.txt"), string(sum(kept))))
                    @test false
                end
                """)
            with_activated(stepped) do _
                _, out = capture_run(() -> Runtests.Private.debug_item(f -> f(), "stepped and failing", nothing))
                m = match(r"artifacts: (\S+\.artifacts)", out)
                @test m !== nothing
                @test read(joinpath(m.captures[1], "producer_1", "kept.txt"), String) == "6"
                @test PENDING_ARTIFACTS[] === nothing
                rm(dirname(m.captures[1]); recursive = true)
            end
        end
    end

    end; end
end
