# Runtests' own tests use plain Test.jl, not Runtests: a test framework that can only be
# tested by itself cannot be trusted at the moment it is broken. For the same
# reason the files are run in plain subprocesses rather than on Runtests' own worker
# pool — a bug in the transport would stop the suite from running instead of
# telling you which test it broke.
#
#     julia --project=test test/runtests.jl                    every file, in parallel
#     julia --project=test test/runtests.jl test_scan.jl       one file, in this process
#     RUNTESTS_TEST_JOBS=1 julia --project=test test/runtests.jl   every file, in this process
#
# `test/` is a project in the package's workspace, with the test-only dependencies,
# and `Pkg.test()` runs in it too.
#
# Each file is independent: it builds the fixtures it needs and asserts only on
# what it built.

using Test
using Runtests

# A worker finds RuntestsWorkers through the load path it is given, and `@` there means
# the worker's own project, which is a fixture's. `Pkg.test` puts this environment
# on the path by name; a run started with `--project=test` has to do it here.
let env = dirname(Base.active_project())
    env in LOAD_PATH || push!(LOAD_PATH, env)
end

const FIXTURES = joinpath(@__DIR__, "testfixtures")
fixture(name) = joinpath(FIXTURES, name)

include("helpers.jl")
include("parallel.jl")

# Slowest first (ordered by measured wall-clock duration). The files are independent
# and the run is only as short as its longest tail, so long files start first.
const TEST_FILES = [
    "test_execute.jl",
    "test_monorepo.jl",
    "test_precompile.jl",
    "test_timeouts.jl",
    "test_crashes.jl",
    "test_runstate.jl",
    "test_runner.jl",
    "test_environments.jl",
    "test_setups.jl",
    "test_artifacts.jl",
    "test_monitor.jl",
    "test_static.jl",
    "test_editor.jl",
    "test_templates.jl",
    "test_sandbox.jl",
    "test_workers.jl",
    "test_where_code_runs.jl",
    "test_debug.jl",
    "test_testenv.jl",
    "test_interactive.jl",
    "test_matrix.jl",
    "test_port.jl",
    "test_output.jl",
    "test_pkgtest.jl",
    "test_coverage.jl",
    "test_shared_runstates.jl",
    "test_config.jl",
    "test_groups.jl",
    "test_plan.jl",
    "test_filters.jl",
    "test_fixtures.jl",
    "test_chores.jl",
    "test_scan.jl",
    "test_gating.jl",
]

# CI sets `RUNTESTS_TEST_JOBS` explicitly for its 2-4 core runners; locally scale gently
# with CPU count (capped at 6 to bound peak RSS across worker-spawning test files).
default_jobs() = something(tryparse(Int, get(ENV, "RUNTESTS_TEST_JOBS", "")), clamp(Sys.CPU_THREADS ÷ 3, 4, 6))

"""
    run_file(file)

Run one test file in this process and let `Test` decide the verdict: a failing
`@testset` throws, which is what makes the process exit non-zero.
"""
run_file(file::AbstractString) = @testset "$file" begin
    # A run state directory of the file's own: what its runs record, and what its
    # `chores` calls prune, stays out of the depot of whoever runs the suite, and out
    # of every other file's way.
    withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
        include(joinpath(@__DIR__, file))
    end
end

# Where the suite ran, for a CI log read by someone who was not there.
print_environment() = println(
    "[tests] julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, ") · ", Sys.MACHINE, " · ",
    Sys.CPU_THREADS, " CPU threads · ", round(Sys.total_memory() / 1.0e9; digits = 1), "G · threads ",
    Threads.nthreads(:default), ",", Threads.nthreads(:interactive), " · ", default_jobs(), " files at a time",
    get(ENV, "CI", "") == "true" ? " · CI" : ""
)

"""
    with_temp_test_depot(f)

Prepend a temporary writable depot for Runtests' own test suite so precompile caches of
throwaway fixture packages and setups do not accumulate in the user's `~/.julia/compiled/`.
Existing caches and registries are still read from the remaining `DEPOT_PATH` entries.
"""
function with_temp_test_depot(f)
    get(ENV, "RUNTESTS_TEST_DEPOT", "") == "1" && return f()
    pathsep = Sys.iswindows() ? ";" : ":"
    depot = mktempdir(; prefix = "runtests_test_depot_")
    pushfirst!(DEPOT_PATH, depot)
    try
        return withenv("RUNTESTS_TEST_DEPOT" => "1", "JULIA_DEPOT_PATH" => join(DEPOT_PATH, pathsep)) do
            f()
        end
    finally
        filter!(!=(depot), DEPOT_PATH)
        rm(depot; force = true, recursive = true)
    end
end

if !isempty(ARGS)
    # A child, or someone running one file by hand. The hook makes the signal a
    # hung file is sent print every task's backtrace, which is where it is stuck.
    RuntestsWorkers.install_inspection_hook()
    # Windows has no such signal: a file still running a minute before the runner's
    # limit prints the backtraces itself, into the log the runner shows once it kills it.
    RuntestsWorkers.INSPECT_SIGNAL === nothing && Timer(max(FILE_LIMIT_SECONDS - 60, 1)) do _
        println(stderr, "[tests] ", join(ARGS, ", "), " still running after ", FILE_LIMIT_SECONDS - 60,
                "s: every task's backtrace follows")
        # Before the backtraces, which the runtime writes to the descriptor directly.
        flush(stderr)
        ccall(:jl_print_task_backtraces, Cvoid, (Cint,), 0)
    end
    with_temp_test_depot(() -> foreach(run_file, ARGS))
elseif default_jobs() <= 1
    print_environment()
    with_temp_test_depot() do
        @testset "Runtests" begin
            for file in TEST_FILES
                println(stdout, "[tests] running ", file)
                run_file(file)
            end
        end
    end
else
    print_environment()
    results, memory = with_temp_test_depot(() -> run_in_parallel(@__FILE__, TEST_FILES, default_jobs()))
    report_files(results; memory, jobs = default_jobs())
end
