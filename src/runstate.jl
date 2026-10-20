# The run state file: binary, fixed-stride, written as the run goes, so that a
# killed coordinator still leaves behind which items passed and how long they took.
# It also holds what it takes to run the same run again elsewhere: a run state
# downloaded from CI and passed to `runtests(replay = path)` brings back the items,
# the configuration, the profiles and the seed, and says how the environment
# differs from the one it was recorded in.
#
# Layout:
#
#   header      96 B, fixed, holds the section offsets
#   strings     every string in the file, referenced by index
#   meta        key/value pairs of strings: platform, invocation, environment
#   profiles    name, julia args, threads, env, init, test_end, preferences path and content
#   units       n_units x 16 B: item span, profile, exclusive, chain
#   items       n_items x 32 B: name, file, line, unit, source hash, seed
#   environment the test environment's Manifest.toml, zlib-compressed: its length,
#               the compressed length, then the compressed bytes
#   statuses    n_items x 32 B, fixed stride, overwritten in place
#   memory      fixed block, rewritten whenever a peak is set
#   events      32 B each, appended: every attempt, and every worker's start and end
#
# After the run starts only the statuses, the memory block, the events and the
# header's flags and end time are written, which keeps a crash from corrupting
# anything else; a reader drops a torn last event.
#
# The manifest is most of a file's bytes, and only a replay reads it, so it is
# stored compressed and inflated only when asked for (`recorded_manifest`): the
# reads that plan every run pay nothing for it.
#
# Beside the file, a directory of the same name ending in `.logs` (`logs_dir`) holds
# what the items printed, `item_<index>_<attempt>.log`, the failure report of each
# attempt that did not pass, `item_<index>_<attempt>.failure.txt`, and `setup.log`
# for a run that ended before its first item. It is made with the file and deleted
# only with it.

using CRC32c: crc32c
using Zlib_jll: libz

const RS_MAGIC = 0x544e5552   # "RUNT" on disk
const RS_VERSION = UInt32(8)
# Every version this one reads. A new version keeps a reader for the one before it:
# a run state the reader passes over is history lost to the next run.
const RS_READABLE = (UInt32(7), UInt32(8))
# 40 bytes of counts and times, then nine section offsets; the rest is room to
# add a field without moving every section.
const RS_HEADER_BYTES = 96
const RS_STATUS_BYTES = 32
const RS_MEMORY_BYTES = 64
const RS_EVENT_BYTES = 32

const RS_FLAG_COMPLETE = UInt32(1) << 0
const RS_FLAG_DRY_RUN = UInt32(1) << 1
const RS_FLAG_CANCELLED = UInt32(1) << 2
# The run ended before its first item: its setup failed, or it was stopped there.
const RS_FLAG_ABORTED = UInt32(1) << 3

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
# The flags and the end time are rewritten in place when the run finishes, at the
# offsets this layout gives them.
struct Header
    magic::UInt32
    version::UInt32
    flags::UInt32
    n_items::UInt32
    n_units::UInt32
    n_profiles::UInt16
    pad::UInt16
    start_unix::Float64
    end_unix::Float64
    off_strings::UInt32
    off_meta::UInt32
    off_profiles::UInt32
    off_units::UInt32
    off_items::UInt32
    off_status::UInt32
    off_memory::UInt32
    off_events::UInt32
    off_environment::UInt32
end
@assert sizeof(Header) <= RS_HEADER_BYTES

header_offset(field::Symbol) = Int(fieldoffset(Header, Base.fieldindex(Header, field)))

# One item's place in the plan, and one unit's, as they sit on disk.
struct ItemRecord
    name::UInt32
    file::UInt32
    line::UInt32
    unit::UInt32
    hash::UInt32   # see `RawItem`
    pad::UInt32
    seed::UInt64   # the seed the item's numbers came from, mixed with its name
end
@assert sizeof(ItemRecord) == 32

# An item as version 7 stored it: no source hash, and the run's seed for every item.
struct ItemRecord7
    name::UInt32
    file::UInt32
    line::UInt32
    unit::UInt32
end

# Sixteen bytes, two of them padding after `exclusive`: the compiler's layout, so
# it cannot drift from the struct.
struct UnitRecord
    first::UInt32
    last::UInt32
    profile::UInt8
    exclusive::UInt8
    chain::UInt32
end

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
end
@assert sizeof(EventRecord) == RS_EVENT_BYTES

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
    # Keeps the file's modification time fresh while the run lasts; see `is_live`.
    heartbeat::Base.RefValue{Union{Nothing, Tuple{Timer, Task}}}
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

# The run settings a replay puts back, with how each is read out of the file. What
# only changes how a run is presented is recorded but not replayed.
const REPLAYED_SETTINGS = (
    :workers => s -> parse(Int, s), :threads => identity,
    :timeout => s -> parse(Int, s), :init_timeout => s -> parse(Int, s),
    :test_end_timeout => s -> parse(Int, s), :retries => s -> parse(Int, s),
    :failfast => s -> parse(Bool, s), :item_failfast => s -> parse(Bool, s),
    :logs => Symbol, :memory_threshold => s -> parse(Float64, s),
    :seed => s -> parse(UInt64, s),
)

run_setting(cfg::RunConfig, key::Symbol) =
    key === :timeout ? cfg.timeout_s : key === :init_timeout ? cfg.init_timeout_s :
    key === :test_end_timeout ? cfg.test_end_timeout_s : getfield(cfg, key)

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
    for key in RUN_KEYS
        push!(meta, string(key) => key === :seed ? seed_text(cfg.seed) : string(run_setting(cfg, key)))
    end
    # Where each profile that names an environment found it: in the project, as the
    # project's path, so that a replay elsewhere finds it in its own checkout.
    for prof in p.profiles
        isempty(prof.environment) ||
            push!(meta, string(PROFILE_ENVIRONMENT, prof.name) => relpath_or_path(prof.environment, p.root))
    end
    push!(meta, "order_first" => join(cfg.order_first, '\n'), "order_last" => join(cfg.order_last, '\n'))
    return meta
end

# The active environment's manifest, which the file keeps in a section of its own.
function environment_manifest()
    env = Base.active_project()
    return env === nothing ? "" : read_text(Base.project_file_manifest_path(env))
end

"""
    init_run_state(path, plan; dry_run=false, start=time()) -> RunStateFile

Write everything that is known before the run starts, including a full status
section of `unseen` records, so that every later write is an overwrite at a
known offset. `start` is the moment every offset in the file counts from.
"""
function init_run_state(path::AbstractString, p::Plan; dry_run::Bool = false, start::Float64 = time())
    mkpath(dirname(path))
    io = open(path, "w+")
    strings = StringTable()
    # Two per item — its name and its file — plus the profiles and the metadata.
    sizehint!(strings.index, 2 * nitems(p) + 64)
    sizehint!(strings.order, 2 * nitems(p) + 64)

    profiles = IOBuffer()
    write(profiles, UInt32(length(p.profiles)))
    for prof in p.profiles
        write(profiles, intern!(strings, string(prof.name)))
        write(profiles, UInt32(length(prof.julia_args)))
        for a in prof.julia_args
            write(profiles, intern!(strings, a))
        end
        # As configured, empty for the run's: a replay asked for other threads gives
        # them to the profiles that take the run's.
        write(profiles, intern!(strings, p.cfg.profiles[prof.name].threads))
        write(profiles, UInt32(length(prof.env)))
        for (k, v) in prof.env
            write(profiles, intern!(strings, k))
            write(profiles, intern!(strings, v))
        end
        write(profiles, intern!(strings, expr_text(prof.init)))
        write(profiles, intern!(strings, expr_text(prof.test_end)))
        write(profiles, intern!(strings, prof.preferences))
        # The content too: the path is one on the machine that ran it.
        write(profiles, intern!(strings, read_text(prof.preferences)))
    end

    units = IOBuffer()
    write(units, UInt32(length(p.units)))
    uref = Ref{UnitRecord}()
    for u in 1:length(p.units)
        span = p.units.span[u]
        uref[] = UnitRecord(
            UInt32(first(span)), UInt32(last(span)), UInt8(p.units.profile[u]),
            UInt8(p.units.exclusive[u]), intern!(strings, string(p.units.chain[u]))
        )
        write_record(units, uref)
    end

    items = IOBuffer()
    write(items, UInt32(nitems(p)))
    iref = Ref{ItemRecord}()
    for i in 1:nitems(p)
        iref[] = ItemRecord(
            intern!(strings, p.items.name[i]), intern!(strings, itemfile(p, i)),
            UInt32(p.items.line[i]), UInt32(p.items.unit[i]), p.items.hash[i], UInt32(0), p.items.seed[i]
        )
        write_record(items, iref)
    end

    meta = IOBuffer()
    pairs_ = run_meta(p)
    write(meta, UInt32(length(pairs_)))
    for (k, v) in pairs_
        write(meta, intern!(strings, k), intern!(strings, v))
    end

    strbuf = IOBuffer()
    write_strings(strbuf, strings)

    manifest = Vector{UInt8}(environment_manifest())
    packed = isempty(manifest) ? UInt8[] : zlib_compress(manifest)
    environment = IOBuffer()
    write(environment, UInt32(length(manifest)), UInt32(length(packed)), packed)

    off_strings = UInt32(RS_HEADER_BYTES)
    off_meta = off_strings + UInt32(strbuf.size)
    off_profiles = off_meta + UInt32(meta.size)
    off_units = off_profiles + UInt32(profiles.size)
    off_items = off_units + UInt32(units.size)
    off_environment = off_items + UInt32(items.size)
    off_status = off_environment + UInt32(environment.size)
    off_memory = off_status + UInt32(RS_STATUS_BYTES * nitems(p))
    off_events = off_memory + UInt32(RS_MEMORY_BYTES)

    write_record(io, Ref(Header(
        RS_MAGIC, RS_VERSION, dry_run ? RS_FLAG_DRY_RUN : UInt32(0), nitems(p), length(p.units),
        length(p.profiles), 0, start, 0.0, off_strings, off_meta, off_profiles, off_units,
        off_items, off_status, off_memory, off_events, off_environment
    )))
    write(io, zeros(UInt8, RS_HEADER_BYTES - sizeof(Header)))
    write(io, take!(strbuf)); write(io, take!(meta)); write(io, take!(profiles))
    write(io, take!(units)); write(io, take!(items)); write(io, take!(environment))
    blank = Ref{StatusRecord}()
    for _ in 1:nitems(p)
        write_status_record(
            io, blank, UNSEEN, Int8(0), SlotIdx(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0
        )
    end
    write(io, zeros(UInt8, RS_MEMORY_BYTES))
    flush(io)
    rsf = RunStateFile(
        io, String(path), off_status, off_memory, UInt32(nitems(p)),
        ReentrantLock(), Ref{StatusRecord}(), Ref{EventRecord}(), Ref{Union{Nothing, Tuple{Timer, Task}}}(nothing)
    )
    rsf.heartbeat[] = start_heartbeat(rsf)
    return rsf
end

# While the run lasts, its file is written at least every `HEARTBEAT_S`: the magic
# number, rewritten in place with the value it has, so that a beat changes no byte,
# and one landing in a file a pruner deleted harms nothing. Its own task, which hands
# an interrupt on, as the stall watchdog's does.
function start_heartbeat(rsf::RunStateFile)
    timer = Timer(HEARTBEAT_S; interval = HEARTBEAT_S)
    task = shielded(() -> @async beat(rsf, timer))
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
# treats a record it cannot make sense of as `unseen`.
function update!(f, rsf::Union{Nothing, RunStateFile}, at::Integer)
    rsf === nothing && return nothing
    @lock rsf.lock try
        # Closed means the run is over; a worker that exits after that has nothing
        # left to add to it.
        isopen(rsf.io) || return nothing
        at < 0 ? seekend(rsf.io) : seek(rsf.io, at)
        f(rsf.io)
        flush(rsf.io)
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: could not write the run state" exception = e maxlog = 1
    end
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
        seq::Integer = 0
    )
    update!(rsf, -1) do io
        rsf.event_ref[] = EventRecord(
            kind, UInt8(state), Int8(attempt), 0x00, Int16(slot), Int16(seq), Int32(item), Int32(pid),
            Float32(t0), Float32(t1), Int32(exitcode), Int32(signal)
        )
        write_record(io, rsf.event_ref)
    end
end

write_memory!(rsf::Union{Nothing, RunStateFile}, m) = update!(rsf, rsf === nothing ? 0 : rsf.off_memory) do io
    write(io, Float32(m.peak_total_bytes / 2^20), Float32(m.peak_total_at), Float32(m.peak_single_bytes / 2^20))
    write(io, Int32(m.peak_single_pid), Float32(phase_peak(m, PHASE_SETUP) / 2^20))
    write(io, Float32(phase_peak(m, PHASE_TEST) / 2^20), Int32(m.nprocs_peak))
end

# `exiting`, from the exit hook, which waits neither on a task nor on the event loop:
# there the beat's timer is left running, since closing a timer waits for the event
# loop to close it, and the beat ends at its next tick, finding the file closed.
# Stopped and waited for otherwise, so that nothing is written once this returns.
# `aborted` for a run that ended before its first item.
function finish_run_state!(rsf::Union{Nothing, RunStateFile}; cancelled::Bool = false, exiting::Bool = false,
                           aborted::Bool = false)
    rsf === nothing && return nothing
    beating = rsf.heartbeat[]
    if beating !== nothing
        rsf.heartbeat[] = nothing
        exiting || (close(first(beating)); wait(last(beating)))
    end
    flags = RS_FLAG_COMPLETE | (cancelled ? RS_FLAG_CANCELLED : UInt32(0)) | (aborted ? RS_FLAG_ABORTED : UInt32(0))
    update!(io -> write(io, flags), rsf, header_offset(:flags))
    update!(io -> write(io, time()), rsf, header_offset(:end_unix))
    @lock rsf.lock close(rsf.io)
    return nothing
end

### Reading ################################################################

struct RunStateItem
    name::String
    file::String
    line::Int32
    unit::Int32
    hash::UInt32   # 0 when not recorded
    seed::UInt64
end

struct RunStateUnit
    span::UnitRange{Int32}
    profile::Int32
    exclusive::Bool
    chain::Symbol
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
end

struct RunStateRecord
    path::String
    version::UInt32
    complete::Bool
    dry_run::Bool
    cancelled::Bool
    aborted::Bool       # ended before its first item; see `RS_FLAG_ABORTED`
    start_unix::Float64
    end_unix::Float64
    meta::Dict{String, String}
    profiles::Dict{Symbol, Profile}
    preferences::Dict{Symbol, String}   # profile name => its preferences file's content, as recorded
    manifest_bytes::Int                 # the recorded manifest's length, inflated
    manifest_zlib::Vector{UInt8}        # the manifest as stored; see `recorded_manifest`
    units::Vector{RunStateUnit}
    items::Vector{RunStateItem}
    statuses::Vector{RunStateStatus}
    memory::@NamedTuple{peak_total_mb::Float32, peak_total_at::Float32, peak_single_mb::Float32,
        peak_single_pid::Int32, setup_peak_mb::Float32, test_peak_mb::Float32, nprocs_peak::Int32}
    events::Vector{RunStateEvent}
    truncated::Bool
    mtime::Float64      # when the file was last written, as it was read; see `is_live`
end

"""
    is_live(rs; now = time()) -> Bool

Whether the run that wrote `rs` is still going, as far as its file can say: it has
not finished, its file was written in the last `LIVE_S` seconds, which a running
one's always is (`start_heartbeat`), and the process that wrote it is not known to
be gone (`writer_gone`). Another process's run state can be read part
way through. A live one's verdicts are not in yet, and an item it holds as `running`
is being run, not one a run left so when it died; its finished items' durations are
as good as any.
"""
is_live(rs::RunStateRecord; now::Real = time()) = !rs.complete && now - rs.mtime < LIVE_S && !writer_gone(rs)

# Whether the process that wrote `rs` is known to have exited, so that a run killed a
# moment ago counts as over at once rather than `LIVE_S` later: it ran on this
# machine, by its own hostname, not `RUNTESTS_HOST`, which names one machine across
# the CI runners that take turns being it and whose pids mean nothing here, and its
# pid is free. A pid another process has taken since says nothing either way.
function writer_gone(rs::RunStateRecord)
    get(rs.meta, "hostname", "") in (machine_name(), gethostname()) || return false
    pid = tryparse(Int32, get(rs.meta, "pid", ""))
    pid === nothing && return false
    return ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == Base.UV_ESRCH
end

"""
    read_run_state(path) -> Union{Nothing,RunStateRecord}

Read a run state file. Never throws: a file that is truncated, from a crashed
run, or written by a different version comes back as much as can be read (or
`nothing`), because a broken record of an old run must not stop a new one.
"""
function read_run_state(path::AbstractString)
    bytes = try
        read(path)
    catch
        return nothing
    end
    written = mtime(path)
    length(bytes) >= RS_HEADER_BYTES || return nothing
    io = IOBuffer(bytes)
    total = length(bytes)
    try
        h = read_record(io, Header)
        (h.magic == RS_MAGIC && h.version in RS_READABLE) || return nothing
        n_items = bounded(h.n_items, total)

        seek(io, Int(h.off_strings))
        strings = read_strings(io, bytes)
        seek(io, Int(h.off_meta))
        meta = Dict{String, String}()
        for _ in 1:bounded(read(io, UInt32), total)
            k = lookup(strings, read(io, UInt32))
            meta[k] = lookup(strings, read(io, UInt32))
        end

        seek(io, Int(h.off_profiles))
        profiles, preferences = read_profiles_section(io, strings, meta)

        seek(io, Int(h.off_units))
        # A `Symbol` per chain name, not per unit: nearly every unit has the same one.
        chains = Dict{UInt32, Symbol}()
        units = map(1:bounded(read(io, UInt32), total)) do _
            r = read_record(io, UnitRecord)
            chain = get(chains, r.chain, nothing)
            chain === nothing && (chain = chains[r.chain] = Symbol(lookup(strings, r.chain)))
            RunStateUnit(Int32(r.first):Int32(r.last), Int32(r.profile), r.exclusive != 0, chain)
        end

        seek(io, Int(h.off_items))
        run_seed = something(tryparse(UInt64, get(meta, "seed", "")), UInt64(0))
        items = map(1:min(bounded(read(io, UInt32), total), n_items)) do _
            if h.version == 7
                r7 = read_record(io, ItemRecord7)
                RunStateItem(lookup(strings, r7.name), lookup(strings, r7.file), Int32(r7.line), Int32(r7.unit),
                             UInt32(0), run_seed)
            else
                r = read_record(io, ItemRecord)
                RunStateItem(lookup(strings, r.name), lookup(strings, r.file), Int32(r.line), Int32(r.unit),
                             r.hash, r.seed)
            end
        end

        # Kept as stored: inflating it is for whoever asks for it.
        seek(io, Int(h.off_environment))
        manifest_bytes = Int(read(io, UInt32))
        manifest_zlib = read(io, bounded(read(io, UInt32), total))

        statuses = sizehint!(RunStateStatus[], n_items)
        truncated = false
        for i in 1:n_items
            at = Int(h.off_status) + (i - 1) * RS_STATUS_BYTES
            if at + RS_STATUS_BYTES > total
                truncated = true
                push!(statuses, RunStateStatus(UNSEEN, Int8(0), Int16(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, Int32(0)))
                continue
            end
            seek(io, at)
            push!(statuses, read_status_record(io))
        end

        memory = if Int(h.off_memory) + 28 <= total
            seek(io, Int(h.off_memory))
            (; peak_total_mb = read(io, Float32), peak_total_at = read(io, Float32), peak_single_mb = read(io, Float32),
                peak_single_pid = read(io, Int32), setup_peak_mb = read(io, Float32), test_peak_mb = read(io, Float32),
                nprocs_peak = read(io, Int32))
        else
            truncated = true
            (; peak_total_mb = 0.0f0, peak_total_at = 0.0f0, peak_single_mb = 0.0f0, peak_single_pid = Int32(0),
                setup_peak_mb = 0.0f0, test_peak_mb = 0.0f0, nprocs_peak = Int32(0))
        end

        at = Int(h.off_events)
        events = sizehint!(RunStateEvent[], max(0, total - at) ÷ RS_EVENT_BYTES)
        while at + RS_EVENT_BYTES <= total
            seek(io, at)
            e = read_record(io, EventRecord)
            kind = e.kind == EVENT_ATTEMPT ? :attempt : e.kind == EVENT_WORKER_UP ? :worker_up :
                e.kind == EVENT_WORKER_DOWN ? :worker_down : :unknown
            state = kind === :attempt && e.state <= UInt8(CANCELLED) ? ItemState(e.state) : UNSEEN
            ended_by = kind === :worker_down ? worker_end(e.state) : :none
            push!(events, RunStateEvent(kind, state, ended_by, e.attempt, e.seq, e.slot, e.item, e.pid, e.t0, e.t1, e.exitcode, e.signal))
            at += RS_EVENT_BYTES
        end
        return RunStateRecord(
            String(path), h.version, h.flags & RS_FLAG_COMPLETE != 0,
            h.flags & RS_FLAG_DRY_RUN != 0, h.flags & RS_FLAG_CANCELLED != 0, h.flags & RS_FLAG_ABORTED != 0,
            h.start_unix, h.end_unix, meta, profiles, preferences, manifest_bytes, manifest_zlib,
            units, items, statuses, memory, events, truncated, written
        )
    catch e
        is_interrupt(e) && rethrow()
        # Any exception, not a list of expected ones: the caller has a run to finish
        # and no use for a file it cannot read. Reader bugs still surface, because
        # the round-trip tests assert on what a written file reads back as.
        # `JULIA_DEBUG=Runtests` shows what went wrong.
        @debug "Runtests: could not read run state $(path)" exception = (e, catch_backtrace())
        return nothing
    end
end

"""
    recorded_manifest(rs) -> String

The test environment's `Manifest.toml` as the run recorded it: `""` when it
recorded none, or when the stored copy does not inflate to what it should.
"""
function recorded_manifest(rs::RunStateRecord)
    rs.manifest_bytes == 0 && return ""
    try
        return String(zlib_uncompress(rs.manifest_zlib, rs.manifest_bytes))
    catch e
        is_interrupt(e) && rethrow()
        @debug "Runtests: the manifest recorded in $(rs.path) is unreadable" exception = e
        return ""
    end
end

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

# The meta key under which a profile's environment is recorded, the profile's name
# after it. The profiles section has no room for it, and its layout is the format's.
const PROFILE_ENVIRONMENT = "profile_environment."

function read_profiles_section(io::IO, strings, meta::Dict{String, String} = Dict{String, String}())
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
        environment = get(meta, string(PROFILE_ENVIRONMENT, name), "")
        profiles[name] = Profile(name, args, threads, env, init, test_end, path, environment)
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
    println(io, "Runtests run state ", rs.path, rs.complete ? "" : " (incomplete: the run did not finish)")
    took = rs.end_unix > rs.start_unix ? string(", took ", fmt_seconds(rs.end_unix - rs.start_unix)) : ""
    # A damaged file's start is no time a clock can show.
    started = abs(rs.start_unix) < 1.0e12 ? Libc.strftime("%Y-%m-%d %H:%M:%S", rs.start_unix) : string(rs.start_unix)
    println(io, "  started ", started, took, rs.cancelled ? ", cancelled" : "", rs.aborted ? ", ended before its first item" : "")
    println(io, "  julia ", m("julia"), " (", first(m("julia_commit"), 10), ") · ", m("machine"), " · ",
        m("cpu_threads"), " CPU threads · ", fmt_gib(something(tryparse(Int64, m("memory_bytes")), 0)), " · host ", m("host"))
    println(io, "  project ", m("project_id"), isempty(m("revision")) ? "" : string(" · rev ", first(m("revision"), 10)),
        " · Runtests ", m("runtests"), isempty(m("runtests_revision")) ? "" : string(" (", first(m("runtests_revision"), 10), ")"))
    flags = nondefault_flags(split(m("julia_flags")))
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
    # Paired by `zip`: a damaged file can hold fewer items than statuses.
    bad = [(it, st) for (it, st) in zip(rs.items, rs.statuses) if is_non_pass(st.state) || st.state === RUNNING]
    isempty(bad) || println(io, "  not passed:")
    prefix = joinpath(logs_dir(rs.path), "item_")
    for (it, st) in bad
        println(io, "    ", rpad(repr(it.name), 30), " ", rpad(string(st.state), 12), " attempt ", st.attempt,
            " · worker ", st.slot, " (pid ", st.pid, ") · ", fmt_seconds(st.elapsed), " · ", it.file, ":", it.line)
        i = findfirst(x -> x === it, rs.items)
        kept = filter(isfile, [failure_path(prefix, i, max(st.attempt, 1)), item_log_path(prefix, i, max(st.attempt, 1))])
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
    print(io, "  run it again with Runtests.runtests(replay = ", repr(rs.path), ")")
    any(((it, st),) -> is_non_pass(st.state) && st.state !== CANCELLED, zip(rs.items, rs.statuses)) &&
        print(io, ", or its failing items with Runtests.runtestsf(replay = ", repr(rs.path), ")")
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
function recorded_here(rs::RunStateRecord)
    host = get(rs.meta, "host", "")
    host == run_host() && return true
    return isempty(get(ENV, "RUNTESTS_HOST", "")) && host == gethostname()
end

"""
    runstate_dir(root) -> String

`\$RUNTESTS_RUNSTATE_DIR` when set, otherwise a directory of the depot's own keyed by
the project path, so nothing lands in the repository, and named for the project as
well, so a person can tell which is whose. Not under `scratchspaces/`:
`Pkg.gc`, which `Pkg` also runs after its own operations, deletes every directory
there that no package has registered, and with it the history that orders the
next run. The path is printed at the end of a run so CI can upload it.
"""
function runstate_dir(root::AbstractString)
    dir = get(ENV, "RUNTESTS_RUNSTATE_DIR", "")
    isempty(dir) || return dir
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
# tells `sweep_runstate_dirs` whether the project is still there.
const PROJECT_MARK = "project"

# Named for the microsecond the run started, in 16 digits (enough until the year
# 2286), so that names sort oldest first: one process starts its runs one after
# another, milliseconds apart at the least, so its names never tie. The pid tells
# apart processes that start in the same microsecond, which leaves nothing to
# order. The wall clock, not `time_ns`, which restarts with the machine. A file
# already there, a run state downloaded from CI say, is never written over: the new
# name takes a suffix instead.
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
        path = joinpath(dir, n == 1 ? stem * ".runstate" : string(stem, "_", n, ".runstate"))
        # Created, not checked for: two processes that name a file the same, in
        # containers sharing the directory say, get one each.
        claimed = try
            close(Base.Filesystem.open(path, Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_EXCL | Base.Filesystem.JL_O_WRONLY, 0o644))
            true
        catch e
            (e isa Base.IOError && e.code == Base.UV_EEXIST) || rethrow()
            false
        end
        claimed && return path
        n += 1
    end
end

wall_microseconds() = (tv = Libc.TimeVal(); tv.sec * 1_000_000 + tv.usec)

function runstate_files(root::AbstractString)
    dir = runstate_dir(root)
    # Another process can delete the directory between any two calls.
    files = try
        filter!(endswith(".runstate"), readdir(dir; join = true))
    catch e
        e isa Base.IOError || rethrow()
        return String[]
    end
    return sort!(files)   # names start with a unix timestamp, so this is oldest-first
end

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
(see [`removable_runs`](@ref)). One recorded elsewhere, a CI artifact downloaded
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

# On CI each job is a new machine to its hostname, so a directory of run states that a
# cache brings back from job to job gains files and never loses any, unless
# `RUNTESTS_HOST` names the machine the jobs take turns being. Said once a session for
# each directory, when it holds run states of other machines.
const WARNED_HOSTS = Set{String}()
function warn_unnamed_ci_host(dir::AbstractString)
    get(ENV, "CI", "") in ("true", "1") && isempty(get(ENV, "RUNTESTS_HOST", "")) || return nothing
    first_time = @lock WARNED_FORMATS_LOCK (dir in WARNED_HOSTS ? false : (push!(WARNED_HOSTS, dir); true))
    first_time || return nothing
    @warn "Runtests: $(relpath_or_path(dir)) holds run states of other machines, and `RUNTESTS_HOST` is not set: " *
        "on CI each job is a new machine, and what a cache brings back is never pruned. Set `RUNTESTS_HOST` to " *
        "one name for the jobs that share the cache"
    return nothing
end

# The directory of a run state's logs.
logs_dir(path::AbstractString) = string(chopsuffix(path, ".runstate"), ".logs")

# A run state and its logs, which go together. Another process may be reading them,
# or have deleted them already.
function remove_runstate(path::AbstractString)
    try
        rm(path; force = true)
        rm(logs_dir(path); force = true, recursive = true)
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

# This project's run states that can be read, oldest first, each with its file.
# Ordered by when each run started, as the file records it, not by its name: a run
# state from elsewhere, renamed as it was downloaded say, counts from when it ran.
function project_runs(root::AbstractString)
    project = project_id(root)
    runs = Pair{String, RunStateRecord}[]
    others = Dict{UInt32, Int}()   # format => how many files of a format this version does not read
    for f in runstate_files(root)
        rs = read_run_state(f)
        if rs === nothing
            v = runstate_version(f)
            v === nothing || v in RS_READABLE || (others[v] = get(others, v, 0) + 1)
            continue
        end
        of_project(rs, project) && push!(runs, f => rs)
    end
    isempty(others) || warn_other_formats(runstate_dir(root), others)
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

# The directories already warned about, once a session each: every read of the
# history comes past the same files.
const WARNED_FORMATS = Set{String}()
const WARNED_FORMATS_LOCK = ReentrantLock()

# A run state this version does not read is history the run goes without, which is
# said rather than left to be found out.
function warn_other_formats(dir::AbstractString, others::Dict{UInt32, Int})
    first_time = @lock WARNED_FORMATS_LOCK (dir in WARNED_FORMATS ? false : (push!(WARNED_FORMATS, dir); true))
    first_time || return nothing
    older = sum((n for (v, n) in others if v < first(RS_READABLE)); init = 0)
    newer = sum((n for (v, n) in others if v > last(RS_READABLE)); init = 0)
    what = String[]
    older > 0 && push!(what, string(plural(older, "run state"), " of an older format, which `Runtests.chores()` deletes"))
    newer > 0 && push!(what, string(plural(newer, "run state"), " written by a newer version of Runtests"))
    @warn "Runtests: $(relpath_or_path(dir)) holds $(join(what, " and ")); this version does not read them, " *
        "so the durations and failures they recorded are not used"
    return nothing
end

"""
    old_format_runstates(root) -> Vector{String}

The run states in the project's own directory of a format older than any this
version reads, which no later version reads either. Empty for a directory that
`RUNTESTS_RUNSTATE_DIR` names, which can hold other projects' files.
"""
function old_format_runstates(root::AbstractString)
    isempty(get(ENV, "RUNTESTS_RUNSTATE_DIR", "")) || return String[]
    return filter(runstate_files(root)) do f
        v = runstate_version(f)
        v !== nothing && v < first(RS_READABLE)
    end
end

# `project_runs`, with `base` among them, when there is one, wherever its file is:
# the run state a replay names.
function runs_with(root::AbstractString, base::Union{Nothing, RunStateRecord})
    runs = project_runs(root)
    (base === nothing || any(((f, _),) -> samefile(f, base.path), runs)) && return runs
    push!(runs, base.path => base)
    return sort!(runs; by = ((f, rs),) -> (rs.start_unix, f))
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
end
const NO_FACTS = ItemFacts(Int8(-1), UNSEEN, 0.0, 0.0f0, UInt64(0), 0.0, UInt32(0), 0.0, false)

is_failing(f::ItemFacts) = f.verdict == 1

"""
    item_facts(runs; base = nothing) -> Dict{String, ItemFacts}

Every item's facts from `runs`, oldest first as `project_runs` gives them. Durations
and source hashes come from every run but dry runs and those that ended before their
first item, a run another process is still in the middle of included: what it has
finished is finished. Verdicts and stops come from the runs that are over, and with
`base`, the run state a replay names, from it and the runs that started after it.
"""
function item_facts(runs::Vector{Pair{String, RunStateRecord}}; base::Union{Nothing, RunStateRecord} = nothing)
    facts = Dict{String, ItemFacts}()
    for (_, rs) in runs
        (rs.dry_run || rs.aborted) && continue
        counts = !is_live(rs) && (base === nothing || rs.start_unix >= base.start_unix)
        # Paired by index: a damaged file can hold fewer statuses than items.
        for i in 1:min(length(rs.items), length(rs.statuses))
            it, st = rs.items[i], rs.statuses[i]
            f = get(facts, it.name, NO_FACTS)
            v, state, at, ended, seed = f.verdict, f.state, f.verdict_at, f.verdict_end, f.seed
            seconds, hash, selected_at, unreached = f.seconds, f.hash, f.selected_at, f.unreached
            timed(st.state) && st.elapsed > 0 && (seconds = Float64(st.elapsed))
            (st.state === UNSEEN || st.state === RUNNING || st.state === CANCELLED) || (hash = it.hash)
            if counts
                found = verdict(rs, i)
                if found !== nothing
                    v, state, at, ended, seed = Int8(found), st.state, rs.start_unix, st.start_off + st.elapsed, it.seed
                end
                selected_at = rs.start_unix
                unreached = rs.cancelled && (st.state === UNSEEN || st.state === CANCELLED)
            end
            facts[it.name] = ItemFacts(v, state, at, ended, seed, seconds, hash, selected_at, unreached)
        end
    end
    return facts
end

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
    kept = copy(runs)
    now = kept_facts(item_facts(kept), names)
    out = String[]
    for f in candidates
        k = findfirst(((g, _),) -> g == f, kept)
        k === nothing && continue
        without = deleteat!(copy(kept), k)
        kept_facts(item_facts(without), names) == now || continue
        push!(out, f)
        kept = without
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
temporary files, delete this machine's run states and their logs, and those of a
format older than any this version reads, and then the directory once nothing else
is left in it. With `fix = false` it deletes nothing and says what it would. A run
state recorded elsewhere, one that cannot be read otherwise, and a directory without
a recorded project stay: nothing shows they are this machine's to delete. So does a
project that is out of reach rather than gone: one whose parent directory is missing
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
        files = [joinpath(dir, f) for f in entries if endswith(f, ".runstate")]
        in_temp || time() - maximum(mtime, files; init = 0.0) >= SWEEP_GRACE_S || return nothing
        deleted = filter(files) do f
            rs = read_run_state(f)
            rs === nothing ? something(runstate_version(f), typemax(UInt32)) < first(RS_READABLE) :
                recorded_here(rs) && !is_live(rs)
        end
        going = Set(basename(f) for f in deleted)
        union!(going, (basename(logs_dir(f)) for f in deleted))
        whole = all(f -> f == PROJECT_MARK || is_folder_metadata(f) || f in going, entries)
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
    isempty(facts) && return History()
    over = [rs for (_, rs) in since_base(runs, base) if !rs.dry_run && !rs.aborted && !is_live(rs)]
    starts = sort!([rs.start_unix for rs in over])
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
    recent = sort(over; by = rs -> rs.start_unix)[max(1, end - nruns + 1):end]
    return History(seconds, failed, recorded_cold_cost(recent), cancelled, hashes, Set(keys(facts)))
end

"""
    timed(state) -> Bool

Whether the time recorded with an outcome is how long the item takes: not for one the
run stopped part way through (`cancelled`), whose time is how far it got, nor for one
that never ran (`unseen`, a chain's `broken` members).
"""
timed(state::ItemState) = !(state === UNSEEN || state === CANCELLED || state === BROKEN_CHAIN)

# What a fresh worker cost across `runs`: how long its process took to come up, and
# how much longer a process's first item spent compiling than its later ones did.
# 0 for what the runs did not record.
function recorded_cold_cost(runs::Vector{RunStateRecord})
    starts, start_s = 0, 0.0
    cold, cold_s, warm, warm_s = 0, 0.0, 0, 0.0
    for rs in runs
        seq = Dict{Tuple{Int32, Int8}, Int16}()   # (item, attempt) => where it came on its process
        for e in rs.events
            if e.kind === :attempt && e.seq > 0
                seq[(e.item, e.attempt)] = e.seq
            elseif e.kind === :worker_up && e.t1 > e.t0
                starts += 1
                start_s += e.t1 - e.t0
            end
        end
        for (i, st) in enumerate(rs.statuses)
            n = get(seq, (Int32(i), st.attempt), Int16(0))
            if n == 1
                cold += 1; cold_s += st.compile
            elseif n > 1
                warm += 1; warm_s += st.compile
            end
        end
    end
    return ColdCost(
        starts > 0 ? start_s / starts : 0.0,
        cold > 0 && warm > 0 ? max(0.0, cold_s / cold - warm_s / warm) : 0.0
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
