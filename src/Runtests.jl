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
"""
module Runtests

"""
    Runtests.Private

Everything but the public API, which `Runtests` takes from here by name. `Runtests.<tab>`
offers every name `Runtests` itself defines, and the public API is what it should offer.
"""
module Private

using Base.ScopedValues: ScopedValue, with
using Logging: Logging, with_logger, current_logger
using Pkg: Pkg
using Random: Random, RandomDevice
using Test
using Test: Test
using TestEnv: TestEnv
using TOML: TOML

# The worker side is a package of its own, so a worker loads the protocol and the
# item runner and nothing else.
using RuntestsWorkers: RuntestsWorkers, ItemState, UNSEEN, RUNNING, PASSED, FAILED, ERRORED, TIMEDOUT,
    SKIPPED, BROKEN_CHAIN, CANCELLED, is_non_pass, ItemSpec, ItemResult,
    current_testitem, in_testitem, in_test_run, run_item,
    with_testset_printing, without_enclosing_testset, PATHSEP, is_interrupt, shielded, RECORD_MARK

include("types.jl")
include("json.jl")
include("macros.jl")
include("scan.jl")
include("config.jl")
include("plan.jl")
include("runstate.jl")
include("report.jl")
include("platform.jl")
include("monitor.jl")
include("coverage.jl")
include("editor.jl")
include("execute.jl")
include("interactive.jl")
include("debug.jl")
include("setup_packages.jl")
include("expander.jl")
include("templates.jl")
include("chores.jl")

"""
    runtests([paths...]; kwargs...)

Run the test items under `test/`. With no arguments, the project of the active
environment is used.

`paths` narrow what is read: a directory, a test file, or `file.jl:42` to select
the item that line is inside, which is given without other files or directories.

Returns the run's testset, a [`RunTestSet`](@ref) named `testset_name` (`"Runtests"`
unless given), holding one testset per test file. Inside an enclosing `@testset`
it is recorded there, so the runs of several calls add up under one, told apart by
their names. Outside any, an item that did not pass makes the call throw, which is
what fails `Pkg.test`. A dry run returns `nothing`.

A process holds one run at a time: a call made while another is running, from
another task or thread, throws and leaves that run going.

# Keywords

Selection: `name` (`String` for an exact match, `Regex` for a partial one, or a
set of exact names), `tags` (a symbol or vector of symbols an item must carry
all of, or a string expression such as `"!slow"` or `"juliac || serializer"`; a tag
no item carries is an error), and `group` (the name of a tag expression `[groups]` of
`test/TestItems.toml` declares; also `RUNTESTS_GROUP`, which the keyword overrides).
A run that selects nothing else selects the group named `default`, when there is
one, and `group = "all"` is the whole suite. Selections narrow together.

Execution: `workers` (a count, or `0` to run in this process), `threads`,
`timeout`, `init_timeout` and `test_end_timeout` (a profile's `init` and `test_end`
expressions are timed separately from the items, and default to `timeout`),
`retries`, `failfast`, `memory_threshold`, `full_stacktraces` (keep the
framework's own frames in a failing item's stacktrace; trimmed by default), `seed`
(every item draws its random numbers from this and its own name; random unless
given, and printed at the start of the run).

Output: `logs` (`:issues`, `:batched`, `:eager`), `verbose`,
`monitor`, `monitor_interval`, `testset_name`, `coverage` (count which lines of
`src/` and `ext/` the workers run, merged into `lcov.info` at the package's root;
also `RUNTESTS_COVERAGE`, which a keyword overrides and which overrides the file).

State: `dry_run` prints the plan and runs nothing. `replay` names a run state (one
downloaded from CI, say) and runs it again: the same items, settings, profiles
and seed, with any keyword given here winning, and a warning naming each package
whose version differs from the one recorded.

Every keyword can also be set in `test/TestItems.toml`, which additionally
declares sandbox profiles and forced ordering; an explicit keyword wins. `config`
names another file to read in its place, relative to the current directory, which
has to exist; nothing but this keyword makes a run read one.
"""
function runtests(args...; name = nothing, tags = nothing, dry_run::Bool = false, kwargs...)
    return exclusively() do
        # A dry run says what it found in its own block, with the plan.
        p, target = prepare(args; name, tags, announce = !dry_run, kwargs...)
        if dry_run
            print_plan(stdout, p)
            return nothing
        end
        run = execute(p, target)
        try
            return RunTestSet(report(run))
        finally
            rm(run.logdir; force = true, recursive = true)
        end
    end
end

# Everything up to starting a process, so a plan can be inspected, printed or run.
# `announce` prints what is being read and what was found, as it happens.
# `expansions = false` leaves the expansions of templates unchecked, for `chores`,
# which says itself where they stand.
function prepare(args; name = nothing, tags = nothing, group = nothing, replay = nothing, announce::Bool = true,
                 expansions::Bool = true, kwargs...)
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    rs = replay === nothing ? nothing : read_replay(String(replay), target)
    if rs !== nothing
        # The items and settings it recorded, under whatever the call says itself.
        selected = name !== nothing || tags !== nothing || group !== nothing || !isempty(target.paths) || target.line != 0
        selected || (name = Set(it.name for it in rs.items))
        kwargs = merge(recorded_settings(rs), kwargs)
    end
    # Read before the test files: which directories the profiles' environments are
    # decides which files are read, and the group what is selected from them.
    config_path, toml = config_toml(target.testdir, get(kwargs, :config, nothing))
    claimed = claimed_environments(config_path, toml)
    selected = name !== nothing || tags !== nothing || !isempty(target.paths) || target.line != 0
    filter = Filter(; name, tags, paths = target.paths, line = target.line,
                    group = select_group(read_groups(config_path, toml), config_path, group, selected))
    setups = setup_modules(target.testdir)
    # Printed directly: there is no printer yet, and nothing else writes this early.
    announce && println(
        stdout, label_prefix(), "reading test files under ",
        relpath_or_path(target.testdir, target.root),
        is_full_run(filter, target) ? "" : string(" matching ", describe(filter, target))
    )
    t_files = time()
    walked = walk_test_dir(target.testdir; claimed)
    for path in target.paths, (dir, _) in walked.unclaimed
        (rstrip_path(path) == dir || startswith(path, joinpath(dir, ""))) && throw(NoTestsError(string(
            relpath_or_path(path, target.root), " is in ", relpath_or_path(dir, target.root),
            ", which has an environment of its own; a profile with `environment = ",
            repr(relpath_or_path(dir, target.testdir)), "` runs the tests there"
        )))
    end
    files, strays, templates = walked.tests, walked.strays, walked.templates
    if isempty(files)
        # A stray file, or a template not expanded yet, is the likeliest reason there
        # is nothing to run, so it is what the run says rather than "no test files found".
        errors = copy(strays)
        expansions && append!(errors, expansion_errors(files, templates))
        isempty(errors) || throw(ScanFailure(errors))
        throw(
            NoTestsError(
                "no test files found under $(relpath_or_path(target.testdir)); test files are " *
                    "named `*_test.jl` or `*_tests.jl` and live under `test/`"
            )
        )
    end
    # Every file, whatever the selection: a broken suite is broken, not smaller.
    suite_names = String[]
    items = scan(files, filter, setups; strays, templates, expansions, suite_names, claimed)
    isempty(items) && throw(NoTestsError("no test items matched " * describe(filter, target)))
    announce && println(
        stdout, label_prefix(), "found ", plural(length(items), "test item"), " in ",
        plural(length(unique(i -> i.file, items)), "file"),
        length(files) == length(unique(i -> i.file, items)) ? "" :
            string(" of ", length(files), " searched"),
        " in ", fmt_seconds(time() - t_files)
    )
    files_seconds = time() - t_files
    t_plan = time()
    cfg = read_config(target.testdir; nunits = length(items), kwargs...)
    rs === nothing || (cfg = replayed_config(cfg, rs, target.root))
    p = plan(
        items, cfg; history = history(target.root; base = rs), root = target.root,
        strict_order = is_full_run(filter, target),
        selection = is_full_run(filter, target) ? "" : describe(filter, target), suite_names,
        unclaimed = walked.unclaimed
    )
    p.startup.files = files_seconds
    p.startup.plan = time() - t_plan
    return p, target
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
        stdout, label_prefix(), "replaying ", basename(path), ": ", plural(length(rs.items), "test item"),
        " · seed ", m("seed"), " · recorded with julia ", m("julia"), " on ", m("machine"),
        isempty(m("revision")) ? "" : string(" at rev ", first(m("revision"), 10))
    )
    return rs
end

# The settings a run state recorded, as `runtests` keywords.
function recorded_settings(rs::RunStateRecord)
    out = Pair{Symbol, Any}[]
    for (key, parse_) in REPLAYED_SETTINGS
        text = get(rs.meta, string(key), "")
        isempty(text) && continue
        value = try
            parse_(text)
        catch
            throw(ConfigError("the run state's `$key` setting is unreadable: $(repr(text))"))
        end
        push!(out, key => value)
    end
    return NamedTuple(out)
end

# The recorded profiles in place of this checkout's, each preferences file written
# back out from what was recorded, each environment found in this checkout, under
# `root`, where the recording's was in its own, and the recorded manifest kept for
# comparison.
function replayed_config(cfg::RunConfig, rs::RunStateRecord, root::AbstractString)
    profiles = copy(cfg.profiles)
    for (name, prof) in rs.profiles
        prefs = get(rs.preferences, name, "")
        path = isempty(prefs) ? "" : (f = tempname() * ".toml"; write(f, prefs); f)
        env = isempty(prof.environment) || isabspath(prof.environment) ? prof.environment :
            normpath(joinpath(root, prof.environment))
        isempty(env) || isdir(env) || throw(ConfigError(
            "the run state's profile `$name` runs in $(prof.environment), which this checkout does not have"
        ))
        profiles[name] = Profile(prof.name, prof.julia_args, prof.threads, prof.env, prof.init, prof.test_end, path, env)
    end
    fields = NamedTuple{fieldnames(RunConfig)}(ntuple(i -> getfield(cfg, i), fieldcount(RunConfig)))
    return RunConfig(; merge(fields, (; profiles, replayed_manifest = recorded_manifest(rs),
                                        replayed_from = rs.path))...)
end

"""
    runtestsf(paths...; kwargs...)

Run the items that are failing: those whose last verdict, in the last run that ran
them to one, was not a pass. Each item keeps its own, so running some of one run's
failures again does not forget the others, and a run stopped before it reached an
item leaves that item's verdict as it was. Only items the suite still has run: one
renamed or deleted since it failed has nothing to run. With `replay`, the verdicts
are that run's and those of the runs that started after it. See
[`failing_items`](@ref).
"""
function runtestsf(args...; replay = nothing, kwargs...)
    target = resolve_target(args)
    base = replay === nothing ? nothing : read_replay(String(replay), target; announce = false)
    names = Set(failing_items(target.root; names = suite_item_names(target; config = get(kwargs, :config, nothing)), base))
    isempty(names) && throw(
        NoTestsError(
            "no test item is failing in the recorded runs" *
                (isempty(runstate_files(target.root)) ? " (no run state found for this project)" : "")
        )
    )
    println(
        stdout, label_prefix(), "running ", plural(length(names), "failing item")
    )
    return runtests(args...; name = names, replay, kwargs...)
end

# Every item's name in the suite, read as a run reads it, the environments profiles
# name included: a suite that does not parse throws here as it would there.
function suite_item_names(target; config = nothing)
    claimed = claimed_environments(config_toml(target.testdir, config)...)
    files, strays, templates = walk_test_dir(target.testdir; claimed)
    names = String[]
    scan(files, Filter(), setup_modules(target.testdir); strays, templates, suite_names = names, claimed)
    return Set(names)
end

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
    paths = String[]; line = Int32(0)
    for a in args
        a isa AbstractString || throw(ArgumentError("Runtests.runtests takes paths or a module, got $(repr(a))"))
        path, ln = split_line_suffix(String(a))
        ln == 0 || (line = ln)
        push!(paths, abspath(path))
    end
    for path in paths
        ispath(path) || throw(ArgumentError("no such file or directory: $path"))
    end
    t = target_from_dir(isdir(first(paths)) ? first(paths) : dirname(first(paths)))
    # Naming the project or its test directory means "everything", not a narrowing.
    narrowing = String[]
    for path in paths
        rstrip_path(path) in (rstrip_path(t.root), rstrip_path(t.testdir)) && continue
        if !startswith(path, joinpath(t.testdir, ""))
            # In a monorepo, the likeliest path outside `test/` is another package's.
            other = find_project(isdir(path) ? path : dirname(path))
            other === nothing || dirname(other) == t.root || throw(ArgumentError(
                "$(path) belongs to the package at $(dirname(other)), and $(first(paths)) to the one " *
                    "at $(t.root): a call runs one package's tests, so give each package a call of its own"
            ))
            throw(ArgumentError("$(path) is not under $(t.testdir); Runtests only reads test files from `test/`"))
        end
        isdir(path) || is_test_file(path) || throw(
            ArgumentError(
                "$(path) is not a test file; test files are named `*_test.jl` or `*_tests.jl`"
            )
        )
        push!(narrowing, path)
    end
    # The line picks one item, the last to start at or above it among those the paths
    # select: beside another file or directory, it could pick one there.
    line == 0 || length(narrowing) == 1 || throw(ArgumentError(
        "a `file.jl:line` target picks the item at that line, so it is given without other " *
        "files or directories: got $(join(map(repr, args), ", "))"
    ))
    return Target(t.root, t.project, t.testdir, narrowing, line)
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
    return String(m[1]::AbstractString), parse(Int32, m[2]::AbstractString)
end

# Not the active project: under `Pkg.test` that is a temporary environment, and the
# package is where the `runtests.jl` being evaluated is.
function default_search_dir()
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    if source !== nothing && basename(String(source)) == "runtests.jl"
        return dirname(abspath(String(source)))
    end
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
# project declares no package, or that a profile of the package names as its
# `environment`. A package kept under `test/`, as a fixture is, is a project.
function is_test_environment(dir::AbstractString, p::AbstractString)
    testdir = dirname(rstrip_path(dir))
    while basename(testdir) != "test"
        parent = dirname(testdir)
        parent == testdir && return false
        testdir = parent
    end
    project_file_in(dirname(testdir)) === nothing && return false
    project_name_of(p) === nothing && return true
    return haskey(claimed_environments(config_toml(testdir, nothing)...), rstrip_path(dir))
end

# A run of a group is not of the whole suite, its default group's included: what a
# run of the whole suite does not find, a later one takes for renamed or deleted.
is_full_run(f::Filter, t::Target) =
    f.name === nothing && f.tags === nothing && f.group === nothing && f.line == 0 && isempty(t.paths)

function describe(f::Filter, t::Target)
    parts = String[]
    f.name === nothing || push!(parts, f.name isa Set ? plural(length(f.name), "named item") : "name = $(repr(f.name))")
    f.tags === nothing || push!(parts, "tags = $(f.tags)")
    f.group === nothing || push!(parts, "group `$(f.group.name)` = $(repr(f.group.tags.text)), $(f.group.source)")
    f.line == 0 || push!(parts, "line $(f.line)")
    isempty(t.paths) || push!(parts, "paths " * join(map(p -> relpath_or_path(p, t.root), t.paths), ", "))
    return isempty(parts) ? "the filter" : join(parts, " and ")
end

using PrecompileTools: @setup_workload, @compile_workload

# The paths a run takes that the workload below cannot take for it: starting a
# worker starts a process during the build, and running an item evaluates code
# into `Main`, which makes Julia warn that incremental compilation may be broken.
# `with_test_env` takes a closure and has no concrete signature to name.
const PRECOMPILE_SIGNATURES = (
    (test_env, (Target,)),
    (resolve_target, (Tuple{String},)),
    (prepare, (Tuple{String},)),
    (execute, (Plan, Target)),
    (report, (Run,)),
    (run_on_workers, (Run, Target)),
    (run_slot, (Run, Slot, Target)),
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
    @testitem "precompile two" chain=:c retries=1 begin
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
        instances = [Dict{String, Any}("name" => "precompile three $n", "values" => [["n", string(n)]],
                                       "computed" => [["n > 2", "false"]]) for n in 1:2]
        write_whole(expansion_of(template), render_expansion(template, template_source,
            [Dict{String, Any}("line" => 1, "instances" => instances)]))
        files, strays, templates = walk_test_dir(testdir)
        setups = setup_modules(testdir)
        items = scan(files, Filter(), setups; ntasks = 2, strays, templates)
        scan(files, Filter(name = "precompile one"), setups; ntasks = 1)
        cfg = read_config(testdir; nunits = length(items), monitor = false)
        p = plan(items, cfg; history = history(dir), root = dir)
        print_plan(devnull, p)
        Queues(p); Statuses(nitems(p))

        # The run state, written before the first item starts and read by the run
        # after this one.
        statepath = joinpath(dir, "precompile.runstate")
        rsf = init_run_state(statepath, p)
        write_status!(rsf, 1, RUNNING, 1, 1)
        write_status!(rsf, 1, PASSED, 1, 1; elapsed = 0.1, compile = 0.05)
        append_event!(rsf, EVENT_ATTEMPT, UInt8(PASSED), 1, 1, 0.1, 0.2; item = 1, attempt = 1)
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
using .Private: @testitem, @testtemplate, runtests, runtestsf, current_testitem, in_testitem, in_test_run,
    activate, deactivate, is_activated, debug, setups_to_packages, chores, serve,
    ConfigError, ChoresError, NoTestsError, ScanFailure, RunTestSet, read_run_state

export @testitem, @testtemplate, runtests, runtestsf, chores

# Re-exported, so `using Runtests` alone gives a script or the REPL `@test`, `@testset`
# and the rest of `Test`'s macros; anything else of it is reached as `Test.X`. A test
# item's body does not need them: it is handed `Test` directly.
export Test
for name in names(Test)
    startswith(string(name), "@") && @eval export $name
end

public current_testitem, in_testitem, in_test_run,
    activate, deactivate, is_activated, debug, setups_to_packages, serve,
    ConfigError, ChoresError, NoTestsError, ScanFailure, RunTestSet, read_run_state

end # module Runtests
