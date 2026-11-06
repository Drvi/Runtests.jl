# A combined run: the suites of several packages of one workspace, run together.
# Which packages take part.

"""
    Participants

The packages whose suites a combined run runs, one row each, sorted by directory,
and the root of the workspace they belong to. An `isolated` package runs in its own
test environment, on workers of its own. `skipped` holds each package of the
workspace that does not take part, by its directory relative to the workspace root,
with the reason, for the run to say.
"""
struct Participants
    workspace::String
    name::Vector{String}
    uuid::Vector{Base.UUID}
    root::Vector{String}
    isolated::Vector{Bool}
    skipped::Vector{Pair{String, String}}
end

Base.length(ps::Participants) = length(ps.name)

# Workspaces came with Julia 1.12.
const MONOREPO_JULIA = v"1.12"
const MONOREPO_KEYS = (:packages, :isolated)

"""
    find_participants(dir = nothing; packages = nothing) -> Participants

The packages of the workspace at `dir` whose suites a combined run runs. Without
`dir`, the workspace of the active project. Every package of the workspace that has
a suite takes part, or those that `packages` of `[monorepo]` in the root's
`test/TestItems.toml` names by directory or glob. The keyword `packages` narrows that
to the package names or directories it gives, a directory relative to the workspace
root. A package that takes part needs its test project to be a member of the
workspace. A mistake in a file is a `ConfigError`, one in the call an `ArgumentError`.
"""
function find_participants(dir::Union{Nothing, AbstractString} = nothing; packages = nothing)
    VERSION >= MONOREPO_JULIA || error(
        "a combined run needs Julia $(MONOREPO_JULIA.major).$(MONOREPO_JULIA.minor) or later, whose workspaces it ",
        "runs in; this is Julia $VERSION. `Runtests.runtests` runs one package at a time on this version"
    )
    workspace, project = monorepo_workspace(dir)
    found = package_candidates(workspace, project)
    why = Union{Nothing, String}[no_suite(r) for r in found.root]
    config = joinpath(workspace, "test", "TestItems.toml")
    table = monorepo_table(config)
    rel(k) = rel_slash(found.root[k], workspace)

    chosen = Int[]
    if table.listed
        for entry in table.packages
            hits = match_entry(config, "packages", entry, workspace, found.root)
            if !is_glob(entry)
                k = only(hits)
                why[k] === nothing || throw(ConfigError(string(
                    "`packages` entry ", repr(entry), " of [monorepo] in ", relpath_or_path(config, workspace),
                    " names ", found.name[k], ", which has no suite to run: ", why[k]
                )))
            end
            append!(chosen, k for k in hits if why[k] === nothing)
        end
        unique!(sort!(chosen))
        isempty(chosen) && throw(ConfigError(
            "`packages` of [monorepo] in $(relpath_or_path(config, workspace)) leaves no package with a suite to run"
        ))
    else
        append!(chosen, k for k in eachindex(found.root) if why[k] === nothing)
        isempty(chosen) && throw(NoTestsError("no package of the workspace at $workspace has a suite to run"))
    end
    isolated = falses(length(found.root))
    for entry in table.isolated, k in match_entry(config, "isolated", entry, workspace, found.root)
        isolated[k] = true
    end

    kept = packages === nothing ? chosen : narrow_participants(found, chosen, why, packages, workspace)
    # A run, its run states and an editor know an item by its package's name and its own.
    for name in unique(found.name[kept])
        dirs = [rel(k) for k in kept if found.name[k] == name]
        length(dirs) > 1 && throw(ConfigError(string(
            "a combined run knows a package by its name, and ", length(dirs), " packages that take part are ", name, ": ",
            join(dirs, " and "), ". Rename one, or leave one out with `packages` of [monorepo] in ",
            relpath_or_path(config, workspace), " or with the keyword `packages`"
        )))
    end
    outside = [k for k in kept if !test_project_in_workspace(found.root[k])]
    isempty(outside) || throw(ConfigError(string(
        "a combined run runs each package's tests in the environment of the workspace at ", workspace, ", ",
        "and the test project of ", join((string(rel(k), isnothing(project_file(joinpath(found.root[k], "test"))) ?
            " (it has none: its tests use [extras] and [targets])" : "") for k in outside), ", "),
        length(outside) == 1 ? " is" : " are", " not a member of it. Add each test project to `projects` of ",
        "[workspace] in ", basename(project), ", or leave the package out with `packages` of [monorepo] in ",
        relpath_or_path(config, workspace)
    )))
    skipped = Pair{String, String}[]
    for k in eachindex(found.root)
        k in kept && continue
        push!(skipped, rel(k) => why[k] !== nothing ? why[k] :
            k in chosen ? "not among the `packages` given" : "left out by `packages` of [monorepo]")
    end
    return Participants(workspace, found.name[kept], found.uuid[kept], found.root[kept], isolated[kept], skipped)
end

# The workspace root a combined run at `dir` runs, and its project file. Without
# `dir`, the root of the active project's workspace. A `dir` given has to be the root
# itself, not a member, so that what a call runs does not depend on where it is made.
function monorepo_workspace(dir)
    start = dir === nothing ? default_search_dir() : abspath(dir)
    dir === nothing || isdir(start) || throw(ArgumentError("no such directory: $start"))
    project = find_project(start)
    project === nothing && throw(ArgumentError("could not find a Project.toml at or above $start"))
    outer = outermost_workspace(project)
    dir === nothing || samefile(outer, project) || throw(ArgumentError(
        "$(dirname(project)) is a member of the workspace at $(dirname(outer)): give that directory, " *
            "and `packages` to run some of its packages"
    ))
    haskey(parse_project(outer), "workspace") || throw(ConfigError(
        "$outer declares no workspace. A combined run runs the packages of a workspace, which share one " *
            "manifest: list each package and its test project under [workspace], as in " *
            "`projects = [\"lib/A\", \"lib/A/test\"]`"
    ))
    return realpath(dirname(outer)), outer
end

function parse_project(path::AbstractString)
    return try
        TOML.parsefile(path)
    catch e
        throw(ConfigError("could not parse $path: $(sprint(showerror, e))"))
    end
end

# The project file of directory `dir`, or `nothing`.
function project_file(dir::AbstractString)
    for n in PROJECT_NAMES
        p = joinpath(dir, n)
        isfile(p) && return p
    end
    return nothing
end

# The project file of directory `dir`, which has to have one.
function existing_project_file(dir::AbstractString)
    p = project_file(dir)
    p === nothing && throw(ConfigError("$dir has no Project.toml"))
    return p
end

# The directory of every project of the workspace that `project` declares, and of
# the workspaces its members declare in turn, each once, as `realpath` gives it, and
# without the workspace's root. A member outside the root is an error: Julia looks
# for a member's workspace above the member, so such a member is in no workspace.
function workspace_members(project::AbstractString)
    root = realpath(dirname(project))
    out, seen, pending = String[], Set{String}([root]), String[project]
    while !isempty(pending)
        proj = pop!(pending)
        ws = get(parse_project(proj), "workspace", nothing)
        ws === nothing && continue
        rels = ws isa AbstractDict ? get(ws, "projects", String[]) : nothing
        (rels isa AbstractVector && all(x -> x isa AbstractString, rels)) || throw(ConfigError(
            "`projects` of [workspace] in $proj must be a list of directories, got $(repr(rels))"
        ))
        for r in rels
            d = joinpath(dirname(proj), r)
            p = isdir(d) ? project_file(d) : nothing
            p === nothing && throw(ConfigError("[workspace] of $proj lists $(repr(r)), which has no Project.toml"))
            d = realpath(d)
            within(d, root) || throw(ConfigError(string(
                "[workspace] of ", proj, " lists ", repr(r), ", which is outside the workspace at ", root, ". Julia ",
                "looks for a member's workspace above the member, so it is in none: move it under ", root,
                ", or take it out of `projects`"
            )))
            d in seen && continue
            push!(seen, d); push!(out, d); push!(pending, p)
        end
    end
    return out
end

# The packages of the workspace whose root is `workspace`: the root, when it is a
# package, and each member project with a name and a UUID that is not inside another
# package's `test/`, where a test project or an environment with a name of its own
# would be. Sorted by directory.
function package_candidates(workspace::String, project::String)
    name, uuid, root = String[], Base.UUID[], String[]
    for d in [workspace; workspace_members(project)]
        p = existing_project_file(d)
        t = parse_project(p)
        (haskey(t, "name") && haskey(t, "uuid")) || continue
        u = tryparse(Base.UUID, string(t["uuid"]))
        u === nothing && throw(ConfigError("`uuid` of $p is not a UUID: $(repr(t["uuid"]))"))
        push!(name, string(t["name"])); push!(uuid, u); push!(root, d)
    end
    keep = [k for k in eachindex(root) if !any(r -> startswith(root[k], joinpath(r, "test", "")), root)]
    sort!(keep; by = k -> root[k])
    return (; name = name[keep], uuid = uuid[keep], root = root[keep])
end

# Why the package at `root` has no suite for a combined run, or `nothing` when it has
# one: a test file, a template or a stray Julia file under `test/`. A stray fails the
# combined run, as it fails the package's own.
function no_suite(root::AbstractString)
    testdir = joinpath(root, "test")
    isdir(testdir) || return "it has no test/ directory"
    w = walk_test_dir(testdir)
    (isempty(w.tests) && isempty(w.strays) && isempty(w.templates)) || return nothing
    return isfile(joinpath(testdir, RUNTESTS_FILE)) ?
        "its test/ has only $RUNTESTS_FILE, which a combined run does not run" : "its test/ has no test files"
end

# Whether the test project of the package at `root` is a member of the package's
# workspace, which a combined run needs to run its tests in the workspace's
# environment.
function test_project_in_workspace(root::AbstractString)
    test = project_file(joinpath(root, "test"))
    return test !== nothing && in_package_workspace(test, project_file(root))
end

# `[monorepo]` of the root's `test/TestItems.toml`: the packages it lists, whether it
# lists them at all, and the isolated ones.
function monorepo_table(config::AbstractString)
    isfile(config) || return (; packages = String[], listed = false, isolated = String[])
    t = section(config, parse_project(config), "monorepo", MONOREPO_KEYS)
    return (; packages = string_list(config, t, "packages", "monorepo"), listed = haskey(t, "packages"),
            isolated = string_list(config, t, "isolated", "monorepo"))
end

is_glob(entry::AbstractString) = occursin(r"[*?]", entry)

# The packages among `roots` that `entry` of `key` in [monorepo] names, by index: a
# directory relative to the workspace root, or a glob of directories with `*` and `?`.
function match_entry(config, key, entry::AbstractString, workspace::AbstractString, roots::Vector{String})
    what = string("`", key, "` entry ", repr(entry), " of [monorepo] in ", relpath_or_path(config, workspace))
    # Joined to the root, an empty entry would name the root.
    isempty(strip(entry)) &&
        throw(ConfigError("$what is empty; an entry is a directory under the workspace root, such as \"lib/A\" or \".\""))
    ".." in split(entry, ('/', '\\')) &&
        throw(ConfigError("$what leaves the workspace; an entry is a directory under the workspace root"))
    if is_glob(entry)
        rx = glob_regex(entry)
        hits = [k for k in eachindex(roots) if occursin(rx, rel_slash(roots[k], workspace))]
        isempty(hits) && throw(ConfigError("$what matches no package of the workspace"))
        return hits
    end
    path = normpath(joinpath(workspace, entry))
    isdir(path) || throw(ConfigError("$what: no such directory, $path"))
    real = realpath(path)
    within(real, workspace) || throw(ConfigError("$what leads outside the workspace, to $real"))
    k = findfirst(==(real), roots)
    k === nothing && throw(ConfigError("$what is not a package of the workspace: a member project with a name and a UUID"))
    return [k]
end

# A glob's pattern over directories relative to the workspace root, `/` between them:
# `*` is any run of characters but `/`, and `?` is one.
function glob_regex(glob::AbstractString)
    special = ".^\$+()[]{}|\\"
    parts = map(split(chopprefix(replace(glob, '\\' => '/'), "./"), '/')) do part
        join(c == '*' ? "[^/]*" : c == '?' ? "[^/]" : c in special ? string('\\', c) : string(c) for c in part)
    end
    return Regex(string("^", join(parts, '/'), "\$"))
end

rel_slash(path::AbstractString, base::AbstractString) = replace(relpath(path, base), '\\' => '/')
within(path::AbstractString, dir::AbstractString) = path == dir || startswith(path, joinpath(dir, ""))

# The participants that the keyword `packages` keeps, by index: each a package name,
# or a directory relative to the workspace root, as in [monorepo].
function narrow_participants(found, chosen::Vector{Int}, why, packages, workspace::AbstractString)
    packages isa Union{AbstractString, Symbol} && (packages = [packages])
    (packages isa Union{AbstractVector, Tuple} && !isempty(packages) &&
        all(p -> p isa Union{AbstractString, Symbol}, packages)) || throw(ArgumentError(
        "`packages` must be package names or directories, as in `packages = [\"A\", \"lib/B\"]`, got $(repr(packages))"
    ))
    left_out(k) = why[k] !== nothing ? why[k] : "it is left out by `packages` of [monorepo]"
    keep = Int[]
    for p in packages
        s = String(p)
        if p isa Symbol || !(occursin(r"[/\\]", s) || startswith(s, "."))
            ks = [k for k in eachindex(found.name) if found.name[k] == s]
            if isempty(ks)
                near = nearest(s, unique(found.name[chosen]))
                throw(ArgumentError(string(
                    "`packages` names ", repr(s), ", which is not a package of the workspace at ", workspace,
                    isempty(near) ? "" : string(" (did you mean ", join(repr.(near), " or "), "?)")
                )))
            end
            length(ks) == 1 || throw(ArgumentError(string(
                "`packages` names ", repr(s), ", and the workspace has ", length(ks), " packages of that name, in ",
                join((rel_slash(found.root[k], workspace) for k in ks), " and "), ": give its directory instead"
            )))
            k = only(ks)
        else
            path = normpath(joinpath(workspace, s))
            isdir(path) || throw(ArgumentError("`packages` names $(repr(s)), and there is no such directory: $path"))
            k = findfirst(==(realpath(path)), found.root)
            k === nothing && throw(ArgumentError(
                "`packages` names $(repr(s)), which is not a package of the workspace at $workspace"
            ))
        end
        k in chosen || throw(ArgumentError(
            "`packages` names $(repr(s)), $(found.name[k]), which does not take part: $(left_out(k))"
        ))
        push!(keep, k)
    end
    return unique!(sort!(keep))
end

"""
    import_problems(ps, items, item_participant, profiles, setups, configs) -> Vector{ScanError}

The imports that a shared worker could load but the participant's own test
environment could not, each where it is written, so that a combined run gives no
item a package its own run would not. A worker of a shared pool runs in the union of
the participants' test environments. Checked are the items in the test environment of
a participant that is not isolated, the `init`, `test_end` and skip expressions they
run, and the setups they load. An item or profile expression of participant `k` may
import the dependencies of `k`'s test project, `k` itself, `k`'s setups and the
standard library. A setup module may import the same. A setup package may import its
own dependencies and the standard library. Only an import that a shared worker can
load is a problem: a package, a test dependency or a setup of a participant, or
Runtests. Any other fails, or loads from a directory the code puts on `LOAD_PATH`,
the same way in a combined run as in the package's own.

`item_participant[i]` is the participant of `items[i]`; `profiles[k]`, `setups[k]` and
`configs[k]` are participant `k`'s profiles, setup modules and configuration file.
`all_setups` checks every setup of a participant, those no item loads too.
What this checks is the syntax as written, a macro call's arguments included: not an
import built at run time, as with `Core.eval`, quoted code or a file that `include` reads.
"""
function import_problems(
        ps::Participants, items::Vector{RawItem}, item_participant::Vector{Int},
        profiles::Vector{Dict{Symbol, Profile}}, setups::Vector{Dict{Symbol, String}}, configs::Vector{String};
        all_setups::Bool = false
    )
    eachindex(items) == eachindex(item_participant) || throw(DimensionMismatch("one participant per item"))
    problems = ScanError[]
    common = Set{Symbol}([:Base, :Core, :Main]); union!(common, stdlib_names())
    # What a shared worker can load that a package's own environment might not.
    shared = Set{Symbol}([Symbol(Base.PkgId(parentmodule(@__MODULE__)).name)])
    for k in eachindex(ps.name)
        ps.isolated[k] && continue
        push!(shared, Symbol(ps.name[k]))
        union!(shared, dependency_names(existing_project_file(joinpath(ps.root[k], "test"))), keys(setups[k]))
    end
    for k in eachindex(ps.name)
        ps.isolated[k] && continue
        testproj = existing_project_file(joinpath(ps.root[k], "test"))
        allowed = union(common, dependency_names(testproj), (Symbol(ps.name[k]),), keys(setups[k]))
        declarer = string(ps.name[k], "'s test project, ", relpath_or_path(testproj, ps.workspace))
        # A profile's expression has lines of its own, not of the file that holds it.
        check(file, ex, what, in_file = true) = for (root, line) in imports_in(ex)
            (root in allowed || !(root in shared)) || push!(problems, ScanError(file, in_file ? line : Int32(0), string(
                what, "imports ", root, ", which is not in [deps] of ", declarer, ", so ", ps.name[k],
                "'s own run cannot load it"
            )))
        end
        used_profiles, used_setups = Set{Symbol}(), Set{Symbol}()
        for i in eachindex(items)
            (item_participant[i] == k && isempty(items[i].environment)) || continue
            it = items[i]
            check(it.file, it.code, "")
            it.skip isa Expr && check(it.file, it.skip, "the `skip` expression ")
            push!(used_profiles, it.profile)
            union!(used_setups, it.setups)
        end
        for name in sort!(collect(used_profiles))
            prof = get(profiles[k], name, nothing)
            prof === nothing && continue
            # A profile the workspace shares has its code in the root's file.
            file = isempty(prof.dir) ? configs[k] : joinpath(prof.dir, "test", "TestItems.toml")
            check(file, prof.init, "`init` of [profiles.$name] ", false)
            check(file, prof.test_end, "`test_end` of [profiles.$name] ", false)
        end
        all_setups && union!(used_setups, keys(setups[k]))
        # A setup module's sibling setups load with it.
        pending = collect(used_setups)
        while !isempty(pending)
            name = pop!(pending)
            path = setups[k][name]
            ex = parse_source(path)
            ex === nothing && continue
            dir = joinpath(ps.root[k], "test", TESTSETUPS_DIR, String(name))
            if isdir(dir)
                own = project_file(dir)
                deps = union(common, dependency_names(own), (name,))
                own_text = own === nothing ? string(name, ", which has no Project.toml") : relpath_or_path(own, ps.workspace)
                for (root, line) in imports_in(ex)
                    (root in deps || !(root in shared)) || push!(problems, ScanError(path, line, string(
                        "imports ", root, ", which is not in [deps] of the setup package ", name, ", ", own_text
                    )))
                end
            else
                check(path, ex, "")
                for (root, _) in imports_in(ex)
                    haskey(setups[k], root) && !(root in used_setups) && (push!(used_setups, root); push!(pending, root))
                end
            end
        end
    end
    return problems
end

# Each module that a `using` or `import` in `ex` reaches from outside it, with the line
# it is written on: `A` of `using A.B: c`, of `import A as B` and of `@eval using A`, and
# nothing of `using .A` or of quoted code.
function imports_in(@nospecialize(ex), out::Vector{Tuple{Symbol, Int32}} = Tuple{Symbol, Int32}[],
                    line::Base.RefValue{Int32} = Ref(Int32(0)))
    if ex isa LineNumberNode
        line[] = Int32(ex.line)
    elseif ex isa Expr && ex.head !== :quote
        if ex.head === :using || ex.head === :import
            foreach(root -> push!(out, (root, line[])), sort!(collect(imported_roots(ex))))
        else
            foreach(a -> imports_in(a, out, line), ex.args)
        end
    end
    return out
end

# The names in [deps] of the project file `project`, none when there is none.
function dependency_names(project::Union{Nothing, AbstractString})
    project === nothing && return Set{Symbol}()
    deps = get(parse_project(project), "deps", Dict{String, Any}())
    return Set{Symbol}(Symbol(n) for n in keys(deps))
end

# The packages of the standard library that `@stdlib` holds.
stdlib_names() = Set{Symbol}(Symbol(n) for n in readdir(Sys.STDLIB) if isdir(joinpath(Sys.STDLIB, n)))

# A source file parsed, or `nothing` when it does not parse: running it reports that.
function parse_source(path::AbstractString)
    ex = Meta.parseall(read(path, String); filename = path)
    return first_syntax_error(ex) === nothing ? ex : nothing
end

"""
    union_environment(ps, dir) -> project file

The environment of a combined run's shared workers, written into the empty directory
`dir`: a project whose dependencies are the participants that are not isolated, their
test dependencies and Runtests, beside a copy of the workspace's manifest with every
path in it absolute, and the participants' `LocalPreferences.toml` together. The
manifest already holds each dependency in the version that the workspace resolved,
so Julia loads the project without a resolve.

Before writing anything, it stops the run with a `ConfigError` for a name that two
participants declare with different UUIDs, for a preference that two participants
set differently, and for a dependency, Runtests among them, that the manifest does
not hold. The workspace has to be instantiated first.
"""
function union_environment(ps::Participants, dir::AbstractString)
    deps, declared = union_dependencies(ps)
    runtests = Base.PkgId(parentmodule(@__MODULE__))
    preferences = merged_preferences(ps, [k for k in eachindex(ps.name) if !ps.isolated[k]])

    manifest = Base.project_file_manifest_path(existing_project_file(ps.workspace))
    no_manifest = ConfigError("the workspace at $(ps.workspace) has no manifest: instantiate it, with `Pkg.instantiate()` in its root")
    manifest === nothing && throw(no_manifest)
    isfile(manifest) || throw(no_manifest)
    data = parse_project(manifest)
    entries = get(data, "deps", nothing)
    entries isa AbstractDict || throw(ConfigError("$manifest is not a manifest of a workspace: it has no [deps]"))
    held(name, uuid) = any(e -> e isa AbstractDict && get(e, "uuid", "") == uuid, get(entries, name, ()))
    missing_ = sort!(String[name for (name, uuid) in deps if !held(name, uuid)])
    isempty(missing_) || throw(ConfigError(string(
        "the manifest of the workspace, ", relpath_or_path(manifest, ps.workspace), ", does not hold ",
        join((string(n, " (", declared[n], ")") for n in missing_), ", "),
        runtests.name in missing_ ? ". A combined run needs Runtests in the workspace: add it to [deps] of the " *
            "root project or of a member, then resolve the workspace" : ": resolve the workspace"
    )))

    open(io -> TOML.print(io, Dict("deps" => deps); sorted = true), joinpath(dir, "Project.toml"), "w")
    open(io -> TOML.print(io, absolute_paths!(data, ps.workspace); sorted = true), joinpath(dir, "Manifest.toml"), "w")
    isempty(preferences) ||
        open(io -> TOML.print(io, preferences; sorted = true), joinpath(dir, "LocalPreferences.toml"), "w")
    return joinpath(dir, "Project.toml")
end

# The dependencies of the union environment of `ps`, each name with its UUID, and
# what declared each first: the participants that are not isolated, their test
# dependencies and Runtests. A name that two of them declare with different UUIDs
# stops the run.
function union_dependencies(ps::Participants)
    deps = Dict{String, String}()
    declared = Dict{String, String}()
    function declare!(name, uuid, where_)
        seen = get(deps, name, nothing)
        seen === nothing && (deps[name] = uuid; declared[name] = where_; return)
        seen == uuid || throw(ConfigError(string(
            "the participants of a combined run share one environment, and ", name, " is two packages in it: ",
            seen, " in ", declared[name], ", and ", uuid, " in ", where_, ". Make them the same package, or ",
            "put one of the participants in `isolated` of [monorepo]"
        )))
    end
    for k in eachindex(ps.name)
        ps.isolated[k] && continue
        declare!(ps.name[k], string(ps.uuid[k]), relpath_or_path(existing_project_file(ps.root[k]), ps.workspace))
        testproj = existing_project_file(joinpath(ps.root[k], "test"))
        for (name, uuid) in get(parse_project(testproj), "deps", Dict{String, Any}())
            declare!(name, string(uuid), relpath_or_path(testproj, ps.workspace))
        end
    end
    runtests = Base.PkgId(parentmodule(@__MODULE__))
    declare!(runtests.name, string(runtests.uuid), "the combined run itself")
    return deps, declared
end

# The `LocalPreferences.toml` of the test projects of participants `shared`, together.
# Two that set one preference of a package to different values stop the run.
function merged_preferences(ps::Participants, shared::Vector{Int})
    out = Dict{String, Any}()
    from = Dict{Tuple{String, String}, String}()
    for k in shared
        path = joinpath(ps.root[k], "test", "LocalPreferences.toml")
        isfile(path) || continue
        for (pkg, prefs) in parse_project(path)
            prefs isa AbstractDict || continue
            mine = get!(Dict{String, Any}, out, pkg)
            for (key, value) in prefs
                if haskey(mine, key) && mine[key] != value
                    throw(ConfigError(string(
                        "the participants of a combined run share one environment, and they set preference ",
                        repr(key), " of ", pkg, " differently: ", repr(mine[key]), " in ", from[(pkg, key)], ", and ",
                        repr(value), " in ", relpath_or_path(path, ps.workspace), ". Make them agree, or put one of ",
                        "the participants in `isolated` of [monorepo]"
                    )))
                end
                mine[key] = value
                from[(pkg, key)] = relpath_or_path(path, ps.workspace)
            end
        end
    end
    return out
end

# The settings of a combined run itself: from the call, the `RUNTESTS_` variables and
# `[run]` of the workspace root, in that order. One in another package's `[run]` has
# no effect. The others are each package's own: a keyword or variable gives one to
# every package, and otherwise each package keeps its own.
const RUN_WIDE_KEYS = (:workers, :memory_threshold, :logs, :verbose, :monitor, :monitor_interval,
    :full_stacktraces, :full_names, :testset_name, :coverage, :seed, :failfast)
const PACKAGE_KEYS = Tuple(k for k in RUN_KEYS if !(k in RUN_WIDE_KEYS))

"""
    prepare_mono(paths; packages, name, tags, group, replay, announce, expansions, kwargs...)
        -> (; plan, participants, skipped, ignored)

Everything a combined run does up to starting a process, as `prepare` for one
package: which packages take part, their items as the selection narrows each, and
the plan. `paths` select within the packages that hold them; a path that is the
workspace root, or a package's root or `test/`, selects the whole of it. `skipped`
holds each package of the workspace that gives no item, with why; `ignored` each
run-wide setting in a package's own `[run]`, which has no effect.

`replay` names a run state of a combined run, any of its packages'. The run is made
again from the run states of that run that the packages hold: each package's items,
settings, profiles, `[order]` and seeds, and the run's settings from the one named,
with the call's own winning.

`item_keys`, pairs of a package's name and an item's name, selects those items, as an
editor asks for them: a key the workspace has no item of is returned in `unknown`
rather than being an error.
"""
function prepare_mono(paths = (); packages = nothing, name = nothing, tags = nothing, group = nothing,
                      replay = nothing, item_keys::Union{Nothing, Vector{Tuple{String, String}}} = nothing,
                      announce::Bool = true, expansions::Bool = true, kwargs...)
    haskey(kwargs, :config) && throw(ArgumentError(
        "`config` names a file to read in place of one package's test/TestItems.toml, and a combined run reads " *
            "each package's own"
    ))
    for k in keys(kwargs)
        k in RUN_KEYS || throw(unknown_keyword(k))
    end
    workspace, chosen, line = mono_paths(paths)
    PROJECT_ROOT[] = workspace
    ps = find_participants(workspace; packages)
    n = length(ps)
    narrowing, whole = assign_paths(ps, chosen)
    wanted = Dict{String, Set{String}}()
    item_keys === nothing || foreach(((pkg, it),) -> push!(get!(Set{String}, wanted, pkg), it), item_keys)
    called = name !== nothing || tags !== nothing || group !== nothing || !isempty(chosen) || item_keys !== nothing
    replayed = replay === nothing ? nothing : replay_records(String(replay), ps; announce)
    if replayed !== nothing
        # The run's settings as recorded, under the call's.
        recorded = recorded_settings(replayed.given)
        kwargs = merge(NamedTuple(k => v for (k, v) in pairs(recorded) if k in RUN_WIDE_KEYS), kwargs)
    end

    configs = [config_toml(joinpath(ps.root[k], "test"), nothing) for k in 1:n]
    selected = name !== nothing || tags !== nothing || !isempty(chosen) || item_keys !== nothing ||
        (replayed !== nothing && !called)
    gsel, lacking, group_name = mono_groups([read_groups(path, toml) for (path, toml) in configs],
                                            [path for (path, _) in configs], group, selected)
    # A replay that the call does not narrow runs what each run state recorded.
    # A package that no key names is not read.
    names_of_package(k) = item_keys !== nothing ? get(wanted, ps.name[k], nothing) :
        replayed === nothing || called || replayed.records[k] === nothing ? name :
        Set{String}(it.name for it in replayed.records[k].items)
    filters = [Filter(; name = names_of_package(k), tags, paths = narrowing[k], line = isempty(narrowing[k]) ? 0 : line,
                      group = gsel[k]) for k in 1:n]
    setups = [setup_modules(joinpath(ps.root[k], "test")) for k in 1:n]

    announce && println(stdout, label_prefix(), "reading the test files of ", plural(n, "package"), " under ",
                        joinpath(workspace, ""))
    t_files = time()
    items, errors, all_tags = RawItem[], ScanError[], Set{Symbol}()
    suite_names = [String[] for _ in 1:n]
    reasons = Union{Nothing, String}[nothing for _ in 1:n]
    for k in 1:n
        if replayed !== nothing && replayed.records[k] === nothing
            reasons[k] = replayed.why[k]
            continue
        elseif item_keys !== nothing && !haskey(wanted, ps.name[k])
            reasons[k] = "none of its items was asked for"
            continue
        elseif lacking[k]
            reasons[k] = "it declares no group `$group_name`"
            continue
        elseif !isempty(chosen) && !whole[k] && isempty(narrowing[k])
            reasons[k] = "no path given is in it"
            continue
        end
        files, strays, templates, environments = walk_test_dir(joinpath(ps.root[k], "test"))
        tags_k = Set{Symbol}()
        its = try
            scan(files, filters[k], setups[k]; strays, templates, expansions, suite_names = suite_names[k], environments,
                 suite_tags = tags_k)
        catch e
            e isa ScanFailure || rethrow()
            append!(errors, e.errors)
            continue
        end
        gsel[k] === nothing || check_tags_exist(Filter(; group = gsel[k]), tags_k)
        union!(all_tags, tags_k)
        isempty(its) && (reasons[k] = "no item matches the selection")
        append!(items, with_package(it, k) for it in its)
    end
    isempty(errors) || throw(ScanFailure(sort!(errors; by = e -> (e.file, e.line))))
    tags === nothing || check_tags_exist(Filter(; tags), all_tags)
    description = mono_description(name, tags, group, chosen, workspace)
    all_names = reduce(vcat, suite_names)
    unknown = Tuple{String, String}[]
    if item_keys !== nothing
        known = Set((ps.name[k], n) for k in 1:n for n in suite_names[k])
        unknown = sort!(unique!([key for key in item_keys if !(key in known)]))
        isempty(items) && throw(NoTestsError(
            "no test items matched the items asked for: none of " * join((string(p, " ", repr(i)) for (p, i) in item_keys), ", ")
        ))
    end
    isempty(items) && throw(NoTestsError("no test items matched " * description * name_hint(filters[1].name, all_names)))
    if name !== nothing
        hint = name_hint(filters[1].name, all_names)
        isempty(hint) || throw(NoTestsError("not every name given is a test item" * hint))
    end
    files_seconds = time() - t_files

    # The packages that give items, renumbered in their order.
    kept = [k for k in 1:n if reasons[k] === nothing]
    renumber = zeros(Int32, n); renumber[kept] = 1:length(kept)
    items = RawItem[with_package(it, renumber[it.package]) for it in items]
    announce && println(stdout, label_prefix(), "found ", plural(length(items), "test item"), " in ",
                        plural(length(kept), "package"), " in ", fmt_seconds(files_seconds))

    t_plan = time()
    overrides = map(kept) do k
        rs = replayed === nothing ? nothing : replayed.records[k]
        rs === nothing ? Dict{Symbol, Any}() :
            Dict{Symbol, Any}(key => v for (key, v) in pairs(recorded_settings(rs)) if key in PACKAGE_KEYS)
    end
    run_cfg, cfgs, ignored = mono_configs(ps, configs, kept, length(items), kwargs, overrides)
    if replayed !== nothing
        run_cfg, cfgs = replayed_configs(run_cfg, cfgs, [replayed.records[k] for k in kept], ps.root[kept], replayed.given,
                                         haskey(kwargs, :seed) && !haskey(recorded_settings(replayed.given), :seed))
        check_replayed_environments(items, [replayed.records[k] for k in kept], ps.root[kept])
    end
    sub = Participants(workspace, ps.name[kept], ps.uuid[kept], ps.root[kept], ps.isolated[kept], ps.skipped)
    # Of the packages that run: one that gives no item shares no worker and no load path.
    check_setup_names(sub, setups[kept])
    problems = import_problems(sub, items, Int[it.package for it in items],
                               [c.profiles for c in cfgs], setups[kept], [configs[k][1] for k in kept])
    isempty(problems) || throw(ScanFailure(problems))
    histories = History[history(ps.root[k]) for k in kept]
    full = name === nothing && tags === nothing && all(g -> g === nothing, gsel) && isempty(chosen)
    p = plan(items, run_cfg; histories, root = workspace,
             packages = Packages(ps.name[kept], ps.uuid[kept], ps.root[kept], ps.isolated[kept], cfgs,
                                 [sort(suite_names[k]) for k in kept]),
             strict_order = full, selection = full ? "" : description, suite_names = all_names)
    p.startup.files = files_seconds
    p.startup.plan = time() - t_plan
    skipped = [ps.skipped; [rel_slash(ps.root[k], workspace) => reasons[k] for k in 1:n if reasons[k] !== nothing]]
    isempty(skipped) || push!(p.notes, string("skipped: ", join((string(d, " (", why, ")") for (d, why) in skipped), ", ")))
    if replayed !== nothing && !isempty(replayed.gone)
        push!(p.notes, string("partial replay: no run state of ", join(replayed.gone, ", "), " is left from the replayed run"))
    end
    for (pkg, keys_) in ignored
        push!(p.notes, string("no effect: ", pkg, "'s [run] sets ", join(("`$k`" for k in keys_), ", "),
                              ", which a combined run takes from the call, the `RUNTESTS_` variables and ",
                              "test/TestItems.toml of the workspace root"))
    end
    return (; plan = p, participants = ps, skipped, ignored, unknown)
end

# The workspace that `paths` are in, the paths as absolute ones, and the line of a
# `file.jl:line` among them, 0 for none.
function mono_paths(paths)
    isempty(paths) && return first(monorepo_workspace(nothing)), String[], Int32(0)
    abs = String[]; line = Int32(0)
    for a in paths
        a isa AbstractString || throw(ArgumentError("a combined run takes paths, got $(repr(a))"))
        path, ln = split_line_suffix(String(a))
        ln == 0 || (line = ln)
        p = abspath(path)
        ispath(p) || throw(ArgumentError("no such file or directory: $p"))
        push!(abs, p)
    end
    line == 0 || length(abs) == 1 || throw(ArgumentError(
        "a `file.jl:line` target picks the item at that line, so it is given without other files or directories: " *
            "got $(join(map(repr, paths), ", "))"
    ))
    first_ = abs[1]
    project = find_project(isdir(first_) ? first_ : dirname(first_))
    project === nothing && throw(ArgumentError("could not find a Project.toml at or above $first_"))
    workspace = realpath(dirname(outermost_workspace(project)))
    for p in abs
        within(realpath(p), workspace) || throw(ArgumentError("$p is not in the workspace at $workspace"))
    end
    # The workspace root itself is all of it.
    any(p -> rstrip_path(realpath(p)) == workspace, abs) && return workspace, String[], line
    return workspace, String[realpath(p) for p in abs], line
end

# What each path selects: for each participant, the paths under its `test/` that
# narrow what it runs, and whether a path names the whole of it.
function assign_paths(ps::Participants, paths::Vector{String})
    narrowing = [String[] for _ in eachindex(ps.name)]
    whole = falses(length(ps))
    # The package a path is in is the innermost one: the root package holds them all.
    skipped_roots = [rstrip_path(normpath(joinpath(ps.workspace, rel))) for (rel, _) in ps.skipped]
    for path in paths
        ks = [k for k in eachindex(ps.root) if within(path, ps.root[k])]
        js = [j for j in eachindex(skipped_roots) if within(path, skipped_roots[j])]
        deepest(roots, is) = isempty(is) ? 0 : argmax(i -> length(roots[i]), is)
        k, j = deepest(ps.root, ks), deepest(skipped_roots, js)
        if j != 0 && (k == 0 || length(skipped_roots[j]) > length(ps.root[k]))
            throw(ArgumentError(string(path, " is in ", ps.skipped[j][1], ", which does not take part: ", ps.skipped[j][2])))
        end
        k == 0 && throw(ArgumentError("$path is in no package of the workspace at $(ps.workspace)"))
        testdir = joinpath(ps.root[k], "test")
        if rstrip_path(path) in (ps.root[k], testdir)
            whole[k] = true
            continue
        end
        startswith(path, joinpath(testdir, "")) ||
            throw(ArgumentError("$path is not under $testdir; Runtests only reads test files from `test/`"))
        isdir(path) || is_test_file(path) ||
            throw(ArgumentError("$path is not a test file; test files are named `*_test.jl` or `*_tests.jl`"))
        path in narrowing[k] || push!(narrowing[k], path)
    end
    for k in eachindex(ps.name)
        whole[k] && empty!(narrowing[k])
    end
    return narrowing, whole
end

"""
    mono_groups(groups, paths, requested, selected) -> (selections, lacking, name)

The group each package of a combined run selects by, as `select_group` gives it for
one package: the `group` keyword, `requested`, and for a call that selects nothing
else, `RUNTESTS_GROUP`, and otherwise `$DEFAULT_GROUP`. A package that does not
declare a group that the call or the variable asks for gives no items (`lacking`);
it is an error only when no package declares it. `$DEFAULT_GROUP` is each package's
own, and the whole suite of a package that does not declare it. `name` is the group
asked for, `$ALL_GROUP` when none is.
"""
function mono_groups(groups::Vector{Dict{String, TagExpr}}, paths::Vector{String}, requested, selected::Bool)
    n = length(groups)
    none = (Union{Nothing, GroupSelection}[nothing for _ in 1:n], falses(n), ALL_GROUP)
    if requested !== nothing
        (requested isa Union{AbstractString, Symbol} && !isempty(string(requested))) || throw(ArgumentError(
            "`group = $(repr(requested))`: expected the name of a group of [groups], \"$ALL_GROUP\" or \"$DEFAULT_GROUP\""
        ))
        name, asker = String(string(requested)), "the `group` keyword"
    else
        selected && return none
        env = strip(get(ENV, "RUNTESTS_GROUP", ""))
        name, asker = isempty(env) ? (DEFAULT_GROUP, "") : (String(env), "`RUNTESTS_GROUP`")
    end
    name == ALL_GROUP && return none
    source = isempty(asker) ? "the default" : string("from ", asker)
    sel = Union{Nothing, GroupSelection}[haskey(g, name) ? GroupSelection(name, g[name], source, paths[k]) : nothing
                                         for (k, g) in enumerate(groups)]
    name == DEFAULT_GROUP && return sel, falses(n), name
    lacking = BitVector([!haskey(g, name) for g in groups])
    if all(lacking)
        declared = sort!(unique!([g for gs in groups for g in keys(gs)]))
        near = near_group_names(name, [declared; ALL_GROUP])
        hint = isempty(near) ? "" : string(" (did you mean ", join(("`$g`" for g in near), " or "), "?)")
        msg = string(asker, " asks for group `", name, "`, which no package of the combined run declares", hint,
                     isempty(declared) ? "" : string("; they declare ", join(("`$g`" for g in declared), ", ")),
                     ", and `$ALL_GROUP` is the whole of every suite")
        throw(requested !== nothing ? ArgumentError(msg) : ConfigError(msg))
    end
    return sel, lacking, name
end

# Two participants with a setup of one name: a shared worker would find only one of
# them on its load path, and two setups without a project of their own would share a
# precompile cache. And a setup of a participant that is not isolated, with the name of
# a package that another participant puts in the union environment: a worker's project
# comes before the setups on its load path, so a shared worker loads that package for
# the name, where the participant's own run loads the setup.
function check_setup_names(ps::Participants, setups::Vector{Dict{Symbol, String}})
    seen = Dict{Symbol, Int}()
    clashes = String[]
    dir(j) = relpath_or_path(joinpath(ps.root[j], "test", TESTSETUPS_DIR), ps.workspace)
    for k in eachindex(ps.name), name in sort!(collect(keys(setups[k])))
        other = get(seen, name, 0)
        other == 0 && (seen[name] = k; continue)
        push!(clashes, string("`", name, "` in ", dir(other), " and in ", dir(k)))
    end
    isempty(clashes) || throw(ConfigError(string(
        "the packages of a combined run share one load path, so their setups need names of their own; ",
        "these setups have one name: ", join(clashes, ", "), ". Rename one of each"
    )))
    # The packages of the union environment, each with the first file that declares it.
    declarer = Dict{Symbol, String}(Symbol(Base.PkgId(parentmodule(@__MODULE__)).name) => "the combined run itself")
    for j in eachindex(ps.name)
        ps.isolated[j] && continue
        get!(declarer, Symbol(ps.name[j]), relpath_or_path(existing_project_file(ps.root[j]), ps.workspace))
        testproj = existing_project_file(joinpath(ps.root[j], "test"))
        for name in sort!(collect(dependency_names(testproj)))
            get!(declarer, name, relpath_or_path(testproj, ps.workspace))
        end
    end
    shadowed = String[]
    for k in eachindex(ps.name)
        ps.isolated[k] && continue
        # What the participant's own run loads by these names is a package too.
        own = push!(dependency_names(existing_project_file(joinpath(ps.root[k], "test"))), Symbol(ps.name[k]))
        for name in sort!(collect(keys(setups[k])))
            (name in own || !haskey(declarer, name)) && continue
            push!(shadowed, string("`", name, "` in ", dir(k), ", which ", declarer[name], " declares"))
        end
    end
    isempty(shadowed) || throw(ConfigError(string(
        "the packages of a combined run that are not isolated share one environment, and a worker loads a package of ",
        "it before a setup of the same name; these setups have the name of a package in it: ", join(shadowed, ", "),
        ". Rename the setup, or put its package or the one that declares the name in `isolated` of [monorepo]"
    )))
    return nothing
end

# The selection of a combined run, as the run says it.
function mono_description(name, tags, group, paths::Vector{String}, workspace::AbstractString)
    parts = String[]
    name === nothing || push!(parts, "name = $(repr(name))")
    tags === nothing || push!(parts, "tags = $(repr(tags))")
    group === nothing || push!(parts, "group `$(group)`")
    isempty(paths) || push!(parts, "paths " * join((rel_slash(p, workspace) for p in paths), ", "))
    return isempty(parts) ? "the filter" : join(parts, " and ")
end

"""
    mono_configs(ps, configs, kept, nunits, kwargs, overrides) -> (run, packages, ignored)

The settings of a combined run, and of each of its packages `kept`. The run's come
from the call, the `RUNTESTS_` variables and the workspace root's file; with
`workers = "auto"`, the CPU bound uses the most threads any of the packages'
workers start with. A package's come from the call and the variables, then from
`overrides` for it, a replayed run state's, and then from its own file, whose
run-wide settings have no effect and are returned in `ignored`, each with its
package; the root package's file is the root's. A package's `item_failfast` that
nothing sets is the run's `failfast`.
"""
function mono_configs(ps::Participants, configs, kept::Vector{Int}, nunits::Int, kwargs,
                      overrides::Vector{Dict{Symbol, Any}} = [Dict{Symbol, Any}() for _ in kept])
    root_path, root_toml = config_toml(joinpath(ps.workspace, "test"), nothing)
    shared = shared_profiles(root_path, root_toml, ps.workspace)
    run_kwargs = Dict{Symbol, Any}(pairs(kwargs))
    if requested_workers(kwargs, root_toml) == "auto"
        per_worker = maximum(k -> worker_threads(configs[k]..., kwargs, shared), kept)
        run_kwargs[:workers] = auto_workers(string(per_worker), nunits)
    end
    run = build_config(root_path, root_toml; nunits, shared, run_kwargs...)
    package_kwargs = Dict{Symbol, Any}(k => v for (k, v) in pairs(kwargs) if k in PACKAGE_KEYS)
    cfgs = RunConfig[]
    ignored = Pair{String, Vector{String}}[]
    for (n, k) in enumerate(kept)
        path, toml = configs[k]
        run_table = get(toml, "run", nothing)
        # The root's run-wide settings are the run's; another package's have no effect.
        if ps.root[k] != ps.workspace && run_table isa AbstractDict
            dropped = sort!([key for key in keys(run_table) if Symbol(key) in RUN_WIDE_KEYS])
            if !isempty(dropped)
                push!(ignored, ps.name[k] => dropped)
                toml = merge(toml, Dict("run" => Dict(key => v for (key, v) in run_table if !(key in dropped))))
            end
        end
        given = merge(overrides[n], package_kwargs)
        push!(cfgs, build_config(path, toml; given..., shared, workers = run.workers, failfast = run.failfast,
                                 seed = run.seed, logs = run.logs, coverage = false))
    end
    return run, cfgs, ignored
end

# The `workers` a combined run asks for, as the call, the variable or the root's file
# gives it, `"auto"` when none does.
function requested_workers(kwargs, root_toml)
    w = get(kwargs, :workers, nothing)
    w === nothing || return w
    env = strip(get(ENV, env_setting_name(:workers), ""))
    isempty(env) || return env == "auto" ? "auto" : something(tryparse(Int, env), env)
    run = get(root_toml, "run", Dict{String, Any}())
    return run isa AbstractDict ? get(run, "workers", "auto") : "auto"
end

# The `threads` of the workers of a package with the configuration `toml`, short of a
# keyword: the variable's, or its file's, or the default.
function package_threads(toml)
    env = strip(get(ENV, env_setting_name(:threads), ""))
    isempty(env) || return String(env)
    run = get(toml, "run", nothing)
    return string(run isa AbstractDict ? get(run, "threads", "2,1") : "2,1")
end

# The most threads a worker of a package with configuration file `path` starts with:
# its `threads`, and each of its profiles', those its workspace shares among them.
# `auto` counts as every CPU.
function worker_threads(path, toml, kwargs, shared::SharedProfiles)
    cpus = @static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS
    count_of(spec) = (t = first(split(spec, ',')); t == "auto" ? cpus : something(tryparse(Int, t), 2))
    most = count_of(threads_spec("threads", get(kwargs, :threads, package_threads(toml)), ArgumentError))
    for prof in values(read_profiles(path, toml; shared))
        isempty(prof.threads) || (most = max(most, count_of(prof.threads)))
    end
    return most
end

"""
    with_union_env(f, run)

`f()` with the union environment of a combined run active: the workspace
instantiated once, and the union of the participants' test environments
(`union_environment`) written into a directory of the run's own, which is removed
once `f` has returned and the workers with it. An isolated package's items run in
its own test project, which the instantiated workspace provides.
"""
function with_union_env(f, run)
    p = run.plan
    ps = Participants(p.root, p.packages.name, p.packages.uuid, p.packages.root, p.packages.isolated,
                      Pair{String, String}[])
    with_status_line_off(run.monitor) do
        say(run, "instantiating the workspace at ", p.root)
        instantiate_workspace(p.root)
    end
    dir = mktempdir(; prefix = "runtests_union_")
    original = Base.active_project()
    try
        union = union_environment(ps, dir)
        for k in eachindex(p.packages.name)
            push!(run.package_projects,
                  p.packages.isolated[k] ? something(project_file(joinpath(p.packages.root[k], "test")), union) : union)
        end
        Base.set_active_project(union)
        return f()
    finally
        Base.set_active_project(original)
        rm(dir; force = true, recursive = true)
    end
end

# The workspace's manifest instantiated, which every package and test project of the
# workspace shares; a resolve only when there is none.
function instantiate_workspace(root::AbstractString)
    original = Base.active_project()
    try
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            with_pkg() do Pkg, _
                Pkg.activate(root; io = devnull)
                manifest = Base.project_file_manifest_path(project_file(root))
                (manifest === nothing || !isfile(manifest)) && Pkg.resolve(; io = devnull)
                Pkg.instantiate(; allow_autoprecomp = false, io = devnull)
            end
        end
    catch e
        is_interrupt(e) && rethrow()
        throw(ConfigError("could not instantiate the workspace at $root: $(sprint(showerror, e))"))
    finally
        Base.set_active_project(original)
    end
    return nothing
end

"""
    chores_mono([root]; dry_run = false)

[`chores`](@ref) for each package of a combined run, as `runtests_mono` finds them,
and what a combined run needs on top, in one report with paths from the workspace
root. Before any package's chores change a file, it stops for what would stop a
combined run and what no chore fixes: two setups of one name, one dependency name
declared with two UUIDs, and two packages that set one preference differently. Then it
does each package's chores in turn, and the run states of checkouts that are gone
once. After them, the report says which items can share a worker: the groups of
profiles whose workers are alike, a profile that the workspace shares
(`monorepo_default`) with the packages that use it, and each package's own. It checks
each `using` and `import` written in the items, setups and profiles of each package
that shares workers against that package's own test environment, once the setups'
packages have their new dependencies. And it says of a package whose
`test/runtests.jl` does more than call `runtests` that a combined run does not run
that file.

Returns and throws as `chores` does. A [`ChoresError`](@ref) names the packages
whose chores already ran, and so may have changed files.
"""
function chores_mono(root::Union{Nothing, AbstractString} = nothing; dry_run::Bool = false)
    return exclusively() do
        ps = find_participants(root)
        PROJECT_ROOT[] = ps.workspace
        check_setup_names(ps, [setup_modules(joinpath(r, "test")) for r in ps.root])
        union_dependencies(ps)
        merged_preferences(ps, [k for k in eachindex(ps.name) if !ps.isolated[k]])
        fix = !dry_run
        todo = problems = 0
        done = String[]
        failure = nothing
        body = styled() do io
            # The run states of every checkout that is gone, for all the packages at once.
            gone = chore_task(io -> chore_gone_checkouts!(io, fix))
            for k in eachindex(ps.root)
                println(io, ps.name[k])
                part = styled() do pio
                    try
                        n, bad = package_chores!(pio, resolve_target((ps.root[k],)), fix, String[])
                        todo += n
                        problems += bad
                    catch e
                        is_interrupt(e) && rethrow()
                        failure = ChoresError(string(
                            "the chores of ", ps.name[k], " failed: ", sprint(showerror, e),
                            isempty(done) ? "" : string("; the chores of ", join(done, ", "), " ran before")
                        ))
                    end
                end
                foreach(line -> println(io, "  ", line), eachsplit(chomp(part), '\n'))
                failure === nothing || break
                push!(done, ps.name[k])
            end
            todo += said!(io, gone)
            failure === nothing || return print(io, "stopped: the chores of ", ps.name[length(done) + 1], " failed")
            print_worker_groups(io, ps)
            imports = written_import_problems(ps)
            if isempty(imports)
                println(io, "imports: each loads in the test environment of its own package")
            else
                println(io, "imports: ", plural(length(imports), "problem"), ", each one that the test environment of ",
                        "its own package cannot load:")
                foreach(e -> println(io, "  ", relpath_or_path(e.file, ps.workspace), ":", e.line, ": ", e.msg), imports)
                problems += length(imports)
            end
            foreach(line -> println(io, line), launcher_lines(ps))
            print_chores_outcome(io, fix, todo, problems, "Runtests.chores_mono()")
        end
        print(stdout, bracket(body, "[TEST]", string("chores of ", plural(length(ps), "package"), fix ? "" : ", checking only"),
                              "", :default))
        failure === nothing || throw(failure)
        dry_run && return problems == 0 && todo == 0
        problems == 0 || throw(ChoresError(string(plural(problems, "problem"), " to fix by hand, as the report says")))
        return true
    end
end

# The groups of workers of the packages `ps`, each the profiles whose items can share a
# worker (`pool_key`): a line with those profiles, by name and package, and what they
# set. A group of a profile that the workspace shares says where it is declared, and
# which packages declare the same again, which they need not. A package's own profile
# that is the same as the root's of its name says that `monorepo_default` would make
# them one group. The items in an environment directory have workers of their own.
function print_worker_groups(io::IO, ps::Participants)
    root_path, root_toml = config_toml(joinpath(ps.workspace, "test"), nothing)
    shared = shared_profiles(root_path, root_toml, ps.workspace)
    root_profiles = read_profiles(root_path, root_toml)
    declared_in(toml) = Set{Symbol}(Symbol(n) for n in keys(get(Dict{String, Any}, toml, "profiles")))
    root_declared = declared_in(root_toml)
    keys_ = Any[]
    # Each group's profiles: the package, the name, how the package has it, the profile,
    # and whether it is the same as a profile the root declares but does not share.
    groups = Vector{Tuple{Int, Symbol, Symbol, Profile, Bool}}[]
    environments = String[]
    for k in eachindex(ps.root)
        testdir = joinpath(ps.root[k], "test")
        path, toml = config_toml(testdir, nothing)
        declared = declared_in(toml)
        profiles = read_profiles(path, toml; shared)
        threads = package_threads(toml)
        for name in sort!(collect(keys(profiles)); by = n -> (n !== DEFAULT_PROFILE, string(n)))
            prof = profiles[name]
            s = get(shared.profiles, name, nothing)
            how = s === nothing ? :own : ps.root[k] == ps.workspace || !(name in declared) ? :shared :
                isempty(profile_differences(prof, s)) ? :copy : :own
            as_root = how === :own && name in declared && name in root_declared && ps.root[k] != ps.workspace &&
                isempty(profile_differences(prof, root_profiles[name]))
            key = pool_key(run_profile(prof, threads), k, ps.root[k], ps.isolated[k])
            g = findfirst(isequal(key), keys_)
            if g === nothing
                push!(keys_, key)
                push!(groups, Tuple{Int, Symbol, Symbol, Profile, Bool}[])
                g = length(groups)
            end
            push!(groups[g], (k, name, how, prof, as_root))
        end
        append!(environments, [relpath_or_path(d, ps.workspace) for d in walk_test_dir(testdir).environments])
    end
    n = length(groups)
    println(io, "workers: ", n == 1 ? "one group, so the items of every package can share a worker" :
        string(n, " groups, and an item shares a worker only with the items of its group"))
    of(k) = ps.isolated[k] ? string(ps.name[k], " (isolated)") : ps.name[k]
    and(names) = length(names) <= 1 ? join(names) : string(join(names[1:(end - 1)], ", "), " and ", names[end])
    for members in groups
        names = unique!([m[2] for m in members])
        who(name) = string("`", name, "` of ", and([of(m[1]) for m in members if m[2] === name]))
        parts = profile_parts(members[1][4], "")
        println(io, "  ", who(names[1]), ": ", isempty(parts) ? "sets nothing" : join(parts, " · "))
        foreach(name -> println(io, "    with ", who(name)), names[2:end])
        any(m -> m[3] !== :own, members) && println(io, "    shared by ", relpath_or_path(root_path, ps.workspace))
        copies = [of(m[1]) for m in members if m[3] === :copy]
        isempty(copies) || println(io, "    the same in the test/TestItems.toml of ", and(copies), ", which can leave it out")
        for m in members
            m[5] && println(io, "    the same as the root's `", m[2], "`: `monorepo_default = true` in ",
                            relpath_or_path(root_path, ps.workspace), " makes them one group")
        end
    end
    isempty(environments) ||
        println(io, "  items in an environment directory, with workers of their own: ", join(environments, ", "))
    return nothing
end

# The settings in which profile `own` differs from `shared`, by their keys.
function profile_differences(own::Profile, shared::Profile)
    out = String[]
    own.julia_args == shared.julia_args || push!(out, "julia_args")
    own.threads == shared.threads || push!(out, "threads")
    own.env == shared.env || push!(out, "env")
    same_code(own.init, shared.init) || push!(out, "init")
    same_code(own.test_end, shared.test_end) || push!(out, "test_end")
    own.preferences == shared.preferences || push!(out, "preferences")
    return out
end

# `import_problems` for every item, setup and profile of the participants `ps`, as
# their files are now. A suite that does not scan is its own chores' to report.
function written_import_problems(ps::Participants; all_setups::Bool = true)
    shared = shared_profiles(config_toml(joinpath(ps.workspace, "test"), nothing)..., ps.workspace)
    items, owner = RawItem[], Int[]
    profiles, setups, configs = Dict{Symbol, Profile}[], Dict{Symbol, String}[], String[]
    for k in eachindex(ps.root)
        testdir = joinpath(ps.root[k], "test")
        s = setup_modules(testdir)
        path, toml = config_toml(testdir, nothing)
        push!(setups, s); push!(configs, path)
        push!(profiles, try read_profiles(path, toml; shared) catch e; e isa ConfigError || rethrow(); Dict{Symbol, Profile}() end)
        w = walk_test_dir(testdir)
        its = try
            scan(w.tests, Filter(), s; environments = w.environments, expansions = false, suite_tags = Set{Symbol}())
        catch e
            e isa ScanFailure || rethrow()
            RawItem[]
        end
        append!(items, its); append!(owner, fill(k, length(its)))
    end
    return import_problems(ps, items, owner, profiles, setups, configs; all_setups)
end

# A line for each package whose `test/runtests.jl` does more than load packages and
# call `runtests()` or `runtests_mono()`, with nothing given: a combined run reads the
# package's files and not that one, so what else it does is done in the package's own
# runs alone. Loading packages, the package itself and Runtests among them, changes
# nothing in a run.
function launcher_lines(ps::Participants)
    calls = (:runtests, :runtests_mono, :(Runtests.runtests), :(Runtests.runtests_mono))
    plain_call(ex) = ex isa Expr && ex.head === :call && length(ex.args) == 1 && any(isequal(ex.args[1]), calls)
    loads(ex) = ex isa Expr && ex.head in (:using, :import)
    lines = String[]
    for root in ps.root
        path = joinpath(root, "test", RUNTESTS_FILE)
        isfile(path) || continue
        ex = parse_source(path)
        statements = ex === nothing ? Any[nothing] : [a for a in ex.args if !(a isa LineNumberNode)]
        (!isempty(statements) && plain_call(last(statements)) && all(loads, statements[1:(end - 1)])) && continue
        push!(lines, string(relpath_or_path(path, ps.workspace), " does more than call `Runtests.runtests()`, and a combined run does not ",
                            "run it"))
        push!(lines, string("  move what it sets to test/TestItems.toml of its package: run settings to [run], the group ",
                            "a run takes to `default` of [groups], and variables to `env` of a profile, or to its `init` ",
                            "for a computed value"))
    end
    return lines
end
