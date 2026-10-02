using Runtests.Private: prepare, init_run_state, finish_run_state!, write_status!, new_runstate_path,
                    read_run_state, failing_items, history, recent_runs, prune_runstates, stale_runstates,
                    runstate_files, is_live, KEEP_RUNS, LIVE_S, PASSED, FAILED, RUNNING, nitems

const SHARED_REPO = dirname(@__DIR__)

shared_items(names...) = join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in names))

# A run state of `p` started `ago` seconds back, its items in `states` (name => state)
# and the rest unseen, finished unless `finish = false`, when it is left as a run
# still going leaves its file.
function shared_run(pkg, p, states; ago = 0.0, elapsed = 1.0, finish = true)
    start = time() - ago
    path = new_runstate_path(pkg; start_us = round(Int, start * 1e6))
    rsf = init_run_state(path, p; start)
    for (name, state) in states
        write_status!(rsf, findfirst(==(name), p.items.name), state, 1, 1; elapsed = state === RUNNING ? 0.0 : elapsed)
    end
    finish && finish_run_state!(rsf)
    return rsf
end

# What a run that died leaves: its beats stopped, and its file last written long ago.
function died!(rsf)
    beating = rsf.heartbeat[]
    rsf.heartbeat[] = nothing
    close(first(beating)); wait(last(beating))
    f = Base.Filesystem.open(rsf.path, Base.Filesystem.JL_O_WRONLY)
    Base.Filesystem.futime(f, time() - 2LIVE_S, time() - 2LIVE_S)
    close(f)
    return rsf
end

@testset "run states shared by concurrent runs" begin
    @testset "a run still going gives no verdicts, and its finished items' durations count" begin
        pkg = make_pkg("SharedLive", "test/t_test.jl" => shared_items("a", "b", "c"))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            p, _ = prepare((pkg,); announce = false)
            finished = shared_run(pkg, p, ["a" => FAILED, "b" => PASSED, "c" => PASSED]; ago = 100)
            going = shared_run(pkg, p, ["a" => RUNNING, "b" => PASSED, "c" => RUNNING]; ago = 10, elapsed = 3.0, finish = false)
            @test is_live(read_run_state(going.path)) && !is_live(read_run_state(finished.path))
            # Its `running` items are being run, not left so by a run that died.
            @test failing_items(pkg) == ["a"]
            h = history(pkg)
            @test haskey(h.failed, "a") && !haskey(h.failed, "c")
            @test h.seconds["b"] == 3.0
            @test last(only(recent_runs(pkg, 1))).path == finished.path
            # Once it has died, what it held as running is what it was running when it did.
            died!(going)
            @test !is_live(read_run_state(going.path))
            @test failing_items(pkg) == ["a", "c"]
            @test haskey(history(pkg).failed, "c")
            finish_run_state!(going)
        end
    end

    @testset "a run on this machine whose process is gone is over at once" begin
        pkg = make_pkg("SharedGone", "test/t_test.jl" => shared_items("a"))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            p, _ = prepare((pkg,); announce = false)
            going = shared_run(pkg, p, ["a" => RUNNING]; finish = false)
            rs = read_run_state(going.path)
            @test is_live(rs)
            # A pid known to be free: that of a process that has exited.
            proc = run(`$(Base.julia_cmd()) --startup-file=no -e 0`; wait = false)
            pid = getpid(proc)
            wait(proc)
            rs.meta["pid"] = string(pid)
            @test !is_live(rs)
            # By its own hostname: a pid from another machine says nothing here.
            rs.meta["hostname"] = "another-machine"
            @test is_live(rs)
            finish_run_state!(going)
        end
    end

    @testset "pruning, and chores, never delete a run still going" begin
        pkg = make_pkg("SharedPrune", "test/t_test.jl" => shared_items("a", "b"))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            p, _ = prepare((pkg,); announce = false)
            # Started before every run the pruning keeps, and still going.
            going = shared_run(pkg, p, ["a" => PASSED]; ago = 1000, finish = false)
            for k in 1:(KEEP_RUNS + 3)
                shared_run(pkg, p, ["a" => PASSED, "b" => PASSED]; ago = 900 - k)
            end
            @test !(going.path in stale_runstates(pkg, Set(["a", "b"])))
            prune_runstates(pkg)
            @test isfile(going.path)
            @test length(runstate_files(pkg)) == KEEP_RUNS + 1
            died!(going)
            prune_runstates(pkg)
            @test !isfile(going.path) && length(runstate_files(pkg)) == KEEP_RUNS
            finish_run_state!(going)
        end
    end

    @testset "a run's beats keep its file live, and stop when the exit hook ends it" begin
        pkg = make_pkg("SharedBeat", "test/t_test.jl" => shared_items("a"))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            p, _ = prepare((pkg,); announce = false)
            rsf = died!(shared_run(pkg, p, ["a" => RUNNING]; finish = false))
            @test !is_live(read_run_state(rsf.path))
            # Its beats again, every 50 ms rather than every 30 s.
            timer = Timer(0.05; interval = 0.05)
            beats = @async Runtests.Private.beat(rsf, timer)
            rsf.heartbeat[] = (timer, beats)
            @test timedwait(() -> is_live(read_run_state(rsf.path)), 10) === :ok
            # The exit hook waits on no task: the beats end on their own, after the file
            # has said how the run ended.
            finish_run_state!(rsf; cancelled = true, exiting = true)
            rs = read_run_state(rsf.path)
            @test rs.complete && rs.cancelled && !is_live(rs)
            @test timedwait(() -> istaskdone(beats), 10) === :ok && !istaskfailed(beats)
        end
    end

    @testset "a status record read half written holds no duration" begin
        pkg = make_pkg("SharedTorn", "test/t_test.jl" => shared_items("a", "b"))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            p, _ = prepare((pkg,); announce = false)
            rsf = shared_run(pkg, p, ["a" => PASSED, "b" => PASSED]; elapsed = 2.0)
            b = findfirst(==("b"), p.items.name)
            # A status record holds state, attempt and slot, then its start, then its elapsed time.
            at = Int(rsf.off_status) + (b - 1) * 32 + 8
            for garbage in (NaN32, -1.0f0, Inf32)
                open(rsf.path, "r+") do io
                    seek(io, at)
                    write(io, garbage)
                end
                rs = read_run_state(rsf.path)
                @test rs.statuses[b].elapsed == 0
                @test !haskey(history(pkg).seconds, "b") && history(pkg).seconds["a"] == 2.0
            end
        end
    end

    @testset "runs that share a directory read, write and prune it at once" begin
        nruns = 3
        pkg = make_pkg("SharedBusy", "test/t_test.jl" => join(
            ("@testitem \"slow $i\" begin\n    sleep(1)\n    @test true\nend\n" for i in 1:3)))
        dir = mktempdir()
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            p, _ = prepare((pkg,); announce = false)
            # Enough finished runs that each run's pruning has some to delete.
            for k in 1:(KEEP_RUNS + 5)
                shared_run(pkg, p, ["slow $i" => PASSED for i in 1:3]; ago = 600 - k)
            end
        end
        seeded = time()
        script = """
            using Runtests
            Runtests.runtests($(repr(pkg)); workers = 0, monitor = false)
            """
        cmd = addenv(`$(Base.julia_cmd()) --project=$(SHARED_REPO) --startup-file=no -e $script`,
                     "JULIA_LOAD_PATH" => join([SHARED_REPO, joinpath(SHARED_REPO, "test"), ""], Runtests.Private.PATHSEP),
                     "RUNTESTS_RUNSTATE_DIR" => dir)
        logs = [Base.BufferStream() for _ in 1:nruns]
        procs = [run(pipeline(cmd; stdout = logs[k], stderr = logs[k]); wait = false) for k in 1:nruns]
        # Read as a planner and `runtestsf` would, the whole time they write: nothing
        # throws, and nothing they have running is ever taken for a failure.
        reads = 0
        bad = String[]
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            while any(process_running, procs)
                try
                    isempty(failing_items(pkg)) || push!(bad, "failing: $(failing_items(pkg))")
                    isempty(history(pkg).failed) || push!(bad, "history failed: $(history(pkg).failed)")
                    foreach(read_run_state, runstate_files(pkg))
                    reads += 1
                catch e
                    push!(bad, sprint(showerror, e))
                end
                sleep(0.05)
            end
        end
        foreach(wait, procs)
        foreach(closewrite, logs)
        outputs = [read(l, String) for l in logs]
        @test all(proc -> proc.exitcode == 0, procs) || (foreach(println, outputs); false)
        @test reads > 0 && isempty(bad)
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            runs = filter(!isnothing, read_run_state.(runstate_files(pkg)))
            ran = filter(rs -> rs.start_unix > seeded, runs)
            @test length(ran) == nruns
            @test all(rs -> rs.complete && !is_live(rs) && all(st -> st.state === PASSED, rs.statuses), ran)
            @test length(runs) <= KEEP_RUNS + nruns
        end
    end
end
