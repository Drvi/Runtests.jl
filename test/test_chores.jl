using Runtests.Private: prepare, init_run_state, finish_run_state!, read_run_state, runstate_files,
                    write_status!, prunable_runstates, KEEP_RUNS, PASSED, FAILED, nitems

declared(names...) = join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in names))

# `n` run states of this machine's in `dir`, oldest first and newer than the `after`
# recorded before them, each with the items `ran` names passed, every item by
# default, and `failed` failed.
function recorded_runs(dir, pkg, n; after = 0, ran = nothing, failed = String[])
    p, _ = prepare((pkg,); announce = false)
    return map(1:n) do i
        path = joinpath(dir, string(1_000_000 + after + i, "-1.runstate"))
        rsf = init_run_state(path, p)
        for k in 1:nitems(p)
            name = p.items.name[k]
            name in failed ? write_status!(rsf, k, FAILED, 1, 1; elapsed = 0.1) :
                (ran === nothing || name in ran) && write_status!(rsf, k, PASSED, 1, 1; elapsed = 0.1)
        end
        finish_run_state!(rsf)
        path
    end
end

# What `chores` returned, or the exception it threw, with what it printed.
chores_out(args...; kw...) = capture_run(() -> try
    Runtests.chores(args...; kw...)
catch e
    e isa Runtests.ChoresError || rethrow()
    e
end)

@testset "chores" begin
    @testset "a suite in order has nothing to do" begin
        dir = make_pkg("Tidy", "test/a_test.jl" => declared("one", "two"),
                       "test/TestItems.toml" => "[order]\nfirst = [\"two\"]\n")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            ok, out = chores_out(dir; dry_run = true)
            @test ok === true
            @test occursin("test items: 2 in 1 file, all valid", out)
            @test occursin("config: $(joinpath("test", "TestItems.toml")), valid", out)
            @test occursin("setups: none", out)
            @test occursin("run states: none", out)
            @test occursin("└ nothing to do", out)
            # Nothing to do, nothing to throw.
            done, out = chores_out(dir)
            @test done === true && occursin("└ nothing to do", out)
        end
    end

    @testset "a step that takes long says how long, after its first line's words" begin
        with_duration = Runtests.Private.with_duration
        @test with_duration("templates: 1, 1 expanded:\n  test/a_tests.jl: expanded\n", 6.61) ==
              "templates: 1, 1 expanded, in 6.6s:\n  test/a_tests.jl: expanded\n"
        @test with_duration("test items: 3 in 2 files, all valid\n", 4.0) == "test items: 3 in 2 files, all valid, in 4.0s\n"
        @test with_duration("setups: none", 75.0) == "setups: none, in 1m15.0s"
        # A quick one, and one that said nothing, are left as they are.
        @test with_duration("setups: none\n", 2.9) == "setups: none\n"
        @test with_duration("", 10.0) == ", in 10.0s"
    end

    @testset "a dry run changes nothing, and a run does what it reported" begin
        dir = make_pkg("Untidy", "test/a_test.jl" => declared("one"),
                       "test/testsetups/Helpers.jl" => "module Helpers\nusing Random\nend\n")
        setups = joinpath(dir, "test", "testsetups")
        runs = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => runs) do
            # Two more than a run keeps.
            recorded = recorded_runs(runs, dir, KEEP_RUNS + 2)
            ok, out = chores_out(dir; dry_run = true)
            @test ok === false
            @test occursin("chores, checking only", out)
            @test occursin(r"setups: 1 of 1 to change(, in \S+)?:", out)
            @test occursin("`Helpers`: would move to $(joinpath("Helpers", "src", "Helpers.jl"))", out)
            @test occursin("2 of this machine's to delete: beyond the newest $KEEP_RUNS", out)
            @test occursin("to do: 3, which `Runtests.chores()` does", out)
            @test isfile(joinpath(setups, "Helpers.jl"))
            @test runstate_files(dir) == recorded

            done, out = chores_out(dir)
            @test done === true
            @test occursin("`Helpers`: moved to", out)
            @test occursin("└ done: 3", out)
            @test isfile(joinpath(setups, "Helpers", "Project.toml"))
            @test runstate_files(dir) == recorded[3:end]

            ok, out = chores_out(dir; dry_run = true)
            @test ok === true
            @test occursin("setups: 1, all up to date", out)
            @test occursin("└ nothing to do", out)
        end
    end

    @testset "run states are kept as a run keeps them, and only this machine's go" begin
        dir = make_pkg("OldRuns", "test/a_test.jl" => declared("one"))
        runs = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => runs) do
            recorded = recorded_runs(runs, dir, KEEP_RUNS + 4)
            # The two oldest: one recorded on another machine, one that cannot be read.
            here = Runtests.Private.machine_name()
            elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
            write(recorded[1], replace(read(recorded[1], String), here => elsewhere))
            @test read_run_state(recorded[1]).meta["host"] == elsewhere
            write(recorded[2], "not a run state")
            # This machine's newest twenty stay, however old the others are.
            @test prunable_runstates(dir; names = Set(["one"])) == recorded[3:4]
            @test prunable_runstates(dir) == recorded[3:4]
        end
    end

    @testset "chores deletes what a run's pruning deletes, and nothing among the newest" begin
        dir = make_pkg("Useless", "test/a_test.jl" => declared("one"))
        file = joinpath(dir, "test", "a_test.jl")
        runs = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => runs) do
            # Of an item the suite has since lost, and one stopped before any item ran.
            write(file, declared("gone"))
            renamed = recorded_runs(runs, dir, 2)
            write(file, declared("one"))
            p, _ = prepare((dir,); announce = false)
            stopped = joinpath(runs, "1000003-1.runstate")
            finish_run_state!(init_run_state(stopped, p); cancelled = true)
            useful = recorded_runs(runs, dir, 3; after = 3)
            # Among the newest twenty they stay, whatever they hold: another branch
            # may have `gone`.
            @test isempty(prunable_runstates(dir; names = Set(["one"])))
            done, out = chores_out(dir)
            @test done === true && occursin("none to delete", out)
            # Beyond them, the same ones go as a run's own pruning deletes.
            newer = recorded_runs(runs, dir, KEEP_RUNS; after = 6)
            pruned = prunable_runstates(dir; names = Set(["one"]))
            @test pruned == [renamed; stopped; useful]
            done, out = chores_out(dir)
            @test done === true && occursin("$(length(pruned)) of this machine's deleted", out)
            @test runstate_files(dir) == newer
        end
    end

    @testset "beyond the newest, a failing item's last verdict keeps its run state" begin
        dir = make_pkg("OldFailure", "test/a_test.jl" => declared("one", "two"))
        runs = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => runs) do
            # The oldest run failed `two`; every run since ran only `one`.
            first_ = only(recorded_runs(runs, dir, 1; failed = ["two"]))
            since = recorded_runs(runs, dir, KEEP_RUNS + 2; after = 1, ran = ["one"])
            stale = prunable_runstates(dir; names = Set(["one", "two"]))
            @test !(first_ in stale) && stale == since[1:2]
            @test Runtests.Private.failing_items(dir) == ["two"]
        end
    end

    @testset "a package without test files, a fixture in another's test/ say, has nothing to do" begin
        outer = make_pkg("Outer", "test/a_test.jl" => declared("one"))
        fixture = mkpath(joinpath(outer, "test", "testfixtures", "Inner"))
        write(joinpath(fixture, "Project.toml"), "name = \"Inner\"\nuuid = \"$(next_uuid())\"\nversion = \"0.1.0\"\n")
        mkpath(joinpath(fixture, "src"))
        write(joinpath(fixture, "src", "Inner.jl"), "module Inner\nend\n")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            # Asked of the fixture, which is a package of its own and has no tests.
            ok, out = chores_out(fixture; dry_run = true)
            @test ok === true
            @test occursin(Regex("test items: none, no test files under \\Q$(joinpath("test", ""))\\E(, in \\S+)?\n"), out) &&
                  occursin("nothing to do", out)
            done, _ = chores_out(fixture)
            @test done === true
            # Asked of the package around it, the fixture is no test file of its own.
            ok, out = chores_out(outer; dry_run = true)
            @test ok === true && occursin("test items: 1 in 1 file, all valid", out)
            # A run of the fixture has nothing to run, and says so.
            @test_throws Runtests.NoTestsError Runtests.runtests(fixture; dry_run = true)
        end
    end

    @testset "a fixture package in test/testfixtures/ is no stray, however many threads read the suite" begin
        # The checks of the suite run in tasks, which move between threads. A walk
        # that `walkdir` led went into a fixture's `src/` while it was taking the
        # fixture out of the walk, and took its source for a misnamed test file.
        repo = dirname(@__DIR__)
        pkg = make_pkg("WithFixture", "test/a_test.jl" => declared("one"))
        fixture = mkpath(joinpath(pkg, "test", "testfixtures", "Inner", "src"))
        write(joinpath(dirname(fixture), "Project.toml"), "name = \"Inner\"\nuuid = \"$(next_uuid())\"\nversion = \"0.1.0\"\n")
        write(joinpath(fixture, "Inner.jl"), "module Inner\nend\n")
        script = """
            using Runtests
            fails = count(_ -> !redirect_stdout(() -> Runtests.chores(ARGS[1]; dry_run = true), devnull), 1:10)
            print(Threads.nthreads(), " threads, ", fails, " failed")
            """
        cmd = addenv(`$(Base.julia_cmd()) --threads=4 --project=$repo --startup-file=no -e $script $pkg`,
                     "JULIA_LOAD_PATH" => join([repo, joinpath(repo, "test"), ""], Runtests.Private.PATHSEP),
                     "RUNTESTS_RUNSTATE_DIR" => mktempdir())
        @test read(cmd, String) == "4 threads, 0 failed"
    end

    @testset "what a run would refuse to start on is left to a person" begin
        # A test file that does not parse, beside settings with a key they do not take,
        # and a setup that can be made a package.
        dir = make_pkg("Broken", "test/a_test.jl" => "@testitem \"open\" begin\n",
                       "test/TestItems.toml" => "[run]\nworkerz = 2\n",
                       "test/testsetups/Helpers.jl" => "module Helpers\nend\n")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            before = read(joinpath(dir, "test", "a_test.jl"), String)
            # A dry run says so without throwing, and changes nothing.
            ok, out = chores_out(dir; dry_run = true)
            @test ok === false
            @test occursin("└ to fix by hand: 2 · the rest `Runtests.chores()` does", out)
            @test isfile(joinpath(dir, "test", "testsetups", "Helpers.jl"))
            err, out = chores_out(dir)
            @test err isa Runtests.ChoresError
            @test occursin("2 problems to fix by hand", sprint(showerror, err))
            @test occursin(r"test items: 1 problem(, in \S+)?:", out)
            @test occursin("a_test.jl:", out)
            @test occursin("config: unknown key `workerz`", out)
            # What needs no person is done before it says what does.
            @test occursin("└ done: 1 · to fix by hand: 2", out)
            @test isfile(joinpath(dir, "test", "testsetups", "Helpers", "Project.toml"))
            @test read(joinpath(dir, "test", "a_test.jl"), String) == before
        end
        # Settings that name an item the suite does not have.
        dir = make_pkg("Misnamed", "test/a_test.jl" => declared("one"),
                       "test/TestItems.toml" => "[order]\nfirst = [\"onw\"]\n")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            ok, out = chores_out(dir; dry_run = true)
            @test ok === false
            @test occursin("config: [order] of TestItems.toml names test items that do not exist:", out)
            @test occursin("onw", out)
            @test occursin("└ to fix by hand: 1", out)
        end
    end

    @testset "a config file it is given is checked as a run given it would check it" begin
        other = mktempdir()
        conf(name, text) = (path = joinpath(other, name); write(path, text); path)
        good = conf("good.toml", "[order]\nfirst = [\"two\"]\n")
        misnamed = conf("misnamed.toml", "[order]\nfirst = [\"onw\"]\n")
        badkey = conf("badkey.toml", "[run]\nworkerz = 2\n")
        gone = joinpath(other, "gone.toml")
        dir = make_pkg("ChoreConfigs", "test/a_test.jl" => declared("one", "two"))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            # One in order: said beside the suite's own, and nothing to do.
            ok, out = chores_out(dir; dry_run = true, config = good)
            @test ok === true
            @test occursin("config: none", out)
            @test occursin("config: $good, valid", out)
            # Several: each checked, counted, and named in what is wrong with it.
            ok, out = chores_out(dir; dry_run = true, config = [good, misnamed, badkey, gone])
            @test ok === false
            @test occursin("config: $good, valid", out)
            @test occursin("[order] of $misnamed names test items that do not exist:", out)
            @test occursin("unknown key `workerz`", out) && occursin("badkey.toml", out)
            @test occursin("$gone does not exist", out)
            @test occursin("└ to fix by hand: 3", out)
        end
        # A profile only the named file has: the suite's own file lacks it, and the
        # named one still serves the item that names it.
        prof = conf("prof.toml", "[profiles.fast]\nthreads = \"1\"\n")
        dir = make_pkg("ChoreProfile", "test/a_test.jl" => "@testitem \"fast\" sandbox=:fast begin\n    @test true\nend\n")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            ok, out = chores_out(dir; dry_run = true, config = prof)
            @test ok === false
            @test occursin("has no [profiles.fast] in TestItems.toml", out)
            @test occursin("config: $prof, valid", out)
            @test occursin("└ to fix by hand: 1", out)
        end
        # Test items that do not read: the named file's own settings are still checked.
        dir = make_pkg("ChoreUnread", "test/a_test.jl" => "@testitem \"open\" begin\n")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            ok, out = chores_out(dir; dry_run = true, config = [good, badkey])
            @test ok === false
            @test occursin("config: $good reads; the items it names are checked once the test items read", out)
            @test occursin("unknown key `workerz`", out) && occursin("badkey.toml", out)
        end
    end
end
