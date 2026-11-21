# Watching the machine while the tests run: how much memory *we* use, where, and
# when it was worst. Peaks are recorded as they happen, so a run that dies still
# leaves the answer behind. Best effort: if the monitor throws, it switches itself
# off, says so once, and the tests carry on.

using .Platform: process_rss, process_owners, child_lister, machine_memory, cpu_load, cpu_count,
    cpu_ticks, process_cpu_seconds, ensure_checked!, PER_PROCESS_OK

# The scan is over before the monitor exists. Resolving the environment and
# precompiling are one stage: the same process does both, back to back.
@enum RunPhase::UInt8 begin
    PHASE_SETUP = 0
    PHASE_TEST = 1
    PHASE_REPORT = 2
end

phase_name(p::RunPhase) =
    p === PHASE_SETUP ? "setup" : p === PHASE_TEST ? "testing" : "reporting"

struct Sample
    t::Float32     # seconds since the run started
    phase::RunPhase
    nprocs::Int16    # the whole tree: this process, its workers, and what they started
    nworkers::Int16  # of those, the live workers
    total_rss::Int64       # summed over our whole process tree
    largest_rss::Int64
    largest_pid::Int32
    machine_used::Int64
    machine_total::Int64
    load1::Float32     # one-minute load average
    # Where the platform has no load average (Windows): the machine's CPU use over the
    # last `CPU_WINDOW_S` seconds, in percent of its threads. -1 otherwise.
    cpu_pct::Float32
end

Sample() = Sample(0.0f0, PHASE_SETUP, 0, 0, 0, 0, 0, 0, 0, -1.0f0, -1.0f0)

# What one stage of a run cost. Per stage because the stages are different
# machines: one process resolving, a few short-lived ones precompiling, and the
# workers testing. `entered` and `starts` are written on the run's thread, the rest
# by the monitor's task; the monitor reads `entered`, so it is atomic, and `starts`
# is read only once the monitor has stopped.
mutable struct PhaseStats
    @atomic entered::Float64   # when the run entered this stage, 0 if it never did
    peak_total::Int64          # summed resident size over our processes
    peak_single::Int64
    # Processes alive at the sample that set `peak_total`, not the most ever alive:
    # maxima from different instants, printed side by side, contradict each other.
    nprocs_at_peak::Int
    workers_at_peak::Int       # of those, the live workers
    nprocs_peak::Int           # most processes ever sampled in this stage
    # Processes started during this stage. A stage that replaces a worker per item
    # churns through many more than are ever alive together.
    starts::Int
end

PhaseStats(; entered = 0.0, peak_total = 0, peak_single = 0, nprocs_at_peak = 0, workers_at_peak = 0,
           nprocs_peak = 0, starts = 0) =
    PhaseStats(entered, peak_total, peak_single, nprocs_at_peak, workers_at_peak, nprocs_peak, starts)

"""
    CpuReading

The machine's CPU time at one moment: milliseconds its threads have spent busy and
in all since boot, how many threads, this process's and its reaped children's CPU
seconds (-1 where the platform keeps no total for children), and when it was taken.
Two readings give how busy the run kept the machine, and how busy the machine was.
"""
struct CpuReading
    busy_ms::UInt64
    total_ms::UInt64
    threads::Int
    run_s::Float64
    at::Float64
end
CpuReading() = CpuReading(0, 0, 0, -1.0, 0.0)
cpu_reading() = CpuReading(cpu_ticks()..., process_cpu_seconds(), time())

"""
    MemStats

The aggregates worth having after the fact, per stage and for the whole run.
Summed resident sizes over-count the pages processes share (the runtime and every
package image), so a total is an upper bound, and is reported as one.
"""
Base.@kwdef mutable struct MemStats
    # One per `RunPhase`, indexed by `Int(phase) + 1`.
    phases::Vector{PhaseStats} = [PhaseStats() for _ in instances(RunPhase)]
    peak_total_bytes::Int64 = 0
    peak_total_at::Float64 = 0.0
    peak_single_bytes::Int64 = 0
    peak_single_pid::Int32 = 0
    nprocs_peak::Int = 0
    machine_peak_used::Int64 = 0
    machine_total::Int64 = 0
    guard_actions::Int = 0
    # Taken on the run's thread: the first before the monitor's task starts, the
    # second once it has stopped and the workers have exited and been reaped.
    cpu_start::CpuReading = CpuReading()
    cpu_end::CpuReading = CpuReading()
end

phase_stats(st::MemStats, p::RunPhase) = st.phases[Int(p) + 1]

"""
    phase_peak(stats, phase) -> Int

The peak summed resident size while the run was in `phase`, or 0 if it never was.
"""
phase_peak(st::MemStats, p::RunPhase) = phase_stats(st, p).peak_total

"""
    phase_seconds(stats, phase, finish) -> Float64

How long the run spent in `phase`: a stage ends when the next one begins, and the
last at `finish`. A run only moves forward, so one stamp per stage cannot disagree
with another.
"""
function phase_seconds(st::MemStats, p::RunPhase, finish::Float64)
    entered = phase_stats(st, p).entered
    entered == 0 && return 0.0
    ends = finish
    for other in st.phases
        other.entered > entered && other.entered < ends && (ends = other.entered)
    end
    return max(0.0, ends - entered)
end

"""
    Reading

What the monitor has measured, as of its newest sample, for readers on other
threads: the status line, which whoever prints redraws, and the report of a worker
that died. Built whole by the monitor's task and published through one atomic
field, so a reader sees one sample's figures together; the statistics and peaks it
is built from stay the monitor's own.
"""
struct Reading
    sample::Sample
    peak_total::Int64            # the run's peak, summed over its processes
    peak_single::Int64           # the largest any one of them has been
    phase_entered::Float64       # when the sample's stage began
    worker_peak::Vector{Int64}   # per slot, the largest its worker was sampled at; a copy
    worker_pid::Vector{Int32}    # and whose peak that is; a copy
    # Per slot, copies: its worker's tree, the worker and the processes under it, summed
    # at this sample; the largest that sum was over the attempt the slot held; and which
    # attempt that is (`attempt_key`).
    tree_rss::Vector{Int64}
    attempt_peak::Vector{Int64}
    attempt_key::Vector{Int64}
end

mutable struct Monitor
    # `Run` is defined after this, so the field cannot name its type; `run_of`
    # restores it, or every access from the sampling loop is a dynamic lookup.
    const run::Any
    const stats::MemStats
    last_sample::Sample
    # See `Reading`: the only way into what the monitor measures from another thread.
    @atomic reading::Reading
    task::Union{Nothing, Task}
    @atomic stop::Bool
    # Something else owns the terminal for a moment; sampling carries on, drawing
    # does not.
    @atomic quiet::Bool
    @atomic phase::RunPhase
    const interval::Float64
    const print_interval::Float64
    const tty::Bool
    # The terminal's width, or 0 when nothing is drawn. Erasing a line that wrapped
    # leaves all but its last row behind, so the status line is clipped to this.
    # Refreshed with the clock.
    columns::Int

    # Per slot, the largest resident size sampled for its current process, and that
    # process's pid: a new pid starts a new peak. The monitor's task alone writes
    # both; others read the peaks through `reading`.
    const worker_peak::Vector{Int64}
    const worker_pid::Vector{Int32}
    # Per slot, its worker's tree at the newest sample, and its peak over the attempt
    # `attempt_key` names: an attempt the slot holds for longer than a sample starts a
    # new peak. Written by the monitor's task alone, as the two above are.
    const tree_rss::Vector{Int64}
    const attempt_peak::Vector{Int64}
    const attempt_key::Vector{Int64}
    # Reusable scratch tables for the 5 Hz sampling loop (single-writer monitor task).
    const scratch_roots::Vector{Int32}
    const scratch_rss::Dict{Int32, Int64}
    const scratch_tree::Dict{Int32, Int64}
    # Where the status line is assembled, reused for the same reason. `lineio`
    # carries the colour setting into it: written to the buffer directly, every
    # `printstyled` in the line would come out plain.
    const linebuf::IOBuffer
    const lineio::IO
    const color::Bool
    # Second when `columns` was last refreshed (clock text itself comes from `clock_now`).
    clock_at::Int
    last_print::Float64
    next_print::Float64      # when the next scheduled report is due
    done_reported::Int       # the items finished at the last report
    last_mem_pct::Float64    # the machine's memory at the previous check
    const mark_said::Vector{Float64}   # when each of MEMORY_MARKS last reported
    last_cpu_pct::Float64    # the machine's CPU use (%) at the previous check
    cpu_mark_said::Float64   # when CPU >= 100% last triggered a status line
    last_phase_printed::RunPhase
    over_since::Float64      # when machine pressure first crossed the threshold
    last_gc::Float64
    last_restart::Float64
    # The CPU ticks at the start of the window `cpu_percent!` measures, when it started,
    # and the percentage of the last window that ended.
    cpu_window::Tuple{UInt64, UInt64}
    cpu_window_at::Float64
    cpu_pct::Float32
end

"""
    TTY_OVERRIDE

What [`is_tty`](@ref) answers when a test has decided: the drawing path exists
only on a terminal, and a test suite's output is a pipe.
"""
const TTY_OVERRIDE = ScopedValue{Union{Nothing, Bool}}(nothing)

# `displaysize` falls back to `COLUMNS` when the stream is not a terminal, which is
# how a test says how wide to pretend the screen is.
function terminal_columns(tty::Bool)
    tty || return 0
    io = stdout
    return io isa Base.TTY ? displaysize(io)[2] : displaysize()[2]
end

"""
    is_tty() -> Bool

Whether the run should draw a line that rewrites itself: that needs a terminal to
rewrite it and a reader watching. A pipe, a log file or a CI job gets the line
printed periodically instead.
"""
function is_tty()
    forced = TTY_OVERRIDE[]
    forced === nothing || return forced
    return stdout isa Base.TTY && !haskey(ENV, "CI") && get(ENV, "TERM", "") != "dumb"
end

function Monitor(run; interval = 0.2, print_interval = 30.0)
    tty = is_tty()
    color = get(stdout, :color, false)::Bool
    linebuf = IOBuffer()
    # The run is already in its first stage by the time it has a monitor — nothing
    # calls `set_phase!` to enter the one it starts in.
    stats = MemStats(; cpu_start = cpu_reading())
    entered = time()
    @atomic phase_stats(stats, PHASE_SETUP).entered = entered
    n = nslots(run.plan)
    return Monitor(
        run, stats, Sample(),
        Reading(Sample(), 0, 0, entered, zeros(Int64, n), zeros(Int32, n), zeros(Int64, n), zeros(Int64, n), zeros(Int64, n)),
        nothing, false, false,
        PHASE_SETUP, interval, print_interval, tty, terminal_columns(tty),
        zeros(Int64, n), zeros(Int32, n), zeros(Int64, n), zeros(Int64, n), zeros(Int64, n),
        Int32[], Dict{Int32, Int64}(), Dict{Int32, Int64}(),
        linebuf, IOContext(linebuf, :color => color), color, 0, 0.0, 0.0, 0, 0.0,
        zeros(Float64, length(MEMORY_MARKS)), 0.0, 0.0, PHASE_REPORT, 0.0, 0.0, 0.0, (UInt64(0), UInt64(0)), 0.0, -1.0f0
    )
end

# A window rather than the time since the last sample, a fifth of a second, which is
# noise: the load average it stands in for is a one-minute average.
const CPU_WINDOW_S = 10.0

# The machine's CPU use over the last window that ended, in percent of its threads, or
# -1 until one has. Reads the CPU ticks once a window.
function cpu_percent!(m::Monitor, now::Float64)
    now - m.cpu_window_at < CPU_WINDOW_S && return m.cpu_pct
    busy, total, _ = cpu_ticks()
    busy0, total0 = m.cpu_window
    m.cpu_window_at > 0 && total > total0 && busy >= busy0 &&
        (m.cpu_pct = Float32(100 * (busy - busy0) / (total - total0)))
    m.cpu_window, m.cpu_window_at = (busy, total), now
    return m.cpu_pct
end

# Counted rather than sampled: a sandbox worker can live and die between samples.
function count_worker_start!(m::Union{Nothing, Monitor})
    m === nothing && return nothing
    phase_stats(m.stats, @atomic m.phase).starts += 1
    return nothing
end

# What memory looked like when the worker `pid` in a slot was last seen: the largest
# it was sampled at, and the machine at the newest sample. Empty when nothing was
# measured; no peak when that worker died before a sample saw it.
function memory_note(m::Union{Nothing, Monitor}, slot::Integer, pid::Integer)
    m === nothing && return ""
    r = @atomic m.reading
    s = r.sample
    peak = r.worker_pid[slot] == pid ? r.worker_peak[slot] : 0
    return string(
        peak > 0 ? string(" · peak rss ", fmt_bytes(peak)) : "",
        s.machine_total > 0 ? string(" · machine ", round(Int, 100 * s.machine_used / s.machine_total), "% in use") : ""
    )
end

# Which attempt a slot holds, as one number: 0 for none.
attempt_key(i::Integer, attempt::Integer) = i == 0 ? Int64(0) : (Int64(i) << 8) | Int64(attempt & 0xff)

"""
    attempt_tree_rss(m, slot, i, attempt, pid) -> Int64

The most memory that the worker `pid` of `slot` and the processes under it held
together while the slot's attempt `attempt` at item `i` ran, as the monitor sampled
them: the largest sum over the samples of the attempt, or, for an attempt shorter than
the time between two samples, the sum at the newest sample of that worker. 0 without a
monitor or a sample of that worker.
"""
function attempt_tree_rss(m::Union{Nothing, Monitor}, slot::Integer, i::Integer, attempt::Integer, pid::Integer)
    m === nothing && return Int64(0)
    r = @atomic m.reading
    checkbounds(Bool, r.attempt_key, slot) || return Int64(0)
    r.attempt_key[slot] == attempt_key(i, attempt) && r.attempt_peak[slot] > 0 && return r.attempt_peak[slot]
    return r.worker_pid[slot] == pid ? r.tree_rss[slot] : Int64(0)
end

# Stamped by the run's own task as it enters a stage: one writer per field.
function set_phase!(m::Union{Nothing, Monitor}, p::RunPhase)
    m === nothing && return nothing
    @atomic phase_stats(m.stats, p).entered = time()
    @atomic m.phase = p
    return nothing
end

function start_monitor!(m::Monitor)
    try
        ensure_checked!()
    catch e
        is_interrupt(e) && rethrow()
        @warn "Runtests: per-process memory accounting is unavailable here" exception = e maxlog = 1
    end
    # A task keeps the logger of the scope that started it, and the monitor starts
    # before the run's own is in place: its warnings go through `printline` whoever
    # starts it, or they land on the status line it draws.
    logger = RunLogger(current_logger(), run_of(m))
    # Shielded: the run stops it, and it watches the run's teardown too.
    m.task = shielded() do
        Threads.@spawn with_logger(logger) do
            try
                monitor_loop(m)
            catch e
                # Ctrl-C, when this was the task its thread last ran: the run is
                # stopping, and needs no monitor to do it.
                is_interrupt(e) && return RuntestsWorkers.forward_interrupt(e)
                @warn "Runtests: the resource monitor stopped; the run continues without it" exception = e
            end
        end
    end
    return m
end

function stop_monitor!(m::Union{Nothing, Monitor})
    m === nothing && return nothing
    # Stopped and erased in one step under the lock every writer takes. A stopped
    # monitor is not drawing, so `printline` writes without erasing; with the line
    # still up, what the monitor's own task says on its way out would continue it.
    @lock run_of(m).printer begin
        @atomic m.stop = true
        clear_status_line(m)
    end
    task = m.task
    task === nothing || (
        try
            wait(task)
        catch
        end
    )
    return nothing
end

function monitor_loop(m::Monitor)
    while !m.stop
        sample!(m)
        maybe_print(m)
        guard!(m)
        sleep(m.interval)
    end
    sample!(m)
    return nothing
end

# Roots of our process tree: this process, plus every worker it has started and
# not seen end, including one still connecting or shutting down, which no slot holds.
# Their children — `Pkg`'s precompilation workers, anything a test item starts — are
# found from there, because they spend the same memory budget.
function tree_roots!(roots::Vector{Int32}, m::Monitor)
    empty!(roots)
    push!(roots, Int32(getpid()))
    append!(roots, RuntestsWorkers.live_worker_pids())
    # Each slot's worker heads its own tree, which its memory is counted by.
    for slot in run_of(m).slots
        w = @atomic slot.worker
        w === nothing || Int32(w.pid) in roots || push!(roots, Int32(w.pid))
    end
    return roots
end

function sample!(m::Monitor)
    t = Float32(time() - run_of(m).t0)
    phase = @atomic m.phase
    used, total = machine_memory()
    total_rss = Int64(0); largest = Int64(0); largest_pid = Int32(0); nprocs = 0; nworkers = 0
    if PER_PROCESS_OK[]
        roots = tree_roots!(m.scratch_roots, m)
        # One walk of the whole tree, each process with the worker it descends from, or
        # this process for what no worker started.
        rss_of = empty!(m.scratch_rss)
        tree_of = empty!(m.scratch_tree)
        for (pid, root) in process_owners(roots; children = child_lister())
            rss = process_rss(pid)
            rss <= 0 && continue
            rss_of[pid] = rss
            tree_of[root] = get(tree_of, root, Int64(0)) + rss
            nprocs += 1
            # Every root but this process is a worker.
            pid != first(roots) && pid == root && (nworkers += 1)
            total_rss += rss
            rss > largest && ((largest, largest_pid) = (rss, Int32(pid)))
        end
        for slot in run_of(m).slots
            w = @atomic slot.worker
            if w === nothing
                m.tree_rss[slot.id] = 0
                continue
            end
            pid = Int32(w.pid)
            if m.worker_pid[slot.id] != pid
                m.worker_pid[slot.id] = pid
                m.worker_peak[slot.id] = 0
            end
            rss = get(rss_of, pid, Int64(0))
            rss > m.worker_peak[slot.id] && (m.worker_peak[slot.id] = rss)
            # The worker with what it started, such as a build, so that an item's memory
            # is what running it took.
            tree = get(tree_of, pid, Int64(0))
            m.tree_rss[slot.id] = tree
            key = attempt_key(@atomic(slot.current), @atomic(slot.attempt))
            if key != m.attempt_key[slot.id]
                m.attempt_key[slot.id] = key
                m.attempt_peak[slot.id] = 0
            end
            key == 0 || tree <= m.attempt_peak[slot.id] || (m.attempt_peak[slot.id] = tree)
        end
    end
    load1 = Float32(cpu_load())
    cpu_pct = load1 >= 0 ? -1.0f0 : cpu_percent!(m, time())
    s = Sample(t, phase, Int16(nprocs), Int16(nworkers), total_rss, largest, largest_pid, used, total, load1, cpu_pct)
    m.last_sample = s
    update_stats!(m, s)
    st = m.stats
    @atomic m.reading = Reading(s, st.peak_total_bytes, st.peak_single_bytes,
                                (@atomic phase_stats(st, phase).entered), copy(m.worker_peak), copy(m.worker_pid),
                                copy(m.tree_rss), copy(m.attempt_peak), copy(m.attempt_key))
    return s
end

function update_stats!(m::Monitor, s::Sample)
    st = m.stats
    st.machine_total = s.machine_total
    s.machine_used > st.machine_peak_used && (st.machine_peak_used = s.machine_used)
    s.nprocs > st.nprocs_peak && (st.nprocs_peak = Int(s.nprocs))
    changed = false
    if s.total_rss > st.peak_total_bytes
        st.peak_total_bytes = s.total_rss
        st.peak_total_at = Float64(s.t)
        changed = true
    end
    if s.largest_rss > st.peak_single_bytes
        st.peak_single_bytes = s.largest_rss
        st.peak_single_pid = s.largest_pid
        changed = true
    end
    changed && write_memory!((@atomic run_of(m).runstate), st)
    # The stages are different memory regimes, and a figure for the whole run
    # hides which of them was the expensive one.
    ps = phase_stats(st, s.phase)
    if s.total_rss > ps.peak_total
        ps.peak_total = s.total_rss
        ps.nprocs_at_peak = Int(s.nprocs)
        ps.workers_at_peak = Int(s.nworkers)
    end
    s.largest_rss > ps.peak_single && (ps.peak_single = s.largest_rss)
    s.nprocs > ps.nprocs_peak && (ps.nprocs_peak = Int(s.nprocs))
    return nothing
end

# The run this monitor watches, with its type restored. See the note on the field.
run_of(m::Monitor) = m.run::Run

### Printing ###############################################################

# The unit changes over at a thousand of the smaller one, not at 1024, so that no
# figure is four digits wide.
const BYTES_PER_UNIT = 1000

"""
    print_bytes(io, b, width = 0)

Write `b` in one binary unit (`K`, `M` and `G` are 2^10, 2^20 and 2^30, as in
`du -h`), gibibytes to a decimal and the others whole, right-aligned in `width`
columns; 1000 to 1023 MiB reads `1.0G`. Padded here from the digits about to be
written, and without building strings: the status line writes three of these on
every redraw.
"""
function print_bytes(io::IO, b::Real, width::Integer = 0)
    if b <= 0
        pad_to(io, width, 1)
        write(io, UInt8('-'))
    elseif b >= BYTES_PER_UNIT * 2^20
        print_1dp(io, b / 2^30, width - 1)
        write(io, UInt8('G'))
    else
        mib = b >= BYTES_PER_UNIT * 2^10
        print_int(io, round(Int, b / (mib ? 2^20 : 2^10)), width - 1)
        write(io, UInt8(mib ? 'M' : 'K'))
    end
    return nothing
end

fmt_bytes(b::Real) = sprint(print_bytes, b)

# `x` to one decimal, right-aligned in `width`. Rounded on the scaled integer, so
# a tie lands on the even tenth.
function print_1dp(io::IO, x::Real, width::Integer = 0)
    isfinite(x) || (print(io, x); return nothing)
    tenths = round(Int, 10 * x)
    neg = tenths < 0
    neg && (tenths = -tenths)
    pad_to(io, width, ndigits(tenths ÷ 10) + 2 + neg)
    neg && write(io, UInt8('-'))
    print_int(io, tenths ÷ 10)
    write(io, UInt8('.'), UInt8('0') + UInt8(tenths % 10))
    return nothing
end

# Decimal digits straight to the stream; `print(io, n)` builds a string first.
function print_int(io::IO, n::Integer, width::Integer = 0)
    neg = n < 0
    neg && (n = -n)
    d = ndigits(n)
    pad_to(io, width, d + neg)
    neg && write(io, UInt8('-'))
    for k in (d - 1):-1:0
        write(io, UInt8('0') + UInt8((n ÷ 10^k) % 10))
    end
    return nothing
end

# How long the reporting stage has to take before it is worth a line of its own.
const REPORT_WORTH_SAYING = 1.0

# Who a stage's peak was summed over: this process, its workers, and whatever they
# started (the processes precompiling, or anything a test ran), each counted apart.
function procs_text(ps::PhaseStats)
    spawned = ps.nprocs_at_peak - 1 - ps.workers_at_peak
    return string(
        "coordinator",
        ps.workers_at_peak > 0 ? string(" + ", plural(ps.workers_at_peak, "worker")) : "",
        spawned > 0 ? string(" + ", spawned, " spawned") : ""
    )
end
# Four holds every figure up to `9.9G`; a bigger tree shifts the line by a column
# rather than every redraw carrying a blank one.
const TOTAL_WIDTH = 4     # "1.1G", "612M"
const BYTES_WIDTH = 5     # "12.3G"
const RUNNING_WIDTH = 28

# The workers field of the progress line: those up, of all there are.
function print_workers(io::IO, up::Integer, all::Integer)
    print(io, FIELD)
    print_int(io, up)
    write(io, UInt8('/'))
    print_int(io, all)
    print(io, " workers")
    return nothing
end

"""
    print_status_line(io, m)

The progress line, written straight to `io`. Every field is a fixed width and the
one variable-length field comes last and is clipped, so the line keeps its shape.
It is rebuilt after every line the run prints, so nothing formats through a
temporary string.
"""
function print_status_line(io::IO, m::Monitor)
    # Drawn by whichever task prints, on any thread: what the monitor measured
    # comes from its published reading, and the run's own counts are atomic.
    r = @atomic m.reading
    s = r.sample
    run = run_of(m)
    # While the precompile queue runs, the line counts its compiles and their failures
    # in place of the items', under its white square, and ends with the oldest compile
    # in flight.
    queued = @atomic QUEUE_PROGRESS.total
    total = queued > 0 ? queued : nitems(run.plan)
    done = queued > 0 ? (@atomic QUEUE_PROGRESS.done) : (@atomic run.ndone)
    failed = queued > 0 ? (@atomic QUEUE_PROGRESS.failed) : (@atomic run.nonpass)
    # The same shape as every other line in the log; `w0` is the coordinator.
    solo = single_process(run.plan)
    print_line_head(io, queued > 0 ? PRECOMPILE_MARK_INFO : MARK_INFO, solo ? nothing : 0, clock_text(m))
    print_word(io, "INFO")
    print_int(io, done, ndigits(total))
    write(io, UInt8('/'))
    print_int(io, total)
    print(io, FIELD)
    # Unpadded: on a healthy run it is one digit.
    print_int(io, failed)
    print(io, " failed")
    # Single pass over `run.slots`: live worker count, oldest running item, and any artifact collector.
    live_workers = 0
    oldest = ItemIdx(0)
    oldest_since = Inf32
    collecting = ItemIdx(0)
    for sl in run.slots
        (@atomic sl.worker) !== nothing && (live_workers += 1)
        ci = @atomic sl.current
        if ci != 0
            ts = @atomic sl.started
            ts == 0f0 && (ts = run.statuses.start[ci])
            if ts < oldest_since
                oldest, oldest_since = ci, ts
            end
        end
        if collecting == 0
            col = @atomic sl.collecting
            col != 0 && (collecting = col)
        end
    end
    if queued > 0
        # No test worker runs yet: the workers are the queue's helpers, if it has any.
        helpers = @atomic QUEUE_PROGRESS.helpers
        helpers > 0 && print_workers(io, @atomic(QUEUE_PROGRESS.live), helpers)
    elseif !solo && (@atomic m.phase) !== PHASE_SETUP
        # The test workers, from the stage that starts them on.
        print_workers(io, live_workers, length(run.slots))
    end
    if PER_PROCESS_OK[] && s.total_rss > 0
        if solo
            # One process: its total, its peak, and nothing to compare them to.
            print(io, " · rss ")
            print_bytes(io, s.total_rss, TOTAL_WIDTH)
            print(io, " (max ")
            print_bytes(io, r.peak_total)
            write(io, UInt8(')'))
        else
            # The newest sample's whole tree, the coordinator among it, with the
            # run's peak alongside.
            print(io, " · tree mem ")
            print_bytes(io, s.total_rss, TOTAL_WIDTH)
            print(io, " (max ")
            print_bytes(io, r.peak_total)
            write(io, UInt8(')'))
            # The largest any one process has been, not the largest now: a current
            # reading moves with whichever worker is mid-item.
            print(io, " · child max ")
            print_bytes(io, r.peak_single, TOTAL_WIDTH)
        end
    end
    if s.machine_total > 0
        print(io, " · mem ")
        print_int(io, round(Int, 100 * s.machine_used / s.machine_total), 2)
        write(io, UInt8('%'))
    end
    if s.load1 >= 0
        print(io, " · cpu ")
        # Four wide: a load average on a many-core machine reaches double digits
        # routinely, and this is the last field before the phase.
        print_1dp(io, s.load1, 4)
        write(io, UInt8('/'))
        print_int(io, cpu_count())
    elseif s.cpu_pct >= 0
        print(io, " · cpu ")
        print_int(io, round(Int, s.cpu_pct), 3)
        write(io, UInt8('%'))
    end
    # The stage and its age, then the oldest running item: last, because it is the
    # only field that changes width.
    print(io, " · ", phase_name(s.phase), " ")
    print_age(io, run.t0 + Float64(s.t) - r.phase_entered)
    oldest == 0 || (print(io, " · "); print_clipped(io, run.plan.items.name[oldest], RUNNING_WIDTH))
    # A producer that takes long is not an item that hangs, and is said apart from one.
    collecting == 0 || (print(io, " · collecting artifacts of "); print_clipped(io, run.plan.items.name[collecting], RUNNING_WIDTH))
    if queued > 0
        compiling = oldest_compiling()
        isempty(compiling) ||
            (print(io, " · precompiling "); print_clipped(io, compiling, RUNNING_WIDTH))
    end
    return nothing
end

"""
    print_age(io, seconds)

An elapsed time as `45s`, `1m12s` or `2h05m`, written a digit at a time into the
caller's buffer.
"""
function print_age(io::IO, seconds::Real)
    s = seconds > 0 ? unsafe_trunc(Int, seconds) : 0
    if s < 60
        print_int(io, s)
        write(io, UInt8('s'))
    elseif s < 3600
        print_int(io, s ÷ 60)
        write(io, UInt8('m'))
        print_int2(io, s % 60)
        write(io, UInt8('s'))
    else
        print_int(io, s ÷ 3600)
        write(io, UInt8('h'))
        print_int2(io, (s % 3600) ÷ 60)
        write(io, UInt8('m'))
    end
    return nothing
end

# Zero-padded to two digits: `1m05s` reads as one duration, `1m5s` as two numbers.
function print_int2(io::IO, n::Integer)
    n < 10 && write(io, UInt8('0'))
    print_int(io, n)
    return nothing
end

"""
    clip_status!(m, from)

Cut the status line the buffer holds from `from` onward to what fits on one row.

A line wider than the terminal wraps, and `\\r\\e[2K` erases the row the cursor is
on and no other — so the next redraw leaves every row but the last of the old line
sitting on the screen. Cutting it is what keeps one line one row.
"""
function clip_status!(m::Monitor, from::Integer)
    m.columns > 0 || return nothing
    buf = m.linebuf
    to = position(buf)
    fits = from + bytes_within(buf.data, from + 1, to, m.columns)
    if fits < to
        # A colour the kept part turns on may have had its reset cut off.
        colored = any(==(0x1b), view(buf.data, (from + 1):fits))
        truncate(buf, fits)
        colored && print(buf, "\e[0m")
    end
    return nothing
end

"""
    bytes_within(data, from, to, columns) -> Int

How many of the bytes `data[from:to]` fit in `columns` columns of screen.

Escape sequences change the colour, not the cursor's position, so they cost
nothing, and one is kept or cut whole. Decoded a byte at a time: a `String` would
allocate on every redraw.
"""
function bytes_within(data::AbstractVector{UInt8}, from::Int, to::Int, columns::Int)
    col = 0
    i = from
    while i <= to
        b = data[i]
        if b == 0x1b
            # `ESC [`, then parameter and intermediate bytes, then a final byte in
            # 0x40:0x7e; any other escape is `ESC` and one byte.
            if i + 1 <= to && data[i + 1] == UInt8('[')
                j = i + 2
                while j <= to && !(0x40 <= data[j] <= 0x7e)
                    j += 1
                end
                i = j + 1
            else
                i += 2
            end
            continue
        end
        n = b < 0x80 ? 1 : b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4
        i + n - 1 > to && break
        cp = if n == 1
            UInt32(b)
        elseif n == 2
            (UInt32(b & 0x1f) << 6) | UInt32(data[i + 1] & 0x3f)
        elseif n == 3
            (UInt32(b & 0x0f) << 12) | (UInt32(data[i + 1] & 0x3f) << 6) |
                UInt32(data[i + 2] & 0x3f)
        else
            (UInt32(b & 0x07) << 18) | (UInt32(data[i + 1] & 0x3f) << 12) |
                (UInt32(data[i + 2] & 0x3f) << 6) | UInt32(data[i + 3] & 0x3f)
        end
        w = textwidth(Char(cp))
        col + w > columns && return i - from
        col += w
        i += n
    end
    return i - from
end

status_line(m::Monitor) =
    sprint(io -> print_status_line(IOContext(io, :color => m.color), m))

# The wall clock as this line writes it (shared with `clock_now`), refreshing
# terminal width once a second when on a TTY.
function clock_text(m::Monitor)
    sec = unsafe_trunc(Int, time())
    if sec != m.clock_at
        m.clock_at = sec
        m.columns = terminal_columns(m.tty)
    end
    return clock_now()
end

# Clipped but not padded: the pinned line is erased before it is redrawn, so
# trailing spaces would only litter a log file.
function print_clipped(io::IO, s::AbstractString, width::Int)
    if length(s) <= width
        print(io, s)
    else
        print(io, SubString(s, 1, nextind(s, 0, width - 1)), '…')
    end
    return nothing
end

"""
    MEMORY_MARKS

Percentages of the machine's memory whose upward crossing earns a report of its
own, off schedule: past ninety percent, things change faster than a thirty-second
cadence can follow.
"""
const MEMORY_MARKS = (90, 95, 96, 97, 98, 99)

# A mark sits still while the machine breathes across it, so a run hovering on one
# would narrate every sample. Each mark says its piece at most this often.
const MEMORY_MARK_QUIET = 30.0

# The highest mark the machine has just crossed upward, or 0 for none.
function crossed_memory_mark!(m::Monitor, pct::Float64, now::Float64)
    prev = m.last_mem_pct
    m.last_mem_pct = pct
    crossed = 0
    for (i, mark) in pairs(MEMORY_MARKS)
        prev < mark <= pct || continue
        # Marked as said even when it is not reported, so that a machine drifting
        # over the same mark again in a moment stays quiet.
        now - m.mark_said[i] < MEMORY_MARK_QUIET && continue
        m.mark_said[i] = now
        crossed = mark
    end
    return crossed
end

# Off a terminal, a report every `PROGRESS_ITEMS` finished items as well as on the
# clock, but none within `PROGRESS_GAP_S` of the previous report: a run of quick
# items would otherwise print a line per item, and a slow run none for a long time.
const PROGRESS_ITEMS = 10
const PROGRESS_GAP_S = 5.0

# Machine CPU saturation (>= 100% of machine threads): triggers an immediate status
# line regardless of `PROGRESS_GAP_S`, with a cooldown so dancing on the boundary
# does not spam.
const CPU_MARK = 100.0
const CPU_MARK_QUIET = 30.0

cpu_load_pct(s::Sample) =
    s.cpu_pct >= 0 ? Float64(s.cpu_pct) :
    (s.load1 >= 0 ? 100.0 * Float64(s.load1) / max(cpu_count(), 1) : -1.0)

function crossed_cpu_mark!(m::Monitor, pct::Float64, now::Float64)
    pct < 0 && return false
    prev = m.last_cpu_pct
    m.last_cpu_pct = pct
    prev < CPU_MARK <= pct || return false
    now - m.cpu_mark_said < CPU_MARK_QUIET && return false
    m.cpu_mark_said = now
    return true
end

progress_due(done::Integer, reported::Integer, now::Float64, last_print::Float64) =
    done - reported >= PROGRESS_ITEMS && now - last_print >= PROGRESS_GAP_S

function maybe_print(m::Monitor)
    now = time()
    s = m.last_sample
    if m.tty
        now - m.last_print < 0.5 && return nothing
        m.last_print = now
        @lock run_of(m).printer redraw_status(m)
        return nothing
    end
    # Not a terminal: poll often and report on a clock, every `PROGRESS_ITEMS` items,
    # and immediately on phase change or memory/CPU threshold crossings. Both the clock
    # and item-progress reports respect `PROGRESS_GAP_S` so two routine lines do not
    # land seconds apart; threshold crossings fire immediately (with their own cooldown).
    phase_changed = s.phase !== m.last_phase_printed
    pressure = s.machine_total > 0 ? 100 * s.machine_used / s.machine_total : 0.0
    near_oom = crossed_memory_mark!(m, pressure, now) != 0
    high_cpu = crossed_cpu_mark!(m, cpu_load_pct(s), now)
    due = now >= m.next_print
    due && (m.next_print = max(now, m.next_print) + m.print_interval)
    clock_due = due && (now - m.last_print >= min(PROGRESS_GAP_S, m.print_interval))
    done = @atomic run_of(m).ndone
    prog_due = progress_due(done, m.done_reported, now, m.last_print)
    (clock_due || prog_due || phase_changed || near_oom || high_cpu) || return nothing
    m.last_print = now
    m.done_reported = done
    m.last_phase_printed = s.phase
    printline(run_of(m), status_line(m))
    return nothing
end

# The pinned line is erased before anything else writes, and redrawn after. Both
# happen under the printer lock, so no other output can land in between.
clear_status_line(m::Union{Nothing, Monitor}) =
    (m !== nothing && m.tty && (print(stdout, "\r\e[2K"); flush(stdout)); nothing)

# Assemble the clipped status line at the end of `m.linebuf` and rewind to start.
function append_status!(m::Monitor)
    buf = m.linebuf
    print(m.lineio, "\r\e[2K")
    at = position(buf)
    print_status_line(m.lineio, m)
    clip_status!(m, at)
    seekstart(buf)
    return buf
end

"""
    status_update!(m, text) -> IOBuffer

What one printed line sends to a terminal: erase the status line, the line, the
status line again, assembled whole and written once. Written as three pieces, a
run that prints fast mostly shows a half-erased status line.
"""
function status_update!(m::Monitor, text::AbstractString)
    truncate(m.linebuf, 0)
    print(m.lineio, "\r\e[2K", text)
    endswith(text, "\n") || print(m.lineio, "\n")
    return append_status!(m)
end

"""
    with_status_line_off(f, m)

Run `f` with the pinned status line withdrawn: `Pkg` draws its own progress by
moving the cursor, and two writers rewriting the last line produce neither.
Sampling continues; only the drawing stops.
"""
function with_status_line_off(f, m::Union{Nothing, Monitor})
    m === nothing && return f()
    # Under the printer lock, as `stop_monitor!` does: a redraw already under way
    # would otherwise land after the erase.
    @lock run_of(m).printer begin
        @atomic m.quiet = true
        clear_status_line(m)
    end
    try
        return f()
    finally
        @atomic m.quiet = false
    end
end

# Whether the status line may be drawn at all right now.
drawing(m::Monitor) = m.tty && !m.stop && !(@atomic m.quiet)

function redraw_status(m::Union{Nothing, Monitor})
    (m === nothing || !drawing(m)) && return nothing
    # Assembled in the monitor's buffer and written once. Safe to share: every
    # caller holds the printer lock.
    truncate(m.linebuf, 0)
    write(stdout, append_status!(m))
    flush(stdout)
    return nothing
end

"""
    print_memory_summary(io, m; indent)

What each stage of the run cost, a line each, for the run's closing block. Per
stage because the stages are not comparable, and the stage that came closest to
the edge is the one a reader can act on.
"""
function print_memory_summary(io::IO, m::Monitor; indent::AbstractString = "  ")
    st = m.stats
    finish = time()
    run = run_of(m)
    solo = single_process(run.plan)
    if PER_PROCESS_OK[]
        rows = NamedTuple{(:phase, :ps, :name, :time_text, :procs), Tuple{RunPhase, PhaseStats, String, String, String}}[]
        name_width, time_width, procs_width = 0, 0, 0
        for phase in instances(RunPhase)
            ps = phase_stats(st, phase)
            ps.entered == 0 && continue
            secs = phase_seconds(st, phase, finish)
            phase === PHASE_REPORT && secs < REPORT_WORTH_SAYING && continue
            nm = phase_name(phase)
            tt = fmt_seconds(secs)
            pt = (!solo && ps.peak_total > 0) ? procs_text(ps) : ""
            name_width = max(name_width, length(nm))
            time_width = max(time_width, length(tt))
            procs_width = max(procs_width, length(pt))
            push!(rows, (; phase, ps, name = nm, time_text = tt, procs = pt))
        end
        total_elapsed = sum(run.statuses.elapsed; init = 0.0f0)
        for row in rows
            ps = row.ps
            starts = ps.starts
            has_compile = row.phase === PHASE_TEST && total_elapsed > 0
            more_follows = starts > nslots(run.plan) || has_compile
            print(io, indent, rpad(row.name, name_width), FIELD, lpad(row.time_text, time_width))
            if ps.peak_total > 0
                print(io, FIELD, solo ? "rss " : "tree max ")
                print_bytes(io, ps.peak_total, BYTES_WIDTH)
                if !solo
                    print(io, FIELD, "child max ")
                    print_bytes(io, ps.peak_single, BYTES_WIDTH)
                    print(io, FIELD, row.procs)
                    more_follows && pad_to(io, procs_width, length(row.procs))
                end
            end
            # Only when workers were replaced rather than reused: otherwise this is
            # the worker count again, said twice.
            starts > nslots(run.plan) && print(io, FIELD, plural(starts, "worker start"))
            if has_compile
                share = round(Int, 100 * sum(run.statuses.compile; init = 0.0f0) / total_elapsed)
                print(io, FIELD, share, "% compile")
            end
            println(io)
        end
        solo || println(
            io, indent, "(summed resident sizes over-count pages the processes share)"
        )
    end
    st.machine_total > 0 && println(
        io, indent, "machine", FIELD, fmt_bytes(st.machine_peak_used), " of ",
        fmt_bytes(st.machine_total), " in use at peak"
    )
    print_cpu(io, st.cpu_start, st.cpu_end; indent)
    st.guard_actions > 0 &&
        println(io, indent, "guard", FIELD, plural(st.guard_actions, "action"))
    return nothing
end

# Once every worker has exited and been reaped: before that, what a worker has used
# is not in its parent's count.
record_cpu_end!(m::Union{Nothing, Monitor}) = (m === nothing || (m.stats.cpu_end = cpu_reading()); nothing)

# How busy the run kept the machine's CPU threads, and how busy the machine was:
# the two differ by whatever else was running. Where the run's own time is unknown,
# or comes out beyond what the machine could give, only the machine's is said.
function print_cpu(io::IO, a::CpuReading, b::CpuReading; indent::AbstractString = "  ")
    (b.at > a.at && b.total_ms > a.total_ms && b.threads > 0) || return nothing
    machine = round(Int, 100 * (b.busy_ms - a.busy_ms) / (b.total_ms - a.total_ms))
    run = a.run_s >= 0 && b.run_s >= a.run_s ? (b.run_s - a.run_s) / ((b.at - a.at) * b.threads) : -1.0
    print(io, indent, "cpu", FIELD)
    if 0 <= run <= 1.05
        println(io, round(Int, 100 * min(run, 1.0)), "% of ", b.threads, " threads for this run's processes, ",
                machine, "% for the whole machine (averages over the run)")
    else
        println(io, machine, "% of ", b.threads, " threads for the whole machine (average over the run)")
    end
    return nothing
end

# How much of the time the items spent was spent compiling. Summed over the items
# rather than measured against the stage's wall time, which several workers share
# and which would make the share depend on how many there were.
function print_compile_share(io::IO, run)
    elapsed = sum(run.statuses.elapsed; init = 0.0f0)
    elapsed > 0 || return nothing
    share = round(Int, 100 * sum(run.statuses.compile; init = 0.0f0) / elapsed)
    print(io, FIELD, share, "% compile")
    return nothing
end

### The memory guard #######################################################

const GUARD_BACKPRESSURE_SECONDS = 10.0
const GUARD_GC_SECONDS = 20.0
const GUARD_RESTART_COOLDOWN = 60.0
# A hold ends this far below the threshold, not at it. The machine's reading drifts
# by about this much with nothing happening (1.8 points over 30s, measured on an idle
# 64 GiB Mac), and a hold released on the first dip is taken again on the next rise.
const GUARD_HYSTERESIS = 0.02

# Escalates slowly on purpose: restarting a worker throws away everything it has
# compiled, which on a compilation-heavy suite is the most expensive thing the
# framework can do to itself.
function guard!(m::Monitor)
    run = run_of(m)
    threshold = run.plan.cfg.memory_threshold
    s = m.last_sample
    s.machine_total > 0 || return nothing
    pressure = s.machine_used / s.machine_total
    now = time()
    release = max(threshold - GUARD_HYSTERESIS, threshold / 2)
    if m.over_since != 0.0 && pressure < release
        m.over_since = 0.0
        # Said only when the hold was still on: `wait_while_paused` lets go by itself
        # after `MAX_BACKPRESSURE_SECONDS`, and says so.
        if is_paused(run.queues)
            set_paused!(run.queues, false)
            say(run, "memory is down to ", round(Int, 100 * pressure), "%; no longer holding off on new test items")
        end
        return nothing
    end
    pressure < threshold && return nothing   # below it, or on the way down from a hold
    if m.over_since == 0.0
        m.over_since = now
        set_paused!(run.queues, true)
        m.stats.guard_actions += 1
        @warn "Runtests: memory is at $(round(Int, 100 * pressure))% of the machine; holding off on new " *
            "test items until it is below $(round(Int, 100 * release))%, for " *
            "$(round(Int, MAX_BACKPRESSURE_SECONDS))s at most"
        # Collecting costs less than waiting. A worker running an item collects when
        # the item is done and it waits (`wait_while_paused`).
        collect_idle_garbage!(run)
        return nothing
    end
    over = now - m.over_since
    if over > GUARD_GC_SECONDS && now - m.last_restart > GUARD_RESTART_COOLDOWN
        m.last_restart = now
        m.stats.guard_actions += 1
        recycle_biggest_worker!(m)
    elseif over > GUARD_BACKPRESSURE_SECONDS && now - m.last_gc > GUARD_GC_SECONDS
        m.last_gc = now
        m.stats.guard_actions += 1
        collect_idle_garbage!(run)
    end
    return nothing
end

# This process, and each worker not running an item or its producers: a request to
# one that is would wait behind the item and hold up its `test_end`.
function collect_idle_garbage!(run)
    GC.gc(true)
    for slot in run.slots
        (@atomic slot.current) == 0 && (@atomic slot.collecting) == 0 && collect_garbage(@atomic slot.worker)
    end
    return nothing
end

# The largest worker, measured now, is replaced once its slot is between units.
function recycle_biggest_worker!(m::Monitor)
    run = run_of(m)
    victim, most = nothing, Int64(-1)
    for slot in run.slots
        w = @atomic slot.worker
        (w === nothing || (@atomic slot.recycle)) && continue
        rss = process_rss(w.pid)
        rss > most && ((victim, most) = (slot, rss))
    end
    victim === nothing && return nothing
    w = @atomic victim.worker
    w === nothing && return nothing
    @atomic victim.recycle = true
    # A slot waiting for a gate replaces its worker now rather than once it has a unit.
    wake_waiting!(run.queues)
    say(run, "memory is above ", round(Int, 100 * run.plan.cfg.memory_threshold), "%; restarting w",
        victim.id, " (pid ", w.pid, most > 0 ? string(", ", fmt_bytes(most)) : "", ")",
        (@atomic victim.current) == 0 ? "" : " once its item is done")
    return nothing
end

