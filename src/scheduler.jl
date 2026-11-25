# Scheduling a plan across worker slots: each slot takes its pool's head first, then
# walks its own stretch of the pool's body, steals half of the largest stretch left when
# its own is done, then the pool's tail. When its own pool has nothing left it may
# rebind to another pool, estimating completion with and without that worker including
# its start and compilation cost. Under exact replay (`replay_slots`), stealing and
# reordering are bypassed and each slot runs its recorded sequence in order.

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

An item of a gate (`Items`) whose gate runs as many items as its limit allows is set
aside when a cursor passes it, in its pool's `set_aside`, and handed out from there,
before anything else of the pool, once an item of the gate ends. A slot whose pool
holds only items set aside moves to a pool with an item it can start now, if there is
one, and otherwise waits on `room`. A pool that its last slot leaves so is `parked`
until a slot takes it up again, which one does before any slot is done. When
`replay_slots` is non-empty (exact replay), `claim_replay_now!` hands out each slot's
fixed sequence in order with no stealing, rebinding pools as needed and waiting in
place when a gate is full.
"""
mutable struct Queues
    const lock::ReentrantLock
    const room::Threads.Condition    # on `lock`: a gate's item ended, a set-aside item left, or the run stopped
    const pools::Vector{Pool}
    const head::Vector{ItemIdx}      # per pool: its next head item
    const tail::Vector{ItemIdx}      # per pool: its next tail item
    const from::Vector{ItemIdx}      # per slot: the next item of its stretch
    const to::Vector{ItemIdx}        # per slot: the last item of its stretch
    const pool::Vector{Int32}        # per slot: the pool it serves
    const pending::Vector{Int32}     # pools no slot serves yet, in pickup order
    const parked::Vector{Int32}      # pools with only set-aside items left that no slot serves
    const claimed::BitVector         # per item: handed out already
    const serving::Vector{Int}       # per pool: slots working for it
    const est::Vector{Float64}       # per item: its recorded seconds, 0 for unrecorded
    const typical::Float64           # an unrecorded item, before its pool has timed any
    const stats::Vector{PoolStats}   # per pool
    const prior::ColdCost            # what a fresh worker cost in earlier runs
    const gate::Vector{Int32}        # per item: its gate, 0 for none
    const gate_limit::Vector{Int32}  # per gate: how many of its items run at once
    const gate_warming::Vector{Bool} # per gate: true while waiting for the first non-skipped item to finish
    const gate_warmup_item::Vector{ItemIdx}  # per gate: designated warmup item while warming (0 if any may warm up)
    const gate_running::Vector{Int32}    # per gate: how many of its items are handed out and not ended
    const set_aside::Vector{Vector{ItemIdx}}  # per pool: items passed while their gate was full, in order
    # Per pool: `gate_ends` when its set-aside items were last found all held back. Only
    # a gate's item ending lets one go, so until `gate_ends` moves on they still are.
    const aside_blocked_at::Vector{Int}
    gate_ends::Int                   # items of gates that have ended
    const replay_slots::Vector{Vector{ItemIdx}}  # non-empty for exact replay: fixed per-slot sequence
    const replay_pos::Vector{Int}                # per slot: next index in `replay_slots[s]`
    const item_pool::Vector{Int32}               # per item: pool index (populated for exact replay)
    @atomic cancelled::Bool
    @atomic paused::Bool             # the memory guard is holding new work back
end

function pool_of_items(p::Plan)
    isempty(p.replay_slots) && return Int32[]
    out = zeros(Int32, nitems(p))
    for (k, pool) in enumerate(p.pools)
        for range in (pool.head, pool.body, pool.tail)
            for i in range
                out[i] = Int32(k)
            end
        end
    end
    return out
end

function Queues(p::Plan)
    lock = ReentrantLock()
    return Queues(lock, Threads.Condition(lock), p)
end
Queues(lock::ReentrantLock, room::Threads.Condition, p::Plan) = Queues(
    lock, room, p.pools,
    ItemIdx[first(k.head) for k in p.pools], ItemIdx[first(k.tail) for k in p.pools],
    ItemIdx[first(r) for r in p.slot_items], ItemIdx[last(r) for r in p.slot_items],
    copy(p.slot_pool), copy(p.pending), Int32[], falses(nitems(p)),
    [count(==(k), p.slot_pool) for k in eachindex(p.pools)],
    p.items.est_s, typical_estimate(p.items.est_s),
    [PoolStats() for _ in p.pools], p.cold, p.items.gate, p.gate_limit, copy(p.gate_warmup),
    isempty(p.replay_slots) ? copy(p.gate_warmup_item) : zeros(ItemIdx, length(p.gate_limit)),
    zeros(Int32, length(p.gate_limit)),
    [ItemIdx[] for _ in p.pools], fill(-1, length(p.pools)), 0,
    p.replay_slots, ones(Int, length(p.replay_slots)), pool_of_items(p),
    false, false
)

struct Claim
    kind::Symbol        # :item, :rebind, :done, :wait (`claim!`)
    item::ItemIdx
    pool::Int32
end
Claim(kind::Symbol) = Claim(kind, ItemIdx(0), Int32(0))

gate_effective_limit(q::Queues, g::Integer) = q.gate_warming[g] ? Int32(1) : q.gate_limit[g]

function gate_full(q::Queues, i::Integer)
    g = q.gate[i]
    g == 0 && return false
    if q.gate_warming[g]
        w = q.gate_warmup_item[g]
        (w != 0 && w != i) && return true
        return q.gate_running[g] >= Int32(1)
    end
    return q.gate_running[g] >= q.gate_limit[g]
end

# Item `i`, handed out. Every item is handed out exactly once; a second time is a
# scheduling bug, stopped here rather than run twice.
function hand_out!(q::Queues, i::ItemIdx)
    q.claimed[i] && error("Runtests internal error: item $i was handed out twice")
    q.claimed[i] = true
    g = q.gate[i]
    g == 0 || (q.gate_running[g] += Int32(1))
    return Claim(:item, i, Int32(0))
end

# The first item from cursor `i` up to `stop` that its gate lets run, moving the
# cursor past it and setting aside, for pool `k`, the items before it that their
# gate does not; 0 when the cursor passes `stop`.
function next!(q::Queues, cursor::Vector{ItemIdx}, i::Integer, stop::Integer, k::Integer)
    while cursor[i] <= stop
        item = cursor[i]
        cursor[i] += ItemIdx(1)
        gate_full(q, item) || return item
        push!(q.set_aside[k], item)
    end
    return ItemIdx(0)
end

# The first item pool `k` set aside that its gate now lets run, taken off the list,
# or 0.
function take_set_aside!(q::Queues, k::Integer)
    aside = q.set_aside[k]
    (isempty(aside) || q.aside_blocked_at[k] == q.gate_ends) && return ItemIdx(0)
    j = findfirst(item -> !gate_full(q, item), aside)
    if j === nothing
        q.aside_blocked_at[k] = q.gate_ends
        return ItemIdx(0)
    end
    item = popat!(aside, j)
    # A slot waiting only because this item was set aside can now finish or move on.
    isempty(aside) && notify(q.room)
    return item
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
    isempty(q.replay_slots) || return claim_replay_now!(q, s)
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

# Exact replay hand-out: each slot runs its recorded sequence in order, with no stealing
# and no reordering. Switches pool when the next item belongs to another pool, and waits
# in place if a throttle gate is currently full.
function claim_replay_now!(q::Queues, s::Integer)
    seq = q.replay_slots[s]
    pos = q.replay_pos[s]
    if pos > length(seq)
        k = q.pool[s]
        q.serving[k] > 0 && (q.serving[k] -= 1)
        return Claim(:done)
    end
    u = seq[pos]
    j = q.item_pool[u]
    if j != q.pool[s]
        k = q.pool[s]
        q.serving[k] > 0 && (q.serving[k] -= 1)
        q.serving[j] += 1
        q.pool[s] = j
        return Claim(:rebind, ItemIdx(0), j)
    end
    gate_full(q, u) && return Claim(:wait)
    q.replay_pos[s] = pos + 1
    return hand_out!(q, u)
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
        q.from[s] = q.from[victim] + ItemIdx(most ÷ 2)
        q.to[s] = q.to[victim]
        q.to[victim] = q.from[s] - ItemIdx(1)
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
        q.from[s], q.to[s] = ItemIdx(1), ItemIdx(0)
    else
        deleteat!(q.pending, at)
        q.from[s], q.to[s] = first(q.pools[j].body), last(q.pools[j].body)
    end
    q.pool[s] = j
    q.serving[k] -= 1
    q.serving[j] += 1
    return Claim(:rebind, ItemIdx(0), j)
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

# Item `i` ended, with all its attempts: its gate can run another. When `warmed` is true
# (any non-skipped outcome), a warming gate opens to its full `gate_limit`.
function item_ended!(q::Queues, i::ItemIdx; warmed::Bool = true)
    g = q.gate[i]
    g == 0 && return nothing
    @lock q.lock begin
        q.gate_running[g] -= Int32(1)
        if warmed
            q.gate_warming[g] = false
            q.gate_warmup_item[g] = ItemIdx(0)
        elseif q.gate_warmup_item[g] == i
            # Designated warmup item was skipped: let the next gated item warm up alone.
            q.gate_warmup_item[g] = ItemIdx(0)
        end
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
    seconds = item_seconds(q, j)
    pool = q.pools[j]
    return Float64[seconds(i) for i in first(pool.head):last(pool.tail) if !q.claimed[i]]
end

# The least time pool `j`'s unclaimed items take, however many workers serve it, as
# the items of each gate run at most its limit at a time; and whether those items
# are all of gates whose limits the pool's workers can already fill, which another
# worker therefore does not speed up.
function gated_work(q::Queues, j::Integer)
    isempty(q.gate_limit) && return 0.0, false
    seconds = item_seconds(q, j)
    work = zeros(length(q.gate_limit))
    longest = zeros(length(q.gate_limit))
    saturated = true
    pool = q.pools[j]
    for i in first(pool.head):last(pool.tail)
        q.claimed[i] && continue
        g = q.gate[i]
        if g == 0
            saturated = false
        else
            e = seconds(i)
            work[g] += e
            e > longest[g] && (longest[g] = e)
            saturated &= q.gate_limit[g] <= q.serving[j]
        end
    end
    best = 0.0
    for g in eachindex(work)
        warmup_unclaimed = q.gate_warming[g] && q.gate_running[g] == 0
        v = gate_floor_s(work[g], longest[g], q.gate_limit[g], warmup_unclaimed)
        v > best && (best = v)
    end
    return best, saturated
end

# The estimated seconds of an item of pool `j`, as `unclaimed_work` counts them.
function item_seconds(q::Queues, j::Integer)
    st = q.stats[j]
    scale = st.estimated_s > 0 ? st.estimated_took_s / st.estimated_s : 1.0
    unknown = st.items > 0 ? st.took_s / st.items : q.typical
    return i -> (e = q.est[i]; e > 0 ? e * scale : unknown)
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
