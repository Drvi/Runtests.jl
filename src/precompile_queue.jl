### The precompile queue ###################################################

# One queue compiles what the run's workers load, before they start: the packages and
# extensions of each project the workers start in, the setups, and Runtests, each under
# every set of cache flags its workers have. A compile starts as soon as the compiles it
# waits for are done and one of `precompile_tasks()` slots is free, whatever its
# project or flags. The active project and the load path are one value for a process,
# so each environment has a helper process of its own (`precompile_helper.jl`), which
# this process starts once a job there has work. This process decides what compiles,
# when, and how many at once, and reports progress and failures.

include("precompile_helper.jl")

# An environment the queue compiles in: a project, `""` for none, and the load path of
# its processes.
const QueueEnv = @NamedTuple{project::String, load_path::Vector{String}}

# One compile: `pkg` in environment `env` (an index into the queue's environments)
# under set of flags `config` (an index into its configurations), after the jobs
# `deps`. `strict` makes a dependency without a cache an error in the compile process;
# `exts` are the extensions that may load while it compiles, `nothing` for any. `kind`
# is `:package`, `:setup` or `:runtests`; `group` indexes what the announcement and a
# failure call the job's environment, and `name` is what a line of output calls it.
# `profiles` are the profiles that need it for their flags or their project, which its
# line of output names, and `version` is the version it compiles, `""` when none is known.
const QueueJob = @NamedTuple{env::Int, pkg::Base.PkgId, config::Int, deps::Vector{Int}, strict::Bool,
                             exts::Union{Nothing, Vector{Base.PkgId}}, kind::Symbol, group::Int, name::String,
                             profiles::Set{String}, version::String}

# The environment a group of jobs compiles in, as the announcement names it: a
# project, as a message calls it, and the profiles whose flags or project need it.
const QueueGroup = @NamedTuple{project::String, subject::String, profiles::Set{String}}

struct PrecompileQueue
    envs::Vector{QueueEnv}
    configs::Vector{PrecompileConfig}
    jobs::Vector{QueueJob}
    groups::Vector{QueueGroup}
    # Each job by project, package and configuration: one compile for each, whatever
    # environment asked for it first.
    index::Dict{Tuple{String, Base.PkgId, Int}, Int}
    graphs::Dict{String, Any}
end

PrecompileQueue() = PrecompileQueue(QueueEnv[], PrecompileConfig[], QueueJob[], QueueGroup[],
                                    Dict{Tuple{String, Base.PkgId, Int}, Int}(), Dict{String, Any}())

# As many compiles at a time as Julia's own precompiler runs: `JULIA_NUM_PRECOMPILE_TASKS`,
# or one more than the CPU threads, half of them on Windows, and at most 16.
function precompile_tasks()
    # Chosen as the code is compiled: before 1.13 the name does not exist at all.
    n = @static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS
    default = min(Sys.iswindows() ? div(n, 2) + 1 : n + 1, 16)
    return max(1, something(tryparse(Int, get(ENV, "JULIA_NUM_PRECOMPILE_TASKS", "")), default))
end

### The graph of a project #################################################

"""
    EnvGraph

What Julia's precompiler compiles for a project, and the order: each package outside the
system image that the project's dependencies reach, and each extension whose package and
triggers are all there. `deps` holds what each one waits for, `parent` the package of
each extension, `triggers` the packages and extensions that load each extension, and
`circular` the packages in or above a cycle, which the precompiler leaves out.
`versions` holds the version that the manifest records for each package, by UUID.
"""
struct EnvGraph
    deps::Dict{Base.PkgId, Vector{Base.PkgId}}
    parent::Dict{Base.PkgId, Base.PkgId}
    triggers::Dict{Base.PkgId, Vector{Base.PkgId}}
    circular::Set{Base.PkgId}
    versions::Dict{Base.UUID, String}
end

function reach!(seen::Set{Base.UUID}, deps::Dict{Base.UUID, Vector{Base.UUID}}, uuid::Base.UUID)
    uuid in seen && return seen
    push!(seen, uuid)
    foreach(d -> reach!(seen, deps, d), get(deps, uuid, Base.UUID[]))
    return seen
end

# Everything `pkg` waits for, directly or through others, added to `out`.
function all_deps!(out::Set{Base.PkgId}, deps::Dict{Base.PkgId, Vector{Base.PkgId}}, pkg::Base.PkgId)
    for d in get(deps, pkg, Base.PkgId[])
        d in out && continue
        push!(out, d)
        all_deps!(out, deps, d)
    end
    return out
end

"""
    env_graph(project_file) -> EnvGraph

The graph that Julia's precompiler builds for the project, by the same rules:
`Base.Precompilation` builds it inside its precompile call before 1.14, and in
`build_dep_graph` from 1.14.
"""
function env_graph(project_file::AbstractString)
    env = Base.Precompilation.ExplicitEnv(String(project_file))
    reachable = Set{Base.UUID}()
    foreach(u -> reach!(reachable, env.deps, u), values(env.project_deps))
    id(u) = Base.PkgId(u, env.names[u])
    deps = Dict{Base.PkgId, Vector{Base.PkgId}}()
    parent = Dict{Base.PkgId, Base.PkgId}()
    triggers = Dict{Base.PkgId, Vector{Base.PkgId}}()
    for u in reachable
        haskey(env.deps, u) || continue
        pkg = id(u)
        Base.in_sysimage(pkg) && continue
        deps[pkg] = filter!(!Base.in_sysimage, Base.PkgId[id(d) for d in env.deps[u]])
        for (name, trigger_uuids) in get(Dict{String, Vector{Base.UUID}}, env.extensions, u)
            ext = Base.PkgId(Base.uuid5(u, name), name)
            loaded_by = Base.PkgId[pkg]
            present = true
            for t in trigger_uuids
                trigger = id(t)
                (t in reachable || Base.in_sysimage(trigger)) || (present = false; break)
                push!(loaded_by, trigger)
            end
            present || continue
            triggers[ext] = loaded_by
            parent[ext] = pkg
            deps[ext] = filter(!Base.in_sysimage, loaded_by)
        end
    end
    # An extension whose triggers hold all of another's loads that one too.
    for a in keys(parent), b in keys(parent)
        if triggers[a] ⊋ triggers[b]
            push!(triggers[a], b)
            push!(deps[a], b)
        end
    end
    # A package that loads every trigger of an extension, and is not one of them, loads
    # the extension while it compiles, so it waits for it, unless a package it waits
    # for already does.
    changed = true
    while changed
        changed = false
        indirect = Dict(p => all_deps!(Set{Base.PkgId}(), deps, p) for p in keys(deps))
        for ext in keys(parent)
            loads = Dict(p => !haskey(parent, p) && issubset(deps[ext], indirect[p]) && !(p in deps[ext])
                         for p in keys(deps))
            for (p, l) in loads
                (l && !any(d -> get(loads, d, false), deps[p]) && !(ext in deps[p])) || continue
                push!(deps[p], ext)
                changed = true
            end
        end
    end
    return EnvGraph(deps, parent, triggers, circular_packages(deps), versions_by_uuid(project_file))
end

# The version of each package that the manifest of `project_file` records, by UUID.
function versions_by_uuid(project_file::AbstractString)
    versions = Dict{Base.UUID, String}()
    manifest = Base.project_file_manifest_path(String(project_file))
    (manifest === nothing || !isfile(manifest)) && return versions
    data = TOML.parsefile(manifest)
    # Format 1 has the packages at the top level.
    entries = get(data, "deps", data)
    entries isa AbstractDict || return versions
    for (_, list) in entries
        list isa AbstractVector || continue
        for e in list
            (e isa AbstractDict && haskey(e, "uuid") && haskey(e, "version")) || continue
            versions[Base.UUID(e["uuid"])] = string(e["version"])
        end
    end
    return versions
end

# The version in the project file of the package whose source `pkg` is, as a setup or
# Runtests has it, or `""`.
function source_version(pkg::Base.PkgId)
    path = Base.locate_package(pkg)
    path === nothing && return ""
    project = project_file_in(dirname(dirname(path)))
    project === nothing && return ""
    return string(get(parse_project(project), "version", ""))
end

# The version a line of output gives for `pkg` of `g`: an extension's is its package's.
graph_version(g::EnvGraph, pkg::Base.PkgId) = get(g.versions, get(g.parent, pkg, pkg).uuid, "")

# The packages that are in a cycle or wait for one.
function circular_packages(deps::Dict{Base.PkgId, Vector{Base.PkgId}})
    state = Dict{Base.PkgId, Int8}()   # 1 being visited, 2 visited
    circular = Set{Base.PkgId}()
    function visit(p)
        s = get(state, p, Int8(0))
        s == 1 && return true
        s == 2 && return p in circular
        state[p] = 1
        found = false
        for d in get(deps, p, Base.PkgId[])
            visit(d) && (found = true)
        end
        state[p] = 2
        found && push!(circular, p)
        return found
    end
    foreach(visit, keys(deps))
    return circular
end

# The packages and extensions of `g` that compile for `names` and what they wait for,
# or for the whole project when `names` is `nothing`. An extension compiles when all it
# waits for does.
function compile_set(g::EnvGraph, names::Union{Nothing, Set{String}})
    names === nothing && return Set(keys(g.deps))
    keep = Set{Base.PkgId}()
    for p in keys(g.deps)
        p.name in names || continue
        push!(keep, p)
        all_deps!(keep, g.deps, p)
    end
    for ext in keys(g.parent)
        issubset(all_deps!(Set{Base.PkgId}(), g.deps, ext), keep) && push!(keep, ext)
    end
    return keep
end

# What a line of output calls `pkg`: an extension with its package.
display_name(g::EnvGraph, pkg::Base.PkgId) = haskey(g.parent, pkg) ? string(g.parent[pkg].name, " → ", pkg.name) : pkg.name

### The jobs ###############################################################

function env_of!(q::PrecompileQueue, project::AbstractString, load_path::Vector{String})
    e = findfirst(x -> x.project == project && x.load_path == load_path, q.envs)
    e === nothing || return e
    push!(q.envs, (; project = String(project), load_path = copy(load_path)))
    return lastindex(q.envs)
end

function config_of!(q::PrecompileQueue, config::PrecompileConfig)
    c = findfirst(==(config), q.configs)
    c === nothing || return c
    push!(q.configs, config)
    return lastindex(q.configs)
end

function group_of!(q::PrecompileQueue, project::AbstractString, subject::AbstractString, profiles)
    g = findfirst(x -> x.project == project && x.subject == subject, q.groups)
    if g === nothing
        push!(q.groups, (; project = String(project), subject = String(subject), profiles = Set{String}()))
        g = lastindex(q.groups)
    end
    union!(q.groups[g].profiles, profiles)
    return g
end

# The project file of `project`, a file or a directory, or `nothing` for none.
queue_project_file(project::AbstractString) =
    isempty(project) ? nothing : isdir(project) ? project_file_in(project) : isfile(project) ? String(project) : nothing

function add_job!(q::PrecompileQueue, key, job::NamedTuple)
    haskey(q.index, key) && return q.index[key]
    push!(q.jobs, job)
    return q.index[key] = lastindex(q.jobs)
end

# The jobs that compile `names` of `project`, and what they wait for, or all of it
# (`nothing`), under `config`, in the environment of `project` and `load_path`. What
# the precompiler cannot read, a run without a project or a project without a manifest,
# adds nothing.
function add_project!(q::PrecompileQueue, project::AbstractString, load_path::Vector{String},
                      config::PrecompileConfig, names::Union{Nothing, Set{String}}, group::Int;
                      profiles::Set{String} = Set{String}())
    file = queue_project_file(project)
    file === nothing && return nothing
    g = get!(() -> env_graph(file), q.graphs, file)::EnvGraph
    e, c = env_of!(q, project, load_path), config_of!(q, config)
    keep = filter!(p -> !(p in g.circular), compile_set(g, names))
    for pkg in keep
        exts = haskey(g.parent, pkg) ? filter(d -> haskey(g.parent, d), g.triggers[pkg]) : nothing
        j = add_job!(q, (String(project), pkg, c),
                     (; env = e, pkg, config = c, deps = Int[], strict = !isempty(g.deps[pkg]), exts,
                      kind = :package, group, name = display_name(g, pkg), profiles = Set{String}(),
                      version = graph_version(g, pkg)))
        union!(q.jobs[j].profiles, profiles)
    end
    for pkg in keep
        job = q.jobs[q.index[(String(project), pkg, c)]]
        for d in g.deps[pkg]
            j = get(q.index, (String(project), d, c), 0)
            (j == 0 || j in job.deps) || push!(job.deps, j)
        end
    end
    return nothing
end

"""
    precompile_queue(run, p, flags_of) -> (queue, once)

The jobs of the run's precompile queue: what each pool's workers load, in the project
and on the load path they start with, under the cache flags that `flags_of(profile)`
gives them (`precompile_needs`); Runtests for each other set of flags, where no project
of the run compiles it already; and the setups (`setup_needs`). A setup that is not a
package has a single cache file per depot, which a second project or set of flags would
write over: it compiles for the first pool that loads it, and `once` holds its source
file, for the warning that the run gives.
"""
function precompile_queue(run::Run, p::Plan, flags_of)
    q = PrecompileQueue()
    needs, others = precompile_needs(run, p, flags_of)
    for n in needs
        (n.whole || !isempty(n.names)) || continue
        group = group_of!(q, n.project, n.subject, n.profiles)
        add_project!(q, n.project, n.load_path, n.config, n.whole ? nothing : n.names, group; n.profiles)
    end
    # Runtests, which a worker loads before it connects, for the flags that no project of
    # the run compiles it for. In this process's environment, where it was loaded from.
    here, here_path = something(Base.active_project(), ""), copy(LOAD_PATH)
    pkg = RuntestsWorkers.PKGID
    for config in others
        c = config_of!(q, config)
        any(((_, k, kc),) -> k == pkg && kc == c, keys(q.index)) && continue
        group = group_of!(q, here, string("Runtests for workers started with `", join(first(config).exec, " "), "`"),
                          String[])
        add_project!(q, here, here_path, config, Set(["Runtests"]), group)
        # Not in the project's manifest: the compile process builds what it waits for.
        haskey(q.index, (here, pkg, c)) && continue
        add_job!(q, (here, pkg, c), (; env = env_of!(q, here, here_path), pkg, config = c, deps = Int[], strict = false,
                                    exts = nothing, kind = :runtests, group, name = "Runtests", profiles = Set{String}(),
                                    version = source_version(pkg)))
    end
    once = Dict{Symbol, String}()
    for (; project, load_path, needs) in setup_needs(run, p, flags_of)
        add_setups!(q, project, load_path, needs, once)
    end
    return q, once
end

# The setups of `needs`, loaded in `project` on `load_path`, each after the setups and
# packages it loads, as far as `setup_dependencies` knows them. A setup compiles without
# `strict`: a package it loads that no job compiles, the compile process builds.
function add_setups!(q::PrecompileQueue, project::AbstractString, load_path::Vector{String},
                     needs::Vector{SetupNeed}, once::Dict{Symbol, String})
    e = env_of!(q, project, load_path)
    group = group_of!(q, project, "test setups", String[])
    waits = Tuple{Int, Base.PkgId}[]
    in_worker_environment(project, load_path) do
        for (; name, args, flags, dir) in needs
            pkg = Base.identify_package(String(name))
            pkg === nothing && throw(ConfigError("test setup module `$name` is not loadable from $dir"))
            if pkg.uuid === nothing
                haskey(once, name) && continue
                once[name] = something(Base.locate_package(pkg), dir)
            end
            c = config_of!(q, args => flags)
            key = (String(project), pkg, c)
            haskey(q.index, key) && continue
            i = add_job!(q, key, (; env = e, pkg, config = c, deps = Int[], strict = false, exts = nothing,
                                  kind = :setup, group, name = pkg.name, profiles = Set{String}(),
                                  version = source_version(pkg)))
            for dep in setup_dependencies(pkg)
                # Named in the setup's own `[deps]`, or for a setup that is not a package,
                # in the environment.
                d = pkg.uuid === nothing ? Base.identify_package(dep) : Base.identify_package(pkg, dep)
                d === nothing || push!(waits, (i, d))
            end
        end
    end
    for (i, d) in waits
        job = q.jobs[i]
        j = get(q.index, (String(project), d, job.config), 0)
        (j == 0 || j == i || j in job.deps) || push!(job.deps, j)
    end
    return nothing
end

# The jobs in an order where each comes after the jobs it waits for. A wait that closes
# a cycle, which only setups that name each other make, is dropped: it would wait
# forever, and Julia refuses to load such setups anyway.
function queue_order!(jobs::Vector{QueueJob})
    state = zeros(Int8, length(jobs))   # 1 being visited, 2 visited
    order = Int[]
    function visit(i)
        state[i] = 1
        deps = jobs[i].deps
        for d in copy(deps)
            if state[d] == 1
                deleteat!(deps, findfirst(==(d), deps))
                continue
            end
            state[d] == 0 && visit(d)
        end
        state[i] = 2
        push!(order, i)
    end
    foreach(i -> state[i] == 0 && visit(i), eachindex(jobs))
    return order
end

### Helper processes #######################################################

const HELPER_FILE = joinpath(@__DIR__, "precompile_helper.jl")

# A reply of a helper: its status, the seconds a build took, the fresh cache file or
# `nothing`, and the output of a compile that did not build.
const HelperReply = Tuple{String, Float64, Union{Nothing, String}, Float64, String}

# A helper process, the requests it has not answered, by job, the sets of flags it was
# given, and the jobs whose cache files it was told. `id` numbers the helpers of a run
# from 1 in the order they start, as the lines of their compiles name them, `w1` and on:
# `w0` is the coordinator.
mutable struct QueueHelper
    const id::Int
    const process::Base.Process
    const pid::Int32
    # On Windows, the job object that holds the helper and its compile processes.
    const job::Ptr{Cvoid}
    const started_at::Float64
    const lock::ReentrantLock
    const pending::Dict{Int, Channel{HelperReply}}
    const configs::Set{Int}
    const told::Set{Int}
    const err::IOBuffer
    @atomic dead::Bool
end

"""
    start_helper(id, env) -> QueueHelper

Helper process `id` for environment `env`: this process's julia arguments, so that its
default cache flags are this process's, the project and the load path of `env`, and a
process group (on Windows, a job object) of its own, so that stopping it stops the
compiles it started.
"""
function start_helper(id::Integer, env::QueueEnv)
    vars = Dict{String, String}(ENV)
    vars["JULIA_LOAD_PATH"] = join(env.load_path, PATHSEP)
    vars["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, PATHSEP)
    isempty(env.project) ? delete!(vars, "JULIA_PROJECT") : (vars["JULIA_PROJECT"] = env.project)
    code = "include($(repr(HELPER_FILE))); PrecompileHelper.serve()"
    cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no --threads=1 -e $code`
    err = Pipe()
    proc = RuntestsWorkers.track!(open(pipeline(detach(setenv(cmd, vars)); stderr = err), "r+"))
    close(err.in)
    pid = try
        getpid(proc)
    catch e
        is_interrupt(e) && rethrow()
        Int32(0)
    end
    h = QueueHelper(id, proc, pid, RuntestsWorkers.worker_job(pid), time(), ReentrantLock(),
                    Dict{Int, Channel{HelperReply}}(), Set{Int}(), Set{Int}(), IOBuffer(), false)
    @async try
        write(h.err, err)
    catch e
        is_interrupt(e) && RuntestsWorkers.forward_interrupt(e)
    end
    @async read_replies(h)
    return h
end

# Hands each reply of `h` to the request that waits for it. Once the helper is gone,
# whatever it did not answer fails, and so does what is asked of it later.
function read_replies(h::QueueHelper)
    try
        for line in eachline(h.process.out)
            f = split(line, '\t'; limit = 6)
            length(f) == 6 || continue
            job = tryparse(Int, f[1])
            job === nothing && continue
            ch = @lock h.lock pop!(h.pending, job, nothing)
            ch === nothing || put!(ch, (String(f[2]), something(tryparse(Float64, f[3]), 0.0),
                                        f[4] == "-" ? nothing : String(f[4]),
                                        something(tryparse(Float64, f[5]), 0.0), PrecompileHelper.unescape_field(f[6])))
        end
    catch e
        is_interrupt(e) && RuntestsWorkers.forward_interrupt(e)
    finally
        @lock h.lock begin
            @atomic h.dead = true
            why = helper_gone(h)
            foreach(ch -> put!(ch, ("failed", 0.0, nothing, 0.0, why)), values(h.pending))
            empty!(h.pending)
        end
    end
    return nothing
end

helper_gone(h::QueueHelper) =
    string("the precompile helper process (pid ", h.pid, ") stopped", (s = strip(String(copy(h.err.data)))) |> isempty ? "" : ":\n" * s)

# The reply of `h` to the build of job `i` of `q`. First `h` is told the cache files of
# the jobs in `upstream`, all that job `i` waits for, that it was not told already:
# `paths` holds the fresh file of each job, or `nothing`.
function build!(h::QueueHelper, q::PrecompileQueue, i::Int, upstream, paths::Vector{Union{Nothing, String}})
    job = q.jobs[i]
    ch = Channel{HelperReply}(1)
    @lock h.lock begin
        (@atomic h.dead) && return ("failed", 0.0, nothing, 0.0, helper_gone(h))
        try
            if !(job.config in h.configs)
                args, flags = q.configs[job.config]
                println(h.process.in, join(["config", string(job.config), PrecompileHelper.cache_flags_text(flags), args.exec...], '\t'))
                push!(h.configs, job.config)
            end
            for d in upstream
                (paths[d] === nothing || d in h.told) && continue
                println(h.process.in, string("fresh\t", job.config, '\t', PrecompileHelper.pkgid_field(q.jobs[d].pkg), '\t', paths[d]))
                push!(h.told, d)
            end
            h.pending[i] = ch
            println(h.process.in, string("build\t", i, '\t', job.config, '\t', PrecompileHelper.pkgid_field(job.pkg), '\t',
                                         job.strict ? 1 : 0, '\t', PrecompileHelper.exts_field(job.exts)))
        catch e
            is_interrupt(e) && rethrow()
            delete!(h.pending, i)
            return ("failed", 0.0, nothing, 0.0, helper_gone(h))
        end
    end
    return take!(ch)
end

# Stops each helper: at the end of its input, which it ends at, or at once (`kill`),
# with the compiles it started. A helper that exits on its own gets an EXIT line, as
# a test worker's does; a killed one is part of a run already saying it stopped.
function stop_helpers!(run::Run, helpers::Vector{Union{Nothing, QueueHelper}}, answered::Vector{Int},
                       reused::Vector{Int}; kill::Bool)
    for h in helpers
        h === nothing && continue
        try
            if !kill
                close(h.process.in)
                RuntestsWorkers.wait_exit(h.process, 10)
                print_helper_line(run, h.id, "EXIT",
                    string("pid ", h.pid, " · ", plural(answered[h.id] - reused[h.id], "compile"),
                           reused[h.id] > 0 ? string(" (", reused[h.id], " reused)") : "",
                           " · ", fmt_seconds(time() - h.started_at)))
            end
            RuntestsWorkers.signal!(h.pid, h.process, Base.SIGKILL)
        catch e
            is_interrupt(e) && rethrow()
        finally
            RuntestsWorkers.end_job!(h.job)
            RuntestsWorkers.untrack!(h.process)
        end
    end
    return nothing
end

### Running the queue ######################################################

# Everything each job waits for, directly or through others, by job, given the jobs
# in an order where each comes after what it waits for.
function upstream_jobs(jobs::Vector{QueueJob}, order::Vector{Int})
    up = [Set{Int}() for _ in jobs]
    for i in order, d in jobs[i].deps
        push!(up[i], d)
        union!(up[i], up[d])
    end
    return up
end

"""
    fresh_paths(q, order) -> Vector{Union{Nothing, String}}

The fresh cache file of each job of `q`, or `nothing`, asked in this process in the
order `order`, where each job comes after what it waits for. As in Julia's precompiler,
each job is held to the files found for the jobs it waits for in the same project and
under the same flags, so a job that waits for a stale one is stale as well: compiled
again, that one replaces the build its cache was made against.
"""
function fresh_paths(q::PrecompileQueue, order::Vector{Int})
    paths = Vector{Union{Nothing, String}}(nothing, length(q.jobs))
    caches = Dict{Tuple{String, Int}, Dict{Base.PkgId, Vector{String}}}()
    verdicts = Dict{Tuple{String, Int}, Dict{Base.StaleCacheKey, Bool}}()
    original_project, original_path = Base.active_project(), copy(LOAD_PATH)
    current = 0
    try
        for i in order
            job = q.jobs[i]
            env = q.envs[job.env]
            if job.env != current
                Base.set_active_project(isempty(env.project) ? nothing : env.project)
                copy!(LOAD_PATH, env.load_path)
                current = job.env
            end
            key = (env.project, job.config)
            cache = get!(Dict{Base.PkgId, Vector{String}}, caches, key)
            path = PrecompileHelper.freshest_path(job.pkg, last(q.configs[job.config]);
                                                  stale_cache = get!(Dict{Base.StaleCacheKey, Bool}, verdicts, key),
                                                  cachepath_cache = cache)
            cache[job.pkg] = path === nothing ? String[] : [path]
            paths[i] = path
        end
    finally
        copy!(LOAD_PATH, original_path)
        Base.set_active_project(original_project)
    end
    return paths
end

"""
    run_queue(run, q) -> (status, texts)

Compile what is stale among the jobs of `q`. Which jobs are fresh is asked first, in
this process (`fresh_paths`); nothing else starts a helper. Each stale job waits for
its `deps`, and a `strict` job whose dependency failed is skipped: its compile could
only fail too. `status` holds `:fresh`, `:built`, `:waited`, `:unprecompilable`,
`:failed` or `:skipped` for each job, and `texts` the output of each compile that did
not build.
"""
function run_queue(run::Run, q::PrecompileQueue)
    t0 = time()
    n = length(q.jobs)
    order = queue_order!(q.jobs)
    paths = fresh_paths(q, order)
    work = BitVector(paths[i] === nothing for i in 1:n)
    status, texts = fill(:fresh, n), fill("", n)
    any(work) || return status, texts
    announce(run, q, work)
    # Only a job that takes a turn can print: it is numbered into the compiles.
    total, ended = count(work), Threads.Atomic{Int}(0)
    width = name_width([q.jobs[i].name for i in eachindex(q.jobs) if work[i]])
    vwidth = maximum((textwidth(version_text(q.jobs[i])) for i in eachindex(q.jobs) if work[i]); init = 0)
    # When the last completion was reported: the reminder a run off a terminal prints
    # counts its thirty seconds from here, and a new completion resets it.
    last_report, reminded, watching = Ref(time()), Ref(false), Ref(true)
    upstream = upstream_jobs(q.jobs, order)
    done = [Base.Event() for _ in 1:n]
    foreach(i -> work[i] || notify(done[i]), 1:n)
    # Julia serializes a package's compiles on a pidfile lock it shares across every
    # project and set of preferences: two jobs of one (package, flags) cannot compile
    # at the same time anyway. The later one is chained to wait on `done` instead, so
    # it holds no compile slot while it waits; its own freshness check then finds the
    # cache the first built, when that file serves its project too.
    waits = [Int[] for _ in 1:n]
    serialized = Dict{Tuple{Base.PkgId, Int}, Int}()
    for i in order
        work[i] || continue
        # `key` keeps `job` out of this scope: a name bound here is captured by the
        # closures that assign it below, and `run_job` and `helper_line_text` give
        # their `job`s a variable of their own.
        key = (q.jobs[i].pkg, q.jobs[i].config)
        prev = get(serialized, key, 0)
        prev == 0 || push!(waits[i], prev)
        serialized[key] = i
    end
    limit = Base.Semaphore(precompile_tasks())
    helpers = Vector{Union{Nothing, QueueHelper}}(nothing, length(q.envs))
    answered = zeros(Int, length(q.envs))
    reused = zeros(Int, length(q.envs))
    helper_lock = ReentrantLock()
    cancelled = Ref(false)
    function report(i, h_id, s, seconds, rss, text)
        cancelled[] ||
            report_job(run, q, i, h_id, s, seconds, rss, text, Threads.atomic_add!(ended, 1) + 1, total, width, vwidth)
        last_report[] = time()
        reminded[] = false
        return nothing
    end
    # A run off a terminal has no pinned line to show what compiles: after an interval
    # without a completion it names what is still compiling, once per such gap.
    (run.monitor === nothing || !run.monitor.tty) && @async while watching[]
        sleep(0.5)
        watching[] || break
        if !reminded[] && !cancelled[] && time() - last_report[] > run.plan.cfg.monitor_interval
            names = compiling_names()
            isempty(names) || (say(run, "still precompiling ", join(names, ", ")); reminded[] = true)
        end
    end
    # What a helper's UP line calls it by, in the shape a test worker's UP line has:
    # the profiles it compiles for, the environments it serves, then the sets of
    # julia arguments its compiles run under.
    function helper_line_text(e, pid)
        subjects, argsets, profnames = String[], String[], Set{String}()
        for i in eachindex(q.jobs)
            job = q.jobs[i]
            (work[i] && job.env == e) || continue
            s = up_subject(q.groups[job.group].subject)
            s === nothing || (s in subjects || push!(subjects, s))
            union!(profnames, job.profiles)
            args = first(q.configs[job.config]).exec
            isempty(args) && continue
            argtext = join(args, ' ')
            argtext in argsets || push!(argsets, argtext)
        end
        named = sort!(collect(setdiff(profnames, (String(DEFAULT_PROFILE),))))
        return string("pid ", pid,
                      isempty(named) ? "" :
                          string(" · ", length(named) == 1 ? "profile " : "profiles ", join(named, ", ")),
                      isempty(subjects) ? "" : " · " * join(sort!(subjects), ", "),
                      isempty(argsets) ? "" : " · " * join(sort!(argsets), ", "))
    end
    function helper(e)
        @lock helper_lock begin
            cancelled[] && return nothing
            h = helpers[e]
            h === nothing || return h
            h = helpers[e] = start_helper(count(!isnothing, helpers) + 1, q.envs[e])
            print_helper_line(run, h.id, "UP", helper_line_text(e, h.pid))
            return h
        end
    end
    function run_job(i)
        job = q.jobs[i]
        foreach(d -> wait(done[d]), job.deps)
        if job.strict && any(d -> status[d] in (:failed, :skipped), job.deps)
            status[i] = :skipped
            report(i, 0, :skipped, 0.0, 0.0, "")
            return
        end
        foreach(d -> wait(done[d]), waits[i])
        h = helper(job.env)
        if h === nothing
            status[i] = :skipped
            report(i, 0, :skipped, 0.0, 0.0, "")
            return
        end
        s, seconds, path, rss, text = Base.acquire(limit) do
            compiling_started(i, job.name)
            try
                build!(h, q, i, upstream[i], paths)
            finally
                compiling_ended(i)
            end
        end
        status[i], paths[i], texts[i] = Symbol(s), path, text
        answered[h.id] += 1
        status[i] in (:fresh, :waited) && (reused[h.id] += 1)
        haskey(COMPILE_STATES, status[i]) &&
            report(i, h.id, status[i], seconds, rss, text)
        return
    end
    try
        @sync for i in order
            work[i] || continue
            @async try
                run_job(i)
            catch e
                if is_interrupt(e)
                    cancelled[] = true
                    RuntestsWorkers.forward_interrupt(e)
                    rethrow()
                end
                status[i], texts[i] = :failed, sprint(showerror, e)
                report(i, 0, :failed, 0.0, 0.0, texts[i])
            finally
                notify(done[i])
            end
        end
    catch
        cancelled[] = true
        rethrow()
    finally
        watching[] = false
        @lock COMPILING_LOCK empty!(COMPILING)
        shielded(() -> stop_helpers!(run, helpers, answered, reused; kill = cancelled[]))
    end
    # What the jobs ended as: a job that waited a build out, or whose cache arrived
    # while it was queued, is a reuse here whatever the scan said at the start.
    nbuilt = count(==(:built), status)
    nreused = count(in((:fresh, :waited)), status)
    extra = String[]
    nfailed = count(==(:failed), status)
    nfailed > 0 && push!(extra, string(nfailed, " failed"))
    nskipped = count(in((:skipped, :unprecompilable)), status)
    nskipped > 0 && push!(extra, string(nskipped, " skipped"))
    say(run, "precompiled ", plural(nbuilt, "compile"),
        nreused > 0 ? " ($nreused reused)" : "",
        isempty(extra) ? "" : string(", ", join(extra, ", ")),
        " in ", fmt_seconds(time() - t0))
    return status, texts
end

# The text a group of jobs is announced with, or `nothing` for the test environment
# compiled for no profile in particular: its lines of output say enough.
function group_text(g::QueueGroup)
    isempty(g.profiles) && return g.subject == TEST_ENVIRONMENT ? nothing : g.subject
    return string(g.subject, " for ", plural(length(g.profiles), "profile"), ": ", join(sort!(collect(g.profiles)), ", "))
end

# What the queue is about to compile, as one bracketed block: each environment under
# the profiles that need it, then the setups, under a head that counts the compiles,
# the helper processes they spread over, and how many run at once — the single
# semaphore (`run_queue`) that bounds compiles across every helper.
function announce(run::Run, q::PrecompileQueue, work::BitVector)
    lines, setups, envs = String[], String[], Set{Int}()
    for i in eachindex(q.jobs)
        work[i] && push!(envs, q.jobs[i].env)
    end
    for (g, group) in pairs(q.groups)
        mine = [i for i in eachindex(q.jobs) if work[i] && q.jobs[i].group == g]
        isempty(mine) && continue
        if group.subject == "test setups"
            append!(setups, (q.jobs[i].name for i in mine))
            continue
        end
        text = group_text(group)
        text === nothing || push!(lines, string("precompiling ", text))
    end
    isempty(setups) || push!(lines, string("precompiling ", join(unique!(setups), ", ")))
    fresh = length(q.jobs) - count(work)
    head = string("precompiling ", plural(count(work), "compile"),
                  fresh == 0 ? "" : string(" (", fresh, " reused)"),
                  " with ", plural(length(envs), "worker"),
                  ", at most ", precompile_tasks(), " at once")
    print_label_block(run, head, join(lines, '\n'))
    return nothing
end

# A group's subject as a worker's UP line calls its environment — `env test`,
# `env <path>` for an environment directory, `this environment` for this
# process's own — or `nothing` for a subject that is not an environment.
function up_subject(subject::AbstractString)
    subject == "test setups" && return nothing
    subject == TEST_ENVIRONMENT && return "env test"
    for (prefix, short) in (("the test environment of ", "env test of "),
                            ("the environment of ", "env "))
        startswith(subject, prefix) && return short * subject[(ncodeunits(prefix) + 1):end]
    end
    startswith(subject, "Runtests for ") && return "this environment"
    return subject
end

# An environment subject shortened for the fields of a line, or `nothing` for a
# subject that is not a path: "the environment of test/qa" becomes "env test/qa".
function env_field(subject::AbstractString)
    for (prefix, short) in (("the environment of ", "env "), ("the test environment of ", "env test of "))
        startswith(subject, prefix) || continue
        return short * subject[(ncodeunits(prefix) + 1):end]
    end
    return nothing
end

# What a job compiled for, where it is not the default: the environment and the
# profiles, as the fields at the end of its line. The julia arguments it ran under
# are on the helper's UP line, as a test worker's are on its own.
function job_fields(q::PrecompileQueue, i::Int)
    job = q.jobs[i]
    fields = String[]
    field = env_field(q.groups[job.group].subject)
    field === nothing || push!(fields, field)
    named = sort!(collect(setdiff(job.profiles, (String(DEFAULT_PROFILE),))))
    isempty(named) || push!(fields, string(length(named) == 1 ? "profile " : "profiles ", join(named, ", ")))
    return fields
end

version_text(job::QueueJob) = isempty(job.version) ? "" : "v" * job.version

# What a line shows for each status of a compile, as a test item's line shows its
# outcome: a module that cannot be precompiled is set aside, and loads from its source.
const COMPILE_STATES = Dict(
    :built => ("PASS", PRECOMPILE_MARK_PASSED, :green),
    :fresh => ("REUSED", PRECOMPILE_MARK_INFO, :light_black),
    :waited => ("REUSED", PRECOMPILE_MARK_INFO, :light_black),
    :skipped => ("SKIP", PRECOMPILE_MARK_UNPRECOMPILABLE, :yellow),
    :failed => ("FAIL", PRECOMPILE_MARK_FAILED, :red),
    :unprecompilable => ("SKIP", PRECOMPILE_MARK_UNPRECOMPILABLE, :yellow),
)

# The compiles in flight, as a job name against when each started: the interactive
# status line names the oldest of them, and the reminder a run off a terminal prints
# names them all. One queue runs at a time in a process. The queue's tasks write it on
# several threads and the run's thread reads it, which `COMPILING_LOCK` keeps apart.
const COMPILING = Dict{Int, Tuple{Float64, String}}()
const COMPILING_LOCK = ReentrantLock()
compiling_started(i::Integer, name::AbstractString) = (@lock COMPILING_LOCK COMPILING[i] = (time(), name); nothing)
compiling_ended(i::Integer) = (@lock COMPILING_LOCK delete!(COMPILING, i); nothing)
oldest_compiling() = @lock COMPILING_LOCK (isempty(COMPILING) ? "" : last(argmin(first, collect(values(COMPILING)))))
compiling_names() = @lock COMPILING_LOCK (sort!(String[last(v) for v in collect(values(COMPILING))]))

"""
    report_job(run, q, i, helper, status, seconds, text, n, total, width, vwidth)

The line of job `i` of `q`, compiled by helper process `helper`, the `n`th of `total` compiles to end, in the shape of a test
item's DONE line: its outcome, its time, the largest a compile of the helper has run
(`rss`), and what it compiled for where that is not the default. A compile that did not
build follows it with its output, in the bracket a test item's failure has; `width` is
the name column's, and `vwidth` the version column's.
"""
function report_job(run::Run, q::PrecompileQueue, i::Int, helper::Integer, status::Symbol, seconds::Float64,
                    rss::Float64, text::AbstractString,
                    n::Integer, total::Integer, width::Integer, vwidth::Integer)
    # REUSED is kept quiet: a job that found a fresh cache, or found one built by
    # the process it waited the lock out for, measured nothing. These lines want a
    # verbosity setting the run does not have yet, so they stay off for now; the
    # states and their marks are still defined above.
    status in (:fresh, :waited) && return nothing
    haskey(COMPILE_STATES, status) || return nothing
    word, mark, color = COMPILE_STATES[status]
    shown = repr(q.jobs[i].name)
    fields = job_fields(q, i)
    line = styled() do io
        print_line_head(io, mark, helper, clock_now())
        print_word(io, "COMP")
        print_int(io, n, ndigits(total)); write(io, UInt8('/')); print_int(io, total); print(io, FIELD)
        print(io, shown)
        pad_to(io, width, textwidth(shown))
        if vwidth > 0
            v = version_text(q.jobs[i])
            print(io, FIELD, v)
            # A name longer than its column has pushed the version out of its own:
            # padding what nothing aligns under only lengthens the line.
            textwidth(shown) > width || pad_to(io, vwidth, textwidth(v))
        end
        print(io, FIELD)
        print_colored(io, word, STATE_WIDTH, color)
        # A job found fresh, or skipped, measured nothing: no time to give it.
        seconds > 0 && (print(io, FIELD); print_1dp(io, round(seconds; digits = 1), TIME_WIDTH - 1); print(io, "s"))
        # The largest a compile of its helper has run, as a worker's DONE line
        # shows its process's: 0 where the platform keeps no rusage.
        rss > 0 && (print(io, FIELD, "maxrss "); print_1dp(io, round(rss / 2^30; digits = 1)); print(io, " GiB"))
        foreach(f -> print(io, FIELD, f), fields)
    end
    text = strip(text)
    if status !== :built && !isempty(text)
        body = bracket(text, "Captured logs", "", "", Base.info_color())
        label = string("[", lpad(n, ndigits(total)), "/", total, "] ", word)
        footer = string("@ ", something(group_text(q.groups[q.jobs[i].group]), TEST_ENVIRONMENT))
        line = string(line, "\n", bracket(body, label, join([shown; fields], " · "), footer, color))
    end
    printline(run, line)
    return nothing
end

"""
    precompile_queued(run, p, flags_of)

Build and run the run's precompile queue (`precompile_queue`, `run_queue`). Work brought
forward, not work that has to succeed: a package that fails to compile is said, with
its output, and the workers compile what they need themselves. A setup that fails stops
the run, as its items could not load it. The run warns about each setup that is not a
package, whose cache each environment and set of flags writes over.
"""
function precompile_queued(run::Run, p::Plan, flags_of)
    q, once = precompile_queue(run, p, flags_of)
    status, texts = run_queue(run, q)
    setup_failure = nothing
    for i in eachindex(q.jobs)
        status[i] === :failed || continue
        job, text = q.jobs[i], texts[i]
        args = first(q.configs[job.config])
        if job.kind === :setup
            setup_failure === nothing && (setup_failure = ConfigError(string(
                "test setup module `", job.pkg.name, "` failed to precompile",
                isempty(args) ? "" : string(" under `", join(args.exec, " "), "`"), ":\n", text)))
        end
    end
    setup_failure === nothing || throw(setup_failure)
    if !isempty(once)
        files = sort!([relpath_or_path(file, p.root) for file in values(once)])
        one = length(files) == 1
        @warn string(
            "Runtests: the test setup", one ? " " : "s ", join(("`$f`" for f in files), ", "),
            one ? " is not a package. It shares" : " are not packages. Each one shares",
            " one precompile cache with every setup of its name in the depot. Each checkout, environment and set ",
            "of Julia flags writes over that cache. Run `Runtests.setups_to_packages()` in ",
            one ? "its package to give it" : "the package that holds each one to give it", " a cache of its own."
        )
    end
    return nothing
end
