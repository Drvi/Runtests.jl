# A suite's upkeep in one call: what a run would refuse to start on, setups whose
# packages have fallen behind what they import, templates to expand, and run states
# nothing reads.

"""
    chores([path]; dry_run = false, config = nothing)

Look after a package's suite: do what needs no person, then say what does.

- test items and `test/TestItems.toml`: everything a run would refuse to start on,
  such as a syntax error, a name declared twice, a setting it does not accept, an
  `[order]` entry naming no item or an unknown profile. Reported, never changed.
- config files given as `config`, a path or several, relative to the current
  directory: each checked as a run given it would check it, as well as
  `test/TestItems.toml`.
- test setups: what [`setups_to_packages`](@ref) would do, making packages of the
  setups that are not and adding to their `[deps]` what they have come to import.
- test templates: each `*_test_template.jl` or `*_tests_template.jl` under
  `test/testtemplates/` expanded into a test file in `test/`, in a process with
  the test environment. An expansion whose template is gone is deleted. Every
  template is expanded because its computed inputs can change without a source
  edit; a dry run checks expansion stamps and runs no templates. An expansion
  edited by hand, or a test file in a template's way that `chores` did not write,
  is left to a person.
- run states: this machine's are pruned as a run prunes them, with their logs. One
  recorded elsewhere, a CI artifact say, and one that cannot be read are never deleted.
- checkouts that are gone: when the project keeps its run states in the default
  location, the run states there of every checkout that no longer exists, together with
  the directories that held them. Nothing else deletes them: a run reads its own
  directory and no other.

Returns whether nothing is left to do. Having done the rest, it throws a
[`ChoresError`](@ref) when something is left that a person has to fix, and otherwise
returns `true`; so `Runtests.chores(); Runtests.runtests()` stops before any test
runs on a suite a person has to fix first. With `dry_run = true` it changes nothing
and does not throw `ChoresError` for reported problems; it returns whether there is
nothing to do, neither for a person nor for it. An invalid `path` can still throw.
`path` finds the package as it does for [`runtests`](@ref).
"""
function chores(args...; dry_run::Bool = false,
                config::Union{Nothing, AbstractString, AbstractVector{<:AbstractString}} = nothing)
    return exclusively(() -> run_chores(args, dry_run, config))
end

function run_chores(args, dry_run::Bool, config)
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    configs = config === nothing ? String[] : config isa AbstractString ? [String(config)] : String.(config)
    fix = !dry_run
    todo = problems = 0
    body = styled() do io
        # The checkouts that are gone are no other step's business, and reading the
        # default location takes its own time: in a task of its own from the start.
        gone = chore_task(io -> chore_gone_checkouts!(io, fix))
        todo, problems = package_chores!(io, target, fix, configs)
        todo += said!(io, gone)
        print_chores_outcome(io, fix, todo, problems, "Runtests.chores()")
    end
    print(stdout, bracket(body, "[TEST]", fix ? "chores" : "chores, checking only", "", :default))
    dry_run && return problems == 0 && todo == 0
    problems == 0 || throw(ChoresError(string(plural(problems, "problem"), " to fix by hand, as the report says")))
    return true
end

# The chores of the suite of `target`, each step said into `io` in turn, with paths
# from `PROJECT_ROOT`: the number of things done, or to do on a dry run, and the number
# of problems a person has to fix.
function package_chores!(io::IO, target, fix::Bool, configs::Vector{String})
    todo = problems = 0
    # Setups first, as expanding a template loads them, and the suite after the
    # templates, so that it is read with their new expansions.
    n, bad = said!(io, chore_step(io -> chore_setups!(io, target, fix)))
    todo += n
    problems += bad
    n, bad = said!(io, chore_step(io -> chore_templates!(io, target, fix)))
    todo += n
    problems += bad
    # Scan the suite once, then check TestItems.toml, every named config, and every
    # `[groups]` entry in memory against that single scan.
    (bad, names) = said!(io, chore_step(io -> check_suite!(io, target, configs)))
    problems += bad
    todo += said!(io, chore_step(io -> chore_runstates!(io, target, fix, names)))
    return todo, problems
end

# The last line of a chores report: what was done, or is to do and which call does it,
# and what is left to a person.
function print_chores_outcome(io::IO, fix::Bool, todo::Integer, problems::Integer, call::AbstractString)
    t, p = Int(todo), Int(problems)
    if p > 0
        fix && t > 0 && print(io, "done: ", t, " · ")
        print(io, "to fix by hand: ", p)
        !fix && t > 0 && print(io, " · the rest `", call, "` does")
    elseif t > 0
        print(io, fix ? "done: $t" : "to do: $t, which `$call` does")
    else
        print(io, "nothing to do")
    end
    return nothing
end

# The suite as a full run would read it: scan once, then check `test/TestItems.toml`,
# each extra config in `configs`, and every `[groups]` entry against the scanned items
# in memory. Returns the number of problems a person has to fix, and the names of the
# test items (`nothing` when they could not be read).
function check_suite!(io::IO, target, configs::Vector{String} = String[])
    default_config = joinpath(target.testdir, "TestItems.toml")
    # A package with no test files of any kind, a fixture package in another's
    # `test/` say, has no suite for chores to keep: nothing to do, where a run of it
    # has nothing to run and says so.
    walked = walk_test_dir(target.testdir)
    if all(isempty, (walked.tests, walked.strays, walked.templates))
        println(io, "test items: none, no test files under ", joinpath(relpath_or_path(target.testdir), ""))
        bad = 0
        for path in configs
            bad += check_config_entry!(io, target, path, nothing, nothing, nothing, walked.environments)
        end
        return bad, Set{String}()
    end

    items = nothing
    suite_names = String[]
    suite_tags = Set{Symbol}()
    problems = 0
    try
        setups = setup_modules(target.testdir)
        if isempty(walked.tests)
            isempty(walked.strays) || throw(ScanFailure(copy(walked.strays)))
            throw(NoTestsError("no test files found under $(joinpath(relpath_or_path(target.testdir), "")); test files are " *
                               "named `*_test.jl` or `*_tests.jl` and live under `test/`"))
        end
        items = scan(walked.tests, Filter(), setups; strays = walked.strays, templates = walked.templates,
                     expansions = false, suite_names, environments = walked.environments, suite_tags)
        isempty(items) && throw(NoTestsError("no test items matched the filter"))
        println(io, "test items: ", length(items), " in ", plural(length(unique(it -> it.file, items)), "file"), ", all valid")
    catch e
        if e isa ConfigError
            problems += print_problem(io, "config", e.msg)
            for path in configs
                problems += check_config_entry!(io, target, path, nothing, nothing, nothing, walked.environments)
            end
            return problems, nothing
        end
        e isa ScanFailure || e isa NoTestsError || rethrow()
        # Under a dry run the test files may be expansions `chores` has yet to write.
        if e isa NoTestsError && any(t -> !isfile(expansion_of(t)), walked.templates)
            println(io, "test items: none to read until the templates are expanded")
            for path in configs
                problems += check_config_entry!(io, target, path, nothing, nothing, nothing, walked.environments)
            end
            return problems, nothing
        end
        problems += if e isa ScanFailure
            println(io, "test items: ", plural(length(e.errors), "problem"), ":")
            foreach(err -> println(io, "  ", err), e.errors)
            length(e.errors)
        else
            print_problem(io, "test items", e.msg)
        end
    end

    problems += check_config_entry!(io, target, nothing, items, suite_names, suite_tags, walked.environments;
                                    default_path = default_config)
    for path in configs
        problems += check_config_entry!(io, target, path, items, suite_names, suite_tags, walked.environments)
    end
    return problems, items === nothing ? nothing : Set{String}(suite_names)
end

# Validate one config file (`nothing` for `test/TestItems.toml`, or an explicit path)
# and its `[groups]` against already-scanned `items` (or settings alone when `items === nothing`).
function check_config_entry!(io::IO, target, config::Union{Nothing, AbstractString},
                             items::Union{Nothing, Vector{RawItem}}, suite_names, suite_tags,
                             environments::Vector{String}; default_path::String = "")
    cfg = try
        nunits = items === nothing ? 0 : length(items)
        c = read_config(target.testdir; config, nunits)
        if items !== nothing
            naming = naming_root(target.root)
            check_skip_environment(c.skip_environment, String[rel_slash(dir, naming) for dir in environments], naming, ConfigError)
            plan(items, c; history = History(), root = target.root, suite_names)
        end
        c
    catch e
        e isa ConfigError || rethrow()
        return print_problem(io, "config", e.msg)
    end
    path = config === nothing ? default_path : abspath(config)
    if config === nothing && !isfile(path)
        items === nothing || println(io, "config: none")
        return 0
    end
    print(io, "config: ")
    printstyled(io, relpath_or_path(path); color = :light_black)
    if items === nothing
        println(io, " reads; the items it names are checked once the test items read")
        return 0
    end
    println(io, ", valid")
    return check_groups!(io, path, cfg.groups, items, suite_tags)
end

# Every group of `[groups]` checked in memory against the already-scanned items and
# suite tags: catches unknown tags (`ConfigError`) and groups selecting zero items.
function check_groups!(io::IO, config_path::AbstractString, groups::Dict{String, TagExpr},
                       items::Vector{RawItem}, suite_tags::Set{Symbol})
    bad = 0
    for name in sort!(collect(keys(groups)))
        expr = groups[name]
        msg = try
            check_tags_exist(Filter(; group = GroupSelection(name, expr, "from the `group` keyword", String(config_path))), suite_tags)
            any(it -> matches_tags(expr, it.tags), items) ? nothing : "group `$name` selects no test item"
        catch e
            e isa ConfigError || rethrow()
            e.msg
        end
        msg === nothing || (bad += print_problem(io, "groups", msg))
    end
    return bad
end

# A step of the chores: what it says, styled as the report is, with how long it took
# when that was long, and what it returns. `said!` prints the first and returns the
# second. A step in a task of its own is said once the task is done, so the report
# reads in the order of its steps whatever order they end in.
function chore_step(f)
    t0 = time()
    out = Ref{Any}(nothing)
    text = styled(io -> (out[] = f(io)))
    return (with_duration(text, time() - t0), out[])
end

chore_task(f) = Threads.@spawn chore_step(f)

said!(io::IO, t::Task) = said!(io, fetch_result(t))

function said!(io::IO, (text, out)::Tuple{String, Any})
    print(io, text)
    return out
end

# A step that takes longer than this says how long it took, so that a person who
# waited knows which step it was.
const SLOW_STEP_S = 3.0

# `text`, a step's report, with how long the step took after its first line's words,
# ahead of a colon that leads into the lines under it: `templates: 1, 1 expanded, in 1m30s:`.
function with_duration(text::String, seconds::Real)
    seconds < SLOW_STEP_S && return text
    nl = something(findfirst('\n', text), ncodeunits(text) + 1)
    head, rest = text[1:prevind(text, nl)], text[nl:end]
    took = string(", in ", fmt_seconds(seconds))
    return endswith(head, ":") ? string(chop(head), took, ":", rest) : string(head, took, rest)
end

# What a task returned, or what it threw, as itself rather than wrapped.
function fetch_result(t::Task)
    try
        return fetch(t)
    catch e
        e isa TaskFailedException && throw(e.task.result)
        rethrow()
    end
end

# `label: msg`, a message of several lines indented under its first. Counts as one.
function print_problem(io::IO, label::AbstractString, msg::AbstractString)
    lines = split(chomp(msg), '\n')
    println(io, label, ": ", first(lines))
    foreach(l -> println(io, "  ", l), lines[2:end])
    return 1
end

# What making the setups packages would change, done under `fix`: the number of
# setups to change, and of problems a person has to fix.
function chore_setups!(io::IO, target, fix::Bool)
    dir = joinpath(target.testdir, TESTSETUPS_DIR)
    modules = setup_modules(target.testdir)
    isempty(modules) && (println(io, "setups: none"); return (0, 0))
    plans = try
        plan_setup_packages(target, dir, modules)
    catch e
        e isa ConfigError || rethrow()
        return (0, print_problem(io, "setups", e.msg))
    end
    pending = filter(p -> moves(p) || p.changed, plans)
    if isempty(pending)
        println(io, "setups: ", length(plans), ", all up to date")
        return (0, 0)
    end
    fix && foreach(write_setup_package, pending)
    println(io, "setups: ", length(pending), " of ", length(plans), fix ? " changed:" : " to change:")
    print_setup_changes(io, pending, dir; done = fix, indent = "  ")
    return (length(pending), 0)
end

# Deletes, under `fix`, the run states pruning would; their number.
function chore_runstates!(io::IO, target, fix::Bool, names)
    files = runstate_files(target.root)
    print(io, "run states: ")
    isempty(files) && (println(io, "none"); return 0)
    print(io, length(files), " in ")
    printstyled(io, relpath_or_path(runstate_dir(target.root)); color = :light_black)
    return with_runs_read(target.root) do
        stale = prunable_runstates(target.root; names)
        if isempty(stale)
            println(io, ", none to delete")
        else
            # Another process may be reading one, or have deleted it, already.
            fix && foreach(remove_runstate, stale)
            println(io, ", ", length(stale), " of this machine's ", fix ? "deleted" : "to delete", ": beyond the newest ",
                    KEEP_RUNS, ", and holding nothing about the suite's items that a newer one does not")
        end
        print_other_machines(io, target.root)
        return length(stale)
    end
end

# The project's run states that other machines recorded, which no deletion on this
# machine touches: how many, from how many machines, and what their directories hold.
function print_other_machines(io::IO, root::AbstractString)
    others = [(get(rs.meta, "host", ""), f) for (f, rs) in project_runs(root) if !recorded_here(rs)]
    isempty(others) && return nothing
    machines = length(unique(first.(others)))
    bytes = sum(((_, f),) -> dir_bytes(rundata_dir(f)), others)
    println(io, "run states of other machines: ", length(others), " from ", plural(machines, "machine"), ", ",
            fmt_bytes(bytes), ", which this machine never deletes")
    return nothing
end

# The bytes of the files under `dir`, as far as they can be read: another process
# may delete them meanwhile.
function dir_bytes(dir::AbstractString)
    total = 0
    for (root, _, files) in walkdir(dir; onerror = _ -> nothing), f in files
        total += filesize(joinpath(root, f))
    end
    return total
end

# Deletes, under `fix`, the run states of checkouts that are gone; their number. Only
# where this project's own are, the default location: one that `RUNTESTS_RUNSTATE_DIR`
# names is a CI job's, or shared, and the sweep has no business there.
function chore_gone_checkouts!(io::IO, fix::Bool)
    isempty(get(ENV, "RUNTESTS_RUNSTATE_DIR", "")) || return 0
    gone = sweep_runstate_dirs(; fix)
    print(io, "checkouts that are gone: ")
    if isempty(gone)
        println(io, "none with run states to delete")
        return 0
    end
    n = sum(g -> length(g.runstates), gone)
    println(io, plural(length(gone), "directory", "directories"), " in ", relpath_or_path(runstate_root()), ", ",
            plural(n, "run state"), fix ? " deleted" : " to delete")
    return max(n, 1)
end
