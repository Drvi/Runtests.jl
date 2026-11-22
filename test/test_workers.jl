# The worker protocol: the framing on its own, then real worker processes.
using Runtests.RuntestsWorkers: RuntestsWorkers, Worker, remote_eval, remote_fetch, remote_run, terminate!,
                    WorkerTerminatedException, RemoteException
using Runtests.RuntestsWorkers: ItemSpec, ItemResult, PASSED, ERRORED
using Random: Random
using Sockets

# A connected socket pair standing in for coordinator and worker.
function socket_pair()
    port, server = listenany(Sockets.localhost, UInt16(20000))
    client = connect(Sockets.localhost, port)
    peer = accept(server)
    close(server)
    return client, peer
end

# What `Worker()` gives a worker process, for tests that spawn one by hand.
function worker_child_env(cmd)
    pathsep = Sys.iswindows() ? ";" : ":"
    env = ["JULIA_LOAD_PATH" => join(LOAD_PATH, pathsep), "JULIA_DEPOT_PATH" => join(DEPOT_PATH, pathsep)]
    Base.active_project() === nothing || push!(env, "JULIA_PROJECT" => Base.active_project())
    return addenv(cmd, env...)
end

# Built by field name, with a plain default for every field not given, so that a
# field added to `ItemSpec` does not break these tests.
function probe_spec(code::Expr; name="probe", skip=false)
    given = (; name, code, file=@__FILE__, location=string(@__FILE__, ":1"), skip)
    default(T) = T === Int32 ? Int32(1) : T === Int8 ? Int8(1) : T === String ? "" : T === UInt64 ? UInt64(1) :
                 T === Bool ? false : T === Symbol ? :default : T === Expr ? Expr(:block) : nothing
    return ItemSpec((haskey(given, f) ? given[f] : default(fieldtype(ItemSpec, f))
                     for f in fieldnames(ItemSpec))...)
end

# Every worker these tests start is ended here, whatever the test body did: a
# worker left running would count against later tests' process-cap assertions.
function with_worker(f; kwargs...)
    w = Worker(; kwargs...)
    try
        f(w)
    finally
        w.terminated || (terminate!(w); wait(w))
    end
end

@testset "workers" begin
    @testset "framing: round trip, exact reads, corrupt stream" begin
        a, b = socket_pair()
        write(a, RuntestsWorkers.encode_message(UInt64(7), RuntestsWorkers.KIND_EVAL, :(1 + 1)))
        f = RuntestsWorkers.read_message(b)
        @test f.id == 7 && f.kind == RuntestsWorkers.KIND_EVAL && f.error === nothing
        @test f.payload == :(1 + 1)
        # Back-to-back messages stay separate.
        write(a, RuntestsWorkers.encode_message(UInt64(8), RuntestsWorkers.KIND_RESULT, (1, "two")),
                 RuntestsWorkers.encode_message(UInt64(9), RuntestsWorkers.KIND_RESULT, nothing))
        @test RuntestsWorkers.read_message(b).payload == (1, "two")
        @test RuntestsWorkers.read_message(b).id == 9
        # A frame whose boundary is wrong is a corrupt stream, not a message.
        bad = RuntestsWorkers.encode_message(UInt64(10), RuntestsWorkers.KIND_RESULT, 1)
        bad[end] ⊻= 0xff
        write(a, bad)
        @test_throws ErrorException RuntestsWorkers.read_message(b)
        close(a); close(b)
        # A connection cut mid-payload is EOF, not a short payload.
        c, d = socket_pair()
        msg = RuntestsWorkers.encode_message(UInt64(11), RuntestsWorkers.KIND_RESULT, collect(1:100))
        write(c, msg[1:end-20])
        close(c)
        @test_throws EOFError RuntestsWorkers.read_message(d)
        close(d)
    end

    @testset "a reply that cannot be serialized becomes an error string" begin
        bytes = RuntestsWorkers.encode_reply(UInt64(1), RuntestsWorkers.KIND_RESULT, current_task())
        f = RuntestsWorkers.read_message(IOBuffer(bytes))
        @test f.id == 1 && f.kind == RuntestsWorkers.KIND_ERROR
        @test f.payload isa String && occursin("could not serialize", f.payload)
    end

    @testset "a reply that cannot be deserialized is reported against its request" begin
        m = Module(:Nowhere)
        Core.eval(m, :(struct Ghost; x::Int; end))
        bytes = RuntestsWorkers.encode_message(UInt64(2), RuntestsWorkers.KIND_RESULT, Core.eval(m, :(Ghost(1))))
        f = RuntestsWorkers.read_message(IOBuffer(bytes))
        @test f.id == 2 && f.kind == RuntestsWorkers.KIND_RESULT
        @test f.error !== nothing
    end

    @testset "with_timeout never loses a result" begin
        # A function that returns before the caller waits must not hang the caller.
        for _ in 1:50
            @test RuntestsWorkers.with_timeout(() -> 42, 5) == 42
        end
        @test_throws ErrorException RuntestsWorkers.with_timeout(() -> sleep(3), 0.2)
        err = try; RuntestsWorkers.with_timeout(() -> error("inner"), 5); catch e; e; end
        @test err isa CapturedException && occursin("inner", sprint(showerror, err))
    end

    # A task stuck to its thread, as a run's task is, that waits until it is thrown into
    # or let go. Returns it once it is stuck.
    function stuck_task(go::Threads.Event)
        pinned = Threads.Event()
        t = Threads.@spawn begin
            current_task().sticky = true
            notify(pinned)
            try
                wait(go)
                :let_go
            catch e
                e
            end
        end
        wait(pinned)
        return t
    end

    @testset "a worker's exit leaves out Julia's warnings about the temporary paths it could not delete" begin
        # What Julia's exit says on Windows of a directory whose library is still loaded,
        # and deletes after the exit; any other warning, of that group too, goes through.
        inner = Test.TestLogger()
        Base.CoreLogging.with_logger(RuntestsWorkers.WithoutTempCleanup(inner)) do
            @warn "Failed to clean up temporary path \"C:\\Temp\\fmijl_x\"" _module = Base.Filesystem _group = :file
            @warn "a warning of the run" _group = :file
            @warn "a warning of Base.Filesystem of another group" _module = Base.Filesystem
            @error "mktempdir cleanup" _module = Base.Filesystem _group = :file
            @warn "another warning of Base.Filesystem about files" _module = Base.Filesystem _group = :file
        end
        @test [r.message for r in inner.logs] == ["a warning of the run", "a warning of Base.Filesystem of another group",
                                                  "mktempdir cleanup", "another warning of Base.Filesystem about files"]
    end

    @testset "an interrupt reaches its target from any thread, once" begin
        # From Julia 1.12 the test's own task is on the interactive thread and the
        # target on another: the throw is handed to a task on the target's thread.
        t = stuck_task(Threads.Event())
        outer = @atomic RuntestsWorkers.INTERRUPT_TARGET.task
        @atomic RuntestsWorkers.INTERRUPT_TARGET.task = t
        try
            @test RuntestsWorkers.forward_interrupt(InterruptException())
            @test fetch(t) isa InterruptException
            @test RuntestsWorkers.INTERRUPT_TARGET.task === nothing
            @test !RuntestsWorkers.forward_interrupt(InterruptException())
        finally
            @atomic RuntestsWorkers.INTERRUPT_TARGET.task = outer
        end
    end

    @testset "interrupting a task parked in uv_write waits for the write callback" begin
        # Calling `schedule(t, InterruptException(); error=true)` while `t` is parked
        # in `Base.uv_write` (`t.queue === nothing`) races with `uv_writecb_task`,
        # throwing `schedule: Task not runnable` into whichever task polls libuv.
        p = Pipe()
        Base.link_pipe!(p)
        buf = fill(UInt8(65), 512 * 1024)
        started = Base.Event()
        writer = @async begin
            notify(started)
            try
                write(p.in, buf)
                sleep(60)
                return :completed
            catch e
                return e
            end
        end
        try
            wait(started)
            timedwait(() -> istaskdone(writer) || writer.queue === nothing, 5.0)
            @test !istaskdone(writer) && writer.queue === nothing
            @test RuntestsWorkers.schedule_interrupt(writer, InterruptException())
            # Not pre-scheduled while `uv_write` still owns the request pointer.
            @test writer.queue === nothing
            # Let `uv_write` finish cleanly; the deferred interrupt then stops `sleep(60)`.
            @test length(read(p.out, length(buf))) == length(buf)
            @test fetch(writer) isa InterruptException
        finally
            close(p.in)
            close(p.out)
        end
    end

    @testset "a held thread runs none of its tasks until it is released" begin
        # What the exit hook does to a run's thread while it closes the run.
        go = Threads.Event()
        t = stuck_task(go)
        tid = Threads.threadid(t)
        if tid == Threads.threadid()
            @test RuntestsWorkers.hold_thread(tid) === nothing
            notify(go)
        else
            hold = RuntestsWorkers.hold_thread(tid)
            @test hold[] == 1
            notify(go)
            sleep(0.3)
            @test !istaskdone(t)
            RuntestsWorkers.release_thread(hold)
        end
        @test fetch(t) === :let_go
    end

    @testset "a skip expression draws from the item's seed, and leaves the caller's numbers alone" begin
        # It runs where the item does, just before it: its draws repeat with the seed,
        # as the body's do, and the process's own sequence goes on as if it had not.
        skip = quote
            ENV["RUNTESTS_SKIP_DRAW"] = string(rand(UInt64))
            false
        end
        spec = probe_spec(:(@test true); skip)
        withenv("RUNTESTS_SKIP_DRAW" => nothing) do
            Random.seed!(42)
            expected = rand(UInt64)
            Random.seed!(42)
            draws = map(1:2) do _
                @test RuntestsWorkers.run_item(spec).state === PASSED
                ENV["RUNTESTS_SKIP_DRAW"]
            end
            @test draws[1] == draws[2]
            @test rand(UInt64) == expected
        end
    end

    Sys.iswindows() || @testset "the CPU reading declares libuv's fields as wide as libuv writes them" begin
        # libuv writes each field and leaves the padding as it was. Filled with ones
        # first, a field declared wider than libuv's reads ones where its value ends.
        buf = fill(0xff, sizeof(RuntestsWorkers.UvRusage))
        r = GC.@preserve buf begin
            @test ccall(:uv_getrusage, Cint, (Ptr{UInt8},), buf) == 0
            unsafe_load(Ptr{RuntestsWorkers.UvRusage}(pointer(buf)))
        end
        @test all(t -> 0 <= t.sec < 10^7 && 0 <= t.usec < 10^6, (r.utime, r.stime))
        a = RuntestsWorkers.cpu_time_ns()
        @test 0 < a <= RuntestsWorkers.cpu_time_ns()
    end

    @testset "a DONE record reads back whole, its numbers past 2^31 included" begin
        # A 32-bit `Int` holds 2.1 seconds of nanoseconds and 2 GiB.
        spec = probe_spec(:(@test true))
        stats = RuntestsWorkers.PerfStats(; elapsed_ns = 3_000_000_000, compile_ns = 2_500_000_000, maxrss = 5_000_000_000)
        line = RuntestsWorkers.record_done(spec, ItemResult(spec.index, PASSED, Test.DefaultTestSet("probe"), stats))
        rec = Runtests.Private.parse_record(line)
        @test rec !== nothing && rec.how.state === PASSED
        @test rec !== nothing && (rec.how.elapsed_ns, rec.how.compile_ns, rec.how.maxrss) == (3_000_000_000, 2_500_000_000, 5_000_000_000)
    end

    @testset "a worker evaluates, runs items, reports errors as text, and stops" begin
        out = IOBuffer()
        w = Worker(; threads="1", redirect_io=out)
        # On Windows a worker is held in a job, which ends what it starts.
        @test (w.job != C_NULL) == Sys.iswindows()
        try
            @test remote_fetch(w, :(global probe = 41)) === nothing
            err = try; remote_fetch(w, :(error("boom"))); catch e; e; end
            @test err isa RemoteException && occursin("boom", sprint(showerror, err))
            # An exception type that exists only on the worker still arrives, as text.
            err = try
                remote_fetch(w, quote struct OnlyHere <: Exception end; throw(OnlyHere()) end)
            catch e
                e
            end
            @test err isa RemoteException && occursin("OnlyHere", sprint(showerror, err))
            res = fetch(remote_run(w, probe_spec(:(begin @test Main.probe == 41 end))))
            @test res isa ItemResult && res.state === PASSED
            # ...and the worker is still usable afterwards.
            @test remote_fetch(w, :(1 + 1)) === nothing
        finally
            close(w)
        end
        @test process_exited(w.process)
        @test w.ended_by === :close
        @test w.process.exitcode == 0
        @test_throws WorkerTerminatedException remote_eval(w, :(1 + 1))
    end

    @testset "what an item's globals hold is let go when it ends" begin
        # The item's module outlives the item: it is bound in Main, and the methods
        # and types it defines are rooted for the life of the process. What its
        # globals refer to need not: item after item, it would pile up in the worker.
        probes = Core.eval(Main, :(const RUNTESTS_RELEASE_PROBES = WeakRef[]))
        shared = Core.eval(Main, :(const RUNTESTS_RELEASE_SHARED = [1, 2, 3]))
        res = RuntestsWorkers.run_item(probe_spec(quote
            global big = zeros(UInt8, 10^7)
            push!(Main.RUNTESTS_RELEASE_PROBES, WeakRef(big))
            # One that cannot hold `nothing` is given an empty container instead.
            global typed_big::Vector{UInt8} = zeros(UInt8, 10^7)
            push!(Main.RUNTESTS_RELEASE_PROBES, WeakRef(typed_big))
            const kept = 1          # a constant stays, and does not stop the rest
            global typed::Int = 2   # nor does a global with no empty value
            # What an item shares with the rest of the process is dropped, not emptied:
            # the next item on the worker may need it.
            global alias::Vector{Int} = Main.RUNTESTS_RELEASE_SHARED
            const also = Main.RUNTESTS_RELEASE_SHARED
            @test length(big) == 10^7
        end))
        @test res.state === PASSED
        GC.gc(true)
        @test [p.value for p in probes] == [nothing, nothing]
        @test shared == [1, 2, 3]
    end

    @testset "what an item defines is shown the way the item defines it" begin
        # The worker's loop was entered before the item ran, so a method the item
        # defines is newer than the loop: showing the item's values from there needs
        # the latest world, or a custom `show` is passed over for the default one.
        # A pass is kept, and so shown, only when Test is asked to keep passes, which
        # Julia 1.12 cannot be.
        keeps_passes = isdefined(Test, :TEST_RECORD_PASSES)
        with_worker(; threads="1", redirect_io=IOBuffer(),
                    extra_env=["JULIA_TEST_RECORD_PASSES" => "true"]) do w
            res = fetch(remote_run(w, probe_spec(quote
                struct Boom <: Exception end
                Base.show(io::IO, ::Boom) = print(io, "a custom Boom")
                @test_throws Boom throw(Boom())
            end)))
            @test res.state === PASSED
            keeps_passes && @test only(res.testset.results).value == "a custom Boom"
            # A `skip` that is not a Bool is the item's error, its value shown as it prints.
            odd = quote
                struct Maybe end
                Base.show(io::IO, ::Maybe) = print(io, "a custom Maybe")
                Maybe()
            end
            res = fetch(remote_run(w, probe_spec(:(begin end); name="odd skip", skip=odd)))
            @test res.state === ERRORED
            @test occursin("`skip` must evaluate to a Bool, got a custom Maybe", sprint(show, only(res.testset.results)))
        end
    end

    @testset "a worker that dies before it is ready is reported at once" begin
        t = @elapsed err = try
            Worker(; julia_args=["--no-such-flag"], redirect_io=IOBuffer())
        catch e
            e
        end
        @test err isa Exception
        @test occursin("before it was ready", sprint(showerror, err))
        @test t < 20   # neither the connect timeout nor a spin
    end

    @testset "closing a worker that cannot read the request still ends it" begin
        with_worker(; threads="1", redirect_io=IOBuffer()) do w
            remote_eval(w, :(while true end))    # a non-yielding loop on the worker's root task
            sleep(0.5)
            t = @elapsed close(w)
            @test process_exited(w.process)
            @test t < RuntestsWorkers.GRACEFUL_EXIT_SECONDS + RuntestsWorkers.TERM_GRACE_SECONDS + RuntestsWorkers.KILL_WAIT_SECONDS
        end
    end

    if !Sys.iswindows()
        @testset "a worker past its timeout reports where its tasks are" begin
            out = IOBuffer()
            with_worker(; threads="1", redirect_io=out) do w
                remote_eval(w, :(let c = Threads.Condition(); lock(c); wait(c) end))   # a deadlock on the root task
                sleep(0.5)
                RuntestsWorkers.inspect!(w)
                terminate!(w)
                wait(w)
            end
            @test occursin("live tasks", String(take!(out)))   # jl_print_task_backtraces ran on the worker
        end
    end

    # A process an item starts and does not wait for: `sleep` on Unix, where every
    # machine has one; Windows has no such command, so Julia sleeps instead.
    sleeper = Sys.iswindows() ? `$(Base.julia_cmd()) --startup-file=no -e "sleep(600)"` : `sleep 600`
    # `uv_kill` with signal 0 asks whether the process is there, on Windows too.
    alive(pid) = ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0

    @testset "a job ends every process it holds, one started inside it included" begin
        if Sys.iswindows()
            # A process that starts one of its own, says which, and waits. The job
            # holds it before it has run a line: Julia's startup alone outlasts that.
            script, pidfile = tempname() * ".jl", tempname()
            write(script, """
            p = run(`\$(Base.julia_cmd()) --startup-file=no -e "sleep(600)"`; wait=false)
            tmp = ARGS[1] * ".tmp"
            write(tmp, string(getpid(p)))
            mv(tmp, ARGS[1]; force=true)
            sleep(600)
            """)
            parent = run(`$(Base.julia_cmd()) --startup-file=no $script $pidfile`; wait=false)
            job = RuntestsWorkers.worker_job(getpid(parent))
            child = 0
            try
                @test job != C_NULL
                @test timedwait(() -> isfile(pidfile), 60) === :ok
                child = parse(Int, read(pidfile, String))
                @test alive(child)
                RuntestsWorkers.end_job!(job)
                job = C_NULL
                @test timedwait(() -> !alive(child) && process_exited(parent), 10) === :ok
            finally
                RuntestsWorkers.end_job!(job)
                child == 0 || ccall(:uv_kill, Cint, (Cint, Cint), child, Base.SIGKILL)
                process_running(parent) && kill(parent, Base.SIGKILL)
            end
        else
            # A process group does this elsewhere, and there is no job to end.
            @test RuntestsWorkers.worker_job(getpid()) == C_NULL
            @test RuntestsWorkers.end_job!(C_NULL) === nothing
        end
    end

    @testset "killing a worker kills the processes its item started" begin
        pidfile = tempname()
        child = 0
        with_worker(; threads="1", redirect_io=IOBuffer()) do w
            spec = probe_spec(:(begin write($pidfile, string(getpid(run($sleeper; wait=false)))) end);
                              name="spawner")
            fetch(remote_run(w, spec))
            child = parse(Int, read(pidfile, String))
            @test alive(child)
        end
        @test child != 0 && timedwait(() -> !alive(child), 5) === :ok
    end

    # A worker that exits by itself: what its item left running holds the output
    # pipe it inherited. On Unix `detach` puts the child in a session of its own,
    # beyond the reach of the worker's process group; on Windows it stays in the
    # worker's job.
    function exits_leaving(spawn)
        pidfile = tempname()
        w = Worker(; threads="1", redirect_io=IOBuffer())
        child = 0
        try
            fut = remote_eval(w, :(begin
                child = run(pipeline($spawn; stdout=stdout, stderr=stderr); wait=false)
                write($pidfile, string(getpid(child)))
                exit(7)
            end))
            @test_throws WorkerTerminatedException fetch(fut)
            child = parse(Int, read(pidfile, String))
            # Waited for from a task of its own, so a wait that never ends fails
            # this test rather than hanging it.
            waiter = @async wait(w)
            done = timedwait(() -> istaskdone(waiter), RuntestsWorkers.GRACEFUL_EXIT_SECONDS + 10) === :ok
            return (; done, gone = timedwait(() -> !alive(child), 5) === :ok)
        finally
            child == 0 || ccall(:uv_kill, Cint, (Cint, Cint), child, Base.SIGKILL)
        end
    end

    @testset "what a worker leaves running goes when it exits" begin
        r = exits_leaving(sleeper)
        @test r.done
        @test r.gone
    end

    @testset "a process that left the worker's group cannot hold its teardown" begin
        @test exits_leaving(detach(sleeper)).done
    end

    @testset "a worker nobody connects to exits on its own" begin
        cmd = `$(Base.julia_cmd()) --startup-file=no -e $(RuntestsWorkers.worker_startup_code(1))`
        proc = open(worker_child_env(cmd), "r+")
        println(proc, "x"^RuntestsWorkers.COOKIE_BYTES)
        # Its stdin open, as a coordinator keeps it: closed, it says the coordinator is gone.
        t = @elapsed wait(proc)
        close(proc.in)
        @test proc.exitcode == 1
        @test t < 30
        @test occursin("no coordinator connected", read(proc, String))
    end

    @testset "a worker whose coordinator is killed goes, and what its item started with it" begin
        # Killed outright, the coordinator runs no teardown, and the worker is in an item
        # that sleeps for ten minutes and reads nothing from the coordinator meanwhile.
        dir = mktempdir()
        pidfile = joinpath(dir, "pids")
        script = joinpath(dir, "coordinator.jl")
        write(script, """
            using Runtests: RuntestsWorkers
            w = RuntestsWorkers.Worker(; threads = "1", connect_timeout = 120, redirect_io = stderr)
            fut = RuntestsWorkers.remote_eval(w, :(begin
                child = run(Sys.iswindows() ? Cmd([Base.julia_cmd().exec..., "--startup-file=no", "-e", "sleep(600)"]) :
                            `sleep 600`; wait = false)
                tmp = $(repr(pidfile)) * ".tmp"
                write(tmp, string(getpid(), " ", getpid(child)))
                mv(tmp, $(repr(pidfile)); force = true)
                sleep(600)
            end))
            try
                fetch(fut)
            catch e
                showerror(stderr, e)
                println(stderr)
                exit(1)
            end
            sleep(600)
            """)
        log = Base.BufferStream()
        coordinator = run(pipeline(worker_child_env(`$(Base.julia_cmd()) --startup-file=no $script`);
                                   stdout = log, stderr = log); wait = false)
        pids = Int32[]
        try
            timedwait(() -> isfile(pidfile) || process_exited(coordinator), 300)
            isfile(pidfile) && append!(pids, parse.(Int32, split(read(pidfile, String))))
            if length(pids) != 2
                process_running(coordinator) && kill(coordinator, Base.SIGKILL)
                wait(coordinator)
                close(log)
                @info "coordinator did not write pidfile (exitcode=$(coordinator.exitcode)); output:\n$(read(log, String))"
            end
            @test length(pids) == 2
            kill(coordinator, Base.SIGKILL)
            wait(coordinator)
            close(log)
            # By the job that holds them on Windows; elsewhere, by the worker's watch on
            # the coordinator.
            gone = timedwait(() -> !any(alive, pids), 30) === :ok
            @test gone
            gone || foreach(p -> ccall(:uv_kill, Cint, (Cint, Cint), p, Base.SIGKILL), pids)
        finally
            process_running(coordinator) && kill(coordinator, Base.SIGKILL)
            isopen(log) && close(log)
            rm(dir; force = true, recursive = true)
        end
    end

    @testset "a worker waits out connections that are not its coordinator's" begin
        # Whatever else connects first, a scanner that hangs up or a client that says
        # something else, is closed; the connection that presents the cookie is served.
        cookie = "c"^RuntestsWorkers.COOKIE_BYTES
        port, server = listenany(Sockets.localhost, UInt16(21000))
        try
            accepted = Threads.@spawn RuntestsWorkers.accept_coordinator(server, cookie)
            close(connect(Sockets.localhost, port))
            other = connect(Sockets.localhost, port)
            write(other, "x"^RuntestsWorkers.COOKIE_BYTES)
            # Closed, never answered, before the coordinator connects: of two
            # connections waiting at once, libuv on Windows hands `accept` the newer
            # first, and the older would never be accepted at all.
            closed = Threads.@spawn eof(other)
            @test timedwait(() -> istaskdone(closed), 60) === :ok && fetch(closed)
            coordinator = connect(Sockets.localhost, port)
            write(coordinator, cookie)
            sock = fetch(accepted)
            write(sock, "served\n")
            @test readline(coordinator) == "served"
            close(sock); close(other); close(coordinator)
        finally
            close(server)
        end
    end

    @testset "waiting for a process to exit wakes when it exits, and gives up at the limit" begin
        quick = run(`$(Base.julia_cmd()) --startup-file=no -e "sleep(1)"`; wait = false)
        t = @elapsed exited = RuntestsWorkers.wait_exit(quick, 120)
        @test exited && process_exited(quick)
        @test t < 60   # woken by the exit, not by the limit
        slow = run(`$(Base.julia_cmd()) --startup-file=no -e "sleep(600)"`; wait = false)
        try
            t = @elapsed exited = RuntestsWorkers.wait_exit(slow, 1)
            @test !exited && 0.95 <= t < 60
        finally
            kill(slow, Base.SIGKILL)
            wait(slow)
        end
    end

    @testset "killed from an exit hook, a worker is signalled and its connection left open" begin
        # Closing the connection waits for the event loop, which an exit hook may not
        # get again; the exit closes it.
        w = Worker(; threads="1", redirect_io=IOBuffer())
        try
            RuntestsWorkers.kill!(w; exiting = true)
            @test isopen(w.socket)
            @test w.terminated && w.ended_by === :interrupt
            @test RuntestsWorkers.wait_exit(w.process, 30)
        finally
            close(w.socket)
            wait(w)
        end
    end

    @testset "remote_activate switches active project and LOAD_PATH in place" begin
        alt = mktempdir()
        alt_proj = joinpath(alt, "Project.toml")
        write(alt_proj, "[deps]\n")
        extra_dir = mktempdir()
        with_worker(; threads="1", redirect_io=IOBuffer()) do w
            new_lp = String["@", extra_dir, "@stdlib"]
            @test fetch(RuntestsWorkers.remote_activate(w, alt_proj, new_lp)) === nothing
            res = fetch(remote_run(w, probe_spec(:(begin
                @test abspath(Base.active_project()) == abspath($alt_proj)
                @test abspath(ENV["JULIA_PROJECT"]) == abspath($alt_proj)
                @test LOAD_PATH == $new_lp
            end); name = "activated")))
            @test res.state === PASSED
        end
    end

    @testset "abort_worker_process! and interrupted connect_worker leave no process behind" begin
        wp = RuntestsWorkers.spawn_worker_process(; threads="1")
        @test wp.pid > 0
        RuntestsWorkers.abort_worker_process!(wp)
        @test Base.process_exited(wp.proc)
        @test @lock(RuntestsWorkers.LIVE_LOCK, !(wp.proc in RuntestsWorkers.LIVE_PROCESSES))
        Sys.iswindows() || @test all_gone([wp.pid])

        # Interrupting `connect_worker` while the process is still booting must kill
        # and reap it rather than leaving a detached worker behind.
        wp2 = RuntestsWorkers.spawn_worker_process(; threads="1")
        pid2 = wp2.pid
        t = @async RuntestsWorkers.connect_worker(wp2; redirect_io=IOBuffer())
        yield()
        schedule(t, InterruptException(); error=true)
        err = try
            w, _ = fetch(t)
            close(w)
            nothing
        catch e
            e
        end
        @test err isa TaskFailedException && err.task.exception isa InterruptException
        @test Base.process_exited(wp2.proc)
        @test @lock(RuntestsWorkers.LIVE_LOCK, !(wp2.proc in RuntestsWorkers.LIVE_PROCESSES))
        Sys.iswindows() || @test all_gone([pid2])
    end

    @testset "these tests leave no worker running" begin
        @test @lock(RuntestsWorkers.LIVE_LOCK, count(Base.process_running, RuntestsWorkers.LIVE_PROCESSES)) == 0
    end
end

@testset "the profile report is not laid out for a pipe" begin
    # A worker's output is a pipe, and `displaysize` calls a pipe eighty columns.
    # The report the inspection prints is a table of file, line and function fitted
    # to that width, so eighty columns is where the part naming what ran is cut.
    before = get(ENV, "COLUMNS", nothing)
    inside = RuntestsWorkers.wide_display() do
        (something(tryparse(Int, get(ENV, "COLUMNS", "")), 0), displaysize(stdout))
    end
    @test inside[1] >= 1000
    # What the report actually consults, and the reason for setting the variable.
    @test inside[2][1] >= 1000 && inside[2][2] >= 1000
    # Scoped to the report: the rest of the worker formats for whatever it had.
    @test get(ENV, "COLUMNS", nothing) == before
end
