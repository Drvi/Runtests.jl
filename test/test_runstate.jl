using Random: Random
using Runtests.Private: init_run_state, write_status!, finish_run_state!, read_run_state, history,
            runstate_files, runstate_dir, prune_runstates, new_runstate_path, prepare,
            execute, plan, scan, discover, setup_modules, read_config, Filter, History,
            UNSEEN, RUNNING, PASSED, FAILED, ERRORED, TIMEDOUT, SKIPPED, nitems, RS_STATUS_BYTES,
            project_revision, repository_root

function a_plan(pkg=fixture("Basic.jl"))
    testdir = joinpath(pkg, "test")
    items = scan(discover(testdir), Filter(), setup_modules(testdir))
    return plan(items, read_config(testdir); root=pkg)
end

# The `n`th run state recorded for `pkg` in `dir`, each item `outcomes` names with its
# state and duration: a run of the whole suite, or of only those items.
function record_run(dir, pkg, n, outcomes; whole = false)
    p, _ = prepare((pkg,); name = whole ? nothing : Set(keys(outcomes)), announce = false)
    path = joinpath(dir, string(1_000_000 + n, "-1.runstate"))
    rsf = init_run_state(path, p)
    for i in 1:nitems(p)
        haskey(outcomes, p.items.name[i]) || continue
        state, elapsed = outcomes[p.items.name[i]]
        write_status!(rsf, i, state, 1, 1; elapsed)
    end
    finish_run_state!(rsf)
    return path
end

@testset "run state" begin
    @testset "by default a project's run states are the depot's own, and go with the project" begin
        depot = mktempdir()
        pushfirst!(DEPOT_PATH, depot)
        try
            withenv("RUNTESTS_RUNSTATE_DIR" => nothing) do
                one_item = "test/a_test.jl" => "@testitem \"one\" begin\n    @test true\nend\n"
                kept, gone, foreign = make_pkg("Kept", one_item), make_pkg("Gone", one_item),
                                      make_pkg("Foreign", one_item)
                paths = Dict(pkg => new_runstate_path(pkg) for pkg in (kept, gone, foreign))
                for (pkg, path) in paths
                    # Not under `scratchspaces/`, which `Pkg.gc` empties of what no package registered.
                    @test startswith(path, joinpath(depot, "runtests", "runs"))
                    # Named for the package, so a person can tell whose it is.
                    @test occursin(r"^[A-Za-z]+-[0-9a-f]{8}$", basename(dirname(path)))
                    @test startswith(basename(dirname(path)), Runtests.Private.project_name_of(joinpath(pkg, "Project.toml")))
                    finish_run_state!(init_run_state(path, a_plan(pkg)))
                    @test read(joinpath(dirname(path), "project"), String) == abspath(pkg)
                end
                # Among one gone project's run states, one recorded on another machine.
                here = gethostname()
                elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
                write(paths[foreign], replace(read(paths[foreign], String), here => elsewhere))
                rm(gone; recursive = true)
                rm(foreign; recursive = true)
                Runtests.Private.sweep_runstate_dirs()
                @test isfile(paths[kept])
                @test !ispath(dirname(paths[gone]))
                @test isfile(paths[foreign])        # not this machine's to delete
                # Out of reach rather than gone: a drive that is not mounted leaves no
                # parent, or an empty mount point, where the project was.
                for recorded in (joinpath(mktempdir(), "Volume", "Unmounted"), joinpath(mktempdir(), "Unmounted"))
                    away = mkpath(joinpath(dirname(dirname(paths[kept])), "Unmounted-" * string(hash(recorded); base = 16)))
                    write(joinpath(away, "project"), recorded)
                    cp(paths[kept], joinpath(away, basename(paths[kept])))
                    Runtests.Private.sweep_runstate_dirs()
                    @test isfile(joinpath(away, basename(paths[kept])))
                end

                # A project without a name is named for its directory, and what a
                # directory name cannot hold everywhere is left out.
                env = mkpath(joinpath(mktempdir(), ".my env ☃ " * "x"^40))
                write(joinpath(env, "Project.toml"), "[deps]\n")
                @test basename(runstate_dir(env)) == string("myenvx", "x"^26, "-", string(Runtests.Private.crc32c(abspath(env)); base = 16, pad = 8))
                # Nothing left of the name: the key alone.
                odd = mkpath(joinpath(mktempdir(), "☃☃"))
                @test occursin(r"^[0-9a-f]{8}$", basename(runstate_dir(odd)))
            end
        finally
            filter!(!=(depot), DEPOT_PATH)
        end
    end

    @testset "round trip" begin
        p = a_plan()
        dir = mktempdir()
        path = joinpath(dir, "run.runstate")
        rsf = init_run_state(path, p)
        write_status!(rsf, 1, PASSED, 1, 3; elapsed=1.5, compile=0.5)
        write_status!(rsf, 2, FAILED, 2, 1; elapsed=0.25)
        finish_run_state!(rsf)

        rs = read_run_state(path)
        @test rs !== nothing
        @test rs.complete
        @test !rs.cancelled
        @test length(rs.items) == nitems(p)
        @test rs.items[1].name == p.items.name[1]
        @test rs.meta["julia"] == string(VERSION)
        @test rs.statuses[1].state === PASSED
        @test rs.statuses[1].elapsed ≈ 1.5f0
        @test rs.statuses[1].compile ≈ 0.5f0
        @test rs.statuses[1].slot == 3
        @test rs.statuses[2].state === FAILED
        @test rs.statuses[2].attempt == 2
        @test rs.statuses[3].state === UNSEEN
        @test haskey(rs.profiles, :default)
        # A profile without `init` or `test_end` reads back without them.
        @test rs.profiles[:default].init == Expr(:block) && rs.profiles[:default].test_end == Expr(:block)
    end

    @testset "the manifest is stored compressed, and a damaged copy costs only the manifest" begin
        p = a_plan()
        path = joinpath(mktempdir(), "run.runstate")
        rsf = init_run_state(path, p)
        write_status!(rsf, 1, PASSED, 1, 1; elapsed=1.0)
        finish_run_state!(rsf)
        manifest = Runtests.Private.environment_manifest()
        @test !isempty(manifest)
        rs = read_run_state(path)
        @test Runtests.Private.recorded_manifest(rs) == manifest
        @test rs.manifest_bytes == sizeof(manifest)
        @test length(rs.manifest_zlib) < sizeof(manifest)
        # One byte of the stored copy changed: the rest of the file reads as before.
        bytes = read(path)
        at = Runtests.Private.read_record(IOBuffer(bytes), Runtests.Private.Header).off_environment + 8 + 10
        bytes[at + 1] = ~bytes[at + 1]
        write(path, bytes)
        rs = read_run_state(path)
        @test rs.statuses[1].state === PASSED
        @test Runtests.Private.recorded_manifest(rs) == ""
    end

    @testset "profiles survive the round trip, expressions and all" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nuuid = \"1a2b3c4d-0000-4000-8000-00000000000a\"\n")
        write(joinpath(dir, "test", "a_test.jl"), """@testitem "x" sandbox=:p begin\n @test true\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"), """
        [profiles.p]
        julia_args = ["--check-bounds=yes"]
        threads = "3"
        env = { FOO = "bar" }
        init = "const A = 1"
        test_end = "GC.gc(true)"
        """)
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        p = plan(items, read_config(joinpath(dir, "test")); root=dir)
        path = joinpath(mktempdir(), "run.runstate")
        finish_run_state!(init_run_state(path, p))
        rs = read_run_state(path)
        prof = rs.profiles[:p]
        @test prof.julia_args == ["--check-bounds=yes"]
        @test prof.threads == "3"
        @test prof.env == ["FOO" => "bar"]
        @test occursin("A = 1", string(prof.init))
        @test occursin("GC.gc", string(prof.test_end))
    end

    @testset "a truncated file never throws, at any length" begin
        p = a_plan()
        path = joinpath(mktempdir(), "run.runstate")
        rsf = init_run_state(path, p)
        write_status!(rsf, 1, PASSED, 1, 1; elapsed=1.0)
        finish_run_state!(rsf)
        full = read(path)
        broken = joinpath(mktempdir(), "broken.runstate")
        for n in 0:length(full)
            write(broken, full[1:n])
            rs = read_run_state(broken)       # must not throw, whatever n is
            rs === nothing && continue
            @test length(rs.statuses) == nitems(p)
        end
        @test true    # reaching here is the assertion
    end

    @testset "a garbled file never throws" begin
        p = a_plan()
        path = joinpath(mktempdir(), "run.runstate")
        finish_run_state!(init_run_state(path, p))
        full = read(path)
        garbled = joinpath(mktempdir(), "garbled.runstate")
        # Seeded, so that a corruption which breaks the reader breaks every run of
        # this file rather than one in a hundred. A count is what usually does it:
        # the number some garbled bytes happen to spell, taken as a length, is an
        # allocation nobody comes back from.
        rng = Random.Xoshiro(20250921)
        for _ in 1:400
            bytes = copy(full)
            for _ in 1:20
                bytes[rand(rng, 1:length(bytes))] = rand(rng, UInt8)
            end
            write(garbled, bytes)
            rs = read_run_state(garbled)
            # What is read of it can be shown, however little that is.
            @test (rs === nothing || sprint(show, MIME"text/plain"(), rs) isa String)
        end
        @test read_run_state(joinpath(mktempdir(), "not_a_file")) === nothing
        write(garbled, "not a run state at all")
        @test read_run_state(garbled) === nothing
    end

    @testset "a file with fewer items than statuses shows, and says what failed" begin
        pkg = make_pkg("FewerItems", "test/t_test.jl" => join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in ("a", "b", "c"))))
        with_runstate_dir() do dir
            path = record_run(dir, pkg, 1, Dict("a" => (FAILED, 1.0), "b" => (PASSED, 1.0), "c" => (FAILED, 1.0)); whole = true)
            # The items section says two where the header says three.
            bytes = read(path)
            at = Runtests.Private.read_record(IOBuffer(bytes), Runtests.Private.Header).off_items
            bytes[(at + 1):(at + 4)] = reinterpret(UInt8, [UInt32(2)])
            write(path, bytes)
            rs = read_run_state(path)
            @test length(rs.items) == 2 && length(rs.statuses) == 3
            shown = sprint(show, MIME"text/plain"(), rs)
            @test occursin("\"a\"", shown) && !occursin("\"c\"", shown)
            @test Runtests.Private.last_failure(Runtests.Private.resolve_target((pkg,))).name == "a"
        end
    end

    @testset "a damaged file's times are shown as they are" begin
        pkg = make_pkg("OddTimes", "test/t_test.jl" => "@testitem \"a\" begin\n    @test true\nend\n")
        with_runstate_dir() do dir
            path = record_run(dir, pkg, 1, Dict("a" => (FAILED, 1.0)); whole = true)
            H = Runtests.Private.Header
            clean = read(path)
            h = Runtests.Private.read_record(IOBuffer(clean), H)
            put!(bytes, at, x) = (bytes[(at + 1):(at + sizeof(x))] = reinterpret(UInt8, [x]); bytes)
            for t in (NaN, Inf, -Inf, 2.5e219)
                bytes = copy(clean)
                put!(bytes, Runtests.Private.header_offset(:start_unix), t)
                put!(bytes, Runtests.Private.header_offset(:end_unix), -t)
                put!(bytes, Int(h.off_status) + 8, Float32(t))   # the item's elapsed
                write(path, bytes)
                shown = sprint(show, MIME"text/plain"(), read_run_state(path))
                @test occursin("started ", shown) && occursin("\"a\"", shown)
            end
        end
    end

    @testset "a killed run still reports what finished" begin
        # A real SIGKILL, not a simulated one: the file has to be readable
        # without anything having closed it.
        dir = mktempdir()
        script = joinpath(dir, "run.jl")
        write(script, """
        push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
        using Runtests
        Runtests.runtests($(repr(fixture("Faulty.jl"))); workers=1, logs=:issues, monitor=false,
                      name=r"^(passes|hangs)\$", timeout=600)
        """)
        child_log = joinpath(dir, "child.log")
        proc = run(pipeline(addenv(`$(Base.julia_cmd()) --startup-file=no $script`,
                                   "RUNTESTS_RUNSTATE_DIR" => dir);
                            stdout=child_log, stderr=child_log); wait=false)
        # Wait until the run state shows the passing item is done, then kill. The
        # ceiling is generous because the child starts a Julia process, resolves a
        # test environment and starts a worker, and the files run several at a
        # time; the loop leaves as soon as the condition holds, so a slack ceiling
        # costs nothing and a tight one is a flake on a busy machine.
        deadline = time() + 600
        seen = false
        while time() < deadline && !seen
            files = filter!(endswith(".runstate"), readdir(dir; join=true))
            for f in files
                rs = read_run_state(f)
                rs === nothing && continue
                any(s -> s.state === PASSED, rs.statuses) && (seen = true)
            end
            seen || sleep(0.2)
        end
        kill(proc, Base.SIGKILL)
        wait(proc)
        seen || @info "the killed-run fixture never got going; its output was:\n" *
                      (isfile(child_log) ? read(child_log, String) : "(no output)")
        @test seen
        files = filter!(endswith(".runstate"), readdir(dir; join=true))
        @test !isempty(files)
        rs = read_run_state(last(sort!(files)))
        @test rs !== nothing
        # Killed that way, the coordinator never stopped its worker, which is asleep
        # in "hangs" and would outlive this test by ten minutes.
        rs === nothing || foreach(rs.events) do e
            e.kind === :worker_up && ccall(:uv_kill, Cint, (Cint, Cint), e.pid, Base.SIGKILL)
        end
        @test !rs.complete                              # the run never finished
        @test any(s -> s.state === PASSED, rs.statuses) # but what did finish is recorded
        @test any(s -> s.state === RUNNING, rs.statuses) # and what was in flight says so
    end

    @testset "history feeds the next run" begin
        dir = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            pkg = fixture("Basic.jl")
            p, target = prepare((pkg,); workers=1, logs=:issues)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
            h = history(pkg)
            @test length(h.seconds) == 6
            @test all(>(0), values(h.seconds))
            @test isempty(h.failed)
            # the next plan sees those timings
            p2, _ = prepare((pkg,); workers=2, logs=:issues)
            @test any(>(0), p2.units.est_s)
        end
    end

    @testset "runs of a few items leave the others' timings standing" begin
        pkg = make_pkg("Timings", "test/t_test.jl" => join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in ("x", "y", "z"))))
        with_runstate_dir() do dir
            record_run(dir, pkg, 1, Dict("x" => (PASSED, 1.0), "y" => (PASSED, 2.0), "z" => (PASSED, 3.0)); whole = true)
            # More runs of `x` alone than `history` reads recent failures from.
            for k in 1:(Runtests.Private.HISTORY_RUNS + 1)
                record_run(dir, pkg, 1 + k, Dict("x" => (PASSED, 0.5)))
            end
            @test history(pkg).seconds == Dict("x" => 0.5, "y" => 2.0, "z" => 3.0)
            p, _ = prepare((pkg,); announce = false)
            @test all(>(0), p.units.est_s)
        end
    end

    @testset "a run stopped part way through leaves the durations of the items it stopped" begin
        pkg = make_pkg("StoppedTimings", "test/t_test.jl" => join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in ("slow", "chained"))))
        with_runstate_dir() do dir
            record_run(dir, pkg, 1, Dict("slow" => (PASSED, 300.0), "chained" => (PASSED, 4.0)); whole = true)
            # Stopped 2 s into `slow`; `chained` never ran, its chain having broken.
            record_run(dir, pkg, 2, Dict("slow" => (Runtests.Private.CANCELLED, 2.0),
                                         "chained" => (Runtests.Private.BROKEN_CHAIN, 0.1)); whole = true)
            @test history(pkg).seconds == Dict("slow" => 300.0, "chained" => 4.0)
            # A timeout is how long the item took at the least, and counts.
            record_run(dir, pkg, 3, Dict("slow" => (TIMEDOUT, 600.0)); whole = true)
            @test history(pkg).seconds["slow"] == 600.0
        end
    end

    @testset "a project without a name keeps its run states when its project file changes" begin
        env = mkpath(joinpath(mktempdir(), "Analysis"))
        write(joinpath(env, "Project.toml"), "[deps]\n")
        mkpath(joinpath(env, "test"))
        write(joinpath(env, "test", "a_test.jl"), "@testitem \"one\" begin\n    @test true\nend\n")
        with_runstate_dir() do dir
            for n in 1:25
                record_run(dir, env, n, Dict("one" => (n == 1 ? FAILED : PASSED, 1.0)))
            end
            @test Runtests.Private.project_id(env) == "Analysis"
            # A dependency added: the project is the same one, and so are its runs.
            write(joinpath(env, "Project.toml"), "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n")
            @test length(Runtests.Private.project_runs(env)) == 25
            @test history(env).seconds == Dict("one" => 1.0)
            prune_runstates(env)
            @test length(runstate_files(env)) == Runtests.Private.KEEP_RUNS
        end
    end

    @testset "an item is failing while the last run that ran it says so" begin
        verdicts(a, b) = string("@testitem \"a\" begin\n    @test $a\nend\n",
                                "@testitem \"b\" begin\n    @test $b\nend\n",
                                "@testitem \"c\" begin\n    @test true\nend\n")
        pkg = make_pkg("Failing", "test/t_test.jl" => verdicts(false, false))
        file = joinpath(pkg, "test", "t_test.jl")
        failing = Runtests.Private.failing_items
        with_runstate_dir() do _
            @test failing(pkg) == String[]           # nothing recorded yet
            run_states(pkg; workers = 1, logs = :issues)
            @test failing(pkg) == ["a", "b"]
            # `a` fixed and run alone: `b` is still failing, though the newest run
            # did not run it.
            write(file, verdicts(true, false))
            run_states(pkg; workers = 1, logs = :issues, name = "a")
            @test failing(pkg) == ["b"]
            # A run that stopped before reaching anything says nothing about any of it.
            p, _ = prepare((pkg,); workers = 1)
            finish_run_state!(init_run_state(new_runstate_path(pkg), p); cancelled = true)
            @test failing(pkg) == ["b"]
            @test failing(pkg; names = Set(["a", "c"])) == String[]
            # `runtestsf` runs exactly those, and then there is nothing left to run.
            write(file, verdicts(true, true))
            ts, out = capture_run(() -> Runtests.runtestsf(pkg; workers = 1, logs = :issues))
            @test occursin("matching 1 failing item", out)
            @test occursin("ran 1 test item", out)
            @test failing(pkg) == String[]
            @test_throws Runtests.NoTestsError Runtests.runtestsf(pkg)
        end
    end

    @testset "pruning keeps every run state an item's failure rests on" begin
        pkg = make_pkg("Pruned", "test/t_test.jl" => join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in ("x", "y", "z", "w"))))
        failing = Runtests.Private.failing_items
        # The `n`th run recorded here, each item it ran with the verdict given.
        function recorded(dir, n, verdicts)
            p, _ = prepare((pkg,); name = Set(keys(verdicts)), announce = false)
            path = joinpath(dir, string(1_000_000 + n, "-1.runstate"))
            rsf = init_run_state(path, p)
            for i in 1:nitems(p)
                write_status!(rsf, i, verdicts[p.items.name[i]], 1, 1; elapsed = 0.1)
            end
            finish_run_state!(rsf)
            return path
        end
        with_runstate_dir() do dir
            # A run that fails two items, then one of them run alone 25 times until
            # it passes: the other's failure is only in the first run.
            full = recorded(dir, 1, Dict("x" => FAILED, "y" => FAILED, "z" => PASSED))
            alone = [recorded(dir, 1 + k, Dict("x" => k < 25 ? FAILED : PASSED)) for k in 1:25]
            @test failing(pkg) == ["y"]
            prune_runstates(pkg)
            left = runstate_files(pkg)
            @test full in left
            @test issubset(alone[(end - 19):end], left)      # the newest 20, as ever
            @test !any(in(left), alone[1:5])                  # the rest had nothing to keep
            @test failing(pkg) == ["y"]
        end
        with_runstate_dir() do dir
            # A pass that stands in front of an older failure: without it, the old
            # failure would count again.
            full = recorded(dir, 1, Dict("x" => FAILED, "y" => FAILED))
            fixed = recorded(dir, 2, Dict("x" => PASSED))
            others = [recorded(dir, 2 + k, Dict("w" => PASSED)) for k in 1:24]
            prune_runstates(pkg)
            left = runstate_files(pkg)
            @test full in left && fixed in left
            @test !any(in(left), others[1:4])
            @test failing(pkg) == ["y"]
        end
    end

    @testset "a failing suite's own pruning keeps the run state a failing item's last verdict is in" begin
        pkg = make_pkg("KeepsFailure", "test/t_test.jl" => """
        @testitem "passes" begin
            @test true
        end
        @testitem "fails" begin
            @test false
        end
        @testitem "keeps failing" begin
            @test false
        end
        """)
        keep = Runtests.Private.KEEP_RUNS
        failing = Runtests.Private.failing_items
        with_runstate_dir() do _
            # The whole suite once: the only run of `fails` there will be.
            capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            first_run = only(runstate_files(pkg))
            # Then more failing runs of another item than pruning keeps, each pruning
            # as it ends, as every run does.
            for _ in 1:(keep + 3)
                capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false, name = "keeps failing"))
            end
            left = runstate_files(pkg)
            @test first_run in left
            # The newest runs, and that one: each newer failure of `keeps failing`
            # stands in for the one before, so those do not pile up.
            @test length(left) == keep + 1
            @test failing(pkg) == ["fails", "keeps failing"]
            _, out = capture_run(() -> Runtests.runtestsf(pkg; dry_run = true))
            @test occursin("matching 2 failing items", out)
        end
    end

    @testset "an item the suite no longer has is not failing, and holds no run state back" begin
        items(names...) = join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in names))
        pkg = make_pkg("Renamed", "test/t_test.jl" => items("x", "y"))
        failing = Runtests.Private.failing_items
        with_runstate_dir() do dir
            failed = record_run(dir, pkg, 1, Dict("x" => (FAILED, 1.0), "y" => (PASSED, 1.0)); whole = true)
            @test failing(pkg) == ["x"]
            # `x` renamed to `z`. A run of some of the items does not say what the
            # suite has, so `x` stays failing.
            write(joinpath(pkg, "test", "t_test.jl"), items("y", "z"))
            record_run(dir, pkg, 2, Dict("y" => (PASSED, 1.0)))
            @test failing(pkg) == ["x"]
            # A run of the whole suite does: `x` is gone.
            record_run(dir, pkg, 3, Dict("y" => (PASSED, 1.0), "z" => (PASSED, 1.0)); whole = true)
            @test failing(pkg) == String[]
            @test failing(pkg; names = Set(["x", "y"])) == String[]
            # Nor is the run state `x` failed in kept for it.
            for k in 1:20
                record_run(dir, pkg, 3 + k, Dict("y" => (PASSED, 1.0)))
            end
            prune_runstates(pkg)
            @test !(failed in runstate_files(pkg))
            @test length(runstate_files(pkg)) == 20
        end
    end

    @testset "runtestsf at a line runs the item there if it is failing, and no other" begin
        pkg = make_pkg("FailingAtLine", "test/t_test.jl" => """
        @testitem "fails" begin
            @test false
        end
        @testitem "passes" begin
            @test true
        end
        """)
        file = joinpath(pkg, "test", "t_test.jl")
        with_runstate_dir() do _
            capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            # Line 5 is inside "passes", which is not failing: there is nothing to run,
            # and "fails", above it, is not what the line names.
            @test_throws Runtests.NoTestsError capture_run(() -> Runtests.runtestsf("$file:5"; dry_run = true))
            _, out = capture_run(() -> Runtests.runtestsf("$file:2"; dry_run = true))
            @test occursin("1 test item", out) && occursin("\"fails\"", out)
        end
    end

    @testset "runtestsf narrows the failing items by every other selection, name included" begin
        pkg = make_pkg("FailingNarrowed", "test/t_test.jl" => """
        @testitem "fails" tags=[:slow] begin
            @test false
        end
        @testitem "passes" tags=[:fast] begin
            @test true
        end
        @testitem "errors" begin
            error("on purpose")
        end
        """)
        said(f) = try
            f()
            ""
        catch e
            e isa Runtests.NoTestsError || rethrow()
            sprint(showerror, e)
        end
        with_runstate_dir() do _
            capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            # A name keeps the failing items it matches, and nothing that is not failing.
            _, out = capture_run(() -> Runtests.runtestsf(pkg; name = "fails", dry_run = true))
            @test occursin("1 test item in 1 file matching 1 failing item", out)
            _, out = capture_run(() -> Runtests.runtestsf(pkg; name = r"s$", dry_run = true))
            @test occursin("2 test items in 1 file matching 2 failing items", out)
            msg = said(() -> capture_run(() -> Runtests.runtestsf(pkg; name = "passes", dry_run = true)))
            @test occursin("none of the 2 failing items matches name = \"passes\": \"errors\", \"fails\"", msg)
            # Tags narrow them too, and a selection that leaves none says so before
            # anything claims to be running.
            _, out = capture_run(() -> Runtests.runtestsf(pkg; tags = :slow, dry_run = true))
            @test occursin("matching 2 failing items and tags = [:slow]", out)
            out = Ref("")
            msg = said(() -> (out[] = last(capture_run(() -> Runtests.runtestsf(pkg; tags = :fast)))))
            @test occursin("no test items matched 2 failing items and tags = [:fast]", msg)
        end
    end

    @testset "runtestsf runs the failing items the suite still has" begin
        suite(a, b) = string("@testitem \"a\" begin\n    @test $a\nend\n", "@testitem \"$b\" begin\n    @test $(b == "b2")\nend\n")
        pkg = make_pkg("RenamedFailure", "test/t_test.jl" => suite(false, "b"))
        failing = Runtests.Private.failing_items
        with_runstate_dir() do _
            capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            @test failing(pkg) == ["a", "b"]
            # `a` fixed, and `b` renamed to `b2`: only `a` is there to run.
            write(joinpath(pkg, "test", "t_test.jl"), suite(true, "b2"))
            _, out = capture_run(() -> Runtests.runtestsf(pkg; workers = 0, logs = :issues, monitor = false))
            @test occursin("matching 1 failing item", out)
            @test occursin("ran 1 test item", out)
            # `b` is still on record, but not what the suite has, so nothing is left to run.
            @test failing(pkg) == ["b"]
            err = try
                Runtests.runtestsf(pkg; workers = 0)
            catch e
                e
            end
            @test err isa Runtests.NoTestsError
            @test occursin("no test item is failing", sprint(showerror, err))
            # A run of the whole suite takes `b` off the record.
            capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            @test failing(pkg) == String[]
        end
    end

    @testset "a directory several projects share gives each its own history" begin
        with_runstate_dir() do _
            item(passes) = "@testitem \"shared name\" begin\n    @test $passes\nend\n"
            a = make_pkg("SharedA", "test/t_test.jl" => item(true))
            b = make_pkg("SharedB", "test/t_test.jl" => item(false))
            capture_run(() -> run_states(a; workers=0, logs=:issues, monitor=false))
            capture_run(() -> run_states(b; workers=0, logs=:issues, monitor=false))   # the newer, failing
            @test length(runstate_files(a)) == 2          # both in the one directory
            @test isempty(history(a; nruns=1).failed)
            @test history(b; nruns=1).failed == Dict("shared name" => 0)
            # Pruning one project's runs leaves the other's alone.
            prune_runstates(a, 0)
            @test isempty(history(a).seconds)
            @test history(b; nruns=1).failed == Dict("shared name" => 0)
        end
    end

    @testset "old run states are pruned" begin
        dir = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            p = a_plan()
            for i in 1:25
                path = joinpath(dir, string(1000000 + i, "-1.runstate"))
                finish_run_state!(init_run_state(path, p))
            end
            @test length(runstate_files(p.root)) == 25
            prune_runstates(p.root, 20)
            @test length(runstate_files(p.root)) == 20
        end
    end

    @testset "a run state recorded on another machine is never pruned" begin
        dir = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            p = a_plan()
            for i in 1:25
                finish_run_state!(init_run_state(joinpath(dir, string(1000000 + i, "-1.runstate")), p))
            end
            # A CI artifact downloaded among them, older than any: the same file, but
            # recorded on another machine. Rewritten byte for byte, so it stays valid.
            here = gethostname()
            elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
            artifact = joinpath(dir, "999999-1.runstate")
            write(artifact, replace(read(joinpath(dir, "1000001-1.runstate"), String), here => elsewhere))
            @test read_run_state(artifact).meta["host"] == elsewhere
            before = read(artifact)
            prune_runstates(p.root, 20)
            @test isfile(artifact) && read(artifact) == before
            @test length(runstate_files(p.root)) == 21   # this machine's twenty, and the artifact
        end
    end

    @testset "a run state from elsewhere counts from when it ran, whatever its name" begin
        suite(a) = "@testitem \"a\" begin\n    @test $a\nend\n@testitem \"b\" begin\n    @test false\nend\n"
        pkg = make_pkg("Downloaded", "test/t_test.jl" => suite(false))
        failing = Runtests.Private.failing_items
        run_a() = capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false, name = "a"))
        with_runstate_dir() do dir
            # A run on CI, in which `a` and `b` fail, downloaded under a name of its
            # own: one that sorts after every name a run here gets.
            capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            recorded = only(runstate_files(pkg))
            here = gethostname()
            elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
            ci = joinpath(dir, "run.runstate")
            write(ci, replace(read(recorded, String), here => elsewhere))
            rm(recorded)
            before = read(ci)
            # `a` fixed and run alone here, after the CI run: only `b` is failing.
            write(joinpath(pkg, "test", "t_test.jl"), suite(true))
            run_a()
            @test failing(pkg) == ["b"]
            # And so it stays through more runs here than are kept, each pruning,
            # none of them touching the CI run's file.
            foreach(_ -> run_a(), 1:(Runtests.Private.KEEP_RUNS + 2))
            @test read(ci) == before
            @test failing(pkg) == ["b"]
        end
    end

    @testset "RUNTESTS_HOST names the machine, so a CI cache is pruned like a local directory" begin
        dir = mktempdir()
        p = a_plan()
        withenv("RUNTESTS_RUNSTATE_DIR" => dir, "RUNTESTS_HOST" => "ci-linux") do
            for i in 1:25
                finish_run_state!(init_run_state(joinpath(dir, string(1000000 + i, "-1.runstate")), p))
            end
            @test read_run_state(joinpath(dir, "1000001-1.runstate")).meta["host"] == "ci-linux"
            # Recorded under the name this runner has too, whatever its hostname: its own.
            prune_runstates(p.root, 20)
            @test length(runstate_files(p.root)) == 20
        end
        # Under another name, those twenty are another machine's.
        withenv("RUNTESTS_RUNSTATE_DIR" => dir, "RUNTESTS_HOST" => "ci-macos") do
            prune_runstates(p.root, 5)
            @test length(runstate_files(p.root)) == 20
        end
    end

    @testset "a replay changes and deletes no run state, the one it runs among them" begin
        with_runstate_dir() do dir
            pkg = make_pkg("ReplayKeeps", "test/r_test.jl" => "@testitem \"x\" begin\n    @test true\nend\n")
            run_states(pkg; workers=0, logs=:issues, monitor=false)
            recorded = only(runstate_files(pkg))
            # The oldest of as many as are kept: the run a replay adds would push it out.
            stamp = parse(Int, first(split(basename(recorded), '-')))
            for k in 1:(Runtests.Private.KEEP_RUNS - 1)
                cp(recorded, joinpath(dir, string(stamp + k, "-1.runstate")))
            end
            before = Dict(f => read(f) for f in runstate_files(pkg))
            capture_run(() -> run_states(pkg; workers=0, logs=:issues, monitor=false, replay=recorded))
            @test all(f -> isfile(f) && read(f) == before[f], keys(before))
            @test length(runstate_files(pkg)) == Runtests.Private.KEEP_RUNS + 1
        end
    end

    @testset "the run state a replay names is the base for what is failing, and is never deleted" begin
        suite(failing...) = join(("@testitem \"$n\" begin\n    @test $(!(n in failing))\nend\n" for n in ("a", "b", "c", "d")))
        pkg = make_pkg("ReplayBase", "test/t_test.jl" => suite("a", "d"))
        file = joinpath(pkg, "test", "t_test.jl")
        failing = Runtests.Private.failing_items
        run_once(; kwargs...) = capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false, kwargs...))
        with_runstate_dir() do dir
            # An older run of the whole suite, in which `a` and `d` fail.
            run_once()
            # The base: `a` fixed, `b` and `c` failing, `d` not run. Renamed, and this
            # machine's: pruning takes it for one of its own.
            write(file, suite("b", "c"))
            run_once(; name = Set(["a", "b", "c"]))
            base = joinpath(dir, "base.runstate")
            mv(last(runstate_files(pkg)), base)
            # A newer run: `c` fixed.
            write(file, suite("b"))
            run_once(; name = "c")
            rs = read_run_state(base)
            # Without the base, the older run's failure of `d` still counts.
            @test failing(pkg) == ["b", "d"]
            @test failing(pkg; base = rs) == ["b"]
            h = history(pkg; base = rs)
            @test !haskey(h.failed, "d") && !haskey(h.failed, "a")
            @test haskey(h.seconds, "d")     # how long it took, from the older run
            _, out = capture_run(() -> Runtests.runtestsf(pkg; replay = base, dry_run = true))
            @test occursin("matching 1 failing item", out)
            # More replays of what it ran than pruning keeps, `b` failing in each. They
            # hold every verdict it did, so pruning as a run without it does would
            # take it; pointed at, it is never deleted.
            before = read(base)
            foreach(_ -> run_once(; replay = base, name = Set(["a", "b", "c"])), 1:(Runtests.Private.KEEP_RUNS + 2))
            @test isfile(base) && read(base) == before
            @test base in Runtests.Private.removable_runs(Runtests.Private.project_runs(pkg), [base])
            @test failing(pkg; base = rs) == ["b"]
        end
    end

    @testset "a new run state never takes an existing file's name" begin
        dir = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            # A file already has the name a run starting in this microsecond gets.
            start_us = Runtests.Private.wall_microseconds()
            taken = new_runstate_path(dir; start_us)
            write(taken, "someone else's")
            path = new_runstate_path(dir; start_us)
            # Claimed: created, empty, before anything is written to it.
            @test path != taken && isfile(path) && filesize(path) == 0 && endswith(path, ".runstate")
            @test read(taken, String) == "someone else's"
            # Two processes asking for the same name, before either has written a byte.
            again = new_runstate_path(dir; start_us)
            @test again != path && again != taken && isfile(again)
        end
    end

    @testset "run states started within one second sort in the order they started" begin
        pkg = make_pkg("QuickRuns", "test/t_test.jl" => "@testitem \"x\" begin\n    @test true\nend\n")
        failing = Runtests.Private.failing_items
        with_runstate_dir() do _
            p, _ = prepare((pkg,); announce = false)
            # Far more than ten within a second, `x` failing in all but the last.
            for k in 1:30
                rsf = init_run_state(new_runstate_path(pkg), p)
                write_status!(rsf, 1, k < 30 ? FAILED : PASSED, 1, 1; elapsed = 0.1)
                finish_run_state!(rsf)
            end
            starts = [read_run_state(f).start_unix for f in runstate_files(pkg)]
            @test length(starts) == 30 && issorted(starts)
            @test failing(pkg) == String[]
        end
    end
    @testset "the commit is read straight out of .git" begin
        sha = "0123456789abcdef0123456789abcdef01234567"
        dir = mktempdir()
        mkpath(joinpath(dir, ".git", "refs", "heads"))
        write(joinpath(dir, ".git", "HEAD"), "ref: refs/heads/main\n")
        write(joinpath(dir, ".git", "refs", "heads", "main"), sha * "\n")
        @test project_revision(dir) == sha

        # A ref that has been packed away is still a ref.
        rm(joinpath(dir, ".git", "refs", "heads", "main"))
        write(joinpath(dir, ".git", "packed-refs"),
              "# pack-refs with: peeled fully-peeled sorted\n$sha refs/heads/main\n^deadbeef\n")
        @test project_revision(dir) == sha

        # A detached HEAD holds the commit itself.
        write(joinpath(dir, ".git", "HEAD"), sha * "\n")
        @test project_revision(dir) == sha

        # A worktree or a submodule: `.git` is a file pointing at the real one.
        wt = mktempdir()
        write(joinpath(wt, ".git"), "gitdir: " * joinpath(dir, ".git") * "\n")
        @test project_revision(wt) == sha

        # A worktree on a branch, laid out as `git worktree add` lays it out: its
        # own directory holds HEAD, and the branch is in the repository's.
        main = mktempdir()
        mkpath(joinpath(main, ".git", "refs", "heads"))
        write(joinpath(main, ".git", "HEAD"), "ref: refs/heads/main\n")
        write(joinpath(main, ".git", "refs", "heads", "feature"), sha * "\n")
        own = joinpath(main, ".git", "worktrees", "feature")
        mkpath(own)
        write(joinpath(own, "HEAD"), "ref: refs/heads/feature\n")
        write(joinpath(own, "commondir"), "../..\n")
        wt = mktempdir()
        write(joinpath(wt, ".git"), "gitdir: " * own * "\n")
        @test project_revision(wt) == sha
        rm(joinpath(main, ".git", "refs", "heads", "feature"))
        write(joinpath(main, ".git", "packed-refs"), "$sha refs/heads/feature\n")
        @test project_revision(wt) == sha

        @test project_revision(mktempdir()) == ""        # not a checkout
        @test project_revision("/nonexistent/path") == ""

        # A package below the root of its checkout, as in a monorepo, has the
        # checkout's commit.
        sub = mkpath(joinpath(dir, "lib", "Sub"))
        @test project_revision(sub) == sha
        @test repository_root(sub) == dir
        @test repository_root(dir) == dir
        @test repository_root(mktempdir()) === nothing
        # A `gitdir` written relative is relative to the directory `.git` is in, not
        # to the package.
        parent = mktempdir()
        cp(joinpath(dir, ".git"), joinpath(parent, "real.git"))
        checkout = mkpath(joinpath(parent, "checkout"))
        write(joinpath(checkout, ".git"), "gitdir: ../real.git\n")
        @test repository_root(joinpath(checkout, "lib")) == checkout
        @test project_revision(mkpath(joinpath(checkout, "lib", "Sub"))) == sha
    end

    @testset "the run state records the commit it ran from" begin
        sha = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        dir = make_pkg("Revisioned", "test/a_test.jl" => """@testitem "x" begin\n @test true\nend\n""")
        mkpath(joinpath(dir, ".git"))
        write(joinpath(dir, ".git", "HEAD"), sha * "\n")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        p = plan(items, read_config(joinpath(dir, "test")); root=dir)
        path = joinpath(mktempdir(), "run.runstate")
        finish_run_state!(init_run_state(path, p))
        @test read_run_state(path).meta["revision"] == sha
    end

    @testset "replay applies the worker configuration a run state recorded" begin
        dir = make_pkg(
            "Replayed",
            "test/a_test.jl" => """@testitem "x" sandbox=:p begin\n @test true\nend\n""",
            "test/TestItems.toml" =>
                "[profiles.p]\njulia_args = [\"--check-bounds=yes\"]\nthreads = \"3\"\n"
        )
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        p = plan(items, read_config(joinpath(dir, "test")); root=dir)
        path = joinpath(mktempdir(), "run.runstate")
        finish_run_state!(init_run_state(path, p))

        # The same suite after the profile was dropped from its configuration.
        write(joinpath(dir, "test", "TestItems.toml"), "")
        @test_throws Runtests.ConfigError prepare((dir,))

        (p2, _), out = capture_run() do
            prepare((dir,); replay=path)
        end
        prof = only(x for x in p2.profiles if x.name === :p)
        @test prof.julia_args == ["--check-bounds=yes"]
        @test prof.threads == "3"
        @test occursin("replaying run.runstate", out)

        # A run state that cannot be read is an error, not a silent fallback to
        # whatever this checkout happens to say.
        @test_throws Runtests.ConfigError prepare((dir,); replay=joinpath(mktempdir(), "nope.runstate"))
    end

    @testset "a run records where it ran, how it was asked for, and what each worker did" begin
        with_runstate_dir() do dir
            pkg = make_pkg("Recorded", "test/r_test.jl" => """
            @testitem "a" begin
                @test true
            end
            @testitem "b" begin
                @test true
            end
            @testitem "throws" begin
                error("thrown outside any @test")
            end
            """)
            run_states(pkg; workers=1, logs=:issues, monitor=false, seed=0x1234)
            rs = read_run_state(only(readdir(dir; join=true)))
            @test rs.meta["seed"] == "0x0000000000001234"
            @test (rs.meta["workers"], rs.meta["machine"], rs.meta["julia"]) == ("1", Sys.MACHINE, string(VERSION))
            @test occursin("[[deps.", Runtests.Private.recorded_manifest(rs))
            @test occursin("Recorded", rs.meta["environment_project"])
            up, down = only(e for e in rs.events if e.kind === :worker_up), only(e for e in rs.events if e.kind === :worker_down)
            @test down.ended_by === :close && down.pid == up.pid
            attempts = [e for e in rs.events if e.kind === :attempt]
            @test sort([rs.items[e.item].name for e in attempts]) == ["a", "b", "throws"]
            @test all(e -> e.pid == up.pid && e.t1 >= e.t0, attempts)
            @test [e.state for e in attempts if rs.items[e.item].name != "throws"] == [PASSED, PASSED]
            # Each attempt says where it came among its process's items, and the start
            # how long the process took to come up: what the next run's plan expects a
            # fresh worker to cost.
            @test [e.seq for e in sort(attempts; by = e -> e.t0)] == [1, 2, 3]
            @test up.t1 > up.t0
            cold = history(pkg).cold
            @test cold.start_s ≈ up.t1 - up.t0
            @test cold.compile_s >= 0
            # An item that throws took time and memory like any other.
            @test all(s -> s.pid == up.pid && s.peak_rss_mb > 0 && s.elapsed > 0, rs.statuses)
            @test occursin("run it again", sprint(show, MIME"text/plain"(), rs))
        end
    end

    @testset "a replay runs the same items with the same settings and the same seed" begin
        with_runstate_dir() do dir
            with_journal() do jdir
                pkg = make_pkg("Replayable", "test/r_test.jl" => """
                @testitem "draws" begin
                    write(joinpath(ENV["RUNTESTS_JOURNAL"], string(time_ns())), string(rand(UInt64)))
                    @test true
                end
                """)
                run_states(pkg; workers=1, retries=1, logs=:issues, monitor=false)
                recorded = only(readdir(dir; join=true))
                # An item added since is not part of the run that was recorded.
                write(joinpath(pkg, "test", "later_test.jl"), "@testitem \"added later\" begin\n @test true\nend\n")
                (p, _), out = capture_run(() -> prepare((pkg,); replay=recorded))
                @test p.items.name == ["draws"]
                @test p.cfg.retries == 1
                @test p.cfg.seed == parse(UInt64, read_run_state(recorded).meta["seed"])
                @test occursin("replaying ", out)
                @test prepare((pkg,); replay=recorded, retries=0)[1].cfg.retries == 0   # the call still wins
                _, out = capture_run(() -> run_states(pkg; replay=recorded, logs=:issues, monitor=false))
                @test occursin("the environment matches the one the run state was recorded in", out)
                draws = [read(f, String) for f in readdir(jdir; join=true)]
                @test length(draws) == 2 && draws[1] == draws[2]
            end
        end
    end

    @testset "a manifest is read as package versions" begin
        m = Runtests.Private.manifest_versions("""
        manifest_format = "2.0"
        [[deps.Foo]]
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        version = "1.2.3"
        [[deps.Local]]
        path = "/elsewhere"
        uuid = "5b0c2a4e-7f3d-4e21-9c55-3a1f0e6d7b90"
        [[deps.Test]]
        uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        """)
        @test m == Dict("Foo" => "1.2.3", "Local" => "path", "Test" => "stdlib")
    end

    @testset "a run state lying next to the project does not change the next run" begin
        with_runstate_dir() do _
            dir = make_pkg("NotReplayed", "test/a_test.jl" => """@testitem "x" begin\n @test true\nend\n""")
            run_states(dir; workers=1, threads="1", logs=:issues, monitor=false)
            # What the caller asked for, not what the last run happened to record.
            p, _ = prepare((dir,); workers=1, threads="2,1")
            @test p.profiles[1].threads == "2,1"
        end
    end
end
