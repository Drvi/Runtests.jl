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
#   items       n_items x 16 B: name, file, line, unit
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

using CRC32c: crc32c
using Zlib_jll: libz

const RS_MAGIC = 0x544e5552   # "RUNT" on disk
const RS_VERSION = UInt32(7)
# 40 bytes of counts and times, then nine section offsets; the rest is room to
# add a field without moving every section.
const RS_HEADER_BYTES = 96
const RS_STATUS_BYTES = 32
const RS_MEMORY_BYTES = 64
const RS_EVENT_BYTES = 32

const RS_FLAG_COMPLETE = UInt32(1) << 0
const RS_FLAG_DRY_RUN = UInt32(1) << 1
const RS_FLAG_CANCELLED = UInt32(1) << 2

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
    len <= 1032 * length(data) || error("$(length(data)) compressed bytes cannot inflate to $len")
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
end

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
        "memory_bytes" => string(Sys.total_memory()),
        "coordinator_threads" => string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
        "environment_variables" => environment_variables(),
        "project_id" => project_id(p.root), "revision" => project_revision(p.root),
        "selection" => p.selection,
        "environment" => env, "environment_project" => read_text(env),
    ]
    for key in RUN_KEYS
        push!(meta, string(key) => key === :seed ? seed_text(cfg.seed) : string(run_setting(cfg, key)))
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
        write(profiles, intern!(strings, prof.threads))
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
            UInt32(p.items.line[i]), UInt32(p.items.unit[i])
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
    return RunStateFile(
        io, String(path), off_status, off_memory, UInt32(nitems(p)),
        ReentrantLock(), Ref{StatusRecord}(), Ref{EventRecord}()
    )
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

function finish_run_state!(rsf::Union{Nothing, RunStateFile}; cancelled::Bool = false)
    rsf === nothing && return nothing
    update!(io -> write(io, RS_FLAG_COMPLETE | (cancelled ? RS_FLAG_CANCELLED : UInt32(0))), rsf, header_offset(:flags))
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
    length(bytes) >= RS_HEADER_BYTES || return nothing
    io = IOBuffer(bytes)
    total = length(bytes)
    try
        h = read_record(io, Header)
        (h.magic == RS_MAGIC && h.version == RS_VERSION) || return nothing
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
        profiles, preferences = read_profiles_section(io, strings)

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
        items = map(1:min(bounded(read(io, UInt32), total), n_items)) do _
            r = read_record(io, ItemRecord)
            RunStateItem(lookup(strings, r.name), lookup(strings, r.file), Int32(r.line), Int32(r.unit))
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
            h.flags & RS_FLAG_DRY_RUN != 0, h.flags & RS_FLAG_CANCELLED != 0,
            h.start_unix, h.end_unix, meta, profiles, preferences, manifest_bytes, manifest_zlib,
            units, items, statuses, memory, events, truncated
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
        r.start_off, r.elapsed, r.compile, r.recompile, r.alloc_mb, r.peak_rss_mb, r.pid
    )
end

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
        len = Int(read(io, UInt32))
        at = position(io)
        at + len > total && break
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
        profiles[name] = Profile(name, args, threads, env, init, test_end, path)
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
    println(io, "  started ", started, took, rs.cancelled ? ", cancelled" : "")
    println(io, "  julia ", m("julia"), " (", first(m("julia_commit"), 10), ") · ", m("machine"), " · ",
        m("cpu_threads"), " CPU threads · ", fmt_gib(something(tryparse(Int, m("memory_bytes")), 0)), " · host ", m("host"))
    println(io, "  project ", m("project_id"), isempty(m("revision")) ? "" : string(" · rev ", first(m("revision"), 10)),
        " · Runtests ", m("runtests"), isempty(m("runtests_revision")) ? "" : string(" (", first(m("runtests_revision"), 10), ")"))
    println(io, "  seed ", m("seed"), " · workers ", m("workers"), " · threads ", m("threads"), " · timeout ", m("timeout"),
        "s · retries ", m("retries"), isempty(m("selection")) ? "" : string(" · selected ", m("selection")))
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
    for (it, st) in bad
        println(io, "    ", rpad(repr(it.name), 30), " ", rpad(string(st.state), 12), " attempt ", st.attempt,
            " · worker ", st.slot, " (pid ", st.pid, ") · ", fmt_seconds(st.elapsed), " · ", it.file, ":", it.line)
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
    return isempty(host) ? gethostname() : host
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
    if isempty(get(ENV, "RUNTESTS_RUNSTATE_DIR", ""))
        mkpath(dir)
        mark = joinpath(dir, PROJECT_MARK)
        isfile(mark) || write(mark, abspath(root))
    end
    stem = string(lpad(start_us, 16, '0'), "-", getpid())
    path = joinpath(dir, stem * ".runstate")
    n = 1
    while ispath(path)
        n += 1
        path = joinpath(dir, string(stem, "_", n, ".runstate"))
    end
    return path
end

wall_microseconds() = (tv = Libc.TimeVal(); tv.sec * 1_000_000 + tv.usec)

function runstate_files(root::AbstractString)
    dir = runstate_dir(root)
    isdir(dir) || return String[]
    files = filter!(endswith(".runstate"), readdir(dir; join = true))
    return sort!(files)   # names start with a unix timestamp, so this is oldest-first
end

const KEEP_RUNS = 20

# How many of the newest run states `history` reads recent failures from.
const HISTORY_RUNS = 5

# Whether a run state is this project's. The default directory holds one project's
# runs; one set by `RUNTESTS_RUNSTATE_DIR` can hold several.
of_project(rs::RunStateRecord, project::AbstractString) = get(rs.meta, "project_id", "") == project

# Only the run states this machine recorded for this project are pruned: the newest
# `keep` of them stay, and of the rest each that can go without changing which
# items are failing goes (`removable_runs`). One recorded elsewhere, a CI artifact
# downloaded into the directory say, one of another project, and one that cannot be
# read are never deleted: nothing shows they are ours.
function prune_runstates(root::AbstractString, keep::Int = KEEP_RUNS)
    here = run_host()
    runs = project_runs(root)
    ours = [f for (f, rs) in runs if get(rs.meta, "host", "") == here]
    for f in removable_runs(runs, ours[1:max(0, length(ours) - keep)])
        try
            rm(f; force = true)
        catch
        end
    end
    return nothing
end

# This project's run states that can be read, oldest first, each with its file.
# Ordered by when each run started, as the file records it, not by its name: a run
# state from elsewhere, renamed as it was downloaded say, counts from when it ran.
function project_runs(root::AbstractString)
    project = project_id(root)
    runs = Pair{String, RunStateRecord}[]
    for f in runstate_files(root)
        rs = read_run_state(f)
        (rs === nothing || !of_project(rs, project)) && continue
        push!(runs, f => rs)
    end
    return sort!(runs; by = ((f, rs),) -> (rs.start_unix, f))
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

# Item `i`'s verdict in a run: `true` when it did not pass, `false` when it passed or
# was skipped, and `nothing` when the run got none — it stopped before the item ran,
# or while it ran.
function verdict(rs::RunStateRecord, i::Integer)
    state = i <= length(rs.statuses) ? rs.statuses[i].state : UNSEEN
    (state === UNSEEN || state === CANCELLED) && return nothing
    return !(state === PASSED || state === SKIPPED)
end

# Whether a run was of the whole suite, and so lists every item the suite had: one
# missing from it had been renamed or deleted, and is no longer failing.
whole_suite(rs::RunStateRecord) = !rs.dry_run && get(rs.meta, "selection", nothing) == ""

"""
    removable_runs(runs, candidates) -> Vector{String}

Of `candidates`, files among `runs` (every run state of the project, oldest first),
those that can be deleted without changing which items are failing (see
[`failing_items`](@ref)). A run state stays while it holds an item's last verdict and
the verdict the item would fall back to without it reads differently: its last
failure, or a pass that keeps an older failure from counting again. A run of the
whole suite gives every item it did not find a verdict of its own, not failing.
Taken oldest first, so a run state is judged by what is left once the older ones
have gone.
"""
function removable_runs(runs::Vector{Pair{String, RunStateRecord}}, candidates)
    known = Set{String}(it.name for (_, rs) in runs for it in rs.items)
    verdicts = [Dict{String, Bool}() for _ in runs]   # per run: item => failing
    holders = Dict{String, Vector{Int}}()             # per item: the runs left with a verdict, oldest first
    for (k, (_, rs)) in enumerate(runs)
        for (i, it) in enumerate(rs.items)
            v = verdict(rs, i)
            v === nothing || (verdicts[k][it.name] = v)
        end
        if whole_suite(rs)
            found = Set(it.name for it in rs.items)
            for name in known
                name in found || (verdicts[k][name] = false)
            end
        end
        for name in keys(verdicts[k])
            push!(get!(Vector{Int}, holders, name), k)
        end
    end
    index = Dict(f => k for (k, (f, _)) in enumerate(runs))
    out = String[]
    for f in candidates
        k = index[f]
        keeps = any(verdicts[k]) do (name, failing)
            h = holders[name]
            last(h) == k || return false                  # a newer run has the item's verdict
            (length(h) >= 2 && verdicts[h[end - 1]][name]) != failing
        end
        keeps && continue
        push!(out, f)
        for name in keys(verdicts[k])
            filter!(!=(k), holders[name])
        end
    end
    return out
end

"""
    sweep_runstate_dirs(base = runstate_root())

Clear the default location of projects that are gone: in each directory whose
recorded project path no longer exists, delete this machine's run states, and then
the directory once nothing else is left in it. A run state recorded elsewhere, one
that cannot be read, and a directory without a recorded project stay: nothing shows
they are this machine's to delete. So does a project that is out of reach rather
than gone: one whose parent directory is missing or empty, as a drive that is not
mounted leaves it.
"""
function sweep_runstate_dirs(base::AbstractString = runstate_root())
    isdir(base) || return nothing
    here = run_host()
    for dir in readdir(base; join = true)
        mark = joinpath(dir, PROJECT_MARK)
        try
            isfile(mark) || continue
            project = String(strip(read(mark, String)))
            ispath(project) && continue
            parent = dirname(project)
            (isdir(parent) && !isempty(readdir(parent))) || continue
            for f in filter!(endswith(".runstate"), readdir(dir; join = true))
                rs = read_run_state(f)
                rs !== nothing && get(rs.meta, "host", "") == here && rm(f; force = true)
            end
            readdir(dir) == [PROJECT_MARK] && rm(dir; recursive = true, force = true)
        catch
            # A directory another process is writing or deleting is left for next time.
        end
    end
    return nothing
end

"""
    recent_runs(root, n) -> Vector{Pair{String, RunStateRecord}}

The newest `n` runs, oldest first, each with its file: this project's, readable,
and not dry runs, which ran nothing. The files of other projects in a shared
directory are passed over rather than counted.
"""
function recent_runs(root::AbstractString, n::Int)
    runs = filter!(((_, rs),) -> !rs.dry_run, project_runs(root))
    return runs[max(1, end - n + 1):end]
end

"""
    failing_items(root; names = nothing, base = nothing) -> Vector{String}

The items that are failing as the recorded runs leave them, sorted: for each item,
the last run in which it ran to a verdict decides, so running a few of one run's
failures again does not forget the rest. A verdict other than passed or skipped —
failed, errored, timed out, cut short by a dead worker, left running when the run
itself died — is failing. A run that stopped before reaching an item, or while
running it, says nothing about it, and the verdict before stands. An item that a
newer run of the whole suite did not find was renamed or deleted, and is not
failing whatever older runs say. With `names`, only those items, and the reading
stops once each has its verdict. With `base`, the run state a replay names, the
verdicts are its own and those of the runs that started after it.
"""
function failing_items(
        root::AbstractString; names::Union{Nothing, AbstractSet{String}} = nothing,
        base::Union{Nothing, RunStateRecord} = nothing
    )
    decided = Set{String}()
    failing = String[]
    alive = nothing   # the items every newer run of the whole suite found
    # Newest first, as far back as it takes: pruning keeps every run state an
    # item's failure rests on, however many runs ago.
    for (_, rs) in Iterators.reverse(since_base(runs_with(root, base), base))
        rs.dry_run && continue
        for (i, it) in enumerate(rs.items)
            (it.name in decided || (names !== nothing && !(it.name in names))) && continue
            v = verdict(rs, i)
            v === nothing && continue
            push!(decided, it.name)
            v && (alive === nothing || it.name in alive) && push!(failing, it.name)
        end
        if whole_suite(rs)
            found = Set(it.name for it in rs.items)
            alive = alive === nothing ? found : intersect!(alive, found)
            names === nothing || union!(decided, setdiff(names, alive))
        end
        names !== nothing && length(decided) == length(names) && break
    end
    return sort!(failing)
end

"""
    history(root; nruns = HISTORY_RUNS, base = nothing) -> History

Per-item durations from every run state kept, each item's newest that ran to an
end (see [`timed`](@ref)), so that runs of a few items leave the others' standing, and a
run stopped part way through leaves those it stopped. Last-run failures, when the newest run
started, and what a fresh worker cost, from the most recent `nruns`. With `base`,
the run state a replay names, those come from it and the runs after it only; the
durations still come from every run. Only items that actually ran contribute; a
name that has never been seen simply has no estimate and is scheduled as if it
were new.
"""
function history(root::AbstractString; nruns::Int = HISTORY_RUNS, base::Union{Nothing, RunStateRecord} = nothing)
    everything = filter!(((_, rs),) -> !rs.dry_run, runs_with(root, base))
    runs = last.(everything)
    isempty(runs) && return History()
    seconds = Dict{String, Float64}()
    # Oldest first, so a newer duration overwrites an older one.
    for rs in runs
        for (i, it) in enumerate(rs.items)
            i <= length(rs.statuses) || break
            st = rs.statuses[i]
            timed(st.state) && st.elapsed > 0 && (seconds[it.name] = Float64(st.elapsed))
        end
    end
    failed = Dict{String, Int}()
    since = 0.0
    counted = last.(since_base(everything, base))
    recent = counted[max(1, end - nruns + 1):end]
    for (k, rs) in enumerate(recent)
        ago = length(recent) - k
        since = rs.start_unix
        for (i, it) in enumerate(rs.items)
            i <= length(rs.statuses) || break
            st = rs.statuses[i]
            if st.state === UNSEEN
                # A cancelled run stopped before reaching these: the next run takes
                # them early, as it does what failed, so it picks up where that one
                # stopped.
                ago == 0 && rs.cancelled && (failed[it.name] = 0)
                continue
            end
            # Runs are read oldest first, so a newer failure overwrites an older one.
            is_non_pass(st.state) && (failed[it.name] = ago)
        end
    end
    return History(seconds, failed, since, recorded_cold_cost(recent))
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
    project_revision(root) -> String

The commit the tests run from, or `""`, so a run state (one downloaded from CI,
say) says what to check out. Read from `.git` rather than by running `git`, which
would put a subprocess between `runtests()` and the first item. It names the commit,
not the working tree: local edits do not change it.
"""
function project_revision(root::AbstractString)
    try
        gitdir = joinpath(root, ".git")
        if isfile(gitdir)
            # A worktree or a submodule: `.git` is a file pointing at the real one.
            m = match(r"^gitdir:\s*(.+?)\s*$"m, read(gitdir, String))
            m === nothing && return ""
            to = m[1]::AbstractString   # the group is not optional
            gitdir = isabspath(to) ? String(to) : joinpath(root, to)
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
