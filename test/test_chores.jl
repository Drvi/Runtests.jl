using Runtests.Private: prepare, init_run_state, finish_run_state!, read_run_state, runstate_files,
                    write_status!, stale_runstates, KEEP_RUNS, PASSED, FAILED, nitems

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
            @test occursin("setups: 1 of 1 to change:", out)
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
            here = gethostname()
            elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
            write(recorded[1], replace(read(recorded[1], String), here => elsewhere))
            @test read_run_state(recorded[1]).meta["host"] == elsewhere
            write(recorded[2], "not a run state")
            # This machine's newest twenty stay, however old the others are.
            @test stale_runstates(dir, Set(["one"])) == recorded[3:4]
            @test stale_runstates(dir) == recorded[3:4]
        end
    end

    @testset "among the newest, only a run state with nothing about the suite's items goes" begin
        dir = make_pkg("Useless", "test/a_test.jl" => declared("one"))
        file = joinpath(dir, "test", "a_test.jl")
        runs = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => runs) do
            useful = recorded_runs(runs, dir, 3)
            # Of items the suite has since lost.
            write(file, declared("gone"))
            renamed = recorded_runs(runs, dir, 2; after = 3)
            write(file, declared("one"))
            # A dry run, and a run stopped before any item finished: nothing in either.
            p, _ = prepare((dir,); announce = false)
            dry = joinpath(runs, "1000006-1.runstate")
            finish_run_state!(init_run_state(dry, p; dry_run = true))
            stopped = joinpath(runs, "1000007-1.runstate")
            finish_run_state!(init_run_state(stopped, p); cancelled = true)
            # And one that ran `one`, however little else: it stays.
            partial = recorded_runs(runs, dir, 1; after = 7)
            @test stale_runstates(dir, Set(["one"])) == [renamed; dry; stopped]
            # With the suite unread nothing says what it has: fewer than twenty, all stay.
            @test isempty(stale_runstates(dir))

            done, out = chores_out(dir)
            @test done === true
            @test occursin("4 of this machine's deleted", out)
            @test runstate_files(dir) == [useful; partial]
        end
    end

    @testset "beyond the newest, a failing item's last verdict keeps its run state" begin
        dir = make_pkg("OldFailure", "test/a_test.jl" => declared("one", "two"))
        runs = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => runs) do
            # The oldest run failed `two`; every run since ran only `one`.
            first_ = only(recorded_runs(runs, dir, 1; failed = ["two"]))
            since = recorded_runs(runs, dir, KEEP_RUNS + 2; after = 1, ran = ["one"])
            stale = stale_runstates(dir, Set(["one", "two"]))
            @test !(first_ in stale) && stale == since[1:2]
            @test Runtests.Private.failing_items(dir) == ["two"]
        end
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
            @test occursin("test items: 1 problem:", out)
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
