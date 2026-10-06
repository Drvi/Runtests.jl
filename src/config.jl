# Run configuration: `runtests` keywords over `test/TestItems.toml` over defaults.
#
# Nothing here is evaluated: `init` and `test_end` are only parsed, so a syntax
# error surfaces before any worker starts.

using TOML: TOML

"""
    Profile

Everything that makes two worker processes non-interchangeable. Items with the
same profile can share a worker; items with different profiles cannot.
"""
struct Profile
    name::Symbol
    julia_args::Vector{String}
    threads::String
    env::Vector{Pair{String, String}}
    init::Expr
    test_end::Expr
    # An absolute path to a preferences file, or empty. Preferences reach a package
    # from the environment that owns it, so this becomes the worker's own project
    # rather than anything layered on the test environment.
    preferences::String
    # An absolute path to a directory with an environment of its own, its workers'
    # in place of the test environment, or empty. Its tests run under this profile.
    environment::String
end

Profile(
    name::Symbol; julia_args = String[], threads = "2,1", env = Pair{String, String}[],
    init = Expr(:block), test_end = Expr(:block), preferences = "", environment = ""
) =
    Profile(name, julia_args, threads, env, init, test_end, preferences, environment)

Base.@kwdef struct RunConfig
    workers::Int
    threads::String = "2,1"
    timeout_s::Int = 30 * 60
    # The suite's code, not the item's, so limits of their own.
    init_timeout_s::Int = 30 * 60
    test_end_timeout_s::Int = 30 * 60
    retries::Int = 0
    failfast::Bool = false
    item_failfast::Bool = false
    logs::Symbol = :issues
    verbose::Bool = false
    memory_threshold::Float64 = 0.9
    full_stacktraces::Bool = false
    # Every name printed whole in the name column, rather than one too long for it
    # shortened to a prefix no other item has.
    full_names::Bool = false
    # What the run's testset is called in the summary; runs of several calls under
    # one `@testset` are told apart by it.
    testset_name::String = "Runtests"
    # Workers count which lines of the package's `src/` and `ext/` run, and the run
    # merges what they counted into `lcov.info` at the package's root.
    coverage::Bool = false
    # What set `coverage`, for the run to say, or empty for the default.
    coverage_source::String = ""
    monitor::Bool = true
    monitor_interval::Int = 30
    profiles::Dict{Symbol, Profile} = Dict(DEFAULT_PROFILE => Profile(DEFAULT_PROFILE))
    # The `[groups]` table, which a run has already selected by; kept for `chores`.
    groups::Dict{String, TagExpr} = Dict{String, TagExpr}()
    order_first::Vector{String} = String[]
    order_last::Vector{String} = String[]
    # Every item's random numbers start from this and its name, so a run with the
    # same seed draws the same numbers in each item, whatever ran before it.
    seed::UInt64 = 0
    # The manifest a replayed run state was recorded against, or empty: the run
    # says how its own environment differs.
    replayed_manifest::String = ""
    # The run state a replay runs, or empty for a run that is not one.
    replayed_from::String = ""
    # The file a call named to read in place of `test/TestItems.toml`, or empty.
    config_file::String = ""
end

const RUN_KEYS = (
    :workers, :threads, :timeout, :init_timeout, :test_end_timeout, :retries,
    :failfast, :item_failfast, :logs, :verbose, :memory_threshold,
    :monitor, :monitor_interval, :full_stacktraces, :full_names, :testset_name, :coverage, :seed,
)
# The keywords of `runtests` that are not run settings: what it selects, and what it
# does with the selection.
const CALL_KEYS = (:name, :tags, :group, :dry_run, :replay, :config)

# A keyword `runtests` does not take, with the nearest it does: a misspelled one would
# otherwise be the one setting a run quietly goes without.
function unknown_keyword(k::Symbol)
    # Keywords are short, and three edits turn `tag` into `name`: one in three letters.
    near = nearest(String(k), String[String(x) for x in (CALL_KEYS..., RUN_KEYS...)]; cutoff = max(1, length(String(k)) ÷ 3))
    return ArgumentError(string(
        "unknown keyword `", k, "`", isempty(near) ? "" : string(" (did you mean ", join(("`$n`" for n in near), " or "), "?)"),
        "; `runtests` selects with ", join(("`$x`" for x in CALL_KEYS[1:3]), ", "), ", takes ",
        join(("`$x`" for x in CALL_KEYS[4:end]), ", "), ", and the run settings ", join(("`$x`" for x in RUN_KEYS), ", ")
    ))
end

const ORDER_KEYS = (:first, :last)
const PROFILE_KEYS = (:julia_args, :threads, :env, :init, :test_end, :preferences, :environment)
const TOP_KEYS = (:run, :order, :profiles, :groups)
const LOG_MODES = (:eager, :batched, :issues)

# The group a run selects when nothing else selects, the whole suite unless declared,
# and the name of the whole suite, which no `[groups]` entry may take.
const DEFAULT_GROUP = "default"
const ALL_GROUP = "all"

"""
    read_config(testdir; config = nothing, kwargs...) -> RunConfig

Merge `test/TestItems.toml` with explicit keyword arguments. An unknown key is an
error, not a no-op: a misspelled option would otherwise be ignored in silence.
`config` names another file to read in its place, relative to the current
directory; named, it has to exist, where `test/TestItems.toml` may be absent.
"""
function read_config(testdir::AbstractString; config::Union{Nothing, AbstractString} = nothing, kwargs...)
    path, toml = config_toml(testdir, config)
    return build_config(path, toml; config_file = config === nothing ? "" : path, kwargs...)
end

"""
    config_toml(testdir, config) -> (path, toml)

The config file a run reads, `test/TestItems.toml` or the file `config` names, and
what it holds: an empty table for a `TestItems.toml` that is not there.
"""
function config_toml(testdir::AbstractString, config::Union{Nothing, AbstractString})
    path = config === nothing ? joinpath(testdir, "TestItems.toml") : abspath(config)
    config === nothing || isfile(path) ||
        throw(ConfigError("the config file $(relpath_or_path(path)) does not exist"))
    isfile(path) || return path, Dict{String, Any}()
    toml = try
        TOML.parsefile(path)
    catch e
        throw(ConfigError("could not parse $(relpath_or_path(path)): $(sprint(showerror, e))"))
    end
    check_keys(path, toml, TOP_KEYS, "")
    return path, toml
end

function check_keys(path, tbl::AbstractDict, allowed::Tuple, where_)
    for k in sort!(collect(keys(tbl)))
        Symbol(k) in allowed && continue
        loc = isempty(where_) ? "" : " in [$where_]"
        throw(
            ConfigError(
                "unknown key `$k`$loc of $(relpath_or_path(path)); " *
                    "allowed here: $(join(allowed, ", "))"
            )
        )
    end
    return
end

# A table of the configuration, holding only the keys it may hold. `label` is how
# a message names it.
function section(path, parent::AbstractDict, key::AbstractString, allowed::Tuple, label = key)
    t = get(Dict{String, Any}, parent, key)
    t isa AbstractDict || throw(ConfigError("[$label] of $(relpath_or_path(path)) must be a table"))
    check_keys(path, t, allowed, label)
    return t
end

# `key` of the table labelled `label`, a list of strings, empty when absent. A string on
# its own is refused rather than read as the list of its characters: `key = "a"` for
# `key = ["a"]` is the likeliest slip.
function string_list(path, table::AbstractDict, key::AbstractString, label::AbstractString)
    v = get(Vector{String}, table, key)
    (v isa AbstractVector && all(x -> x isa AbstractString, v)) || throw(ConfigError(
        "`$key` of [$label] in $(relpath_or_path(path)) must be a list of strings, as in " *
            "`$key = [\"…\"]`, got $(repr(v))"
    ))
    return String[x for x in v]
end

# `key` of the table labelled `label`, a string, empty when absent.
function string_setting(path, table::AbstractDict, key::AbstractString, label::AbstractString)
    v = get(table, key, "")
    v isa AbstractString ||
        throw(ConfigError("`$key` of [$label] in $(relpath_or_path(path)) must be a string, got $(repr(v))"))
    return String(v)
end

# `true` or `false` from an environment variable, or `nothing` when it is unset or empty.
function env_flag(name::AbstractString)
    v = lowercase(strip(get(ENV, name, "")))
    isempty(v) && return nothing
    v in ("1", "true", "yes") && return true
    v in ("0", "false", "no") && return false
    throw(ConfigError("`$name` must be true or false (or 1, 0, yes, no), got $(repr(ENV[name]))"))
end

function build_config(path, toml; nunits = 0, config_file::AbstractString = "", kwargs...)
    for k in keys(kwargs)
        k in RUN_KEYS || throw(unknown_keyword(k))
    end
    # A value the call gave is the call's mistake; one from the file or the
    # environment is the configuration's.
    given(keys...) = any(k -> get(kwargs, k, nothing) !== nothing, keys)
    bad(msg, keys...) = given(keys...) ? ArgumentError(msg) : ConfigError(msg)
    run = section(path, toml, "run", RUN_KEYS)
    # A keyword wins over the file, and the file over the default.
    pick(key, default) = something(get(kwargs, key, nothing), get(run, string(key), default))
    seconds(key, x) = (is_number(x) && 0 < x <= MAX_TIMEOUT_S) ? Int(ceil(x)) :
        throw(bad("`$key` must be a positive number of seconds, at most $MAX_TIMEOUT_S, got $(repr(x))", key))
    # 0 prints at every sample, five times a second: a test's way to make the
    # monitor print as often as it can.
    interval(x) = (is_number(x) && 0 <= x <= MAX_TIMEOUT_S) ? Int(ceil(x)) :
        throw(bad("`monitor_interval` must be a number of seconds from 0 to $MAX_TIMEOUT_S, got $(repr(x))", :monitor_interval))
    flag(key, default) = (v = pick(key, default); v isa Bool ? v :
        throw(bad("`$key` must be true or false, got $(repr(v))", key)))

    threads = threads_spec("threads", pick(:threads, "2,1"), given(:threads) ? ArgumentError : ConfigError)
    w = pick(:workers, "auto")
    # A worker is a slot, and slots are numbered in a `SlotIdx`.
    ((is_whole_number(w) && 0 <= w <= typemax(SlotIdx)) || w == "auto") || throw(bad(
        "`workers` must be \"auto\" or an integer from 0 to $(typemax(SlotIdx)), got $(repr(w))", :workers
    ))
    workers = w isa Integer ? Int(w) : auto_workers(threads, nunits)
    logs = Symbol(pick(:logs, default_logs(workers)))::Symbol
    logs in LOG_MODES || throw(bad("`logs` must be one of $(LOG_MODES), got $(repr(logs))", :logs))
    timeout = seconds(:timeout, pick(:timeout, 30 * 60))
    retries = pick(:retries, 0)
    (is_whole_number(retries) && 0 <= retries <= MAX_RETRIES) ||
        throw(bad("`retries` must be an integer from 0 to $MAX_RETRIES, got $(repr(retries))", :retries))
    mt = pick(:memory_threshold, 0.9)
    (is_number(mt) && 0 < mt <= 1) || throw(bad("`memory_threshold` must be in (0, 1], got $(repr(mt))", :memory_threshold))
    failfast = flag(:failfast, false)
    seed = pick(:seed, 0)
    (is_whole_number(seed) && 0 <= seed <= typemax(UInt64)) ||
        throw(bad("`seed` must be an integer from 0 to $(typemax(UInt64)), got $(repr(seed))", :seed))
    order = section(path, toml, "order", ORDER_KEYS)
    # A keyword, then the environment, then the file: CI switches coverage on for a
    # job without editing the project. The environment is read only when the keyword
    # does not decide, so a bad value there fails only a run it would have set.
    coverage, coverage_source = if get(kwargs, :coverage, nothing) !== nothing
        (kwargs[:coverage], "the `coverage` keyword")
    else
        env_coverage = env_flag("RUNTESTS_COVERAGE")
        env_coverage !== nothing ? (env_coverage, "`RUNTESTS_COVERAGE`") :
            haskey(run, "coverage") ? (run["coverage"], relpath_or_path(path)) : (false, "")
    end
    coverage isa Bool || throw(bad("`coverage` must be true or false, got $(repr(coverage))", :coverage))
    coverage && workers == 0 && throw((given(:coverage, :workers) ? ArgumentError : ConfigError)(
        "`coverage` is counted by worker processes, and `workers = 0` runs the items in this one, " *
            "whose coverage was fixed when it started; use one worker or more"
    ))
    testset_name = pick(:testset_name, "Runtests")
    (testset_name isa AbstractString && !isempty(testset_name)) ||
        throw(bad("`testset_name` must be a non-empty string, got $(repr(testset_name))", :testset_name))

    return RunConfig(;
        workers, threads, timeout_s = timeout,
        init_timeout_s = seconds(:init_timeout, pick(:init_timeout, timeout)),
        test_end_timeout_s = seconds(:test_end_timeout, pick(:test_end_timeout, timeout)),
        retries = Int(retries), failfast, item_failfast = flag(:item_failfast, failfast), logs,
        verbose = flag(:verbose, false),
        memory_threshold = Float64(mt), monitor = flag(:monitor, true),
        full_stacktraces = flag(:full_stacktraces, false),
        full_names = flag(:full_names, false),
        testset_name = String(testset_name), coverage, coverage_source,
        monitor_interval = interval(pick(:monitor_interval, 30)),
        profiles = read_profiles(path, toml, threads),
        groups = read_groups(path, toml),
        order_first = string_list(path, order, "first", "order"),
        order_last = string_list(path, order, "last", "order"),
        seed = seed == 0 ? rand(RandomDevice(), UInt64) : UInt64(seed),
        config_file = String(config_file)
    )
end

# What `--threads` takes: default threads, `auto` or at least one, then optionally
# interactive ones, `auto` or any number. Checked here, or the first worker dies of it.
function threads_spec(what, x, err = ConfigError)
    s = x isa Integer ? string(x) : x
    (s isa AbstractString && occursin(r"^(auto|[1-9][0-9]*)(,(auto|[0-9]+))?$", s)) || throw(err(
        "`$what` must be what `--threads` takes (\"4\", \"4,1\", \"auto\"), got $(repr(x))"
    ))
    return String(s)
end

# One interactive worker streams its logs; several would interleave unreadably, so
# only items with problems print, as in a non-interactive run. `interactive` is a
# parameter so that a test suite, which is never interactive, can check both.
default_logs(workers::Integer, interactive::Bool = isinteractive()) =
    interactive && workers <= 1 ? :eager : :issues

function read_profiles(path, toml, default_threads::String)
    profiles = Dict{Symbol, Profile}()
    tbl = get(Dict{String, Any}, toml, "profiles")
    tbl isa AbstractDict || throw(ConfigError("[profiles] of $(relpath_or_path(path)) must be a table"))
    # Numbered in a `ProfileIdx`, `default` among them.
    length(tbl) < typemax(ProfileIdx) ||
        throw(ConfigError("$(relpath_or_path(path)) declares $(length(tbl)) profiles; at most $(typemax(ProfileIdx) - 1) fit"))
    for name in keys(tbl)
        label = "profiles.$name"
        p = section(path, tbl, name, PROFILE_KEYS, label)
        args = string_list(path, p, "julia_args", label)
        vars = get(Dict{String, Any}, p, "env")
        (vars isa AbstractDict && all(v -> v isa Union{AbstractString, Real}, values(vars))) || throw(ConfigError(
            "`env` of [$label] in $(relpath_or_path(path)) must be a table of variables, as in " *
                "`env = { NAME = \"value\" }`, got $(repr(vars))"
        ))
        env = Pair{String, String}[string(k) => string(v) for (k, v) in vars]
        sort!(env; by = first)
        profiles[Symbol(name)] = Profile(
            Symbol(name), args,
            threads_spec("threads of [$label]", get(p, "threads", default_threads)), env,
            parse_expr(path, name, "init", string_setting(path, p, "init", label)),
            parse_expr(path, name, "test_end", string_setting(path, p, "test_end", label)),
            profile_preferences(path, name, get(p, "preferences", "")),
            profile_environment(path, name, get(p, "environment", ""))
        )
    end
    check_environment_owners(path, Pair{Symbol, String}[n => p.environment for (n, p) in profiles if !isempty(p.environment)])
    haskey(profiles, DEFAULT_PROFILE) ||
        (profiles[DEFAULT_PROFILE] = Profile(DEFAULT_PROFILE; threads = default_threads))
    return profiles
end

"""
    profile_environment(config_path, name, value) -> String

The absolute path to the directory a profile names as its `environment`, or `""`
when it names none. Relative to the directory of the config file, as `preferences`
is, and checked here, before any worker starts: a directory holding a `Project.toml`
or a `JuliaProject.toml`.
"""
function profile_environment(config_path, name, value)
    bad(what) = ConfigError("`environment` of [profiles.$name] in $(relpath_or_path(config_path))" * what)
    value isa AbstractString ||
        throw(bad(" must be the path of a directory with a Project.toml, as in `environment = \"qa\"`, got $(repr(value))"))
    isempty(value) && return ""
    dir = rstrip_path(normpath(isabspath(value) ? value : joinpath(dirname(config_path), value)))
    isdir(dir) || throw(bad(" names $(relpath_or_path(dir)), which is not a directory"))
    any(n -> isfile(joinpath(dir, n)), PROJECT_NAMES) ||
        throw(bad(" names $(relpath_or_path(dir)), which has no Project.toml: an environment is a directory with one"))
    return dir
end

# Which profile an item in an environment's directory runs under has one answer: a
# directory is one profile's environment, and the default profile runs in the test
# environment.
function check_environment_owners(path, owners::Vector{Pair{Symbol, String}})
    seen = Dict{String, Symbol}()
    for (name, dir) in sort(owners; by = first)
        name === DEFAULT_PROFILE && throw(ConfigError(
            "`environment` of [profiles.$name] in $(relpath_or_path(path)): the default profile's workers run in " *
                "the test environment; give $(relpath_or_path(dir)) a profile of its own"
        ))
        other = get(seen, dir, nothing)
        other === nothing || throw(ConfigError(
            "$(relpath_or_path(dir)) is the `environment` of both [profiles.$other] and [profiles.$name] in " *
                "$(relpath_or_path(path)), and the items in it can run under one profile only"
        ))
        seen[dir] = name
    end
    return nothing
end

"""
    claimed_environments(path, toml) -> Dict{String, Symbol}

Every directory a profile of the config file names as its `environment`, with that
profile: what reading the test directory needs to know before the rest of the
settings are read. Checked as [`read_config`](@ref) checks it.
"""
function claimed_environments(path, toml)
    claimed = Dict{String, Symbol}()
    tbl = get(Dict{String, Any}, toml, "profiles")
    tbl isa AbstractDict || return claimed   # `read_config` says what is wrong with it
    owners = Pair{Symbol, String}[]
    for (name, p) in tbl
        p isa AbstractDict || continue
        dir = profile_environment(path, name, get(p, "environment", ""))
        isempty(dir) || push!(owners, Symbol(name) => dir)
    end
    check_environment_owners(path, owners)
    for (name, dir) in owners
        claimed[dir] = name
    end
    return claimed
end

"""
    read_groups(path, toml) -> Dict{String, TagExpr}

The `[groups]` table: names for tag expressions, each written as a string as `tags`
takes one, which a run selects by with the `group` keyword or `RUNTESTS_GROUP`. Two
names are reserved: `$DEFAULT_GROUP` is what a run selects when nothing else selects,
the whole suite unless declared here, and `$ALL_GROUP` is the whole suite, and is not
declared. A name that differs from either only in case is an error.
"""
function read_groups(path, toml)
    tbl = get(Dict{String, Any}, toml, "groups")
    tbl isa AbstractDict || throw(ConfigError("[groups] of $(relpath_or_path(path)) must be a table"))
    groups = Dict{String, TagExpr}()
    for (name, value) in tbl
        what = "group `$name` of [groups] in $(relpath_or_path(path))"
        name == ALL_GROUP && throw(ConfigError("$what: `$ALL_GROUP` is the whole suite, and is not declared"))
        # Told apart by case alone, `All` and `all` would select different items.
        reserved = lowercase(name)
        reserved in (ALL_GROUP, DEFAULT_GROUP) && name != DEFAULT_GROUP && throw(ConfigError(string(
            what, ": `", reserved, "` is reserved, and this differs from it only in case; ",
            reserved == ALL_GROUP ? "`all` is the whole suite, and is not declared" :
                "declare the group a run selects by default as `default`"
        )))
        value isa AbstractString || throw(ConfigError(
            "$what must be a tag expression written as a string, as in `$name = \"fast && !slow\"`, got $(repr(value))"
        ))
        groups[name] = try
            parse_tag_expr(value; what)
        catch e
            e isa ArgumentError || rethrow()
            throw(ConfigError(e.msg))
        end
    end
    return groups
end

"""
    select_group(groups, path, requested, selected) -> Union{Nothing, GroupSelection}

The group a run selects by: the `group` keyword, `requested`; else, for a run that
selects nothing else (`selected` false), the group `RUNTESTS_GROUP` names, else
`$DEFAULT_GROUP`. `nothing` for the whole suite: `$ALL_GROUP`, and `$DEFAULT_GROUP`
when `[groups]` of the config file `path` does not declare it. A name `[groups]` does
not declare is an error that says the nearest it does: an `ArgumentError` from the
keyword, a `ConfigError` from the environment.
"""
function select_group(groups::Dict{String, TagExpr}, path::AbstractString, requested, selected::Bool)
    if requested !== nothing
        (requested isa Union{AbstractString, Symbol} && !isempty(string(requested))) || throw(ArgumentError(
            "`group = $(repr(requested))`: expected the name of a group of [groups], \"$ALL_GROUP\" or \"$DEFAULT_GROUP\""
        ))
        name, asker = String(string(requested)), "the `group` keyword"
    else
        # Like the default, the environment's group is what a run selects when the
        # call selects nothing: a name or a line asked for runs whatever group it is in.
        selected && return nothing
        env = strip(get(ENV, "RUNTESTS_GROUP", ""))
        name, asker = isempty(env) ? (DEFAULT_GROUP, "") : (String(env), "`RUNTESTS_GROUP`")
    end
    name == ALL_GROUP && return nothing
    haskey(groups, name) &&
        return GroupSelection(name, groups[name], isempty(asker) ? "the default" : string("from ", asker), path)
    name == DEFAULT_GROUP && return nothing
    file = relpath_or_path(path)
    declared = sort!(collect(keys(groups)))
    near = near_group_names(name, [declared; ALL_GROUP; haskey(groups, DEFAULT_GROUP) ? String[] : [DEFAULT_GROUP]])
    hint = isempty(near) ? "" : string(" (did you mean ", join(("`$g`" for g in near), " or "), "?)")
    msg = isempty(groups) ? string(asker, " asks for group `", name, "`, and ", file, " declares no [groups]", hint) :
        string(asker, " asks for group `", name, "`, which [groups] of ", file, " does not declare", hint,
               "; it declares ", join(("`$g`" for g in declared), ", "), ", and `$ALL_GROUP` is the whole suite")
    throw(requested !== nothing ? ArgumentError(msg) : ConfigError(msg))
end

# The names among `candidates` that `name` most likely meant, without regard to case:
# one that differs only in case first, else the nearest by spelling.
function near_group_names(name::AbstractString, candidates::Vector{String})
    low = lowercase(name)
    same = [c for c in candidates if lowercase(c) == low]
    isempty(same) || return same
    lows = lowercase.(candidates)
    # Group names are short: one edit in three letters, or `gpu` would suggest `all`.
    return [candidates[findfirst(==(n), lows)] for n in nearest(low, lows; cutoff = max(1, length(low) ÷ 3))]
end

"""
    profile_preferences(config_path, name, value) -> String

The absolute path to a profile's preferences file, or `""` when it declares none.
Parsed here, so a missing or malformed file fails before any worker starts.
"""
function profile_preferences(config_path, name, value)
    bad(what) = ConfigError("`preferences` of [profiles.$name]" * what)
    value isa AbstractString || throw(bad(" must be a path to a TOML file"))
    isempty(value) && return ""
    path = isabspath(value) ? value : normpath(joinpath(dirname(config_path), value))
    isfile(path) || throw(bad(" points at $(relpath_or_path(path)), which does not exist"))
    try
        TOML.parsefile(path)
    catch e
        throw(bad(": could not parse $(relpath_or_path(path)): $(sprint(showerror, e))"))
    end
    return path
end

function parse_expr(path, profile, key, str::AbstractString)
    isempty(strip(str)) && return Expr(:block)
    bad(what) = ConfigError("could not parse `$key` of [profiles.$profile] in $(relpath_or_path(path)): $what")
    ex = try
        Meta.parseall(str; filename = "$(relpath_or_path(path)):[profiles.$profile].$key")
    catch e
        throw(bad(sprint(showerror, e)))
    end
    # `parseall` reports a bad parse as an `:error`/`:incomplete` node rather than
    # by throwing, so an unchecked result would defer the failure to the worker.
    for a in ex.args
        a isa Expr && a.head in (:error, :incomplete) && throw(bad(a.args[1]))
    end
    return Expr(:block, ex.args...)
end

# A guess, not a measurement: too many workers is an OOM kill, and each extra one
# compiles the same code again.
const ASSUMED_WORKER_RSS = 4 * 2^30

function auto_workers(threads::String, nunits::Int)
    per_worker = something(tryparse(Int, first(split(threads, ','))), 2)
    # The CPUs this process may use: fewer than the machine's under a container
    # quota, and oversubscribing them turns timeouts flaky. 1.12 has only the
    # machine's count.
    cpus = @static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS
    by_cpu = max(1, cpus ÷ max(1, per_worker))
    by_mem = max(1, Int(Sys.total_memory() ÷ ASSUMED_WORKER_RSS))
    n = clamp(min(by_cpu, by_mem), 1, 8)
    return nunits > 0 ? min(n, nunits) : n
end
