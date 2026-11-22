"""
    Runtests

Run a package's tests as independent test items across worker processes.

    Runtests.runtests()                      # every test item under test/
    Runtests.runtests("test/solver_test.jl") # one file
    Runtests.runtests(name="adds numbers")   # one item
    Runtests.runtests(dry_run=true)          # print the plan, run nothing

Test files live under `test/` and are named `*_test.jl` or `*_tests.jl`. They
contain `@testitem` declarations and nothing else. Shared setup code goes in
`test/testsetups/` as ordinary modules, which test items load with `using`.
[`runtests_mono`](@ref) runs several packages of a Julia workspace in one run.
"""
module Runtests

include("RuntestsWorkers/RuntestsWorkers.jl")

"""
    Runtests.Private

The implementation behind the public API. `Runtests` brings its public entry
points into scope; call them through `Runtests`, not this module.
"""
module Private

Base.Experimental.@optlevel 1

using Base.ScopedValues: ScopedValue, with
using Logging: Logging, with_logger, current_logger
using Random: Random, RandomDevice
using Test
using Test: Test
using TOML: TOML

# The worker side: the protocol and the item runner, which a worker process calls.
using ..RuntestsWorkers: RuntestsWorkers, ItemState, UNSEEN, RUNNING, PASSED, FAILED, ERRORED, TIMEDOUT,
    SKIPPED, BROKEN_CHAIN, CANCELLED, is_non_pass, ItemSpec, ItemResult,
    current_testitem, run_item,
    with_testset_printing, without_enclosing_testset, PATHSEP, is_interrupt, shielded, RECORD_MARK,
    OncePerProcess, on_failure, artifacts_dir, ARTIFACT_FILES, ARTIFACT_PRODUCERS, artifacts_log_path

include("types.jl")
include("json.jl")
include("macros.jl")
include("scan.jl")
include("config.jl")
include("plan.jl")
include("monorepo.jl")
include("runstate.jl")
include("runstate_set.jl")
include("report.jl")
include("platform.jl")
include("monitor.jl")
include("coverage.jl")
include("editor.jl")
include("scheduler.jl")
include("execute.jl")
include("environments.jl")
include("precompile_queue.jl")
include("artifacts.jl")
include("interactive.jl")
include("debug.jl")
include("setup_packages.jl")
include("expander.jl")
include("templates.jl")
include("chores.jl")

"""
    runtests([paths...]; kwargs...)
    runtests(mod::Module; kwargs...)

Run the test items under a package's `test/`. With no paths, use the package of
the active project, or the package whose `test/runtests.jl` is running under
`Pkg.test`. A `Module` runs its package's whole suite.

`paths` narrow what runs, while the whole suite is still parsed for errors: a
directory, a test file, or `file.jl:42` to select the item that line is inside,
which is given without other files or directories.
Several paths select what any of them does, so the package or its `test/` among them
is the whole suite.

Returns the run's testset, a [`RunTestSet`](@ref) named `testset_name` (`"Runtests"`
unless given), holding one testset per test file. Inside an enclosing `@testset`
it is recorded there, so the runs of several calls add up under one, told apart by
their names. Outside any, an item that did not pass makes the call throw, which is
what fails `Pkg.test`. A dry run returns `nothing`.

A process holds one run at a time: a call made while another is running, from
another task or thread, throws and leaves that run going.

# Keywords

Selection: `name` (`String` for an exact match, `Regex` for a partial one, or a
vector or set of exact names), `tags` (a symbol or vector of symbols an item must
carry all of, or a string expression such as `"!slow"` or `"juliac || serializer"`), and
`group` (the name of a tag expression `[groups]` of `test/TestItems.toml` declares,
or `"all"`, the whole suite, or `"default"`). The selections a call gives narrow
together. A call that gives none selects the group `RUNTESTS_GROUP` names, when it is
set, and otherwise the whole suite, or `default` from [`runtestsd`](@ref): the group of
that name when `[groups]` declares one, and the whole suite when it does not. A name,
tag or group the suite does not have is an error that says the nearest it does.

`skip_environment` names environment directories, each by its path from the root of
the repository (`"test/qa"`, or `"lib/A/test/qa"` in a monorepo), or one of them: the
run does not build these environments and starts no worker in them, and it records the
items it selected there as skipped. A run that does not include the package of a
named directory accepts the name, and a name that is no environment directory is an
error. Also `RUNTESTS_SKIP_ENVIRONMENT`, with commas between the names, but not `[run]`.

Profile code: `worker_init` and `test_end`, each an expression, as in
`worker_init = :(using Plots)` or a `quote` block, are the `init` and `test_end` of
the default profile, in place of `test/testconfigs/worker_init.jl` and
`test/testconfigs/test_end.jl`. Another profile's code is in its directory there.

Execution: `workers` (a count, or `0` to run in this process), `threads`,
`timeout`, `init_timeout` and `test_end_timeout` (a profile's `init` and `test_end`
expressions are timed separately from the items, and default to `timeout`),
`artifacts_timeout` (what all the producers of one failed attempt may take together,
see [`on_failure`](@ref); `timeout` by default),
`retries`, `failfast` (stop the run on the first failing item), `item_failfast`
(stop an item at its first failing `@test`), `memory_threshold`, `full_stacktraces`
(keep the framework's own frames in a failing item's stacktrace; trimmed by default),
`seed` (every item draws its random numbers from this and its own name; random unless
given, and printed at the start of the run).

Output: `logs` (`:issues`, `:batched`, `:eager`, or `:quiet`, which keeps every
item's non-empty output in the run's logs — readable afterwards with [`logs`](@ref) —
and prints none of it; worker runs in `:eager` mode also save non-empty item output to
per-item logs), `verbose`, `full_names` (do not shorten long item names in the output
column), `monitor`, `monitor_interval`, `testset_name`, `coverage` (count which lines of
`src/` and `ext/` the workers run, merged into `lcov.info` at the package's root;
also `RUNTESTS_COVERAGE`, which a keyword overrides and which overrides the file).

State: `dry_run` prints the plan and runs nothing. `replay` names a run state (one
downloaded from CI, say) and runs it again: the same items in the exact per-worker
slot order recorded (without work-stealing or reordering), with the recorded settings,
profiles, `[order]`, `[throttle]` limits, per-item policies (`timeout`, `retries`,
`item_failfast`, `skip`), and seeds, on workers given the Julia flags it recorded,
with any keyword given here winning. Warns on git revision/worktree changes, missing
or changed items, moved environments, overridden policies, and package/preference
differences against the recording (`dry_run = true` prints the full diff).

Each item: `on_event`, a function this process calls with a [`TestItemEvent`](@ref) as
each attempt at an item starts, and again as it ends with what the attempt cost: its
time, CPU time, compilation, garbage collection, allocations and the memory of its
process. The calls come one at a time from the run's own tasks, which wait for each,
so a slow function slows the run. A call that throws is reported, the function is not
called again, and the tests carry on.

The execution and output settings can also be set under `[run]` in
`test/TestItems.toml`, which also declares profiles, groups and forced ordering, and
by a variable `RUNTESTS_<SETTING>` (`RUNTESTS_WORKERS`, say), which the run's header
names: a keyword wins over the variable, and the variable over the file. `config` names another file to read in its place, relative to the
current directory, which has to exist; nothing but this keyword makes a run read
one. A mistake in the call, such as a misspelled keyword or a value out of range, is
an `ArgumentError`; one in a file or an environment variable is a `ConfigError`.
"""
function runtests(args...; name = nothing, tags = nothing, dry_run::Bool = false, on_event = nothing, kwargs...)
    on_event === nothing || hasmethod(on_event, Tuple{TestItemEvent}) || throw(ArgumentError(
        "`on_event` must be a function that takes a `Runtests.TestItemEvent`, got $(repr(on_event))"
    ))
    return runtests_impl(Any[args...], name, tags, dry_run, on_event, kwargs_dict(kwargs))
end

# Monomorphic entry behind `runtests`: packs every keyword combination into one compiled
# body so first-call JIT never delays the opening "reading test files..." line.
function runtests_impl(args::Vector{Any}, @nospecialize(name), @nospecialize(tags),
                       dry_run::Bool, @nospecialize(on_event), opts::Dict{Symbol, Any})
    return exclusively() do
        # A dry run says what it found in its own block, with the plan.
        p, target = prepare_impl(args, name, tags, nothing, nothing, !dry_run, dry_run, true, false,
                                 nothing, nothing, opts)
        if dry_run
            print_plan(stdout, p)
            return nothing
        end
        run = execute_impl(p, target, on_event)
        try
            return RunTestSet(report(run))
        finally
            isempty(run.scratch) || rm(run.scratch; force = true, recursive = true)
        end
    end
end

# Everything up to starting a process, so a plan can be inspected, printed or run.
# `announce` prints what is being read and what was found, as it happens.
# `expansions = false` leaves the expansions of templates unchecked, for `chores`,
# which says itself where they stand. `allow_unknown_names` runs the named items the
# suite has and leaves the rest out, for an editor, whose tree can be behind the files.
function prepare(args; name = nothing, tags = nothing, group = nothing, replay = nothing, announce::Bool = true,
                 dry_run::Bool = false, expansions::Bool = true, allow_unknown_names::Bool = false,
                 worker_init = nothing, test_end = nothing, kwargs...)
    return prepare_impl(
        Any[args...], name, tags, group, replay, announce, dry_run, expansions, allow_unknown_names,
        worker_init, test_end, kwargs_dict(kwargs)
    )
end

function prepare_impl(args::Vector{Any}, @nospecialize(name), @nospecialize(tags), @nospecialize(group),
                      @nospecialize(replay), announce::Bool, dry_run::Bool, expansions::Bool,
                      allow_unknown_names::Bool, @nospecialize(worker_init), @nospecialize(test_end),
                      opts::Dict{Symbol, Any})
    kwargs = copy(opts)
    group === nothing && (group = pop!(kwargs, :group, nothing))
    replay === nothing && (replay = pop!(kwargs, :replay, nothing))
    worker_init === nothing && (worker_init = pop!(kwargs, :worker_init, nothing))
    test_end === nothing && (test_end = pop!(kwargs, :test_end, nothing))
    config_arg = pop!(kwargs, :config, nothing)
    # Reject unknown keywords and invalid call values before touching the filesystem,
    # reading run states, printing startup lines, or scanning the test suite.
    validate_call_kwarg(:name, name)
    validate_call_kwarg(:tags, tags)
    validate_call_kwarg(:group, group)
    validate_call_kwarg(:replay, replay)
    validate_call_kwarg(:worker_init, worker_init)
    validate_call_kwarg(:test_end, test_end)
    validate_call_kwarg(:config, config_arg)
    validate_run_kwargs(kwargs; mono = false)
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    named = name !== nothing   # by the caller, not by a replay
    call_kwargs = copy(kwargs)
    # A seed the caller gives is every item's; otherwise a failure runs again with the
    # seed it failed with, and a replayed item with the one it was recorded with.
    seeded = haskey(kwargs, :seed)
    item_seeds = Dict{String, UInt64}()
    rs = replay === nothing ? nothing : read_replay(String(replay), target)
    if rs !== nothing && !seeded
        run_seed = tryparse(UInt64, get(rs.meta, "seed", ""))
        for it in rs.items
            it.seed == run_seed || (item_seeds[it.name] = it.seed)
        end
    end
    !seeded && name isa FailingItems && merge!(item_seeds, name.seeds)
    recorded = nothing         # the items a replay runs again
    if rs !== nothing
        # The items and settings it recorded, under whatever the call says itself. What
        # the call selects narrows the recorded items; the failing items of
        # `runtestsf(replay = …)` are the base's and the later runs', and are not narrowed.
        if !(name isa FailingItems)
            name = recorded = replayed_names((it.name for it in rs.items), name)
            isempty(recorded) && throw(NoTestsError("none of the $(plural(length(rs.items), "test item")) the run state " *
                                                    "recorded matches the name given"))
        end
        for (k, v) in pairs(recorded_settings(rs))
            haskey(kwargs, k) || (kwargs[k] = v)
        end
    end
    # Read before the test files: the group decides what is selected from them.
    config_path, toml = config_toml(target.testdir, config_arg === nothing ? nothing : String(config_arg))
    selected = name !== nothing || tags !== nothing || !isempty(target.paths) || target.line != 0
    filter = Filter(; name, tags, paths = target.paths, line = target.line,
                    group = select_group(read_groups(config_path, toml), config_path, group, selected))
    # Printed and flushed directly: there is no printer yet, and nothing else writes this
    # early. How many of the failing items on record the suite has is known once it is read.
    if announce
        println(
            stdout, label_prefix(), "reading test files under ",
            joinpath(relpath_or_path(target.testdir, target.root), ""),
            name isa FailingItems ? " for the items failing on record" :
                is_full_run(filter, target) ? "" : string(" matching ", describe(filter, target))
        )
        flush(stdout)
    end
    t_files = time()
    setups = setup_modules(target.testdir)
    files, strays, templates, environments = walk_test_dir(target.testdir)
    warn_packages(environments)
    if isempty(files)
        # A stray file, or a template not expanded yet, is the likeliest reason there
        # is nothing to run, so it is what the run says rather than "no test files found".
        errors = copy(strays)
        expansions && append!(errors, expansion_errors(files, templates))
        isempty(errors) || throw(ScanFailure(errors))
        throw(
            NoTestsError(
                "no test files found under $(joinpath(relpath_or_path(target.testdir), "")); test files are " *
                    "named `*_test.jl` or `*_tests.jl` and live under `test/`"
            )
        )
    end
    # Every file, whatever the selection: a broken suite is broken, not smaller.
    suite_names = String[]
    items = scan(files, filter, setups; strays, templates, expansions, suite_names, environments)
    # The failing items on record may all be of items the suite no longer has, which
    # is nothing failing rather than a selection that matched nothing.
    if name isa FailingItems
        in_suite = Set(suite_names)
        present = Set(n for n in name.names if n in in_suite)
        isempty(present) && throw(NothingFailing())
        # What the run says it selected: the failing items the suite has.
        filter = Filter(present, filter.tags, filter.paths, filter.line, filter.group, filter.names_are)
    end
    isempty(items) && throw(NoTestsError("no test items matched " * describe(filter, target) * name_hint(filter.name, suite_names)))
    # One unknown name beside known ones would be left out without a word. A failing
    # item the suite no longer has is left out on purpose.
    if named && recorded === nothing && !allow_unknown_names && !(name isa FailingItems)
        hint = name_hint(filter.name, suite_names)
        isempty(hint) || throw(NoTestsError("not every name given is a test item" * hint))
    end
    gone = recorded === nothing ? String[] : String[repr(n) for n in sort!(collect(setdiff(recorded, suite_names)))]
    changed = rs === nothing ? String[] : String[repr(n) for n in changed_since(rs, items)]
    if announce
        println(
            stdout, label_prefix(), "found ", plural(length(items), "test item"), " in ",
            plural(length(unique(i -> i.file, items)), "file"),
            length(files) == length(unique(i -> i.file, items)) ? "" :
                string(" of ", length(files), " searched"),
            " in ", fmt_seconds(time() - t_files)
        )
        flush(stdout)
    end
    files_seconds = time() - t_files
    t_plan = time()
    hist = history(target.root; base = rs)
    peak_worker_mb, rss_coverage = estimate_worker_rss(items, History[hist])
    cfg = read_config_impl(
        target.testdir, peak_worker_mb, rss_coverage,
        config_arg === nothing ? nothing : String(config_arg), length(items), kwargs
    )
    naming = naming_root(target.root)
    check_skip_environment(cfg.skip_environment, String[rel_slash(dir, naming) for dir in environments], naming,
                           get(kwargs, :skip_environment, nothing) === nothing ? ConfigError : ArgumentError)
    rs === nothing || (cfg = replayed_config(cfg, rs, target.root))
    # After a replay's code too: what the call gives wins.
    call_code!(cfg.profiles, worker_init, test_end)
    merge!(cfg.item_seeds, item_seeds)
    p = plan(
        items, cfg; history = hist, root = target.root,
        selection = is_full_run(filter, target) ? "" : describe(filter, target), suite_names
    )
    if rs !== nothing
        p = apply_recorded_replay!(p, rs, Union{Nothing, RunStateRecord}[rs], call_kwargs;
                                   gone, changed, dry_run, target_project = target.project)
    end
    p.startup.files = files_seconds
    p.startup.plan = time() - t_plan
    return p, target
end

# For a name, or names, that the suite does not have: the nearest it does, since a
# selection that matched nothing is most often a misspelling.
function name_hint(name, suite_names::Vector{String})
    wanted = name isa String ? [name] : name isa Set{String} ? sort!(collect(name)) : String[]
    unknown = [n for n in wanted if !(n in suite_names)]
    isempty(unknown) && return ""
    told = map(unknown) do n
        near = nearest(n, suite_names)
        isempty(near) ? repr(n) : string(repr(n), " (did you mean ", join(repr.(near), " or "), "?)")
    end
    return string("; the suite has no item called ", join(told, ", "))
end

# `replay`: a run state (one downloaded from CI, say) to run again. Only when asked:
# a run state lying next to the project is not a request to run differently.
function read_replay(path::String, target; announce::Bool = true)
    rs = read_run_state(path)
    rs === nothing && throw(ConfigError(
        "could not read a run state from $path: it is missing, damaged, or written by another version of Runtests"
    ))
    id, here = get(rs.meta, "project_id", ""), project_id(target.root)
    id == here || throw(ConfigError("$path records a run of project $(repr(id)), not of this one ($(repr(here)))"))
    m(k) = get(rs.meta, k, "")
    announce && println(
        stdout, label_prefix(), "replaying ", basename(run_location(rs.path)), ": ", plural(length(rs.items), "test item"),
        " · seed ", m("seed"), " · recorded with julia ", m("julia"), " on ", m("machine"),
        isempty(m("revision")) ? "" : string(" at rev ", first(m("revision"), 10)),
        m("worktree") == "dirty" ? " with uncommitted changes" : ""
    )
    return rs
end

# The settings a run state recorded, as `runtests` keywords.
function recorded_settings(rs::RunStateRecord)
    out = Pair{Symbol, Any}[]
    for spec in REPLAY_SPECS
        text = get(rs.meta, string(spec.key), "")
        isempty(text) && continue
        value = try
            parse_replay_setting(spec.replay, text)
        catch
            throw(ConfigError("the run state's `$(spec.key)` setting is unreadable: $(repr(text))"))
        end
        push!(out, spec.key => value)
    end
    return NamedTuple(out)
end

# The recorded profiles in place of this checkout's, each preferences file written
# back out from what was recorded, and the recorded manifest kept for comparison. The
# items' environments are this checkout's, found where their files are, and so is the
# directory a shared profile's `init` ran in, recorded relative to the package at `root`.
function replayed_config(cfg::RunConfig, rs::RunStateRecord, root::AbstractString)
    dirs = Dict{Symbol, String}()
    for line in split(get(rs.meta, "profile_dirs", ""), '\n'; keepempty = false)
        parts = split(line, '\t')
        length(parts) == 2 || throw(ConfigError("the run state's `profile_dirs` is unreadable: $(repr(line))"))
        dir = normpath(joinpath(root, parts[2]))
        dirs[Symbol(parts[1])] = isdirpath(dir) ? dirname(dir) : dir
    end
    profiles = copy(cfg.profiles)
    for (name, prof) in rs.profiles
        prefs = get(rs.preferences, name, "")
        path = isempty(prefs) ? "" : (f = tempname() * ".toml"; write(f, prefs); f)
        # `precompile` from this checkout's configuration, as a run state does not hold it.
        profiles[name] = with_profile(prof; preferences = path, environment = "",
                                      dir = get(dirs, name, ""), precompile = get(cfg.profiles, name, prof).precompile)
    end
    # The order the recording handed its items out in, whatever this checkout's says.
    order_first = String.(split(get(rs.meta, "order_first", ""), '\n'; keepempty = false))
    order_last = String.(split(get(rs.meta, "order_last", ""), '\n'; keepempty = false))
    # Its throttle limits, which bound how many items of each throttle run at once. A
    # record from before throttles has none, and keeps this checkout's.
    throttle = haskey(rs.meta, "throttle") ? recorded_throttle(rs.meta["throttle"]) : cfg.throttle
    # The code its workers compiled, which this process's flags need not match: the
    # recorded flags go first, before each profile's own, as the recorded workers had
    # them from their coordinator.
    recorded = split(get(rs.meta, "julia_flags", ""), ' '; keepempty = false)
    julia_flags = isempty(recorded) || recorded == code_flags() ? String[] : String.(recorded)
    if !isempty(julia_flags)
        for (name, prof) in profiles
            profiles[name] = with_profile(prof; julia_args = [julia_flags; prof.julia_args])
        end
    end
    return with_config(cfg; profiles, julia_flags, order_first, order_last, throttle,
                       replayed_manifest = recorded_manifest(rs), replayed_from = rs.path)
end

# `name=limit` lines, as `run_meta` writes `[throttle]`.
function recorded_throttle(text::AbstractString)
    limits = Dict{Symbol, Int}()
    for line in split(text, '\n'; keepempty = false)
        m = match(r"^([^=]+)=([1-9][0-9]{0,9})$", line)
        m === nothing && throw(ConfigError("the run state's `throttle` is unreadable: $(repr(line))"))
        limits[Symbol(m[1]::AbstractString)] = parse(Int, m[2]::AbstractString)
    end
    return limits
end

"""
    runtests_mono([paths...]; packages, kwargs...)

Run the test suites of several packages of one Julia workspace in one run: one plan,
one set of workers and one report. Items of different packages share workers when
their profiles start workers the same way. Julia 1.12 or later.

The packages are the workspace's members that have a suite, or those that
`packages` of a `[monorepo]` table in `test/TestItems.toml` of the workspace root
lists, by directory or glob, and `isolated` there lists those that run in their own
test environment, on workers of their own. The keyword `packages` narrows them by
name or directory relative to the workspace root. Each package's test project has
to be a member of the workspace. With no `paths`, use the workspace of the active
project, or of `test/runtests.jl` under `Pkg.test`. A path selects within the
package that holds it; the workspace root, a package's root or its `test/` selects
all of it.

Each package's items run under its own profiles, setups and settings. The settings
of the run itself (`workers`, `memory_threshold`, `logs`, `verbose`, `monitor`,
`monitor_interval`, `full_stacktraces`, `full_names`, `testset_name`, `coverage`,
`seed`, `failfast`) come from the call, the `RUNTESTS_` variables and `[run]` of the
workspace root's `test/TestItems.toml`; one in another package's `[run]` has no
effect. The others are each package's own: a keyword or a
variable gives every package its value. `name`, `tags` and `group` select within each
package; a group or tag only some packages have is no error. `config` is an error.
`worker_init` and `test_end` are the code of the default profile of every package, and
the `init` runs in the workspace root, as the `init` of a profile that the workspace
shares does. Also accepts `skip_environment`, `replay`, and `on_event`, as
[`runtests`](@ref) does.

Before any worker starts, a `using` or `import` written in an item, a setup or a
profile's `init` or `test_end` that the package's own test environment could not
load stops the run, as do two packages' setups of one name. Each package gets a run
state of its own, which its `runtestsf`, `debug` and next runs read as one of its own
runs. Returns a [`RunTestSet`](@ref) with a testset for each package, and throws as
[`runtests`](@ref) does when an item did not pass. `workers = 0` can run one selected
package only, because this process holds one test environment. A dry run prints the
combined plan and returns `nothing`.
"""
function runtests_mono(args...; packages = nothing, name = nothing, tags = nothing, dry_run::Bool = false,
                       on_event = nothing, kwargs...)
    on_event === nothing || hasmethod(on_event, Tuple{TestItemEvent}) || throw(ArgumentError(
        "`on_event` must be a function that takes a `Runtests.TestItemEvent`, got $(repr(on_event))"
    ))
    return runtests_mono_impl(Any[args...], packages, name, tags, dry_run, on_event, kwargs_dict(kwargs))
end

function runtests_mono_impl(args::Vector{Any}, @nospecialize(packages), @nospecialize(name), @nospecialize(tags),
                            dry_run::Bool, @nospecialize(on_event), opts::Dict{Symbol, Any})
    return exclusively() do
        r = prepare_mono_impl(args, packages, name, tags, nothing, nothing, nothing, nothing,
                              !dry_run, dry_run, true, nothing, nothing, opts)
        p = r.plan
        # One process holds one test environment.
        p.cfg.workers == 0 && length(p.packages) > 1 && throw(ArgumentError(
            "`workers = 0` runs the items in this process, which holds one package's test environment, and this " *
                "run has $(length(p.packages)) packages: give it one worker or more, or `packages` to run one"
        ))
        if dry_run
            print_plan(stdout, p)
            return nothing
        end
        project = something(project_file(p.root), joinpath(p.root, "Project.toml"))
        run = execute_impl(p, Target(p.root, project, joinpath(p.root, "test"), String[], Int32(0)), on_event)
        try
            return RunTestSet(report(run))
        finally
            isempty(run.scratch) || rm(run.scratch; force = true, recursive = true)
        end
    end
end

"""
    runtestsd(args...; kwargs...)

[`runtests`](@ref) with the group `default` of `[groups]` applied, the whole suite
when `[groups]` declares no `default`. A `name`, `tags` or a path narrows it, as in
`runtests`, and `group` is an error. A call that selects nothing else runs the group
`RUNTESTS_GROUP` names in place of `default`, when it is set, as `runtests` runs it in
place of the whole suite.
"""
runtestsd(args...; kwargs...) = runtests(args...; default_group_kwargs("runtestsd", kwargs)...)

"""
    runtestsd_mono(args...; kwargs...)

[`runtests_mono`](@ref) with the group `default` of each package applied, as
[`runtestsd`](@ref) applies it to one package.
"""
runtestsd_mono(args...; kwargs...) = runtests_mono(args...; default_group_kwargs("runtestsd_mono", kwargs)...)

# The keywords of a call of `caller` with the group `default` among them, which a
# `group` of the call would contradict.
function default_group_kwargs(caller::String, kwargs)
    haskey(kwargs, :group) && throw(ArgumentError(
        "`$caller` runs the group `$DEFAULT_GROUP`, and the call gives `group = $(repr(kwargs[:group]))`: " *
            "call `$(replace(caller, "runtestsd" => "runtests"))` with that group"
    ))
    return (; kwargs..., group = DefaultGroupCall(caller))
end

"""
    runtestsf(paths...; kwargs...)

Run the items whose latest verdict was not a pass. A skip does not replace an
earlier verdict, and a run stopped before reaching an item leaves its verdict
unchanged. Rerunning some failures does not forget the others. Only items still
in the suite run; one renamed or deleted since it failed has nothing to run.
With `replay`, the verdicts come from that run and runs started after it.

Every other selection narrows the failing items: `name` keeps those it matches, as
paths, a `file.jl:line`, `tags` and `group` do, so nothing that is not failing runs.
Each item runs with the seed it failed with, so it draws the random numbers it
failed with, unless `seed` is given.

When no item is failing, it says so and returns `nothing`: running the failures
until there are none is what it is for. A `name` that none of the failing items
matches is an error.
"""
function runtestsf(args...; replay = nothing, name = nothing, kwargs...)
    # Validate all keywords up front so misspelled or invalid kwargs fail even when
    # no item is currently failing and before reading run states.
    validate_call_kwarg(:replay, replay)
    validate_call_kwarg(:name, name)
    validate_run_kwargs(kwargs_dict(kwargs); mono = false, allow_call_keys = true)
    target = resolve_target(args)
    return with_runs_read(() -> run_failing(target, args; replay, name, kwargs...), target.root)
end

# `runtestsf` itself, under its one reading of the run states (`with_runs_read`).
function run_failing(target, args; replay, name, kwargs...)
    base = replay === nothing ? nothing : read_replay(String(replay), target; announce = false)
    # Every item failing on record. The run reads the suite once, and leaves out of
    # these the items it no longer has; reading it here as well doubled the time
    # before the first item.
    facts = failing_facts(target.root; base)
    names = Set(keys(facts))
    nothing_failing() = (println(stdout, label_prefix(), "no test item is failing in the recorded runs",
                                 isempty(runstate_files(target.root)) ? " (no run state found for this project)" : "");
                         nothing)
    isempty(names) && return nothing_failing()
    if name !== nothing
        want = Filter(; name).name
        kept = Set(n for n in names if matches_name(want, n))
        isempty(kept) && throw(NoTestsError(string(
            "none of the ", plural(length(names), "failing item"), " matches name = ", repr(name), ": ",
            join(repr.(first(sort!(collect(names)), 10)), ", "), length(names) > 10 ? ", …" : ""
        )))
        names = kept
    end
    try
        return runtests(args...; name = FailingItems(names, Dict(n => facts[n].seed for n in names)), replay, kwargs...)
    catch e
        e isa NothingFailing || rethrow()
        return nothing_failing()
    end
end

# A package where the suite reads is an environment of the suite, which is seldom what
# it is there for: each says where it belongs.
function warn_packages(environments::Vector{String})
    for (dir, name) in packages_among(environments)
        @warn "Runtests: $(relpath_or_path(dir)) holds the package `$name`. The suite reads it as an environment, " *
            "so its test files run in it. If the tests take it as input, move it to `test/$TESTFIXTURES_DIR/`. " *
            "If it is a test setup, move it to `test/$TESTSETUPS_DIR/`."
    end
    return nothing
end

# Every item's name in the suite, read as a run reads it (`suite_items`).
suite_item_names(target) = Set{String}(it.name for it in suite_items(target))

"""
    Target

Where a run reads from: the project, its `test/` directory, and any narrowing
the caller asked for.
"""
struct Target
    root::String
    project::String
    testdir::String
    paths::Vector{String}   # absolute; empty means "all of testdir"
    line::Int32
end

function resolve_target(args)
    isempty(args) && return target_from_dir(default_search_dir())
    length(args) == 1 && args[1] isa Module && return target_from_dir(_pkgdir(args[1]))
    any(a -> a isa Module, args) && throw(ArgumentError(
        "a module stands for its package's whole suite, so it is given on its own: got $(join(map(repr, args), ", "))"
    ))
    paths = String[]; orig = String[]; line = Int32(0); line_arg = ""
    for a in args
        a isa AbstractString || throw(ArgumentError("Runtests.runtests takes paths or a module, got $(repr(a))"))
        s = a isa String ? a : String(a)::String
        path, ln = split_line_suffix(s)
        ln == 0 || (line = ln; line_arg = s)
        push!(orig, s)
        push!(paths, abspath(path))
    end
    for (a, path) in zip(orig, paths)
        # A name given where a path goes is the likeliest slip: `debug` takes either.
        named = !occursin(r"[/\\]|\.jl", a)
        ispath(path) || throw(ArgumentError(string(
            "no such file or directory: ", path,
            named ? string("; to run the test item called ", repr(a), ", give `name = ", repr(a), "`") : ""
        )))
    end
    t = target_from_dir(isdir(first(paths)) ? first(paths) : dirname(first(paths)))
    # Naming the project or its test directory means "everything": beside other
    # paths too, since several paths select what any of them does.
    whole = false
    narrowing = String[]
    fixtures = joinpath(t.testdir, TESTFIXTURES_DIR)
    configs = joinpath(t.testdir, TESTCONFIGS_DIR)
    for path in paths
        rstrip_path(path) in (rstrip_path(t.root), rstrip_path(t.testdir)) && (whole = true; continue)
        # Under `test/` too: a package kept there, a fixture say, is a suite of its own.
        # In a monorepo, the likeliest path outside `test/` is another package's.
        other = find_project(isdir(path) ? path : dirname(path))
        other === nothing || dirname(other) == t.root || throw(ArgumentError(
            "$(path) belongs to the package at $(dirname(other)), and $(first(paths)) to the one " *
                "at $(t.root): a call runs one package's tests, so give each package a call of its own"
        ))
        startswith(path, joinpath(t.testdir, "")) ||
            throw(ArgumentError("$(path) is not under $(t.testdir); Runtests only reads test files from `test/`"))
        (rstrip_path(path) == fixtures || startswith(path, joinpath(fixtures, ""))) && throw(ArgumentError(
            "$(path) is in $(joinpath(fixtures, "")), which holds input for the tests and is not read as part of " *
                "the suite; a package kept there runs as a suite of its own when a path inside it is given alone"
        ))
        (rstrip_path(path) == configs || startswith(path, joinpath(configs, ""))) && throw(ArgumentError(
            "$(path) is in $(joinpath(configs, "")), which holds the code of the profiles and no test items"
        ))
        isdir(path) || is_test_file(path) || throw(
            ArgumentError(
                "$(path) is not a test file; test files are named `*_test.jl` or `*_tests.jl`"
            )
        )
        path in narrowing || push!(narrowing, path)
    end
    # The line picks one item, the last to start at or above it among those the paths
    # select: beside another file or directory, it could pick one there.
    line == 0 || (length(narrowing) == 1 && !whole) || throw(ArgumentError(
        "a `file.jl:line` target picks the item at that line, so it is given without other " *
        "files or directories: got $(join(map(repr, args), ", "))"
    ))
    line == 0 || check_target_line(only(narrowing), line, line_arg, t.root)
    return Target(t.root, t.project, t.testdir, whole ? String[] : narrowing, line)
end

# A `file.jl:line` target (`arg`) names a line that `file` has.
function check_target_line(file::AbstractString, line::Integer, arg::AbstractString, root::AbstractString)
    n = countlines(file)
    line <= n || throw(ArgumentError(
        "`$arg`: $(relpath_or_path(file, root)) has $(plural(n, "line")), so there is no line $line"
    ))
    return nothing
end

rstrip_path(p::AbstractString) = rstrip(p, PATH_SEPARATORS)

function _pkgdir(m::Module)
    dir = pkgdir(m)
    dir === nothing && throw(ArgumentError("could not find a directory for module $m"))
    return dir
end

function split_line_suffix(path::AbstractString)
    m = match(r"^(.*\.jl):(\d+)$", path)
    m === nothing && return String(path), Int32(0)
    # Neither group is optional, so a match has both.
    # Too large to be a line is past the end of any file, which is said as such.
    line = something(tryparse(Int32, m[2]::AbstractString), typemax(Int32))
    line == 0 && throw(ArgumentError("`$path`: lines are numbered from 1"))
    return String(m[1]::AbstractString), line
end

# The items of `items` whose source differs from what run state `rs` recorded of them,
# by the hash of each: a replay runs them as the checkout has them, so that a fix can be
# checked against the run that failed, and says so once.
function changed_since(rs::RunStateRecord, items)
    recorded = Dict(it.name => it.hash for it in rs.items)
    return sort!([it.name for it in items if (h = get(recorded, it.name, UInt32(0))) != 0 && h != it.hash])
end

# At most twenty of `names`, and how many more there are.
listed(names) = join(first(names, 20), ", ") * (length(names) > 20 ? string(", and ", length(names) - 20, " more") : "")

# The items a replay runs: those its run state recorded, narrowed by a `name` the call
# gives. Tags, a group and paths narrow them as they narrow any run.
replayed_names(recorded, name) = name === nothing ? Set{String}(recorded) :
    (want = Filter(; name).name; Set{String}(n for n in recorded if matches_name(want, n)))

# Not the active project: under `Pkg.test` that is a temporary environment, and the
# package is where the `runtests.jl` being evaluated is; after `activate`, it is the
# package's generated test environment, and the package is the one activated.
function default_search_dir()
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    if source !== nothing && basename(String(source)) == "runtests.jl"
        return dirname(abspath(String(source)))
    end
    # A package that `activate` readied: the active project is its generated test
    # environment now, not the package.
    state = ACTIVATION[]
    state === nothing || state.participants !== nothing || return state.target.root
    proj = Base.active_project()
    return proj === nothing ? pwd() : dirname(proj)
end

function target_from_dir(dir::AbstractString)
    project = find_project(abspath(dir))
    project === nothing && throw(
        ArgumentError(
            "could not find a Project.toml at or above $(abspath(dir))"
        )
    )
    root = dirname(project)
    return Target(root, project, joinpath(root, "test"), String[], Int32(0))
end

const PROJECT_NAMES = ("Project.toml", "JuliaProject.toml")

function find_project(dir::AbstractString)
    # `test/` has its own Project.toml, which is an environment and not a project
    # root, so a path inside it must keep walking up, as must one inside another
    # environment of the tests.
    while true
        if basename(dir) != "test"
            for n in PROJECT_NAMES
                p = joinpath(dir, n)
                isfile(p) && !is_test_environment(dir, p) && return p
            end
        end
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
    return
end

# Whether `dir`, whose project file is `p`, is an environment of a package's tests
# rather than a project of its own: a directory under the package's `test/` whose
# project declares no package, or whose test files run in it (see `walk_test_dir`).
# A package kept where the suite does not read, in `test/testfixtures/` as a fixture
# is, in `test/testsetups/` as a setup is, or in a hidden directory, is a project of
# its own.
function is_test_environment(dir::AbstractString, p::AbstractString)
    testdir = dirname(rstrip_path(dir))
    while basename(testdir) != "test"
        parent = dirname(testdir)
        parent == testdir && return false
        testdir = parent
    end
    project_file(dirname(testdir)) === nothing && return false
    project_name_of(p) === nothing && return true
    return suite_reads(testdir, rstrip_path(dir))
end

# A run of a group is not of the whole suite, its default group's included: what a
# run of the whole suite does not find, a later one takes for renamed or deleted.
is_full_run(f::Filter, t::Target) =
    f.name === nothing && f.tags === nothing && f.group === nothing && f.line == 0 && isempty(t.paths)

function describe(f::Filter, t::Target)
    parts = String[]
    f.name === nothing || push!(parts, f.name isa Set ? plural(length(f.name), f.names_are) : "name = $(repr(f.name))")
    f.tags === nothing || push!(parts, "tags = $(f.tags)")
    f.group === nothing || push!(parts, "group `$(f.group.name)` = $(repr(f.group.tags.text)), $(f.group.source)")
    f.line == 0 || push!(parts, "line $(f.line)")
    isempty(t.paths) || push!(parts, "paths " * join(map(p -> relpath_or_path(p, t.root), t.paths), ", "))
    return isempty(parts) ? "the filter" : join(parts, " and ")
end

include("dispatch.jl")
include("logs.jl")

using PrecompileTools: @setup_workload, @compile_workload

# The paths a run takes that the workload below cannot take for it: starting a
# worker starts a process during the build, and running an item evaluates code
# into `Main`, which makes Julia warn that incremental compilation may be broken.
# `with_test_env` takes a closure and has no concrete signature to name.
const PRECOMPILE_SIGNATURES = (
    (test_env, (Target,)),
    (resolve_target, (Tuple{String},)),
    (resolve_target, (Vector{Any},)),
    (runtests, ()),
    (runtests, (String,)),
    (runtests_impl, (Vector{Any}, Nothing, Nothing, Bool, Nothing, Dict{Symbol, Any})),
    (prepare, (Tuple{String},)),
    (runtests_mono, ()),
    (runtests_mono, (String,)),
    (runtests_mono_impl, (Vector{Any}, Nothing, Nothing, Nothing, Bool, Nothing, Dict{Symbol, Any})),
    (prepare_mono_impl, (Vector{Any}, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing,
                         Bool, Bool, Bool, Nothing, Nothing, Dict{Symbol, Any})),
    (find_participants, (String,)),
    (find_participants_impl, (String, Nothing)),
    (find_participants_impl, (String, Vector{String})),
    (workspace_disk_instantiated, (String,)),
    (mono_groups, (Vector{Dict{String, TagExpr}}, Vector{String}, Nothing, Bool)),
    (read_config_impl, (String, Float64, Float64, Nothing, Int, Dict{Symbol, Any})),
    (build_config_impl, (String, Dict{String, Any}, Float64, Float64, Int, String, String,
                         Nothing, Nothing, Dict{Symbol, Any})),
    (execute_impl, (Plan, Target, Nothing)),
    (start_monitor!, (Monitor,)),
    (monitor_loop, (Monitor,)),
    (_open_runstate, (Plan, Float64, String, Vector{String})),
    (open_runstate_set_impl, (Plan, Float64, String, String, Vector{Vector{String}})),
    (path_dep_stamps_match, (Vector{Any},)),
    (circular_packages, (Dict{Base.PkgId, Vector{Base.PkgId}},)),
    (add_job!, (PrecompileQueue, JobKey, QueueJob)),
    (queue_order!, (Vector{QueueJob},)),
    (note_start!, (Queues, SlotIdx, Float64)),
    (start_worker, (Run, Slot, Bool)),
    (relay!, (Run, Slot, RelayState, String)),
    (worker_ended!, (Run, SlotIdx, RuntestsWorkers.Worker)),
    (close_relay_log!, (RelayState,)),
    (complete_attempt!, (Run, Slot, ItemIdx, Int8, Int, RuntestsWorkers.ItemSpec, RuntestsWorkers.ItemResult,
                         RuntestsWorkers.Worker, Float32, Int32, SlotIdx)),
    (report, (Run,)),
    (Test.print_test_results, (Base.TTY, Test.DefaultTestSet, Int)),
    (Test.print_test_results, (Base.PipeEndpoint, Test.DefaultTestSet, Int)),
    (run_on_workers, (Run,)),
    (run_slot, (Run, Slot)),
    (logs, (String,)),
    (logs_impl, (IOContext{IOBuffer}, String, Nothing, Bool, Int)),
    (report_unfinished_run, ()),
)

# Everything between `runtests()` and the first test item: reading, configuring,
# planning and the shapes the run prints; and `chores` but for expanding templates.
# On a 2,000-item suite the first takes 2.3 s uncompiled and 0.04 s compiled, paid
# before anything appears on screen.
@setup_workload begin
    source = """
    @testitem "precompile one" tags=[:a] timeout=60 begin
        using Test
        using PrecompileSetup
        @test true
    end
    @testitem "precompile two" throttle=:c retries=1 begin
        @test true
    end
    """
    # A real directory, because the run reads real directories: the walk, the
    # parallel scan and the TOML are each their own pile of code.
    dir = mktempdir()
    mkpath(joinpath(dir, "test"))
    write(joinpath(dir, "Project.toml"), "name = \"Precompile\"\nuuid = \"1a2b3c4d-0000-4000-8000-00000000000f\"\n")
    write(joinpath(dir, "test", "precompile_test.jl"), source)
    write(joinpath(dir, "test", "TestItems.toml"), "[run]\nworkers = 2\n")
    testdir = joinpath(dir, "test")
    # A setup as `chores` leaves one, a package whose `[deps]` hold what it imports.
    setup = mkpath(joinpath(testdir, TESTSETUPS_DIR, "PrecompileSetup", "src"))
    write(joinpath(setup, "PrecompileSetup.jl"), "module PrecompileSetup\nusing Test\nend\n")
    write(joinpath(dirname(setup), "Project.toml"), "name = \"PrecompileSetup\"\n" *
          "uuid = \"1a2b3c4d-0000-4000-8000-0000000000f0\"\n\n[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n")
    # A template and its expansion, as `chores` would have written it: every run checks
    # the stamp, and expanding would evaluate code, which a workload must not.
    template = joinpath(mkpath(joinpath(testdir, TESTTEMPLATES_DIR)), "precompile_tests_template.jl")
    template_source = "@testtemplate \"precompile three \$n\" skip = \$(n > 2) for n in 1:2\n    @test \$n > 0\nend\n"
    write(template, template_source)
    @compile_workload begin
        instances = Dict{String, Any}[]
        for n in 1:2
            d = Dict{String, Any}()
            d["name"] = "precompile three $n"
            d["values"] = [["n", string(n)]]
            d["computed"] = [["n > 2", "false"]]
            push!(instances, d)
        end
        tpl_item = Dict{String, Any}()
        tpl_item["line"] = 1
        tpl_item["instances"] = instances
        write_whole(expansion_of(template), render_expansion(template, template_source, Dict{String, Any}[tpl_item]))
        # Exercise the opening `prepare_impl` path so the first log line prints
        # without first-call compilation delay, and reuse its plan below instead of
        # scanning and planning the fixture twice.
        p = withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            redirect_stdout(devnull) do
                res = prepare_impl(Any[dir], nothing, nothing, nothing, nothing, true, false, true, false,
                                   nothing, nothing, Dict{Symbol, Any}(:monitor => false))
                prepare_impl(Any[joinpath(testdir, "precompile_test.jl")], nothing, :a, nothing, nothing,
                             true, false, true, false, nothing, nothing, Dict{Symbol, Any}(:workers => 2))
                first(res)
            end
        end
        print_plan(devnull, p)
        Queues(p); Statuses(nitems(p))
        Filter(; name = "precompile one", line = Int32(0))
        sortperm_stable(Tuple{Float64, String}[(1.0, "a"), (2.0, "b")]; rev = false)
        path_dep_stamps_match(Any[Any["Pkg", "1", "1:00000000"]])
        Logging.min_enabled_level(RunLogger(Logging.ConsoleLogger(devnull), nothing))

        # The run state, written before the first item starts and read by the run
        # after this one.
        statepath = joinpath(dir, string("precompile", RUNDATA_EXT), RUNSTATE_FILE)
        rsf = init_run_state(statepath, p)
        write_status!(rsf, 1, RUNNING, 1, 1)
        write_status!(rsf, 1, PASSED, 1, 1; elapsed = 0.1, compile = 0.05)
        append_event!(rsf, EVENT_ATTEMPT, UInt8(PASSED), 1, 1, 0.1, 0.2; item = 1, attempt = 1)
        append_event!(rsf, EVENT_WORKER_UP, 0, SlotIdx(1), 1, 0.1, 0.2)
        write_memory!(rsf, MemStats())
        finish_run_state!(rsf)
        read_run_state(statepath)
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            history(dir)
        end

        # The shapes a run prints. The first three run once per field of the
        # progress line, which is redrawn after every line the run writes.
        buf = IOBuffer()
        print_bytes(buf, 3.5 * 2^30, BYTES_WIDTH)
        print_bytes(buf, 512 * 2^20, TOTAL_WIDTH)
        print_1dp(buf, 2.5, 4)
        print_int(buf, 42, 4)
        item_line(1, 1, 2, "\"an item\"", 12, 1, 1, "a_test.jl:1")
        item_line(1, 1, 2, "\"an item\"", 12, 2, 2, (; state = PASSED, elapsed_ns = 1, compile_ns = 0, maxrss = 1))
        parse_record(string(RuntestsWorkers.RECORD_MARK, "DONE 1 1 2 3 4 5"))
        item_log_path("/precompile/item_", 1, 1)
        bracket("a line\nanother", "[1/2] FAIL", "\"an item\"", "@ a_test.jl:1", :red)
        fmt_seconds(0.5); plural(2, "worker"); plural(1, "process", "processes")

        # What an editor asks for first: the listing, as JSON, and a command read.
        json(list_items(dir))
        read_json("{\"id\":1,\"command\":\"run\",\"names\":[\"precompile one\"],\"options\":{\"workers\":2}}")

        # `chores` on a suite with nothing to do, the common case: checking it, then
        # doing it, without the template, whose expanding would start a process.
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            redirect_stdout(() -> chores(dir; dry_run = true), devnull)
            rm(template); rm(expansion_of(template))
            redirect_stdout(() -> chores(dir), devnull)
        end
    end
    rm(dir; force = true, recursive = true)
    for (f, types) in PRECOMPILE_SIGNATURES
        RuntestsWorkers.precompile_or_throw(f, types)
    end
end

end # module Private

using Test
using .Private: @testitem, @testtemplate, runtests, runtestsd, runtestsf, runtests_dispatch, logs,
    runtests_mono, runtestsd_mono, runtests_dispatch_mono, chores_mono, activate_mono, current_testitem,
    serve_mono,
    on_failure, artifacts_dir, activate, deactivate, is_activated, debug, setups_to_packages, chores, serve,
    ConfigError, ChoresError, NoTestsError, ScanFailure, RunTestSet, read_run_state, TestItemEvent

export @testitem, @testtemplate, runtests, runtestsd, runtestsf, runtests_dispatch, chores,
    runtests_mono, runtestsd_mono, runtests_dispatch_mono, chores_mono

# Re-exported, so `using Runtests` alone gives a script or the REPL `@test`, `@testset`
# and the rest of `Test`'s macros; anything else of it is reached as `Test.X`. A test
# item's body does not need them: it is handed `Test` directly.
export Test
for name in names(Test)
    startswith(string(name), "@") && @eval export $name
end

public activate_mono, serve_mono, current_testitem, on_failure, artifacts_dir, logs,
    activate, deactivate, is_activated, debug, setups_to_packages, serve,
    ConfigError, ChoresError, NoTestsError, ScanFailure, RunTestSet, read_run_state, TestItemEvent

end # module Runtests
