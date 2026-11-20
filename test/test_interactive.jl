# Test items outside a run: `Runtests.activate`, and a `@testitem` evaluated rather
# than scanned. What these check is that the two agree with a real run — same
# parser, same evaluator, same environment — because an item that behaves one way
# when pasted and another when scheduled is worse than one that cannot be pasted.

using Runtests.Private: activate, deactivate, is_activated, ScanFailure, ConfigError,
            collect_failures, PASSED, FAILED, SKIPPED, ERRORED
using Runtests.RuntestsWorkers: state_of
using Logging: Logging

const DEPS = fixture("TestDeps.jl")

@testset "interactive" begin
    @testset "every exported name has help at the REPL" begin
        # A comment between a docstring and its definition detaches the docstring.
        for name in names(Runtests)
            @test Base.Docs.hasdoc(Runtests, name)
        end
    end

    @testset "activate puts the session where a worker would be" begin
        before_project, before_path = Base.active_project(), copy(LOAD_PATH)
        with_activated(DEPS) do env
            @test is_activated()
            @test Base.active_project() == env
            @test env != before_project
            # The setups are importable, which is the other half of what a test
            # item gets and a REPL does not.
            @test joinpath(DEPS, "test", "testsetups") in LOAD_PATH
            @test Base.identify_package("DepSetup") !== nothing
        end
        @test !is_activated()
        @test Base.active_project() == before_project
        @test LOAD_PATH == before_path
    end

    @testset "activating twice is an error, deactivating twice is not" begin
        with_activated(DEPS) do _
            @test_throws ConfigError activate(DEPS)
        end
        @test deactivate() === nothing
        @test deactivate() === nothing
        @test !is_activated()
    end

    @testset "a call with no path after activate runs the activated package" begin
        # The active project is the package's generated test environment, which holds no
        # tests: a run, a dry run and a failure check go to the package itself.
        dir = make_pkg("ActivatedTarget", "test/a_test.jl" => "@testitem \"the activated item\" begin\n    @test true\nend\n")
        with_activated(dir) do _
            @test realpath(Runtests.Private.resolve_target(()).root) == realpath(dir)
            _, out = capture_run(() -> Runtests.runtests(; dry_run = true))
            @test occursin("\"the activated item\"", out)
            # A path given is the path given.
            @test realpath(Runtests.Private.resolve_target((DEPS,)).root) == realpath(DEPS)
        end
    end

    @testset "a pasted item runs, and its results come back" begin
        with_activated(DEPS) do _
            ts, out = capture_run() do
                @testitem "pasted pass" begin
                    x = 1 + 1
                    @test x == 2
                    @test true
                end
            end
            @test ts isa Test.AbstractTestSet
            @test state_of(ts) === PASSED
            @test ts.n_passed == 2
            # It announces itself the way a scheduled item does.
            @test occursin("RUN", out)
            @test occursin("DONE", out)
            @test occursin("pasted pass", out)
        end
    end

    @testset "a failing item is a result, not an exception" begin
        with_activated(DEPS) do _
            ts, out = capture_run() do
                @testitem "pasted fail" begin
                    @test 1 == 2
                end
            end
            @test state_of(ts) === FAILED
            @test length(collect_failures(ts)) == 1
            # ...and it says what failed, here, because there is no coordinator.
            @test occursin("1 == 2", out)
        end
    end

    @testset "an item that throws is an error, not a thrown exception" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted throw" begin
                    error("boom")
                end
            end
            @test state_of(ts) === ERRORED
        end
    end

    @testset "the body gets Test, the package, and the setups" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted imports" begin
                    using DepSetup
                    @test DepSetup.draw() isa Float64          # a setup module
                    @test TestDeps.pick([3, 4]) == 3           # the package under test
                    @test @isdefined(Test)                     # Test, without asking
                end
            end
            @test state_of(ts) === PASSED
            @test ts.n_passed == 3
        end
    end

    @testset "the body has soft scope, as it does in a file" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted softscope" begin
                    total = 0
                    for i in 1:3
                        total += i
                    end
                    @test total == 6
                end
            end
            @test state_of(ts) === PASSED
        end
    end

    @testset "an included test file runs each of its items, as a pasted item runs" begin
        with_activated(DEPS) do _
            file = joinpath(mktempdir(), "included_tests.jl")
            write(file, """
            @testitem "included first" begin
                @test TestDeps.pick([3, 4]) == 3
            end
            @testitem "included second" begin
                total = 0
                for i in 1:3
                    total += i
                end
                @test total == 6 && @isdefined(Test)
            end
            """)
            ts, out = capture_run(() -> include(file))
            @test state_of(ts) === PASSED
            @test occursin("included first", out) && occursin("included second", out)
            @test count("· DONE", out) == 2
        end
    end

    @testset "a pasted item runs in the root of its package, and the session stays where it is" begin
        with_activated(DEPS) do _
            elsewhere = mktempdir()
            ts, back = cd(elsewhere) do
                ts, _ = capture_run(() -> @eval @testitem "pasted where" begin
                    @test samefile(pwd(), $DEPS)
                end)
                ts, pwd()
            end
            @test state_of(ts) === PASSED
            @test samefile(back, elsewhere)
        end
    end

    @testset "skip is honoured, literally and as an expression" begin
        with_activated(DEPS) do _
            static, _ = capture_run() do
                @testitem "pasted skip static" skip=true begin
                    @test false
                end
            end
            @test isempty(collect_failures(static))
            dynamic, _ = capture_run() do
                @testitem "pasted skip dynamic" skip=(1 + 1 == 2) begin
                    @test false
                end
            end
            @test isempty(collect_failures(dynamic))
        end
    end

    @testset "failfast stops the item at its first failure" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted failfast" failfast=true begin
                    @test 1 == 2
                    @test 3 == 4
                end
            end
            @test length(collect_failures(ts)) == 1   # the second never ran
        end
    end

    @testset "a keyword that is wrong in a file is wrong here too" begin
        with_activated(DEPS) do _
            @test_throws ScanFailure (
                @testitem "bad tags" tags = "not a vector" begin
                    @test true
                end
            )
            @test_throws ScanFailure (
                @testitem "unknown keyword" nonsense = 1 begin
                    @test true
                end
            )
            @test_throws ScanFailure (
                @testitem "given twice" timeout = 1 timeout = 2 begin
                    @test true
                end
            )
        end
    end

    @testset "keywords a single evaluation cannot honour are named" begin
        with_activated(DEPS) do _
            logs = Test.collect_test_logs() do
                capture_run() do
                    @testitem "pasted knobs" timeout=5 retries=2 throttle=:c tags=[:x] begin
                        @test true
                    end
                end
            end
            warnings = filter(r -> r.level == Logging.Warn, first(logs))
            @test length(warnings) == 1
            msg = first(warnings).message
            # Every one of them named, and why.
            for key in ("timeout", "retries", "throttle")
                @test occursin(key, msg)
            end
            # `tags` is not among them: selecting nothing is what a single pasted
            # item does, and saying so on every paste is noise.
            @test !occursin("tags", msg)
            @test occursin("pasted knobs", msg)
        end
    end

    @testset "sandbox=true really uses another process" begin
        with_activated(DEPS) do _
            ts, _ = withenv("RUNTESTS_REPL_PID" => string(getpid())) do
                capture_run() do
                    @testitem "pasted sandbox" sandbox=true begin
                        @test getpid() != parse(Int, ENV["RUNTESTS_REPL_PID"])
                    end
                end
            end
            @test state_of(ts) === PASSED
            @test isempty(collect_failures(ts))
        end
    end

    @testset "profile=:profile uses that profile's flags and init" begin
        dir = make_pkg(
            "PastedProfile",
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n",
            profile_files("bounds"; init = "const FROM_INIT = 7")...,
        )
        with_activated(dir) do _
            ts, _ = capture_run() do
                @testitem "pasted profile" profile=:bounds begin
                    @test Base.JLOptions().check_bounds == 1
                    @test Main.FROM_INIT == 7
                end
            end
            @test state_of(ts) === PASSED
            @test ts.n_passed == 2
        end
    end

    # What follows is what a run does for a sandboxed item, and a pasted one has to
    # do the same: the default profile from TestItems.toml, a profile's preferences,
    # its `test_end`'s verdict.
    @testset "sandbox=true runs under [profiles.default]" begin
        dir = make_pkg("PastedDefault", "test/TestItems.toml" => "[profiles.default.env]\nRUNTESTS_PASTED_FLAG = \"configured\"\n")
        with_activated(dir) do _
            ts, _ = capture_run() do
                @testitem "pasted default profile" sandbox=true begin
                    @test get(ENV, "RUNTESTS_PASTED_FLAG", "unset") == "configured"
                end
            end
            @test state_of(ts) === PASSED
        end
    end

    @testset "a pasted profile's preferences reach its worker" begin
        dir = make_pkg("PastedPrefs", "test/prefs.toml" => "[PastedPrefs]\nmode = \"fast\"\n",
                       "test/TestItems.toml" => "[profiles.tuned]\npreferences = \"prefs.toml\"\n")
        uuid = Runtests.Private.TOML.parsefile(joinpath(dir, "Project.toml"))["uuid"]
        with_activated(dir) do _
            ts, _ = capture_run() do
                Core.eval(Main, :(@testitem "pasted preferences" profile=:tuned begin
                    @test get(Base.get_preferences(Base.UUID($uuid)), "mode", "unset") == "fast"
                end))
            end
            @test state_of(ts) === PASSED
        end
    end

    @testset "a pasted profile's test_end is said, not counted, and a skipped item runs none" begin
        dir = make_pkg("PastedEnd", "test/TestItems.toml" => "[profiles.checked]\n",
                       profile_files("checked"; test_end = "@test false")...)
        with_activated(dir) do _
            passed, out = capture_run() do
                @testitem "pasted checked" profile=:checked begin
                    @test true
                end
            end
            skipped, skipped_out = capture_run() do
                @testitem "pasted checked skip" profile=:checked skip=true begin
                    @test true
                end
            end
            # As in a run, the result is the body's, and the hook's failure is said.
            @test state_of(passed) === PASSED
            @test isempty(collect_failures(passed))
            @test occursin("test_end of profile `checked`: 1 did not pass: Test Failed", out)
            @test !occursin("test_end of profile", skipped_out)   # the hook never ran
        end
    end

    @testset "a profile that does not exist says so" begin
        with_activated(DEPS) do _
            err = try
                @testitem "pasted missing profile" profile=:nope begin
                    @test true
                end
                nothing
            catch e
                e
            end
            @test err isa ConfigError
            @test occursin("nope", sprint(showerror, err))
        end
    end

    @testset "no worker is left behind by a sandboxed item" begin
        before = live_worker_processes()
        with_activated(DEPS) do _
            capture_run() do
                @testitem "pasted sandbox cleanup" sandbox=true begin
                    @test true
                end
            end
        end
        @test timedwait(() -> live_worker_processes() <= before, 10) === :ok
    end
end

@testset "a pasted sandbox has a process, so it keeps its keywords" begin
    # Without `sandbox` there is nothing to stop and nothing to restart, so
    # `timeout` and `retries` are ignored and said to be. With it the item runs in
    # a worker, which is exactly what those two need.

    @testset "the warning covers only what a sandbox cannot supply" begin
        ignored(sandboxed) = [k for (k, _) in Runtests.Private.repl_ignored(sandboxed)]
        @test :timeout in ignored(false)
        @test :retries in ignored(false)
        @test :timeout ∉ ignored(true)
        @test :retries ∉ ignored(true)
        # A throttle has nothing else to run with either way, and `tags` select
        # nothing here — which was never worth a line.
        @test :throttle in ignored(true)
        @test :tags ∉ ignored(false)
    end

    @testset "a timeout stops it, and retries start it again" begin
        # Pinned to a fixture rather than left on whatever project the session is
        # in: under `Pkg.test` that is an unnamed generated environment, and a
        # sandbox asks for a test environment to be built from it.
        with_activated(DEPS) do _
        with_marker_dir() do work
            marker = joinpath(work, "count")
            withenv("RUNTESTS_CRASH_MARKER" => marker) do
                ex = :(@testitem "paste retries" timeout=3 retries=1 sandbox=true begin
                    k = let p = ENV["RUNTESTS_CRASH_MARKER"]
                        n = isfile(p) ? parse(Int, read(p, String)) : 0
                        write(p, string(n + 1))
                        n
                    end
                    k < 1 && sleep(30)
                    @test k == 1
                end)
                ts = Core.eval(Main, ex)
                # The first attempt was stopped at the timeout; the second passed.
                @test parse(Int, read(marker, String)) == 2
                @test isempty(collect_failures(ts))
            end
        end
        end
    end

    @testset "a retry knows it is one, and draws the numbers the first attempt drew" begin
        with_activated(DEPS) do _
            log = tempname()
            withenv("RUNTESTS_ATTEMPTS" => log) do
                ts, _ = capture_run() do
                    # The fixture's workers load RuntestsWorkers, not Runtests.
                    @testitem "paste attempts" retries=1 sandbox=true begin
                        attempt = Main.Runtests.current_testitem().attempt
                        open(io -> println(io, attempt, " ", rand(UInt64)), ENV["RUNTESTS_ATTEMPTS"], "a")
                        @test attempt == 2
                    end
                end
                @test state_of(ts) === PASSED
            end
            attempts = split.(readlines(log))
            @test first.(attempts) == ["1", "2"]
            @test attempts[1][2] == attempts[2][2]
        end
    end

    @testset "a skipped item is not retried" begin
        # Skipping is an outcome, not a failure to try again.
        with_activated(DEPS) do _
            log = tempname()
            withenv("RUNTESTS_ATTEMPTS" => log) do
                capture_run() do
                    @testitem "paste skipped" retries=2 sandbox=true skip=(open(io -> println(io, "asked"), ENV["RUNTESTS_ATTEMPTS"], "a"); true) begin
                        @test false
                    end
                end
            end
            @test readlines(log) == ["asked"]
        end
    end

    @testset "a skip after a failure leaves the failure, as in a run" begin
        with_activated(DEPS) do _
            log = tempname()
            withenv("RUNTESTS_ATTEMPTS" => log) do
                ts, _ = capture_run() do
                    @testitem "paste fails, then skips" retries=1 sandbox=true skip=isfile(ENV["RUNTESTS_ATTEMPTS"]) begin
                        touch(ENV["RUNTESTS_ATTEMPTS"])
                        @test false
                    end
                end
                @test state_of(ts) === FAILED
            end
        end
    end

    @testset "a sandbox that never finishes reports the timeout" begin
        with_activated(DEPS) do _
            ex = :(@testitem "paste overruns" timeout=2 sandbox=true begin
                sleep(30)
                @test true
            end)
            @test_throws Runtests.Private.TimeoutException Core.eval(Main, ex)
        end
    end

    @testset "a profile's init and test_end are held to their limits" begin
        # As in a run: a hook past `init_timeout` or `test_end_timeout` is stopped instead
        # of holding the session for as long as it takes. A late `init` stops the item; a
        # late `test_end` leaves it the body's result.
        dir = make_pkg("PastedHooks", "test/TestItems.toml" => """
            [run]
            init_timeout = 2
            test_end_timeout = 2

            [profiles.slow_init]

            [profiles.slow_end]
            """,
            profile_files("slow_init"; init = "sleep(60)")..., profile_files("slow_end"; test_end = "sleep(60)")...)
        with_activated(dir) do _
            ex(profile) = :(@testitem $("pasted $profile") profile=$(QuoteNode(profile)) begin
                @test true
            end)
            took = @elapsed @test_throws Runtests.Private.TimeoutException Core.eval(Main, ex(:slow_init))
            @test took < 40
            # A `test_end` past its limit is ended and said; the body's result stands.
            took = @elapsed begin
                ts, out = capture_run(() -> Core.eval(Main, ex(:slow_end)))
            end
            @test took < 40
            @test state_of(ts) === PASSED
            @test occursin("test_end of profile `slow_end`: the `test_end` expression of profile `slow_end`", out)
        end
    end
end
