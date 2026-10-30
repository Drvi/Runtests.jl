# Evidence from a failed attempt, on the side of the process that runs the item: the
# directory an item writes outputs into, and the producers it registers to run if the
# attempt fails. The coordinator says where an attempt's evidence goes, and decides
# what is kept.
#
#     <dir>/files/          artifacts_dir(): what the item writes while it runs
#     <dir>/producer_<k>/   what the k-th producer writes, if the attempt fails
#     <dir>.log             what collecting said: producers' output, errors, timings
#
# Nothing is created until an item asks: `artifacts_dir()` makes `files/`, the first
# producer writes `<dir>.log`, which tells the coordinator of a worker that died that
# producers were waiting, and collecting makes each `producer_<k>/`.

"""
    AttemptArtifacts

One attempt's evidence: where it goes, and the producers registered for it. Open for
registration while the item's body runs; closed, under `lock`, once it returns, so a
task the item did not wait for cannot register against a later attempt.
"""
mutable struct AttemptArtifacts
    const index     :: Int32
    const attempt   :: Int8
    const dir       :: String           # "" when the attempt was given nowhere to keep evidence
    const info      :: TestItemInfo     # what `current_testitem()` says while producers run
    const full_stacktraces :: Bool      # a producer's error keeps the framework's own frames
    const lock      :: ReentrantLock    # guards everything below
    const producers :: Vector{Any}
    open            :: Bool
    files           :: Bool             # whether `files/` was made
    # The item's module, kept from `release_globals!` while producers may still read it;
    # empty when there is nothing to let go of.
    modsym          :: Symbol
end

AttemptArtifacts(spec::ItemSpec) = AttemptArtifacts(
    spec.index, spec.attempt, spec.artifacts,
    TestItemInfo(spec.name, spec.file, spec.line, spec.attempt, spec.profile), spec.full_stacktraces,
    ReentrantLock(), Any[], true, false, Symbol("")
)

# What an attempt's result says of its evidence, so that one with none costs the
# coordinator nothing further.
const ARTIFACT_FILES     = 0x01   # it made `files/`
const ARTIFACT_PRODUCERS = 0x02   # it registered producers

artifact_flags(a::AttemptArtifacts) = @lock a.lock UInt8(
    (a.files ? ARTIFACT_FILES : 0x00) | (isempty(a.producers) ? 0x00 : ARTIFACT_PRODUCERS)
)

"""
    artifacts_log_path(dir) -> String

Where what was said of collecting the evidence in `dir` goes: beside it, so that the
directory holds only what the test wrote.
"""
artifacts_log_path(dir::AbstractString) = string(dir, ".log")

# Set for the length of an item's body, and seen by the tasks it starts.
const CURRENT_ARTIFACTS = ScopedValue{Union{Nothing, AttemptArtifacts}}(nothing)

# The attempt whose producers wait for the coordinator's verdict, or `nothing`. Read
# and written by the task that serves requests, one at a time.
const PENDING_ARTIFACTS = Ref{Union{Nothing, AttemptArtifacts}}(nothing)

# The attempt a call from test code belongs to, or an error saying why there is none.
function current_artifacts(what::AbstractString)
    a = CURRENT_ARTIFACTS[]
    a === nothing && throw(ArgumentError(string(
        "`Runtests.", what, "` works in the body of a running test item, and the tasks it starts: not in ",
        "a profile's `init` or `test_end`, in `skip`, outside a test item, or in a producer"
    )))
    isempty(a.dir) && throw(ArgumentError(string(
        "`Runtests.", what, "`: this attempt was started without a directory for its evidence"
    )))
    return a
end

closed_error(what::AbstractString) = ArgumentError(string(
    "`Runtests.", what, "` was called after the test item's body returned, from a task it did not wait ",
    "for; an item waits for the tasks it starts, or they outlive its attempt"
))

"""
    on_failure(f) -> nothing

Register `f` to be called with a directory of its own if this attempt at the test item
fails, and not otherwise. Producers are called once each, in the order registered, after
the item and its profile's `test_end` have finished and the verdict is recorded, so they
see the values they refer to as they are then. What they write is kept with the
attempt's evidence; what they throw, or a `@test` in them that fails, is reported there
and never changes the verdict.

Only in the body of a running test item, or in a task it starts and waits for.
"""
function on_failure(f)
    a = current_artifacts("on_failure")
    first_one = @lock a.lock begin
        a.open || throw(closed_error("on_failure"))
        push!(a.producers, f)
        length(a.producers) == 1
    end
    first_one && note_registration(a)
    return nothing
end

"""
    artifacts_dir() -> String

The directory this attempt at the test item keeps outputs in, made the first time it
is asked for. What is written there is deleted if the attempt passes and kept if it
fails. The same directory every time within one attempt; another for each attempt.

Only in the body of a running test item, or in a task it starts and waits for.
"""
function artifacts_dir()
    a = current_artifacts("artifacts_dir")
    return @lock a.lock begin
        a.open || throw(closed_error("artifacts_dir"))
        dir = joinpath(a.dir, "files")
        a.files || (mkpath(dir); a.files = true)
        dir
    end
end

# The first producer leaves word beside the evidence, for the coordinator to find if the
# worker does not survive to say. A note that cannot be written loses that word only.
function note_registration(a::AttemptArtifacts)
    try
        mkpath(dirname(a.dir))
        open(io -> println(io, "producers registered; they run if this attempt fails"),
             artifacts_log_path(a.dir), "a")
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not write beside $(a.dir) that this attempt registered producers" exception = e
    end
    return nothing
end

# The body has returned: nothing more registers. Whether producers wait, in which case
# the item's module `modsym` is kept for them, unless it is empty.
function close_registration!(a::AttemptArtifacts, modsym::Symbol)
    @lock a.lock begin
        a.open = false
        isempty(a.producers) && return false
        a.modsym = modsym
        return true
    end
end

# Let go of what an attempt's producers, and the module kept for them, refer to.
function release_artifacts!(a::AttemptArtifacts)
    m = @lock a.lock begin
        empty!(a.producers)
        m = a.modsym
        a.modsym = Symbol("")
        m
    end
    m === Symbol("") || release_globals!(Main, m)
    return nothing
end

"""
    discard_artifacts!()

Let go of producers still waiting for a verdict that did not want them: the attempt
passed. Called before the process runs another item.
"""
function discard_artifacts!()
    a = PENDING_ARTIFACTS[]
    a === nothing && return nothing
    PENDING_ARTIFACTS[] = nothing
    release_artifacts!(a)
    return nothing
end

"""
    finish_artifacts(index, attempt, collect) -> NamedTuple

Run the producers attempt `attempt` at item `index` registered, when `collect`, and then
let go of them and of the item's module either way. Returns how many ran, how many
failed, and how long they took. Throws when no producers of that attempt are waiting.
"""
function finish_artifacts(index::Integer, attempt::Integer, collect::Bool)
    a = PENDING_ARTIFACTS[]
    (a === nothing || a.index != index || a.attempt != attempt) &&
        error("no producers of attempt $attempt at item $index are waiting")
    PENDING_ARTIFACTS[] = nothing
    try
        return collect ? run_producers(a) : (producers = 0, failed = 0, seconds = 0.0)
    finally
        release_artifacts!(a)
    end
end

# Each producer in turn, with what it prints, its errors and its timing in the log
# beside the evidence. One that fails leaves the rest to run.
function run_producers(a::AttemptArtifacts)
    producers = @lock a.lock copy(a.producers)
    t0 = time()
    failed = 0
    capture_output(artifacts_log_path(a.dir)) do
        with(CURRENT_TESTITEM => a.info) do
            for (k, f) in enumerate(producers)
                failed += !run_producer(f, k, joinpath(a.dir, string("producer_", k)), a.full_stacktraces)
            end
        end
        println(stdout, "collected: ", length(producers), length(producers) == 1 ? " producer" : " producers",
                ", ", failed, " failed, in ", round(time() - t0; digits = 2), "s")
    end
    return (producers = length(producers), failed, seconds = time() - t0)
end

# Whether producer `k` ran to its end with every test in it passing. Its tests are
# recorded in a testset of its own, never the item's, and an error it throws is shown
# down to the frame that called it, as an item's is.
function run_producer(f, k::Int, dir::String, full_stacktraces::Bool)
    t = time()
    name = string("producer ", k, " (producer_", k, "/)")
    ts = Test.DefaultTestSet(name)
    ok = try
        mkpath(dir)
        without_enclosing_testset() do
            with_testset(ts) do
                Base.invokelatest(f, dir)
            end
        end
        true
    catch e
        is_interrupt(e) && rethrow()
        bt = catch_backtrace()
        println(stdout, name, " threw:")
        println(stdout, format_error(e, full_stacktraces ? bt : trim_backtrace(bt)))
        false
    end
    passed = state_of(ts) === PASSED
    passed || println(stdout, name, ": a test in it did not pass; a producer's tests are not the item's")
    println(stdout, name, ok && passed ? ": done" : ": failed", " in ", round(time() - t; digits = 2), "s")
    return ok && passed
end
