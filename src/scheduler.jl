# Scheduling a plan across worker slots: each slot takes its pool's head first, then
# walks its own stretch of the pool's body, steals half of the largest stretch left when
# its own is done, then the pool's tail. When its own pool has nothing left it may
# rebind to another pool, estimating completion with and without that worker including
# its start and compilation cost.

"""
    PoolStats

What the run has measured of one pool, for deciding where a slot whose own pool
has run dry does the most good: how long the pool's workers took to be ready; the
compile time of items that ran first on a fresh process, and of items that ran on
one that had run others; and how long its items took, against their recorded
durations where they had one.
"""
mutable struct PoolStats
    starts::Int
    start_s::Float64
    cold::Int                    # items that ran first on a fresh process
    cold_compile_s::Float64
    warm::Int                    # items that ran on a process that had run others
    warm_compile_s::Float64
    items::Int
    took_s::Float64
    estimated_s::Float64         # the recorded durations of the items that had one
    estimated_took_s::Float64    # and what those items took
end
PoolStats() = PoolStats(0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, 0.0, 0.0)

"""
    Queues

Every cursor a run has, behind one lock: each pool's head and tail, and each slot's
stretch of its pool's body; and what the run has measured of each pool, which the
slots write and a slot whose pool ran dry reads. Each claim takes the lock so the
cursors and pool statistics remain consistent.

A unit of a gate (`Units`) whose gate runs as many units as its limit allows is set
aside when a cursor passes it, in its pool's `set_aside`, and handed out from there,
before anything else of the pool, once a unit of the gate ends. A slot whose pool
holds only units set aside moves to a pool with a unit it can start now, if there is
one, and otherwise waits on `room`. A pool that its last slot leaves so is `parked`
until a slot takes it up again, which one does before any slot is done.
"""
mutable struct Queues
    const lock::ReentrantLock
    const room::Threads.Condition    # on `lock`: a gate's unit ended, a set-aside unit left, or the run stopped
    const pools::Vector{Pool}
    const head::Vector{UnitIdx}      # per pool: its next head unit
    const tail::Vector{UnitIdx}      # per pool: its next tail unit
    const from::Vector{UnitIdx}      # per slot: the next unit of its stretch
    const to::Vector{UnitIdx}        # per slot: the last unit of its stretch
    const pool::Vector{Int32}        # per slot: the pool it serves
    const pending::Vector{Int32}     # pools no slot serves yet, in pickup order
    const parked::Vector{Int32}      # pools with only set-aside units left that no slot serves
    const claimed::BitVector         # per unit: handed out already
    const serving::Vector{Int}       # per pool: slots working for it
    const est::Vector{Float64}       # per unit: the recorded seconds of its items
    const unrecorded::Vector{Int32}  # per unit: its items without a recorded duration
    const typical::Float64           # an unrecorded item, before its pool has timed any
    const stats::Vector{PoolStats}   # per pool
    const prior::ColdCost            # what a fresh worker cost in earlier runs
    const gate::Vector{Int32}        # per unit: its gate, 0 for none
    const gate_limit::Vector{Int32}  # per gate: how many of its units run at once
    const gate_running::Vector{Int32}    # per gate: how many of its units are handed out and not ended
    const set_aside::Vector{Vector{UnitIdx}}  # per pool: units passed while their gate was full, in order
    # Per pool: `gate_ends` when its set-aside units were last found all held back. Only
    # a gate's unit ending lets one go, so until `gate_ends` moves on they still are.
    const aside_blocked_at::Vector{Int}
    gate_ends::Int                   # units of gates that have ended
    @atomic cancelled::Bool
    @atomic paused::Bool             # the memory guard is holding new work back
end

function Queues(p::Plan)
    lock = ReentrantLock()
    return Queues(lock, Threads.Condition(lock), p)
end
Queues(lock::ReentrantLock, room::Threads.Condition, p::Plan) = Queues(
    lock, room, p.pools,
    UnitIdx[first(k.head) for k in p.pools], UnitIdx[first(k.tail) for k in p.pools],
    UnitIdx[first(r) for r in p.slot_units], UnitIdx[last(r) for r in p.slot_units],
    copy(p.slot_pool), copy(p.pending), Int32[], falses(length(p.units)),
    [count(==(k), p.slot_pool) for k in eachindex(p.pools)],
    p.units.est_s, Int32[count(i -> p.items.est_s[i] == 0, span) for span in p.units.span],
    typical_estimate(p.items.est_s),
    [PoolStats() for _ in p.pools], p.cold, p.units.gate, p.gate_limit, zeros(Int32, length(p.gate_limit)),
    [UnitIdx[] for _ in p.pools], fill(-1, length(p.pools)), 0, false, false
)

struct Claim
    kind::Symbol        # :unit, :rebind, :done, :wait (`claim!`)
    unit::UnitIdx
    pool::Int32
end
Claim(kind::Symbol) = Claim(kind, UnitIdx(0), Int32(0))

gate_full(q::Queues, u::Integer) = (g = q.gate[u]; g != 0 && q.gate_running[g] >= q.gate_limit[g])

# Unit `u`, handed out. Every unit is handed out exactly once; a second time is a
# scheduling bug, stopped here rather than run twice.
function hand_out!(q::Queues, u::UnitIdx)
    q.claimed[u] && error("Runtests internal error: unit $u was handed out twice")
    q.claimed[u] = true
    g = q.gate[u]
    g == 0 || (q.gate_running[g] += Int32(1))
    return Claim(:unit, u, Int32(0))
end

# The first unit from cursor `i` up to `stop` that its gate lets run, moving the
# cursor past it and setting aside, for pool `k`, the units before it that their
# gate does not; 0 when the cursor passes `stop`.
function next!(q::Queues, cursor::Vector{UnitIdx}, i::Integer, stop::Integer, k::Integer)
    while cursor[i] <= stop
        u = cursor[i]
        cursor[i] += UnitIdx(1)
        gate_full(q, u) || return u
        push!(q.set_aside[k], u)
    end
    return UnitIdx(0)
end

# The first unit pool `k` set aside that its gate now lets run, taken off the list,
# or 0.
function take_set_aside!(q::Queues, k::Integer)
    aside = q.set_aside[k]
    (isempty(aside) || q.aside_blocked_at[k] == q.gate_ends) && return UnitIdx(0)
    j = findfirst(u -> !gate_full(q, u), aside)
    if j === nothing
        q.aside_blocked_at[k] = q.gate_ends
        return UnitIdx(0)
    end
    u = popat!(aside, j)
    # A slot waiting only because this unit was set aside can now finish or move on.
    isempty(aside) && notify(q.room)
    return u
end

# The next unit for slot `s`, or what it does instead. A slot whose pool has only
# units their gates hold back waits here, until a gate's unit ends, the memory guard
# asks for its worker or the run stops, and then gets `:wait`: its loop looks at
# those before it claims again. The claim and the wait are under one hold of the
# lock, so a unit that ends in between still wakes it.
function claim!(q::Queues, s::Integer)
    @lock q.lock begin
        c = claim_now!(q, s)
        c.kind === :wait && wait(q.room)
        return c
    end
end

# Every slot waiting in `claim!` looks again.
wake_waiting!(q::Queues) = @lock q.lock (notify(q.room); nothing)

function claim_now!(q::Queues, s::Integer)
    (@atomic q.cancelled) && return Claim(:done)
    k = q.pool[s]
    u = next_unit!(q, s, k)
    u == 0 || return hand_out!(q, u)
    if !isempty(q.set_aside[k])
        # What is left of its pool waits for a gate. The slot moves to a pool with a
        # unit it can start now, if there is one; a pool that loses its last slot so
        # waits in `parked` for another.
        j = next_pool(q, k; now = true)
        j == 0 && return Claim(:wait)
        q.serving[k] == 1 && push!(q.parked, Int32(k))
        return rebind!(q, s, k, j)
    end
    # Its own pool has nothing left: the slot moves to another, whose profile its
    # next process is started with.
    j = next_pool(q, k; now = false)
    if j == 0
        q.serving[k] -= 1
        return Claim(:done)
    end
    return rebind!(q, s, k, j)
end

# The next unit slot `s` of pool `k` can start, or 0: one set aside whose gate has
# room, then the pool's head, its own stretch, the second half of the largest
# stretch left in the pool, and the tail.
function next_unit!(q::Queues, s::Integer, k::Integer)
    u = take_set_aside!(q, k)
    u == 0 || return u
    u = next!(q, q.head, k, last(q.pools[k].head), k)
    u == 0 || return u
    u = next!(q, q.from, s, q.to[s], k)
    u == 0 || return u
    # Its own stretch is done: take the second half of the largest stretch left
    # in the pool, so both slots go on walking neighbouring units. A stretch of
    # one gives it up too, so a slow slot's last unit does not wait behind the
    # one it is running. Never across pools: a unit run under another profile's
    # flags is not the test that was declared. A stretch whose units all wait for
    # their gate is set aside whole, and the next largest taken.
    while true
        victim, most = 0, 0
        for v in eachindex(q.pool)
            q.pool[v] == k || continue
            r = q.to[v] - q.from[v] + 1
            r > most && ((victim, most) = (v, r))
        end
        victim == 0 && break
        q.from[s] = q.from[victim] + UnitIdx(most ÷ 2)
        q.to[s] = q.to[victim]
        q.to[victim] = q.from[s] - UnitIdx(1)
        u = next!(q, q.from, s, q.to[s], k)
        u == 0 || return u
    end
    return next!(q, q.tail, k, last(q.pools[k].tail), k)
end

# Slot `s` leaves pool `k` for pool `j`. A pool no slot served yet gives it its whole
# body to walk; one that slots served already, an empty stretch: it takes what is left
# of the pool's head, then the second half of the largest stretch, as any of the
# pool's slots would.
function rebind!(q::Queues, s::Integer, k::Integer, j::Integer)
    at = findfirst(==(j), q.pending)
    if at === nothing
        filter!(!=(j), q.parked)
        q.from[s], q.to[s] = UnitIdx(1), UnitIdx(0)
    else
        deleteat!(q.pending, at)
        q.from[s], q.to[s] = first(q.pools[j].body), last(q.pools[j].body)
    end
    q.pool[s] = j
    q.serving[k] -= 1
    q.serving[j] += 1
    return Claim(:rebind, UnitIdx(0), j)
end

# The pool a slot leaving pool `k` goes to, or 0: one no slot serves yet, then a
# parked one with a unit it can start now, then the one where it does the most good
# (`neediest_pool`). With `now`, for a slot that would otherwise wait, only a pool
# with a unit it can start now; without, for one that would otherwise be done, last a
# parked pool whose units still wait for their gate, which no slot may leave behind.
function next_pool(q::Queues, k::Integer; now::Bool)
    for j in q.pending
        (!now || startable(q, j)) && return Int(j)
    end
    for j in q.parked
        startable(q, j) && return Int(j)
    end
    j = neediest_pool(q, k)
    j != 0 && (!now || startable(q, j)) && return j
    return now || isempty(q.parked) ? 0 : Int(q.parked[1])
end

startable(q::Queues, j::Integer) =
    any(u -> !q.claimed[u] && !gate_full(q, u), first(q.pools[j].head):last(q.pools[j].tail))

# Unit `u` ended, with all its attempts: its gate can run another.
function unit_ended!(q::Queues, u::UnitIdx)
    g = q.gate[u]
    g == 0 && return nothing
    @lock q.lock begin
        q.gate_running[g] -= Int32(1)
        q.gate_ends += 1
        notify(q.room)
    end
    return nothing
end

# The pool a slot whose own pool `k` has run dry does the most good in, or 0 for
# none: of the pools that one more worker makes finish sooner, the one that finishes
# last. Each pool is played out (`finish_time!`): its unclaimed units, in the order they
# are handed out, each to whichever of its workers is free first, its own workers free
# now and the new one once it has started its process and compiled what the others
# have (`cold_cost`). Units are whole, so a worker that is ready only after the others
# have claimed the last of them makes the pool finish no sooner. Nor does one that
# could take only units that their gates hold back (`gated_work`). A parked pool is
# `next_pool`'s to choose.
function neediest_pool(q::Queues, k::Integer)
    best, latest = 0, 0.0
    for j in eachindex(q.pools)
        (j == k || j in q.parked) && continue
        units = unclaimed_work(q, j)
        isempty(units) && continue
        n = q.serving[j]
        floor, saturated = gated_work(q, j)
        saturated && continue
        without = n == 0 ? Inf : max(floor, finish_time!(units, zeros(n)))
        free = zeros(n + 1)
        free[n + 1] = cold_cost(q, j)
        with = max(floor, finish_time!(units, free))
        with < without && without > latest && ((best, latest) = (j, without))
    end
    return best
end

# When the last of `units`, durations in seconds in the order they are handed out,
# ends, on workers free from the times `free`, mutating `free` in place.
function finish_time!(units::Vector{Float64}, free::Vector{Float64})
    for d in units
        _, w = findmin(free)
        free[w] += d
    end
    return maximum(free)
end

finish_time(units::Vector{Float64}, free::Vector{Float64}) = finish_time!(units, copy(free))

# Pool `j`'s unclaimed units, each its estimated seconds, in the order they are handed
# out: its head, its body, its tail, which are consecutive. A recorded duration is
# scaled by how this run's items took against theirs. An item without one counts as
# the pool's average item so far. Before the pool has timed any, it counts as the
# typical recorded item, as in the plan.
function unclaimed_work(q::Queues, j::Integer)
    seconds = unit_seconds(q, j)
    pool = q.pools[j]
    return Float64[seconds(u) for u in first(pool.head):last(pool.tail) if !q.claimed[u]]
end

# The least time pool `j`'s unclaimed units take, however many workers serve it, as
# the units of each gate run at most its limit at a time; and whether those units
# are all of gates whose limits the pool's workers can already fill, which another
# worker therefore does not speed up.
function gated_work(q::Queues, j::Integer)
    isempty(q.gate_limit) && return 0.0, false
    seconds = unit_seconds(q, j)
    work = zeros(length(q.gate_limit))
    saturated = true
    pool = q.pools[j]
    for u in first(pool.head):last(pool.tail)
        q.claimed[u] && continue
        g = q.gate[u]
        if g == 0
            saturated = false
        else
            work[g] += seconds(u)
            saturated &= q.gate_limit[g] <= q.serving[j]
        end
    end
    best = 0.0
    for g in eachindex(work)
        v = work[g] / q.gate_limit[g]
        v > best && (best = v)
    end
    return best, saturated
end

# The estimated seconds of a unit of pool `j`, as `unclaimed_work` counts them.
function unit_seconds(q::Queues, j::Integer)
    st = q.stats[j]
    scale = st.estimated_s > 0 ? st.estimated_took_s / st.estimated_s : 1.0
    unknown = st.items > 0 ? st.took_s / st.items : q.typical
    return u -> q.est[u] * scale + q.unrecorded[u] * unknown
end

# What a fresh worker in pool `j` costs before it is as fast as the pool's others:
# starting its process, and compiling what they already have. Measured in the pool
# once the run has seen it there, across the run's pools before that, and taken
# from earlier runs before the run has seen it at all.
function cold_cost(q::Queues, j::Integer)
    st = q.stats[j]
    starts = sum(x -> x.starts, q.stats)
    start = st.starts > 0 ? st.start_s / st.starts :
        starts > 0 ? sum(x -> x.start_s, q.stats) / starts : q.prior.start_s
    excess(cold_s, cold, warm_s, warm) = max(0.0, cold_s / cold - warm_s / warm)
    cold, warm = sum(x -> x.cold, q.stats), sum(x -> x.warm, q.stats)
    compile = st.cold > 0 && st.warm > 0 ? excess(st.cold_compile_s, st.cold, st.warm_compile_s, st.warm) :
        cold > 0 && warm > 0 ?
        excess(sum(x -> x.cold_compile_s, q.stats), cold, sum(x -> x.warm_compile_s, q.stats), warm) :
        q.prior.compile_s
    return start + compile
end

# A worker process of slot `s` took `seconds` to be ready for its first item.
note_start!(q::Queues, s::Integer, seconds::Real) = @lock q.lock begin
    st = q.stats[q.pool[s]]
    st.starts += 1
    st.start_s += seconds
    nothing
end

# A slot waiting for a gate stops waiting.
function cancel!(q::Queues)
    return @lock q.lock begin
        was = @atomic q.cancelled
        @atomic q.cancelled = true
        notify(q.room)
        was
    end
end

is_cancelled(q::Queues) = @atomic q.cancelled
is_paused(q::Queues) = @atomic q.paused
function set_paused!(q::Queues, v::Bool)
    @atomic q.paused = v
    v || wake_waiting!(q)
    return nothing
end
