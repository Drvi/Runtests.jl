# Run configuration: `runtests` keywords over `test/TestItems.toml` over defaults.
#
# Nothing here is evaluated: `init` and `test_end` are only parsed, so a syntax
# error surfaces before any worker starts.

using TOML: TOML

"""
    Profile

A named worker configuration: startup flags, threads, environment, preferences and
`init`, plus the `test_end` run after each item. Different profiles can share a
worker when their startup configuration and `init` directory agree; `test_end` does
not split pools (see `pool_key`).
"""
struct Profile
    name::Symbol
    julia_args::Vector{String}
    # The workers' `--threads`; empty when the profile sets none and takes the run's,
    # which `run_profile` fills in. A run state records it as it was set.
    threads::String
    env::Vector{Pair{String, String}}
    init::Expr
    test_end::Expr
    # An absolute path to a preferences file, or empty. Preferences reach a package
    # from the environment that owns it, so this becomes the worker's own project
    # rather than anything layered on the test environment.
    preferences::String
    # An absolute path to the directory whose environment the workers run in, in
    # place of the test environment, or empty. Never declared: a plan gives each pool
    # the environment of its items' directory (see `in_environment`).
    environment::String
    # The absolute path of the directory its `init` runs in: the workspace root for a
    # profile that a workspace shares with its packages (see `SharedProfiles`), or
    # empty for the root of the package whose configuration holds it.
    dir::String
    # The packages the run precompiles for its workers before they start, with their
    # dependencies: `nothing` for the whole environment of its items. A worker compiles
    # any other package as an item loads it. Not part of the start configuration, and
    # not in a run state: it changes when packages compile, not how a worker starts.
    precompile::Union{Nothing, Vector{String}}
end

const DEFAULT_THREADS = "2,1"
const DEFAULT_TIMEOUT_S = 30 * 60

Profile(
    name::Symbol; julia_args = String[], threads = DEFAULT_THREADS, env = Pair{String, String}[],
    init = Expr(:block), test_end = Expr(:block), preferences = "", environment = "", dir = "", precompile = nothing
) =
    Profile(name, julia_args, threads, env, init, test_end, preferences, environment, dir, precompile)

# A copy of `p` with selected fields replaced.
with_profile(
    p::Profile;
    name = p.name, julia_args = p.julia_args, threads = p.threads, env = p.env,
    init = p.init, test_end = p.test_end, preferences = p.preferences,
    environment = p.environment, dir = p.dir, precompile = p.precompile
) = Profile(name, julia_args, threads, env, init, test_end, preferences, environment, dir, precompile)

"""
    SharedProfiles

The profiles a workspace shares with its packages: those that the `test/TestItems.toml`
of the workspace root marks `monorepo_default = true`, by name, each with the workspace
root as the directory its `init` runs in. `path` is that file, empty for a package in
no workspace. A package takes a shared profile that it does not declare, and one that
it declares with the same `init` and `test_end`, as code, runs its `init` where the
shared one does. Their workers can share a pool when the other startup settings
agree (`share_profiles!` and `pool_key`).
"""
struct SharedProfiles
    path::String
    profiles::Dict{Symbol, Profile}
end

const NO_SHARED_PROFILES = SharedProfiles("", Dict{Symbol, Profile}())

# A `[throttle]` entry: at most `limit` items of the throttle run at once; when `warmup`
# is true, one non-skipped item runs to completion alone first before opening to `limit`.
struct Throttle
    limit::Int
    warmup::Bool
end
Throttle(limit::Integer) = Throttle(Int(limit), false)

const DEFAULT_THROTTLE = Throttle(1, false)
const THROTTLE_KEYS = (:limit, :warmup)

Base.@kwdef struct RunConfig
    workers::Int
    threads::String = DEFAULT_THREADS
    timeout_s::Int = DEFAULT_TIMEOUT_S
    # The suite's code, not the item's, so limits of their own.
    init_timeout_s::Int = DEFAULT_TIMEOUT_S
    test_end_timeout_s::Int = DEFAULT_TIMEOUT_S
    # All the producers of one failed attempt together (see `Runtests.on_failure`).
    artifacts_timeout_s::Int = DEFAULT_TIMEOUT_S
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
    # The `RUNTESTS_<KEY>` variables that set something, with their values, for the
    # run to say: nothing else in the project shows them.
    env_settings::Vector{Pair{String, String}} = Pair{String, String}[]
    monitor::Bool = true
    monitor_interval::Int = 30
    profiles::Dict{Symbol, Profile} = Dict(DEFAULT_PROFILE => Profile(DEFAULT_PROFILE))
    # The `[groups]` table, which a run has already selected by; kept for `chores`.
    groups::Dict{String, TagExpr} = Dict{String, TagExpr}()
    order_first::Vector{String} = String[]
    order_last::Vector{String} = String[]
    # The `[throttle]` table: how many items of each throttle may run at once, and
    # whether one item warms up alone first. A throttle it does not name has limit 1
    # and `warmup = false`.
    throttle::Dict{Symbol, Throttle} = Dict{Symbol, Throttle}()
    # Every item's random numbers start from this and its name, so a run with the
    # same seed draws the same numbers in each item, whatever ran before it.
    seed::UInt64 = 0
    # Items that draw from a seed of their own rather than `seed`: the failures
    # `runtestsf` runs again, each with the seed it failed with.
    item_seeds::Dict{String, UInt64} = Dict{String, UInt64}()
    # The flags that change compiled code (see `code_flags`) the workers run with when
    # they are not this process's: a replay's, as its run state recorded them. Empty
    # for this process's own, which the workers inherit.
    julia_flags::Vector{String} = String[]
    # The manifest a replayed run state was recorded against, or empty: the run
    # says how its own environment differs.
    replayed_manifest::String = ""
    # The run state a replay runs, or empty for a run that is not one.
    replayed_from::String = ""
    # The file a call named to read in place of `test/TestItems.toml`, or empty.
    config_file::String = ""
    # The environment directories the run does not build, each as its path from the
    # root of the repository (`naming_root`): the run records their items as skipped
    # itself. From the call or `RUNTESTS_SKIP_ENVIRONMENT` only, never from a file.
    skip_environment::Vector{String} = String[]
end

# A copy of `cfg` with selected fields replaced. Explicit typed keywords avoid
# constructing a dynamic `NamedTuple` and compiling `RunConfig(::Any, ...)`.
with_config(
    cfg::RunConfig;
    workers::Int = cfg.workers,
    threads::String = cfg.threads,
    timeout_s::Int = cfg.timeout_s,
    init_timeout_s::Int = cfg.init_timeout_s,
    test_end_timeout_s::Int = cfg.test_end_timeout_s,
    artifacts_timeout_s::Int = cfg.artifacts_timeout_s,
    retries::Int = cfg.retries,
    failfast::Bool = cfg.failfast,
    item_failfast::Bool = cfg.item_failfast,
    logs::Symbol = cfg.logs,
    verbose::Bool = cfg.verbose,
    memory_threshold::Float64 = cfg.memory_threshold,
    full_stacktraces::Bool = cfg.full_stacktraces,
    full_names::Bool = cfg.full_names,
    testset_name::String = cfg.testset_name,
    coverage::Bool = cfg.coverage,
    coverage_source::String = cfg.coverage_source,
    env_settings::Vector{Pair{String, String}} = cfg.env_settings,
    monitor::Bool = cfg.monitor,
    monitor_interval::Int = cfg.monitor_interval,
    profiles::Dict{Symbol, Profile} = cfg.profiles,
    groups::Dict{String, TagExpr} = cfg.groups,
    order_first::Vector{String} = cfg.order_first,
    order_last::Vector{String} = cfg.order_last,
    throttle::Dict{Symbol, Throttle} = cfg.throttle,
    seed::UInt64 = cfg.seed,
    item_seeds::Dict{String, UInt64} = cfg.item_seeds,
    julia_flags::Vector{String} = cfg.julia_flags,
    replayed_manifest::String = cfg.replayed_manifest,
    replayed_from::String = cfg.replayed_from,
    config_file::String = cfg.config_file,
    skip_environment::Vector{String} = cfg.skip_environment,
) = RunConfig(
    workers, threads, timeout_s, init_timeout_s, test_end_timeout_s, artifacts_timeout_s,
    retries, failfast, item_failfast, logs, verbose, memory_threshold, full_stacktraces,
    full_names, testset_name, coverage, coverage_source, env_settings, monitor,
    monitor_interval, profiles, groups, order_first, order_last, throttle, seed,
    item_seeds, julia_flags, replayed_manifest, replayed_from, config_file, skip_environment,
)

# Declarative table of the 20 run settings. Each is a keyword, a `RUNTESTS_<KEY>`
# variable, and a key of `[run]` (except `skip_environment`, which `[run]` refuses).
#   kind:   :flag | :text | :workers | :skip_env | :number
#   scope:  :run (run-wide in monorepo) | :pkg (per-package in monorepo)
#   replay: :none | :int | :float | :bool | :symbol | :string | :uint64 | :csv
const SETTING_SPECS = (
    (key = :workers,           field = :workers,             kind = :workers,  scope = :run, replay = :int),
    (key = :threads,           field = :threads,             kind = :text,     scope = :pkg, replay = :string),
    (key = :timeout,           field = :timeout_s,           kind = :number,   scope = :pkg, replay = :int),
    (key = :init_timeout,      field = :init_timeout_s,      kind = :number,   scope = :pkg, replay = :int),
    (key = :test_end_timeout,  field = :test_end_timeout_s,  kind = :number,   scope = :pkg, replay = :int),
    (key = :artifacts_timeout, field = :artifacts_timeout_s, kind = :number,   scope = :pkg, replay = :int),
    (key = :retries,           field = :retries,             kind = :number,   scope = :pkg, replay = :int),
    (key = :failfast,          field = :failfast,            kind = :flag,     scope = :run, replay = :bool),
    (key = :item_failfast,     field = :item_failfast,       kind = :flag,     scope = :pkg, replay = :bool),
    (key = :logs,              field = :logs,                kind = :text,     scope = :run, replay = :symbol),
    (key = :verbose,           field = :verbose,             kind = :flag,     scope = :run, replay = :none),
    (key = :memory_threshold,  field = :memory_threshold,    kind = :number,   scope = :run, replay = :float),
    (key = :monitor,           field = :monitor,             kind = :flag,     scope = :run, replay = :none),
    (key = :monitor_interval,  field = :monitor_interval,    kind = :number,   scope = :run, replay = :none),
    (key = :full_stacktraces,  field = :full_stacktraces,    kind = :flag,     scope = :run, replay = :none),
    (key = :full_names,        field = :full_names,          kind = :flag,     scope = :run, replay = :none),
    (key = :testset_name,      field = :testset_name,        kind = :text,     scope = :run, replay = :none),
    (key = :coverage,          field = :coverage,            kind = :flag,     scope = :run, replay = :none),
    (key = :seed,              field = :seed,                kind = :number,   scope = :run, replay = :uint64),
    (key = :skip_environment,  field = :skip_environment,    kind = :skip_env, scope = :pkg, replay = :csv),
)

const RUN_KEYS = map(s -> s.key, SETTING_SPECS)
const FLAG_SETTINGS = Tuple(s.key for s in SETTING_SPECS if s.kind === :flag)
const TEXT_SETTINGS = Tuple(s.key for s in SETTING_SPECS if s.kind === :text)
const RUN_WIDE_KEYS = Tuple(s.key for s in SETTING_SPECS if s.scope === :run)
const PACKAGE_KEYS = Tuple(s.key for s in SETTING_SPECS if s.scope === :pkg)
const REPLAY_SPECS = Tuple((key = s.key, field = s.field, replay = s.replay) for s in SETTING_SPECS if s.replay !== :none)

# Parse a recorded meta string for a replayed setting.
function parse_replay_setting(kind::Symbol, s::AbstractString)
    kind === :int    && return parse(Int, s)
    kind === :float  && return parse(Float64, s)
    kind === :bool   && return parse(Bool, s)
    kind === :symbol && return Symbol(s)
    kind === :string && return String(s)
    kind === :uint64 && return parse(UInt64, s)
    kind === :csv    && return String[n for n in split(s, ',')]
    error("unknown replay kind: $kind")
end
# The keywords of `runtests` that are not run settings: what it selects, and what it
# does with the selection.
const CALL_KEYS = (:name, :tags, :group, :dry_run, :replay, :config, :on_event, :worker_init, :test_end)
const MONO_CALL_KEYS = (:packages, :name, :tags, :group, :dry_run, :replay, :on_event, :worker_init, :test_end)

# A keyword `runtests` / `runtests_mono` does not take, with the nearest it does: a
# misspelled one would otherwise be the one setting a run quietly goes without.
function unknown_keyword(k::Symbol; mono::Bool = false, prefix::AbstractString = "")
    call_keys = mono ? MONO_CALL_KEYS : CALL_KEYS
    caller = mono ? "runtests_mono" : "runtests"
    sel_end = mono ? 4 : 3
    candidates = String[String(x) for x in call_keys]
    for x in RUN_KEYS
        push!(candidates, String(x))
    end
    # Keywords are short, and three edits turn `tag` into `name`: one in three letters.
    near = nearest(String(k), candidates; cutoff = max(1, length(String(k)) ÷ 3))
    return ArgumentError(string(
        prefix, "unknown keyword `", k, "`",
        isempty(near) ? "" : string(" (did you mean ", join(("`$n`" for n in near), " or "), "?)"),
        "; `", caller, "` selects with ", join(("`$x`" for x in call_keys[1:sel_end]), ", "), ", takes ",
        join(("`$x`" for x in call_keys[(sel_end + 1):end]), ", "), ", and the run settings ",
        join(("`$x`" for x in RUN_KEYS), ", ")
    ))
end

# Pure (no-I/O) validation of one run setting keyword value given directly by a caller.
# `nothing` means unset (fall through to env / TOML / default), matching `pick_run_setting`.
function validate_run_setting(k::Symbol, @nospecialize(v); prefix::AbstractString = "")
    v === nothing && return nothing
    if k === :workers
        ((is_whole_number(v) && 0 <= v <= typemax(SlotIdx)) || (v isa AbstractString && v == "auto")) || throw(ArgumentError(string(
            prefix, "`workers` must be \"auto\" or an integer from 0 to ", typemax(SlotIdx), ", got ", repr(v)
        )))
    elseif k === :threads
        threads_spec("threads", v, msg -> ArgumentError(string(prefix, msg)))
    elseif k === :timeout || k === :init_timeout || k === :test_end_timeout || k === :artifacts_timeout
        (is_number(v) && 0 < v <= MAX_TIMEOUT_S) || throw(ArgumentError(string(
            prefix, "`", k, "` must be a positive number of seconds, at most ", MAX_TIMEOUT_S, ", got ", repr(v)
        )))
    elseif k === :monitor_interval
        (is_number(v) && 0 <= v <= MAX_TIMEOUT_S) || throw(ArgumentError(string(
            prefix, "`monitor_interval` must be a number of seconds from 0 to ", MAX_TIMEOUT_S, ", got ", repr(v)
        )))
    elseif k === :retries
        (is_whole_number(v) && 0 <= v <= MAX_RETRIES) || throw(ArgumentError(string(
            prefix, "`retries` must be an integer from 0 to ", MAX_RETRIES, ", got ", repr(v)
        )))
    elseif k === :memory_threshold
        (is_number(v) && 0 < v <= 1) || throw(ArgumentError(string(
            prefix, "`memory_threshold` must be in (0, 1], got ", repr(v)
        )))
    elseif k === :logs
        ok = if v isa Symbol
            any(m -> m === v, LOG_MODES)
        elseif v isa AbstractString
            s = Symbol(v)::Symbol
            any(m -> m === s, LOG_MODES)
        else
            false
        end
        ok || throw(ArgumentError(string(
            prefix, "`logs` must be one of ", LOG_MODES, ", got ", repr(v)
        )))
    elseif k in FLAG_SETTINGS
        v isa Bool || throw(ArgumentError(string(
            prefix, "`", k, "` must be true or false, got ", repr(v)
        )))
    elseif k === :seed
        (is_whole_number(v) && 0 <= v <= typemax(UInt64)) || throw(ArgumentError(string(
            prefix, "`seed` must be an integer from 0 to ", typemax(UInt64), ", got ", repr(v)
        )))
    elseif k === :testset_name
        (v isa AbstractString && !isempty(v)) || throw(ArgumentError(string(
            prefix, "`testset_name` must be a non-empty string, got ", repr(v)
        )))
    elseif k === :skip_environment
        ok = if v isa AbstractString
            !isempty(v)
        elseif v isa AbstractVector
            all_ok = true
            for n in v
                if !(n isa AbstractString && !isempty(n))
                    all_ok = false
                    break
                end
            end
            all_ok
        else
            false
        end
        ok || throw(ArgumentError(string(
            prefix, "`skip_environment` must be the path of an environment directory from the root of the " *
                "repository, as in \"test/qa\", or a vector of them, got ", repr(v)
        )))
    else
        throw(unknown_keyword(k; prefix))
    end
    return nothing
end

# Pure (no-I/O) validation of one selection or call-level keyword value.
function validate_call_kwarg(k::Symbol, @nospecialize(v); mono::Bool = false, prefix::AbstractString = "")
    if k === :name
        (v === nothing || v isa FailingItems) && return nothing
        Filter(; name = v)
    elseif k === :tags
        v === nothing && return nothing
        Filter(; tags = v)
    elseif k === :group
        (v === nothing || v isa DefaultGroupCall) && return nothing
        (v isa Union{AbstractString, Symbol} && !isempty(string(v))) || throw(ArgumentError(string(
            prefix, "`group = ", repr(v), "`: expected the name of a group of [groups], \"",
            ALL_GROUP, "\" or \"", DEFAULT_GROUP, "\""
        )))
    elseif k === :dry_run
        v isa Bool || throw(ArgumentError(string(prefix, "`dry_run` must be true or false, got ", repr(v))))
    elseif k === :on_event
        (v === nothing || hasmethod(v, Tuple{TestItemEvent})) || throw(ArgumentError(string(
            prefix, "`on_event` must be a function that takes a `Runtests.TestItemEvent`, got ", repr(v)
        )))
    elseif k === :config
        mono && throw(ArgumentError(string(
            prefix, "`config` names a file to read in place of one package's test/TestItems.toml, " *
                "and a combined run reads each package's own"
        )))
        (v === nothing || v isa AbstractString) || throw(ArgumentError(string(
            prefix, "`config` must be a path string, got ", repr(v)
        )))
    elseif k === :replay
        (v === nothing || v isa AbstractString) || throw(ArgumentError(string(
            prefix, "`replay` must be a path string, got ", repr(v)
        )))
    elseif k === :worker_init || k === :test_end
        (v === nothing || v isa Expr) || throw(ArgumentError(string(
            prefix, "`", k, "` must be an expression, as in `", k,
            " = :(using Foo)` or a `quote` block, got ", repr(v)
        )))
    elseif k === :packages
        mono || throw(unknown_keyword(k; mono, prefix))
        v === nothing && return nothing
        ok = if v isa Union{AbstractString, Symbol}
            true
        elseif v isa Union{AbstractVector, Tuple} && !isempty(v)
            all_ok = true
            for p in v
                if !(p isa Union{AbstractString, Symbol})
                    all_ok = false
                    break
                end
            end
            all_ok
        else
            false
        end
        ok || throw(ArgumentError(string(
            prefix, "`packages` must be package names or directories, as in `packages = [\"A\", \"lib/B\"]`, got ",
            repr(v)
        )))
    else
        throw(unknown_keyword(k; mono, prefix))
    end
    return nothing
end

# Validate every keyword name and value in `opts` up front, before any filesystem I/O,
# suite scan, or runstate read.
function validate_run_kwargs(opts::Dict{Symbol, Any}; mono::Bool = false, allow_call_keys::Bool = false,
                             prefix::AbstractString = "")
    call_keys = mono ? MONO_CALL_KEYS : CALL_KEYS
    for (k, v) in opts
        if k in RUN_KEYS
            validate_run_setting(k, v; prefix)
        elseif mono && k === :config
            validate_call_kwarg(k, v; mono = true, prefix)
        elseif allow_call_keys && k in call_keys
            validate_call_kwarg(k, v; mono, prefix)
        else
            throw(unknown_keyword(k; mono, prefix))
        end
    end
    w = get(opts, :workers, nothing)
    if get(opts, :coverage, nothing) === true && is_whole_number(w) && w == 0
        throw(ArgumentError(string(
            prefix, "`coverage` is counted by worker processes, and `workers = 0` runs the items in this one, " *
                "whose coverage was fixed when it started; use one worker or more"
        )))
    end
    return nothing
end

const ORDER_KEYS = (:first, :last)
const PROFILE_KEYS = (:julia_args, :env, :preferences, :monorepo_default, :precompile)
const TOP_KEYS = (:run, :order, :profiles, :groups, :throttle, :monorepo)
const LOG_MODES = (:eager, :batched, :issues, :quiet)

### Names that become paths ###################################################

# What some system refuses in the name of a file: the separators of every system and
# the characters that Windows reserves. Control characters are refused apart.
const UNPORTABLE_CHARS = ('/', '\\', ':', '*', '?', '"', '<', '>', '|')
# The names that Windows takes for devices, in any case and with any extension.
const DEVICE_NAMES = Set(["con", "prn", "aux", "nul", ("com$i" for i in 1:9)..., ("lpt$i" for i in 1:9)...])

"""
    unportable_name(name) -> Union{Nothing, String}

Why `name` cannot be the name of one file or directory on each system that Runtests
runs on, or `nothing` when it can.
"""
function unportable_name(name::AbstractString)
    isempty(name) && return "it is empty"
    isvalid(name) || return "it is not valid UTF-8"
    name in (".", "..") && return "it names a directory itself"
    i = findfirst(c -> c in UNPORTABLE_CHARS || c < ' ' || c == '\x7f', name)
    i === nothing || return string("it holds ", repr(name[i]))
    (endswith(name, ' ') || endswith(name, '.')) && return "Windows drops a space or a dot at its end"
    lowercase(first(split(name, '.'))) in DEVICE_NAMES && return "Windows takes it for a device"
    ncodeunits(name) > 255 && return "it is longer than 255 bytes"
    return nothing
end

"""
    fold_name(name) -> String

`name` as a system that ignores case compares it: macOS and Windows hold one file for
two names with the same fold. The fold also composes Unicode, as macOS does.
"""
fold_name(name::AbstractString) = Base.Unicode.normalize(String(name); casefold = true)

# The groups of `names` that differ only in case, each sorted: on macOS and Windows,
# each group is one file.
function case_clashes(names)
    groups = Dict{String, Vector{String}}()
    for n in unique(names)
        push!(get!(Vector{String}, groups, fold_name(n)), String(n))
    end
    return sort!([sort!(g) for g in values(groups) if length(g) > 1])
end

# Whether `base` holds `parts`, one inside the other, each with its case as written:
# on macOS and Windows, `isfile` finds `Bounds/x` for `bounds/x` too.
function exists_exactly(base::AbstractString, parts::AbstractString...)
    dir = String(base)::String
    for part in parts
        name = String(part)::String
        (isdir(dir) && name in readdir(dir)) || return false
        dir = joinpath(dir, name)
    end
    return true
end

# The group that `runtestsd` selects, the whole suite unless declared, and the name of
# the whole suite, which no `[groups]` entry may take.
const DEFAULT_GROUP = "default"
const ALL_GROUP = "all"

# What `runtestsd` and `runtestsd_mono` ask for in place of a `group`: the group
# `default`, which the header of the run says that they selected.
struct DefaultGroupCall
    caller::String
end

"""
    read_config(testdir; config = nothing, kwargs...) -> RunConfig

Merge `test/TestItems.toml` with explicit keyword arguments. An unknown key is an
error, not a no-op: a misspelled option would otherwise be ignored in silence.
`config` names another file to read in its place, relative to the current
directory; named, it has to exist, where `test/TestItems.toml` may be absent. For a
workspace member, profiles marked `monorepo_default = true` in the workspace root's
file are also available; unrelated root profiles and run settings do not apply.
"""
function kwargs_dict(kwargs)
    d = Dict{Symbol, Any}()
    for (k, v) in pairs(kwargs)
        d[k] = v
    end
    return d
end

function read_config(testdir::AbstractString, peak_worker_mb::Real = 0.0, rss_coverage::Real = 1.0;
                     config::Union{Nothing, AbstractString} = nothing, nunits::Integer = 0, kwargs...)
    return read_config_impl(
        String(testdir), Float64(peak_worker_mb), Float64(rss_coverage),
        config === nothing ? nothing : String(config), Int(nunits), kwargs_dict(kwargs)
    )
end

function read_config_impl(testdir::String, peak_worker_mb::Float64, rss_coverage::Float64,
                          config::Union{Nothing, String}, nunits::Int, opts::Dict{Symbol, Any})
    path, toml = config_toml(testdir, config)
    # The code of the profiles is the suite's, wherever the file that `config` names is.
    return build_config_impl(
        path, toml, peak_worker_mb, rss_coverage, nunits,
        config === nothing ? "" : path, testdir,
        package_shared_profiles(dirname(abspath(testdir))), nothing, opts
    )
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

# A TOML table value as a concrete `Dict{String, Any}`, empty when absent or not a table.
function toml_table(d::Dict{String, Any}, key::AbstractString)::Dict{String, Any}
    v = get(d, key, nothing)
    return v isa Dict{String, Any} ? v : Dict{String, Any}()
end

function check_keys(path, tbl::AbstractDict, allowed::Tuple, where_)
    ks = String[]
    for k in keys(tbl)
        push!(ks, k isa String ? k : string(k)::String)
    end
    for k in sort!(ks)
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

# Format `case_clashes` groups as `` `a` and `b`, `c` and `d` ``.
format_case_clashes(clashes::Vector{Vector{String}}) =
    join((join(("`$n`" for n in g), " and ") for g in clashes), ", ")

# A table of the configuration, validated to be a TOML table.
function table_section(path, parent::AbstractDict, key::AbstractString, label = key)::Dict{String, Any}
    t = get(parent, key, nothing)
    t === nothing && return Dict{String, Any}()
    t isa Dict{String, Any} && return t
    t isa AbstractDict || throw(ConfigError("[$label] of $(relpath_or_path(path)) must be a table"))
    out = Dict{String, Any}()
    for (k, v) in t
        out[k isa String ? k : string(k)::String] = v
    end
    return out
end

# A table of the configuration, holding only the keys it may hold. `label` is how
# a message names it.
function section(path, parent::AbstractDict, key::AbstractString, allowed::Tuple, label = key)::Dict{String, Any}
    t = table_section(path, parent, key, label)
    check_keys(path, t, allowed, label)
    return t
end

# `key` of the table labelled `label`, a list of strings, empty when absent. A string on
# its own is refused rather than read as the list of its characters: `key = "a"` for
# `key = ["a"]` is the likeliest slip.
function string_list(path, table::AbstractDict, key::AbstractString, label::AbstractString)::Vector{String}
    v = get(table, key, nothing)
    v === nothing && return String[]
    (v isa AbstractVector && all(x -> x isa AbstractString, v)) || throw(ConfigError(
        "`$key` of [$label] in $(relpath_or_path(path)) must be a list of strings, as in " *
            "`$key = [\"…\"]`, got $(repr(v))"
    ))
    out = String[]
    for x in v
        push!(out, x isa String ? x : String(x)::String)
    end
    return out
end

# `true` or `false` from an environment variable, or `nothing` when it is unset or empty.
function env_flag(name::AbstractString)
    v = lowercase(strip(get(ENV, name, "")))
    isempty(v) && return nothing
    v in ("1", "true", "yes") && return true
    v in ("0", "false", "no") && return false
    throw(ConfigError("`$name` must be true or false (or 1, 0, yes, no), got $(repr(ENV[name]))"))
end

# The variable that sets the run setting `key`: `RUNTESTS_WORKERS` for `workers`.
env_setting_name(key::Symbol) = string("RUNTESTS_", uppercase(String(key)))

# The value of a run setting as a variable gives it: a flag, the text of a setting
# that is text, and otherwise a number where it reads as one and else the text, which
# the setting's own check then refuses by name.
function env_setting(key::Symbol, name::String, text::String)
    key in FLAG_SETTINGS && return env_flag(name)
    # Names with commas between them.
    key === :skip_environment && return String[strip(n) for n in split(text, ','; keepempty = false)]
    (key in TEXT_SETTINGS || (key === :workers && text == "auto")) && return text
    return something(tryparse(Int, text), tryparse(UInt64, text), tryparse(Float64, text), Some(text))
end

# Pick a run setting with precedence: keyword > RUNTESTS_<KEY> > `[run]` > default.
# Records env overrides in `from_env` when provided.
function pick_run_setting(key::Symbol, default, kwargs, run::AbstractDict,
                          from_env::Union{Nothing, Vector{Pair{String, String}}} = nothing)
    v = get(kwargs, key, nothing)
    v === nothing || return v
    name = env_setting_name(key)
    text = String(strip(get(ENV, name, "")))
    if !isempty(text)
        from_env === nothing || push!(from_env, name => text)
        return env_setting(key, name, text)
    end
    return get(run, string(key), default)
end

function build_config(path, toml, peak_worker_mb::Real = 0.0, rss_coverage::Real = 1.0; nunits = 0,
                      config_file::AbstractString = "", testdir::AbstractString = dirname(path),
                      shared::Union{Nothing, SharedProfiles} = nothing,
                      profiles::Union{Nothing, Dict{Symbol, Profile}} = nothing, kwargs...)
    return build_config_impl(
        String(path), toml, Float64(peak_worker_mb), Float64(rss_coverage), Int(nunits),
        String(config_file), String(testdir), shared, profiles, kwargs_dict(kwargs)
    )
end

function build_config_impl(path::String, toml::Dict{String, Any}, peak_worker_mb::Float64, rss_coverage::Float64,
                           nunits::Int, config_file::String, testdir::String,
                           shared::Union{Nothing, SharedProfiles},
                           profiles::Union{Nothing, Dict{Symbol, Profile}},
                           kwargs::Dict{Symbol, Any})
    for k in keys(kwargs)
        k in RUN_KEYS || throw(unknown_keyword(k))
    end
    # A value the call gave is the call's mistake; one from the file or the
    # environment is the configuration's.
    given(keys...) = any(k -> get(kwargs, k, nothing) !== nothing, keys)
    run = section(path, toml, "run", RUN_KEYS)
    # Which environments a version of Julia cannot build is the caller's to say: one
    # list in the file would hold on every version.
    haskey(run, "skip_environment") && throw(ConfigError(
        "`skip_environment` of [run] in $(relpath_or_path(path)): a configuration file skips no environment. " *
            "Give the names to the call, as `test/runtests.jl` can compute them from `VERSION`, or in " *
            "`RUNTESTS_SKIP_ENVIRONMENT`"
    ))
    # A keyword wins over the environment, the environment over the file, and the file
    # over the default: CI sets a job's settings without editing the project. A
    # variable is read only when no keyword decides, so a bad value there fails only a
    # run it would have set.
    from_env = Pair{String, String}[]
    pick(key, default) = pick_run_setting(key, default, kwargs, run, from_env)
    # A value from a variable is said with its variable, which is all that shows it.
    function bad(msg, keys...)
        given(keys...) && return ArgumentError(msg)
        vars = [n for k in keys for (n, _) in from_env if n == env_setting_name(k)]
        return ConfigError(isempty(vars) ? msg : string(msg, " (from `", join(vars, "`, `"), "`)"))
    end
    seconds(key, x)::Int = (is_number(x) && 0 < x <= MAX_TIMEOUT_S) ? Int(ceil(x)) :
        throw(bad("`$key` must be a positive number of seconds, at most $MAX_TIMEOUT_S, got $(repr(x))", key))
    # 0 prints at every sample, five times a second: a test's way to make the
    # monitor print as often as it can.
    interval(x)::Int = (is_number(x) && 0 <= x <= MAX_TIMEOUT_S) ? Int(ceil(x)) :
        throw(bad("`monitor_interval` must be a number of seconds from 0 to $MAX_TIMEOUT_S, got $(repr(x))", :monitor_interval))
    flag(key, default)::Bool = (v = pick(key, default); v isa Bool ? v :
        throw(bad("`$key` must be true or false, got $(repr(v))", key)))

    threads = threads_spec("threads", pick(:threads, DEFAULT_THREADS), msg -> bad(msg, :threads))
    mt = pick(:memory_threshold, 0.9)
    (is_number(mt) && 0 < mt <= 1) || throw(bad("`memory_threshold` must be in (0, 1], got $(repr(mt))", :memory_threshold))
    mt_f = Float64(mt)::Float64
    w = pick(:workers, "auto")
    # A worker is a slot, and slots are numbered in a `SlotIdx`.
    ((is_whole_number(w) && 0 <= w <= typemax(SlotIdx)) || w == "auto") || throw(bad(
        "`workers` must be \"auto\" or an integer from 0 to $(typemax(SlotIdx)), got $(repr(w))", :workers
    ))
    workers = (w isa Integer ? Int(w) :
        auto_workers(threads, nunits; peak_worker_mb, coverage = rss_coverage, memory_threshold = mt_f))::Int
    logs = Symbol(pick(:logs, default_logs(workers)))::Symbol
    logs in LOG_MODES || throw(bad("`logs` must be one of $(LOG_MODES), got $(repr(logs))", :logs))
    timeout = seconds(:timeout, pick(:timeout, DEFAULT_TIMEOUT_S))
    retries = pick(:retries, 0)
    (is_whole_number(retries) && 0 <= retries <= MAX_RETRIES) ||
        throw(bad("`retries` must be an integer from 0 to $MAX_RETRIES, got $(repr(retries))", :retries))
    retries_i = Int(retries)::Int
    failfast = flag(:failfast, false)
    # Absent, a random one: 0 is a seed like any other.
    seed = pick(:seed, nothing)
    (seed === nothing || (is_whole_number(seed) && 0 <= seed <= typemax(UInt64))) ||
        throw(bad("`seed` must be an integer from 0 to $(typemax(UInt64)), got $(repr(seed))", :seed))
    seed_u = (seed === nothing ? rand(RandomDevice(), UInt64) : UInt64(seed))::UInt64
    order = section(path, toml, "order", ORDER_KEYS)
    coverage = flag(:coverage, false)
    coverage_source = given(:coverage) ? "the `coverage` keyword" :
        any(((n, _),) -> n == "RUNTESTS_COVERAGE", from_env) ? "`RUNTESTS_COVERAGE`" :
        haskey(run, "coverage") ? relpath_or_path(path) : ""
    coverage && workers == 0 && throw((given(:coverage, :workers) ? ArgumentError : ConfigError)(
        "`coverage` is counted by worker processes, and `workers = 0` runs the items in this one, " *
            "whose coverage was fixed when it started; use one worker or more"
    ))
    testset_name = pick(:testset_name, "Runtests")
    (testset_name isa AbstractString && !isempty(testset_name)) ||
        throw(bad("`testset_name` must be a non-empty string, got $(repr(testset_name))", :testset_name))
    testset_name_s = testset_name isa String ? testset_name : String(testset_name)::String
    skip = pick(:skip_environment, String[])
    skip isa AbstractString && (skip = [skip])
    (skip isa AbstractVector && all(n -> n isa AbstractString && !isempty(n), skip)) || throw(bad(
        "`skip_environment` must be the path of an environment directory from the root of the repository, " *
            "as in \"test/qa\", or a vector of them, got $(repr(skip))", :skip_environment
    ))
    skip_env = String[]
    for n in skip
        ns = n isa String ? n : String(n)::String
        push!(skip_env, String(rstrip(replace(ns, '\\' => '/'), '/')))
    end
    unique!(skip_env)
    cfg_file_s = config_file isa String ? config_file : String(config_file)::String

    return RunConfig(;
        workers, threads, timeout_s = timeout,
        init_timeout_s = seconds(:init_timeout, pick(:init_timeout, timeout)),
        test_end_timeout_s = seconds(:test_end_timeout, pick(:test_end_timeout, timeout)),
        artifacts_timeout_s = seconds(:artifacts_timeout, pick(:artifacts_timeout, timeout)),
        retries = retries_i, failfast, item_failfast = flag(:item_failfast, failfast), logs,
        verbose = flag(:verbose, false),
        memory_threshold = mt_f, monitor = flag(:monitor, true),
        full_stacktraces = flag(:full_stacktraces, false),
        full_names = flag(:full_names, false),
        testset_name = testset_name_s, coverage, coverage_source, env_settings = from_env,
        monitor_interval = interval(pick(:monitor_interval, 30)),
        profiles = profiles === nothing ? read_profiles(path, toml; shared, testdir) : profiles,
        groups = read_groups(path, toml),
        order_first = string_list(path, order, "first", "order"),
        order_last = string_list(path, order, "last", "order"),
        throttle = read_throttle(path, toml),
        seed = seed_u,
        config_file = cfg_file_s,
        # With `/` between the directories, whatever the system writes.
        skip_environment = skip_env
    )
end

# What `--threads` takes: default threads, `auto` or at least one, then optionally
# interactive ones, `auto` or any number. Checked here, or the first worker dies of it.
# `where_` says where the setting is, after its name.
function threads_spec(what, x, err = ConfigError; where_ = "")::String
    s = x isa Integer ? string(Int(x)) : x
    (s isa AbstractString && occursin(r"^(auto|[1-9][0-9]*)(,(auto|[0-9]+))?$", s)) || throw(err(
        "`$what`$where_ must be what `--threads` takes (\"4\", \"4,1\", \"auto\"), got $(repr(x))"
    ))
    return s isa String ? s : String(s)::String
end

# One interactive worker streams its logs; several would interleave unreadably, so
# only items with problems print, as in a non-interactive run. `interactive` is a
# parameter so that a test suite, which is never interactive, can check both.
default_logs(workers::Integer, interactive::Bool = isinteractive()) =
    interactive && workers <= 1 ? :eager : :issues

# The profiles of the configuration file `path`, `default` always among them, with
# those that the package's workspace shares (`share_profiles!`), and their code from
# `testdir`'s `testconfigs/`. `shared` is `nothing` where the workspace is not known,
# as before Julia 1.12.
function read_profiles(path, toml; shared::Union{Nothing, SharedProfiles} = nothing,
                       testdir::AbstractString = dirname(path))
    profiles = Dict{Symbol, Profile}()
    tbl = table_section(path, toml, "profiles")
    # Numbered in a byte in a run state, `default` among them.
    length(tbl) <= MAX_PACKAGE_PROFILES ||
        throw(ConfigError("$(relpath_or_path(path)) declares $(length(tbl)) profiles; at most $MAX_PACKAGE_PROFILES fit"))
    names = collect(String, keys(tbl))
    check_profile_names(path, names)
    code_files = check_testconfigs(testdir, names)
    for name in names
        prof, shares = parse_profile(path, tbl, name; testdir, code_files)
        (shares && shared !== nothing && !same_file(path, shared.path)) && throw(ConfigError(string(
            "`monorepo_default` of [profiles.", name, "] in ", relpath_or_path(path), ": only the test/TestItems.toml ",
            "of a workspace's root shares a profile with the packages of the workspace",
            isempty(shared.path) ? ", and this package is in no workspace" :
                string(", here ", relpath_or_path(shared.path), ". Move the profile there")
        )))
        profiles[prof.name] = prof
    end
    # The package's own default profile, with no table, when its code is in files: a
    # default that the workspace shares takes its place only where the package has none.
    if !haskey(profiles, DEFAULT_PROFILE)
        init, test_end = profile_code(testdir, String(DEFAULT_PROFILE), code_files)
        isempty(init.args) && isempty(test_end.args) ||
            (profiles[DEFAULT_PROFILE] = Profile(DEFAULT_PROFILE; threads = "", init, test_end))
    end
    if shared !== nothing
        share_profiles!(profiles, shared)
        clashes = case_clashes(String.(keys(profiles)))
        isempty(clashes) || throw(ConfigError(string(
            relpath_or_path(path), " and ", relpath_or_path(shared.path), ", which shares its profiles, declare ",
            format_case_clashes(clashes), ", which differ only in case: ",
            "macOS and Windows hold one directory in test/$TESTCONFIGS_DIR/ for each such pair. Rename one"
        )))
    end
    haskey(profiles, DEFAULT_PROFILE) ||
        (profiles[DEFAULT_PROFILE] = Profile(DEFAULT_PROFILE; threads = ""))
    return profiles
end

# The names of the profiles that `path` declares, each the name of a directory in
# `test/testconfigs/` (see `check_testconfigs`): a name that some system cannot give a
# directory, `default` in another case, the name of a file of the directory, and two
# names that differ only in case are errors.
function check_profile_names(path, names::Vector{String})
    for n in names
        bad(why) = ConfigError("[profiles.$n] in $(relpath_or_path(path)): the name of a profile is the name of " *
                               "its directory in test/$TESTCONFIGS_DIR/, and $why")
        why = unportable_name(n)
        why === nothing || throw(bad(why))
        fold_name(n) == String(DEFAULT_PROFILE) && n != String(DEFAULT_PROFILE) &&
            throw(bad("it differs from `default` only in case, which macOS and Windows do not tell apart"))
        fold_name(n) in map(fold_name, TESTCONFIG_FILES) && throw(bad("it is the name of a file there"))
    end
    clashes = case_clashes(names)
    isempty(clashes) || throw(ConfigError(string(
        relpath_or_path(path), " declares the profiles ", format_case_clashes(clashes),
        ", which differ only in case: macOS and Windows hold one directory in test/$TESTCONFIGS_DIR/ for each such ",
        "pair. Rename one"
    )))
    return nothing
end

"""
    check_testconfigs(testdir, names) -> Dict{String, Set{String}}

Throw a `ConfigError` for each entry of `test/testconfigs/` that is not code of a
profile: the default profile's `worker_init.jl` and `test_end.jl` at its top, and for
each other profile in `names` a directory with its exact name that holds the two files.
Hidden entries are passed over. A directory that is a profile's name in another case
is an error: macOS and Windows would read it, and Linux would not. Returns the valid
files found per profile name so `profile_code` need not re-read the directories.
"""
function check_testconfigs(testdir::AbstractString, names::Vector{String})
    found = Dict{String, Set{String}}()
    dir = joinpath(testdir, TESTCONFIGS_DIR)
    (exists_exactly(testdir, TESTCONFIGS_DIR) && isdir(dir)) || return found
    others = filter(!=(String(DEFAULT_PROFILE)), names)
    bad = String[]
    notes = String[]
    for e in readdir(dir)
        startswith(e, '.') && continue
        path = joinpath(dir, e)
        if !isdir(path)
            e in TESTCONFIG_FILES ? push!(get!(Set{String}, found, String(DEFAULT_PROFILE)), e) : push!(bad, "`$e`")
        elseif e in others
            for f in readdir(path)
                startswith(f, '.') && continue
                if f in TESTCONFIG_FILES && isfile(joinpath(path, f))
                    push!(get!(Set{String}, found, e), f)
                else
                    push!(bad, "`$e/$f`")
                end
            end
        else
            push!(bad, "`$e/`")
            i = findfirst(n -> fold_name(n) == fold_name(e), others)
            i === nothing || push!(notes, "`$e/` is the profile `$(others[i])` in another case")
        end
    end
    isempty(bad) && return found
    throw(ConfigError(string(
        relpath_or_path(dir), " holds ", join(bad, ", "), ". It holds `", WORKER_INIT_FILE, "` and `", TEST_END_FILE,
        "`, the code of the default profile, and for each other profile of [profiles] a directory of its name ",
        "with those two files. ", isempty(others) ? "No other profile is declared" :
            string("The other profiles are ", join(("`$n`" for n in sort(others)), ", ")),
        isempty(notes) ? "" : string(". ", join(notes, ", ")),
        ". A profile that the workspace shares takes its code from the workspace root's test/$TESTCONFIGS_DIR/"
    )))
end

# The directory of the code of profile `name` in `testdir`.
profile_code_dir(testdir::AbstractString, name::AbstractString) =
    name == String(DEFAULT_PROFILE) ? joinpath(testdir, TESTCONFIGS_DIR) : joinpath(testdir, TESTCONFIGS_DIR, name)

"""
    profile_code(testdir, name[, code_files]) -> (init, test_end)

The `init` and `test_end` of profile `name`, from `test/testconfigs/` in `testdir`:
each file parsed with its path, so that an error in it names the file and the line.
An empty block for a file that is not there with its exact name.
"""
function profile_code(testdir::AbstractString, name::AbstractString,
                      code_files::Union{Nothing, Dict{String, Set{String}}} = nothing)
    parts = name == String(DEFAULT_PROFILE) ? (TESTCONFIGS_DIR,) : (TESTCONFIGS_DIR, name)
    have = code_files === nothing ? nothing : get(code_files, String(name), nothing)
    function code(file)
        ok = code_files === nothing ? exists_exactly(testdir, parts..., file) : (have !== nothing && file in have)
        return ok ? parse_code_file(joinpath(testdir, parts..., file)) : Expr(:block)
    end
    return code(WORKER_INIT_FILE), code(TEST_END_FILE)
end

"""
    call_code!(profiles, worker_init, test_end; dir = "")

Put the `worker_init` and `test_end` that a call gave, expressions or `nothing`, in
place of the code that the default profile in `profiles` has from its files. A call
wins over a file, as a keyword wins over the file for a setting. The code runs in
`dir` (see `init_dir`): the package's root when empty, as for code that its files
give, or a workspace root for a combined run.
"""
function call_code!(profiles::Dict{Symbol, Profile}, worker_init, test_end; dir::AbstractString = "")
    worker_init === nothing && test_end === nothing && return profiles
    block(key, ex) = ex isa Expr ? (ex.head === :block ? ex : Expr(:block, ex)) : throw(ArgumentError(
        "`$key` must be an expression, as in `$key = :(using Foo)` or a `quote` block, got $(repr(ex))"
    ))
    p = profiles[DEFAULT_PROFILE]
    profiles[DEFAULT_PROFILE] = with_profile(
        p;
        init = worker_init === nothing ? p.init : block(:worker_init, worker_init),
        test_end = test_end === nothing ? p.test_end : block(:test_end, test_end),
        dir = String(dir)
    )
    return profiles
end

function parse_code_file(path::AbstractString)
    bad(what) = ConfigError("could not parse $(relpath_or_path(path)): $what")
    ex = try
        Meta.parseall(read(path, String); filename = path)
    catch e
        throw(bad(sprint(showerror, e)))
    end
    # `parseall` reports a bad parse as an `:error`/`:incomplete` node rather than
    # by throwing, so an unchecked result would defer the failure to the worker.
    for a in ex.args
        a isa Expr && a.head in (:error, :incomplete) && throw(bad(a.args[1]))
    end
    # A file of comments and blank lines is no code: a profile without code shares
    # workers more widely, and a default without code gives way to a shared one.
    all(a -> a isa LineNumberNode, ex.args) && return Expr(:block)
    return Expr(:block, ex.args...)
end

# Profile `name` of the `[profiles]` table `tbl` of the configuration file `path`, with
# its code from `testdir` (see `profile_code`), and whether it says
# `monorepo_default = true`.
function parse_profile(path, tbl::AbstractDict, name::AbstractString; testdir::AbstractString = dirname(path),
                       code_files::Union{Nothing, Dict{String, Set{String}}} = nothing)
    label = "profiles.$name"
    given = table_section(path, tbl, name, label)
    haskey(given, "environment") && throw(ConfigError(
        "`environment` of [$label] in $(relpath_or_path(path)): a profile has no environment. The test items in " *
            "a directory under `test/` with a Project.toml of its own run in that environment, under any " *
            "profile; remove the key, and give those items `profile = :$name` where they need this profile"
    ))
    haskey(given, "threads") && throw(ConfigError(
        "`threads` of [$label] in $(relpath_or_path(path)): the threads of a profile are a flag of `julia_args`, " *
            "as in `julia_args = [\"--threads=$(get(given, "threads", "4"))\"]`. Move them there, and remove the key"
    ))
    for (key, file) in (("init", WORKER_INIT_FILE), ("test_end", TEST_END_FILE))
        haskey(given, key) && throw(ConfigError(string(
            "`", key, "` of [", label, "] in ", relpath_or_path(path), ": the code of a profile is in a file of its own. ",
            "Move it to ", relpath_or_path(joinpath(profile_code_dir(testdir, name), file)), ", and remove the key"
        )))
    end
    check_keys(path, given, PROFILE_KEYS, label)
    p = given
    args = string_list(path, p, "julia_args", label)
    vars = get(Dict{String, Any}, p, "env")
    (vars isa AbstractDict && all(v -> v isa Union{AbstractString, Real}, values(vars))) || throw(ConfigError(
        "`env` of [$label] in $(relpath_or_path(path)) must be a table of variables, as in " *
            "`env = { NAME = \"value\" }`, got $(repr(vars))"
    ))
    env = Pair{String, String}[]
    for (k, v) in vars
        push!(env, (k isa String ? k : string(k)::String) => (v isa String ? v : string(v)::String))
    end
    sort_by!(env, first)
    shares = get(p, "monorepo_default", false)
    shares isa Bool || throw(ConfigError(
        "`monorepo_default` of [$label] in $(relpath_or_path(path)) must be true or false, got $(repr(shares))"
    ))
    precompile = haskey(p, "precompile") ? string_list(path, p, "precompile", label) : nothing
    init, test_end = profile_code(testdir, name, code_files)
    threads = take_threads!(args, " in `julia_args` of [$label] in $(relpath_or_path(path))")
    prof = Profile(
        Symbol(name), args, threads, env, init, test_end,
        profile_preferences(path, name, get(p, "preferences", "")), "", "", precompile
    )
    return prof, shares
end

"""
    take_threads!(args, where_) -> String

The `--threads` that the julia arguments `args` give, as `-t 4`, `-t4`, `--threads 4`
or `--threads=4`, taken out of `args`; empty when they give none. The workers get the
threads apart from the other arguments, the run's `threads` when a profile gives
none, and the threads never reach the cache flags (`cache_flags_for`): the number of
threads compiles no code differently. `where_` says where the arguments are, for an
error.
"""
function take_threads!(args::Vector{String}, where_::AbstractString)
    threads = ""
    i = firstindex(args)
    while i <= lastindex(args)
        a = args[i]
        value = if a == "-t" || a == "--threads"
            i < lastindex(args) || throw(ConfigError("`$a`$where_ has no value after it"))
            v = args[i + 1]
            deleteat!(args, i:(i + 1))
            v
        elseif startswith(a, "--threads=")
            deleteat!(args, i)
            a[(ncodeunits("--threads=") + 1):end]
        elseif startswith(a, "-t") && !startswith(a, "--")
            deleteat!(args, i)
            a[3:end]
        else
            i += 1
            continue
        end
        isempty(threads) || throw(ConfigError("`--threads`$where_ is given twice"))
        threads = threads_spec("--threads", value; where_)
    end
    return threads
end

same_file(a::AbstractString, b::AbstractString) = !isempty(b) && isfile(a) && isfile(b) && samefile(a, b)

# A package's profiles with those its workspace shares: a shared profile that the
# package does not declare is its own too, and one that it declares with the same
# `init` and `test_end`, as code, runs that code where the shared one runs it. One
# with another `init` or `test_end` keeps its own definition; it may still share
# workers when its startup configuration and `init` directory match another's.
function share_profiles!(profiles::Dict{Symbol, Profile}, shared::SharedProfiles)
    for (name, s) in shared.profiles
        own = get(profiles, name, nothing)
        if own === nothing
            profiles[name] = s
        elseif same_code(own.init, s.init) && same_code(own.test_end, s.test_end)
            profiles[name] = with_profile(own; init = s.init, test_end = s.test_end, dir = s.dir)
        end
    end
    return profiles
end

# The directory the `init` of `prof` runs in, for a package whose root is `root`.
init_dir(prof::Profile, root::AbstractString) = isempty(prof.dir) ? String(root) : prof.dir

# Whether two expressions are the same code, wherever and however each was written.
same_code(a::Expr, b::Expr) = Base.remove_linenums!(deepcopy(a)) == Base.remove_linenums!(deepcopy(b))

"""
    shared_profiles(path, toml, workspace) -> SharedProfiles

The profiles that the configuration file `path` of the root of `workspace` marks
`monorepo_default = true`, with `workspace` as the directory their `init` runs in.
After TOML syntax is parsed, only marked profile declarations are validated here;
the rest of the file is the root's own, which its own runs check.
"""
function shared_profiles(path::AbstractString, toml, workspace::AbstractString)
    out = Dict{Symbol, Profile}()
    tbl = get(Dict{String, Any}, toml, "profiles")
    tbl isa AbstractDict || return SharedProfiles(String(path)::String, out)
    marked = String[]
    for (name, given) in tbl
        if given isa AbstractDict && get(given, "monorepo_default", false) === true
            push!(marked, name isa String ? name : String(name)::String)
        end
    end
    check_profile_names(path, marked)
    ws = workspace isa String ? workspace : String(workspace)::String
    for name in marked
        # Its code is in the workspace root's `test/testconfigs/`.
        prof, _ = parse_profile(path, tbl, name)
        out[prof.name] = with_profile(prof; dir = ws)
    end
    return SharedProfiles(path isa String ? path : String(path)::String, out)
end

# The profiles that the workspace of the package at `root` shares with its packages:
# none for a package in no workspace, and `nothing` before Julia 1.12, whose packages
# are in none.
function package_shared_profiles(root::AbstractString)
    @static if isdefined(Base, :base_project)
        project = project_file(root)
        project === nothing && return NO_SHARED_PROFILES
        outer = outermost_workspace(project)
        haskey(parse_project(outer), "workspace") || return NO_SHARED_PROFILES
        workspace = realpath(dirname(outer))
        # As TOML only: what else the file holds is the root's to check.
        path = joinpath(workspace, "test", "TestItems.toml")
        isfile(path) || return SharedProfiles(path, Dict{Symbol, Profile}())
        toml = try
            TOML.parsefile(path)
        catch e
            throw(ConfigError("could not parse $(relpath_or_path(path)), which holds the profiles the workspace " *
                              "shares: $(sprint(showerror, e))"))
        end
        return shared_profiles(path, toml, workspace)
    else
        return nothing
    end
end

# The profile as its workers start: with its own `--threads`, or the run's when it
# sets none.
run_profile(prof::Profile, threads::String) = isempty(prof.threads) ? with_profile(prof; threads) : prof

# The profile fields a worker gets when it starts: everything but its name,
# `test_end` (run after each item), `dir` (handled separately by `pool_key`) and
# `precompile` (what the run compiles before any worker starts).
start_configuration(prof::Profile) =
    (prof.julia_args, prof.threads, prof.env, prof.init, prof.preferences, prof.environment)

# The profile as its workers start in the environment of the directory `environment`,
# or in the test environment when it is empty.
in_environment(prof::Profile, environment::AbstractString) = with_profile(prof; environment = String(environment))

"""
    read_groups(path, toml) -> Dict{String, TagExpr}

The `[groups]` table: names for tag expressions, each written as a string as `tags`
takes one, which a run selects by with the `group` keyword or `RUNTESTS_GROUP`. Two
names are reserved: `$DEFAULT_GROUP` is what `runtestsd` selects, the whole suite
unless declared here, and `$ALL_GROUP` is the whole suite, and is not declared. A
name that differs from either only in case is an error.
"""
function read_groups(path, toml)
    tbl = table_section(path, toml, "groups")
    groups = Dict{String, TagExpr}()
    for (name, value) in tbl
        what = "group `$name` of [groups] in $(relpath_or_path(path))"
        name == ALL_GROUP && throw(ConfigError("$what: `$ALL_GROUP` is the whole suite, and is not declared"))
        # Told apart by case alone, `All` and `all` would select different items.
        reserved = lowercase(name::String)   # a TOML key
        reserved in (ALL_GROUP, DEFAULT_GROUP) && name != DEFAULT_GROUP && throw(ConfigError(string(
            what, ": `", reserved, "` is reserved, and this differs from it only in case; ",
            reserved == ALL_GROUP ? "`all` is the whole suite, and is not declared" :
                "declare the group that `runtestsd` selects as `default`"
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
    read_throttle(path, toml) -> Dict{Symbol, Throttle}

The `[throttle]` table: for a throttle name, as `throttle = :name` gives it, either the
most items of that throttle that run at once (an integer from 1 to $(typemax(Int32))), or
a table `{ limit = N, warmup = true|false }` where `limit` is required and `warmup`
defaults to `false`.
"""
function read_throttle(path, toml)
    tbl = table_section(path, toml, "throttle")
    limits = Dict{Symbol, Throttle}()
    for (key, value) in tbl
        name = String(key)::String   # a TOML key
        what = "throttle `$name` of [throttle] in $(relpath_or_path(path))"
        Base.isidentifier(name) || throw(ConfigError(
            "$what: a throttle name is what `throttle = :name` gives, a Julia identifier"
        ))
        spec = if value isa AbstractDict
            label = "throttle.$name"
            check_keys(path, value, THROTTLE_KEYS, label)
            haskey(value, "limit") || throw(ConfigError(
                "$what: table form must set `limit`, an integer from 1 to $(typemax(Int32))"
            ))
            lim = value["limit"]
            (is_whole_number(lim) && 1 <= lim <= typemax(Int32)) || throw(ConfigError(
                "`limit` of [$label] in $(relpath_or_path(path)) must be the number of its items that may run " *
                    "at once, an integer from 1 to $(typemax(Int32)), got $(repr(lim))"
            ))
            warm = get(value, "warmup", false)
            warm isa Bool || throw(ConfigError(
                "`warmup` of [$label] in $(relpath_or_path(path)) must be true or false, got $(repr(warm))"
            ))
            Throttle(Int(lim), warm)
        elseif is_whole_number(value) && 1 <= value <= typemax(Int32)
            Throttle(Int(value), false)
        else
            throw(ConfigError(
                "$what must be the number of its items that may run at once, an integer from 1 to " *
                    "$(typemax(Int32)), or a table `{ limit = ..., warmup = ... }`, got $(repr(value))"
            ))
        end
        # The name as Julia reads `:name`, which composes accents and maps lookalikes
        # (the micro sign to μ) where TOML keeps the key as written.
        sym = Meta.parse(name)::Symbol
        haskey(limits, sym) && throw(ConfigError(
            "$what: Julia reads it as `:$sym`, as it reads another key of [throttle]; keep one"
        ))
        limits[sym] = spec
    end
    return limits
end

"""
    select_group(groups, path, requested, selected) -> Union{Nothing, GroupSelection}

The group a run selects by: the `group` keyword, `requested`; else, for a run that
selects nothing else (`selected` false), the group `RUNTESTS_GROUP` names; else the
group `default` when `runtestsd` asks for it with a `DefaultGroupCall`. `nothing` for
the whole suite: no group asked for, `$ALL_GROUP`, and `$DEFAULT_GROUP` when `[groups]`
of the config file `path` does not declare it. A name `[groups]` does not declare is
an error that says the nearest it does: an `ArgumentError` from the keyword, a
`ConfigError` from the environment.
"""
function select_group(groups::Dict{String, TagExpr}, path::AbstractString, requested, selected::Bool)
    name, asker = requested_group(requested, selected)
    name === nothing && return nothing
    name == ALL_GROUP && return nothing
    haskey(groups, name) && return GroupSelection(name isa String ? name : String(name)::String, groups[name], string("from ", asker)::String, path isa String ? path : String(path)::String)
    name == DEFAULT_GROUP && return nothing
    file = relpath_or_path(path)
    declared = sort!(collect(keys(groups)))
    near = near_group_names(name, [declared; ALL_GROUP; haskey(groups, DEFAULT_GROUP) ? String[] : [DEFAULT_GROUP]])
    hint = isempty(near) ? "" : string(" (did you mean ", join(("`$g`" for g in near), " or "), "?)")
    msg = isempty(groups) ? string(asker, " asks for group `", name, "`, and ", file, " declares no [groups]", hint) :
        string(asker, " asks for group `", name, "`, which [groups] of ", file, " does not declare", hint,
               "; it declares ", join(("`$g`" for g in declared), ", "), ", and `$ALL_GROUP` is the whole suite")
    throw(asker == ENV_GROUP_ASKER ? ConfigError(msg) : ArgumentError(msg))
end

const ENV_GROUP_ASKER = "`RUNTESTS_GROUP`"

# The name of the group a call asks for and what asks for it, or `nothing` for none.
# `RUNTESTS_GROUP` replaces the group a call without a `group` keyword runs: the whole
# suite, or `default` from `runtestsd`. A name or a line asked for runs whatever group
# it is in, so a call that selects anything else does not read the variable.
function requested_group(requested, selected::Bool)
    if requested === nothing || requested isa DefaultGroupCall
        env = selected ? "" : strip(get(ENV, "RUNTESTS_GROUP", ""))
        isempty(env) || return String(env), ENV_GROUP_ASKER
        requested === nothing && return nothing, ""
        return DEFAULT_GROUP, string("`", requested.caller, "`")
    end
    (requested isa Union{AbstractString, Symbol} && !isempty(string(requested))) || throw(ArgumentError(
        "`group = $(repr(requested))`: expected the name of a group of [groups], \"$ALL_GROUP\" or \"$DEFAULT_GROUP\""
    ))
    return String(string(requested)), "the `group` keyword"
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
function profile_preferences(config_path, name, value)::String
    bad(what) = ConfigError("`preferences` of [profiles.$name]" * what)
    value isa AbstractString || throw(bad(" must be a path to a TOML file"))
    isempty(value) && return ""
    val = value isa String ? value : String(value)::String
    path = isabspath(val) ? val : normpath(joinpath(dirname(config_path), val))
    isfile(path) || throw(bad(" points at $(relpath_or_path(path)), which does not exist"))
    try
        TOML.parsefile(path)
    catch e
        throw(bad(": could not parse $(relpath_or_path(path)): $(sprint(showerror, e))"))
    end
    return path
end

"""
    code_flags(opts = Base.JLOptions()) -> Vector{String}

The flags of a process that change the code it compiles, each written out whatever
its value: bounds checking, optimization and debug levels, inlining, and
deprecation warnings. A worker inherits its coordinator's through `Base.julia_cmd`,
so they are what a run state records of how its items were compiled, and what a
replay gives its workers.
"""
function code_flags(o = Base.JLOptions())
    bounds = o.check_bounds == 1 ? "yes" : o.check_bounds == 2 ? "no" : "auto"
    depwarn = o.depwarn == 1 ? "yes" : o.depwarn == 2 ? "error" : "no"
    return ["--check-bounds=$bounds", "-O$(o.opt_level)", "-g$(o.debug_level)",
            "--inline=$(o.can_inline == 0 ? "no" : "yes")", "--depwarn=$depwarn"]
end

# `code_flags` of a process started with none of them.
const DEFAULT_CODE_FLAGS = ("--check-bounds=auto", "-O2", "-g1", "--inline=yes", "--depwarn=no")

# The flags a run's workers compile with, and of them those a plain `julia` would not.
run_code_flags(cfg::RunConfig) = isempty(cfg.julia_flags) ? code_flags() : cfg.julia_flags
nondefault_flags(flags) = String[f for f in flags if !(f in DEFAULT_CODE_FLAGS)]

# Unmeasured fallback when no recorded worker RSS exists yet: too many workers risks
# an OOM kill, and each extra one duplicates compilation. `Int64` avoids 32-bit overflow.
const ASSUMED_WORKER_RSS = Int64(4) * 2^30
const MIN_RECORDED_WORKER_RSS = Int64(256) * 2^20   # floor against noisy tiny samples
const COORDINATOR_MEMORY_RESERVE = Int64(512) * 2^20
const WORKER_MEMORY_MARGIN = 1.25                   # 25% headroom over recorded peak worker RSS
const AUTO_WORKERS_UNMEASURED_CAP = 8
const AUTO_WORKERS_MEASURED_CAP = 16
const AUTO_WORKERS_HIGH_COVERAGE = 0.8              # minimum observed item fraction before lifting cap above 8

# The CPUs this process may use: fewer than the machine's under a container
# quota, and oversubscribing them turns timeouts flaky. 1.12 has only the
# machine's count.
effective_cpu_threads() = @static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS

# Default threads per worker from a `--threads` spec (`auto` gives one per CPU).
default_thread_count(threads::AbstractString, cpus::Int = effective_cpu_threads()) =
    (t = first(split(threads, ','))) == "auto" ? cpus : something(tryparse(Int, t), 2)

function auto_workers(threads::String, nunits::Int;
                      peak_worker_mb::Real = 0.0,
                      coverage::Real = 1.0,
                      memory_threshold::Real = 0.9,
                      total_memory::Integer = Sys.total_memory())
    cpus = effective_cpu_threads()
    per_worker = default_thread_count(threads, cpus)
    by_cpu = max(1, cpus ÷ max(1, per_worker))
    recorded_mb = (isfinite(peak_worker_mb) && peak_worker_mb > 0) ? Float64(peak_worker_mb) : 0.0
    if recorded_mb > 0
        cov = isfinite(coverage) ? clamp(Float64(coverage), 0.0, 1.0) : 0.0
        mt = (isfinite(memory_threshold) && 0 < memory_threshold <= 1) ? Float64(memory_threshold) : 0.9
        usable = Int64(floor(Float64(total_memory) * mt))
        reserve = min(COORDINATOR_MEMORY_RESERVE, usable ÷ 4)
        budget = max(Int64(1), usable - reserve)
        obs_bytes = max(MIN_RECORDED_WORKER_RSS, Int64(ceil(recorded_mb * 2^20 * WORKER_MEMORY_MARGIN)))
        # Asymmetric regularization toward the 4 GiB prior when only part of the selection
        # has recorded worker RSS: low readings pull smoothly upward toward 4 GiB so a tiny
        # partial run cannot oversubscribe a full run, while readings above 4 GiB count in full.
        per_worker_bytes = max(obs_bytes, round(Int64, cov * obs_bytes + (1.0 - cov) * ASSUMED_WORKER_RSS))
        by_mem = max(1, Int(budget ÷ per_worker_bytes))
        cap = cov >= AUTO_WORKERS_HIGH_COVERAGE ? AUTO_WORKERS_MEASURED_CAP : AUTO_WORKERS_UNMEASURED_CAP
        n = clamp(min(by_cpu, by_mem), 1, cap)
    else
        by_mem = max(1, Int(Int64(total_memory) ÷ ASSUMED_WORKER_RSS))
        n = clamp(min(by_cpu, by_mem), 1, AUTO_WORKERS_UNMEASURED_CAP)
    end
    return nunits > 0 ? min(n, nunits) : n
end
