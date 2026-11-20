# Test environments, profile projects, workspace detection, LOAD_PATH management,
# and replay manifest comparison.

"""
    with_test_env(f, target)

Run `f` with the package's test environment active, and restore whatever was
active afterwards. The environment is:

1. the active one, when the call came from `<root>/test/runtests.jl`; `Pkg.test`
   normally builds that environment with the test dependencies;
2. the active one, when it is the package's own `test/Project.toml`, because
   activating that is a deliberate choice;
3. the package's `test/Project.toml`, when it is a member of the workspace the
   package is in, which shares its manifest, as `Pkg.test` uses it;
4. otherwise a test environment built by `TestEnv`.

The last two are cached for the session.

Outside `test/runtests.jl`, the package's plain project is not reused because it
lacks test-only dependencies. A call from that file assumes its active project
already supplies them.
"""
function with_test_env(f, target, run = nothing)
    # Building it is `Pkg`'s to narrate, and it draws its own progress by moving
    # the cursor. Ours comes down while it does.
    monitor = run === nothing ? nothing : run.monitor
    env = with_status_line_off(monitor) do
        test_env_for(target, run === nothing ? nothing : () -> say(run, "resolving the test environment"))
    end
    env === nothing && return f()
    current = Base.active_project()
    Base.set_active_project(env)
    try
        return f()
    finally
        Base.set_active_project(current)
    end
end

"""
    test_env_for(target) -> Union{Nothing,String}

The environment the target's items resolve against, or `nothing` when the active
one is it. `activate` asks too, and must agree with a run.
"""
function test_env_for(target, announce = nothing)
    current = Base.active_project()
    if current !== nothing
        running_from_runtests(target) && return nothing
        testproj = joinpath(target.testdir, "Project.toml")
        isfile(testproj) && abspath(current) == abspath(testproj) && return nothing
    end
    env = test_env(target, announce)::String
    (current !== nothing && abspath(current) == abspath(env)) && return nothing
    return env
end

# `f(Pkg, TestEnv)`, loading them the first time any call needs them rather than with
# this package: a worker process loads this package too, and Pkg alone would double
# the time a worker takes to start. Loaded during the call, their functions are newer
# than its caller, so `f` runs in the latest world.
const PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const TESTENV_ID = Base.PkgId(Base.UUID("1e6cf692-eddd-4d53-88a5-2d735e33781b"), "TestEnv")
with_pkg(f) = Base.invokelatest(f, Base.require(PKG_ID), Base.require(TESTENV_ID))

# Run `f(Pkg, TestEnv)` with `JULIA_PKG_PRECOMPILE_AUTO=0` and the active project
# restored afterwards. Throws `ConfigError` outside the `catch` so Julia does not
# repeat the cause chain.
function with_pkg_isolated(f, err_prefix::AbstractString)
    original = Base.active_project()
    failure = nothing
    result = try
        # `Pkg` would precompile for this process's flags only; the precompile queue
        # does it once for every set of flags the pools use.
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            with_pkg(f)
        end
    catch e
        is_interrupt(e) && rethrow()
        failure = e
        nothing
    finally
        Base.set_active_project(original)
    end
    failure === nothing || throw(ConfigError(string(err_prefix, sprint(showerror, failure))))
    return result
end

# Test environments, kept for the session and keyed by project file: building one
# costs a resolve, seconds at the REPL. It costs no compilation: caches are keyed by
# package versions and flags, not by environment, so a new environment with the same
# versions reuses them. The stamp is what it was generated from, so a test dependency
# added mid-session rebuilds it.
const TEST_ENVS = Dict{String, Tuple{String, NTuple{4, Tuple{String, Float64}}}}()
const TEST_ENVS_LOCK = ReentrantLock()

function test_env(target, announce = nothing)
    proj = abspath(target.project)
    return @lock TEST_ENVS_LOCK begin
        cached = get(TEST_ENVS, proj, nothing)
        if cached !== nothing && isfile(cached[1]) && cached[2] == env_stamp(target)
            return cached[1]
        end
        # Announced only when building: a cache hit is immediate, and at the REPL
        # the hit is the point.
        announce === nothing || announce()
        env = with_pkg_isolated("could not build a test environment for $(relpath_or_path(proj)): ") do Pkg, TestEnv
            testproj = joinpath(target.testdir, "Project.toml")
            if in_package_workspace(testproj, proj)
                # It shares the package's manifest, so `Pkg.test` runs it as it
                # is, without a sandbox.
                Pkg.activate(testproj; io = devnull)
                Pkg.instantiate(; allow_autoprecomp = false)
            else
                Pkg.activate(proj; io = devnull)
                TestEnv.activate()
            end
            # What activating made active: a project, or it would have thrown.
            Base.active_project()::String
        end::String
        # Stamped *after* generating it: resolving writes the package's manifest,
        # so a stamp taken beforehand never matches again and every call would
        # rebuild the environment it was supposed to cache.
        TEST_ENVS[proj] = (env, env_stamp(target))
        return env
    end
end

# The package's project and the test project, each with the manifest Julia reads for
# it: `Manifest-v1.x.toml` before `Manifest.toml`, a workspace's shared one. Paths
# as well as times, so a manifest that takes over from another changes the stamp.
function env_stamp(target)
    proj = abspath(target.project)
    testproj = joinpath(target.testdir, "Project.toml")
    stamped(path) = (path, mtime_or_zero(path))
    manifest(project) = something(isfile(project) ? Base.project_file_manifest_path(project) : nothing, "")
    return (stamped(proj), stamped(manifest(proj)), stamped(testproj), stamped(manifest(testproj)))
end

mtime_or_zero(path::AbstractString) = isfile(path) ? mtime(path) : 0.0

# Whether `test/Project.toml` is a member of a workspace, and of the one the package
# is in: the package's own, or one that lists both, as a monorepo's root does,
# directly or through the package's own. Julia's loader finds a member's manifest by
# following its workspace parents, so the outermost roots decide.
function in_package_workspace(testproj, proj)
    isfile(testproj) || return false
    @static if isdefined(Base, :base_project)
        Base.base_project(testproj) === nothing && return false
        return samefile(outermost_workspace(testproj), outermost_workspace(proj))
    else
        return false   # workspaces came with Julia 1.12
    end
end

# The project at the top of the workspaces that `project` is a member of, or
# `project` itself when it is a member of none, as every project is before Julia 1.12.
function outermost_workspace(project)
    @static if isdefined(Base, :base_project)
        while true
            parent = Base.base_project(project)
            (parent === nothing || samefile(parent, project)) && return project
            project = parent
        end
    else
        return project
    end
end

# A call from `test/runtests.jl` reuses the active project. `Pkg.test` normally
# runs that file in an environment it built for the purpose.
function running_from_runtests(target)
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    source === nothing && return false
    return abspath(String(source)) == abspath(joinpath(target.testdir, "runtests.jl"))
end

# A replay runs against this machine's environment, which may not be the one the
# run state was recorded in. Every package whose version differs is named: it is
# the first thing to rule out when a replay does not fail the way the original did.
function check_replayed_environment(run::Run)
    cfg = run.plan.cfg
    if !isempty(cfg.julia_flags)
        here = join(nondefault_flags(code_flags()), " ")
        say(run, string("the workers compile with the Julia flags the run state recorded, ",
                        join(nondefault_flags(cfg.julia_flags), " "), ", where this process has ",
                        isempty(here) ? "none of them" : here))
        cfg.workers == 0 && @warn "Runtests: the run state was recorded with the Julia flags " *
            "$(join(cfg.julia_flags, " ")), and `workers = 0` runs the items in this process, which has " *
            "$(join(code_flags(), " ")); give it one worker or more to run them as they were run"
    end
    recorded = cfg.replayed_manifest
    isempty(recorded) && return nothing
    env = Base.active_project()
    here = manifest_versions(read_text(env === nothing ? nothing : Base.project_file_manifest_path(env)))
    there = manifest_versions(recorded)
    diffs, by_path = String[], String[]
    for name in sort!(collect(union(keys(here), keys(there))))
        h, t = get(here, name, nothing), get(there, name, nothing)
        if h !== nothing && t !== nothing && (h.path || t.path)
            push!(by_path, name)
        elseif !same_code(h, t)
            push!(diffs, string(name, ": ", code_text(t), " when recorded, ", code_text(h), " here"))
        end
    end
    # Its path is the recording machine's, and its source may differ under the same one.
    isempty(by_path) || say(run, "tracked by path, so not compared with the recorded run: ", join(by_path, ", "))
    # The test environment's manifest is what the run state compares by. A profile with
    # a project of its own, as one of an environment directory has, has a snapshot of
    # its own in the run state, which this does not compare.
    own = length(run.profile_projects)
    own == 0 || say(run, "not compared with the recorded run: the environments of ", plural(own, "profile"),
                    " with a project of their own")
    isempty(diffs) && return say(run, "the test environment matches the one the run state was recorded in")
    @warn "Runtests: the test environment differs from the one the run state was recorded in:\n" *
        join(("  " * d for d in first(diffs, 40)), "\n") * (length(diffs) > 40 ? "\n  …" : "")
    return nothing
end

# The package-entry table of a parsed manifest: Format 2 puts it under `"deps"`,
# Format 1 puts the packages directly at the top level.
function manifest_entries(data::AbstractDict)
    entries = get(data, "deps", nothing)
    return entries isa AbstractDict ? entries : data
end

# What identifies a package's code in a manifest: its UUID, version and source tree
# (`git-tree-sha1`), as far as the manifest has them, or `path` for one tracked by path.
const ManifestCode = @NamedTuple{uuid::String, version::String, tree::String, path::Bool}

# Package name => its code (`ManifestCode`), from a manifest's text.
function manifest_versions(text::AbstractString)
    out = Dict{String, ManifestCode}()
    isempty(text) && return out
    toml = try
        TOML.parse(text)
    catch
        return out
    end
    for (name, entries) in manifest_entries(toml)
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict || continue
            field(k) = (v = get(entry, k, ""); v isa AbstractString ? String(v) : string(v))
            out[name] = (; uuid = field("uuid"), version = field("version"), tree = field("git-tree-sha1"),
                         path = haskey(entry, "path"))
        end
    end
    return out
end

# Whether two manifests give a package the same code: the same UUID and version, and the
# same source tree where both name one. A package that one of them lacks differs.
same_code(a, b) = a !== nothing && b !== nothing && a.uuid == b.uuid && a.version == b.version &&
    (isempty(a.tree) || isempty(b.tree) || a.tree == b.tree)

code_text(c) = c === nothing ? "absent" :
    string(isempty(c.version) ? "stdlib" : c.version, isempty(c.tree) ? "" : string(" (tree ", first(c.tree, 10), ")"))

function project_name_of(projectfile::AbstractString)
    try
        return get(TOML.parsefile(projectfile), "name", nothing)
    catch
        return nothing
    end
end

# The setups directory is an implicit environment, so putting it on LOAD_PATH is
# all that `using MySetup` needs. Done for the duration of the run rather than
# permanently: a test run should not leave the caller's session changed.
function with_load_path(f, setup_paths::Vector{String})
    added = String[]
    for path in setup_paths
        (isdir(path) && !(path in LOAD_PATH)) || continue
        push!(LOAD_PATH, path)
        push!(added, path)
    end
    isempty(added) && return f()
    try
        return f()
    finally
        for path in Iterators.reverse(added)
            i = findlast(==(path), LOAD_PATH)
            i === nothing || deleteat!(LOAD_PATH, i)
        end
    end
end

with_load_path(f, setup_path::AbstractString) = with_load_path(f, String[String(setup_path)])

# `f()` with `project` active, none for `""`, and `load_path` as the load path, as a
# worker started with them has both; afterwards, both as they were.
function in_worker_environment(f, project::AbstractString, load_path::Vector{String})
    original_project, original_path = Base.active_project(), copy(LOAD_PATH)
    try
        Base.set_active_project(isempty(project) ? nothing : project)
        copy!(LOAD_PATH, load_path)
        return f()
    finally
        copy!(LOAD_PATH, original_path)
        Base.set_active_project(original_project)
    end
end

# The environment a run's items resolve against, active for the length of `f`: the
# test environment of a standalone run (`with_test_env`), the union environment of a
# combined one (`with_union_env`). `run.package_projects` says, for each package, the
# project its items run in.
function with_run_env(f, target, run::Run)
    is_combined(run.plan) && return with_union_env(f, run)
    return with_test_env(target, run) do
        push!(run.package_projects, something(Base.active_project(), ""))
        f()
    end
end

"""
    profile_projects!(run, p)

Give every pool's profile that declares preferences, or runs in an environment
directory, a project of its own. A package takes its preferences from the
environment that owns it, and a stacked environment is not consulted, so a profile's
preferences have to arrive as the worker's own project: the test environment's
`Project.toml` and `Manifest.toml`, over a `LocalPreferences.toml` of the
environment's preferences with the profile's on top. Preferences are part of a
cache's identity, so these projects keep caches of their own. A pool in an
environment directory runs in a copy of it instead (see
[`environment_project`](@ref)).
"""
function profile_projects!(run::Run, p::Plan)
    for (j, prof) in enumerate(p.profiles)
        run.skipped_profiles[j] && continue
        env = run.package_projects[p.profile_package[j]]
        announce = () -> say(run, "resolving the environment of ", relpath_or_path(prof.environment, p.root))
        # An environment directory gets the package of its own suite.
        dir = profile_project(prof, env, p.packages.root[p.profile_package[j]], announce)
        dir === nothing || (run.profile_projects[ProfileIdx(j)] = dir)
    end
    return nothing
end

# Merge `base_dir/LocalPreferences.toml` (if present) with `override_file` (if non-empty)
# per package, writing `dir/LocalPreferences.toml` when non-empty or `always` is true.
function write_merged_preferences!(dir::AbstractString, base_dir::AbstractString, override_file::AbstractString;
                                   always::Bool = false)
    own = joinpath(base_dir, "LocalPreferences.toml")
    merged = isfile(own) ? TOML.parsefile(own) : Dict{String, Any}()
    if !isempty(override_file)
        for (pkg, table) in TOML.parsefile(override_file)
            # Per package, not per key: a half-overridden preferences table is a
            # configuration nobody wrote down.
            merged[pkg] = table
        end
    end
    (always || !isempty(merged)) && open(io -> TOML.print(io, merged), joinpath(dir, "LocalPreferences.toml"), "w")
    return nothing
end

# The project `prof`'s workers run in, or `nothing` for a profile without
# preferences or an environment, whose workers run in the environment `env` itself.
# For one with an environment, see `environment_project`, which `root`, the package
# under test, and `announce` are for. Otherwise in the system's temporary files,
# keyed by `env`'s path and the preferences file, and never beside `env`, which can
# be the package's own `test/`. The preferences file is in the key because profiles
# of one name in two packages of a combined run share `env` and can name different
# files. Rewritten on every call, so it follows the environment and the preferences
# file.
function profile_project(prof::Profile, env, root = nothing, announce = nothing)
    isempty(prof.environment) || return environment_project(prof, root, announce)
    (env === nothing || isempty(prof.preferences)) && return nothing
    key = crc32c(string(abspath(env), '\0', abspath(prof.preferences)))
    dir = joinpath(tempdir(), "runtests_profiles", string(key; base = 16, pad = 8), String(prof.name))
    mkpath(dir)
    copy_env_files(dir, env)
    write_merged_preferences!(dir, dirname(env), prof.preferences; always = true)
    return dir
end

# The projects of profiles that name an environment, kept for the session as the
# test environment is, and keyed by the environment, the package and the
# preferences: building one is a resolve.
const ENVIRONMENT_PROJECTS = Dict{NTuple{3, String}, Tuple{String, Vector{Float64}}}()
const ENVIRONMENT_PROJECTS_LOCK = ReentrantLock()

"""
    environment_project(prof, root, announce = nothing) -> String

Create the project in which workers run a profile that names an environment
directory. Copy the environment into a temporary directory, add the package at
`root` by path, apply the profile's preferences over the environment's
`LocalPreferences.toml`, and resolve it. Developing the package by path lets
resolution use its `[sources]` entries. The source environment is not modified.

Keep the result for this session and rebuild it when an input file changes: the
environment's files, the package's project, the preferences, or the project of a
package held by path. Call `announce` before building.
"""
function environment_project(prof::Profile, root, announce = nothing)
    root === nothing && throw(ConfigError(
        "the tests in $(relpath_or_path(prof.environment)) run in an environment of their own, and there is no package here to test in it"
    ))
    key = (prof.environment, String(root), prof.preferences)
    return @lock ENVIRONMENT_PROJECTS_LOCK begin
        cached = get(ENVIRONMENT_PROJECTS, key, nothing)
        if cached !== nothing && isdir(cached[1]) && cached[2] == environment_stamp(cached[1], prof, root)
            return cached[1]
        end
        announce === nothing || announce()
        dir = mktempdir(; prefix = "runtests_environment_")
        write_environment(dir, prof, root)
        resolve_environment(dir, prof)
        # Stamped once resolved: the packages it holds by path are in its manifest.
        ENVIRONMENT_PROJECTS[key] = (dir, environment_stamp(dir, prof, root))
        return dir
    end
end

# The environment `prof` names, written into `dir` with its paths made absolute, the
# package at `root` added by path, and the preferences laid over its own.
function write_environment(dir::AbstractString, prof::Profile, root::AbstractString)
    src = prof.environment
    projfile = something(project_file(src), joinpath(src, "Project.toml"))
    project = absolute_paths!(TOML.parsefile(projfile), src)
    own = project_file(root)
    pkg = own === nothing ? Dict{String, Any}() : TOML.parsefile(own)
    name, uuid = get(pkg, "name", nothing), get(pkg, "uuid", nothing)
    if name isa String && uuid isa String
        get!(Dict{String, Any}, project, "deps")[name] = uuid
        get!(Dict{String, Any}, project, "sources")[name] = Dict{String, Any}("path" => abspath(root))
    end
    open(io -> TOML.print(io, project; sorted = true), joinpath(dir, "Project.toml"), "w")
    copy_manifest_file(dir, projfile; remove_if_missing = false)
    write_merged_preferences!(dir, src, prof.preferences)
    return nothing
end

function resolve_environment(dir::AbstractString, prof::Profile)
    with_pkg_isolated("could not build the environment of $(relpath_or_path(prof.environment)): ") do Pkg, _
        Pkg.activate(dir; io = devnull)
        Pkg.resolve(; io = devnull)
        Pkg.instantiate(; io = devnull)
    end
    return nothing
end

# When the files an environment directory's copy was built from were last written: the
# environment's own, with the manifest that `write_environment` read, the package's
# project, the preferences, and the project of every package the built one at `dir`
# holds by path, which is how a package's siblings in a monorepo come in.
function environment_stamp(dir::AbstractString, prof::Profile, root::AbstractString)
    files = String[joinpath(prof.environment, f) for f in
                   ("Project.toml", "JuliaProject.toml", "Manifest.toml", "JuliaManifest.toml", "LocalPreferences.toml")]
    projfile = project_file(prof.environment)
    manifest = projfile === nothing ? nothing : Base.project_file_manifest_path(projfile)
    manifest === nothing || push!(files, manifest)
    push!(files, joinpath(root, "Project.toml"), joinpath(root, "JuliaProject.toml"))
    isempty(prof.preferences) || push!(files, prof.preferences)
    manifest = joinpath(dir, "Manifest.toml")
    if isfile(manifest)
        for (_, entries) in manifest_entries(TOML.parsefile(manifest))
            entries isa AbstractVector || continue
            for entry in entries
                path = entry isa AbstractDict ? get(entry, "path", nothing) : nothing
                path isa AbstractString || continue
                at = normpath(joinpath(dir, path))
                push!(files, joinpath(at, "Project.toml"), joinpath(at, "JuliaProject.toml"))
            end
        end
    end
    return Float64[mtime_or_zero(f) for f in files]
end

function copy_manifest_file(dir::AbstractString, project::AbstractString; remove_if_missing::Bool = true)
    manifest = Base.project_file_manifest_path(project)
    if manifest !== nothing && isfile(manifest)
        # A manifest's paths are its own directory's, which for a member of a
        # workspace is the workspace's.
        open(io -> TOML.print(io, absolute_paths!(TOML.parsefile(manifest), dirname(manifest)); sorted = true),
             joinpath(dir, "Manifest.toml"), "w")
    elseif remove_if_missing
        # An earlier call's, for a project that has since lost its manifest.
        rm(joinpath(dir, "Manifest.toml"); force = true)
    end
    return nothing
end

"""
    copy_env_files(dir, project)

Write the project file `project`, and the manifest that Julia reads for it, into `dir`
as `Project.toml` and `Manifest.toml`, every path made absolute from the directory of
its own file. The manifest is a versioned `Manifest-v1.x.toml` before `Manifest.toml`,
and a workspace's shared one for a member of it, as for `write_environment`. `dir` is
elsewhere, so a relative path would resolve from the wrong directory, and a worker whose
project cannot find a developed package dies before it is ready.
"""
function copy_env_files(dir::AbstractString, project::AbstractString)
    open(io -> TOML.print(io, absolute_paths!(TOML.parsefile(project), dirname(project)); sorted = true),
         joinpath(dir, "Project.toml"), "w")
    copy_manifest_file(dir, project; remove_if_missing = true)
    return nothing
end

"""
    absolute_paths!(data, root) -> data

Rewrite every `path` in a parsed project or manifest as absolute, reading relative
ones from `root`. The whole table is walked: in these files a `path` is a
filesystem path wherever it appears.
"""
function absolute_paths!(data::AbstractDict, root::AbstractString)
    for (key, value) in data
        if key == "path" && value isa AbstractString
            # A package tracked at the environment's own directory is written `.`,
            # which `abspath` turns into a path with a separator on the end.
            p = abspath(root, value)
            data[key] = isdirpath(p) ? dirname(p) : p
        elseif value isa AbstractDict
            absolute_paths!(value, root)
        elseif value isa AbstractVector
            for entry in value
                entry isa AbstractDict && absolute_paths!(entry, root)
            end
        end
    end
    return data
end
