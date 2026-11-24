# The run states of a combined run: one attempted in each participating package's
# own run state directory, which that package reads as a run of its own.

"""
    package_plan(p, k) -> Plan

Package `k`'s part of a combined plan, as a plan of its own: its items
and profiles in the order of `p`, renumbered, with paths relative to the
package's root, and its own configuration under the run's own settings. What its run
state holds. It has no pools or slots: the run's slots served every package.
"""
function package_plan(p::Plan, k::Integer)
    is = [i for i in 1:nitems(p) if p.items.package[i] == k]
    js = [j for j in eachindex(p.profiles) if p.profile_package[j] == k]
    profile = Dict{ProfileIdx, ProfileIdx}(ProfileIdx(j) => ProfileIdx(n) for (n, j) in enumerate(js))
    files = unique!([p.items.fileidx[i] for i in is])
    file = Dict{Int32, Int32}(f => Int32(n) for (n, f) in enumerate(files))
    tags, tag_span, setups, setup_span = Symbol[], UnitRange{Int32}[], Symbol[], UnitRange{Int32}[]
    for i in is
        push!(tag_span, span!(tags, collect(tags_of(p.items, i))))
        push!(setup_span, span!(setups, collect(setups_of(p.items, i))))
    end
    it = p.items
    items = Items(
        it.name[is], Int32[file[it.fileidx[i]] for i in is], it.line[is], tags, tag_span, setups, setup_span,
        it.code[is], it.skip[is], it.timeout_s[is], it.retries[is], it.failfast[is], it.est_s[is],
        ProfileIdx[profile[it.profile[i]] for i in is], it.exclusive[is], it.throttle[is], it.gate[is],
        it.why[is], it.failed_ago[is], it.cancelled[is], it.changed[is], it.changed_new[is],
        it.hash[is], it.seed[is], ones(Int32, length(is))
    )
    root = p.packages.root[k]
    cfg = under_run_settings(p.packages.cfg[k], p.cfg)
    abs_files = p.files[files]
    relfiles = String[relpath_or_path(f, root) for f in abs_files]
    packages = Packages([p.packages.name[k]], [p.packages.uuid[k]], [root], [p.packages.isolated[k]], [cfg],
                        [p.packages.suite_names[k]])
    return Plan(
        items, abs_files, relfiles,
        p.profiles[js], ones(Int32, length(js)), Pool[], Int32[], UnitRange{ItemIdx}[], Int32[], p.gate_limit, p.gate_warmup, p.cold,
        sort!(unique!(copy(setups))), cfg, packages, root, p.startup, p.selection, p.packages.suite_names[k], String[], nothing, Vector{ItemIdx}[]
    )
end

# The settings a package's items ran with in a run of several packages: its own
# (`PACKAGE_KEYS` plus per-package tables/metadata), and the run's for what is the
# run's (`RUN_WIDE_KEYS`) and how the run was made.
function under_run_settings(own::RunConfig, run::RunConfig)::RunConfig
    return with_config(
        run;
        threads = own.threads,
        timeout_s = own.timeout_s,
        init_timeout_s = own.init_timeout_s,
        test_end_timeout_s = own.test_end_timeout_s,
        artifacts_timeout_s = own.artifacts_timeout_s,
        retries = own.retries,
        item_failfast = own.item_failfast,
        skip_environment = own.skip_environment,
        profiles = own.profiles,
        groups = own.groups,
        order_first = own.order_first,
        order_last = own.order_last,
        throttle = own.throttle,
        item_seeds = own.item_seeds,
        config_file = own.config_file,
    )
end

"""
    RunStateSet

The run states of a combined run, one in each package's own run state
directory, each holding only that package's items by their index in its own plan
(see `package_plan`), so that the package's history, `runtestsf` and `debug` read the
run as one of its own. A write about an item goes to its package's run state. A
worker belongs to no package: its start goes to the run state of the package of the
first item it runs, and its end to the run state of each package it ran items of, so
that a worker that runs no item is in none. One shared heartbeat beats every open file.
"""
struct RunStateSet
    files::Vector{Union{Nothing, RunStateFile}}   # per package; nothing for one that could not be opened
    package::Vector{Int32}                        # per item of the run
    local_item::Vector{ItemIdx}                   # per item of the run: its index in its package's plan
    lock::ReentrantLock                           # guards `up` and `served`
    up::Dict{Int32, Tuple{Int, Float64, Float64}} # by pid: a worker's slot, start and ready, until its first item
    served::Dict{Int32, Vector{Int32}}            # by pid: the packages a live worker ran items of
    heartbeat::Base.RefValue{Union{Nothing, Tuple{Timer, Task}}}
end

function start_set_heartbeat(files::Vector{Union{Nothing, RunStateFile}})
    any(!isnothing, files) || return nothing
    timer = Timer(HEARTBEAT_S; interval = HEARTBEAT_S)
    task = shielded(() -> Threads.@spawn beat_set(files, timer))
    return (timer, task)
end

function beat_set(files::Vector{Union{Nothing, RunStateFile}}, timer::Timer)
    while true
        try
            wait(timer)
            any_open = false
            for rsf in files
                (rsf !== nothing && isopen(rsf.io)) || continue
                any_open = true
                update!(io -> write(io, RS_MAGIC), rsf, 0)
            end
            any_open || break
        catch e
            e isa EOFError && break
            is_interrupt(e) || break
            RuntestsWorkers.forward_interrupt(e)
        end
    end
    return nothing
end

function write_status!(set::RunStateSet, i::Integer, state::ItemState, attempt::Integer, slot::Integer;
                       pid = 0, kwargs...)
    k = set.package[i]
    pid == 0 || worker_served!(set, k, pid)
    return write_status!(set.files[k], set.local_item[i], state, attempt, slot; pid, kwargs...)
end

# Package `k` had an item on the worker `pid`: the worker's start goes to `k`'s run
# state when it is the first, and its end will go there.
function worker_served!(set::RunStateSet, k::Integer, pid::Integer)
    up = nothing
    @lock set.lock begin
        up = pop!(set.up, Int32(pid), nothing)
        served = get!(Vector{Int32}, set.served, Int32(pid))
        k in served || push!(served, Int32(k))
    end
    up === nothing || append_event!(set.files[k], EVENT_WORKER_UP, 0, up[1], pid, up[2], up[3])
    return nothing
end

function append_event!(set::RunStateSet, kind::UInt8, state::Integer, slot::Integer, pid::Integer, t0::Real, t1::Real;
                       item::Integer = 0, kwargs...)
    if kind == EVENT_WORKER_UP
        @lock set.lock set.up[Int32(pid)] = (Int(slot), Float64(t0), Float64(t1))
    elseif kind == EVENT_WORKER_DOWN
        served = @lock set.lock begin
            delete!(set.up, Int32(pid))
            pop!(set.served, Int32(pid), Int32[])
        end
        for k in served
            append_event!(set.files[k], kind, state, slot, pid, t0, t1; kwargs...)
        end
    else
        append_event!(set.files[set.package[item]], kind, state, slot, pid, t0, t1; item = set.local_item[item], kwargs...)
    end
    return nothing
end

write_memory!(set::RunStateSet, m) = (foreach(f -> write_memory!(f, m), set.files); nothing)
function finish_run_state!(set::RunStateSet, ending::RunEnding = ENDING_FINISHED; exiting::Bool = false)
    beating = set.heartbeat[]
    if beating !== nothing
        set.heartbeat[] = nothing
        exiting || (close(first(beating)); wait(last(beating)))
    end
    foreach(f -> finish_run_state!(f, ending; exiting), set.files)
    return nothing
end
mark_ending!(set::RunStateSet, ending::RunEnding) = (foreach(f -> mark_ending!(f, ending), set.files); nothing)

"""
    open_runstate_set(p, start, runid) -> RunStateSet

Attempt a run state for each package of `p` in its own run state directory. Each
record holds the shared run ID, the participant list, its isolation flag, and its
items' environment directories, which link the package records for replay. A run
state that cannot be opened is done without, as in a run of one package, and the
others are written.
"""
function open_runstate_set(p::Plan, start::Float64, runid::AbstractString; worktree::AbstractString = "unknown",
                           worker_projects::Vector{Vector{String}} = [String[] for _ in p.packages.name])
    return open_runstate_set_impl(p, start, String(runid)::String, String(worktree)::String, worker_projects)
end

function open_runstate_set_impl(p::Plan, start::Float64, runid::String, worktree::String,
                                worker_projects::Vector{Vector{String}})
    n = length(p.packages)
    plans = Plan[package_plan(p, k) for k in 1:n]
    workspace = p.root
    participants = join((string(p.packages.name[k], '\t', p.packages.uuid[k], '\t', rel_slash(p.packages.root[k], workspace),
                                '\t', p.packages.isolated[k]) for k in 1:n), '\n')
    # Compress the shared active manifest once for all `n` package records, and run one
    # shared heartbeat timer instead of `n` separate timers/tasks.
    manifest = Vector{UInt8}(environment_manifest())
    shared_env = (manifest, isempty(manifest) ? UInt8[] : zlib_compress(manifest))
    # Partition item indices by package in one O(nitems) pass.
    by_pkg = [Int[] for _ in 1:n]
    local_item = Vector{ItemIdx}(undef, nitems(p))
    for i in 1:nitems(p)
        k = p.items.package[i]
        push!(by_pkg[k], i)
        local_item[i] = ItemIdx(length(by_pkg[k]))
    end
    files = Vector{Union{Nothing, RunStateFile}}(undef, n)
    for k in 1:n
        environments = join((environment_of_item(p, i) for i in by_pkg[k]), '\n')
        meta = ["combined_run" => String(runid), "participants" => participants,
                "isolated" => string(p.packages.isolated[k]), "environments" => environments,
                "worktree" => String(worktree)]
        path = nothing
        files[k] = try
            path = new_runstate_path(p.packages.root[k])
            init_run_state(path, plans[k]; start, meta, worker_projects = worker_projects[k],
                           heartbeat = false, shared_env)
        catch e
            is_interrupt(e) && rethrow()
            path === nothing || remove_runstate(path)
            @warn "Runtests: could not open a run state file for $(p.packages.name[k]); continuing without one" exception = e
            nothing
        end
    end
    return RunStateSet(files, copy(p.items.package), local_item, ReentrantLock(),
                       Dict{Int32, Tuple{Int, Float64, Float64}}(), Dict{Int32, Vector{Int32}}(),
                       Ref{Union{Nothing, Tuple{Timer, Task}}}(start_set_heartbeat(files)))
end

# The environment directory of item `i`, relative to its package's root, or empty for
# its package's test environment.
function environment_of_item(p::Plan, i::Integer)
    env = p.profiles[p.items.profile[i]].environment
    return isempty(env) ? "" : rel_slash(env, p.packages.root[p.items.package[i]])
end

"""
    replay_records(path, ps; announce) -> (; given, records, why, gone)

The run states of the combined run that the run state at `path` is one of: `given`,
that one, and for each of the participants `ps`, its own run state of that run, found
by the run's ID in the package's own run state directory, or `nothing` with the
reason in `why`. `gone` names the packages of the recorded run whose run state is no
longer there, deleted with the older runs perhaps, which the replay runs without.
"""
function replay_records(path::String, ps::Participants; announce::Bool = true)
    given = read_run_state(path)
    given === nothing && throw(ConfigError(
        "could not read a run state from $path: it is missing, damaged, or written by another version of Runtests"
    ))
    id = get(given.meta, "combined_run", "")
    isempty(id) && throw(ConfigError(
        "$path is the run state of a run of one package; replay it with `Runtests.runtests(replay = ...)` in its package"
    ))
    recorded = Dict{String, String}()   # each recorded package's directory relative to the workspace => its name
    for line in split(get(given.meta, "participants", ""), '\n'; keepempty = false)
        fields = split(line, '\t')
        length(fields) == 4 || throw(ConfigError("$path records its run's packages in a form this version does not read"))
        recorded[String(fields[3])] = String(fields[1])
    end
    records = Union{Nothing, RunStateRecord}[]
    why = String[]
    exported = exported_siblings(path, ps.name, id)
    rels = String[rel_slash(r, ps.workspace) for r in ps.root]
    for k in eachindex(ps.root)
        rel = rels[k]
        if !haskey(recorded, rel)
            push!(records, nothing); push!(why, "it was not in the replayed run")
            continue
        end
        project = project_id(ps.root[k])
        rs = if get(given.meta, "project_id", "") == project
            given
        else
            found = get(exported, project, nothing)
            found === nothing ? findfirst_record(ps.root[k], id) : found
        end
        push!(records, rs)
        push!(why, rs === nothing ? "its run state of the replayed run is gone" : "")
    end
    present = Set(rels[k] for k in eachindex(ps.root) if records[k] !== nothing)
    in_workspace = Set(rels)
    gone = sort!([name for (rel, name) in recorded if rel in in_workspace && !(rel in present)])
    all(isnothing, records) && throw(ConfigError(string(
        "no package of the workspace at ", ps.workspace, " has a run state of the run that ", basename(path),
        " is one of", isempty(gone) ? "" : string(": those of ", join(gone, ", "), " are gone")
    )))
    m(k) = get(given.meta, k, "")
    announce && println(
        stdout, label_prefix(), "replaying the combined run of ", basename(path), ": ",
        plural(count(!isnothing, records), "package"), " · seed ", m("seed"), " · recorded with julia ", m("julia"),
        " on ", m("machine"), isempty(m("revision")) ? "" : string(" at rev ", first(m("revision"), 10)),
        m("worktree") == "dirty" ? " with uncommitted changes" : ""
    )
    return (; given, records, why, gone)
end

# The run states of the combined run `id` that the files beside `path` hold, by project,
# for packages called `names`, read once for all of them. `RUNTESTS_ARTIFACT_DIR` keeps
# each package's run in a directory of the package's name, and a killed job's recovery
# step (see the CI guide) copies the run directories side by side. Either way a record
# copied from there has its run's other packages beside it, and no history needs them.
function exported_siblings(path::AbstractString, names, id::AbstractString)
    bundle = dirname(abspath(record_path(path)))
    dirs = unique!([dirname(bundle); [joinpath(dirname(dirname(bundle)), name) for name in names]])
    found = Dict{String, RunStateRecord}()
    for dir in dirs
        isdir(dir) || continue
        for d in readdir(dir; join = true)
            endswith(d, RUNDATA_EXT) || continue
            fp = joinpath(d, RUNSTATE_FILE)
            rm = read_run_meta(fp)
            (rm === nothing || get(rm.meta, "combined_run", "") != id) && continue
            proj = get(rm.meta, "project_id", "")
            haskey(found, proj) && continue
            rs = read_run_state(fp)
            rs === nothing || (found[proj] = rs)
        end
    end
    return found
end

# The run state of the combined run `id` in the run state directory of the package at
# `root`, or `nothing`. Matches via lightweight `read_run_meta`, full-reading only on hit.
function findfirst_record(root::AbstractString, id::AbstractString)
    project = project_id(root)
    matches = Tuple{Float64, String}[]
    for f in runstate_files(root)
        rm = read_run_meta(f)
        rm === nothing && continue
        get(rm.meta, "project_id", "") == project || continue
        get(rm.meta, "combined_run", "") == id && push!(matches, (rm.start_unix, f))
    end
    isempty(matches) && return nothing
    sort!(matches)
    return read_run_state(first(matches)[2])
end

# A replay's settings: each package's under its run state's profiles, `[order]`, flags
# and seeds, and the run's under the replayed run's flags and manifest. `seeded` when the
# call gives a seed of its own, which every item then draws from.
function replayed_configs(run::RunConfig, cfgs::Vector{RunConfig}, records::Vector, roots::Vector{String},
                          given::RunStateRecord, seeded::Bool)
    replayed = map(cfgs, records, roots) do cfg, rs, root
        rs === nothing && return cfg
        out = replayed_config(cfg, rs, root)
        if !seeded
            run_seed = tryparse(UInt64, get(rs.meta, "seed", ""))
            for it in rs.items
                it.seed == run_seed || (out.item_seeds[it.name] = it.seed)
            end
        end
        out
    end
    flags = split(get(given.meta, "julia_flags", ""), ' '; keepempty = false)
    julia_flags = isempty(flags) || flags == code_flags() ? String[] : String.(flags)
    return with_config(run; julia_flags, replayed_manifest = recorded_manifest(given),
                       replayed_from = given.path), replayed
end

# Each replayed item in the environment directory of the current checkout, returning
# descriptions of any item whose environment directory differs from what its run state
# recorded. A run state that does not record one directory for each of its items is not
# paired with them by guess.
function check_replayed_environments(items::Vector{RawItem}, records::Vector, roots::Vector{String})
    moved = String[]
    for (k, rs) in enumerate(records)
        rs === nothing && continue
        text = get(rs.meta, "environments", nothing)
        text === nothing && throw(ConfigError(
            "$(rs.path) does not record the environment directories of its items, which a combined run's run state does"
        ))
        envs = split(text, '\n')
        length(envs) == length(rs.items) || throw(ConfigError(string(
            rs.path, " records ", plural(length(envs), "environment directory", "environment directories"), " for ",
            plural(length(rs.items), "test item"), ": the file is damaged"
        )))
        was = Dict(it.name => String(env) for (it, env) in zip(rs.items, envs))
        for it in items
            it.package == k || continue
            before = get(was, it.name, nothing)
            now = isempty(it.environment) ? "" : rel_slash(it.environment, roots[k])
            before === nothing || before == now ||
                push!(moved, string(repr(it.name), " ran in ", isempty(before) ? "the test environment" : before,
                                    " when recorded, and runs in ", isempty(now) ? "the test environment" : now, " here"))
        end
    end
    return moved
end
