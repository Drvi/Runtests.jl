# Test items outside a run: `Runtests.activate`, and a `@testitem` pasted into a REPL.
#
# A pasted item uses the scanner's parser and the worker's item evaluator. Without
# a coordinator, run-only scheduling options need separate handling below.

# What `activate` changed, for `deactivate` to undo: `(; project, setups, target, dir,
# participants)`, or `nothing` when Runtests has not touched the session. `target` is
# the package of `activate`; `participants` the packages of `activate_mono`.
const ACTIVATION = Ref{Any}(nothing)

"""
    activate([paths...]) -> String

Make this session look the way a test item's worker does: the package's test
environment active and `test/testsetups/` on `LOAD_PATH`, so `using MySetup` and
test-only dependencies work at the REPL. Returns the environment's path;
[`deactivate`](@ref) undoes it.
"""
function activate(args...)
    ACTIVATION[] === nothing || throw(
        ConfigError(
            "Runtests is already active in this session (" *
                something(Base.active_project(), "no project") *
                "); call `Runtests.deactivate()` first"
        )
    )
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    previous = Base.active_project()
    env = test_env_for(target)
    env === nothing || Base.set_active_project(env)
    setups = joinpath(target.testdir, TESTSETUPS_DIR)
    pushed = isdir(setups) && !(setups in LOAD_PATH)
    pushed && push!(LOAD_PATH, setups)
    # Kept because it cannot be found again: with the generated environment active,
    # the session's project is the environment, not the package.
    ACTIVATION[] = (project = previous, setups = pushed ? [setups] : String[], target = target, dir = "", participants = nothing)
    active = something(Base.active_project(), "")
    println(
        stdout, label_prefix(), "activated ", relpath_or_path(active, target.root),
        pushed ? string(" · setups from ", relpath_or_path(setups, target.root)) : ""
    )
    return active
end

"""
    deactivate()

Undo [`activate`](@ref) or [`activate_mono`](@ref): restore the environment that
was active and take the setups back off `LOAD_PATH`. Does nothing if Runtests is
not active.
"""
function deactivate()
    state = ACTIVATION[]
    state === nothing && return nothing
    ACTIVATION[] = nothing
    for setups in state.setups
        i = findlast(==(setups), LOAD_PATH)
        i === nothing || deleteat!(LOAD_PATH, i)
    end
    Base.set_active_project(state.project)
    # The union environment `activate_mono` wrote.
    isempty(state.dir) || rm(state.dir; force = true, recursive = true)
    println(stdout, label_prefix(), "deactivated")
    return nothing
end

"""
    activate_mono([root]) -> String

[`activate`](@ref) for the packages of a workspace, as `runtests_mono` runs them: the
union environment of their test dependencies active, and the setups of each package
that shares workers on `LOAD_PATH`, so that the REPL loads what a shared worker loads.
With no `root`, it finds the workspace of the active project (or of the current
`test/runtests.jl` under `Pkg.test`).
An isolated package is not part of it; `activate` it on its own. A test item runs as
an item of the package whose directory holds its file, as on a shared worker: in the
union environment, with its package loaded, in its package's root. For an item pasted
at the REPL, that is the package whose directory holds the REPL's current directory.
Two setups of one name stop it before anything changes. [`deactivate`](@ref) undoes
it. Returns the active project.
"""
function activate_mono(root::Union{Nothing, AbstractString} = nothing)
    ACTIVATION[] === nothing || throw(
        ConfigError(
            "Runtests is already active in this session (" * something(Base.active_project(), "no project") *
                "); call `Runtests.deactivate()` first"
        )
    )
    ps = find_participants(root)
    PROJECT_ROOT[] = ps.workspace
    check_setup_names(ps, [setup_modules(joinpath(r, "test")) for r in ps.root])
    instantiate_workspace(ps.workspace)
    dir = mktempdir(; prefix = "runtests_union_", cleanup = false)
    previous = Base.active_project()
    pushed = String[]
    try
        union = union_environment(ps, dir)
        Base.set_active_project(union)
        for k in eachindex(ps.root)
            ps.isolated[k] && continue
            setups = joinpath(ps.root[k], "test", TESTSETUPS_DIR)
            (isdir(setups) && !(setups in LOAD_PATH)) || continue
            push!(LOAD_PATH, setups)
            push!(pushed, setups)
        end
        ACTIVATION[] = (project = previous, setups = pushed, target = nothing, dir = dir, participants = ps)
    catch
        foreach(s -> (i = findlast(==(s), LOAD_PATH); i === nothing || deleteat!(LOAD_PATH, i)), pushed)
        Base.set_active_project(previous)
        rm(dir; force = true, recursive = true)
        rethrow()
    end
    shared = count(!, ps.isolated)
    println(stdout, label_prefix(), "activated the union environment of ", plural(shared, "package"),
            isempty(pushed) ? "" : string(" · setups of ", plural(length(pushed), "package")))
    return Base.active_project()::String
end

"""
    is_activated() -> Bool

Whether [`activate`](@ref) or [`activate_mono`](@ref) is in force.
"""
is_activated() = ACTIVATION[] !== nothing

### A pasted test item ######################################################

# Keywords only a run can honour, with the reason the warning gives for each.
const REPL_IGNORED = (
    :timeout => "there is no second process to stop",
    :retries => "a failure you are looking at is not one to paper over",
    :chain => "there is nothing for it to run in sequence with",
)

# A sandboxed item has a process of its own, so a timeout has something to stop and
# a retry something to start; `chain` still has nothing to run in sequence with.
repl_ignored(sandboxed::Bool) = sandboxed ? REPL_IGNORED[3:3] : REPL_IGNORED

"""
    run_interactive(ex, source) -> Test.AbstractTestSet

Run one `@testitem` that was evaluated rather than scanned, and return its
testset. It is read by the scanner's parser and evaluated by the worker's code.
`sandbox`, a profile and an environment directory start a worker. Without a
worker, `timeout` and `retries` are ignored with a warning; `chain` is always
ignored because one pasted item has no chain to schedule.
"""
function run_interactive(ex::Expr, source::LineNumberNode)
    path = source.file === nothing ? "REPL" : String(source.file)
    target, combined = paste_target(path)
    setups = target === nothing ? Dict{Symbol, String}() : setup_modules(target.testdir)
    # An item from a file in an environment directory runs in that environment, as in a run.
    environment = target === nothing ? "" : environment_of(abspath(path), target.testdir)
    errors = ScanError[]
    item = parse_testitem(ex, path, Int32(source.line), errors, setups, environment)
    # `nothing` comes with the error that says why.
    (item === nothing || !isempty(errors)) && throw(ScanFailure(errors))
    sandboxed = item.exclusive || item.profile !== DEFAULT_PROFILE || !isempty(item.environment)
    warn_ignored(item, sandboxed)
    return exclusively() do
        with_interactive_env(target; combined) do
            sandboxed && return run_sandboxed(item, target).testset
            say(item, target, 1, nothing)
            spec = interactive_spec(item, target)
            result = run_item(spec; printing = true)
            say(item, target, 1, outcome(result))
            print_evidence(finish_here!(spec, result))
            return result.testset
        end
    end
end

# The ordinary interactive target, or `nothing`: a pasted item need not come from a
# package. `paste_target` handles package membership after `activate_mono`.
function interactive_target(path::Union{Nothing, AbstractString} = nothing)
    state = ACTIVATION[]
    combined = state !== nothing && state.target === nothing
    state === nothing || combined || return state.target
    return try
        combined ? (path === nothing || !isfile(path) ? nothing : target_from_dir(dirname(abspath(path)))) :
            resolve_target(())
    catch
        nothing
    end
end

# The package a pasted item from `path` runs as one of, and whether it runs as in a
# combined run. After `activate_mono`, the package that takes part whose directory
# holds the item's file, or the REPL's current directory for an item with no file;
# otherwise as `interactive_target`.
function paste_target(path::AbstractString)
    state = ACTIVATION[]
    (state === nothing || state.participants === nothing) && return interactive_target(path), false
    return member_target(state.participants, isfile(path) ? dirname(abspath(path)) : pwd()), true
end

# The package of `ps` whose directory holds `dir`, the innermost. None, or an isolated
# one, which a shared worker never runs, is an error that says what to do instead.
function member_target(ps::Participants, dir::AbstractString)
    real = realpath(dir)
    holds = [k for k in eachindex(ps.root) if within(real, ps.root[k])]
    isempty(holds) && throw(ConfigError(string(
        "after `Runtests.activate_mono()`, a test item runs as an item of the package whose directory holds its file, ",
        "or the REPL's current directory, and ", real, " is in none of ", join(ps.name, ", "),
        ": `cd` into the package's directory first, or `include` the item's file"
    )))
    k = holds[argmax([length(ps.root[h]) for h in holds])]
    ps.isolated[k] && throw(ConfigError(string(
        ps.name[k], " is isolated, and its items run in its own test environment: `Runtests.deactivate()`, then ",
        "`Runtests.activate(", repr(ps.root[k]), ")`"
    )))
    return target_from_dir(ps.root[k])
end

function warn_ignored(item::RawItem, sandboxed::Bool)
    given = String[]
    for (key, why) in repl_ignored(sandboxed)
        set = key === :timeout ? item.timeout_s != USE_RUN_DEFAULT :
            key === :retries ? item.retries != USE_RUN_DEFAULT :
            item.chain !== NO_CHAIN
        set && push!(given, string("`", key, "` (", why, ")"))
    end
    isempty(given) && return nothing
    # Once per item, not once per session: `maxlog` counts by message id.
    @warn "Runtests: running `$(item.name)` here, so these are ignored: " * join(given, ", ") maxlog = 1 _id = (:runtests_ignored, item.name)
    return nothing
end

# The run's environment for the length of one item. After `activate` the session is
# already in it, and `with_test_env` leaves it alone. `combined`: after `activate_mono`,
# the union environment with the shared setups, which is what a shared worker has. For
# a profile in an environment directory, `prof`, that environment over it, as its
# workers have it.
function with_interactive_env(f, target, prof::Union{Nothing, Profile} = nothing; combined::Bool = false)
    target === nothing && return f()
    combined && return in_profile_environment(f, target, prof)
    return with_test_env(target) do
        with_load_path(() -> in_profile_environment(f, target, prof), joinpath(target.testdir, TESTSETUPS_DIR))
    end
end

function in_profile_environment(f, target, prof::Union{Nothing, Profile})
    (prof === nothing || isempty(prof.environment)) && return f()
    project = profile_project(prof, Base.active_project(), target.root)
    current, load_path = Base.active_project(), copy(LOAD_PATH)
    Base.set_active_project(joinpath(project, "Project.toml"))
    copy!(LOAD_PATH, stacked_load_path(load_path, current))
    try
        return f()
    finally
        copy!(LOAD_PATH, load_path)
        Base.set_active_project(current)
    end
end

# An item's RUN or DONE line: one item, so no count, and a name column its own width.
say(item::RawItem, target, attempt, how) = (println(stdout, item_line(
    nothing, 1, 0, repr(item.name), quoted_width(item.name), attempt, 1, something(how, item_location(item, target))
)); flush(stdout))

# A pasted item's file may be `REPL[3]`, `none` or a notebook cell; only a real path
# is made relative.
item_location(item::RawItem, target) = string(
    isabspath(item.file) && target !== nothing ? relpath_or_path(item.file, target.root) : item.file, ":", item.line
)

# `prefix` is where its attempts keep their evidence (see `artifacts_path`), one for
# all of them. The item runs in its package's root, as in a run.
function interactive_spec(item::RawItem, target, attempt::Integer = 1, seed::UInt64 = rand(RandomDevice(), UInt64),
                          prefix::String = interactive_artifacts_prefix())
    project = target === nothing ? "" : something(project_name_of(target.project), "")
    return ItemSpec(
        Int32(1), item.name, item.file, item.line, item.code, item.skip, item.failfast == 1,
        project, item.profile, Int8(attempt), false, "", seed, artifacts_path(prefix, 1, attempt),
        target === nothing ? "" : target.root
    )
end

# A worker configured as a run would configure it, in the profile's own project
# when it declares preferences or runs in an environment directory.
function sandbox_worker(prof, target, redirect_fn)
    env = Base.active_project()
    project = something(profile_project(prof, env, target === nothing ? nothing : target.root), Some(env))
    return RuntestsWorkers.Worker(;
        julia_args = prof.julia_args, threads = prof.threads,
        extra_env = worker_env("repl", 1, project, prof),
        dir = target === nothing ? pwd() : target.root,
        project = env, redirect_io = stdout, redirect_fn
    )
end

function run_sandboxed(item::RawItem, target)
    prof = interactive_profile(item, target)
    # The limits a run holds the profile's own code to; without a project, a run's defaults.
    limits = target === nothing ? RunConfig(; workers = 0) : read_config(target.testdir)
    timeout = item.timeout_s == USE_RUN_DEFAULT ? nothing : Int(item.timeout_s)
    attempts = item.retries == USE_RUN_DEFAULT ? 1 : Int(item.retries) + 1
    result = nothing
    relay(io, pid, line) = let rec = parse_record(line)
        rec === nothing ? println(io, "      worker ", pid, " | ", line) : say(item, target, rec.attempt, rec.how)
    end
    # One seed for every attempt, as a run's retries draw the same numbers, and one
    # place for their evidence.
    seed = rand(RandomDevice(), UInt64)
    prefix = interactive_artifacts_prefix()
    for attempt in 1:attempts
        w = sandbox_worker(prof, target, relay)
        try
            isempty(prof.init.args) || fetch_within(
                RuntestsWorkers.remote_eval(w, Expr(:block, prof.init.args...)), limits.init_timeout_s,
                TimeoutException(limits.init_timeout_s, "the `init` expression of profile `$(prof.name)`", "", "init_timeout")
            )
            spec = interactive_spec(item, target, attempt, seed, prefix)
            fut = RuntestsWorkers.remote_run(w, spec)
            result = (
                timeout === nothing ? fetch(fut) :
                fetch_within(fut, timeout, TimeoutException(timeout, "test item", item.name, "its own timeout=$timeout"))
            )::ItemResult
            # What the profile's `test_end` records counts, as it does in a run.
            if !isempty(prof.test_end.args) && result.state !== SKIPPED
                endres = fetch_within(
                    RuntestsWorkers.remote_end(w, spec, prof.test_end), limits.test_end_timeout_s,
                    TimeoutException(limits.test_end_timeout_s, "the `test_end` expression of profile `$(prof.name)`", "", "test_end_timeout")
                )::ItemResult
                result = merge_test_end(result, endres)
            end
            print_evidence(finish_here!(spec, result; worker = w, limit = limits.artifacts_timeout_s))
            (!is_non_pass(result.state) || attempt == attempts) && break
        catch e
            e isa TimeoutException || rethrow()
            RuntestsWorkers.terminate!(w, :timeout)
            wait(w)
            # What the attempt wrote before it was stopped is kept, and said where.
            dir = artifacts_path(prefix, 1, attempt)
            isfile(artifacts_log_path(dir)) && note_evidence(dir, string("not collected: ", sprint(showerror, e),
                                                                         ", so the producers did not run"))
            (isdir(dir) || isfile(artifacts_log_path(dir))) && print_evidence(dir)
            attempt == attempts && rethrow()
        finally
            close(w)
        end
    end
    # Every attempt sets it or throws, and the last one never goes round again.
    result = result::ItemResult
    # In a run the coordinator prints results; here this process is the coordinator.
    print_interactive_result(result)
    return result
end

# The profile from the project's TestItems.toml, `default` included, as a run reads
# it, in the item's environment. Only a session without a project has the built-in
# default.
function interactive_profile(item::RawItem, target)
    if target === nothing
        item.profile === DEFAULT_PROFILE && return Profile(DEFAULT_PROFILE)
        throw(ConfigError("`profile = :$(item.profile)` needs a TestItems.toml, and there is no project here"))
    end
    cfg = read_config(target.testdir)
    haskey(cfg.profiles, item.profile) || throw(
        ConfigError(
            "`profile = :$(item.profile)` has no [profiles.$(item.profile)] in " *
                relpath_or_path(joinpath(target.testdir, "TestItems.toml"), target.root)
        )
    )
    return in_environment(run_profile(cfg.profiles[item.profile], cfg.threads), item.environment)
end

function print_interactive_result(result::ItemResult)
    for r in collect_failures(result.testset)
        show(stdout, r)
        println(stdout)
    end
    try
        Test.print_test_results(result.testset)
    catch
        # A `Test` that prints its summary some other way is not worth failing over.
        println(stdout, label_prefix(), short_state(result.state))
    end
    return nothing
end
