# Checks of the package's own code rather than of what it does: Aqua for how the two
# packages are put together, JET for errors and dynamic dispatch in the code a run
# depends on, and AllocCheck for the functions that exist to allocate nothing.

using Aqua: Aqua
using JET: JET
using AllocCheck: check_allocs
using RuntestsWorkers: RuntestsWorkers
using Sockets: TCPSocket

const P = Runtests.Private
const W = RuntestsWorkers

# What JET reports on: a problem inside `Base` or `Test` is not this package's to fix.
const OURS = (P, W)

@testset "static checks" begin
    @testset "Aqua: packaging" begin
        Aqua.test_all(Runtests)
        Aqua.test_all(RuntestsWorkers)
    end

    # From each public entry point, and the worker's, through everything it calls.
    @testset "JET: no error the analysis can find from $name" for (name, f, types) in (
            ("runtests", Runtests.runtests, (String,)),
            ("runtestsf", Runtests.runtestsf, (String,)),
            ("chores", Runtests.chores, (String,)),
            ("setups_to_packages", Runtests.setups_to_packages, (String,)),
            ("activate", Runtests.activate, (String,)),
            ("deactivate", Runtests.deactivate, ()),
            ("debug", Runtests.debug, (String,)),
            ("serve", Runtests.serve, (String,)),
            ("read_run_state", Runtests.read_run_state, (String,)),
            ("a pasted @testitem", P.run_interactive, (Expr, LineNumberNode)),
            ("a worker", W.startworker, (Int,)),
        )
        JET.test_call(f, types; target_modules = OURS)
    end

    # Once per unit, per record a worker writes, per run state kept, or per message:
    # where a dispatch would be paid thousands of times a run.
    @testset "JET: no dynamic dispatch in $name" for (name, f, types) in (
            ("claim!", P.claim!, (P.Queues, P.SlotIdx)),
            ("parse_record", P.parse_record, (String,)),
            ("write_status!", P.write_status!, (P.RunStateFile, P.ItemIdx, P.ItemState, Int8, P.SlotIdx)),
            ("append_event!", P.append_event!, (P.RunStateFile, UInt8, UInt8, P.SlotIdx, Int32, Float64, Float64)),
            ("read_run_state", P.read_run_state, (String,)),
            ("removable_runs", P.removable_runs, (Vector{Pair{String, P.RunStateRecord}}, Vector{String})),
            ("bytes_within", P.bytes_within, (Vector{UInt8}, Int, Int, Int)),
            ("read_message", W.read_message, (TCPSocket, W.FrameReader)),
        )
        JET.test_opt(f, types; target_modules = OURS)
    end

    # Each is on a path taken for every item, record, redraw or message. What is
    # checked is the function's own body: `parse_record` builds no string for a
    # field, though the record it returns, one of three shapes, is boxed at a caller
    # that has to tell them apart.
    @testset "AllocCheck: nothing allocated in $name" for (name, f, types) in (
            ("parse_record", P.parse_record, (String,)),
            ("bytes_within", P.bytes_within, (Vector{UInt8}, Int, Int, Int)),
            ("header_field", W.header_field, (Vector{UInt8}, Type{UInt64}, Int)),
            ("verdict", P.verdict, (P.RunStateRecord, Int)),
        )
        allocs = check_allocs(f, types)
        @test isempty(allocs)
        isempty(allocs) || foreach(a -> (show(stdout, a); println(stdout)), allocs)
    end
end
