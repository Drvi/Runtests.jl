### The precompile queue ###################################################

# One queue compiles what the run's workers load, before they start: the packages and
# extensions of each project the workers start in, the setups, and Runtests, each under
# every set of cache flags its workers have. A compile starts as soon as the compiles it
# waits for are done and one of `precompile_tasks()` slots is free, whatever its
# project or flags. The active project and the load path are one value for a process,
# so this process compiles for its own environment, and each other environment has a
# helper process of its own (`precompile_helper.jl`), which this process starts once a
# job there has work. This process decides what compiles, when, and how many at once,
# and reports progress and failures.

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
# In a run of several packages, `requesters` are the tested packages that need it, which
# its line names in a column. `indirect` marks a package that no project file of a
# tested package names, nor the project it compiles in, and an extension of one.
const QueueJob = @NamedTuple{env::Int, pkg::Base.PkgId, config::Int, deps::Vector{Int}, strict::Bool,
                             exts::Union{Nothing, Vector{Base.PkgId}}, kind::Symbol, group::Int, name::String,
                             profiles::Set{String}, version::String, requesters::Set{String}, indirect::Bool}

# The environment a group of jobs compiles in, as the announcement names it: a
# project, as a message calls it, and the profiles whose flags or project need it.
const QueueGroup = @NamedTuple{project::String, subject::String, profiles::Set{String}}

"""
    EnvGraph

What Julia's precompiler compiles for a project, and the order: each package outside the
system image that the project's dependencies reach, and each extension whose package and
triggers are all there. `deps` holds what each one waits for, `parent` the package of
each extension, `triggers` the packages and extensions that load each extension, and
`circular` the packages in or above a cycle, which the precompiler leaves out.
`direct` holds the packages of the project's `[deps]`, its own package and their
extensions: what `Pkg.test` asks the precompiler for. `versions` holds the version
that the manifest records for each package, by UUID.
"""
struct EnvGraph
    deps::Dict{Base.PkgId, Vector{Base.PkgId}}
    parent::Dict{Base.PkgId, Base.PkgId}
    triggers::Dict{Base.PkgId, Vector{Base.PkgId}}
    circular::Set{Base.PkgId}
    direct::Set{Base.PkgId}
    versions::Dict{Base.UUID, String}
end

# A job's key: its project, its package and its cache flags. The flags, not the set of
# julia arguments that gives them: arguments that compile no code differently, as
# `--depwarn=error` or coverage before 1.14, give the same cache, which Julia locks for
# the package and the flags alone.
const JobKey = Tuple{String, Base.PkgId, Base.CacheFlags}

struct PrecompileQueue
    envs::Vector{QueueEnv}
    configs::Vector{PrecompileConfig}
    jobs::Vector{QueueJob}
    groups::Vector{QueueGroup}
    # One compile for each key, whatever environment or arguments asked for it first.
    index::Dict{JobKey, Int}
    # The graph of each project file, `nothing` for one that could not be read.
    graphs::Dict{String, Union{Nothing, EnvGraph}}
    # The jobs the run asks for, as `Pkg.test` asks the precompiler: one of them that
    # fails, or is skipped for a failure under it, stops the run (`queue_failure`).
    requested::Set{Int}
end

PrecompileQueue() = PrecompileQueue(QueueEnv[], PrecompileConfig[], QueueJob[], QueueGroup[],
                                    Dict{JobKey, Int}(), Dict{String, Union{Nothing, EnvGraph}}(), Set{Int}())

# As many compiles at a time as Julia's own precompiler runs: `JULIA_NUM_PRECOMPILE_TASKS`,
# or one more than the CPU threads, half of them on Windows, and at most 16.
function precompile_tasks()
    # Chosen as the code is compiled: before 1.13 the name does not exist at all.
    n = @static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS
    default = min(Sys.iswindows() ? div(n, 2) + 1 : n + 1, 16)
    return max(1, something(tryparse(Int, get(ENV, "JULIA_NUM_PRECOMPILE_TASKS", "")), default))
end

### The graph of a project #################################################

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
    # An extension whose triggers hold all of another's loads that one too. Compared as
    # sets, kept beside the lists, which every pair of extensions would build again.
    sets = Dict(e => Set(t) for (e, t) in triggers)
    for a in keys(parent), b in keys(parent)
        if sets[a] ⊋ sets[b]
            push!(triggers[a], b)
            push!(sets[a], b)
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
            loaders = Set{Base.PkgId}(p for p in keys(deps)
                                      if !haskey(parent, p) && !(p in deps[ext]) && issubset(deps[ext], indirect[p]))
            for p in loaders
                (!any(in(loaders), deps[p]) && !(ext in deps[p])) || continue
                push!(deps[p], ext)
                changed = true
            end
        end
    end
    # The project's own package is among `project_deps`.
    direct = Set{Base.PkgId}(Base.PkgId(u, name) for (name, u) in env.project_deps)
    for (ext, p) in parent
        p in direct && push!(direct, ext)
    end
    return EnvGraph(deps, parent, triggers, circular_packages(deps), direct, versions_by_uuid(project_file))
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
    project = project_file(dirname(dirname(path)))
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
    # Until none is added: an extension can wait for another extension. `keep` holds
    # everything its members wait for, so an extension whose own waits are all in it has
    # the rest there too.
    added = true
    while added
        added = false
        for ext in keys(g.parent)
            (ext in keep || !issubset(g.deps[ext], keep)) && continue
            push!(keep, ext)
            added = true
        end
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
    isempty(project) ? nothing : isdir(project) ? project_file(project) : isfile(project) ? String(project) : nothing

function add_job!(q::PrecompileQueue, key, job::NamedTuple)
    haskey(q.index, key) && return q.index[key]
    push!(q.jobs, job)
    return q.index[key] = lastindex(q.jobs)
end

# The jobs that compile `names` of `project`, and what they wait for, or all of it
# (`nothing`), under `config`, in the environment of `project` and `load_path`. What
# the precompiler cannot read, a run without a project or a project without a manifest,
# adds nothing. A project whose graph cannot be read adds nothing either, with a
# warning: the step is work brought forward, and the workers compile what they load.
# A package is indirect unless `named` holds its name, or, for a project of the tested
# packages (`tested`), the project names it. `by` holds what each tested package
# needs of the project (`PrecompileNeed`).
function add_project!(q::PrecompileQueue, project::AbstractString, load_path::Vector{String},
                      config::PrecompileConfig, names::Union{Nothing, Set{String}}, group::Int;
                      profiles::Set{String} = Set{String}(), named::Set{String} = Set{String}(), tested::Bool = false,
                      by::Dict{String, Union{Nothing, Set{String}}} = Dict{String, Union{Nothing, Set{String}}}())
    file = queue_project_file(project)
    file === nothing && return nothing
    g = get!(q.graphs, file) do
        try
            env_graph(file)
        catch e
            is_interrupt(e) && rethrow()
            @warn "Runtests: could not read the packages of $(relpath_or_path(file)), so none of them is \
                   precompiled before the workers start; the workers compile what they load" exception = e
            nothing
        end
    end
    g === nothing && return nothing
    e, c, flags = env_of!(q, project, load_path), config_of!(q, config), last(config)
    keep = filter!(p -> !(p in g.circular), compile_set(g, names))
    for pkg in keep
        exts = haskey(g.parent, pkg) ? filter(d -> haskey(g.parent, d), g.triggers[pkg]) : nothing
        j = add_job!(q, (String(project), pkg, flags),
                     (; env = e, pkg, config = c, deps = Int[], strict = !isempty(g.deps[pkg]), exts,
                      kind = :package, group, name = display_name(g, pkg), profiles = Set{String}(),
                      version = graph_version(g, pkg), requesters = Set{String}(),
                      indirect = !(get(g.parent, pkg, pkg).name in named || (tested && pkg in g.direct))))
        union!(q.jobs[j].profiles, profiles)
        # As `Pkg.test` asks the precompiler: the project's own, or else the names, with
        # the extensions of each, as a run of one package asks for its project's.
        (names === nothing ? pkg in g.direct : get(g.parent, pkg, pkg).name in names) && push!(q.requested, j)
    end
    for pkg in keep
        job = q.jobs[q.index[(String(project), pkg, flags)]]
        for d in g.deps[pkg]
            j = get(q.index, (String(project), d, flags), 0)
            (j == 0 || j in job.deps) || push!(job.deps, j)
        end
    end
    for (who, asked) in by
        for pkg in (asked === nothing ? keep : compile_set(g, asked))
            j = get(q.index, (String(project), pkg, flags), 0)
            j == 0 || push!(q.jobs[j].requesters, who)
        end
    end
    return nothing
end

# The packages that a project file of a tested package names: each tested package,
# and the dependencies, weak dependencies and test dependencies that its project and
# its test project name.
function named_packages(p::Plan)
    named = Set{String}(p.packages.name)
    for root in p.packages.root, dir in (root, joinpath(root, "test"))
        file = project_file(dir)
        file === nothing && continue
        toml = parse_project(file)
        for section in ("deps", "weakdeps", "extras")
            entries = get(toml, section, nothing)
            entries isa AbstractDict && union!(named, keys(entries))
        end
    end
    return named
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
    named = named_packages(p)
    for n in needs
        (n.whole || !isempty(n.names)) || continue
        group = group_of!(q, n.project, n.subject, n.profiles)
        add_project!(q, n.project, n.load_path, n.config, n.whole ? nothing : n.names, group; n.profiles, named,
                     tested = true, n.by)
    end
    # Runtests, which a worker loads before it connects, for the flags that no project of
    # the run compiles it for. In this process's environment, where it was loaded from.
    here, here_path = something(Base.active_project(), ""), copy(LOAD_PATH)
    pkg = RuntestsWorkers.PKGID
    for config in others
        flags = last(config)
        any(((_, k, f),) -> k == pkg && f == flags, keys(q.index)) && continue
        group = group_of!(q, here, string("Runtests for workers started with `", join(first(config).exec, " "), "`"),
                          String[])
        # The tested packages whose workers start with these flags.
        who = Set{String}(w for n in needs if last(n.config) == flags for w in keys(n.by))
        add_project!(q, here, here_path, config, Set(["Runtests"]), group; named,
                     by = Dict{String, Union{Nothing, Set{String}}}(w => Set(["Runtests"]) for w in who))
        # Not in the project's manifest: the compile process builds what it waits for.
        haskey(q.index, (here, pkg, flags)) && continue
        push!(q.requested,
              add_job!(q, (here, pkg, flags), (; env = env_of!(q, here, here_path), pkg, config = config_of!(q, config),
                                              deps = Int[], strict = false, exts = nothing, kind = :runtests, group,
                                              name = "Runtests", profiles = Set{String}(), version = source_version(pkg),
                                              requesters = who, indirect = false)))
    end
    once = Dict{Symbol, String}()
    for (; project, load_path, needs) in setup_needs(run, p, flags_of)
        add_setups!(q, project, load_path, needs, once)
    end
    return q, once
end

# The setups of `needs`, loaded in `project` on `load_path`, each after the setups and
# packages it loads, as far as `setup_dependencies` knows them, compiled for the same
# cache flags. A setup compiles without `strict`: a package it loads that no job
# compiles, the compile process builds.
function add_setups!(q::PrecompileQueue, project::AbstractString, load_path::Vector{String},
                     needs::Vector{SetupNeed}, once::Dict{Symbol, String})
    e = env_of!(q, project, load_path)
    group = group_of!(q, project, "test setups", String[])
    waits = Tuple{Int, Base.PkgId}[]
    in_worker_environment(project, load_path) do
        for (; name, args, flags, dir, profiles, packages) in needs
            pkg = Base.identify_package(String(name))
            pkg === nothing && throw(ConfigError("test setup module `$name` is not loadable from $dir"))
            if pkg.uuid === nothing
                haskey(once, name) && continue
                once[name] = something(Base.locate_package(pkg), dir)
            end
            key = (String(project), pkg, flags)
            if haskey(q.index, key)
                union!(q.jobs[q.index[key]].profiles, profiles)
                union!(q.jobs[q.index[key]].requesters, packages)
                continue
            end
            i = add_job!(q, key, (; env = e, pkg, config = config_of!(q, args => flags), deps = Int[], strict = false,
                                  exts = nothing, kind = :setup, group, name = pkg.name, profiles = copy(profiles),
                                  version = source_version(pkg), requesters = copy(packages), indirect = false))
            push!(q.requested, i)
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
        j = get(q.index, (String(project), d, last(q.configs[job.config])), 0)
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
# `nothing`, the peak resident size of its compiles, and the output of a compile that
# did not build.
const HelperReply = Tuple{String, Float64, Union{Nothing, String}, Float64, String}

# A helper process, the requests it has not answered, by job, the sets of flags it was
# given, and the jobs whose cache files it was told, each with the set of flags it was
# told it for. `id` numbers the helpers of a run from 1 in the order they start, as the
# lines of their compiles name them, `w1` and on: `w0` is the coordinator.
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
    const told::Set{Tuple{Int, Int}}
    const err::IOBuffer
    @atomic dead::Bool
    @atomic stopped::Bool
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
                    Dict{Int, Channel{HelperReply}}(), Set{Int}(), Set{Tuple{Int, Int}}(), IOBuffer(), false, false)
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
            if !isempty(h.pending)
                why = helper_gone(h)
                foreach(ch -> put!(ch, ("failed", 0.0, nothing, 0.0, why)), values(h.pending))
                empty!(h.pending)
            end
        end
    end
    return nothing
end

# Why a request to `h` failed, with what the helper wrote to its standard error.
function helper_gone(h::QueueHelper)
    # A copy, so that the reader of the stream goes on writing where it was.
    said = strip(String(take!(copy(h.err))))
    return string("the precompile helper process (pid ", h.pid, ") stopped", isempty(said) ? "" : ":\n" * said)
end

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
                (paths[d] === nothing || (job.config, d) in h.told) && continue
                println(h.process.in, string("fresh\t", job.config, '\t', PrecompileHelper.pkgid_field(q.jobs[d].pkg), '\t', paths[d]))
                push!(h.told, (job.config, d))
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

# The build of job `i` of `q` in this process, for a job in its own environment, as a
# helper answers it (`build!`). `caches` holds the cache files that the compiles of each
# set of flags are held to, which the jobs in `upstream` and the job itself add to.
function build_here!(caches::Dict{Int, Dict{Base.PkgId, Vector{String}}}, q::PrecompileQueue, i::Int, upstream,
                     paths::Vector{Union{Nothing, String}})
    job = q.jobs[i]
    cache = get!(Dict{Base.PkgId, Vector{String}}, caches, job.config)
    for d in upstream
        paths[d] === nothing || (cache[q.jobs[d].pkg] = [paths[d]])
    end
    args, flags = q.configs[job.config]
    s, seconds, path, _, text = PrecompileHelper.compile(job.pkg, args, flags; strict = job.strict,
                                                         loadable_exts = job.exts, cachepath_cache = cache)
    path === nothing || (cache[job.pkg] = [path])
    # No peak memory: the children of this process are its test workers too.
    return (String(s), seconds, path, 0.0, text)
end

# Stops helper `h`, once, with the compiles it started. A helper whose environment has no
# job left has answered every request, and so runs no compile and holds no lock: it is
# stopped at once, as Julia takes most of a second to exit, and gets an EXIT line, as a
# test worker does, with what its jobs ended as (`counts_text`). A helper stopped by a
# cancelled queue (`kill`) is part of a run already saying it stopped.
function stop_helper!(run::Run, h::QueueHelper, counts::AbstractString; kill::Bool)
    (@atomicswap h.stopped = true) && return nothing
    try
        kill || print_helper_line(run, h.id, "EXIT",
            string("pid ", h.pid, " · ", counts, " · ", fmt_seconds(time() - h.started_at)))
        RuntestsWorkers.signal!(h.pid, h.process, Base.SIGKILL)
    catch e
        is_interrupt(e) && rethrow()
    finally
        RuntestsWorkers.end_job!(h.job)
        RuntestsWorkers.untrack!(h.process)
        @atomic QUEUE_PROGRESS.live -= 1
    end
    return nothing
end

# What the caches of jobs `mine` ended as, for the block that ends the queue and a
# helper's EXIT line: of the stale ones (`work`), those compiled, those reused because
# another compile built them first, those failed and those skipped; then those fresh
# from the start.
function counts_text(status::Vector{Symbol}, work::BitVector, mine)
    stale = filter(i -> work[i], collect(mine))
    built = count(i -> status[i] === :built, stale)
    reused = count(i -> is_quiet(status[i]), stale)
    failed = count(i -> status[i] === :failed, stale)
    skipped = count(i -> status[i] === :skipped || status[i] === :unprecompilable, stale)
    fresh = length(mine) - length(stale)
    return string(built, " compiled", reused > 0 ? ", $reused reused" : "", failed > 0 ? ", $failed failed" : "",
                  skipped > 0 ? ", $skipped skipped" : "", fresh > 0 ? " ($fresh fresh)" : "")
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
    caches = Dict{Tuple{String, Base.CacheFlags}, Dict{Base.PkgId, Vector{String}}}()
    verdicts = Dict{Tuple{String, Base.CacheFlags}, Dict{Base.StaleCacheKey, Bool}}()
    # The depot's cache files of each package, and the flags each was built for: the
    # same whatever the environment and the flags asked for.
    found, flag_bytes = Dict{Base.PkgId, Vector{String}}(), Dict{String, Int}()
    original_project, original_path, original_cache = Base.active_project(), copy(LOAD_PATH), Base.LOADING_CACHE[]
    current = 0
    try
        for i in order
            job = q.jobs[i]
            env = q.envs[job.env]
            if job.env != current
                Base.set_active_project(isempty(env.project) ? nothing : env.project)
                copy!(LOAD_PATH, env.load_path)
                # The lookups of projects and manifests, kept for one environment, as
                # Julia's precompiler keeps them: without it each check of a dependency
                # reads them again, a third of the time on a large environment. Cleared
                # first: a new cache takes its load path from the cache in place.
                Base.LOADING_CACHE[] = nothing
                Base.LOADING_CACHE[] = Base.LoadingCache()
                current = job.env
            end
            flags = last(q.configs[job.config])
            key = (env.project, flags)
            cache = get!(Dict{Base.PkgId, Vector{String}}, caches, key)
            path = PrecompileHelper.freshest_path(job.pkg, flags;
                                                  stale_cache = get!(Dict{Base.StaleCacheKey, Bool}, verdicts, key),
                                                  cachepath_cache = cache, found, flag_bytes)
            cache[job.pkg] = path === nothing ? String[] : [path]
            paths[i] = path
        end
    finally
        Base.LOADING_CACHE[] = original_cache
        copy!(LOAD_PATH, original_path)
        Base.set_active_project(original_project)
    end
    return paths
end

"""
    run_queue(run, q) -> (status, texts)

Compile what is stale among the jobs of `q`. Which jobs are fresh is asked first, in
this process (`fresh_paths`); nothing else starts a helper. A job in this process's own
environment, its active project and load path, compiles in this process
(`build_here!`), and a job in another environment in the helper of that environment.
Each stale job waits for its `deps`, and a `strict` job whose dependency failed is
skipped: its compile could only fail too. `status` holds `:fresh`, `:built`, `:waited`,
`:unprecompilable`, `:failed` or `:skipped` for each job, and `texts` the output of each
compile that did not build.
"""
function run_queue(run::Run, q::PrecompileQueue)
    t0 = time()
    n = length(q.jobs)
    order = queue_order!(q.jobs)
    paths = fresh_paths(q, order)
    work = BitVector(paths[i] === nothing for i in 1:n)
    status, texts = fill(:fresh, n), fill("", n)
    any(work) || return status, texts
    # This process's environment among the queue's, or 0 for none.
    own = something(findfirst(env -> env.project == something(Base.active_project(), "") && env.load_path == LOAD_PATH,
                              q.envs), 0)
    # Its hooks are the lock on a cache file, as in a helper.
    any(i -> work[i] && q.jobs[i].env == own, 1:n) && Base.require(PrecompileHelper.FILEWATCHING)
    # Each stale cache takes a number as its job ends (`report`).
    total = count(work)
    # A helper for each other environment with a stale cache.
    nhelpers = length(Set(q.jobs[i].env for i in eachindex(q.jobs) if work[i] && q.jobs[i].env != own))
    # From here until the helpers are down, the progress line counts the compiles: the
    # announcement already draws it so.
    queue_started!(total, nhelpers)
    try
        announce(run, q, work, nhelpers)
    catch
        queue_ended!()
        rethrow()
    end
    width = name_width([q.jobs[i].name for i in eachindex(q.jobs) if work[i]])
    vwidth = maximum((textwidth(version_text(q.jobs[i])) for i in eachindex(q.jobs) if work[i]); init = 0)
    # The column of the tested packages, which only a run of several fills.
    pwidth = maximum((textwidth(requesters_text(q.jobs[i])) for i in eachindex(q.jobs) if work[i]); init = 0)
    kwidth = maximum((textwidth(kind_text(q.jobs[i])) for i in eachindex(q.jobs) if work[i]); init = 0)
    # When the last completion was reported: the reminder a run off a terminal prints
    # counts its thirty seconds from here, and a new completion resets it.
    last_report, reminded, watching = Ref(time()), Ref(false), Ref(true)
    upstream = upstream_jobs(q.jobs, order)
    done = [Base.Event() for _ in 1:n]
    foreach(i -> work[i] || notify(done[i]), 1:n)
    # The jobs of each environment that have not ended: a helper stops when its
    # environment has none left (`env_done`).
    left = zeros(Int, length(q.envs))
    foreach(i -> work[i] && (left[q.jobs[i].env] += 1), 1:n)
    # Julia serializes a package's compiles on a pidfile lock it shares across every
    # project and set of preferences: two jobs of one (package, flags) cannot compile
    # at the same time anyway. The later one is chained to wait on `done` instead, so
    # it holds no compile slot while it waits; its own freshness check then finds the
    # cache the first built, when that file serves its project too.
    waits = [Int[] for _ in 1:n]
    serialized = Dict{Tuple{Base.PkgId, Base.CacheFlags}, Int}()
    for i in order
        work[i] || continue
        # `key` keeps `job` out of this scope: a variable of `run_queue` that one of its
        # closures assigns is one box that every closure shares, a data race between the
        # queue's tasks. `run_job` and `env_text` give their `job`s a variable of
        # their own, and test_precompile.jl checks that `run_queue` makes no box.
        key = (q.jobs[i].pkg, last(q.configs[q.jobs[i].config]))
        prev = get(serialized, key, 0)
        prev == 0 || push!(waits[i], prev)
        serialized[key] = i
    end
    limit = Base.Semaphore(precompile_tasks())
    helpers = Vector{Union{Nothing, QueueHelper}}(nothing, length(q.envs))
    here_caches = Dict{Int, Dict{Base.PkgId, Vector{String}}}()
    helper_lock = ReentrantLock()
    cancelled = Ref(false)
    # The pinned line drawn again at once when a compile starts, and when one ends
    # without a line of its own: until the monitor's next turn, half a second later, it
    # would name a compile that ended, or none while the next one already runs.
    redraw() = run.monitor === nothing || (@lock run.printer redraw_status(run.monitor))
    function report(i, h_id, s, seconds, rss, text)
        s === :failed && (@atomic QUEUE_PROGRESS.failed += 1)
        k = @atomic QUEUE_PROGRESS.done += 1
        # A reused job measured nothing: it takes its number, and prints no line.
        (cancelled[] || is_quiet(s)) ||
            report_job(run, q, i, h_id, s, seconds, rss, text, k, total, width, vwidth, pwidth, kwidth)
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
    # Every job of environment `e`: its counts take in the caches found fresh at the start.
    jobs_of(e) = [i for i in 1:n if q.jobs[i].env == e]
    # What a worker's lines call its jobs among `jobs`, in the shape a test worker's UP
    # line has: the profiles it compiles for, the environments it serves, then, with
    # `args`, the sets of julia arguments its compiles run under. This process's own
    # environment needs no name beyond its own.
    function env_text(jobs, args::Bool)
        subjects, argsets, profnames = String[], String[], Set{String}()
        for i in jobs
            job = q.jobs[i]
            s = up_subject(q.groups[job.group].subject)
            (s === nothing || (job.env == own && s == "this environment") || s in subjects) || push!(subjects, s)
            union!(profnames, job.profiles)
            exec = first(q.configs[job.config]).exec
            (args && !isempty(exec)) || continue
            argtext = join(exec, ' ')
            argtext in argsets || push!(argsets, argtext)
        end
        named = sort!(collect(setdiff(profnames, (String(DEFAULT_PROFILE),))))
        return string(isempty(named) ? "" :
                          string(" · ", length(named) == 1 ? "profile " : "profiles ", join(named, ", ")),
                      isempty(subjects) ? "" : " · " * join(sort!(subjects), ", "),
                      isempty(argsets) ? "" : " · " * join(sort!(argsets), ", "))
    end
    # A job of environment `e` ended: its helper stops when it was the last one.
    function env_done(e)
        (left[e] -= 1) == 0 || return nothing
        h = helpers[e]
        (h === nothing || cancelled[]) || stop_helper!(run, h, counts_text(status, work, jobs_of(e)); kill = false)
        return nothing
    end
    function helper(e)
        @lock helper_lock begin
            cancelled[] && return nothing
            h = helpers[e]
            h === nothing || return h
            h = helpers[e] = start_helper(count(!isnothing, helpers) + 1, q.envs[e])
            @atomic QUEUE_PROGRESS.live += 1
            print_helper_line(run, h.id, "UP", string("pid ", h.pid, env_text(filter(i -> work[i], jobs_of(e)), true)))
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
        # `nothing` for this process's own environment, where the coordinator, `w0`,
        # compiles itself.
        h = job.env == own ? nothing : helper(job.env)
        if cancelled[] || (job.env != own && h === nothing)
            status[i] = :skipped
            report(i, 0, :skipped, 0.0, 0.0, "")
            return
        end
        Base.acquire(limit)
        compiling_started(i, job.name)
        redraw()
        s, seconds, path, rss, text = try
            h === nothing ? build_here!(here_caches, q, i, upstream[i], paths) : build!(h, q, i, upstream[i], paths)
        finally
            compiling_ended(i)
            Base.release(limit)
        end
        status[i], paths[i], texts[i] = Symbol(s), path, text
        haskey(COMPILE_STATES, status[i]) && report(i, h === nothing ? 0 : h.id, status[i], seconds, rss, text)
        is_quiet(status[i]) && redraw()
        return
    end
    try
        # Every helper starts at once, and is up by the time its first job has waited
        # for the compiles it waits for, which can be another environment's. A helper
        # that does not start fails the jobs of its environment, each as it comes.
        for e in eachindex(q.envs)
            (e != own && left[e] > 0) || continue
            try
                helper(e)
            catch err
                is_interrupt(err) && rethrow()
            end
        end
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
                env_done(q.jobs[i].env)
            end
        end
    catch
        cancelled[] = true
        rethrow()
    finally
        watching[] = false
        @lock COMPILING_LOCK empty!(COMPILING)
        try
            # Those still up: all of them when the queue was cancelled.
            shielded() do
                for (e, h) in pairs(helpers)
                    h === nothing || stop_helper!(run, h, counts_text(status, work, jobs_of(e)); kill = cancelled[])
                end
            end
        finally
            queue_ended!()
        end
    end
    # What the stale caches ended as, and the fresh ones: a job that waited a build out,
    # or whose cache arrived while it was queued, is a reuse.
    head = string("precompiled ", plural(total, "stale cache"), ": ", counts_text(status, work, 1:n),
                  " in ", fmt_seconds(time() - t0))
    # With helpers, a line for each worker under it, in the order of their numbers, with
    # every cache of the environments it covers: a helper its own, the coordinator its
    # own and each that had no helper, all of whose caches its check found fresh. The
    # counts of the lines add up to the first line's, and a helper's are its EXIT line's.
    body = IOBuffer()
    if any(!isnothing, helpers)
        covered = Dict{Int, Vector{Int}}()
        for i in 1:n
            h = helpers[q.jobs[i].env]
            push!(get!(Vector{Int}, covered, h === nothing ? 0 : h.id), i)
        end
        for id in sort!(collect(keys(covered)))
            println(body, "w", id, " · ", counts_text(status, work, covered[id]), env_text(covered[id], false))
        end
    end
    print_label_block(run, head, String(take!(body)))
    return status, texts
end

# The text a group of jobs is announced with, an environment by the name a worker's UP
# line gives it, or `nothing` for the test environment compiled for no profile in
# particular: its lines of output say enough.
function group_text(g::QueueGroup)
    isempty(g.profiles) && g.subject == TEST_ENVIRONMENT && return nothing
    name = group_name(g.subject)
    isempty(g.profiles) && return name
    return string(name, " for ", plural(length(g.profiles), "profile"), ": ", join(sort!(collect(g.profiles)), ", "))
end

# A group's subject as an announcement names it: `the env test`, `the env test/qa`, or
# the subject itself where it is no environment.
function group_name(subject::AbstractString)
    subject == TEST_ENVIRONMENT && return "the env test"
    field = env_field(subject)
    return field === nothing ? String(subject) : "the " * field
end

# What the queue is about to compile, as one bracketed block: each environment under
# the profiles that need it, then the setups, under a head that counts the stale caches
# and the fresh ones, the helper processes they spread over, if any, and how many
# compiles run at once: the single semaphore (`run_queue`) that bounds the compiles of
# this process and of every helper, of which there are `nhelpers`.
function announce(run::Run, q::PrecompileQueue, work::BitVector, nhelpers::Int)
    lines, setups = String[], String[]
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
    head = string("precompiling ", plural(count(work), "stale cache"),
                  fresh == 0 ? "" : string(" (", fresh, " fresh)"),
                  nhelpers == 0 ? "" : string(" with ", plural(nhelpers, "worker")),
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

# What a job compiles, as its line's column gives it: a setup, a package that a
# project file of a tested package names or an extension of one, or another package.
kind_text(job::QueueJob) = job.kind === :setup ? "testsetup" : job.indirect ? "indirect" : "direct"

# The tested packages a job is for, as its line's column gives them: the first by
# name, and how many more. Empty outside a run of several packages.
function requesters_text(job::QueueJob)
    isempty(job.requesters) && return ""
    n = length(job.requesters)
    return n == 1 ? first(job.requesters) : string(minimum(job.requesters), " +", n - 1)
end

version_text(job::QueueJob) = isempty(job.version) ? "" : "v" * job.version

# What a line shows for each status of a compile, as a test item's line shows its
# outcome: a module that cannot be precompiled is set aside, and loads from its source.
# The run prints no line for a quiet status (`is_quiet`).
const COMPILE_STATES = Dict(
    :built => ("PASS", PRECOMPILE_MARK_PASSED, :green),
    :fresh => ("REUSED", PRECOMPILE_MARK_INFO, :light_black),
    :waited => ("REUSED", PRECOMPILE_MARK_INFO, :light_black),
    :skipped => ("SKIP", PRECOMPILE_MARK_UNPRECOMPILABLE, :yellow),
    :failed => ("FAIL", PRECOMPILE_MARK_FAILED, :red),
    :unprecompilable => ("SKIP", PRECOMPILE_MARK_UNPRECOMPILABLE, :yellow),
)

# Whether a job ended as a reuse: it found its cache fresh, or found it built by the
# compile that it waited for, and so measured nothing.
is_quiet(status::Symbol) = status === :fresh || status === :waited

# The compiles in flight, as a job name against when each started: the interactive
# status line names the oldest of them, and the reminder a run off a terminal prints
# names them all. One queue runs at a time in a process. The queue's tasks write it on
# several threads and the run's thread reads it, which `COMPILING_LOCK` keeps apart.
const COMPILING = Dict{Int, Tuple{Float64, String}}()
const COMPILING_LOCK = ReentrantLock()
compiling_started(i::Integer, name::AbstractString) = (@lock COMPILING_LOCK COMPILING[i] = (time(), name); nothing)
compiling_ended(i::Integer) = (@lock COMPILING_LOCK delete!(COMPILING, i); nothing)
function oldest_compiling()
    @lock COMPILING_LOCK begin
        oldest, name = Inf, ""
        for (t, n) in values(COMPILING)
            t < oldest && ((oldest, name) = (t, n))
        end
        return name
    end
end
compiling_names() = @lock COMPILING_LOCK (sort!(String[last(v) for v in collect(values(COMPILING))]))

# The counts of the queue that runs, which the progress line shows in place of the
# items' while the queue runs: the compiles that printed a line, as their lines number
# them (`report_job`), the compiles that failed, all compiles of the queue, and its
# helper processes, those up and all it has. `total` is 0 while no queue runs.
mutable struct QueueProgress
    @atomic done::Int
    @atomic failed::Int
    @atomic live::Int
    @atomic helpers::Int
    @atomic total::Int
end
const QUEUE_PROGRESS = QueueProgress(0, 0, 0, 0, 0)

# `total` last: a reader that sees it nonzero sees the counts of this queue.
function queue_started!(total::Integer, helpers::Integer)
    @atomic QUEUE_PROGRESS.done = 0
    @atomic QUEUE_PROGRESS.failed = 0
    @atomic QUEUE_PROGRESS.live = 0
    @atomic QUEUE_PROGRESS.helpers = helpers
    @atomic QUEUE_PROGRESS.total = total
    return nothing
end
queue_ended!() = (@atomic QUEUE_PROGRESS.total = 0; nothing)

"""
    report_job(run, q, i, helper, status, seconds, rss, text, n, total, width, vwidth, pwidth, kwidth)

The line of job `i` of `q`, compiled by helper process `helper` (`0` for this
process), the `n`th of `total` stale caches to end, in the shape of a test item's
DONE line: its outcome, its time, the largest a compile of the helper has run (`rss`,
`0` for none known), and what it compiled for where that is not the default. A compile
that did not build follows it with its output, in the bracket a test item's failure
has; `width` is the name column's, `vwidth` the version column's, `pwidth` that of the
tested packages, `0` outside a run of several, and `kwidth` that of what it compiles
(`kind_text`).
"""
function report_job(run::Run, q::PrecompileQueue, i::Int, helper::Integer, status::Symbol, seconds::Float64,
                    rss::Float64, text::AbstractString,
                    n::Integer, total::Integer, width::Integer, vwidth::Integer, pwidth::Integer, kwidth::Integer)
    haskey(COMPILE_STATES, status) || return nothing
    word, mark, color = COMPILE_STATES[status]
    shown = repr(q.jobs[i].name)
    fields = job_fields(q, i)
    line = styled() do io
        print_line_head(io, mark, helper, clock_now())
        print_word(io, "COMP")
        print_int(io, n, ndigits(total)); write(io, UInt8('/')); print_int(io, total); print(io, FIELD)
        # The tested packages it is for, where an item's line has its package.
        if pwidth > 0
            who = requesters_text(q.jobs[i])
            print(io, who); pad_to(io, pwidth, textwidth(who)); print(io, FIELD)
        end
        kind = kind_text(q.jobs[i])
        print(io, kind); pad_to(io, kwidth, textwidth(kind)); print(io, FIELD)
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
        footer = string("@ ", something(group_text(q.groups[q.jobs[i].group]), group_name(TEST_ENVIRONMENT)))
        line = string(line, "\n", bracket(body, label, join([shown; fields], " · "), footer, color))
    end
    printline(run, line)
    return nothing
end

# Why the queue stops the run, or `nothing`: a job it asks for failed or was skipped.
# As the error of `Pkg.precompile`, it gives every compile that failed with its output,
# then the jobs asked for that were skipped.
function queue_failure(q::PrecompileQueue, status::Vector{Symbol}, texts::Vector{String})
    any(i -> status[i] === :failed || status[i] === :skipped, q.requested) || return nothing
    failed = filter(i -> status[i] === :failed, eachindex(q.jobs))
    skipped = sort!(filter(i -> status[i] === :skipped, collect(q.requested)))
    io = IOBuffer()
    print(io, plural(length(failed), "module"), " failed to precompile, so no item ran.")
    foreach(i -> print(io, "\n\n", job_title(q, i), ":\n", strip(texts[i])), failed)
    isempty(skipped) || print(io, "\n\nSkipped because a module that ", length(skipped) == 1 ? "it loads" : "they load",
                              " failed to precompile: ", join((job_title(q, i) for i in skipped), ", "), ".")
    return String(take!(io))
end

# A job as a message names it: a setup as such, a package with the environment it
# compiles in, and the julia arguments of its compile, where there are any.
function job_title(q::PrecompileQueue, i::Int)
    job = q.jobs[i]
    subject = q.groups[job.group].subject
    place = group_name(subject)
    args = first(q.configs[job.config])
    return string(job.kind === :setup ? "test setup module `" : "`", job.name, "`",
                  place == subject ? "" : " in " * place,
                  isempty(args) ? "" : string(" under `", join(args.exec, " "), "`"))
end

"""
    precompile_queued(run, p, flags_of)

Build and run the run's precompile queue (`precompile_queue`, `run_queue`). As
`Pkg.test` from Julia 1.14 does, the run stops before its first item when a module it
asks for fails to compile, or is skipped because a module under it failed: a package
of an environment's `[deps]` or its own package, in a run of several packages a tested
package or a package of its test project's `[deps]`, a package of a profile's
`precompile` list, an extension of any of these, a setup, or Runtests. A failure that
none of those loads is said, with its output, and the run goes on. The run warns about
each setup that is not a package, whose cache each environment and set of flags writes
over.
"""
function precompile_queued(run::Run, p::Plan, flags_of)
    q, once = precompile_queue(run, p, flags_of)
    status, texts = run_queue(run, q)
    failure = queue_failure(q, status, texts)
    failure === nothing || throw(ConfigError(failure))
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
