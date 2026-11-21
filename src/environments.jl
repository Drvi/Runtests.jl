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

The last two are cached for the session and on disk across processes under
`runstate_dir(target.root)/envcache` (keyed by file content hashes, path-dependency
project/manifest hashes, Julia version, and depot package presence).

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
        testproj = test_project_file(target)
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

# Test environments, kept for the session (in-memory) and across processes (on disk
# under `runstate_dir(target.root)/envcache`): building one costs a resolve plus loading
# `Pkg`/`TestEnv`, seconds on every cold CLI or CI run. It costs no compilation: caches
# are keyed by package versions and flags, not by environment, so a reused or rebuilt
# environment with the same versions reuses them.
#
# Both caches track every input that can change resolution: the package and test
# `Project.toml`/`JuliaProject.toml`, their resolved manifests, `LocalPreferences.toml`,
# workspace ancestor and member projects (Julia 1.12+), every developed path dependency's
# project and manifest, installed registry metadata (`*.toml` / `*/Registry.toml`), and
# depot package/artifact state. The in-memory table checks mtimes + depot state for fast
# hits within a session; the disk cache checks file content hashes (surviving CI checkout
# mtime resets), cached file integrity, and pure-Base manifest package presence.
const SessionEnvStamp = Tuple{Vector{Tuple{String, Float64}}, UInt32}
const TEST_ENVS = Dict{String, Tuple{String, SessionEnvStamp}}()
const TEST_ENVS_LOCK = ReentrantLock()

test_project_file(target) = something(project_file(target.testdir), joinpath(target.testdir, "Project.toml"))

function test_env(target, announce = nothing)
    proj = abspath(target.project)
    return @lock TEST_ENVS_LOCK begin
        cached = get(TEST_ENVS, proj, nothing)
        if cached !== nothing && isfile(cached[1]) && cached[2] == session_env_stamp(target, cached[1])
            return cached[1]
        end
        disk = load_disk_test_env(target)
        if disk !== nothing
            TEST_ENVS[proj] = (disk, session_env_stamp(target, disk))
            return disk
        end
        # Announced only when building: a cache hit is immediate, and at the REPL
        # or on a warm CI run the hit is the point.
        announce === nothing || announce()
        testproj = test_project_file(target)
        workspace = in_package_workspace(testproj, proj)
        env = with_pkg_isolated("could not build a test environment for $(relpath_or_path(proj)): ") do Pkg, TestEnv
            if workspace
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
        # Persisted and stamped *after* generating it: resolving can write the
        # package's manifest, so computing hashes beforehand would miss on the
        # very next call.
        saved = save_disk_test_env(target, env, workspace)
        TEST_ENVS[proj] = (saved, session_env_stamp(target, saved))
        return saved
    end
end

mtime_or_zero(path::AbstractString) = isfile(path) ? mtime(path) : 0.0

function file_crc32c(path::AbstractString)
    isfile(path) || return (false, UInt32(0))
    try
        return (true, open(crc32c, path))
    catch e
        is_interrupt(e) && rethrow()
        return (false, UInt32(0))
    end
end

file_tag(path::AbstractString) =
    isempty(path) ? "0:00000000" : ((ex, h) = file_crc32c(path); string(ex ? "1:" : "0:", string(h; base = 16, pad = 8)))

test_env_cache_root(target) = joinpath(runstate_dir(target.root), ENV_CACHE_DIR)
test_env_proj_prefix(proj::AbstractString) =
    string(string(crc32c(abspath(proj)); base = 16, pad = 8), "-v", VERSION.major, ".", VERSION.minor, "-")

# Collect every project, manifest, preferences, workspace ancestor/member, and registry
# metadata file that can influence `TestEnv.activate()` or `Pkg.instantiate()`.
function env_input_files(target)
    proj = abspath(target.project)
    proj_dir = dirname(proj)
    test_dir = abspath(target.testdir)
    manifest_of(p) = something(isfile(p) ? Base.project_file_manifest_path(p) : nothing, "")
    seen = Set{String}()
    files = String[]
    add!(p::AbstractString) = (isempty(p) || p in seen) ? nothing : (push!(seen, String(p)); push!(files, String(p)); nothing)
    add_project_dir!(d::AbstractString) = begin
        for name in ("JuliaProject.toml", "Project.toml", "LocalPreferences.toml")
            add!(joinpath(d, name))
        end
        pf = project_file(d)
        pf === nothing || add!(manifest_of(pf))
    end

    add_project_dir!(proj_dir)
    add_project_dir!(test_dir)
    add!(proj)
    add!(manifest_of(proj))
    testproj = test_project_file(target)
    add!(testproj)
    add!(manifest_of(testproj))

    # Julia 1.12+ workspaces: walk every ancestor up to the outermost workspace root and
    # include every workspace member project listed there, since editing any member or
    # root `[sources]`/`[compat]`/`[workspace]` can make the shared manifest stale.
    @static if isdefined(Base, :base_project)
        for seed in (proj, testproj)
            isfile(seed) || continue
            cur = abspath(seed)
            while true
                add_project_dir!(dirname(cur))
                parent = Base.base_project(cur)
                (parent === nothing || samefile(parent, cur)) && break
                cur = abspath(parent)
            end
            ws_root = dirname(cur)
            ws_pf = project_file(ws_root)
            if ws_pf !== nothing && isfile(ws_pf)
                ws_table = get(parse_project(ws_pf), "workspace", nothing)
                if ws_table isa AbstractDict
                    for rel in get(ws_table, "projects", Any[])
                        rel isa AbstractString || continue
                        add_project_dir!(abspath(joinpath(ws_root, rel)))
                    end
                end
            end
        end
    end

    # Installed registry metadata (`*.toml` for compressed tarballs, `*/Registry.toml`
    # for unpacked directories): ~100 B files carrying each registry's `git-tree-sha1`,
    # so `Pkg.Registry.update()` invalidates test-only dependency resolutions.
    for depot in DEPOT_PATH
        reg_dir = joinpath(depot, "registries")
        isdir(reg_dir) || continue
        entries = try
            readdir(reg_dir)
        catch
            continue
        end
        for entry in entries
            p = joinpath(reg_dir, entry)
            if endswith(entry, ".toml") && isfile(p)
                add!(p)
            elseif isdir(p)
                rt = joinpath(p, "Registry.toml")
                isfile(rt) && add!(rt)
            end
        end
    end
    return sort!(files)
end

# Hash of the unique artifact directory names available across `DEPOT_PATH`: survives
# CI cache mtime resets and empty overlay depots while invalidating immediately if
# `Pkg.gc()` deletes an artifact or a depot switch drops available artifacts.
function depot_artifacts_hash()
    seen = Set{String}()
    for depot in DEPOT_PATH
        adir = joinpath(depot, "artifacts")
        isdir(adir) || continue
        names = try
            readdir(adir)
        catch
            continue
        end
        for n in names
            push!(seen, n)
        end
    end
    io = IOBuffer()
    for n in sort!(collect(seen))
        print(io, n, '\0')
    end
    return crc32c(take!(io))
end

# Fast in-session stamp: mtimes of all input files + resolved path-dep project/manifest
# files + available depot artifacts hash. Catches mid-session edits to path deps,
# workspace members, registries, or `Pkg.gc()` without re-hashing every file on a hit.
function session_env_stamp(target, env_proj::AbstractString)::SessionEnvStamp
    files = env_input_files(target)
    mf = isfile(env_proj) ? Base.project_file_manifest_path(env_proj) : nothing
    if mf !== nothing && isfile(mf)
        toml = try
            TOML.parsefile(mf)
        catch
            nothing
        end
        if toml !== nothing
            mf_dir = dirname(abspath(mf))
            seen = Set(files)
            for (_, entries) in manifest_entries(toml)
                entries isa AbstractVector || continue
                for entry in entries
                    entry isa AbstractDict || continue
                    p = get(entry, "path", nothing)
                    p isa AbstractString || continue
                    d = rstrip_path(normpath(joinpath(mf_dir, p)))
                    for f in (joinpath(d, "JuliaProject.toml"), joinpath(d, "Project.toml"))
                        f in seen || (push!(seen, f); push!(files, f))
                    end
                    pf = project_file(d)
                    if pf !== nothing
                        dmf = something(Base.project_file_manifest_path(pf), "")
                        (!isempty(dmf) && !(dmf in seen)) && (push!(seen, dmf); push!(files, dmf))
                    end
                end
            end
            sort!(files)
        end
    end
    stamps = Tuple{String, Float64}[(f, mtime_or_zero(f)) for f in files]
    return (stamps, depot_artifacts_hash())
end

# Content hash of every input file that determines the test environment (plus Julia
# version, workspace mode, depot paths, and depot artifacts). Content-hashed rather than
# mtime-hashed so CI checkouts with freshly reset mtimes still hit a cached environment.
function disk_env_input_key(target, workspace::Bool)
    io = IOBuffer()
    print(io, VERSION, '\0', workspace ? '1' : '0', '\0', string(depot_artifacts_hash(); base = 16, pad = 8))
    for f in env_input_files(target)
        exists, h = file_crc32c(f)
        print(io, '\0', f, '\0', exists ? '1' : '0', '\0', string(h; base = 16, pad = 8))
    end
    return string(crc32c(take!(io)); base = 16, pad = 8)
end

# Sorted `[dep_dir, proj_path, proj_crc, manifest_path, manifest_crc]` rows for every
# package tracked by `path` in `manifest_path`. Catches a developed dependency whose own
# dependencies or manifest changed without touching the target package's files.
function manifest_path_dep_stamps(manifest_path::AbstractString, toml::AbstractDict)
    mf_dir = dirname(abspath(manifest_path))
    dirs = Set{String}()
    for (_, entries) in manifest_entries(toml)
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict || continue
            p = get(entry, "path", nothing)
            p isa AbstractString || continue
            push!(dirs, rstrip_path(normpath(joinpath(mf_dir, p))))
        end
    end
    rows = Vector{String}[]
    for d in sort!(collect(dirs))
        pf = something(project_file(d), "")
        mf = isempty(pf) ? "" : something(Base.project_file_manifest_path(pf), "")
        push!(rows, String[d, pf, file_tag(pf), mf, file_tag(mf)])
    end
    return rows
end

function path_dep_stamps_match(rows)
    rows isa AbstractVector || return false
    for row in rows
        (row isa AbstractVector && length(row) == 5 && all(x -> x isa AbstractString, row)) || return false
        d, pf_rec, pf_tag, mf_rec, mf_tag = row
        isdir(d) || return false
        pf_now = something(project_file(d), "")
        pf_now == pf_rec || return false
        file_tag(pf_now) == pf_tag || return false
        mf_now = isempty(pf_now) ? "" : something(Base.project_file_manifest_path(pf_now), "")
        mf_now == mf_rec || return false
        file_tag(mf_now) == mf_tag || return false
    end
    return true
end

# Verify without loading `Pkg` that every package named in `manifest_path` is currently
# present on disk (path directory with project or entry file, `DEPOT_PATH` package slug,
# or `Sys.STDLIB`).
function manifest_packages_present(manifest_path::AbstractString, toml::AbstractDict)
    mf_dir = dirname(abspath(manifest_path))
    for (name, entries) in manifest_entries(toml)
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict || continue
            if haskey(entry, "path")
                p = entry["path"]
                p isa AbstractString || return false
                dir = normpath(joinpath(mf_dir, p))
                (isdir(dir) && (project_file(dir) !== nothing || isfile(joinpath(dir, "src", string(name, ".jl"))))) || return false
            elseif haskey(entry, "git-tree-sha1")
                uuid_s = get(entry, "uuid", nothing)
                tree_s = get(entry, "git-tree-sha1", nothing)
                (uuid_s isa AbstractString && tree_s isa AbstractString) || return false
                uuid = tryparse(Base.UUID, uuid_s)
                uuid === nothing && return false
                sha = try
                    Base.SHA1(tree_s)
                catch
                    return false
                end
                slug = Base.version_slug(uuid, sha)
                any(d -> isdir(joinpath(d, "packages", name, slug)), DEPOT_PATH) || return false
            else
                isdir(joinpath(Sys.STDLIB, name)) || return false
            end
        end
    end
    return true
end

const ENV_CACHE_STAMP = "stamp.toml"

function load_disk_test_env(target)
    try
        cache_root = test_env_cache_root(target)
        isdir(cache_root) || return nothing
        proj = abspath(target.project)
        testproj = test_project_file(target)
        workspace = in_package_workspace(testproj, proj)
        input_key = disk_env_input_key(target, workspace)
        want_prefix = string(test_env_proj_prefix(proj), input_key, "-")
        want_mode = workspace ? "workspace" : "testenv"
        ver = string(VERSION)
        for name in readdir(cache_root)
            startswith(name, want_prefix) || continue
            entry_dir = joinpath(cache_root, name)
            isdir(entry_dir) || continue
            stamp_file = joinpath(entry_dir, ENV_CACHE_STAMP)
            isfile(stamp_file) || continue
            stamp = try
                TOML.parsefile(stamp_file)
            catch
                continue
            end
            get(stamp, "mode", "") == want_mode || continue
            get(stamp, "julia_version", "") == ver || continue
            get(stamp, "input_key", "") == input_key || continue
            env_proj = workspace ? String(get(stamp, "env_path", "")) : joinpath(entry_dir, "Project.toml")
            (isempty(env_proj) || !isfile(env_proj)) && continue
            workspace && !samefile(env_proj, testproj) && continue
            mf = Base.project_file_manifest_path(env_proj)
            (mf === nothing || !isfile(mf)) && continue
            if !workspace
                file_tag(env_proj) == get(stamp, "cached_proj_crc", "") || continue
                file_tag(mf) == get(stamp, "cached_mf_crc", "") || continue
            end
            mf_toml = try
                TOML.parsefile(mf)
            catch
                continue
            end
            path_dep_stamps_match(get(stamp, "path_deps", nothing)) || continue
            manifest_packages_present(mf, mf_toml) || continue
            return env_proj
        end
        return nothing
    catch e
        is_interrupt(e) && rethrow()
        return nothing
    end
end

function save_disk_test_env(target, env::AbstractString, workspace::Bool)
    try
        mf = Base.project_file_manifest_path(env)
        (mf === nothing || !isfile(mf)) && return String(env)
        mf_toml = TOML.parsefile(mf)
        cache_root = test_env_cache_root(target)
        mkpath(cache_root)
        if isempty(get(ENV, "RUNTESTS_RUNSTATE_DIR", ""))
            mark = joinpath(dirname(cache_root), PROJECT_MARK)
            isfile(mark) || write_whole(mark, abspath(target.root))
        end
        proj = abspath(target.project)
        proj_prefix = test_env_proj_prefix(proj)
        input_key = disk_env_input_key(target, workspace)
        dep_rows = manifest_path_dep_stamps(mf, mf_toml)
        deps_io = IOBuffer()
        for row in dep_rows
            for col in row
                print(deps_io, col, '\0')
            end
        end
        deps_key = string(crc32c(take!(deps_io)); base = 16, pad = 8)
        entry_name = string(proj_prefix, input_key, "-", deps_key)
        entry_dir = joinpath(cache_root, entry_name)
        if !isdir(entry_dir)
            tmp = mktempdir(cache_root; prefix = ".tmp_")
            try
                cached_proj_crc = ""
                cached_mf_crc = ""
                if !workspace
                    copy_env_files(tmp, env)
                    prefs = joinpath(dirname(env), "LocalPreferences.toml")
                    isfile(prefs) && cp(prefs, joinpath(tmp, "LocalPreferences.toml"); force = true)
                    cached_proj_crc = file_tag(joinpath(tmp, "Project.toml"))
                    cached_mf_crc = file_tag(joinpath(tmp, "Manifest.toml"))
                end
                stamp = Dict{String, Any}(
                    "mode" => workspace ? "workspace" : "testenv",
                    "julia_version" => string(VERSION),
                    "input_key" => input_key,
                    "env_path" => workspace ? abspath(env) : "",
                    "cached_proj_crc" => cached_proj_crc,
                    "cached_mf_crc" => cached_mf_crc,
                    "path_deps" => dep_rows,
                )
                open(io -> TOML.print(io, stamp; sorted = true), joinpath(tmp, ENV_CACHE_STAMP), "w")
                try
                    mv(tmp, entry_dir)
                catch e
                    is_interrupt(e) && rethrow()
                    # Another process may have raced to write the exact same immutable entry.
                    isdir(entry_dir) || rethrow()
                    rm(tmp; force = true, recursive = true)
                end
            catch
                rm(tmp; force = true, recursive = true)
                rethrow()
            end
        end
        # Best-effort prune superseded cache entries for this project + Julia minor version.
        for other in readdir(cache_root)
            (startswith(other, proj_prefix) && other != entry_name) || continue
            try
                rm(joinpath(cache_root, other); force = true, recursive = true)
            catch e
                is_interrupt(e) && rethrow()
            end
        end
        return workspace ? abspath(env) : joinpath(entry_dir, "Project.toml")
    catch e
        is_interrupt(e) && rethrow()
        return String(env)
    end
end

function clear_disk_test_env!(target)
    try
        cache_root = test_env_cache_root(target)
        isdir(cache_root) || return nothing
        prefix = test_env_proj_prefix(abspath(target.project))
        for name in readdir(cache_root)
            startswith(name, prefix) || continue
            rm(joinpath(cache_root, name); force = true, recursive = true)
        end
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

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

# Parse a recorded `skip` policy string back into `Bool` or `Expr`, or `nothing` if
# it cannot be parsed cleanly.
function parse_recorded_skip(text::AbstractString)
    text == "false" && return false
    text == "true" && return true
    ex = Meta.parse(text; raise = false)
    ex isa Expr && (ex.head === :error || ex.head === :incomplete) && return nothing
    return ex
end

# Apply recorded per-item policies from `records` onto `p` (unless overridden by explicit
# call `kwargs`), collect per-profile worker environment snapshots, and return `p` with
# its `ReplayDiff` attached. When `dry_run` is true, also populate on-disk environment diffs.
function apply_recorded_replay!(p::Plan, given::RunStateRecord, records::Vector, kwargs;
                                gone::Vector{String} = String[], changed::Vector{String} = String[],
                                env_moved::Vector{String} = String[], dry_run::Bool = false,
                                target_project::AbstractString = "")
    rec_rev = get(given.meta, "revision", "")
    rec_wt = get(given.meta, "worktree", "")
    cur_rev = project_revision(p.root)
    cur_wt = isempty(cur_rev) && isempty(rec_rev) ? "" : worktree_state(p.root)

    override_timeout = haskey(kwargs, :timeout)
    override_retries = haskey(kwargs, :retries)
    override_failfast = haskey(kwargs, :item_failfast)

    policies = ReplayPolicyDiff[]
    snapshots = ReplayProfileSnapshot[]
    seen_snaps = Set{Tuple{ProfileIdx, Int, Int}}()

    for (k, rs) in enumerate(records)
        rs === nothing && continue
        rec_idx = Dict{String, Int}(it.name => idx for (idx, it) in enumerate(rs.items))
        for i in 1:nitems(p)
            p.items.package[i] == k || continue
            ridx = get(rec_idx, p.items.name[i], 0)
            ridx == 0 && continue
            if ridx <= length(rs.policies)
                pol = rs.policies[ridx]
                cur_t = item_timeout(p, ItemIdx(i))
                cur_r = attempts_for(p, i) - 1
                cur_f = item_failfast(p, i)
                cur_s = p.items.skip[i]
                cur_s_text = cur_s isa Expr ? expr_text(cur_s) : string(cur_s)
                parts = String[]
                if !override_timeout && cur_t != Int(pol.timeout_s)
                    p.items.timeout_s[i] = pol.timeout_s
                    push!(parts, string("timeout ", pol.timeout_s, "s (checkout ", cur_t, "s)"))
                end
                if !override_retries && cur_r != Int(pol.retries)
                    p.items.retries[i] = Int32(pol.retries)
                    push!(parts, string("retries ", pol.retries, " (checkout ", cur_r, ")"))
                end
                if !override_failfast && cur_f != pol.failfast
                    p.items.failfast[i] = Int8(pol.failfast ? 1 : 0)
                    push!(parts, string("failfast ", pol.failfast, " (checkout ", cur_f, ")"))
                end
                if cur_s_text != pol.skip
                    parsed = parse_recorded_skip(pol.skip)
                    if parsed !== nothing
                        p.items.skip[i] = parsed
                        push!(parts, string("skip `", pol.skip, "` (checkout `", cur_s_text, "`)"))
                    end
                end
                if !isempty(parts)
                    label = is_combined(p) ? string(p.packages.name[k], " ", repr(p.items.name[i])) : repr(p.items.name[i])
                    push!(policies, ReplayPolicyDiff(label, join(parts, ", ")))
                end
            end
            rec_prof = Int(rs.items[ridx].profile)
            if 1 <= rec_prof <= length(rs.profile_environments)
                env_idx = rs.profile_environments[rec_prof]
                if 1 <= env_idx <= length(rs.worker_environments)
                    j_now = p.items.profile[i]
                    key = (j_now, k, env_idx)
                    if !(key in seen_snaps)
                        push!(seen_snaps, key)
                        we = rs.worker_environments[env_idx]
                        same_as_run = we.manifest_zlib === rs.manifest_zlib && we.manifest_bytes == rs.manifest_bytes
                        prof = p.profiles[j_now]
                        env_rel = isempty(prof.environment) ? "" : relpath_or_path(prof.environment, p.packages.root[k])
                        base = isempty(env_rel) ? string("profile `", prof.name, "`") : string("profile `", prof.name, "` (", env_rel, ")")
                        plabel = is_combined(p) ? string(p.packages.name[k], " · ", base) : base
                        push!(snapshots, ReplayProfileSnapshot(j_now, plabel, we.manifest_bytes, we.manifest_zlib,
                                                               we.preferences, same_as_run))
                    end
                end
            end
        end
    end

    diff = ReplayDiff(
        basename(run_location(given.path)), rec_rev, rec_wt, cur_rev, cur_wt,
        gone, changed, env_moved, policies, ReplayEnvDiff[], snapshots
    )
    dry_run && populate_dry_run_env_diffs!(diff, p, target_project)
    replay_slots, slot_pool, slot_items = recorded_replay_slots(p, records)
    return with_replay(p, diff; replay_slots, slot_pool, slot_items)
end

# Reconstruct the exact per-slot item sequence recorded in `records`, restricted to the
# items selected in `p`. Any selected item not seen in the recorded `:attempt` events
# (e.g. UNSEEN in a crashed recording) is appended after the recorded work so nothing is
# dropped. Preserves up to `max(p.cfg.workers, 1)` recorded slots even when `count_slots`
# would otherwise allocate fewer slots for fast items. Returns `(replay_slots, slot_pool, slot_items)`.
function recorded_replay_slots(p::Plan, records::Vector)
    (nslots(p) == 0 || nitems(p) == 0) && return Vector{ItemIdx}[], p.slot_pool, p.slot_items
    plan_item = Dict{Tuple{Int32, String}, ItemIdx}(
        (p.items.package[i], p.items.name[i]) => ItemIdx(i) for i in 1:nitems(p)
    )
    by_slot = Dict{Int, Vector{Tuple{Float32, Int, ItemIdx}}}()
    seen = falses(nitems(p))
    ord = 0
    for (k, rs) in enumerate(records)
        rs === nothing && continue
        pkg = Int32(k)
        for ev in rs.events
            ev.kind === :attempt || continue
            1 <= ev.item <= length(rs.items) || continue
            slot = Int(ev.slot)
            slot > 0 || continue
            idx = get(plan_item, (pkg, rs.items[ev.item].name), ItemIdx(0))
            (idx == 0 || seen[idx]) && continue
            seen[idx] = true
            ord += 1
            push!(get!(Vector{Tuple{Float32, Int, ItemIdx}}, by_slot, slot), (ev.t0, ord, idx))
        end
    end
    isempty(by_slot) && return Vector{ItemIdx}[], p.slot_pool, p.slot_items

    rec_slots = sort!(collect(keys(by_slot)))
    budget = max(p.cfg.workers, 1)
    S = min(budget, max(nslots(p), maximum(rec_slots)))
    replay_slots = [ItemIdx[] for _ in 1:S]
    preserve_ids = maximum(rec_slots) <= S
    for (pos, r) in enumerate(rec_slots)
        entries = sort!(by_slot[r]; by = x -> (x[1], x[2]))
        dest = preserve_ids ? r : mod1(pos, S)
        for (_, _, idx) in entries
            push!(replay_slots[dest], idx)
        end
    end
    # Append any selected items never attempted in the recording (e.g. after a crash/failfast).
    for i in ItemIdx(1):ItemIdx(nitems(p))
        seen[i] && continue
        dest = argmin(length, replay_slots)
        push!(dest, i)
    end
    item_pool = zeros(Int32, nitems(p))
    for (k, pool) in enumerate(p.pools)
        for range in (pool.head, pool.body, pool.tail)
            for i in range
                item_pool[i] = Int32(k)
            end
        end
    end
    slot_pool = Int32[s <= length(p.slot_pool) ? p.slot_pool[s] : Int32(1) for s in 1:S]
    slot_items = UnitRange{ItemIdx}[s <= length(p.slot_items) ? p.slot_items[s] : (ItemIdx(1):ItemIdx(0)) for s in 1:S]
    for s in 1:S
        isempty(replay_slots[s]) || (slot_pool[s] = item_pool[replay_slots[s][1]])
    end
    return replay_slots, slot_pool, slot_items
end

function compare_manifest_texts(here_text::AbstractString, there_text::AbstractString)
    here = manifest_versions(here_text)
    there = manifest_versions(there_text)
    diffs, by_path = String[], String[]
    for name in sort!(collect(union(keys(here), keys(there))))
        h, t = get(here, name, nothing), get(there, name, nothing)
        if h !== nothing && t !== nothing && (h.path || t.path)
            push!(by_path, name)
        elseif !same_code(h, t)
            push!(diffs, string(name, ": ", code_text(t), " when recorded, ", code_text(h), " here"))
        end
    end
    return diffs, by_path
end

function compare_project_env(label::AbstractString, proj_file::Union{Nothing, AbstractString},
                             there_manifest::AbstractString, there_prefs::Union{Nothing, AbstractString};
                             partial::Bool = false, require_manifest::Bool = false)
    here_manifest = read_text(proj_file === nothing ? nothing : Base.project_file_manifest_path(proj_file))
    diffs, by_path = (isempty(there_manifest) || (require_manifest && isempty(here_manifest))) ?
        (String[], String[]) : compare_manifest_texts(here_manifest, there_manifest)
    prefs_differ = false
    if there_prefs !== nothing
        here_prefs = proj_file === nothing ? "" : read_text(joinpath(dirname(proj_file), "LocalPreferences.toml"))
        prefs_differ = strip(here_prefs) != strip(there_prefs)
    end
    return ReplayEnvDiff(String(label), diffs, by_path, prefs_differ, partial)
end

# Best-effort read-only project lookup for `dry_run = true`, avoiding `TestEnv.activate()`.
function dry_run_test_project(p::Plan, target_project::AbstractString)
    current = Base.active_project()
    testproj = joinpath(p.root, "test", "Project.toml")
    if current !== nothing && isfile(testproj) && abspath(current) == abspath(testproj)
        return current, false
    end
    if !isempty(target_project)
        proj = abspath(target_project)
        cached = @lock TEST_ENVS_LOCK get(TEST_ENVS, proj, nothing)
        if cached !== nothing && isfile(cached[1])
            return cached[1], false
        end
        if isfile(testproj) && (in_package_workspace(testproj, proj) ||
                                Base.project_file_manifest_path(testproj) !== nothing)
            return testproj, false
        end
        return proj, isfile(testproj) || Base.project_file_manifest_path(proj) !== nothing
    end
    ws_proj = project_file(p.root)
    return ws_proj, ws_proj !== nothing
end

function populate_dry_run_env_diffs!(diff::ReplayDiff, p::Plan, target_project::AbstractString)
    empty!(diff.envs)
    recorded = p.cfg.replayed_manifest
    main_proj, partial = dry_run_test_project(p, target_project)
    if !isempty(recorded)
        push!(diff.envs, compare_project_env("test environment", main_proj, recorded, nothing;
                                             partial, require_manifest = true))
    end
    for snap in diff.snapshots
        prof = p.profiles[snap.profile_idx]
        wfile = !isempty(prof.environment) ? project_file(prof.environment) : main_proj
        if snap.same_as_run && isempty(prof.environment) && isempty(snap.preferences)
            continue
        end
        there_manifest = snap.same_as_run ? recorded :
            inflate_manifest(snap.manifest_zlib, snap.manifest_bytes, snap.label)
        # For a profile with its own preferences file, compare the checkout's file if present.
        here_prefs_proj = !isempty(prof.environment) ? wfile :
            isempty(prof.preferences) ? wfile : prof.preferences
        env_diff = compare_project_env(snap.label, wfile, there_manifest, nothing;
                                       partial = isempty(prof.environment) && partial,
                                       require_manifest = true)
        if !isempty(snap.preferences) || (!isempty(prof.environment) && wfile !== nothing && isfile(joinpath(dirname(wfile), "LocalPreferences.toml")))
            here_prefs = !isempty(prof.environment) ?
                (wfile === nothing ? "" : read_text(joinpath(dirname(wfile), "LocalPreferences.toml"))) :
                read_text(here_prefs_proj)
            prefs_differ = strip(here_prefs) != strip(snap.preferences)
            env_diff = ReplayEnvDiff(env_diff.label, env_diff.diffs, env_diff.by_path, prefs_differ, env_diff.partial)
        end
        push!(diff.envs, env_diff)
    end
    return diff
end

function git_diff_text(d::ReplayDiff)
    rec_r, cur_r = d.recorded_rev, d.current_rev
    rec_w, cur_w = d.recorded_worktree, d.current_worktree
    short(r) = isempty(r) ? "none" : first(r, 10)
    wt(w) = (w == "clean" || w == "dirty") ? " ($w)" : ""
    if rec_r != cur_r
        return string("rev ", short(rec_r), wt(rec_w), " when recorded, rev ", short(cur_r), wt(cur_w), " here")
    end
    isempty(rec_r) && rec_w != "dirty" && cur_w != "dirty" && return ""
    if rec_w == "dirty" && cur_w == "dirty"
        return string("recorded at rev ", short(rec_r), " with uncommitted changes, and this checkout is also dirty")
    elseif rec_w == "dirty"
        return string("recorded at rev ", short(rec_r), " with uncommitted changes (not in git)")
    elseif cur_w == "dirty"
        return string("rev ", short(rec_r), " matches, but this checkout has uncommitted changes")
    end
    return ""
end

has_env_diff(e::ReplayEnvDiff) = !isempty(e.diffs) || e.prefs_differ

has_replay_diff(d::ReplayDiff) =
    !isempty(git_diff_text(d)) || !isempty(d.gone) || !isempty(d.changed) ||
    !isempty(d.env_moved) || !isempty(d.policies) || any(has_env_diff, d.envs)

function format_replay_warning(d::ReplayDiff)
    lines = String[]
    g = git_diff_text(d)
    isempty(g) || push!(lines, string("  revision: ", g))
    item_parts = String[]
    isempty(d.gone) || push!(item_parts, string(plural(length(d.gone), "missing item"), " skipped"))
    isempty(d.changed) || push!(item_parts, string(plural(length(d.changed), "changed item"),
        " (running as the checkout has ", length(d.changed) == 1 ? "it" : "them", ")"))
    isempty(d.env_moved) || push!(item_parts, string(plural(length(d.env_moved), "item"), " moved environment"))
    isempty(item_parts) || push!(lines, string("  items: ", join(item_parts, " · ")))
    isempty(d.policies) || push!(lines, string("  policies: ", plural(length(d.policies), "item"),
        " use", length(d.policies) == 1 ? "s" : "", " the recorded policy where this checkout differs"))
    env_parts = String[]
    for e in d.envs
        ep = String[]
        isempty(e.diffs) || push!(ep, string(plural(length(e.diffs), "package"), " differ", length(e.diffs) == 1 ? "s" : ""))
        e.prefs_differ && push!(ep, "preferences differ")
        isempty(ep) || push!(env_parts, string(join(ep, ", "), " in ", e.label))
    end
    isempty(env_parts) || push!(lines, string("  environments: ", join(env_parts, " · ")))
    isempty(lines) && return ""
    return string(
        "Runtests: this checkout differs from the replayed run:\n",
        join(lines, "\n"),
        "\n  run with `dry_run = true` for details"
    )
end

# A replay runs against this machine's environments, which may not be the ones the
# run state was recorded in. Every package and preference difference is collected on
# `run.plan.replay`, and any drift across revision, items, policies or environments is
# reported in one brief warning pointing to `dry_run = true` for full details.
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
    diff = run.plan.replay
    diff === nothing && return nothing
    empty!(diff.envs)
    recorded = cfg.replayed_manifest
    env = Base.active_project()
    if !isempty(recorded)
        push!(diff.envs, compare_project_env("test environment", env, recorded, nothing))
    end
    for snap in diff.snapshots
        wproj = worker_project(run, snap.profile_idx)
        wfile = isempty(wproj) ? nothing : isdir(wproj) ? project_file(wproj) : String(wproj)
        same_file = wfile !== nothing && env !== nothing && abspath(wfile) == abspath(env)
        snap.same_as_run && same_file && isempty(snap.preferences) && continue
        there_manifest = snap.same_as_run ? recorded :
            inflate_manifest(snap.manifest_zlib, snap.manifest_bytes, snap.label)
        push!(diff.envs, compare_project_env(snap.label, wfile, there_manifest, snap.preferences))
    end
    by_path = sort!(unique!(reduce(vcat, (e.by_path for e in diff.envs); init = String[])))
    # Its path is the recording machine's, and its source may differ under the same one.
    isempty(by_path) || say(run, "tracked by path, so not compared with the recorded run: ", join(by_path, ", "))
    if !isempty(recorded) && !any(has_env_diff, diff.envs)
        say(run, "the test environment matches the one the run state was recorded in")
    end
    msg = format_replay_warning(diff)
    isempty(msg) || @warn msg
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

# A minimal synthetic project containing only `Runtests` and its transitive dependencies
# (copied from the manifest that loaded `Runtests` in this process). Environment directories
# (`test/qa/`) stack over this instead of over the package's test environment, so workers
# can load `RuntestsWorkers` without leaking undeclared dependencies from `test/Project.toml`.
const RUNTESTS_BASE_ENV = Ref{String}("")
const RUNTESTS_BASE_ENV_LOCK = ReentrantLock()

function runtests_base_env()
    return @lock RUNTESTS_BASE_ENV_LOCK begin
        cached = RUNTESTS_BASE_ENV[]
        !isempty(cached) && isfile(cached) && return cached
        built = build_runtests_base_env()
        built === nothing || (RUNTESTS_BASE_ENV[] = built)
        built
    end
end

function enqueue_manifest_deps!(queue::Vector{Tuple{String, String}}, src_deps::AbstractDict, d)
    if d isa AbstractDict
        for (dn, du) in d
            push!(queue, (String(dn), string(du)))
        end
    elseif d isa AbstractVector
        for dn in d
            es = get(src_deps, String(dn), nothing)
            if es isa AbstractVector && length(es) == 1 && es[1] isa AbstractDict
                push!(queue, (String(dn), string(get(es[1], "uuid", ""))))
            end
        end
    end
    return nothing
end

function build_runtests_base_env()
    pkgid = RuntestsWorkers.PKGID
    rt_uuid = string(pkgid.uuid)
    rt_root = pkgdir(Base.moduleroot(@__MODULE__))
    candidates = String[]
    active = Base.active_project()
    active === nothing || push!(candidates, active)
    for p in Base.load_path()
        pf = isdir(p) ? project_file(p) : p
        pf === nothing || push!(candidates, pf)
    end
    if rt_root !== nothing
        pf = project_file(rt_root)
        pf === nothing || push!(candidates, pf)
    end
    for pf in candidates
        isfile(pf) || continue
        mf = Base.project_file_manifest_path(pf)
        (mf === nothing || !isfile(mf)) && continue
        toml = try
            TOML.parsefile(mf)
        catch
            continue
        end
        src_deps = manifest_entries(toml)
        in_manifest = any(
            e -> e isa AbstractDict && string(get(e, "uuid", "")) == rt_uuid,
            get(src_deps, pkgid.name, Any[])
        )
        is_root = get(parse_project(pf), "uuid", "") == rt_uuid
        (in_manifest || is_root) || continue

        visited = Set{String}()
        kept = Dict{String, Vector{Dict{String, Any}}}()
        queue = Tuple{String, String}[]

        if in_manifest
            push!(queue, (pkgid.name, rt_uuid))
        else
            rt_root === nothing && continue
            rt_pf = project_file(rt_root)
            rt_pf === nothing && continue
            rt_proj = parse_project(rt_pf)
            rt_deps = get(Dict{String, Any}, rt_proj, "deps")
            rt_weak = get(Dict{String, Any}, rt_proj, "weakdeps")
            rt_ext = get(Dict{String, Any}, rt_proj, "extensions")
            rt_entry = Dict{String, Any}(
                "uuid" => rt_uuid,
                "version" => string(get(rt_proj, "version", "0.1.0")),
                "path" => abspath(rt_root),
                "deps" => sort!(String[string(k) for k in keys(rt_deps)]),
            )
            isempty(rt_weak) || (rt_entry["weakdeps"] = Dict{String, Any}(string(k) => string(v) for (k, v) in rt_weak))
            isempty(rt_ext) || (rt_entry["extensions"] = Dict{String, Any}(string(k) => v for (k, v) in rt_ext))
            kept[pkgid.name] = Dict{String, Any}[rt_entry]
            push!(visited, rt_uuid)
            enqueue_manifest_deps!(queue, src_deps, rt_deps)
            enqueue_manifest_deps!(queue, src_deps, rt_weak)
        end

        mf_dir = dirname(abspath(mf))
        while !isempty(queue)
            name, uuid = popfirst!(queue)
            (isempty(uuid) || uuid in visited) && continue
            es = get(src_deps, name, nothing)
            es isa AbstractVector || continue
            idx = findfirst(e -> e isa AbstractDict && string(get(e, "uuid", "")) == uuid, es)
            idx === nothing && continue
            push!(visited, uuid)
            copied = deepcopy(es[idx]::Dict{String, Any})
            if haskey(copied, "path") && copied["path"] isa AbstractString && !isabspath(copied["path"])
                copied["path"] = abspath(joinpath(mf_dir, copied["path"]))
            end
            push!(get!(Vector{Dict{String, Any}}, kept, name), copied)
            haskey(copied, "deps") && enqueue_manifest_deps!(queue, src_deps, copied["deps"])
            haskey(copied, "weakdeps") && enqueue_manifest_deps!(queue, src_deps, copied["weakdeps"])
        end

        dir = mktempdir(; prefix = "runtests_base_")
        proj_out = joinpath(dir, "Project.toml")
        man_out = joinpath(dir, "Manifest.toml")
        open(proj_out, "w") do io
            # Both `Runtests` (for `RuntestsWorkers`) and `Test` (injected into every `@testitem`,
            # and absent from `LOAD_PATH` when `Pkg.test` strips `@stdlib`).
            TOML.print(io, Dict("deps" => Dict(
                pkgid.name => rt_uuid,
                "Test" => "8dfed614-e22c-5e08-85e1-65c5234f0b40",
            )); sorted = true)
        end
        out_manifest = Dict{String, Any}("deps" => kept)
        for k in ("julia_version", "manifest_format")
            haskey(toml, k) && (out_manifest[k] = toml[k])
        end
        open(man_out, "w") do io
            TOML.print(io, out_manifest; sorted = true)
        end
        return proj_out
    end
    return nothing
end

# The load path of an item in an environment directory: that environment (`@`) stacked
# over the minimal `Runtests`-only base environment (stripping `test_env` if present),
# so undeclared dependencies from `test/Project.toml` are never visible.
function isolated_load_path(load_path::Vector{String}, test_env::Union{Nothing, String})
    base = runtests_base_env()
    base === nothing && return stacked_load_path(load_path, test_env)
    out = copy(load_path)
    if test_env !== nothing
        tf = abspath(test_env)
        td = dirname(tf)
        filter!(out) do p
            (p == "@" || startswith(p, "@")) && return true
            ap = abspath(p)
            return ap != tf && ap != td
        end
    end
    return stacked_load_path(out, base)
end

# The projects of profiles running in an environment directory, kept for the session as
# the test environment is, and keyed by the environment, the package and the
# preferences: building one is a resolve.
const ENVIRONMENT_PROJECTS = Dict{NTuple{3, String}, Tuple{String, Vector{Float64}}}()
const ENVIRONMENT_PROJECTS_LOCK = ReentrantLock()

"""
    environment_project(prof, root, announce = nothing) -> String

Create the project in which workers run a profile whose `environment` is set (from its
items' directory). Copy the environment into a temporary directory, add the package at
`root` by path in `[sources]`, apply the profile's preferences over the environment's
`LocalPreferences.toml`, and resolve it. Adding the package by path in `[sources]` lets
resolution use its own `[sources]` entries. The source environment is not modified.

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

# The environment directory `prof.environment`, written into `dir` with its paths made
# absolute, the package at `root` added by path, and the preferences laid over its own.
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
