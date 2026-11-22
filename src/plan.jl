# Turning scanned items into a plan: pool order and initial worker slots,
# decided before anything starts. A dry run prints it; drained slots can later
# restart for another pool when doing so shortens estimated completion.

"""
    Why

The class [`order_pool!`](@ref) sorts an item into, in the order the classes are
handed out: what the dry run says about why an item runs where it does.
"""
@enum Why::UInt8 begin
    PINNED_FIRST    # `[order] first`
    SANDBOXED       # needs a process of its own
    RECENT          # failing, a stopped run did not finish it, or it changed or is new since its last run
    LONG            # long enough to decide how long the run takes
    IN_FILE_ORDER   # everything else
    PINNED_LAST     # `[order] last`
end

"""
    Items

Per-item data in plan order, as parallel arrays: the scheduler works with indices
and never touches the bulky `code` and `skip`. An item that names a throttle has
that throttle's `gate`: the scheduler runs at most `Plan.gate_limit[gate]` of the
gate's items at once.
"""
struct Items
    name::Vector{String}
    fileidx::Vector{Int32}
    line::Vector{Int32}
    tags::Vector{Symbol}
    tag_span::Vector{UnitRange{Int32}}
    setups::Vector{Symbol}
    setup_span::Vector{UnitRange{Int32}}
    code::Vector{Expr}
    skip::Vector{Any}
    timeout_s::Vector{Int32}
    retries::Vector{Int32}
    failfast::Vector{Int8}
    est_s::Vector{Float64}      # the newest duration a run recorded; 0 for none
    profile::Vector{ProfileIdx}
    exclusive::Vector{Bool}
    throttle::Vector{Symbol}    # the throttle the item names, NO_THROTTLE for none
    gate::Vector{Int32}         # the throttle's gate index, 0 for none
    why::Vector{Why}            # where `order_pool!` put it, and so why
    failed_ago::Vector{Int32}   # runs since it last did not pass, -1 for none recorded
    cancelled::Vector{Bool}     # whether that was a cancel rather than a verdict
    changed::Vector{Bool}       # edited since its last run or never run
    changed_new::Vector{Bool}   # whether it has never run
    hash::Vector{UInt32}        # see `RawItem`
    # The seed each item draws its numbers from, mixed with its name: the run's, or
    # for an item `runtestsf` runs again, the one it failed with.
    seed::Vector{UInt64}
    package::Vector{Int32}      # the package whose suite holds it, an index into `Plan.packages`
end

Base.length(it::Items) = length(it.name)
tags_of(it::Items, i) = view(it.tags, it.tag_span[i])
setups_of(it::Items, i) = view(it.setups, it.setup_span[i])

"""
    Pool

Items whose profiles have one worker start configuration, possibly from several
profiles or packages, in the order they are handed out as three runs of consecutive
item indices. `profile` names the representative profile used to start workers;
each item retains its own profile for `test_end`:

- `head` goes first, in order, to whichever of the pool's workers asks next;
- `body` is in file order, cut into one stretch per initially assigned worker:
  each walks its own, running neighbouring items that share compiled code;
- `tail` goes last, in order.

What goes where is decided by [`order_pool!`](@ref).
"""
struct Pool
    profile::ProfileIdx
    head::UnitRange{ItemIdx}
    body::UnitRange{ItemIdx}
    tail::UnitRange{ItemIdx}
end

"""
    Startup

Where the time before the first test item went, for the run's header.
"""
mutable struct Startup
    files::Float64   # finding and reading the test files
    plan::Float64   # ordering them and assigning them to workers
    setup::Float64   # the test environment, and precompiling it and the setups
end
Startup() = Startup(0.0, 0.0, 0.0)

"""
    ColdCost

What a fresh worker costs before it runs as fast as one that has been running: the
seconds from starting its process to its being ready for an item (`start_s`), the
compile time its first unit takes beyond what a later unit takes (`compile_s`), and the
mean total compile time each worker process spent across recent runs (`worker_compile_s`).
0 where nothing was measured.
"""
struct ColdCost
    start_s::Float64
    compile_s::Float64
    worker_compile_s::Float64
end
ColdCost() = ColdCost(0.0, 0.0, 0.0)
ColdCost(start_s::Real, compile_s::Real) = ColdCost(Float64(start_s), Float64(compile_s), 0.0)

"""
    Packages

The packages whose suites a run runs, one row each: the one package of a standalone
run, or each participant of a combined one. `cfg` is a package's own configuration,
whose per-package settings its items run with: `timeout`, `retries`,
`item_failfast`, `init_timeout`, `test_end_timeout`, `artifacts_timeout`,
`threads`, and its profiles, groups and `[order]`. The run's own settings are
`Plan.cfg`, which is the package's own in a standalone run.
"""
struct Packages
    name::Vector{String}
    uuid::Vector{Base.UUID}
    root::Vector{String}
    isolated::Vector{Bool}   # runs in its own test environment, on workers of its own
    cfg::Vector{RunConfig}
    suite_names::Vector{Vector{String}}   # every item's name in its suite, chosen or not
end

Base.length(ps::Packages) = length(ps.name)

# The one package of a standalone run at `root`, with the run's configuration.
function single_package(cfg::RunConfig, root::AbstractString, suite_names::Vector{String})
    project = isempty(root) ? nothing : project_file(root)
    t = project === nothing ? Dict{String, Any}() : parse_project(project)
    raw_uuid = get(t, "uuid", "")
    raw_name = get(t, "name", "")
    uuid_str = raw_uuid isa String ? raw_uuid : raw_uuid isa AbstractString ? String(raw_uuid)::String : ""
    name_str = raw_name isa String ? raw_name : raw_name isa AbstractString ? String(raw_name)::String : ""
    uuid = something(tryparse(Base.UUID, uuid_str), Base.UUID(0))
    root_s = root isa String ? root : String(root)::String
    return Packages(String[name_str], Base.UUID[uuid], String[root_s], Bool[false], RunConfig[cfg], Vector{String}[suite_names])
end

struct ReplayPolicyDiff
    item::String
    changes::String
end

struct ReplayEnvDiff
    label::String
    diffs::Vector{String}
    by_path::Vector{String}
    prefs_differ::Bool
    partial::Bool
end

struct ReplayProfileSnapshot
    profile_idx::ProfileIdx
    label::String
    manifest_bytes::Int
    manifest_zlib::Vector{UInt8}
    preferences::String
    same_as_run::Bool
end

mutable struct ReplayDiff
    from::String
    recorded_rev::String
    recorded_worktree::String
    current_rev::String
    current_worktree::String
    gone::Vector{String}
    changed::Vector{String}
    env_moved::Vector{String}
    policies::Vector{ReplayPolicyDiff}
    envs::Vector{ReplayEnvDiff}
    snapshots::Vector{ReplayProfileSnapshot}
end

struct Plan
    items::Items
    files::Vector{String}
    relfiles::Vector{String}    # `files` relative to the project
    profiles::Vector{Profile}
    profile_package::Vector{Int32}   # per profile: the package that declares it
    pools::Vector{Pool}
    slot_pool::Vector{Int32}                 # slot -> pool
    slot_items::Vector{UnitRange{ItemIdx}}   # slot -> its stretch of its pool's body
    pending::Vector{Int32}                   # pools with no slot yet, in pickup order
    gate_limit::Vector{Int32}                # per gate (`Items`): how many of its items run at once
    cold::ColdCost                           # what earlier runs measured a fresh worker to cost
    setups::Vector{Symbol}               # setups to precompile
    cfg::RunConfig
    packages::Packages
    root::String
    startup::Startup
    selection::String   # how the items were chosen, as the run says it; empty for all of them
    suite_names::Vector{String}   # every item's name in the suite, chosen or not, sorted
    # Lines the run's header adds: in a run of several packages, those left out and a
    # replay that found no run state of some of them.
    notes::Vector{String}
    # Differences between the replayed run state and this checkout; `nothing` outside replay.
    replay::Union{Nothing, ReplayDiff}
    # Per-slot fixed item sequences for exact replay (empty outside replay).
    replay_slots::Vector{Vector{ItemIdx}}
end

with_replay(p::Plan, replay::Union{Nothing, ReplayDiff};
            replay_slots::Vector{Vector{ItemIdx}} = p.replay_slots,
            slot_pool::Vector{Int32} = p.slot_pool,
            slot_items::Vector{UnitRange{ItemIdx}} = p.slot_items) = Plan(
    p.items, p.files, p.relfiles, p.profiles, p.profile_package, p.pools, slot_pool,
    slot_items, p.pending, p.gate_limit, p.cold, p.setups, p.cfg, p.packages, p.root,
    p.startup, p.selection, p.suite_names, p.notes, replay, replay_slots
)

with_plan_cfg(p::Plan, cfg::RunConfig) = Plan(
    p.items, p.files, p.relfiles, p.profiles, p.profile_package, p.pools, p.slot_pool,
    p.slot_items, p.pending, p.gate_limit, p.cold, p.setups, cfg, p.packages, p.root,
    p.startup, p.selection, p.suite_names, p.notes, p.replay, p.replay_slots
)

nslots(p::Plan) = length(p.slot_pool)
nitems(p::Plan) = length(p.items)

# No workers: everything happens in this process.
single_process(p::Plan) = p.cfg.workers == 0

# The configuration of the package that holds item `i`, whose per-package settings it
# runs with.
item_cfg(p::Plan, i::Integer) = p.packages.cfg[p.items.package[i]]

# Where an item is, as the run reports it.
itemfile(p::Plan, i::Integer) = p.relfiles[p.items.fileidx[i]]
itemlocation(p::Plan, i::Integer) = string(itemfile(p, i), ":", p.items.line[i])

"""
    History

What earlier runs measured, keyed by item name: how long each item took (`seconds`),
how many runs ago it last did not pass (`failed`, 0 for the newest run), what a fresh
worker cost (`cold`), which of `failed` a cancel decided rather than a verdict
(`cancelled`), each item's source hash in the newest run that ran it (`hashes`), and
every item name seen in kept run states (`known`). Empty on a first run: nothing has
an estimate, and the body is cut by count.
"""
struct History
    seconds::Dict{String, Float64}
    # The failing items, and those the newest run to select them stopped before: how
    # many runs ago that was, 0 for the newest.
    failed::Dict{String, Int}
    cold::ColdCost
    # Of `failed`, the items whose newest entry is a stop's rather than a verdict's.
    cancelled::Set{String}
    hashes::Dict{String, UInt32}   # each item's source hash in the newest run that ran it
    known::Set{String}             # every item a kept run state records
    item_rss_mb::Dict{String, Float64}   # newest recorded worker peak RSS (MiB) per item
    crash_peak_worker_mb::Float64        # peak worker tree RSS (MiB) from recent incomplete/crashed worker runs
    compile_s::Dict{String, Float64}     # newest recorded compile time (s) per item
end
History(seconds = Dict{String, Float64}(), failed = Dict{String, Int}(); cold::ColdCost = ColdCost(),
        cancelled = Set{String}(), hashes = Dict{String, UInt32}(), known = Set{String}(),
        item_rss_mb = Dict{String, Float64}(), crash_peak_worker_mb::Float64 = 0.0,
        compile_s = Dict{String, Float64}()) =
    History(seconds, failed, cold, Set{String}(cancelled), hashes, Set{String}(known),
            item_rss_mb, crash_peak_worker_mb, compile_s)

# Estimate per-worker peak RSS (MiB) and observation coverage (`obs_frac` in [0, 1]) for
# the selected `items` from `histories`. `auto_workers` regularizes low readings toward
# `ASSUMED_WORKER_RSS` (4 GiB) whenever `obs_frac < 1`, while high readings or crash
# peaks (`crash_peak_worker_mb`) are never shrunk downward.
function estimate_worker_rss(items::Vector{RawItem}, histories::Vector{History})
    n = length(items)
    n == 0 && return 0.0, 0.0
    observed = 0
    peak_mb = 0.0
    pkgs_seen = Set{Int32}()
    for it in items
        push!(pkgs_seen, it.package)
        r = get(histories[it.package].item_rss_mb, it.name, 0.0)
        if r > 0.0
            observed += 1
            r > peak_mb && (peak_mb = r)
        end
    end
    for k in pkgs_seen
        p = histories[k].crash_peak_worker_mb
        p > peak_mb && (peak_mb = p)
    end
    return peak_mb, observed / n
end

"""
    plan(raw, cfg; history, histories, root, packages, selection, suite_names) -> Plan

Validate, group into units and pools by worker start configuration, put each pool's
units in the order they are handed out, and cut its body into one stretch per initial
slot. `cfg` holds the run's own settings; `packages` holds each item's package and
its own configuration, and `histories` holds what earlier runs of each measured.
"""
function plan(
        raw::Vector{RawItem}, cfg::RunConfig; history::History = History(), histories::Vector{History} = [history],
        root::AbstractString = "", selection::AbstractString = "",
        suite_names::Vector{String} = String[it.name for it in raw], packages::Packages = single_package(cfg, root, suite_names)
    )
    isempty(raw) && throw(NoTestsError("no test items to run"))
    length(histories) == length(packages) || throw(DimensionMismatch("one history per package"))
    validate_profiles(raw, packages)
    validate_order(raw, packages)

    profiles, profile_package, profile_idx = profile_table(packages, raw)
    draft, gate_limit = build_draft(raw, profile_idx, histories, packages)
    # Pools in order of estimated completion, the latest first: the order they get
    # their first workers in, and the pickup order of those left without one.
    raw_pools, raw_min_prof = pool_units(draft.profile, profiles, profile_package, packages)
    cold = combined_cold(histories)
    estimate = pool_estimate(raw_pools, draft, gate_limit, cold)
    order = sortperm(eachindex(raw_pools); by = k -> (-estimate(k, 1), raw_min_prof[k]))
    pools = raw_pools[order]
    min_prof = raw_min_prof[order]
    slots = count_slots(pools, (k, n) -> estimate(order[k], n), cfg)
    # What a unit of a gate counts as when ordered: its gate's work over its limit.
    gate_floor = Float64[]
    if !isempty(gate_limit)
        gate_floor = zeros(length(gate_limit))
        for u in eachindex(raw)
            g = draft.gate[u]
            g == 0 || (gate_floor[g] += draft.est_s[u])
        end
        gate_floor ./= gate_limit
    end
    has_order = any(c -> !isempty(c.order_first) || !isempty(c.order_last), packages.cfg)
    pin = has_order ? build_pins(packages) : nothing
    for (k, pool) in enumerate(pools)
        order_pool!(pool, raw, draft, slots[k], histories, gate_floor, pin)
    end
    return materialize(raw, draft, pools, min_prof, slots, profiles, profile_package, cfg, packages, root, selection,
                       sort(suite_names), cold, gate_limit)
end

# The file the settings came from, as a message names it.
config_name(cfg) = isempty(cfg.config_file) ? "TestItems.toml" : relpath_or_path(cfg.config_file)

# The configuration file of package `k`, as a message names it: with the package's
# name when the run has several.
config_name(packages::Packages, k::Integer) = length(packages) == 1 ? config_name(packages.cfg[k]) :
    string(packages.name[k], "'s ", config_name(packages.cfg[k]))

function validate_profiles(raw, packages::Packages)
    bad = Dict{Tuple{Int32, Symbol}, Vector{RawItem}}()
    for it in raw
        it.profile === DEFAULT_PROFILE && continue
        haskey(packages.cfg[it.package].profiles, it.profile) ||
            push!(get!(Vector{RawItem}, bad, (it.package, it.profile)), it)
    end
    isempty(bad) && return
    throw(ConfigError(sprint() do io
        if length(packages) == 1
            println(io, "unknown profiles (known: ", join(sort!(string.(collect(keys(packages.cfg[1].profiles)))), ", "), "):")
        else
            println(io, "unknown profiles:")
        end
        for ((k, name), items) in sort!(collect(bad); by = first)
            known = length(packages) == 1 ? "" :
                string(" (known: ", join(sort!(string.(collect(keys(packages.cfg[k].profiles)))), ", "), ")")
            println(io, "  `profile = :$name` has no [profiles.$name] in ", config_name(packages, k), known, ", used by:")
            foreach(it -> println(io, "    ", repr(it.name), " at ", relpath_or_path(it.file), ":", it.line), items)
        end
    end))
end

# Each package's `[order]` names items of its own suite, which a selection that leaves
# them out does not make a mistake: those that run are put in order.
function validate_order(raw, packages::Packages)
    for k in eachindex(packages.name)
        cfg = packages.cfg[k]
        isempty(cfg.order_first) && isempty(cfg.order_last) && continue
        names = union!(Set(packages.suite_names[k]), (it.name for it in raw if it.package == k))
        # A replay hands its items out in the order the recording did, which can name
        # items renamed or deleted since: the replay says which, and the order applies
        # to those still here. The checkout's own `[order]` does not apply to it.
        if !isempty(cfg.replayed_from)
            filter!(in(names), cfg.order_first)
            filter!(in(names), cfg.order_last)
        end
        missing_ = String[]
        for n in Iterators.flatten((cfg.order_first, cfg.order_last))
            n in names || push!(missing_, n)
        end
        check_order_conflicts(cfg)
        isempty(missing_) && continue
        throw(ConfigError(sprint() do io
            println(io, "[order] of ", config_name(packages, k), " names test items that do not exist:")
            for n in missing_
                near = nearest(n, names)
                println(io, "  ", repr(n), isempty(near) ? "" : "  (did you mean $(join(map(repr, near), " or "))?)")
            end
        end))
    end
    return nothing
end

# An item cannot go both first and last.
function check_order_conflicts(cfg)
    last_ = Set(cfg.order_last)
    both = [string(repr(n), " is named by both") for n in cfg.order_first if n in last_]
    isempty(both) && return nothing
    throw(ConfigError("[order] of $(config_name(cfg)) puts these both first and last:\n" *
                      join(("  " * b for b in both), "\n")))
end

# Cheap edit-distance-ish suggestion: a typo'd name should not send anyone hunting.
function nearest(name::AbstractString, names, k::Int = 2; cutoff::Int = max(3, length(name) ÷ 3))
    scored = sort!([(levenshtein(name, n), n) for n in names]; by = first)
    return [n for (d, n) in Iterators.take(scored, k) if d <= cutoff]
end

function levenshtein(a::AbstractString, b::AbstractString)
    m, n = length(a), length(b)
    prev = collect(0:n)
    curr = similar(prev)
    for (i, ca) in enumerate(a)
        curr[1] = i
        for (j, cb) in enumerate(b)
            curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + (ca == cb ? 0 : 1))
        end
        prev, curr = curr, prev
    end
    return prev[n + 1]
end

# The profile/environment pairs available to units: each declared profile in each
# package's test environment, and each pair used by an item in an environment
# directory. `pool_units` later groups compatible pairs by start configuration.
# Package by package, its default profile in the test environment first; record
# the package of each pair too.
function profile_table(packages::Packages, raw::Vector{RawItem})
    triples = Set{Tuple{Int32, Symbol, String}}()
    for k in eachindex(packages.name), n in keys(packages.cfg[k].profiles)
        push!(triples, (Int32(k), n, ""))
    end
    foreach(it -> push!(triples, (it.package, it.profile, it.environment)), raw)
    keys_ = sort!(collect(triples); by = ((k, n, env),) -> (k, n !== DEFAULT_PROFILE, string(n), env))
    for k in eachindex(packages.name)
        used = count(t -> t[1] == k, keys_)
        used <= MAX_PACKAGE_PROFILES || throw(ConfigError(string(
            "the test items", length(packages) == 1 ? "" : " of $(packages.name[k])", " use ", used,
            " pairs of a profile and an environment; at most ", MAX_PACKAGE_PROFILES, " fit"
        )))
    end
    length(keys_) < typemax(ProfileIdx) || throw(ConfigError(string(
        "the packages' test items use ", length(keys_), " pairs of a profile and an environment; at most ",
        typemax(ProfileIdx) - 1, " fit in one run"
    )))
    profiles = Profile[in_environment(run_profile(packages.cfg[k].profiles[n], packages.cfg[k].threads), env)
                       for (k, n, env) in keys_]
    idx = Dict{Tuple{Int32, Symbol, String}, ProfileIdx}(t => ProfileIdx(i) for (i, t) in enumerate(keys_))
    return profiles, Int32[k for (k, _, _) in keys_], idx
end

# Flat SoA scratch buffers indexed `1:length(raw)`, replacing per-item heap
# structs during planning.
struct PlanDraft
    profile::Vector{ProfileIdx}
    gate::Vector{Int32}
    est_s::Vector{Float64}
    compile_s::Vector{Float64}
    file_rank::Vector{Int32}   # sorted file path rank so `order_pool!` compares `Int32`
    key::Vector{Tuple{Int8, Int, Float64, Float64, Int32, Int32}}
    why::Vector{Why}
    failed_ago::Vector{Int32}
    cancelled::Vector{Bool}
    changed::Vector{Bool}
    changed_new::Vector{Bool}
end

# Each item is a unit of its own. An item that names a throttle is a unit of its gate,
# which every package naming the throttle shares, as a limit on what the machine runs
# at once: those packages must give it one limit, 1 where `[throttle]` names none.
# Gates are numbered in the order of their names.
function build_draft(raw::Vector{RawItem}, profile_idx, histories::Vector{History}, packages::Packages)
    n = length(raw)
    uses = Tuple{Int32, Symbol}[]
    for it in raw
        it.throttle === NO_THROTTLE || push!(uses, (it.package, it.throttle))
    end
    gate = Dict{Symbol, Int32}()
    gate_limit = Int32[]
    if !isempty(uses)
        sort!(unique!(uses))
        seen = check_shared_limits(uses, [cfg.throttle for cfg in packages.cfg],
                                   [config_name(packages, k) for k in eachindex(packages.name)])
        names = sort!(collect(keys(seen)))
        sizehint!(gate, length(names))
        gate_limit = Vector{Int32}(undef, length(names))
        for (g, name) in enumerate(names)
            gate[name] = Int32(g)
            gate_limit[g] = Int32(seen[name])
        end
    end

    # Assign dense sorted file ranks once so `order_pool!` sorts bitstype keys.
    ufiles = sort!(unique!(String[it.file for it in raw]))
    rank_of = Dict{String, Int32}(f => Int32(i) for (i, f) in enumerate(ufiles))

    u_profile = Vector{ProfileIdx}(undef, n)
    u_gate = zeros(Int32, n)
    u_est = Vector{Float64}(undef, n)
    u_comp = Vector{Float64}(undef, n)
    u_rank = Vector{Int32}(undef, n)
    for i in 1:n
        it = raw[i]
        u_profile[i] = profile_idx[(it.package, it.profile, it.environment)]
        it.throttle === NO_THROTTLE || (u_gate[i] = gate[it.throttle])
        u_est[i] = get(histories[it.package].seconds, it.name, 0.0)
        u_comp[i] = get(histories[it.package].compile_s, it.name, 0.0)
        u_rank[i] = rank_of[it.file]
    end
    draft = PlanDraft(
        u_profile, u_gate, u_est, u_comp, u_rank,
        Vector{Tuple{Int8, Int, Float64, Float64, Int32, Int32}}(undef, n),
        fill(IN_FILE_ORDER, n), fill(Int32(-1), n), falses(n), falses(n), falses(n)
    )
    return draft, gate_limit
end

"""
    check_shared_limits(uses, limits, names)

That the packages of a run give each throttle they share one limit, 1 where
`[throttle]` names none: a throttle is one for all of them. `uses` holds the package
and name of each throttle an item names, `limits` each package's `[throttle]` and
`names` how a message names each package's configuration file.
"""
function check_shared_limits(uses, limits::AbstractVector{<:AbstractDict{Symbol, Int}}, names::AbstractVector{<:AbstractString})
    seen = Dict{Symbol, Int}()
    for (k, name) in uses
        l = get(limits[k], name, 1)
        get!(seen, name, l) == l && continue
        ks = sort!(unique!([k for (k, n) in uses if n === name]))
        said(k) = string(names[k], " ", haskey(limits[k], name) ? limits[k][name] : "1, by not naming it in [throttle]")
        throw(ConfigError(string(
            "throttle `:", name, "` is one for every package that names it, and they give it different limits: ",
            join(map(said, ks), "; "), ". Give it the same limit in each"
        )))
    end
    return seen
end

const PoolKey = Tuple{Tuple{Vector{String}, String, Vector{Pair{String, String}}, Expr, String, String},
                      Tuple{Symbol, Int, String}}

# The units of each pool: one pool for each `pool_key` of the units' profiles, in the
# order of their first profile, paired with each pool's representative (minimum) profile.
function pool_units(u_profile::Vector{ProfileIdx}, profiles::Vector{Profile},
                    profile_package::Vector{Int32}, packages::Packages)
    # A profile's pool depends on the profile alone: its key is made once per profile.
    pool_of = Dict{PoolKey, Int}()
    of_profile = Vector{Int}(undef, length(profiles))
    for j in eachindex(profiles)
        k = profile_package[j]
        of_profile[j] = get!(pool_of, pool_key(profiles[j], k, packages.root[k], packages.isolated[k]),
                             length(pool_of) + 1)
    end
    raw_pools = [Int[] for _ in 1:length(pool_of)]
    for u in eachindex(u_profile)
        push!(raw_pools[of_profile[u_profile[u]]], u)
    end
    pools = Vector{Int}[]
    min_prof = ProfileIdx[]
    for pool in raw_pools
        isempty(pool) && continue
        push!(pools, pool)
        push!(min_prof, minimum(u -> u_profile[u], pool))
    end
    perm = sortperm(min_prof)
    return pools[perm], min_prof[perm]
end

"""
    pool_key(prof, k, root, isolated)

What tells the workers of profile `prof` of package `k`, whose root is `root`, from
others: equal keys, interchangeable workers. Its start configuration
(`start_configuration`), so that profiles that differ only in `test_end`, which runs
after each item rather than when a worker starts, share workers, whichever packages
declare them. A profile with an `init` shares only with profiles whose `init` runs in
the same directory (`init_dir`): its package's root, or the workspace root for a
profile that the workspace shares. The profiles of an isolated package, which runs
in its own test environment, are its own.
"""
function pool_key(prof::Profile, k::Integer, root::AbstractString, isolated::Bool)::PoolKey
    owner = isolated ? (:package, Int(k), "") :
        isempty(prof.init.args) ? (:none, 0, "") : (:init_dir, 0, String(init_dir(prof, root)))
    return (start_configuration(prof), owner)
end

# Fraction of known per-worker compile time charged against each additional worker
# started in a pool (reflecting duplicated compilation of shared definitions and
# parallel-JIT overhead). Adding worker `n + 1` only pays off when its wall-time
# reduction exceeds `cold.start_s + WORKER_COMPILE_OVERHEAD * per_worker_compile`.
const WORKER_COMPILE_OVERHEAD = 0.20

"""
    pool_estimate(pools, draft, gate_limit, cold) -> completion(k, n)

The estimated completion of pool `k` with `n` workers, in seconds: the time a worker
takes to be ready for its first item, as earlier runs measured it, plus each additional
worker's marginal start and duplicated-compilation cost (`cold.start_s` plus
`WORKER_COMPILE_OVERHEAD` of the pool's per-worker compile time), plus the larger of
the pool's work shared among its workers, its longest unit and each gate's work in it
over the gate's limit, which no number of workers shortens. An item without a
recorded duration counts as the typical item.
"""
function pool_estimate(pools::Vector{Vector{Int}}, draft::PlanDraft, gate_limit::Vector{Int32}, cold::ColdCost)
    typical = typical_estimate(draft.est_s)
    est(u) = (s = draft.est_s[u]; s > 0 ? s : typical)
    np = length(pools)
    work = Vector{Float64}(undef, np)
    longest = Vector{Float64}(undef, np)
    extra = Vector{Float64}(undef, np)
    throttled = zeros(Float64, np)
    has_gates = !isempty(gate_limit)
    gate_work = has_gates ? Vector{Float64}(undef, length(gate_limit)) : Float64[]
    for k in 1:np
        pool = pools[k]
        w = 0.0
        c = 0.0
        l = 0.0
        has_gates && fill!(gate_work, 0.0)
        for u in pool
            e = est(u)
            w += e
            c += draft.compile_s[u]
            e > l && (l = e)
            if has_gates
                g = draft.gate[u]
                g == 0 || (gate_work[g] += e)
            end
        end
        work[k] = w
        longest[k] = l
        # A fresh worker always pays at least the recorded cold-start compile excess;
        # beyond that, cap full-suite per-worker compile at this pool's own compile work.
        per_worker_comp = max(cold.compile_s, min(c, cold.worker_compile_s))
        extra[k] = cold.start_s + WORKER_COMPILE_OVERHEAD * per_worker_comp
        if has_gates
            t = 0.0
            for g in eachindex(gate_limit)
                v = gate_work[g] / gate_limit[g]
                v > t && (t = v)
            end
            throttled[k] = t
        end
    end
    ready = cold.start_s + cold.compile_s
    return (k, n) -> ready + (n - 1) * extra[k] + max(work[k] / n, longest[k], throttled[k])
end

# What a fresh worker cost in the earlier runs of the packages: the mean of what each
# package's runs measured, of those that measured it.
function combined_cold(histories::Vector{History})
    mean_of(f) = (xs = [f(h.cold) for h in histories if f(h.cold) > 0]; isempty(xs) ? 0.0 : sum(xs) / length(xs))
    return ColdCost(mean_of(c -> c.start_s), mean_of(c -> c.compile_s), mean_of(c -> c.worker_compile_s))
end

# `workers` is a hard cap on live processes, because that cap is what bounds
# memory and duplicated compilation. Every pool gets a slot while there are slots
# to give, in the order the pools come in, the latest estimated completion first.
# Each remaining slot goes to the pool whose completion is latest among those it
# shortens, never more slots than a pool has units. A pool left without a slot is
# taken by the first slot whose own pool runs out of work, and a slot whose pool
# runs out goes on where it takes the most off the others (`claim!`).
function count_slots(pools::Vector{Vector{Int}}, completion, cfg::RunConfig)
    n = zeros(Int, length(pools))
    budget = max(cfg.workers, 1)
    for k in eachindex(pools)
        budget == 0 && break
        n[k] = 1
        budget -= 1
    end
    helps(k) = 0 < n[k] < length(pools[k]) && completion(k, n[k] + 1) < completion(k, n[k])
    while budget > 0
        k = argmax(k -> helps(k) ? completion(k, n[k]) : -Inf, eachindex(pools))
        helps(k) || break
        n[k] += 1
        budget -= 1
    end
    return n
end

# Whether an item is what is being worked on: its source differs from the newest run
# that ran it, or no kept run state records it although others record the suite. A
# hash of 0 is none: an item with none recorded is not taken for edited.
edited(it::RawItem, h::History) = (r = get(h.hashes, it.name, UInt32(0)); r != 0 && it.hash != 0 && r != it.hash)
never_ran(it::RawItem, h::History) = !isempty(h.known) && !(it.name in h.known)

const HEAD_CLASSES = Int8(PINNED_FIRST):Int8(LONG)
const TAIL_CLASS = Int8(PINNED_LAST)

# Under this many seconds a unit is never long, whatever its share: started last, it
# ends the run a moment later, and a suite of quick items would otherwise be all head.
const LONG_FLOOR_S = 3.0

function build_pins(packages::Packages)
    pin = [Dict{String, Int}() for _ in eachindex(packages.name)]
    for (k, cfg) in enumerate(packages.cfg)
        for (i, n) in enumerate(cfg.order_first)
            pin[k][n] = i - length(cfg.order_first) - 1
        end
        for (i, n) in enumerate(cfg.order_last)
            pin[k][n] = i
        end
    end
    return pin
end

"""
    order_pool!(pool, raw, draft, nslots, histories, gate_floor, pin)

Sort a pool's units into the order they are handed out, by class and then within
it:

0. `[order] first`, in the order listed;
1. sandboxed units, in file order: each needs a fresh process, and at the start
   every process is fresh, so running them first discards no compiled code;
2. units whose item is failing, however long ago it failed, that the newest run to
   select it stopped before, or that was edited since its last run or never ran: the
   answer most likely to matter, as early as it can be had. An edited or new item
   and a failure in the newest run come first, then older failures, the
   more recent first; within each, the units class 3 would take, longest first,
   then file order;
3. units long enough to decide how long the run takes — more than a quarter of
   one slot's share of the pool's work, and at least `LONG_FLOOR_S` — longest first.
   A unit of a gate counts as long as its gate's work over its limit, `gate_floor`,
   when that is longer: the gate's units start early and together, the longest of
   them first;
4. everything else, in file order, where neighbours share compiled code;
5. `[order] last`, in the order listed.

Classes 0–3 are the pool's head, 4 its body and 5 its tail. The class is recorded as a [`Why`](@ref), whose
values are these numbers. Each package's `[order]` names its own items; in a pool
that serves several packages, see [`order_blocks!`](@ref).
"""
function order_pool!(pool::Vector{Int}, raw::Vector{RawItem}, draft::PlanDraft, nslots::Int,
                     histories::Vector{History}, gate_floor::Vector{Float64},
                     pin::Union{Nothing, Vector{Dict{String, Int}}})
    pinned = nothing
    if pin !== nothing
        pinned = Dict{Int, Int}()
        for u in pool
            it = raw[u]
            p = get(pin[it.package], it.name, 0)
            p == 0 || (pinned[u] = p)
        end
        isempty(pinned) ? (pinned = nothing) : order_blocks!(pinned, pool, raw, draft.est_s)
    end
    share = sum(u -> draft.est_s[u], pool; init = 0.0) / max(nslots, 1)
    for u in pool
        it = raw[u]
        history = histories[it.package]
        p = pinned === nothing ? 0 : get(pinned, u, 0)
        ago = get(history.failed, it.name, typemax(Int))
        draft.failed_ago[u] = ago == typemax(Int) ? Int32(-1) : Int32(ago)
        draft.cancelled[u] = ago != typemax(Int) && it.name in history.cancelled
        is_new = never_ran(it, history)
        is_changed = is_new || edited(it, history)
        draft.changed[u] = is_changed
        draft.changed_new[u] = is_new
        urgency = is_changed ? 0 : ago
        est_s = draft.est_s[u]
        g = draft.gate[u]
        est = g == 0 ? est_s : max(est_s, gate_floor[g])
        long = est >= LONG_FLOOR_S && est > share / 4
        why = p < 0 ? PINNED_FIRST : p > 0 ? PINNED_LAST : it.exclusive ? SANDBOXED :
            urgency < typemax(Int) ? RECENT : long ? LONG : IN_FILE_ORDER
        draft.why[u] = why
        by_length = long && (why === RECENT || why === LONG)
        draft.key[u] = (Int8(why), why === RECENT ? urgency : p, by_length ? -est : 0.0,
                        by_length ? -est_s : 0.0, draft.file_rank[u], it.line)
    end
    return sort!(pool; by = u -> draft.key[u])
end

"""
    order_blocks!(pinned, pool, raw, est_s)

Where `[order]` puts the units of a pool that several packages' lists pin: each
package's `first` items stay one block of the head, in the order of its list, and
the blocks go the longest estimated first; the same for `last` and the tail.
`pinned` holds each unit's place, below 0 in the head and above 0 in the tail, each
ascending in the order handed out, and is shifted in place.
"""
function order_blocks!(pinned::Dict{Int, Int}, pool::Vector{Int}, raw::Vector{RawItem}, est_s::Vector{Float64})
    for side in (-1, 1)
        on_side = [u for u in pool if sign(get(pinned, u, 0)) == side]
        est = Dict{Int32, Float64}()
        for u in on_side
            k = raw[u].package
            est[k] = get(est, k, 0.0) + est_s[u]
        end
        length(est) > 1 || continue
        ranked = sort!(collect(keys(est)); by = k -> (-est[k], k))
        rank = Dict{Int32, Int}(k => r for (r, k) in enumerate(ranked))
        span = maximum(u -> abs(pinned[u]), on_side) + 1
        for u in on_side
            r = rank[raw[u].package]
            pinned[u] += side < 0 ? -(length(ranked) - r) * span : (r - 1) * span
        end
    end
    return pinned
end

# What a unit or an item without an estimate counts as: the median of the estimates
# there are, or a second when there are none, so that those with nothing known still
# count the same as one another.
function typical_estimate(est::AbstractVector{Float64})
    known = sort!(filter(>(0), est))
    return isempty(known) ? 1.0 : known[(end + 1) ÷ 2]
end

"""
    stretches(body, est, file, n) -> Vector{UnitRange}

`body` cut into `n` stretches holding about the same estimated work — the same
number of units when nothing is estimated — each cut made at the file boundary
nearest its ideal place, so that one worker walks a whole file. A unit with no
estimate counts as a typical one.
"""
function stretches(body::UnitRange{ItemIdx}, est::Vector{Float64}, file::Vector{Int32}, n::Int)
    n == 0 && return UnitRange{ItemIdx}[]
    n == 1 && return UnitRange{ItemIdx}[body]
    m = length(body)
    bview = view(est, body)
    guess = typical_estimate(bview)
    cum = Vector{Float64}(undef, m)
    acc = 0.0
    for j in 1:m
        e = bview[j]
        acc += e > 0 ? e : guess
        cum[j] = acc
    end
    between_files = Int[]
    for j in 1:(m - 1)
        file[body[j]] != file[body[j + 1]] && push!(between_files, j)
    end
    has_files = !isempty(between_files)
    # `cum` is strictly increasing, so binary search finds the nearest cut in O(log |between_files|).
    out = Vector{UnitRange{ItemIdx}}(undef, n)
    prev = 0
    total = m == 0 ? 0.0 : cum[m]
    for k in 1:(n - 1)
        target = k * total / n
        cut = if m <= 1
            m
        elseif has_files
            lo, hi = 1, length(between_files) + 1
            while lo < hi
                mid = (lo + hi) >>> 1
                if cum[between_files[mid]] < target
                    lo = mid + 1
                else
                    hi = mid
                end
            end
            if lo == 1
                between_files[1]
            elseif lo > length(between_files)
                between_files[end]
            else
                a, b = between_files[lo - 1], between_files[lo]
                abs(cum[a] - target) <= abs(cum[b] - target) ? a : b
            end
        else
            idx = searchsortedfirst(cum, target)
            if idx == 1
                1
            elseif idx >= m
                m - 1
            else
                abs(cum[idx - 1] - target) <= abs(cum[idx] - target) ? idx - 1 : idx
            end
        end
        out[k] = body[(prev + 1):cut]
        prev = cut
    end
    out[n] = body[(prev + 1):m]
    return out
end

function materialize(
        raw::Vector{RawItem}, draft::PlanDraft, pools::Vector{Vector{Int}}, min_prof::Vector{ProfileIdx},
        slots::Vector{Int}, profiles::Vector{Profile}, profile_package::Vector{Int32}, cfg::RunConfig,
        packages::Packages, root::AbstractString, selection::AbstractString, suite_names::Vector{String},
        cold::ColdCost, gate_limit::Vector{Int32}
    )
    # Pool by pool, in the order each hands out its items: item index order is the
    # order of the plan, which is what the dry run prints and what the run state
    # is indexed by.
    n = length(raw)
    name = Vector{String}(undef, n); fileidx = Vector{Int32}(undef, n); line = Vector{Int32}(undef, n)
    tags = Symbol[]; tag_span = Vector{UnitRange{Int32}}(undef, n)
    setups = Symbol[]; setup_span = Vector{UnitRange{Int32}}(undef, n)
    code = Vector{Expr}(undef, n); skip = Vector{Any}(undef, n)
    timeout = Vector{Int32}(undef, n); retries = Vector{Int32}(undef, n)
    failfast = Vector{Int8}(undef, n); est = Vector{Float64}(undef, n)
    profile = Vector{ProfileIdx}(undef, n); exclusive = Vector{Bool}(undef, n)
    throttle = Vector{Symbol}(undef, n); gate = Vector{Int32}(undef, n)
    why = Vector{Why}(undef, n); failed_ago = Vector{Int32}(undef, n); cancelled = Vector{Bool}(undef, n)
    changed = Vector{Bool}(undef, n); changed_new = Vector{Bool}(undef, n)
    item_hash = Vector{UInt32}(undef, n); item_seed_ = Vector{UInt64}(undef, n); item_package = Vector{Int32}(undef, n)
    files = String[]; fileids = Dict{String, Int32}()
    all_setups = Set{Symbol}()
    ps = Vector{Pool}(undef, length(pools))
    slot_pool = Int32[]; slot_items = UnitRange{ItemIdx}[]; pending = Int32[]
    pos = 0
    for (k, pool) in enumerate(pools)
        start = pos
        nhead = 0
        ntail = 0
        for u in pool
            pos += 1
            it = raw[u]
            name[pos] = it.name
            fid = get!(fileids, it.file) do
                push!(files, it.file); Int32(length(files))
            end
            fileidx[pos] = fid; line[pos] = it.line
            tag_span[pos] = span!(tags, it.tags)
            setup_span[pos] = span!(setups, it.setups)
            isempty(it.setups) || union!(all_setups, it.setups)
            code[pos] = it.code; skip[pos] = it.skip
            timeout[pos] = it.timeout_s; retries[pos] = it.retries
            failfast[pos] = it.failfast
            est[pos] = draft.est_s[u]
            profile[pos] = draft.profile[u]; exclusive[pos] = it.exclusive
            throttle[pos] = it.throttle; gate[pos] = draft.gate[u]
            cls = draft.key[u][1]
            cls in HEAD_CLASSES && (nhead += 1)
            cls == TAIL_CLASS && (ntail += 1)
            why[pos] = draft.why[u]; failed_ago[pos] = draft.failed_ago[u]
            cancelled[pos] = draft.cancelled[u]
            changed[pos] = draft.changed[u]
            changed_new[pos] = draft.changed_new[u]
            item_hash[pos] = it.hash; item_package[pos] = it.package
            # The run's seed is every package's; a failure's own is its package's.
            item_seed_[pos] = get(packages.cfg[it.package].item_seeds, it.name, cfg.seed)
        end
        between(a, b) = ItemIdx(a):ItemIdx(b)
        body = between(start + nhead + 1, pos - ntail)
        # Its workers start with the configuration of its first profile, which its
        # other profiles share.
        ps[k] = Pool(min_prof[k], between(start + 1, start + nhead), body,
                     between(pos - ntail + 1, pos))
        slots[k] == 0 && push!(pending, Int32(k))
        for r in stretches(body, est, fileidx, slots[k])
            push!(slot_pool, Int32(k)); push!(slot_items, r)
        end
    end

    items = Items(
        name, fileidx, line, tags, tag_span, setups, setup_span,
        code, skip, timeout, retries, failfast, est,
        profile, exclusive, throttle, gate, why, failed_ago, cancelled, changed, changed_new,
        item_hash, item_seed_, item_package
    )
    relfiles = String[relpath_or_path(f, root) for f in files]
    return Plan(
        items, files, relfiles,
        profiles, profile_package, ps, slot_pool, slot_items, pending, gate_limit, cold,
        sort!(collect(all_setups)), cfg, packages, String(root), Startup(), String(selection), suite_names, String[], nothing, Vector{ItemIdx}[]
    )
end

function span!(store::Vector{T}, vals::Vector{T}) where {T}
    first_ = Int32(length(store) + 1)
    append!(store, vals)
    return first_:Int32(length(store))
end
