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
- test templates: each `test/testtemplates/*_tests_template.jl` expanded into the test
  file of its name in `test/`, in a process with the test environment, and the
  expansion of a template that is gone deleted. Every template is expanded, since
  what its code computes can change while its text does not; a dry run reads the
  expansions' stamps instead and runs nothing. An expansion edited by hand, and a
  test file in a template's way that `chores` did not write, are left to a person.
- run states: this machine's are pruned as a run prunes them, the same ones and no
  others (see [`prunable_runstates`](@ref)), with their logs; and those of a format
  older than any this version reads are deleted. One recorded elsewhere, a CI
  artifact say, and one that cannot be read otherwise are never deleted.
- checkouts that are gone: when the project keeps its run states in the default
  location, the run states there of every checkout that no longer exists, as
  [`sweep_runstate_dirs`](@ref) finds them, the directories that held them with them.
  Nothing else deletes them: a run reads its own directory and no other.

Returns whether nothing is left to do. Having done the rest, it throws a
[`ChoresError`](@ref) when something is left that a person has to fix, and otherwise
returns `true`; so `Runtests.chores(); Runtests.runtests()` stops before any test
runs on a suite a person has to fix first. With `dry_run = true` it changes nothing
and never throws, and returns whether there is nothing to do, neither for a person
nor for it. `path` finds the package as it does for [`runtests`](@ref).
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
        # Setups first, as expanding a template loads them, and the suite after the
        # templates, so that it is read with their new expansions.
        n, bad = chore_setups!(io, target, fix)
        todo += n
        problems += bad
        n, bad = chore_templates!(io, target, fix)
        todo += n
        problems += bad
        # The checks that read the suite read it at the same time, each in a task.
        suite = chore_task(io -> check_suite!(io, target))
        named = [chore_task(io -> check_named_config!(io, target, path)) for path in configs]
        (bad, names) = said!(io, suite)
        problems += bad
        for t in named
            problems += said!(io, t)
        end
        todo += chore_runstates!(io, target, fix, names)
        todo += said!(io, gone)
        if problems > 0
            fix && todo > 0 && print(io, "done: ", todo, " · ")
            print(io, "to fix by hand: ", problems)
            !fix && todo > 0 && print(io, " · the rest `Runtests.chores()` does")
        elseif todo > 0
            print(io, fix ? "done: $todo" : "to do: $todo, which `Runtests.chores()` does")
        else
            print(io, "nothing to do")
        end
    end
    print(stdout, bracket(body, "[TEST]", fix ? "chores" : "chores, checking only", "", :default))
    dry_run && return problems == 0 && todo == 0
    problems == 0 || throw(ChoresError(string(plural(problems, "problem"), " to fix by hand, as the report says")))
    return true
end

# The suite as a full run would read it: its items, all of them whatever group the
# config or the environment would select, then its settings and what they name,
# each group's selection among them. The number of problems a person has to fix,
# and the names of the test items, `nothing` when they could not be read. The
# expansions of templates are the templates step's to report.
function check_suite!(io::IO, target)
    config = joinpath(target.testdir, "TestItems.toml")
    # A package with no test files of any kind, a fixture package in another's
    # `test/` say, has no suite for chores to keep: nothing to do, where a run of it
    # has nothing to run and says so.
    # The settings' own problems are said below, by the run's reading of them.
    walked = walk_test_dir(target.testdir; claimed = suite_claims_or_none(target))
    if all(isempty, (walked.tests, walked.strays, walked.templates))
        println(io, "test items: none, no test files under ", joinpath(relpath_or_path(target.testdir, target.root), ""))
        return 0, Set{String}()
    end
    try
        p, _ = prepare((target.root,); announce = false, expansions = false, group = ALL_GROUP)
        println(io, "test items: ", nitems(p), " in ", plural(length(p.files), "file"), ", all valid")
        print(io, "config: ")
        if isfile(config)
            printstyled(io, relpath_or_path(config, target.root); color = :light_black)
            println(io, ", valid")
        else
            println(io, "none")
        end
        return check_groups!(io, target, p.cfg.groups), Set(p.items.name)
    catch e
        e isa ConfigError && return print_problem(io, "config", e.msg), nothing
        e isa ScanFailure || e isa NoTestsError || rethrow()
        # Under a dry run the test files may be expansions `chores` has yet to write.
        if e isa NoTestsError && any(t -> !isfile(expansion_of(t)), walked.templates)
            println(io, "test items: none to read until the templates are expanded")
            return 0, nothing
        end
        n = if e isa ScanFailure
            println(io, "test items: ", plural(length(e.errors), "problem"), ":")
            foreach(err -> println(io, "  ", err), e.errors)
            length(e.errors)
        else
            print_problem(io, "test items", e.msg)
        end
        # The settings on their own: which items they name waits on the items.
        try
            read_config(target.testdir)
        catch e2
            e2 isa ConfigError || rethrow()
            return n + print_problem(io, "config", e2.msg), nothing
        end
        if isfile(config)
            print(io, "config: ")
            printstyled(io, relpath_or_path(config, target.root); color = :light_black)
            println(io, " reads; the items it names are checked once the test items read")
        end
        return n, nothing
    end
end

# A config file the call named, checked as a run given it would check it: its
# settings, and what they name among the test items, or the settings alone when the
# items do not read. The number of problems a person has to fix, one when it is
# wrong at all.
function check_named_config!(io::IO, target, path::AbstractString)
    items_read = true
    groups = Dict{String, TagExpr}()
    try
        p, _ = prepare((target.root,); config = path, announce = false, expansions = false, group = ALL_GROUP)
        groups = p.cfg.groups
    catch e
        e isa ConfigError && return print_problem(io, "config", e.msg)
        e isa ScanFailure || e isa NoTestsError || rethrow()
        items_read = false
        try
            read_config(target.testdir; config = path)
        catch e2
            e2 isa ConfigError || rethrow()
            return print_problem(io, "config", e2.msg)
        end
    end
    print(io, "config: ")
    printstyled(io, relpath_or_path(abspath(path), target.root); color = :light_black)
    println(io, items_read ? ", valid" : " reads; the items it names are checked once the test items read")
    return check_groups!(io, target, groups; config = path)
end

# Every group of `[groups]` as a run selecting it would read it, since a lane of CI
# that selects one finds a tag no item carries, or nothing to run, only when it
# runs. Each reads the suite, in a task of its own. The number of groups wrong.
function check_groups!(io::IO, target, groups::Dict{String, TagExpr}; config = nothing)
    checks = map(sort!(collect(keys(groups)))) do name
        Threads.@spawn try
            prepare((target.root,); config, announce = false, expansions = false, group = name)
            nothing
        catch e
            e isa ConfigError || e isa NoTestsError || rethrow()
            e isa ConfigError ? e.msg : "group `$name` selects no test item"
        end
    end
    bad = 0
    for t in checks
        msg = fetch_result(t)
        msg === nothing || (bad += print_problem(io, "groups", msg))
    end
    return bad
end

# A step of the chores in a task of its own: what it says, styled as the report is,
# and what it returns. `said!` prints the first and returns the second, once the task
# is done, so the report reads in the order of its steps whatever order they end in.
chore_task(f) = Threads.@spawn begin
    out = Ref{Any}(nothing)
    text = styled(io -> (out[] = f(io)))
    (text, out[])
end

function said!(io::IO, t::Task)
    text, out = fetch_result(t)
    print(io, text)
    return out
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

# Deletes, under `fix`, the run states pruning would, and those of an older format;
# their number.
function chore_runstates!(io::IO, target, fix::Bool, names)
    files = runstate_files(target.root)
    print(io, "run states: ")
    isempty(files) && (println(io, "none"); return 0)
    print(io, length(files), " in ")
    printstyled(io, relpath_or_path(runstate_dir(target.root), target.root); color = :light_black)
    stale = prunable_runstates(target.root; names)
    old = old_format_runstates(target.root)
    if isempty(stale) && isempty(old)
        println(io, ", none to delete")
        return 0
    end
    # Another process may be reading one, or have deleted it, already.
    fix && foreach(remove_runstate, [stale; old])
    said = String[]
    isempty(stale) || push!(said, string(
        length(stale), " of this machine's ", fix ? "deleted" : "to delete",
        ": beyond the newest ", KEEP_RUNS, ", and holding nothing about the suite's items that a newer one does not"
    ))
    isempty(old) || push!(said, string(
        length(old), " of an older format, which this version of Runtests does not read, ", fix ? "deleted" : "to delete"
    ))
    println(io, ", ", join(said, "; "))
    return length(stale) + length(old)
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
