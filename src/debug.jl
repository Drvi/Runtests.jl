# Stepping into one test item under Debugger.jl, in this process.

"""
    debug([item]; seed) -> Test.AbstractTestSet

Step into one test item with Debugger.jl: `using Debugger` first. `item` picks it: its
exact name; a `Regex` that matches the name of that item and no other; or a path, as
[`runtests`](@ref) takes one, relative to the current directory: `file.jl:line` for
the item that line is inside, or a test file or directory that holds that item and
no other. What picks no item, or several, is an error that says what it found.
Without `item` it is the last recorded run's most recent failure, the item among
those that failed, errored or timed out that finished last, with that run's seed, so
it draws the random numbers it failed with. When no run of the project is recorded,
or the last one had no failures, there is nothing to step into, and it says so.

The item runs here, in this process, as a run would run it: its module and imports,
the test environment, or the environment its profile names, and the setups, and
its profile's `env`, `init` and `test_end`. Its body is a function the debugger enters at the body's first call.
What cannot be part of a function, `using` and `struct` among it, has run by then.
Only this item runs: the items before it in a chain do not.

What this process cannot give the item is listed before it starts: a profile's
`julia_args`, `threads` and `preferences`, a process of its own, and the keywords
only a scheduler honours. `seed` is a run's, as `runtests` takes and prints it, so
the item draws the random numbers it drew in that run.

Returns the item's testset. Leaving the debugger before the item has finished
records an error, since the rest of it did not run.
"""
function debug(item::Union{Nothing, AbstractString, Regex} = nothing; seed::Union{Nothing, Integer} = nothing)
    return debug_item(debugger_entry(), item isa AbstractString ? String(item) : item, seed)
end

# The extension's entry point. Debugger.jl is a weak dependency, loaded by a session
# that wants to step through an item and by nothing else.
function debugger_entry()
    ext = Base.get_extension(Base.moduleroot(@__MODULE__), :RuntestsDebuggerExt)
    ext === nothing && throw(
        ConfigError(
            "Runtests.debug steps through the item with Debugger.jl, which is not loaded: " *
                "`using Debugger` first, after `] add Debugger` if it is not installed"
        )
    )
    return ext.enter
end

# `enter(body)` calls the item's body, a function of no arguments, under a debugger.
# Without a name, the item is the last run's most recent failure.
function debug_item(enter, name::Union{Nothing, String, Regex}, seed::Union{Nothing, Integer})
    target = interactive_target()
    target === nothing &&
        throw(ConfigError("Runtests.debug looks for test items in a package, and there is no package here"))
    failure = name === nothing ? last_failure(target) : nothing
    item = find_item(target, failure === nothing ? name : failure.name)
    # The profile a run would give the item, `[profiles.default]` included.
    prof = interactive_profile(item, target)
    # A failure is stepped into with the seed of the run it happened in.
    runs = failure === nothing ? nothing : failure.seed
    run_seed = UInt64(something(seed, runs, rand(RandomDevice(), UInt64)))
    print_debug_header(item, prof, run_seed, failure, seed === nothing && runs !== nothing)
    return with_interactive_env(target, prof) do
        withenv(prof.env...) do
            isempty(prof.init.args) || Core.eval(Main, Expr(:block, prof.init.args...))
            spec = interactive_spec(item, target, 1, item_seed(run_seed, item.name))
            say(item, target, 1, nothing)
            # The item's testset prints its own summary as it finishes; a `test_end`
            # that then fails is nested under it, and said here.
            result = run_item(spec; printing = true, enter)
            n = length(result.testset.results)
            result = with_test_end(result, spec, prof.test_end)
            for ts in result.testset.results[(n + 1):end], r in collect_failures(ts)
                show(stdout, r)
                println(stdout)
            end
            say(item, target, 1, outcome(result))
            return result.testset
        end
    end
end

# What a run records as a failure that can be stepped into again: an item that ran.
# One that never got to run, because its chain broke or the run was stopped, has
# nothing of its own to show.
const STEPPABLE = (FAILED, ERRORED, TIMEDOUT)

"""
    last_failure(target) -> (; name, others, seed)

The project's last recorded run, and of the items in it that failed, errored or
timed out, the one that finished last; `others` are the rest, most recent first.
`seed` is the run's, or `nothing` if it did not record one. Throws when no run is
recorded or the last one had no failures.
"""
function last_failure(target)
    runs = recent_runs(target.root, 1)
    isempty(runs) && throw(
        NoTestsError(
            "no run of this project is recorded, so there is no failure to step into; " *
                "run its tests first, or name an item: `Runtests.debug(\"name\")`"
        )
    )
    rs = last(only(runs))
    # Paired by `zip`: a damaged file can hold fewer items than statuses.
    failed = [(it, st) for (it, st) in zip(rs.items, rs.statuses) if st.state in STEPPABLE]
    isempty(failed) && throw(
        NoTestsError(
            "the last recorded run of this project had no failures to step into; " *
                "name an item instead: `Runtests.debug(\"name\")`"
        )
    )
    sort!(failed; by = ((_, st),) -> st.start_off + st.elapsed, rev = true)
    names = [it.name for (it, _) in failed]
    return (; name = first(names), others = names[2:end], seed = tryparse(UInt64, get(rs.meta, "seed", "")))
end

# The one item `what` picks from the whole suite, read the way a run reads it: an
# exact name first, then a `Regex` matched against the names, or a path.
function find_item(target, what::Union{String, Regex})
    claimed = claimed_environments(config_toml(target.testdir, nothing)...)
    files, strays, templates = walk_test_dir(target.testdir; claimed)
    items = scan(files, Filter(), setup_modules(target.testdir); strays, templates, claimed)
    if what isa String
        i = findfirst(it -> it.name == what, items)
        i === nothing || return items[i]
        looks_like_path(what) || throw(NoTestsError(string("no test item is called ", repr(what), near_names(what, items))))
        picked = items_at_path(target, items, what)
    else
        picked = [it for it in items if occursin(what, it.name)]
    end
    length(picked) == 1 && return only(picked)
    isempty(picked) && throw(NoTestsError(string("no test item's name matches ", repr(what))))
    shown = first(picked, 10)
    throw(ArgumentError(string(
        "`debug` steps into one test item, and ", repr(what), " picks ", length(picked), ": ",
        join((string(repr(it.name), " at ", relpath_or_path(it.file, target.root), ":", it.line) for it in shown), ", "),
        length(picked) > length(shown) ? ", …" : "", "; give its name, or its `file.jl:line`"
    )))
end

# A string `debug` reads as a path rather than a name, once no item has it as its name.
looks_like_path(s::AbstractString) = endswith(s, ".jl") || occursin(r"\.jl:\d+$", s) || ispath(s)

# The items a path picks, as `runtests` reads one: the item a `file.jl:line` is inside,
# or every item a file or directory holds.
function items_at_path(target, items::Vector{RawItem}, path::String)
    t = resolve_target((path,))
    t.root == target.root || throw(ArgumentError(
        "$path is in the package at $(t.root), and this session's package is the one at $(target.root)"
    ))
    inpath = [it for it in items if matches_path(t.paths, it.file)]
    t.line == 0 && return inpath
    start = maximum((it.line for it in inpath if it.line <= t.line); init = Int32(0))
    if start == 0
        file = relpath_or_path(only(t.paths), target.root)
        throw(NoTestsError(isempty(inpath) ? "$file holds no test items" :
            "line $(t.line) of $file is above its first test item, at line $(minimum(it.line for it in inpath))"))
    end
    return [it for it in inpath if it.line == start]
end

# The names nearest one no item has, as a hint: a misspelling, or a part of a name.
function near_names(name::String, items::Vector{RawItem})
    names = [it.name for it in items]
    near = unique!([nearest(name, names); [n for n in names if occursin(lowercase(name), lowercase(n))]])
    isempty(near) && return ""
    return string("; did you mean ", join(repr.(first(near, 5)), ", ", " or "), "?")
end

# Said before the debugger takes the terminal: which item and why, whose seed, the
# failures there are to step into instead, and what the item gets here that it
# would not get in a run.
function print_debug_header(item::RawItem, prof::Profile, seed::UInt64, failure, runs_seed::Bool)
    head = string(
        "debugging ", repr(item.name), " in this process",
        failure === nothing ? "" : " · the last run's most recent failure",
        runs_seed ? " · the run's seed " : " · seed ", seed_text(seed)
    )
    body = String[]
    if failure !== nothing && !isempty(failure.others)
        shown = first(failure.others, 5)
        push!(
            body, string(
                "the run's other failures: ", join(repr.(shown), ", "),
                length(failure.others) > length(shown) ? string(" and ", length(failure.others) - length(shown), " more") : ""
            )
        )
    end
    ignored = debug_ignored(item, prof)
    isempty(ignored) || push!(body, string("ignored here: ", join(ignored, " · ")))
    if isempty(body)
        println(stdout, label_prefix(), head)
    else
        print(stdout, bracket(join(body, "\n"), "[TEST]", head, "", :default))
    end
    flush(stdout)
    return nothing
end

function debug_ignored(item::RawItem, prof::Profile)
    out = String[]
    of = prof.name === DEFAULT_PROFILE ? "" : string(" of profile `", prof.name, "`")
    isempty(prof.julia_args) || push!(out, string("`", join(prof.julia_args, " "), "`", of))
    here = string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive))
    prof.threads == here || push!(out, string("threads ", prof.threads, of))
    # A profile's environment is activated here, and its copy holds the preferences.
    isempty(prof.preferences) || !isempty(prof.environment) || push!(out, string("preferences", of))
    item.exclusive && push!(out, "sandbox=true")
    item.timeout_s == USE_RUN_DEFAULT || push!(out, string("timeout=", item.timeout_s))
    item.retries == USE_RUN_DEFAULT || push!(out, string("retries=", item.retries))
    item.chain === NO_CHAIN || push!(out, string("chain=:", item.chain))
    return out
end
