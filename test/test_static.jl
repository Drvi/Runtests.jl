# Checks of the package's own code rather than of what it does: Aqua for how the
# package is put together, JET for errors and dynamic dispatch in the code a run
# depends on, AllocCheck for the functions that exist to allocate nothing, and a
# lowered-code check that hot and concurrent functions create no `Core.Box`.

using Aqua: Aqua
using JET: JET
using AllocCheck: check_allocs
using Runtests: RuntestsWorkers
using Sockets: TCPSocket

const P = Runtests.Private
const W = RuntestsWorkers

# What JET reports on: every module of this package (including standalone helpers),
# while ignoring issues inside `Base` or `Test`.
const OURS = (P, W, P.Platform, P.PrecompileHelper, P.Expander)

@testset "static checks" begin
    @testset "Aqua: packaging" begin
        # Pkg and TestEnv are loaded when an environment is built, not with the package
        # (see `with_pkg`), which Aqua would otherwise call stale.
        Aqua.test_all(Runtests; stale_deps = (ignore = [:Pkg, :TestEnv],))
    end

    # From each public entry point, subprocess entry point, exit hook, and spawned task
    # loop, through everything it calls. Combined-run entry points only where workspaces
    # exist: before Julia 1.12, they always throw to say that they need it.
    mono = VERSION >= v"1.12" ? (
            ("runtests_mono", Runtests.runtests_mono, (String,)),
            ("runtestsd_mono", Runtests.runtestsd_mono, (String,)),
            ("chores_mono", Runtests.chores_mono, (String,)),
            ("activate_mono", Runtests.activate_mono, (String,)),
            ("serve_mono", Runtests.serve_mono, (String,)),
        ) : ()
    @testset "JET: no error the analysis can find from $name" for (name, f, types) in (
            ("runtests", Runtests.runtests, (String,)),
            ("runtestsd", Runtests.runtestsd, (String,)),
            ("runtestsf", Runtests.runtestsf, (String,)),
            mono...,
            ("chores", Runtests.chores, (String,)),
            ("setups_to_packages", Runtests.setups_to_packages, (String,)),
            ("activate", Runtests.activate, (String,)),
            ("deactivate", Runtests.deactivate, ()),
            ("is_activated", Runtests.is_activated, ()),
            ("debug", Runtests.debug, (String,)),
            ("serve", Runtests.serve, (String,)),
            ("read_run_state", Runtests.read_run_state, (String,)),
            ("current_testitem", Runtests.current_testitem, ()),
            ("artifacts_dir", Runtests.artifacts_dir, ()),
            ("on_failure", Runtests.on_failure, (typeof(identity),)),
            ("a pasted @testitem", P.run_interactive, (Expr, LineNumberNode)),
            ("a worker", W.startworker, (Int,)),
            ("precompile helper", P.PrecompileHelper.serve, (IOBuffer,)),
            ("template expander", P.Expander.expand_file, (String, String)),
            ("exit hook (run)", P.report_unfinished_run, ()),
            ("exit hook (workers)", W.kill_leftovers, ()),
            ("worker slot loop", P.run_slot, (P.Run, P.Slot)),
            ("monitor loop", P.monitor_loop, (P.Monitor,)),
            ("stall watchdog", P.watch, (P.Run, Timer, Float64)),
            ("precompile queue job", P.run_queue_job!, (P.QueueRun, Int)),
            ("merge_coverage", P.merge_coverage, (String, Vector{String}, String)),
            ("collect_coverage", P.collect_coverage, (P.Run,)),
            ("finish_attempt!", P.finish_attempt!, (P.Run, P.Slot, P.ItemIdx, Int8, W.ItemResult, W.Worker)),
            ("finish_here!", P.finish_here!, (W.ItemSpec, W.ItemResult)),
            ("run_test_end (EndSpec)", W.run_test_end, (W.EndSpec, Expr)),
            ("platform self-check", P.Platform.ensure_checked!, ()),
            ("show(RunTestSet)", show, (IOBuffer, P.RunTestSet)),
            ("show(RunStateRecord)", show, (IOBuffer, P.RunStateRecord)),
        )
        JET.test_call(f, types; target_modules = OURS)
    end

    # Once per unit, per record a worker writes, per run state kept, per monitor sample,
    # per status redraw, or per message: where a dynamic dispatch would be paid thousands
    # of times a run.
    @testset "JET: no dynamic dispatch in $name" for (name, f, types) in (
            ("claim!", P.claim!, (P.Queues, P.SlotIdx)),
            ("neediest_pool", P.neediest_pool, (P.Queues, Int32)),
            ("pool_units", P.pool_units, (Vector{P.ProfileIdx}, Vector{P.Profile}, Vector{Int32}, P.Packages)),
            ("pool_key", P.pool_key, (P.Profile, Int, String, Bool)),
            ("environment_of", P.environment_of, (String, Vector{Pair{String, String}})),
            ("item_seed", P.item_seed, (UInt64, String, String)),
            ("same_profile", P.same_profile, (P.Profile, P.Profile)),
            ("parse_record", P.parse_record, (String,)),
            ("write_status!", P.write_status!, (P.RunStateFile, P.ItemIdx, P.ItemState, Int8, P.SlotIdx)),
            ("write_memory!", P.write_memory!, (P.RunStateFile, P.MemStats)),
            ("append_event!", P.append_event!, (P.RunStateFile, UInt8, UInt8, P.SlotIdx, Int32, Float64, Float64)),
            ("read_run_state", P.read_run_state, (String,)),
            ("read_run_meta", P.read_run_meta, (String,)),
            ("removable_runs", P.removable_runs, (Vector{Pair{String, P.RunStateRecord}}, Vector{String})),
            ("idle_worker_seconds", P.idle_worker_seconds, (P.RunStateRecord,)),
            ("bytes_within", P.bytes_within, (Vector{UInt8}, Int, Int, Int)),
            ("print_status_line", P.print_status_line, (IOBuffer, P.Monitor)),
            ("sample!", P.sample!, (P.Monitor,)),
            ("Platform.process_rss", P.Platform.process_rss, (Int32,)),
            ("Platform.machine_memory", P.Platform.machine_memory, ()),
            ("Platform.cpu_ticks", P.Platform.cpu_ticks, ()),
            ("Platform.process_cpu_seconds", P.Platform.process_cpu_seconds, ()),
            ("Platform.process_owners", P.Platform.process_owners, (Vector{Int32},)),
            ("read_message", W.read_message, (TCPSocket, W.FrameReader)),
            ("encode_message!", W.encode_message!, (IOBuffer, UInt64, UInt8, W.ItemSpec)),
            ("encode_message! (EndSpec)", W.encode_message!, (IOBuffer, UInt64, UInt8, Tuple{W.EndSpec, Expr})),
        )
        JET.test_opt(f, types; target_modules = OURS)
    end

    # Each is on a path taken for every item, record, redraw, sample or message. What is
    # checked is the function's own body: `parse_record` builds no string for a field,
    # though the record it returns, one of three shapes, is boxed at a caller that has
    # to tell them apart.
    apple_allocs = Sys.isapple() ? (
            ("Platform.process_rss", P.Platform.process_rss, (Int32,)),
            ("Platform.process_cpu_seconds", P.Platform.process_cpu_seconds, ()),
        ) : ()
    @testset "AllocCheck: nothing allocated in $name" for (name, f, types) in (
            ("parse_record", P.parse_record, (String,)),
            ("bytes_within", P.bytes_within, (Vector{UInt8}, Int, Int, Int)),
            ("header_field", W.header_field, (Vector{UInt8}, Type{UInt64}, Int)),
            ("verdict", P.verdict, (P.RunStateRecord, Int)),
            ("gate_full", P.gate_full, (P.Queues, P.ItemIdx)),
            ("environment_of", P.environment_of, (String, Vector{Pair{String, String}})),
            ("idle_worker_seconds", P.idle_worker_seconds, (P.RunStateRecord,)),
            apple_allocs...,
        )
        allocs = check_allocs(f, types)
        @test isempty(allocs)
        isempty(allocs) || foreach(a -> (show(stdout, a); println(stdout)), allocs)
    end

    # Captured mutable bindings in concurrent or hot functions box variables into shared
    # `Core.Box`es, causing data races across tasks and runtime dispatch in loops.
    @testset "No Core.Box in $name" for (name, f, types) in (
            ("run_queue", P.run_queue, (P.Run, P.PrecompileQueue)),
            ("run_on_workers", P.run_on_workers, (P.Run,)),
            ("run_slot", P.run_slot, (P.Run, P.Slot)),
            ("plan", P.plan, (Vector{P.RawItem}, P.RunConfig)),
            ("merge_coverage", P.merge_coverage, (String, Vector{String}, String)),
            ("sample!", P.sample!, (P.Monitor,)),
            ("removable_runs", P.removable_runs, (Vector{Pair{String, P.RunStateRecord}}, Vector{String})),
            ("serve_requests", W.serve_requests, (TCPSocket,)),
            ("process_responses", W.process_responses, (W.Worker,)),
            ("connect_worker", W.connect_worker, (W.WorkerProcess,)),
            ("prespawn_workers!", P.prespawn_workers!, (P.Run, P.Plan)),
            ("read_run_state", P.read_run_state, (String,)),
            ("read_run_meta", P.read_run_meta, (String,)),
        )
        @test !occursin("Core.Box", string(only(code_lowered(f, types))))
    end

    # Guard against cross-platform and flakiness footguns in our own test suite that
    # pass locally on a fast macOS machine and break on Windows or loaded CI runners.
    @testset "test suite hygiene" begin
        test_files = sort!(filter(f -> endswith(f, ".jl") && f != "test_static.jl", readdir(@__DIR__)))
        @test !isempty(test_files)
        bad_setenv = String[]
        bad_symlink = String[]
        bad_mtime_sleep = String[]
        bad_tight_timeout = String[]
        for fname in test_files
            lines = readlines(joinpath(@__DIR__, fname))
            full = join(lines, '\n')
            for (i, line) in enumerate(lines)
                stripped = lstrip(line)
                startswith(stripped, '#') && continue
                # `setenv` wipes `JULIA_DEPOT_PATH`, leaking throwaway fixture caches into
                # `~/.julia/compiled/` unless the file forwards it.
                if occursin(r"\bsetenv\(", line) && !occursin("JULIA_DEPOT_PATH", full)
                    push!(bad_setenv, "$fname:$i")
                end
                # Unprivileged Windows runners cannot create symlinks.
                if occursin(r"\bsymlink\(", line)
                    ctx = join(lines[max(1, i - 5):i], '\n')
                    occursin("Sys.iswindows()", ctx) || push!(bad_symlink, "$fname:$i")
                end
                # Waiting on filesystem mtime ticks is slow and flaky; use `bump_mtime!`.
                if occursin(r"\bsleep\([^)]+\)\s*;\s*touch\(", line) ||
                   (occursin(r"^\s*sleep\(", line) && i < length(lines) && occursin(r"^\s*touch\(", lines[i + 1]))
                    push!(bad_mtime_sleep, "$fname:$i")
                end
                # Hook/artifact timeouts of 1s race fresh-worker compilation on slow CI runners,
                # and a 1s item timeout is only safe on an intentional hang (`sleep(`).
                if occursin(r"\b(test_end_timeout|init_timeout|artifacts_timeout)\s*=\s*1(?![.\deE])", line) &&
                   !occursin("read_config(", line) && !occursin("allow-short-timeout", line)
                    push!(bad_tight_timeout, "$fname:$i")
                elseif occursin(r"\btimeout\s*=\s*1(?![.\deE])", line) &&
                       !occursin("read_config(", line) &&
                       !occursin(r"timeout\s*=\s*1\s+timeout\s*=", line) &&
                       !occursin("allow-short-timeout", line)
                    ctx = join(lines[i:min(length(lines), i + 5)], '\n')
                    (occursin("@testitem", line) && occursin("sleep(", ctx)) || push!(bad_tight_timeout, "$fname:$i")
                end
            end
        end
        @test isempty(bad_setenv)
        @test isempty(bad_symlink)
        @test isempty(bad_mtime_sleep)
        @test isempty(bad_tight_timeout)
    end
end
