# A run state is binary, with fixed-stride status and event records written as the
# run goes, so that a killed coordinator still leaves behind which items passed and
# how long they took. A standalone run writes one record; a combined run writes one
# for each participating package. A record downloaded from CI and passed to
# `runtests(replay = path)` or `runtests_mono(replay = path)` brings back the items,
# configuration, profiles and seed, and says how the environment differs from the
# one it was recorded in.
#
# Layout (hot planning prefix first, cold replay data second, append-only events last):
#
#   header       96 B, fixed, holds the section offsets
#   hot_strings  strings referenced by `meta` and `items`
#   meta         key/value pairs of strings: platform, invocation, environment
#   items        n_items x 32 B: name, file, line, throttle, hash, profile, exclusive, seed
#   statuses     n_items x 32 B, fixed stride, overwritten in place
#   memory       fixed 64 B block, rewritten in place whenever a peak is set
#   --- off_cold (planning / history with `full = false` stops reading here) ---
#   cold_strings strings referenced by `profiles`, `workers` and `policies`
#   profiles     name, julia args, threads, env, init, test_end, preferences path and content
#   environment  the test environment's Manifest.toml, zlib-compressed: its length,
#                the compressed length, then the compressed bytes
#   workers      each distinct environment the profiles' workers start in: project,
#                manifest (compressed, or the one above) and LocalPreferences.toml;
#                then each profile's, by index
#   policies     each distinct policy of an item as the run resolved it: timeout,
#                retries, failfast and skip; then each item's, by index
#   --- off_events ---
#   events       48 B each, appended: attempts, with what each measured, and worker
#                events of this record
#
# The initial file (everything up to `off_events`, with blank statuses and memory) is
# written to a sibling `.tmp` file and atomically renamed into place so a concurrent
# reader never observes a half-initialized file. After the run starts only the statuses,
# the memory block, the events and the header's ending/end_unix/closed fields are written,
# keeping a crash or concurrent reader from seeing shifted offsets; a reader drops a torn
# last event and sanitizes out-of-range status/memory fields.
#
# The manifest is most of a file's bytes, and only a replay reads it, so it is
# stored compressed and inflated only when asked for (`recorded_manifest`):
# planning a run does not decompress it.
#
# The file is `run.runstate` in the package record's own `<run>.rundata` directory
# (`new_runstate_path`), which also holds what the items printed,
# `item_<index>_<attempt>.log`, the failure report of each attempt that did not pass,
# `item_<index>_<attempt>.failure.txt`, what each attempt kept (`artifacts.jl`), and
# `setup.log` for a run that ended before its first item. The directory is made with
# the file and deleted only with it.

using CRC32c: crc32c
using Zlib_jll: libz

const RS_MAGIC = 0x544e5552   # "RUNT" on disk
const RS_VERSION = UInt32(1)
# 40 bytes of counts and times, then eleven section offsets; the rest is room to
# add a field without moving every section.
const RS_HEADER_BYTES = 96
const RS_STATUS_BYTES = 32
const RS_MEMORY_BYTES = 64
const RS_EVENT_BYTES = 48

const RS_FLAG_DRY_RUN = UInt32(1) << 1
# The header's `closed` byte. Writers before it left that byte 0, and so did the first
# that wrote it, until they closed the file: see `closed_file`.
const RS_CLOSED = 0x01
const RS_OPEN = 0x02

"""
    RunEnding

How a run ended, as the header of its run state records it. The coordinator writes it
as soon as it knows, before what it does to stop (`mark_ending!`), because what each
item was left in means something different under each: an item left running in a run
stopped by Ctrl-C did not fail, one left running in a run stopped as hung did.
`ENDING_NONE` is a run still going, or one whose coordinator died before it could say.
"""
@enum RunEnding::UInt8 begin
    ENDING_NONE = 0
    ENDING_FINISHED = 1       # every item it selected ran to a verdict
    ENDING_FAILFAST = 2       # stopped after a failure, under `failfast`
    ENDING_INTERRUPTED = 3    # stopped by an interrupt: Ctrl-C, or an item that threw one
    ENDING_STALLED = 4        # stopped as hung: no item finished for longer than one may take
    ENDING_EXITED = 5         # the process exited while the run went on
    ENDING_INIT_FAILED = 6    # a profile's `init` failed, as it would on every worker of it
    ENDING_START_FAILED = 7   # a worker could not be started
    ENDING_SETUP_FAILED = 8   # ended before its first item: its setup failed
    ENDING_ERRORED = 9        # stopped by an error of the run itself
end

# The words a run state's description gives an ending, indexed by `UInt8(ending)`.
const ENDING_WORDS = (
    "finished",
    "stopped after a failure (failfast)",
    "interrupted",
    "stopped as hung",
    "stopped as its process exited",
    "stopped: a profile's init failed",
    "stopped: a worker could not start",
    "ended before its first item",
    "stopped by an error of the run",
)
ending_word(e::RunEnding) = (i = Int(UInt8(e)); 1 <= i <= length(ENDING_WORDS) ? ENDING_WORDS[i] : "")

const EVENT_ATTEMPT = UInt8(1)       # an attempt at an item ended
const EVENT_WORKER_UP = UInt8(2)     # a worker process started
const EVENT_WORKER_DOWN = UInt8(3)   # a worker process ended

# Why a worker process ended, as `Worker.ended_by` names it; the index is what the
# file holds. `:connection_lost` and `:process_exit` mean it ended on its own.
const WORKER_ENDS = (
    :close, :timeout, :connection_lost, :process_exit, :memory_guard, :interrupt,
    :init_failed, :protocol_error, :output_error, :start_failed,
)
worker_end_code(by::Symbol) = UInt8(something(findfirst(==(by), WORKER_ENDS), 0))
worker_end(code::Integer) = 1 <= code <= length(WORKER_ENDS) ? WORKER_ENDS[code] : :unknown

# Write the fixed-layout record `ref` points at, whole; the record structs' layout
# is the file format. The caller refills one `Ref`, because `write(io, x)` of a
# number boxes it, and a run writes tens of thousands of fields.
@inline function write_record(io::IO, ref::Base.RefValue{T}) where {T}
    GC.@preserve ref unsafe_write(
        io, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, ref)), sizeof(T)
    )
    return nothing
end

function read_record(io::IO, ::Type{T}) where {T}
    ref = Ref{T}()
    GC.@preserve ref unsafe_read(io, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, ref)), sizeof(T))
    return ref[]
end

# zlib's one-call compression, at its default level: level 9 makes a manifest under
# 1% smaller and takes over half as long again.
function zlib_compress(data::Vector{UInt8})
    out = Vector{UInt8}(undef, ccall((:compressBound, libz), Culong, (Culong,), length(data)))
    n = Ref{Culong}(length(out))
    rc = ccall((:compress2, libz), Cint, (Ptr{UInt8}, Ref{Culong}, Ptr{UInt8}, Culong, Cint),
               out, n, data, length(data), 6)
    rc == 0 || error("zlib could not compress $(length(data)) bytes (error $rc)")
    return resize!(out, n[])
end

# `len` is the length `data` inflates to, as recorded beside it. deflate expands at
# most 1032-fold, so a length claiming more is garbled, and is refused before it
# sizes an allocation.
function zlib_uncompress(data::Vector{UInt8}, len::Integer)
    len <= 1032 * Int64(length(data)) || error("$(length(data)) compressed bytes cannot inflate to $len")
    out = Vector{UInt8}(undef, len)
    n = Ref{Culong}(len)
    rc = ccall((:uncompress, libz), Cint, (Ptr{UInt8}, Ref{Culong}, Ptr{UInt8}, Culong),
               out, n, data, length(data))
    (rc == 0 && n[] == len) || error("zlib could not inflate $(length(data)) bytes to $len (error $rc)")
    return out
end

# The header as it sits on disk: counts and times, then where each section starts.
# Explicit `pad` keeps `start_unix` 8-byte aligned with no uninitialized padding bytes.
# The ending, end time, and closed byte are rewritten in place as the run finishes.
struct Header
    magic::UInt32
    version::UInt32
    flags::UInt32
    n_items::UInt32
    n_profiles::UInt16
    ending::UInt8           # `RunEnding`; rewritten in place as the run learns how it ends
    closed::UInt8           # `RS_CLOSED` once the writer closed the file, after its last event and `end_unix`; `RS_OPEN` before
    pad::UInt32             # explicit zero
    start_unix::Float64
    end_unix::Float64
    off_strings::UInt32     # hot strings (`meta` + `items`)
    off_meta::UInt32
    off_items::UInt32
    off_status::UInt32
    off_memory::UInt32
    off_cold::UInt32        # cold strings (`profiles`, `workers`, `policies`); end of hot prefix
    off_profiles::UInt32
    off_environment::UInt32
    off_workers::UInt32
    off_policies::UInt32
    off_events::UInt32
end
@assert sizeof(Header) <= RS_HEADER_BYTES

header_offset(field::Symbol) = Int(fieldoffset(Header, Base.fieldindex(Header, field)))

# One item's place in the plan as it sits on disk (32 bytes, natural alignment).
struct ItemRecord
    name::UInt32
    file::UInt32
    line::UInt32
    throttle::UInt32
    hash::UInt32       # see `RawItem`
    profile::UInt16
    exclusive::UInt8
    pad::UInt8         # explicit zero
    seed::UInt64       # the seed the item's numbers came from, mixed with its name
end
@assert sizeof(ItemRecord) == 32

# Peak memory summary written in-place to the reserved `RS_MEMORY_BYTES` (64 B) block.
# Appending `peak_worker_mb` at byte 28 stays within the zero-padded 64 B block, so
# existing v1 files decode it cleanly as `0.0f0` without a format version bump.
struct MemoryRecord
    peak_total_mb::Float32
    peak_total_at::Float32
    peak_single_mb::Float32
    peak_single_pid::Int32
    setup_peak_mb::Float32
    test_peak_mb::Float32
    nprocs_peak::Int32
    peak_worker_mb::Float32   # largest single worker process tree during PHASE_TEST
end
@assert sizeof(MemoryRecord) == 32 && sizeof(MemoryRecord) <= RS_MEMORY_BYTES

const MemorySummary = @NamedTuple{
    peak_total_mb::Float32, peak_total_at::Float32, peak_single_mb::Float32,
    peak_single_pid::Int32, setup_peak_mb::Float32, test_peak_mb::Float32,
    nprocs_peak::Int32, peak_worker_mb::Float32
}
const ZERO_MEMORY = MemorySummary((0.0f0, 0.0f0, 0.0f0, Int32(0), 0.0f0, 0.0f0, Int32(0), 0.0f0))
memory_summary(r::MemoryRecord) = MemorySummary((
    recorded(r.peak_total_mb), recorded(r.peak_total_at), recorded(r.peak_single_mb), r.peak_single_pid,
    recorded(r.setup_peak_mb), recorded(r.test_peak_mb), r.nprocs_peak, recorded(r.peak_worker_mb)
))

# One item's status as it sits on disk. Every field lands on its natural alignment,
# so there is no padding.
struct StatusRecord
    state::UInt8
    attempt::Int8
    slot::Int16
    start_off::Float32
    elapsed::Float32
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32   # the worker process's largest resident size when the item ended
    pid::Int32             # the process the last attempt ran in, 0 for none
end
@assert sizeof(StatusRecord) == RS_STATUS_BYTES

# One event as it sits on disk, natural alignment throughout. For an attempt,
# `state` is its outcome and `item`/`attempt` say which; for a worker's end, `state`
# is why (`WORKER_ENDS`) and `exitcode`/`signal` how.
struct EventRecord
    kind::UInt8
    state::UInt8
    attempt::Int8
    reserved::UInt8
    slot::Int16
    seq::Int16    # for an attempt, where it came among its process's items: 1 for a fresh one, 0 unknown
    item::Int32
    pid::Int32
    t0::Float32   # seconds since the run started: when it began
    t1::Float32   # when it ended; for a worker's start, when its process was up
    exitcode::Int32
    signal::Int32
    # For an attempt, what it measured, as its status row holds the last attempt's:
    # a retry writes over the row, and the event keeps each attempt's.
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32
end
@assert sizeof(EventRecord) == RS_EVENT_BYTES

# One item policy as the run resolved it, the skip expression's text by its index in
# the strings.
struct PolicyRecord
    timeout_s::Int32
    skip::UInt32
    retries::Int8
    failfast::Int8
    pad::UInt16
end

struct RunStateFile
    io::IOStream
    path::String
    off_status::UInt32
    off_memory::UInt32
    n_items::UInt32
    lock::ReentrantLock
    # Refilled for every record written, so a run of thousands of them allocates
    # nothing. Only ever touched under `lock`.
    status_ref::Base.RefValue{StatusRecord}
    event_ref::Base.RefValue{EventRecord}
    memory_ref::Base.RefValue{MemoryRecord}
    # Keeps the file's modification time fresh while the run lasts; see `is_live`.
    heartbeat::Base.RefValue{Union{Nothing, Tuple{Timer, Task}}}
    # How the run ended, once it is known: the first reason given is the one kept.
    ending::Base.RefValue{RunEnding}
end

# How often a running run writes its file at the least, and how long a file goes
# unwritten before a reader takes the run that wrote it to have died. Three beats
# missed, so a busy machine's late beat is not a death.
const HEARTBEAT_S = 30.0
const LIVE_S = 90.0

### Writing ################################################################

struct StringTable
    index::Dict{String, UInt32}
    order::Vector{String}
end
StringTable() = StringTable(Dict{String, UInt32}(), String[])

# Not `get!` with a do-block: the closure allocates on every call, hits included,
# and a run interns two strings per item before it starts.
function intern!(t::StringTable, s::AbstractString)
    str = String(s)
    i = get(t.index, str, UInt32(0))
    i == 0 || return i
    push!(t.order, str)
    i = UInt32(length(t.order))
    t.index[str] = i
    return i
end

function write_strings(io::IO, t::StringTable)
    write(io, UInt32(length(t.order)))
    for s in t.order
        bytes = codeunits(s)
        write(io, UInt32(length(bytes)))
        write(io, bytes)
    end
    return nothing
end

read_text(path) = (path isa AbstractString && isfile(path)) ? read(path, String) : ""

# The seed as it is printed and passed back: a Julia literal, `runtests(seed = 0x…)`.
seed_text(seed::UInt64) = string("0x", string(seed; base = 16, pad = 16))

# Format a `RunConfig` setting from `REPLAY_SPECS` for `meta`.
function format_replay_setting(cfg::RunConfig, spec)
    val = getfield(cfg, spec.field)
    spec.key === :seed && return seed_text(val::UInt64)
    spec.replay === :csv && return join(val::Vector{String}, ',')
    return string(val)
end

# Variables a run's behaviour can depend on, and the ones that find the CI job it
# ran in. Anything that looks like a credential stays out: the file is meant to be
# passed around.
function environment_variables()
    keep(k) = startswith(k, "JULIA_") || startswith(k, "RUNTESTS_") || k == "CI" ||
        k in ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT",
              "GITHUB_WORKFLOW", "GITHUB_JOB", "RUNNER_OS", "RUNNER_ARCH")
    secret(k) = occursin(r"TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|KEY"i, k)
    return join((string(k, "=", v) for (k, v) in sort!(collect(ENV); by = first) if keep(k) && !secret(k)), '\n')
end

# Where the run ran, how it was asked for, and against which environment. The test
# environment is active by the time this is called, so its files are the ones the
# items resolved against.
function run_meta(p::Plan)
    cfg = p.cfg
    env = something(Base.active_project(), "")
    meta = Pair{String, String}[
        "julia" => string(VERSION), "julia_commit" => Base.GIT_VERSION_INFO.commit,
        # Runtests built into a system image has no directory of its own.
        "runtests" => string(pkgversion(@__MODULE__)),
        "runtests_revision" => (dir = pkgdir(@__MODULE__); dir === nothing ? "" : project_revision(dir)),
        "host" => run_host(), "machine" => Sys.MACHINE, "cpu_threads" => string(Sys.CPU_THREADS),
        # The process writing the file, and the machine by its own name: see `writer_gone`.
        "pid" => string(getpid()), "hostname" => machine_name(),
        "memory_bytes" => string(Sys.total_memory()),
        "coordinator_threads" => string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
        # How the workers compiled the items: this process's flags, which they inherit,
        # or a replay's.
        "julia_flags" => join(run_code_flags(cfg), " "),
        "environment_variables" => environment_variables(),
        "project_id" => project_id(p.root), "revision" => project_revision(p.root),
        "selection" => p.selection,
        "environment" => env, "environment_project" => read_text(env),
    ]
    for spec in SETTING_SPECS
        push!(meta, string(spec.key) => format_replay_setting(cfg, spec))
    end
    push!(meta, "order_first" => join(cfg.order_first, '\n'), "order_last" => join(cfg.order_last, '\n'))
    # Always written, empty for no `[throttle]`: a record without it predates throttles.
    push!(meta, "throttle" => join((string(n, '=', l) for (n, l) in sort!(collect(cfg.throttle); by = first)), '\n'))
    # The slots the plan made, which `idle_worker_seconds` counts against. A package's
    # part of a run of several packages has none (`package_plan`): the run's slots
    # served every package, and its record holds only the package's own attempts.
    nslots(p) == 0 || push!(meta, "slots" => string(nslots(p)))
    # Where each profile that a workspace shares ran its `init`, relative to the
    # package, which a replay finds again from wherever the package is then.
    dirs = unique!([string(prof.name, '\t', rel_slash(prof.dir, p.root)) for prof in p.profiles if !isempty(prof.dir)])
    isempty(dirs) || push!(meta, "profile_dirs" => join(dirs, '\n'))
    return meta
end

# The active environment's manifest, which the file keeps in a section of its own.
function environment_manifest()
    env = Base.active_project()
    return env === nothing ? "" : read_text(Base.project_file_manifest_path(env))
end

"""
    init_run_state(path, plan; dry_run=false, start=time(), meta=[], worker_projects=String[]) -> RunStateFile

Write everything that is known before the run starts, including a full status
section of `unseen` records, so that every later write is an overwrite at a
known offset. `start` is the moment every offset in the file counts from. `meta`
adds to what `run_meta` records. `worker_projects` names the project that the workers
of each of the plan's profiles start in, by its index, and the file keeps a snapshot of
it: empty, or past the end, for a profile that started no worker. Two environment
directories can each have a profile of the same name.
"""
function init_run_state(path::AbstractString, p::Plan; dry_run::Bool = false, start::Float64 = time(),
                        meta::Vector{Pair{String, String}} = Pair{String, String}[],
                        worker_projects::Vector{String} = String[],
                        heartbeat::Bool = true,
                        shared_env::Union{Nothing, Tuple{Vector{UInt8}, Vector{UInt8}}} = nothing)
    mkpath(dirname(path))
    hot_strings = StringTable()
    cold_strings = StringTable()
    # Two per item — its name and its file — plus metadata and throttle names.
    sizehint!(hot_strings.index, 2 * nitems(p) + 64)
    sizehint!(hot_strings.order, 2 * nitems(p) + 64)

    # Hot prefix sections: `meta` and `items` (followed on disk by `statuses` and `memory`).
    hot_body = IOBuffer()
    pairs_ = [run_meta(p); meta]
    write(hot_body, UInt32(length(pairs_)))
    for (k, v) in pairs_
        write(hot_body, intern!(hot_strings, k), intern!(hot_strings, v))
    end

    rel_items = UInt32(position(hot_body))
    write(hot_body, UInt32(nitems(p)))
    iref = Ref{ItemRecord}()
    for i in 1:nitems(p)
        iref[] = ItemRecord(
            intern!(hot_strings, p.items.name[i]), intern!(hot_strings, itemfile(p, i)),
            UInt32(p.items.line[i]), intern!(hot_strings, string(p.items.throttle[i])),
            p.items.hash[i], UInt16(p.items.profile[i]), UInt8(p.items.exclusive[i]), UInt8(0),
            p.items.seed[i]
        )
        write_record(hot_body, iref)
    end

    # Cold replay sections: `profiles`, `environment`, `workers`, `policies`.
    cold_body = IOBuffer()
    write(cold_body, UInt32(length(p.profiles)))
    for (j, prof) in enumerate(p.profiles)
        write(cold_body, intern!(cold_strings, string(prof.name)))
        write(cold_body, UInt32(length(prof.julia_args)))
        for a in prof.julia_args
            write(cold_body, intern!(cold_strings, a))
        end
        # As configured, empty for the run's: a replay asked for other threads gives
        # them to the profiles that take the run's.
        write(cold_body, intern!(cold_strings, p.packages.cfg[p.profile_package[j]].profiles[prof.name].threads))
        write(cold_body, UInt32(length(prof.env)))
        for (k, v) in prof.env
            write(cold_body, intern!(cold_strings, k))
            write(cold_body, intern!(cold_strings, v))
        end
        write(cold_body, intern!(cold_strings, expr_text(prof.init)))
        write(cold_body, intern!(cold_strings, expr_text(prof.test_end)))
        write(cold_body, intern!(cold_strings, prof.preferences))
        # The content too: the path is one on the machine that ran it.
        write(cold_body, intern!(cold_strings, read_text(prof.preferences)))
    end

    manifest, packed = if shared_env === nothing
        m = Vector{UInt8}(environment_manifest())
        (m, isempty(m) ? UInt8[] : zlib_compress(m))
    else
        shared_env
    end
    rel_environment = UInt32(position(cold_body))
    write(cold_body, UInt32(length(manifest)), UInt32(length(packed)), packed)

    rel_workers = UInt32(position(cold_body))
    write_workers!(cold_body, cold_strings, p, worker_projects, manifest)

    rel_policies = UInt32(position(cold_body))
    write_policies!(cold_body, cold_strings, p)

    hot_strbuf = IOBuffer()
    write_strings(hot_strbuf, hot_strings)
    cold_strbuf = IOBuffer()
    write_strings(cold_strbuf, cold_strings)

    off_strings     = UInt32(RS_HEADER_BYTES)
    off_meta        = off_strings + UInt32(hot_strbuf.size)
    off_items       = off_meta + rel_items
    off_status      = off_meta + UInt32(hot_body.size)
    off_memory      = off_status + UInt32(RS_STATUS_BYTES * nitems(p))
    off_cold        = off_memory + UInt32(RS_MEMORY_BYTES)
    off_profiles    = off_cold + UInt32(cold_strbuf.size)
    off_environment = off_profiles + rel_environment
    off_workers     = off_profiles + rel_workers
    off_policies    = off_profiles + rel_policies
    off_events      = off_profiles + UInt32(cold_body.size)

    # Stage the entire initial file in a sibling temp file and atomically rename into
    # place so a concurrent reader never sees a partially-written header or sections.
    tmp = string(path, ".tmp")
    try
        open(tmp, "w") do io
            write_record(io, Ref(Header(
                RS_MAGIC, RS_VERSION, dry_run ? RS_FLAG_DRY_RUN : UInt32(0), UInt32(nitems(p)),
                UInt16(length(p.profiles)), UInt8(ENDING_NONE), RS_OPEN, UInt32(0), start, 0.0,
                off_strings, off_meta, off_items, off_status, off_memory,
                off_cold, off_profiles, off_environment, off_workers, off_policies, off_events
            )))
            write(io, zeros(UInt8, RS_HEADER_BYTES - sizeof(Header)))
            write(io, take!(hot_strbuf))
            write(io, take!(hot_body))
            # `UInt8(UNSEEN) == 0`, so blank statuses and memory are a single zero block.
            write(io, zeros(UInt8, RS_STATUS_BYTES * nitems(p) + RS_MEMORY_BYTES))
            write(io, take!(cold_strbuf))
            write(io, take!(cold_body))
            flush(io)
        end
        mv(tmp, path; force = true)
    catch
        rm(tmp; force = true)
        rethrow()
    end
    io = open(path, "r+")
    rsf = RunStateFile(
        io, String(path), off_status, off_memory, UInt32(nitems(p)),
        ReentrantLock(), Ref{StatusRecord}(), Ref{EventRecord}(), Ref{MemoryRecord}(),
        Ref{Union{Nothing, Tuple{Timer, Task}}}(nothing), Ref(ENDING_NONE)
    )
    heartbeat && (rsf.heartbeat[] = start_heartbeat(rsf))
    return rsf
end

# Each distinct environment that the profiles' workers start in (`worker_projects`, by
# the plan's profile index): its project, its manifest, compressed, and its `LocalPreferences.toml`; then
# each profile's, by index from 1, 0 for one without a project. A manifest that is the
# run's own (`run_manifest`) is not stored twice: its length is written as `typemax`.
function write_workers!(io::IO, strings::StringTable, p::Plan, worker_projects::Vector{String},
                        run_manifest::Vector{UInt8})
    snapshots = Tuple{String, Vector{UInt8}, String}[]
    index = UInt32[]
    for j in eachindex(p.profiles)
        project = get(worker_projects, j, "")
        file = isempty(project) ? nothing : isdir(project) ? project_file(project) : String(project)
        if file === nothing || !isfile(file)
            push!(index, UInt32(0))
            continue
        end
        manifest = Base.project_file_manifest_path(file)
        snapshot = (read_text(file), Vector{UInt8}(read_text(manifest)), read_text(joinpath(dirname(file), "LocalPreferences.toml")))
        k = findfirst(==(snapshot), snapshots)
        k === nothing && (push!(snapshots, snapshot); k = length(snapshots))
        push!(index, UInt32(k))
    end
    write(io, UInt32(length(snapshots)))
    for (project, manifest, preferences) in snapshots
        write(io, intern!(strings, project), intern!(strings, preferences))
        if !isempty(manifest) && manifest == run_manifest
            write(io, typemax(UInt32), UInt32(0))
        else
            packed = isempty(manifest) ? UInt8[] : zlib_compress(manifest)
            write(io, UInt32(length(manifest)), UInt32(length(packed)), packed)
        end
    end
    write(io, UInt32(length(index)))
    write(io, index)
    return nothing
end

# Each item's policy as the run resolved it: its timeout in seconds, its retries, whether
# a failure stops the item at its first failing test (`item_failfast`), and its skip
# expression, each distinct one once; then each item's, by index from 1.
function write_policies!(io::IO, strings::StringTable, p::Plan)
    table = Dict{PolicyRecord, UInt32}()
    order = PolicyRecord[]
    index = Vector{UInt32}(undef, nitems(p))
    for i in 1:nitems(p)
        skip = p.items.skip[i]
        r = PolicyRecord(Int32(item_timeout(p, ItemIdx(i))), intern!(strings, skip isa Expr ? expr_text(skip) : string(skip)),
                         Int8(attempts_for(p, i) - 1), Int8(item_failfast(p, i)), UInt16(0))
        id = get(table, r, UInt32(0))
        if id == 0
            push!(order, r)
            id = UInt32(length(order))
            table[r] = id
        end
        index[i] = id
    end
    write(io, UInt32(length(order)))
    write(io, order)
    write(io, UInt32(length(index)))
    write(io, index)
    return nothing
end

# While the run lasts, its file is written at least every `HEARTBEAT_S`: the magic
# number, rewritten in place with the value it has, so that a beat changes no byte,
# and one landing in a file a pruner deleted harms nothing. Its own task, on any
# thread: an item that runs in this process (`workers = 0`) without yielding would
# starve a beat on the run's own thread, and the run would look dead to other
# processes. It writes under the file's lock, and hands on an interrupt it catches,
# as the stall watchdog does.
function start_heartbeat(rsf::RunStateFile)
    timer = Timer(HEARTBEAT_S; interval = HEARTBEAT_S)
    task = shielded(() -> Threads.@spawn beat(rsf, timer))
    return (timer, task)
end

function beat(rsf::RunStateFile, timer::Timer)
    while true
        try
            wait(timer)
            # Closed with its timer left running: the exit hook's way of ending a run.
            isopen(rsf.io) || break
            update!(io -> write(io, RS_MAGIC), rsf, 0)
        catch e
            e isa EOFError && break   # closed: the run is over
            is_interrupt(e) || break
            RuntestsWorkers.forward_interrupt(e)
        end
    end
    return nothing
end

function write_status_record(
        io::IO, ref::Base.RefValue{StatusRecord}, state::ItemState, attempt::Int8,
        slot::SlotIdx, start_off, elapsed, compile, recompile, alloc_mb, peak_rss_mb, pid
    )
    ref[] = StatusRecord(
        UInt8(state), attempt, Int16(slot), Float32(start_off), Float32(elapsed),
        Float32(compile), Float32(recompile), Float32(alloc_mb), Float32(peak_rss_mb),
        Int32(pid)
    )
    write_record(io, ref)
    return nothing
end

# Every write after the header: in place (at the end, for `at < 0`), under the lock,
# flushed, and never a reason to fail the run — the tests matter more than the
# record of them. A crash loses at most the record being written, and a reader
# treats a record it cannot make sense of as `unseen`. Nothing under the lock waits,
# so no task the exit hook stops holds it, and the hook can take it. The warning, which
# can wait, is said after the lock is let go.
function update!(f, rsf::Union{Nothing, RunStateFile}, at::Integer)
    rsf === nothing && return nothing
    failure = @lock rsf.lock try
        # Closed means the run is over; a worker that exits after that has nothing
        # left to add to it.
        isopen(rsf.io) || return nothing
        at < 0 ? seekend(rsf.io) : seek(rsf.io, at)
        f(rsf.io)
        flush(rsf.io)
        nothing
    catch e
        is_interrupt(e) && rethrow()
        e
    end
    failure === nothing || @warn "Runtests: could not write the run state" exception = failure maxlog = 1
    return nothing
end

function write_status!(
        rsf::Union{Nothing, RunStateFile}, i::Integer, state::ItemState,
        attempt::Integer, slot::Integer; start_off = 0.0, elapsed = 0.0,
        compile = 0.0, recompile = 0.0, alloc_mb = 0.0, peak_rss_mb = 0.0, pid = 0
    )
    (rsf === nothing || !(1 <= i <= rsf.n_items)) && return nothing
    update!(rsf, Int(rsf.off_status) + (Int(i) - 1) * RS_STATUS_BYTES) do io
        write_status_record(
            io, rsf.status_ref, state, Int8(attempt), SlotIdx(slot), start_off,
            elapsed, compile, recompile, alloc_mb, peak_rss_mb, pid
        )
    end
end

function append_event!(
        rsf::Union{Nothing, RunStateFile}, kind::UInt8, state::Integer, slot::Integer, pid::Integer,
        t0::Real, t1::Real; item::Integer = 0, attempt::Integer = 0, exitcode::Integer = 0, signal::Integer = 0,
        seq::Integer = 0, compile::Real = 0, recompile::Real = 0, alloc_mb::Real = 0, peak_rss_mb::Real = 0
    )
    update!(rsf, -1) do io
        rsf.event_ref[] = EventRecord(
            kind, UInt8(state), Int8(attempt), 0x00, Int16(slot), Int16(seq), Int32(item), Int32(pid),
            Float32(t0), Float32(t1), Int32(exitcode), Int32(signal), Float32(compile), Float32(recompile),
            Float32(alloc_mb), Float32(peak_rss_mb)
        )
        write_record(io, rsf.event_ref)
    end
end

function write_memory!(rsf::Union{Nothing, RunStateFile}, m)
    rsf === nothing && return nothing
    update!(rsf, rsf.off_memory) do io
        rsf.memory_ref[] = MemoryRecord(
            Float32(m.peak_total_bytes / 2^20), Float32(m.peak_total_at), Float32(m.peak_single_bytes / 2^20),
            Int32(m.peak_single_pid), Float32(phase_peak(m, PHASE_SETUP) / 2^20),
            Float32(phase_peak(m, PHASE_TEST) / 2^20), Int32(m.nprocs_peak),
            Float32(m.peak_worker_bytes / 2^20)
        )
        write_record(io, rsf.memory_ref)
    end
end

"""
    mark_ending!(rsf, ending)

Say how the run ended, the first time it is said, written through. Called as soon as
the run knows, before it stops its workers or records what they were running: the
ending alone says what each item left running or unseen means, which is
more than any one item's record does.
"""
function mark_ending!(rsf::Union{Nothing, RunStateFile}, ending::RunEnding)
    rsf === nothing && return nothing
    first = @lock rsf.lock (rsf.ending[] === ENDING_NONE ? (rsf.ending[] = ending; true) : false)
    first || return nothing
    update!(io -> write(io, UInt8(ending)), rsf, header_offset(:ending))
    return nothing
end

# The run is over: its ending said, if nothing said it before (`mark_ending!`), its end
# time and then that it is closed written through, and the file closed. A stopped run's
# workers can write for seconds after its ending is said, and until then the file is
# live (`is_live`). `exiting`, from the exit hook, which waits neither on a task nor on
# the event loop: there the beat's timer is left running, since closing a timer waits
# for the event loop to close it, and the beat ends at its next tick, finding the file
# closed. Stopped and waited for otherwise, so that nothing is written once this returns.
function finish_run_state!(rsf::Union{Nothing, RunStateFile}, ending::RunEnding = ENDING_FINISHED; exiting::Bool = false)
    rsf === nothing && return nothing
    beating = rsf.heartbeat[]
    if beating !== nothing
        rsf.heartbeat[] = nothing
        exiting || (close(first(beating)); wait(last(beating)))
    end
    failure = @lock rsf.lock try
        if isopen(rsf.io)
            if rsf.ending[] === ENDING_NONE
                rsf.ending[] = ending
                seek(rsf.io, header_offset(:ending)); write(rsf.io, UInt8(ending)); flush(rsf.io)
            end
            seek(rsf.io, header_offset(:end_unix)); write(rsf.io, time()); flush(rsf.io)
            seek(rsf.io, header_offset(:closed)); write(rsf.io, RS_CLOSED); flush(rsf.io)
            close(rsf.io)
        end
        nothing
    catch e
        is_interrupt(e) && rethrow()
        e
    end
    failure === nothing || @warn "Runtests: could not write the run state" exception = failure maxlog = 1
    return nothing
end

### Reading ################################################################

# Whether the writer closed the file. A 0, from a writer before the `closed` byte or one
# that left it open, counts as closed where the file says the run finished: those
# writers said so only as they closed it. A run they stopped is not known to be over
# until its heartbeat and its writer say so (`is_live`).
closed_file(h::Header, ending::RunEnding) =
    h.closed == RS_CLOSED || (h.closed == 0x00 && ending === ENDING_FINISHED && h.end_unix > 0)

struct RunStateItem
    name::String
    file::String
    line::Int32
    profile::Int32
    exclusive::Bool
    throttle::Symbol
    hash::UInt32   # 0 when not recorded
    seed::UInt64
end

struct RunStateStatus
    state::ItemState
    attempt::Int8
    slot::Int16
    start_off::Float32
    elapsed::Float32
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32
    pid::Int32
end

"""
    RunStateEvent

One thing that happened during a run, in the order it happened: `kind` is
`:attempt` (an attempt at `item` ended in `state`; `seq` is where it came among the
items its process ran, 1 for a fresh process and 0 when not recorded), `:worker_up`
or `:worker_down` (the process `pid` of `slot` started or ended; `ended_by`,
`exitcode` and `signal` say why and how). Times are seconds since the run started;
a worker's start runs from launching its process to the process being up.
"""
struct RunStateEvent
    kind::Symbol
    state::ItemState
    ended_by::Symbol
    attempt::Int8
    seq::Int16
    slot::Int16
    item::Int32
    pid::Int32
    t0::Float32
    t1::Float32
    exitcode::Int32
    signal::Int32
    # What an attempt measured.
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32
end

# An environment that a profile's workers started in, as the run recorded it.
struct WorkerEnvironment
    project::String
    manifest_bytes::Int                 # the manifest's length, inflated
    manifest_zlib::Vector{UInt8}
    preferences::String                 # its LocalPreferences.toml
end

# An item's policy as the run resolved it.
struct ItemPolicy
    timeout_s::Int32
    retries::Int8
    failfast::Bool
    skip::String
end

struct RunStateRecord
    path::String
    version::UInt32
    complete::Bool      # its ending is said: `ending` is not `ENDING_NONE`
    closed::Bool        # its writer closed it: nothing more comes, and `end_unix` is its end
    dry_run::Bool
    cancelled::Bool     # stopped before every item it selected ran: failfast, an interrupt and the like
    aborted::Bool       # ended before its first item: `ENDING_SETUP_FAILED`
    ending::RunEnding
    start_unix::Float64
    end_unix::Float64
    meta::Dict{String, String}
    profiles::Dict{Symbol, Profile}
    preferences::Dict{Symbol, String}   # profile name => its preferences file's content, as recorded
    manifest_bytes::Int                 # the recorded manifest's length, inflated
    manifest_zlib::Vector{UInt8}        # the manifest as stored; see `recorded_manifest`
    items::Vector{RunStateItem}
    statuses::Vector{RunStateStatus}
    memory::MemorySummary
    events::Vector{RunStateEvent}
    # Each distinct environment of the profiles' workers, each profile's index into them
    # (0 for none), and each item's policy.
    worker_environments::Vector{WorkerEnvironment}
    profile_environments::Vector{Int}
    policies::Vector{ItemPolicy}
    truncated::Bool
    mtime::Float64      # when the file was last written, as it was read; see `is_live`
end

# Lightweight header + metadata view for callers that only inspect `meta`/`closed`/`mtime`
# (`gone_checkout`, `exported_siblings`, `findfirst_record`), avoiding reading the rest of the file.
struct RunStateMeta
    path::String
    closed::Bool
    ending::RunEnding
    start_unix::Float64
    meta::Dict{String, String}
    mtime::Float64
end

"""
    idle_worker_seconds(rs) -> Union{Nothing, Float64}

The seconds that the run's planned slots spent without a running item, from the
start of its first attempt to its end: the slots times that span, less the time its
attempts ran. A worker's start, a slot that waits for work and one that stopped
early all count. `nothing` for a record without its number of slots, which a package's
record of a run of several packages is, or without an attempt, and for one still being
written, whose end is not known.
"""
function idle_worker_seconds(rs::RunStateRecord)
    slots = tryparse(Int, get(rs.meta, "slots", ""))
    (slots === nothing || !rs.closed || rs.end_unix <= rs.start_unix) && return nothing
    first_t0 = Inf32
    busy = 0.0
    any_attempt = false
    for e in rs.events
        e.kind === :attempt || continue
        any_attempt = true
        e.t0 < first_t0 && (first_t0 = e.t0)
        busy += Float64(e.t1 - e.t0)
    end
    any_attempt || return nothing
    span = (rs.end_unix - rs.start_unix) - first_t0
    return max(0.0, slots * span - busy)
end

"""
    is_live(rs; now = time()) -> Bool

Whether the run that wrote `rs` is still going, as far as its file can say: its writer
has not closed it, which a stopped run's does only once its workers are done with it,
its file was written in the last `LIVE_S` seconds, which a running one's always is
(`start_heartbeat`), and the process that wrote it is not known to be gone
(`writer_gone`). Another process's run state can be read part
way through. A live one's verdicts are not in yet, and an item it holds as `running`
is being run, not one a run left so when it died; its finished items' durations are
as good as any.
"""
is_live(rs::Union{RunStateRecord, RunStateMeta}; now::Real = time()) =
    !rs.closed && now - rs.mtime < LIVE_S && !writer_gone(rs)

# Whether the process that wrote `rs` is known to have exited, so that a run killed a
# moment ago counts as over at once rather than `LIVE_S` later: it ran on this
# machine, by its own hostname, not `RUNTESTS_HOST`, which names one machine across
# the CI runners that take turns being it and whose pids mean nothing here, and its
# pid is free. A pid another process has taken since says nothing either way.
function writer_gone(rs::Union{RunStateRecord, RunStateMeta})
    h = get(rs.meta, "hostname", "")
    (h == machine_name() || h == gethostname()) || return false
    pid = tryparse(Int32, get(rs.meta, "pid", ""))
    pid === nothing && return false
    return ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == Base.UV_ESRCH
end

# Header section offsets must be monotonic from the end of the fixed header.
function valid_header_offsets(h::Header)
    return RS_HEADER_BYTES <= h.off_strings <= h.off_meta <= h.off_items <=
        h.off_status <= h.off_memory <= h.off_cold <= h.off_profiles <=
        h.off_environment <= h.off_workers <= h.off_policies <= h.off_events
end

# Read `n` bytes after the header already copied into `hdr`, returning a single buffer
# covering `[0 .. RS_HEADER_BYTES + nread)`.
function read_prefix(io::IO, hdr::Vector{UInt8}, limit::Int)
    limit <= RS_HEADER_BYTES && return hdr
    buf = Vector{UInt8}(undef, limit)
    copyto!(buf, 1, hdr, 1, RS_HEADER_BYTES)
    nread = readbytes!(io, view(buf, (RS_HEADER_BYTES + 1):limit), limit - RS_HEADER_BYTES)
    nread == limit - RS_HEADER_BYTES || resize!(buf, RS_HEADER_BYTES + nread)
    return buf
end

function load_run_meta(rp::String)
    return open(rp) do io
        written = stat(io).mtime
        hdr = read(io, RS_HEADER_BYTES)
        length(hdr) == RS_HEADER_BYTES || return nothing
        h = read_record(IOBuffer(hdr), Header)
        (h.magic == RS_MAGIC && h.version == RS_VERSION && valid_header_offsets(h)) || return nothing
        limit = min(Int(h.off_items), Int(filesize(io)))
        return read_prefix(io, hdr, limit), h, written
    end
end

function load_run_state(rp::String, full::Bool)
    return open(rp) do io
        written = stat(io).mtime
        hdr = read(io, RS_HEADER_BYTES)
        length(hdr) == RS_HEADER_BYTES || return nothing
        h = read_record(IOBuffer(hdr), Header)
        (h.magic == RS_MAGIC && h.version == RS_VERSION && valid_header_offsets(h)) || return nothing
        fsize = Int(filesize(io))
        if full
            bytes = read_prefix(io, hdr, fsize)
            # A live writer may have appended events after `filesize` was queried.
            eof(io) || append!(bytes, read(io))
            return rp, h, written, bytes, bytes, Int(h.off_events), fsize
        else
            # Hot prefix only `[0 .. off_cold)`, skipping all cold replay sections on disk.
            hot_limit = min(Int(h.off_cold), fsize)
            hot_bytes = read_prefix(io, hdr, hot_limit)
            ev_bytes = if Int(h.off_events) <= fsize
                seek(io, Int(h.off_events))
                ev_n = fsize - Int(h.off_events)
                buf = Vector{UInt8}(undef, ev_n)
                nread = ev_n > 0 ? readbytes!(io, buf, ev_n) : 0
                nread == ev_n || resize!(buf, nread)
                eof(io) || append!(buf, read(io))
                buf
            else
                UInt8[]
            end
            return rp, h, written, hot_bytes, ev_bytes, 0, fsize
        end
    end
end

# Read only the header, hot string table and `meta` section of a run state file
# (skipping items, statuses, memory, cold replay sections and events).
function read_run_meta(path::AbstractString)
    try
        rp = record_path(path)
        got = load_run_meta(rp)
        got === nothing && return nothing
        bytes, h, written = got
        io = IOBuffer(bytes)
        total = length(bytes)
        Int(h.off_strings) <= total && Int(h.off_meta) <= total || return nothing
        seek(io, Int(h.off_strings))
        strings = read_strings(io, bytes)
        seek(io, Int(h.off_meta))
        meta = Dict{String, String}()
        for _ in 1:bounded(read(io, UInt32), total)
            k = lookup(strings, read(io, UInt32))
            meta[k] = lookup(strings, read(io, UInt32))
        end
        ending = h.ending <= UInt8(typemax(RunEnding)) ? RunEnding(h.ending) : ENDING_NONE
        return RunStateMeta(String(rp), closed_file(h, ending), ending, h.start_unix, meta, written)
    catch e
        is_interrupt(e) && rethrow()
        return nothing
    end
end

"""
    read_run_state(path; full = true) -> Union{Nothing,RunStateRecord}

Read a run state: a run's directory, `<run>.rundata`, or the `run.runstate` file in
it. A file that is truncated or from a crashed run gives as much as can be read, or
`nothing`; a file written by a different format version returns `nothing`. The reader
suppresses ordinary read and parse errors so a broken old record does not stop a new
run, and a record that another run deletes while it reads gives `nothing`. An interrupt
during parsing is rethrown. With `full = false`, reads only the planning prefix (including
`memory`) and appended events, leaving `profiles`, `preferences`, `manifest_zlib`,
`worker_environments`, `profile_environments`, and `policies` empty.
"""
function read_run_state(path::AbstractString; full::Bool = true)
    # Another run prunes records at any moment. On Windows a file that is being deleted
    # can refuse even `stat` until every process has closed it, so the look at the path
    # and the read can fail alike. Using `stat(io).mtime` on the open descriptor avoids
    # a second path lookup racing with deletion.
    loaded = try
        load_run_state(record_path(path), full)
    catch e
        is_interrupt(e) && rethrow()
        return nothing
    end
    loaded === nothing && return nothing
    rp, h, written, hot_bytes, ev_bytes, ev_off, fsize = loaded
    hot_total = length(hot_bytes)
    io = IOBuffer(hot_bytes)
    try
        n_items = bounded(h.n_items, max(hot_total, fsize))

        Int(h.off_strings) <= hot_total && Int(h.off_meta) <= hot_total || return nothing
        seek(io, Int(h.off_strings))
        hot_strings = read_strings(io, hot_bytes)
        seek(io, Int(h.off_meta))
        meta = Dict{String, String}()
        for _ in 1:bounded(read(io, UInt32), hot_total)
            k = lookup(hot_strings, read(io, UInt32))
            meta[k] = lookup(hot_strings, read(io, UInt32))
        end

        Int(h.off_items) <= hot_total || return nothing
        seek(io, Int(h.off_items))
        n_rec = min(bounded(read(io, UInt32), hot_total), n_items)
        items = Vector{RunStateItem}(undef, n_rec)
        # Fast cache for the common case where every item shares one throttle (usually `NO_THROTTLE`).
        last_th_id = UInt32(0)
        last_th_sym = NO_THROTTLE
        throttles = nothing
        for idx in 1:n_rec
            r = read_record(io, ItemRecord)
            throttle = if r.throttle == last_th_id && idx > 1
                last_th_sym
            elseif throttles === nothing
                sym = Symbol(lookup(hot_strings, r.throttle))
                if idx == 1
                    last_th_id = r.throttle
                    last_th_sym = sym
                else
                    throttles = Dict{UInt32, Symbol}(last_th_id => last_th_sym, r.throttle => sym)
                    last_th_id = r.throttle
                    last_th_sym = sym
                end
                sym
            else
                sym = get(throttles, r.throttle, nothing)
                sym === nothing && (sym = throttles[r.throttle] = Symbol(lookup(hot_strings, r.throttle)))
                last_th_id = r.throttle
                last_th_sym = sym
                sym
            end
            items[idx] = RunStateItem(lookup(hot_strings, r.name), lookup(hot_strings, r.file), Int32(r.line),
                                      Int32(r.profile), r.exclusive != 0, throttle, r.hash, r.seed)
        end

        truncated = false
        statuses = Vector{RunStateStatus}(undef, n_items)
        off_st = Int(h.off_status)
        avail_st = off_st <= hot_total ? min(n_items, (hot_total - off_st) ÷ RS_STATUS_BYTES) : 0
        if avail_st > 0
            seek(io, off_st)
            for i in 1:avail_st
                statuses[i] = read_status_record(io)
            end
        end
        if avail_st < n_items
            truncated = true
            blank_st = RunStateStatus(UNSEEN, Int8(0), Int16(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, Int32(0))
            for i in (avail_st + 1):n_items
                statuses[i] = blank_st
            end
        end

        memory = ZERO_MEMORY
        if Int(h.off_memory) + sizeof(MemoryRecord) <= hot_total
            seek(io, Int(h.off_memory))
            memory = memory_summary(read_record(io, MemoryRecord))
        elseif full
            truncated = true
        end

        profiles = Dict{Symbol, Profile}()
        preferences = Dict{Symbol, String}()
        manifest_bytes = 0
        manifest_zlib = UInt8[]
        worker_environments = WorkerEnvironment[]
        profile_environments = Int[]
        policies = ItemPolicy[]

        if full
            # A file cut short in the cold replay sections still gives the complete hot prefix.
            try
                Int(h.off_cold) <= hot_total || throw(EOFError())
                seek(io, Int(h.off_cold))
                cold_strings = read_strings(io, hot_bytes)
                Int(h.off_profiles) <= hot_total || throw(EOFError())
                seek(io, Int(h.off_profiles))
                profiles, preferences = read_profiles_section(io, cold_strings)

                Int(h.off_environment) <= hot_total || throw(EOFError())
                seek(io, Int(h.off_environment))
                manifest_bytes = Int(read(io, UInt32))
                manifest_zlib = read(io, bounded(read(io, UInt32), hot_total))

                Int(h.off_workers) <= hot_total || throw(EOFError())
                worker_environments, profile_environments = read_workers_section(
                    seek(io, Int(h.off_workers)), cold_strings, hot_total, manifest_bytes, manifest_zlib
                )
                Int(h.off_policies) <= hot_total || throw(EOFError())
                policies = read_policies_section(seek(io, Int(h.off_policies)), cold_strings, hot_total)
            catch e
                e isa EOFError || rethrow()
                truncated = true
            end
        else
            fsize < Int(h.off_events) && (truncated = true)
        end

        ev_total = length(ev_bytes)
        n_ev = ev_off <= ev_total ? (ev_total - ev_off) ÷ RS_EVENT_BYTES : 0
        events = Vector{RunStateEvent}(undef, n_ev)
        if n_ev > 0
            ev_io = full ? io : IOBuffer(ev_bytes)
            seek(ev_io, ev_off)
            for i in 1:n_ev
                e = read_record(ev_io, EventRecord)
                kind = e.kind == EVENT_ATTEMPT ? :attempt : e.kind == EVENT_WORKER_UP ? :worker_up :
                    e.kind == EVENT_WORKER_DOWN ? :worker_down : :unknown
                state = kind === :attempt && e.state <= UInt8(CANCELLED) ? ItemState(e.state) : UNSEEN
                ended_by = kind === :worker_down ? worker_end(e.state) : :none
                events[i] = RunStateEvent(kind, state, ended_by, e.attempt, e.seq, e.slot, e.item, e.pid, e.t0, e.t1,
                                          e.exitcode, e.signal, recorded(e.compile), recorded(e.recompile),
                                          recorded(e.alloc_mb), recorded(e.peak_rss_mb))
            end
        end
        # Part of an event, which a writer stopped while appending it left.
        ev_off + n_ev * RS_EVENT_BYTES < ev_total && (truncated = true)
        # A verdict whose attempt has no event of the same outcome: the writer stopped
        # between the two writes of a completion. The verdict is kept, and the evidence
        # for it said to be incomplete.
        full && (truncated |= !verdicts_have_events(statuses, events))
        ending = h.ending <= UInt8(typemax(RunEnding)) ? RunEnding(h.ending) : ENDING_NONE
        return RunStateRecord(
            String(rp), h.version, ending !== ENDING_NONE, closed_file(h, ending), h.flags & RS_FLAG_DRY_RUN != 0,
            !(ending in (ENDING_NONE, ENDING_FINISHED, ENDING_SETUP_FAILED)), ending === ENDING_SETUP_FAILED, ending,
            h.start_unix, h.end_unix, meta, profiles, preferences, manifest_bytes, manifest_zlib,
            items, statuses, memory, events, worker_environments, profile_environments, policies,
            truncated, written
        )
    catch e
        is_interrupt(e) && rethrow()
        # Any exception, not a list of expected ones: the caller has a run to finish
        # and no use for a file it cannot read. Reader bugs still surface, because
        # the round-trip tests assert on what a written file reads back as.
        # `JULIA_DEBUG=Runtests` shows what went wrong.
        @debug "Runtests: could not read run state $(rp)" exception = (e, catch_backtrace())
        return nothing
    end
end

# The workers section at `io`'s position (`write_workers!`). A manifest written as the
# run's own takes the environment section's.
function read_workers_section(io::IO, strings, total::Integer, run_bytes::Int, run_zlib::Vector{UInt8})
    envs = map(1:bounded(read(io, UInt32), total)) do _
        project, preferences = lookup(strings, read(io, UInt32)), lookup(strings, read(io, UInt32))
        len = read(io, UInt32)
        packed = read(io, bounded(read(io, UInt32), total))
        len == typemax(UInt32) ? WorkerEnvironment(project, run_bytes, run_zlib, preferences) :
            WorkerEnvironment(project, Int(len), packed, preferences)
    end
    index = Int[Int(read(io, UInt32)) for _ in 1:bounded(read(io, UInt32), total)]
    return envs, index
end

# The policies section at `io`'s position (`write_policies!`): each item's policy.
function read_policies_section(io::IO, strings, total::Integer)
    table = map(1:bounded(read(io, UInt32), total)) do _
        r = read_record(io, PolicyRecord)
        ItemPolicy(r.timeout_s, r.retries, r.failfast != 0, lookup(strings, r.skip))
    end
    n = bounded(read(io, UInt32), total)
    out = sizehint!(ItemPolicy[], n)
    for _ in 1:n
        idx = read(io, UInt32)
        1 <= idx <= length(table) ? push!(out, table[idx]) : throw(EOFError())
    end
    return out
end

function inflate_manifest(zlib::Vector{UInt8}, bytes::Int, label::AbstractString = "")
    bytes == 0 && return ""
    try
        return String(zlib_uncompress(zlib, bytes))
    catch e
        is_interrupt(e) && rethrow()
        isempty(label) || @debug "Runtests: the manifest recorded in $(label) is unreadable" exception = e
        return ""
    end
end

# The manifest of a recorded worker environment, as `recorded_manifest` gives the run's.
recorded_manifest(env::WorkerEnvironment) = inflate_manifest(env.manifest_zlib, env.manifest_bytes)

# Whether every item's recorded verdict has the event of its attempt with that outcome.
# One pass over the events marks each item whose row has its event; an event of no
# item the file has is no item's.
function verdicts_have_events(statuses::Vector{RunStateStatus}, events::Vector{RunStateEvent})
    matched = falses(length(statuses))
    for e in events
        (e.kind === :attempt && checkbounds(Bool, statuses, e.item)) || continue
        st = statuses[e.item]
        st.attempt == e.attempt && st.state === e.state && (matched[e.item] = true)
    end
    for (i, st) in pairs(statuses)
        (st.state === UNSEEN || st.state === RUNNING) && continue
        matched[i] || return false
    end
    return true
end

"""
    recorded_manifest(rs) -> String

The test environment's `Manifest.toml` as the run recorded it: `""` when it
recorded none, or when the stored copy does not inflate to what it should.
"""
recorded_manifest(rs::RunStateRecord) = inflate_manifest(rs.manifest_zlib, rs.manifest_bytes, rs.path)

function read_status_record(io::IO)
    r = read_record(io, StatusRecord)
    return RunStateStatus(
        r.state <= UInt8(CANCELLED) ? ItemState(r.state) : UNSEEN, r.attempt, r.slot,
        recorded(r.start_off), recorded(r.elapsed), recorded(r.compile), recorded(r.recompile),
        recorded(r.alloc_mb), recorded(r.peak_rss_mb), r.pid
    )
end

# A time or a size as recorded, or 0 for one that no write made: a record read while
# its run writes it can be torn, and one a crash cut short can read as zeros or as
# garbage, which as a duration would be the planner's.
recorded(x::Float32) = isfinite(x) && x >= 0 ? x : 0.0f0

"""
    bounded(n, limit) -> Int

A count read out of a file, capped at what the file could hold: every record takes
at least a byte. Uncapped, a garbled count sizes an allocation, and a loop that only
pushes, or a comprehension sized up front, does not stop at the end of the file.
"""
bounded(n::Integer, limit::Integer) = min(Int(n), Int(limit))

# The string table at `io`'s position, `io` reading `bytes`. Each string is copied
# straight out of `bytes`, once; the check before it keeps the copy inside them.
function read_strings(io::IOBuffer, bytes::Vector{UInt8})
    total = length(bytes)
    n = bounded(read(io, UInt32), total)
    out = sizehint!(String[], n)
    for _ in 1:n
        len = read(io, UInt32)
        at = position(io)
        # Against what is left: in a 32-bit `Int`, `at + len` wraps past the check.
        len > total - at && break
        push!(out, GC.@preserve bytes unsafe_string(pointer(bytes, at + 1), len))
        skip(io, len)
    end
    return out
end

lookup(strings::Vector{String}, i::UInt32) = (1 <= i <= length(strings)) ? strings[i] : ""

function read_profiles_section(io::IO, strings)
    n = bounded(read(io, UInt32), bytesavailable(io))
    profiles = Dict{Symbol, Profile}()
    preferences = Dict{Symbol, String}()
    for _ in 1:n
        name = Symbol(lookup(strings, read(io, UInt32)))
        nargs = bounded(read(io, UInt32), bytesavailable(io))
        args = String[lookup(strings, read(io, UInt32)) for _ in 1:nargs]
        threads = lookup(strings, read(io, UInt32))
        nenv = bounded(read(io, UInt32), bytesavailable(io))
        env = Pair{String, String}[]
        for _ in 1:nenv
            k = lookup(strings, read(io, UInt32)); v = lookup(strings, read(io, UInt32))
            push!(env, k => v)
        end
        init = parse_block(lookup(strings, read(io, UInt32)))
        test_end = parse_block(lookup(strings, read(io, UInt32)))
        path = lookup(strings, read(io, UInt32))
        content = lookup(strings, read(io, UInt32))
        profiles[name] = Profile(name, args, threads, env, init, test_end, path, "", "", nothing)
        isempty(content) || (preferences[name] = content)
    end
    return profiles, preferences
end

function parse_block(str::AbstractString)
    isempty(strip(str)) && return Expr(:block)
    ex = try
        Meta.parseall(str)::Expr
    catch
        return Expr(:block)
    end
    return normalize_block(Expr(:block, ex.args...))
end

# An expression that has been printed and parsed back is not `==` to the original
# — line numbers move and blocks nest — so both sides are normalized before they
# are written or compared. Otherwise every run would think the recorded
# configuration differs from its own and say so.
function normalize_block(ex::Expr)
    out = Base.remove_linenums!(deepcopy(ex))::Expr
    while out.head === :block && length(out.args) == 1 && (inner = out.args[1]) isa Expr && inner.head === :block
        out = inner
    end
    return out
end

# An empty block is stored as no text, which `parse_block` reads back without
# parsing: most profiles have no `init` or `test_end`, and every read would parse both.
function expr_text(ex::Expr)
    out = normalize_block(ex)
    return out isa Expr && out.head === :block && isempty(out.args) ? "" : string(out)
end

# What someone who was handed the file needs first: where and how it ran, what did
# not pass, what each worker did before it ended, and how to run it again.
function Base.show(io::IO, ::MIME"text/plain", rs::RunStateRecord)
    m(k) = get(rs.meta, k, "")
    println(io, "Runtests run state ", rs.path, is_live(rs) ? " (still running)" : rs.complete ? "" :
        " (incomplete: its coordinator stopped without saying how the run ended)")
    took = rs.end_unix > rs.start_unix ? string(", took ", fmt_seconds(rs.end_unix - rs.start_unix)) : ""
    # A damaged file's start is no time a clock can show.
    started = abs(rs.start_unix) < 1.0e12 ? Libc.strftime("%Y-%m-%d %H:%M:%S", rs.start_unix) : string(rs.start_unix)
    println(io, "  started ", started, took, rs.complete ? string(", ", ending_word(rs.ending)) : "")
    println(io, "  julia ", m("julia"), " (", first(m("julia_commit"), 10), ") · ", m("machine"), " · ",
        m("cpu_threads"), " CPU threads · ", fmt_gib(something(tryparse(Int64, m("memory_bytes")), 0)), " · host ", m("host"))
    println(io, "  project ", m("project_id"), isempty(m("revision")) ? "" : string(" · rev ", first(m("revision"), 10)),
        m("worktree") == "dirty" ? " with uncommitted changes" : "",
        " · Runtests ", m("runtests"), isempty(m("runtests_revision")) ? "" : string(" (", first(m("runtests_revision"), 10), ")"))
    # Split at the spaces they were joined with: a damaged file's text need not be valid
    # UTF-8, and `split` at whitespace asks each character what it is.
    flags = nondefault_flags(split(m("julia_flags"), ' '; keepempty = false))
    println(io, "  seed ", m("seed"), " · workers ", m("workers"), " · threads ", m("threads"), " · timeout ", m("timeout"),
        "s · retries ", m("retries"), isempty(flags) ? "" : string(" · ", join(flags, " ")),
        isempty(m("selection")) ? "" : string(" · selected ", m("selection")))
    manifest = recorded_manifest(rs)
    isempty(manifest) || println(io, "  environment recorded: ",
        count(l -> startswith(l, "[[deps."), eachline(IOBuffer(manifest))), " packages in its manifest")
    states = [s.state for s in rs.statuses]
    passed = count(==(PASSED), states)
    tally = [passed > 0 ? ["$passed passed"] : String[]; state_tally(states)]
    println(io, "  ", length(rs.items), " items: ", join(tally, ", "))
    # Paired by index: a damaged file can hold fewer items than statuses.
    bad = Tuple{Int, RunStateItem, RunStateStatus}[
        (i, it, st) for (i, (it, st)) in enumerate(zip(rs.items, rs.statuses))
        if is_non_pass(st.state) || st.state === RUNNING
    ]
    isempty(bad) || println(io, "  not passed:")
    prefix = joinpath(rundata_dir(rs.path), "item_")
    for (i, it, st) in bad
        println(io, "    ", rpad(repr(it.name), 30), " ", rpad(string(st.state), 12), " attempt ", st.attempt,
            " · worker ", st.slot, " (pid ", st.pid, ") · ", fmt_seconds(st.elapsed), " · ", it.file, ":", it.line)
        kept = filter(ispath, [failure_path(prefix, i, max(st.attempt, 1)), item_log_path(prefix, i, max(st.attempt, 1)),
                               artifacts_path(prefix, i, max(st.attempt, 1))])
        isempty(kept) || println(io, "      ", join(kept, " · "))
    end
    downs = filter(e -> e.kind === :worker_down && e.ended_by !== :close, rs.events)
    isempty(downs) || println(io, "  workers that did not end normally:")
    for d in downs
        ran = [rs.items[e.item].name for e in rs.events if e.kind === :attempt && e.pid == d.pid && 1 <= e.item <= length(rs.items)]
        # The signal's number alone: names and some numbers differ between systems,
        # and this may not be the one that recorded it.
        how = d.signal != 0 ? string("signal ", d.signal) : string("exit code ", d.exitcode)
        println(io, "    worker ", d.slot, " pid ", d.pid, " at ", fmt_seconds(d.t0), ": ", worker_end_text(d.ended_by),
            " (", how, ") · had run ", length(ran), isempty(ran) ? "" : string(": ", join(repr.(last(ran, 5)), ", "), length(ran) > 5 ? ", …" : ""))
    end
    print(io, "  run it again with Runtests.runtests(replay = ", repr(run_location(rs.path)), ")")
    any(((_, _, st),) -> is_non_pass(st.state) && st.state !== CANCELLED, bad) &&
        print(io, ", or its failing items with Runtests.runtestsf(replay = ", repr(run_location(rs.path)), ")")
end

### Where run states live ##################################################

"""
    run_host() -> String

The machine a run state is recorded as coming from, and whose run states are this
machine's to prune: `\$RUNTESTS_HOST` when set, otherwise the hostname. A CI runner has
a new hostname every run, so run states restored from one run's cache into the next
would count as another machine's and never be pruned; naming the machine keeps them
this machine's.
"""
function run_host()
    host = get(ENV, "RUNTESTS_HOST", "")
    return isempty(host) ? machine_name() : host
end

"""
    machine_name() -> String

This machine's name: the one macOS gives it, `LocalHostName`, and elsewhere its
hostname. On macOS the hostname follows the network, a DHCP name on one and
`name.local` on another, and one machine would keep its run states under several
names, pruning those of each only while it has that name.
"""
function machine_name()
    isempty(MACHINE_NAME[]) || return MACHINE_NAME[]
    given = try
        Platform.local_host_name()
    catch e
        is_interrupt(e) && rethrow()
        ""
    end
    name = isempty(given) ? gethostname() : given
    # Kept for the session, but not while precompiling, which would put the name of
    # the machine that built the package image into it, for every machine to read.
    ccall(:jl_generating_output, Cint, ()) == 0 && (MACHINE_NAME[] = name)
    return name
end
const MACHINE_NAME = Ref("")

# Whether this machine recorded a run state, and so may prune it: by `run_host`, or,
# with no `RUNTESTS_HOST`, by the hostname the machine had when it wrote it, which on
# macOS can be another than the name it has now.
function recorded_here(rs::Union{RunStateRecord, RunStateMeta})
    host = get(rs.meta, "host", "")
    host == run_host() && return true
    return isempty(get(ENV, "RUNTESTS_HOST", "")) && host == gethostname()
end

"""
    runstate_dir(root) -> String

`\$RUNTESTS_RUNSTATE_DIR` when set, made absolute against the current directory: an
item runs in its package's root, and the logs it writes there land here all the same.
Otherwise a directory of the depot's own keyed by the project path, so nothing lands
in the repository, and named for the project as well, so a person can tell which is
whose. Not under `scratchspaces/`:
`Pkg.gc`, which `Pkg` also runs after its own operations, deletes every directory
there that no package has registered, and with it the history that orders the
next run. The path is printed at the end of a run so CI can upload it.
"""
function runstate_dir(root::AbstractString)
    dir = get(ENV, "RUNTESTS_RUNSTATE_DIR", "")
    isempty(dir) || return abspath(dir)
    key = string(crc32c(abspath(root)); base = 16, pad = 8)
    label = dir_label(root)
    return joinpath(runstate_root(), isempty(label) ? key : string(label, "-", key))
end

# The project's name, or its directory's when it has none, as a directory name
# takes it on any system: ASCII letters, digits, `_`, `-` and `.`, not leading with
# a dot, at most 32 of them. For people to read; the key beside it tells projects
# apart.
function dir_label(root::AbstractString)
    i = findfirst(f -> isfile(joinpath(root, f)), PROJECT_NAMES)
    name = i === nothing ? nothing : project_name_of(joinpath(root, PROJECT_NAMES[i]))
    name isa AbstractString || (name = basename(abspath(root)))
    kept = filter(c -> isascii(c) && (isletter(c) || isdigit(c) || c in "_-."), name)
    return first(lstrip(==('.'), kept), 32)
end

# Where each project's directory of run states goes, when `RUNTESTS_RUNSTATE_DIR` does
# not say. Read as the run starts: the depot is the session's, not the build's.
runstate_root() = joinpath(first(DEPOT_PATH), "runtests", "runs")

# Beside a project's run states in the default location: the project's path, which
# tells `sweep_runstate_dirs` whether the project is still there, and the cached test
# environment directory (`environments.jl`).
const PROJECT_MARK = "project"
const ENV_CACHE_DIR = "envcache"

# A run keeps what it records in a directory of its own, `<run>.rundata`: the record,
# `RUNSTATE_FILE`, and beside it what its items left, every name of which starts with
# `item_`, and `setup.log` for a run that ended before its first item. No two of these
# names can be the same.
const RUNDATA_EXT = ".rundata"
const RUNSTATE_FILE = "run.runstate"

# The record of the run whose directory, or record, `path` is.
record_path(path::AbstractString) = isdir(path) ? joinpath(path, RUNSTATE_FILE) : String(path)

# How the run whose record is `path` is named, to replay it say: by its directory,
# `<run>.rundata`, or for a record kept elsewhere, a copy say, by the record's own path.
run_location(path::AbstractString) = endswith(dirname(path), RUNDATA_EXT) ? dirname(path) : String(path)

# The path of a new run's record, in a new directory of its own. Named for the
# microsecond the run started, in 16 digits (enough until the year 2286), so that names
# sort oldest first: one process starts its runs one after another, milliseconds apart
# at the least, so its names never tie. The pid tells apart processes that start in
# the same microsecond, which leaves nothing to order. The wall clock, not `time_ns`,
# which restarts with the machine. A directory already there, one downloaded from CI
# say, is never written into: the new name takes a suffix instead.
function new_runstate_path(root::AbstractString; start_us::Integer = wall_microseconds())
    dir = runstate_dir(root)
    mkpath(dir)
    if isempty(get(ENV, "RUNTESTS_RUNSTATE_DIR", ""))
        mark = joinpath(dir, PROJECT_MARK)
        # Whole or not at all: `sweep_runstate_dirs` reading half a path would take
        # the project for gone.
        isfile(mark) || write_whole(mark, abspath(root))
    end
    stem = string(lpad(start_us, 16, '0'), "-", getpid())
    n = 1
    while true
        rundata = joinpath(dir, n == 1 ? stem * RUNDATA_EXT : string(stem, "_", n, RUNDATA_EXT))
        # Made, not checked for: two processes that name a directory the same, in
        # containers sharing the directory say, get one each.
        claimed = try
            mkdir(rundata)
            true
        catch e
            (e isa Base.IOError && e.code == Base.UV_EEXIST) || rethrow()
            false
        end
        claimed && return joinpath(rundata, RUNSTATE_FILE)
        n += 1
    end
end

wall_microseconds() = (tv = Libc.TimeVal(); tv.sec * 1_000_000 + tv.usec)

# The records of the runs in directory `dir`, oldest first: one in each `<run>.rundata`
# directory, which a run that is starting may not have written yet.
function runstate_files_in(dir::AbstractString)
    # Another process can delete the directory between any two calls.
    files = try
        [joinpath(dir, d, RUNSTATE_FILE) for d in readdir(dir) if endswith(d, RUNDATA_EXT)]
    catch e
        e isa Base.IOError || rethrow()
        return String[]
    end
    # A record that cannot be looked at is one being deleted (see `read_run_state`).
    is_record(f) = try
        isfile(f)
    catch e
        e isa Base.IOError || rethrow()
        false
    end
    return sort!(filter!(is_record, files))   # names start with a unix timestamp, so this is oldest-first
end

runstate_files(root::AbstractString) = runstate_files_in(runstate_dir(root))

const KEEP_RUNS = 20

# How many of the newest run states `history` reads recent failures from.
const HISTORY_RUNS = 5

# Whether a run state is this project's. The default directory holds one project's
# runs; one set by `RUNTESTS_RUNSTATE_DIR` can hold several.
of_project(rs::RunStateRecord, project::AbstractString) = get(rs.meta, "project_id", "") == project

"""
    prunable_runstates(root; keep = KEEP_RUNS, names = nothing) -> Vector{String}

The run states that pruning deletes, oldest first, at the end of a run and in
`chores` alike: of those this machine recorded for this project, beyond the newest
`keep`, each whose deletion changes no fact of an item of `names`, the suite's items
(see [`removable_runs`](@ref)). That is the invariant of every deletion here: what
the run states say about each item of the suite (`kept_facts`) is the same after it
as before, so a run state that holds such a newest fact is never among these. One recorded elsewhere, a CI artifact downloaded
into the directory say, one of another project, and one that cannot be read are
never among them: nothing shows they are ours. Nor is one still being written
(`is_live`), by a run that started long before the newest `keep`.
"""
function prunable_runstates(root::AbstractString; keep::Int = KEEP_RUNS, names = nothing)
    runs = project_runs(root)
    ours = [f for (f, rs) in runs if recorded_here(rs)]
    length(ours) < length(runs) && warn_unnamed_ci_host(runstate_dir(root))
    live = Set(f for (f, rs) in runs if is_live(rs))
    return removable_runs(runs, filter(!in(live), ours[1:max(0, length(ours) - keep)]); names)
end

# Delete what `prunable_runstates` names, each with its logs.
function prune_runstates(root::AbstractString, keep::Int = KEEP_RUNS; names = nothing)
    foreach(remove_runstate, prunable_runstates(root; keep, names))
    return nothing
end

# Once-per-session warning tracker for directories (CI host, foreign format).
const WARNED_DIRS_LOCK = ReentrantLock()
const WARNED_HOSTS = Set{String}()
const WARNED_FORMATS = Set{String}()

warn_once!(seen::Set{String}, key::AbstractString) =
    @lock WARNED_DIRS_LOCK (key in seen ? false : (push!(seen, String(key)); true))

# On CI each job is a new machine to its hostname, so a directory of run states that a
# cache brings back from job to job gains files and never loses any, unless
# `RUNTESTS_HOST` names the machine the jobs take turns being. Said once a session for
# each directory, when it holds run states of other machines.
function warn_unnamed_ci_host(dir::AbstractString)
    get(ENV, "CI", "") in ("true", "1") && isempty(get(ENV, "RUNTESTS_HOST", "")) || return nothing
    warn_once!(WARNED_HOSTS, dir) || return nothing
    @warn "Runtests: $(relpath_or_path(dir)) holds run states of other machines, and `RUNTESTS_HOST` is not set: " *
        "on CI each job is a new machine, and what a cache brings back is never pruned. Set `RUNTESTS_HOST` to " *
        "one name for the jobs that share the cache"
    return nothing
end

# The directory of the run whose record is `path`, `<run>.rundata`, which also holds its
# logs.
rundata_dir(path::AbstractString) = dirname(path)

# A run's directory, its record and its logs together; nothing but a run's directory.
# Another process may be reading them, or have deleted them already.
function remove_runstate(path::AbstractString)
    (basename(path) == RUNSTATE_FILE && endswith(dirname(path), RUNDATA_EXT)) || return nothing
    try
        rm(dirname(path); force = true, recursive = true)
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

# This project's run states that can be read, oldest first, each with its file.
# Ordered by when each run started, as the file records it, not by its name: a run
# state from elsewhere, renamed as it was downloaded say, counts from when it ran.
# Reads with `full = false` (skipping profile AST parsing and cold replay blobs).
function project_runs(root::AbstractString)
    project = project_id(root)
    runs = Pair{String, RunStateRecord}[]
    others = 0   # files of a format this version does not read
    for f in runstate_files(root)
        rs = read_run_state(f; full = false)
        if rs === nothing
            v = runstate_version(f)
            v === nothing || v == RS_VERSION || (others += 1)
            continue
        end
        of_project(rs, project) && push!(runs, f => rs)
    end
    others == 0 || warn_other_formats(runstate_dir(root), others)
    return sort!(runs; by = ((f, rs),) -> (rs.start_unix, f))
end

"""
    runstate_version(path) -> Union{Nothing, UInt32}

The format a run state file says it is in, from its first eight bytes; `nothing`
for a file that is not a run state.
"""
function runstate_version(path::AbstractString)
    try
        return open(path) do io
            read(io, UInt32) == RS_MAGIC ? read(io, UInt32) : nothing
        end
    catch e
        is_interrupt(e) && rethrow()
        return nothing
    end
end

# A run state this version does not read, another version's, is history the run goes
# without, which is said rather than left to be found out.
function warn_other_formats(dir::AbstractString, others::Integer)
    warn_once!(WARNED_FORMATS, dir) || return nothing
    @warn "Runtests: $(relpath_or_path(dir)) holds $(plural(others, "run state")) of another version of Runtests; " *
        "this version does not read them, so the durations and failures they recorded are not used"
    return nothing
end

# The run states that one call reads what is failing and its history from, read once
# (`with_runs_read`): what `runtestsf` selects and the plan that runs it see the same
# files, read once. Pruning, after the run, reads them again with the run's own among them.
const RUNS_READ = ScopedValue{Union{Nothing, Pair{String, Vector{Pair{String, RunStateRecord}}}}}(nothing)

# `f()`, with the run states of the project at `root` read once for it.
with_runs_read(f, root::AbstractString) = with(f, RUNS_READ => (String(root) => project_runs(root)))

# `project_runs`, with `base` among them, when there is one, wherever its file is:
# the run state a replay names.
function runs_with(root::AbstractString, base::Union{Nothing, RunStateRecord})
    read = RUNS_READ[]
    cached = read !== nothing && read.first == root
    runs = cached ? read.second : project_runs(root)
    (base === nothing || any(((f, _),) -> samefile(f, base.path), runs)) && return runs
    out = cached ? copy(runs) : runs
    push!(out, base.path => base)
    return sort!(out; by = ((f, rs),) -> (rs.start_unix, f))
end

# Of `runs`, the ones whose verdicts count: from the base run on, when there is one.
# What ran before it says how long items take, not whether they pass.
since_base(runs, base::Union{Nothing, RunStateRecord}) =
    base === nothing ? runs : filter(((_, rs),) -> rs.start_unix >= base.start_unix, runs)

# Item `i`'s verdict in a run: `true` when it did not pass, `false` when it passed,
# and `nothing` when the run got none: it skipped the item, or stopped before the
# item ran or while it ran. A skip says the item did not run here, not that it works.
function verdict(rs::RunStateRecord, i::Integer)
    state = i <= length(rs.statuses) ? rs.statuses[i].state : UNSEEN
    (state === UNSEEN || state === CANCELLED || state === SKIPPED) && return nothing
    # Left running, as the run's ending says it: hung in a run stopped as hung, and the
    # first suspect of a coordinator that died without saying; stopped, and no verdict,
    # in a run stopped any other way.
    state === RUNNING && return rs.ending in (ENDING_STALLED, ENDING_NONE) ? true : nothing
    return state !== PASSED
end

"""
    ItemFacts

What the kept run states say about one item. The run order, `runtestsf`, `debug` and
pruning all read these, so they cannot disagree about an item.
"""
struct ItemFacts
    verdict::Int8          # the latest: -1 for none, 0 passed, 1 failing
    state::ItemState       # the state that verdict was
    verdict_at::Float64    # when the run of the latest verdict started
    verdict_end::Float32   # when the item ended in that run, in seconds from its start
    seed::UInt64           # the seed the item's numbers came from in that run
    seconds::Float64       # the newest duration; 0 for none
    hash::UInt32           # the source hash in the newest run that ran it; 0 for unknown
    selected_at::Float64   # when the newest run that is over and selected it started
    unreached::Bool        # whether that run stopped before the item ended
    peak_rss_mb::Float64   # newest worker peak RSS (MiB) recorded for this item; 0 for none
    compile_s::Float64     # newest recorded compile time (s) for this item; 0 for none
end
const NO_FACTS = ItemFacts(Int8(-1), UNSEEN, 0.0, 0.0f0, UInt64(0), 0.0, UInt32(0), 0.0, false, 0.0, 0.0)

is_failing(f::ItemFacts) = f.verdict == 1

"""
    item_facts(runs; base = nothing) -> Dict{String, ItemFacts}

Every item's facts from `runs`, oldest first as `project_runs` gives them. Durations,
compile times, worker memory peaks, and source hashes come from every run but dry runs
and those that ended before their first item, a run another process is still in the
middle of included: what it has finished is finished. Verdicts and stops come from the
runs that are over, and with `base`, the run state a replay names, from it and the runs
that started after it.
"""
function item_facts(runs::Vector{Pair{String, RunStateRecord}}; base::Union{Nothing, RunStateRecord} = nothing)
    facts = Dict{String, ItemFacts}()
    for (_, rs) in runs
        (rs.dry_run || rs.aborted) && continue
        counts = !is_live(rs) && (base === nothing || rs.start_unix >= base.start_unix)
        on_worker = get(rs.meta, "workers", "") != "0"
        # Paired by index: a damaged file can hold fewer statuses than items.
        for i in 1:min(length(rs.items), length(rs.statuses))
            it, st = rs.items[i], rs.statuses[i]
            f = get(facts, it.name, NO_FACTS)
            v, state, at, ended, seed = f.verdict, f.state, f.verdict_at, f.verdict_end, f.seed
            seconds, hash, selected_at, unreached, peak_rss, comp =
                f.seconds, f.hash, f.selected_at, f.unreached, f.peak_rss_mb, f.compile_s
            if timed(st.state) && st.elapsed > 0
                seconds = Float64(st.elapsed)
                comp = Float64(st.compile)
            end
            on_worker && timed(st.state) && st.peak_rss_mb > 0 && (peak_rss = Float64(st.peak_rss_mb))
            (st.state === UNSEEN || st.state === RUNNING || st.state === CANCELLED) || (hash = it.hash)
            if counts
                found = verdict(rs, i)
                if found !== nothing
                    v, state, at, ended, seed = Int8(found), st.state, rs.start_unix, st.start_off + st.elapsed, it.seed
                end
                selected_at = rs.start_unix
                # Never reached, or stopped before it ran to a verdict, in a run that is over,
                # whichever way it ended: a coordinator that died stopped it too.
                unreached = st.state === UNSEEN || st.state === CANCELLED || (st.state === RUNNING && found === nothing)
            end
            facts[it.name] = ItemFacts(v, state, at, ended, seed, seconds, hash, selected_at, unreached, peak_rss, comp)
        end
    end
    return facts
end

# Recompute the kept-facts tuple for one item from its sorted `(run_idx, item_idx)`
# occurrences, scanning newest-to-oldest over `alive` runs and stopping once all four
# last-writer-wins channels are filled. Returns `(facts_tuple, min_run_visited)` where
# `min_run_visited > 0` means every channel was decided by runs `>= min_run_visited`.
function eval_item_kept(occ::Vector{Tuple{Int32, Int32}}, runs::Vector{Pair{String, RunStateRecord}},
                        counts::BitVector, alive::BitVector)
    present = false
    has_v = false; v = Int8(-1); vat = 0.0; vseed = UInt64(0)
    has_sec = false; sec = 0.0
    has_hash = false; hash = UInt32(0)
    has_unr = false; unr = false
    min_r = Int32(0)
    for k in lastindex(occ):-1:firstindex(occ)
        r, i = occ[k]
        alive[r] || continue
        present = true
        rs = runs[r].second
        it, st = rs.items[i], rs.statuses[i]
        if !has_sec && timed(st.state) && st.elapsed > 0
            sec = Float64(st.elapsed)
            has_sec = true
        end
        if !has_hash && !(st.state === UNSEEN || st.state === RUNNING || st.state === CANCELLED)
            hash = it.hash
            has_hash = true
        end
        if counts[r]
            if !has_v || !has_unr
                found = verdict(rs, i)
                if !has_v && found !== nothing
                    v = Int8(found)
                    vat = rs.start_unix
                    vseed = found ? it.seed : UInt64(0)
                    has_v = true
                end
                if !has_unr
                    unr = st.state === UNSEEN || st.state === CANCELLED || (st.state === RUNNING && found === nothing)
                    has_unr = true
                end
            end
        end
        if has_v && has_sec && has_hash && has_unr
            min_r = r
            break
        end
    end
    return (present, v, vat, vseed, sec, hash, unr), min_r
end

in_names(::Nothing, ::String) = true
in_names(names, name::String) = name in names

"""
    removable_runs(runs, candidates; names = nothing) -> Vector{String}

Of `candidates`, files among `runs` (every run state of the project, oldest first),
those whose deletion changes no item's facts (see [`item_facts`](@ref)): its latest
verdict and when it was recorded, the seed of a failure, its newest duration and
source hash, and whether the newest run to select it stopped before it. With
`names`, the suite's items, only theirs count: an item the suite no longer has holds
back no run state beyond the newest ones pruning keeps anyway. Taken oldest first, so
a run state is judged by what is left once the older ones have gone. Each item's
newest verdict stays, which is also what a replay's base is read against: the
verdicts after the base, newest first.
"""
function removable_runs(runs::Vector{Pair{String, RunStateRecord}}, candidates; names = nothing)
    # Nothing to weigh: the facts of every item need not be built to keep every run.
    isempty(candidates) && return String[]
    R = length(runs)
    active = BitVector(undef, R)
    counts = BitVector(undef, R)
    now_t = time()
    for r in 1:R
        rs = runs[r].second
        act = !(rs.dry_run || rs.aborted)
        active[r] = act
        counts[r] = act && !is_live(rs; now = now_t)
    end

    # Resolve candidate indices in `runs` (preserving order and duplicate-removal semantics).
    cand_set = Set{String}()
    for f in candidates
        push!(cand_set, String(f))
    end
    # Only items that appear in at least one active candidate run can ever change facts.
    name_to_id = Dict{String, Int32}()
    run_ids = Vector{Vector{Int32}}(undef, R)
    for r in 1:R
        run_ids[r] = Int32[]
        (active[r] && runs[r].first in cand_set) || continue
        rs = runs[r].second
        n = min(length(rs.items), length(rs.statuses))
        ids = run_ids[r]
        sizehint!(ids, n)
        for i in 1:n
            nm = rs.items[i].name
            in_names(names, nm) || continue
            id = get(name_to_id, nm, Int32(0))
            if id == 0
                id = Int32(length(name_to_id) + 1)
                name_to_id[nm] = id
            end
            push!(ids, id)
        end
    end

    M = length(name_to_id)
    occ = [Tuple{Int32, Int32}[] for _ in 1:M]
    if M > 0
        for r in 1:R
            active[r] || continue
            rs = runs[r].second
            for i in 1:min(length(rs.items), length(rs.statuses))
                id = get(name_to_id, rs.items[i].name, Int32(0))
                id == 0 || push!(occ[id], (Int32(r), Int32(i)))
            end
        end
    end

    alive = copy(active)
    target = Vector{Tuple{Bool, Int8, Float64, UInt64, Float64, UInt32, Bool}}(undef, M)
    min_needed = zeros(Int32, M)
    for id in 1:M
        target[id], min_needed[id] = eval_item_kept(occ[id], runs, counts, alive)
    end

    removed = falses(R)
    updated_ids = Int32[]
    updated_mins = Int32[]
    out = String[]
    for f in candidates
        r = 0
        for j in 1:R
            if !removed[j] && runs[j].first == f
                r = j
                break
            end
        end
        r == 0 && continue
        if !active[r]
            removed[r] = true
            push!(out, String(f))
            continue
        end
        alive[r] = false
        ok = true
        empty!(updated_ids); empty!(updated_mins)
        for id in run_ids[r]
            # Fast path: every fact channel for `id` is already decided by alive runs newer than `r`.
            r < min_needed[id] && continue
            got, new_min = eval_item_kept(occ[id], runs, counts, alive)
            if got != target[id]
                ok = false
                break
            end
            push!(updated_ids, id); push!(updated_mins, new_min)
        end
        if ok
            removed[r] = true
            for k in eachindex(updated_ids)
                min_needed[updated_ids[k]] = updated_mins[k]
            end
            push!(out, String(f))
        else
            alive[r] = true
        end
    end
    return out
end

# The facts a deletion has to leave as they are, by item: a pass's seed, and the time
# of a verdict that does not exist, say nothing.
kept_facts(facts::Dict{String, ItemFacts}, names) = Dict(
    n => (f.verdict, f.verdict == -1 ? 0.0 : f.verdict_at, is_failing(f) ? f.seed : UInt64(0), f.seconds, f.hash, f.unreached)
    for (n, f) in facts if names === nothing || n in names
)

# What a file manager leaves in a folder it shows, which says nothing of the folder:
# `.DS_Store` and the like on macOS, `Thumbs.db` and `desktop.ini` on Windows.
is_folder_metadata(name::AbstractString) = startswith(name, '.') || name in ("Thumbs.db", "desktop.ini")

# How long the run states of a checkout that is gone stay, from the newest of them.
const SWEEP_GRACE_S = 30 * 24 * 3600.0

"""
    GoneCheckout

A directory of the default location whose checkout is gone, as the sweep finds it:
the path the checkout was at, the run states of this machine's it deletes there,
and whether the directory goes as well, with nothing left in it but what a file
manager put there.
"""
struct GoneCheckout
    dir::String
    project::String
    runstates::Vector{String}
    whole::Bool
end

"""
    sweep_runstate_dirs(base = runstate_root(); temp = tempdir(), fix = true, ntasks) -> Vector{GoneCheckout}

Clear the default location of checkouts that are gone, as `chores` does: in each
directory whose recorded project path has not existed for `SWEEP_GRACE_S`, by the
newest of its run states, or at once for a project that was in `temp`, the system's
temporary files, delete this machine's run states and their logs, and then the
directory once nothing else is left in it. With `fix = false` it deletes nothing and
says what it would. A run state recorded elsewhere, one of another format version or
that cannot be read otherwise, and a directory without a recorded project stay: nothing
shows they are this machine's to delete. So does a project that is out of reach rather than gone: one whose parent directory is missing
or empty, as a drive that is not mounted leaves it.

The directories are read by `ntasks` tasks: a test suite that makes packages in the
temporary files leaves hundreds of them, and on a file system that answers slowly,
one directory holds up one task rather than the sweep.
"""
function sweep_runstate_dirs(
        base::AbstractString = runstate_root(); temp::AbstractString = tempdir(), fix::Bool = true,
        ntasks::Int = default_scan_tasks()
    )
    dirs = try
        filter!(isdir, readdir(base; join = true))
    catch e
        e isa Base.IOError || rethrow()
        return GoneCheckout[]
    end
    ch = Channel{String}(length(dirs))
    foreach(d -> put!(ch, d), dirs)
    close(ch)
    parents = ParentCheck(ReentrantLock(), Dict{String, Bool}())
    found = [GoneCheckout[] for _ in 1:clamp(ntasks, 1, max(1, length(dirs)))]
    @sync for out in found
        Threads.@spawn for dir in ch
            gone = gone_checkout(dir, temp, parents)
            gone === nothing && continue
            fix && sweep!(gone)
            push!(out, gone)
        end
    end
    return sort!(reduce(vcat, found; init = GoneCheckout[]); by = g -> g.dir)
end

# Whether the folder a gone checkout was in is there with something in it, as an
# unmounted drive's is not: asked once a folder, since the checkouts of a test suite's
# packages share one, the temporary files, which can list thousands of entries.
struct ParentCheck
    lock::ReentrantLock
    seen::Dict{String, Bool}
end
reachable!(c::ParentCheck, parent::String) =
    @lock c.lock get!(() -> isdir(parent) && !isempty(readdir(parent)), c.seen, parent)

# What the sweep deletes in `dir`, or `nothing` when its checkout is there, out of
# reach, gone for less than the grace period, or the directory cannot be read: one
# another process is writing or deleting is left for next time.
function gone_checkout(dir::AbstractString, temp::AbstractString, parents::ParentCheck)
    try
        mark = joinpath(dir, PROJECT_MARK)
        isfile(mark) || return nothing
        project = String(strip(read(mark, String)))
        ispath(project) && return nothing
        # The temporary files are always there, and a checkout in them does not come
        # back; one elsewhere can, after its grace period, from a drive mounted again.
        in_temp = startswith(project, joinpath(temp, ""))
        in_temp || reachable!(parents, dirname(project)) || return nothing
        entries = readdir(dir)
        files = filter!(isfile, [joinpath(dir, d, RUNSTATE_FILE) for d in entries if endswith(d, RUNDATA_EXT)])
        in_temp || time() - maximum(mtime, files; init = 0.0) >= SWEEP_GRACE_S || return nothing
        deleted = filter(files) do f
            rs = read_run_meta(f)
            rs !== nothing && recorded_here(rs) && !is_live(rs)
        end
        going = Set(basename(dirname(f)) for f in deleted)
        whole = all(f -> f == PROJECT_MARK || f == ENV_CACHE_DIR || is_folder_metadata(f) || f in going, entries)
        return GoneCheckout(String(dir), project, deleted, whole)
    catch e
        is_interrupt(e) && rethrow()
        return nothing
    end
end

function sweep!(gone::GoneCheckout)
    foreach(remove_runstate, gone.runstates)
    try
        gone.whole && rm(gone.dir; recursive = true, force = true)
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

"""
    failing_items(root; names = nothing, base = nothing) -> Vector{String}

The items that are failing as the recorded runs leave them, sorted: for each item,
the last run in which it ran to a verdict decides, so running a few of one run's
failures again does not forget the rest. A verdict other than passed (failed,
errored, timed out, cut short by a dead worker, left running when the run itself
died) is failing. A skip is no verdict, and neither is a run that stopped before the
item ran or while it ran, nor a run another process is still in the middle of
(`is_live`): the verdict before stands. With `names`, only those items, which is how
a caller leaves out the items its suite no longer has. With `base`, the run state a
replay names, the verdicts are its own and those of the runs that started after it.
"""
function failing_items(
        root::AbstractString; names::Union{Nothing, AbstractSet{String}} = nothing,
        base::Union{Nothing, RunStateRecord} = nothing
    )
    return sort!(collect(keys(failing_facts(root; names, base))))
end

# The facts of the items `failing_items` names, by name.
function failing_facts(
        root::AbstractString; names::Union{Nothing, AbstractSet{String}} = nothing,
        base::Union{Nothing, RunStateRecord} = nothing
    )
    facts = item_facts(runs_with(root, base); base)
    return Dict(n => f for (n, f) in facts if is_failing(f) && (names === nothing || n in names))
end

"""
    history(root; nruns = HISTORY_RUNS, base = nothing) -> History

What planning takes from the kept run states, out of every item's facts (see
[`item_facts`](@ref)): newest durations and source hashes; the failing items, and
those the newest run to select them stopped before, each with how many runs ago
that was; every item a run state records; and what a fresh worker cost, from the
most recent `nruns` runs that are over (see [`is_live`](@ref)). With `base`, the run
state a replay names, verdicts, stops and costs come from it and the runs after it
only; durations still come from every run.
"""
function history(root::AbstractString; nruns::Int = HISTORY_RUNS, base::Union{Nothing, RunStateRecord} = nothing)
    runs = runs_with(root, base)
    facts = item_facts(runs; base)
    if isempty(facts)
        return base === nothing ? borrowed_history(root, nruns) : History()
    end
    now_t = time()
    # `runs` is already sorted by `(rs.start_unix, f)`.
    over = RunStateRecord[
        rs for (_, rs) in runs
        if (base === nothing || rs.start_unix >= base.start_unix) && !rs.dry_run && !rs.aborted && !is_live(rs; now = now_t)
    ]
    starts = Float64[rs.start_unix for rs in over]
    # How many runs that are over started after one that started at `t`.
    ago(t) = length(starts) - searchsortedlast(starts, t)
    failed = Dict{String, Int}()
    cancelled = Set{String}()
    for (name, f) in facts
        is_failing(f) && (failed[name] = ago(f.verdict_at))
        if f.unreached && ago(f.selected_at) <= get(failed, name, typemax(Int))
            failed[name] = ago(f.selected_at)
            push!(cancelled, name)
        end
    end
    seconds = Dict(n => f.seconds for (n, f) in facts if f.seconds > 0)
    hashes = Dict(n => f.hash for (n, f) in facts if f.hash != 0)
    item_rss = Dict(n => f.peak_rss_mb for (n, f) in facts if f.peak_rss_mb > 0)
    compile_s = Dict(n => f.compile_s for (n, f) in facts if f.compile_s > 0)
    recent = over[max(1, end - nruns + 1):end]
    return History(seconds, failed, recorded_cold_cost(recent), cancelled, hashes, Set(keys(facts)),
                   item_rss, recorded_crash_peak_worker_mb(recent), compile_s)
end

# Largest worker-tree peak RSS (MiB) recorded by the monitor across recent worker runs
# where at least one item crashed, timed out, or was left running without recording a
# status RSS (e.g. OOM before the item could finish). Skips `workers = 0` runs.
function recorded_crash_peak_worker_mb(runs::Vector{RunStateRecord})
    peak = 0.0
    for rs in runs
        get(rs.meta, "workers", "") == "0" && continue
        p = Float64(rs.memory.peak_worker_mb)
        p > 0 || continue
        had_crash = any(st -> st.state in (ERRORED, TIMEDOUT, RUNNING) && st.peak_rss_mb == 0, rs.statuses)
        had_crash && p > peak && (peak = p)
    end
    return peak
end

# When a checkout has no run states of its own, borrow durations and worker cold cost
# (never failures, hashes or known-item sets) from the newest sibling checkout under
# `runstate_root()` that shares the same package UUID. Only runs when `root` has a real
# UUID and `RUNTESTS_RUNSTATE_DIR` is not set.
function borrowed_history(root::AbstractString, nruns::Int = HISTORY_RUNS)
    isempty(get(ENV, "RUNTESTS_RUNSTATE_DIR", "")) || return History()
    pid = project_id(root)
    tryparse(Base.UUID, pid) === nothing && return History()
    base_dir = runstate_root()
    isdir(base_dir) || return History()
    own_dir = abspath(runstate_dir(root))
    best_time = -Inf
    best_files = String[]
    entries = try
        readdir(base_dir; join = true)
    catch e
        e isa Base.IOError || rethrow()
        return History()
    end
    for d in entries
        isdir(d) || continue
        abspath(d) == own_dir && continue
        files = runstate_files_in(d)
        isempty(files) && continue
        rm = read_run_meta(last(files))
        (rm === nothing || get(rm.meta, "project_id", "") != pid) && continue
        if rm.start_unix > best_time
            best_time = rm.start_unix
            best_files = files
        end
    end
    isempty(best_files) && return History()
    runs = Pair{String, RunStateRecord}[]
    for f in best_files
        rs = read_run_state(f; full = false)
        rs !== nothing && of_project(rs, pid) && push!(runs, f => rs)
    end
    sort!(runs; by = p -> (p.second.start_unix, p.first))
    facts = item_facts(runs)
    isempty(facts) && return History()
    now_t = time()
    over = RunStateRecord[rs for (_, rs) in runs if !rs.dry_run && !rs.aborted && !is_live(rs; now = now_t)]
    seconds = Dict(n => f.seconds for (n, f) in facts if f.seconds > 0)
    item_rss = Dict(n => f.peak_rss_mb for (n, f) in facts if f.peak_rss_mb > 0)
    compile_s = Dict(n => f.compile_s for (n, f) in facts if f.compile_s > 0)
    recent = over[max(1, end - nruns + 1):end]
    return History(seconds, Dict{String, Int}(), recorded_cold_cost(recent), Set{String}(),
                   Dict{String, UInt32}(), Set{String}(), item_rss, recorded_crash_peak_worker_mb(recent), compile_s)
end

"""
    timed(state) -> Bool

Whether the time recorded with an outcome is how long the item takes: not for one the
run stopped part way through (`cancelled`), whose time is how far it got, nor for one
that never ran (`unseen`, and `broken`, which older runs recorded for an item of a
chain whose worker died before it ran).
"""
timed(state::ItemState) = !(state === UNSEEN || state === CANCELLED || state === BROKEN_CHAIN)

# What a fresh worker cost across `runs`: how long its process took to come up, how much
# longer a process's first item spent compiling than its later ones did, and the mean total
# compile time each active worker process spent across worker runs. 0 for what the runs
# did not record.
function recorded_cold_cost(runs::Vector{RunStateRecord})
    starts, start_s = 0, 0.0
    cold, cold_s, warm, warm_s = 0, 0.0, 0, 0.0
    worker_count, worker_comp_s = 0, 0.0
    for rs in runs
        on_worker = get(rs.meta, "workers", "") != "0"
        pids = Set{Int32}()
        # Direct integer index per status row replaces a `Dict{Tuple{Int32, Int8}, Int16}`.
        seq = zeros(Int16, length(rs.statuses))
        for e in rs.events
            if e.kind === :attempt
                if on_worker && e.pid > 0
                    push!(pids, e.pid)
                    worker_comp_s += Float64(e.compile)
                end
                if e.seq > 0 && checkbounds(Bool, rs.statuses, e.item) &&
                        rs.statuses[e.item].attempt == e.attempt
                    seq[e.item] = e.seq
                end
            elseif e.kind === :worker_up && e.t1 > e.t0
                starts += 1
                start_s += e.t1 - e.t0
            end
        end
        worker_count += length(pids)
        for (i, st) in enumerate(rs.statuses)
            n = seq[i]
            if n == 1
                cold += 1; cold_s += st.compile
            elseif n > 1
                warm += 1; warm_s += st.compile
            end
        end
    end
    return ColdCost(
        starts > 0 ? start_s / starts : 0.0,
        cold > 0 && warm > 0 ? max(0.0, cold_s / cold - warm_s / warm) : 0.0,
        worker_count > 0 ? worker_comp_s / worker_count : 0.0
    )
end

"""
    repository_root(dir) -> Union{String, Nothing}

The checkout `dir` is in: the nearest directory at or above it that holds `.git`, as
`git` finds it, a directory or, in a worktree or a submodule, a file. `nothing`
outside a checkout. A package in a subdirectory, as in a monorepo, is in its
repository's checkout and holds no `.git` of its own.
"""
function repository_root(dir::AbstractString)
    d = abspath(dir)
    while true
        ispath(joinpath(d, ".git")) && return d
        parent = dirname(d)
        parent == d && return nothing
        d = parent
    end
end

"""
    worktree_state(root) -> String

Whether the repository holding `root` has what its last commit has: `"clean"` when
every file git tracks is unchanged and no Julia or TOML file under `root` is one git
neither tracks nor ignores, such as a test file not added yet; `"dirty"` otherwise; and
`"unknown"` without git or a repository. A run records it beside its revision: a dirty
run ran code that the revision does not give back. Other files git does not track, such
as notes and logs, are no code of the run. It runs `git`, so a run asks it in the
background while it makes its environments ready.
"""
function worktree_state(root::AbstractString)
    repo = repository_root(root)
    (repo === nothing || Sys.which("git") === nothing) && return "unknown"
    try
        # NUL-separated, so a path is as it is, unquoted.
        out = read(pipeline(`git -C $repo status --porcelain -z --untracked-files=all`; stderr = devnull), String)
        under = relpath(realpath(root), realpath(repo))
        prefix = under == "." ? "" : string(replace(under, '\\' => '/'), '/')
        for entry in eachsplit(out, '\0'; keepempty = false)
            startswith(entry, "?? ") || return "dirty"
            path = SubString(entry, 4)
            startswith(path, prefix) && (endswith(path, ".jl") || endswith(path, ".toml")) && return "dirty"
        end
        return "clean"
    catch e
        # In a task of its own, which a Ctrl-C can land in: the interrupt is the run's.
        is_interrupt(e) && RuntestsWorkers.forward_interrupt(e)
        return "unknown"
    end
end

"""
    project_revision(root) -> String

The commit the tests run from, or `""`, so a run state (one downloaded from CI,
say) says what to check out. Read from `.git` rather than by running `git`, which
would put a subprocess between `runtests()` and the first item. It names the commit,
not the working tree: local edits do not change it.
"""
function project_revision(root::AbstractString)
    try
        repo = repository_root(root)
        repo === nothing && return ""
        gitdir = joinpath(repo, ".git")
        if isfile(gitdir)
            # A worktree or a submodule: `.git` is a file pointing at the real one.
            m = match(r"^gitdir:\s*(.+?)\s*$"m, read(gitdir, String))
            m === nothing && return ""
            to = m[1]::AbstractString   # the group is not optional
            gitdir = isabspath(to) ? String(to) : joinpath(repo, to)
        end
        isdir(gitdir) || return ""
        head = String(strip(read(joinpath(gitdir, "HEAD"), String)))
        # A detached HEAD holds the commit itself; otherwise it names a ref.
        startswith(head, "ref:") || return head
        ref = String(strip(head[5:end]))
        # A worktree's own directory holds its HEAD; the branches it names are in
        # the repository's, which `commondir` points at.
        common = joinpath(gitdir, "commondir")
        isfile(common) && (gitdir = abspath(gitdir, String(strip(read(common, String)))))
        loose = joinpath(gitdir, ref)
        isfile(loose) && return String(strip(read(loose, String)))
        packed = joinpath(gitdir, "packed-refs")
        isfile(packed) || return ""
        for line in eachline(packed)
            (isempty(line) || startswith(line, '#') || startswith(line, '^')) && continue
            parts = split(line)
            length(parts) >= 2 && parts[2] == ref && return String(parts[1])
        end
        return ""
    catch
        return ""
    end
end

# Identity of the project, so a run state from somewhere else is not mistaken for
# this project's: the UUID when there is one, else the name, else the name of its
# directory, which a checkout elsewhere usually shares. Nothing else of the project
# file: the rest changes with every dependency added, and each change would make
# every earlier run state another project's, never read again and never deleted.
function project_id(root::AbstractString)::String
    for name in PROJECT_NAMES
        path = joinpath(root, name)
        isfile(path) || continue
        proj = try
            TOML.parsefile(path)
        catch
            Dict{String, Any}()
        end
        haskey(proj, "uuid") && return string(proj["uuid"])
        haskey(proj, "name") && return string(proj["name"])
        return last(splitpath(abspath(root)))
    end
    return ""
end
