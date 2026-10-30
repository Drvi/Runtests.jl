# Reading test files. The scanner parses and never evaluates, so no test file can
# hang, crash or allocate in the process that coordinates the run.

const TEST_FILE_SUFFIXES = ("_test.jl", "_tests.jl")
const TESTSETUPS_DIR = "testsetups"
const TESTTEMPLATES_DIR = "testtemplates"
# Input to the suite's tests, which the suite itself never reads: packages, broken
# projects and sources, reference files. Only the one at the top of `test/`.
const TESTFIXTURES_DIR = "testfixtures"

is_test_file(path::AbstractString) = any(s -> endswith(path, s), TEST_FILE_SUFFIXES)

"""
    discover(testdir) -> Vector{String}

Every test file under `testdir`, sorted. See [`walk_test_dir`](@ref).
"""
discover(testdir::AbstractString) = first(walk_test_dir(testdir))

"""
    walk_test_dir(testdir; claimed) -> (; tests, strays, templates)

Every test file under `testdir`; an error for every other Julia file there, each
saying where such a file belongs; and every test template, a `*_tests_template.jl`
in `testtemplates/` (see [`expansion_errors`](@ref)). Each is sorted by path.
Hidden files and directories, `testsetups/`, and `testfixtures/` at the top of
`testdir` are skipped. A directory with an environment of its own, a `Project.toml`
or a `JuliaProject.toml`, is read when a profile names it as its `environment`
(`claimed`, from [`claimed_environments`](@ref)), and its items run under that
profile; any other is an error among the strays, whether or not it holds tests. The
strays are reported, not skipped: a file of tests not named `*_test.jl` would
otherwise never run, and the run would pass without it, a template anywhere but
`testtemplates/` would never be expanded, and the tests of an environment nothing
names would never run.
"""
function walk_test_dir(testdir::AbstractString; claimed::Dict{String, Symbol} = Dict{String, Symbol}())
    tests, strays, templates = String[], ScanError[], String[]
    isdir(testdir) || return (; tests, strays, templates)
    templates_dir = joinpath(testdir, TESTTEMPLATES_DIR)
    # Told from the listing the walk reads anyway.
    function enter(dir, entries)
        dir == testdir && return true
        i = findfirst(e -> !entry_isdir(e) && entry_name(e) in PROJECT_NAMES, entries)
        (i === nothing || haskey(claimed, dir)) && return true
        push!(strays, unclaimed_error(joinpath(dir, entry_name(entries[i])), testdir))
        return false
    end
    descend(dir, d) = !(startswith(d, '.') || d == TESTSETUPS_DIR ||
                        (dir == testdir && (d == TESTTEMPLATES_DIR || d == TESTFIXTURES_DIR)))
    walk_dirs(testdir; enter, descend) do dir, n
        startswith(n, '.') && return
        if is_test_file(n)
            push!(tests, joinpath(dir, n))
        elseif is_template_file(n)
            push!(strays, misplaced_template_error(joinpath(dir, n)))
        elseif endswith(n, ".jl") && !(n == RUNTESTS_FILE && dir == testdir)
            push!(strays, stray_error(joinpath(dir, n)))
        end
    end
    isdir(templates_dir) && walk_dirs(templates_dir; descend = (_, d) -> !startswith(d, '.')) do dir, n
        (startswith(n, '.') || !endswith(n, ".jl")) && return
        path = joinpath(dir, n)
        if !is_template_file(n)
            push!(strays, ScanError(path, 0, NOT_A_TEMPLATE))
        elseif dir == templates_dir
            push!(templates, path)
        else
            push!(strays, misplaced_template_error(path))
        end
    end
    return (; tests = sort!(tests), strays = sort!(strays; by = e -> e.file), templates = sort!(templates))
end

# An environment under `test/` that no profile names: one error for the directory,
# at its project file, which is what either fix changes.
function unclaimed_error(projectfile::AbstractString, testdir::AbstractString)
    dir = dirname(projectfile)
    return ScanError(
        projectfile, 0,
        "$(relpath_or_path(dir)) has an environment of its own, which no profile names. To run its tests, " *
            "declare a profile with `environment = $(repr(relpath_or_path(dir, testdir)))` in test/TestItems.toml; " *
            "if it is input for the tests, move it under `test/$TESTFIXTURES_DIR/`, which the suite does not read."
    )
end

"""
    walk_dirs(file, root; enter = (dir, entries) -> true, descend = (dir, name) -> true)

Call `file(dir, name)` for each file in `root`, and in each directory under it that
`descend(parent, name)` lets the walk go to and whose listing `enter(dir, entries)`
then takes; a link counts as a file, as `walkdir` takes it. A directory is listed
once, with each entry's type from the listing, and nothing is `stat`ed, collected or
joined into a path but the directories the walk goes on to.

The walk's own, not `walkdir`'s, whose producer task reads the directories it has
handed out to decide where to go next: taken out of that list in place by a task on
another thread, as `chores` reads the suite, they were still gone into.
"""
function walk_dirs(file, root::AbstractString; enter = (_, _) -> true, descend = (_, _) -> true)
    pending = [String(root)]
    while !isempty(pending)
        dir = pop!(pending)
        entries = dir_listing(dir)
        enter(dir, entries) || continue
        for e in entries
            name = entry_name(e)
            if entry_isdir(e)
                descend(dir, name) && push!(pending, joinpath(dir, name))
            else
                file(dir, name)
            end
        end
    end
    return nothing
end

# The entries of `dir`, unsorted, each with its type as the listing has it, which a
# directory a link points at is not. `_readdirx` is internal to Base, and `walkdir`'s
# own way of reading a directory without a `stat` an entry, which took a walk of
# 10,000 files from 9 ms to 39. Without it, one `lstat` an entry.
@static if isdefined(Base.Filesystem, :_readdirx)
    dir_listing(dir::AbstractString) = Base.Filesystem._readdirx(dir; sort = false)
    entry_name(e::Base.Filesystem.DirEntry) = e.name
    entry_isdir(e::Base.Filesystem.DirEntry) = !islink(e) && isdir(e)
else
    dir_listing(dir::AbstractString) = stat_listing(dir)
end
stat_listing(dir::AbstractString) = Tuple{String, Bool}[(n, isdir(lstat(joinpath(dir, n)))) for n in readdir(dir; sort = false)]
entry_name(e::Tuple{String, Bool}) = e[1]
entry_isdir(e::Tuple{String, Bool}) = e[2]

# The profile whose environment holds `path`, the innermost when several do, or the
# default profile when none does.
function owner_of(path::AbstractString, claimed::Dict{String, Symbol})
    best, len = DEFAULT_PROFILE, 0
    for (dir, prof) in claimed
        startswith(path, joinpath(dir, "")) && ncodeunits(dir) > len && ((best, len) = (prof, ncodeunits(dir)))
    end
    return best
end

# `Pkg.test` runs this one, so it belongs at the top of `test/` and nowhere else.
const RUNTESTS_FILE = "runtests.jl"

# One error per file, because the fix is per file.
stray_error(path::AbstractString) = ScanError(
    path, 0,
    "not a test file. Test files are named `*_test.jl` or `*_tests.jl`, and test templates live in " *
        "`test/$TESTTEMPLATES_DIR/`; shared code goes in `test/$TESTSETUPS_DIR/` as a module that test " *
        "items load with `using`; input for the tests, such as fixture source, goes in `test/$TESTFIXTURES_DIR/`, " *
        "which the suite does not read. Rename it, move it there, or remove it."
)

misplaced_template_error(path::AbstractString) = ScanError(
    path, 0,
    "a test template belongs in `test/$TESTTEMPLATES_DIR/` itself, from where `Runtests.chores()` " *
        "expands it into `test/$(basename(expansion_of(path)))`: move it there"
)

const NOT_A_TEMPLATE = "not a test template. `test/$TESTTEMPLATES_DIR/` holds test templates, " *
    "`*_tests_template.jl` or `*_test_template.jl`, each of which `Runtests.chores()` expands into the " *
    "test file of its name without `_template`, in `test/`. Rename it, or move it out."

"""
    setup_modules(testdir) -> Dict{Symbol,String}

The modules `test/testsetups/` makes loadable: `Name.jl` or `Name/src/Name.jl`.
"""
function setup_modules(testdir::AbstractString)
    out = Dict{Symbol, String}()
    dir = joinpath(testdir, TESTSETUPS_DIR)
    isdir(dir) || return out
    for n in sort!(readdir(dir))
        path = joinpath(dir, n)
        if isfile(path) && endswith(n, ".jl")
            out[Symbol(chop(n; tail = 3))] = path
        elseif isdir(path)
            inner = joinpath(path, "src", n * ".jl")
            isfile(inner) && (out[Symbol(n)] = inner)
        end
    end
    return out
end

### Statement extraction ###################################################

# `Meta.parseall` returns a syntax error as a statement at the line where parsing
# stopped, rather than throwing. Nothing after it can be trusted, so it is the
# file's one error. `tags` gets every tag an item of the file carries, selected or
# not, and `profile` is the one its items run under unless they say otherwise.
function scan_file!(
        items::Vector{RawItem}, errors::Vector{ScanError}, names::Vector{ItemName}, tags::Set{Symbol},
        path::String, filter::Filter, known_setups, profile::Symbol = DEFAULT_PROFILE
    )
    src = try
        read(path, String)
    catch e
        push!(errors, ScanError(path, 0, "could not read file: $(sprint(showerror, e))"))
        return
    end
    line = Int32(0)
    # By index: iterating the untyped statements would box every step.
    statements = Meta.parseall(src; filename = path).args
    starts = line_starts(src)
    for k in eachindex(statements)
        a = statements[k]
        if a isa LineNumberNode
            line = Int32(a.line)
        elseif a isa Expr && a.head in (:error, :incomplete)
            msg = a.args[1]
            push!(errors, ScanError(path, line, msg isa AbstractString ? msg : sprint(showerror, msg)))
            return
        else
            # A statement's text runs to the line before the next one starts.
            next_line = k < lastindex(statements) && statements[k + 1] isa LineNumberNode ?
                Int((statements[k + 1]::LineNumberNode).line) : 0
            hash = text_hash(src, starts, Int(line), next_line)
            handle_statement!(items, errors, names, tags, a, path, line, filter, known_setups, profile, hash)
        end
    end
    return
end

# The byte at which each line of `src` starts.
function line_starts(src::String)
    starts = [1]
    for (k, c) in enumerate(codeunits(src))
        c == UInt8('\n') && push!(starts, k + 1)
    end
    return starts
end

# CRC32c of lines `first_line` up to `next_line` of `src`, the end of the file when
# `next_line` is 0, without the blank space that ends them and without carriage
# returns, so that a checkout with Windows line endings hashes as one without.
function text_hash(src::String, starts::Vector{Int}, first_line::Int, next_line::Int)
    1 <= first_line <= length(starts) || return UInt32(0)
    lo = starts[first_line]
    hi = first_line < next_line <= length(starts) ? starts[next_line] - 1 : ncodeunits(src)
    cu = codeunits(src)
    while hi >= lo && cu[hi] in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        hi -= 1
    end
    hi < lo && return UInt32(0)
    if UInt8('\r') in view(cu, lo:hi)
        return crc32c(filter(!=(UInt8('\r')), cu[lo:hi]))
    end
    return GC.@preserve src Base.unsafe_crc32c(pointer(src, lo), Csize_t(hi - lo + 1), UInt32(0))
end

### Header parsing #########################################################

# One method whatever the statement is, so that the call is direct, not a dispatch
# that boxes every argument once per item.
function handle_statement!(items, errors, names, tags, @nospecialize(ex), path, line, filter, known_setups, profile,
                           hash::UInt32 = UInt32(0))
    if !(ex isa Expr) || ex.head !== :macrocall || ex.args[1] !== Symbol("@testitem")
        push!(errors, ScanError(path, line, not_an_item(ex)))
        return
    end
    item = parse_testitem(ex, path, line, errors, known_setups, profile; hash)
    item === nothing && return
    union!(tags, item.tags)
    if !(matches_path(filter.paths, path) && matches_name(filter.name, item.name) &&
            matches_tags(filter.tags, item.tags) && matches_tags(filter.group, item.tags))
        push!(names, ItemName(item.name, path, item.line))
        return
    end
    push!(items, item)
    return
end

# Why a statement in a test file is refused: anything but a `@testitem` is.
function not_an_item(@nospecialize ex)
    ex isa Expr && ex.head === :for && return "test files may only contain `@testitem` declarations, " *
        "found a `for` loop; to declare an item per element, write a `@testtemplate` in a test template, " *
        "`test/$TESTTEMPLATES_DIR/*_tests_template.jl`, which `Runtests.chores()` expands into a test file"
    ex isa Expr && ex.head === :macrocall && ex.args[1] === Symbol("@testtemplate") && return "a " *
        "`@testtemplate` belongs in a test template, `test/$TESTTEMPLATES_DIR/*_tests_template.jl`, which " *
        "`Runtests.chores()` expands into a test file"
    what = ex isa Expr && ex.head === :macrocall ? string(ex.args[1]) : summary(ex)
    return "test files may only contain `@testitem` declarations, found `$what`"
end

# The keywords a `@testitem` accepts. A position in this tuple is a bit in the
# `seen` mask below, which is how a keyword given twice is caught without a set
# per item.
const ITEM_KEYWORDS = (:tags, :timeout, :retries, :skip, :failfast, :chain, :sandbox)

function keyword_bit(key::Symbol)
    i = findfirst(==(key), ITEM_KEYWORDS)
    return i === nothing ? UInt8(0) : UInt8(1) << (i - 1)
end

# `default_profile` is the profile of the environment the item's file is in: one a
# `sandbox` keyword may repeat but not change.
function parse_testitem(ex::Expr, path, line, errors, known_setups, default_profile::Symbol = DEFAULT_PROFILE;
                        hash::UInt32 = UInt32(0))
    # Indexed rather than sliced: slices would copy `ex.args` twice for every item.
    lo, hi = 2, length(ex.args)
    numbered = lo <= hi && ex.args[lo] isa LineNumberNode
    at = numbered ? Int32((ex.args[lo]::LineNumberNode).line) : Int32(line)
    numbered && (lo += 1)
    lo > hi && return scan_error!(errors, path, at, "`@testitem` needs a name and a body")
    last_arg = ex.args[hi]
    last_arg isa Expr && last_arg.head === :for && return scan_error!(errors, path, at,
        "`@testitem` declares one item; to declare one per element, write `@testtemplate` in a test template, " *
            "`test/$TESTTEMPLATES_DIR/*_tests_template.jl`, which `Runtests.chores()` expands into a test file")
    name = ex.args[lo]
    name isa String || return scan_error!(errors, path, at, "`@testitem` needs a string literal name, got `$(_show(name))`")
    isempty(strip(name)) && return scan_error!(errors, path, at, "`@testitem` name must not be blank")
    hi - lo >= 1 || return scan_error!(errors, path, at, "`@testitem $(repr(name))` has no `begin ... end` body")
    body = ex.args[hi]
    (body isa Expr && body.head === :block) ||
        return scan_error!(errors, path, at, "`@testitem $(repr(name))` must end with a `begin ... end` body")

    tags = nothing; setups = Symbol[]
    timeout = USE_RUN_DEFAULT; retries = USE_RUN_DEFAULT
    failfast = Int8(-1); chain = NO_CHAIN; profile = default_profile
    exclusive = false; skip = false
    seen = UInt8(0)
    for k in (lo + 1):(hi - 1)
        kw = ex.args[k]
        if !(kw isa Expr && kw.head === :(=) && kw.args[1] isa Symbol)
            return scan_error!(errors, path, at, "`@testitem $(repr(name))`: expected `key=value`, got `$(_show(kw))`")
        end
        key, val = kw.args[1], kw.args[2]
        bit = keyword_bit(key)
        if bit != 0
            seen & bit == 0 || return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `$key` given twice")
            seen |= bit
        end
        if key === :skip
            # The one keyword that may be an expression: it runs on the worker.
            skip = val isa QuoteNode ? val.value : val
        elseif key === :tags
            tags = symbol_list(val)
            tags === nothing &&
                return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `tags` must be a vector of symbols, got `$(_show(val))`")
        elseif key === :timeout
            v = literal(val)
            (is_number(v) && 0 < v <= MAX_TIMEOUT_S) ||
                return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `timeout` must be a positive number of seconds, at most $MAX_TIMEOUT_S, got `$(_show(val))`")
            timeout = Int32(ceil(v))
        elseif key === :retries
            v = literal(val)
            (is_whole_number(v) && 0 <= v <= MAX_RETRIES) ||
                return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `retries` must be an integer from 0 to $MAX_RETRIES, got `$(_show(val))`")
            retries = Int32(v)
        elseif key === :failfast
            v = literal(val)
            v isa Bool || return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `failfast` must be `true` or `false`, got `$(_show(val))`")
            failfast = Int8(v)
        elseif key === :chain
            v = literal(val)
            v isa Symbol || return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `chain` must be a symbol, got `$(_show(val))`")
            chain = v
        elseif key === :sandbox
            v = literal(val)
            if v isa Bool
                exclusive = v
            elseif v isa Symbol
                (default_profile === DEFAULT_PROFILE || v === default_profile) || return scan_error!(errors, path, at,
                    "`@testitem $(repr(name))`: its file is in the environment of profile `$default_profile`, " *
                        "so it runs under `$default_profile`, and `sandbox = :$v` asks for another profile"
                )
                profile = v
            else
                return scan_error!(errors, path, at, "`@testitem $(repr(name))`: `sandbox` must be `true` or a profile name, got `$(_show(val))`")
            end
        else
            return scan_error!(errors, path, at, 
                "`@testitem $(repr(name))`: unknown keyword `$key`; " *
                    "known keywords are tags, timeout, retries, skip, failfast, chain, sandbox"
            )
        end
    end
    if exclusive && chain !== NO_CHAIN
        return scan_error!(errors, path, at, 
            "`@testitem $(repr(name))`: `sandbox=true` means alone in a process and " *
                "`chain=:$chain` means together with its chain, so they cannot be combined"
        )
    end
    collect_setups!(setups, body, known_setups)
    return RawItem(
        name, path, at, tags === nothing ? Symbol[] : tags, unique!(setups), body, skip,
        timeout, retries, failfast, chain, profile, exclusive, hash
    )
end

# Keyword values must be literals: a keyword that needs evaluating would mean
# running user code to find out what to run.
struct NotALiteral end
function literal(@nospecialize(v))
    v isa Union{Bool, Integer, AbstractFloat, String, Char} && return v
    v isa QuoteNode && v.value isa Symbol && return v.value
    if v isa Expr && (v.head === :vect || v.head === :tuple)
        out = Any[]
        for a in v.args
            x = literal(a)
            x isa NotALiteral && return NotALiteral()
            push!(out, x)
        end
        return isempty(out) ? Any[] : [x for x in out]
    end
    if v isa Expr && v.head === :call && length(v.args) == 3 && v.args[1] isa Symbol &&
            (v.args[1]::Symbol) in (:*, :+, :-, :/)
        # `timeout=5*60` reads better than `timeout=300`, and folding literal
        # arithmetic looks nothing up.
        a, b = literal(v.args[2]), literal(v.args[3])
        (a isa Real && b isa Real) || return NotALiteral()
        return getfield(Base, v.args[1])(a, b)
    end
    return NotALiteral()
end

_show(@nospecialize(x)) = x isa NotALiteral ? "?" : sprint(show, x; context = :limit => true)

# `tags = [:a, :b]`, or the same as a tuple, as the symbols it names; `nothing` for
# anything else. Read straight into its vector, where `literal` would build an
# untyped one first: most items have tags.
function symbol_list(@nospecialize(v))
    (v isa Expr && (v.head === :vect || v.head === :tuple)) || return nothing
    args = (v::Expr).args
    out = Vector{Symbol}(undef, length(args))
    for k in eachindex(args)
        a = args[k]
        (a isa QuoteNode && a.value isa Symbol) || return nothing
        out[k] = a.value::Symbol
    end
    return out
end

# A problem with the item at `path:line`, recorded; `nothing`, for `parse_testitem`
# to return.
scan_error!(errors, path, line, msg) = (push!(errors, ScanError(path, line, msg)); nothing)

function collect_setups!(out::Vector{Symbol}, @nospecialize(ex), known)
    ex isa Expr || return out
    if ex.head === :using || ex.head === :import
        for a in ex.args
            m = module_head(a)
            m !== nothing && haskey(known, m) && push!(out, m)
        end
    else
        for a in ex.args
            collect_setups!(out, a, known)
        end
    end
    return out
end

# The module a `using` or `import` names, as in `M`, `M.x`, `M: f` and `M as N`.
function module_head(@nospecialize(a))
    a isa Expr || return nothing
    a.head === :. && !isempty(a.args) && a.args[1] isa Symbol && return a.args[1]
    (a.head === :(:) || a.head === :as) && return module_head(a.args[1])
    return nothing
end

### Driver #################################################################

"""
    scan(files, filter, known_setups; ntasks, strays, templates, expansions, suite_names, claimed) -> Vector{RawItem}

Read every file, in parallel, and return the items that pass `filter` sorted by
(file, line). Throws a `ScanFailure` listing every problem, so one run surfaces every
broken file: among them the `strays`, and, unless `expansions` is false, every
expansion of a template that is not the template's as it is now (see
[`expansion_errors`](@ref)). `suite_names`, when given, gets the name of every item
read, the filter's rejects included. An item in a directory a profile names as its
environment (`claimed`) runs under that profile.

A tag the filter names that no item of the suite carries is a slip, not a selection:
`tags = "!slw"` would select everything and say nothing. It throws an `ArgumentError`
for the `tags` keyword and a `ConfigError` for the group's tag expression.
"""
function scan(
        files::Vector{String}, filter::Filter, known_setups::Dict{Symbol, String};
        ntasks::Int = default_scan_tasks(),
        strays::Vector{ScanError} = ScanError[],
        templates::Vector{String} = String[],
        expansions::Bool = true,
        suite_names::Union{Nothing, Vector{String}} = nothing,
        claimed::Dict{String, Symbol} = Dict{String, Symbol}()
    )
    items, errors, rejected, tags = scan_files(files, filter, known_setups; ntasks, strays, templates, expansions, claimed)
    isempty(errors) || throw(ScanFailure(errors))
    check_tags_exist(filter, tags)
    if suite_names !== nothing
        append!(suite_names, (it.name for it in items))
        append!(suite_names, (r.name for r in rejected))
    end
    if filter.line > 0
        # The item the line is in, among every item of its file, selected or not: the
        # rest of the selection keeps that item or leaves nothing, never the one above.
        at = item_start(items, rejected, filter.paths, filter.line)
        at == 0 && throw(NoTestsError(above_first_item(items, rejected, filter.paths, filter.line)))
        items = RawItem[it for it in items if it.line == at && matches_path(filter.paths, it.file)]
    end
    return items
end

# Throws when the filter names a tag that none of `tags`, the suite's, is.
function check_tags_exist(filter::Filter, tags::Set{Symbol})
    unknown(names) = unique!(Symbol[t for t in names if !(t in tags)])
    missing_ = unknown(tag_names(filter.tags))
    isempty(missing_) || throw(ArgumentError(
        string("`tags = ", filter.tags isa TagExpr ? repr(filter.tags.text) : repr(filter.tags), "`: ",
               no_such_tags(missing_, tags))
    ))
    g = filter.group
    g === nothing && return nothing
    missing_ = unknown(tag_names(g.tags))
    isempty(missing_) || throw(ConfigError(
        string("group `", g.name, "` of [groups] in ", relpath_or_path(g.file), ", ",
               repr(g.tags.text), ": ", no_such_tags(missing_, tags))
    ))
    return nothing
end

function no_such_tags(missing_::Vector{Symbol}, tags::Set{Symbol})
    known = sort!([String(t) for t in tags])
    near = unique!(reduce(vcat, (nearest(String(t), known) for t in missing_); init = String[]))
    return string(
        length(missing_) == 1 ? "no test item has the tag " : "no test item has the tags ",
        join(("`$t`" for t in missing_), ", "),
        isempty(near) ? "" : string(" (did you mean ", join(("`$t`" for t in near), " or "), "?)"),
        isempty(known) ? "; no item in the suite has a tag" : string("; the suite's tags are ", join(known, ", "))
    )
end

"""
    scan_files(files, filter, known_setups; ntasks, strays, templates, expansions, claimed) -> (items, errors, rejected, tags)

What [`scan`](@ref) reads, without its verdict: the items that pass `filter` sorted
by (file, line), every problem found sorted the same way, the name and place of each
item the filter left out, and every tag an item of the suite carries. For a caller
that shows what it can read beside what is broken.
"""
function scan_files(
        files::Vector{String}, filter::Filter, known_setups::Dict{Symbol, String};
        ntasks::Int = default_scan_tasks(), strays::Vector{ScanError} = ScanError[],
        templates::Vector{String} = String[], expansions::Bool = true,
        claimed::Dict{String, Symbol} = Dict{String, Symbol}()
    )
    nt = clamp(ntasks, 1, max(1, length(files)))
    chunks = [(sizehint!(RawItem[], 64), ScanError[], sizehint!(ItemName[], 64), Set{Symbol}()) for _ in 1:nt]
    ch = Channel{String}(length(files))
    foreach(f -> put!(ch, f), files)
    close(ch)
    @sync for t in 1:nt
        items, errors, names, tags = chunks[t]
        Threads.@spawn begin
            its, errs, nms, tgs = $items, $errors, $names, $tags
            for path in ch
                scan_file!(its, errs, nms, tgs, path, filter, known_setups, owner_of(path, claimed))
            end
        end
    end
    errors = copy(strays)
    expansions && append!(errors, expansion_errors(files, templates))
    for c in chunks
        append!(errors, c[2])
    end
    items = reduce(vcat, (c[1] for c in chunks); init = RawItem[])
    sort!(items; by = i -> (i.file, i.line))
    rejected = reduce(vcat, (c[3] for c in chunks); init = ItemName[])
    append!(errors, duplicate_name_errors(items, rejected))
    sort!(errors; by = e -> (e.file, e.line))
    return items, errors, rejected, reduce(union!, (c[4] for c in chunks); init = Set{Symbol}())
end

# Twice the threads, to keep each busy while another task reads its file. Capped,
# since parsing is allocation-bound; at 18 threads, 16, 18 and 36 tasks took the
# same time within noise.
default_scan_tasks() = clamp(2 * Threads.nthreads(), 1, 36)

# `runtests("file.jl:42")` means the item that line is inside: the last one that
# starts at or before it.
# A line above every item of its file, said as such rather than as a selection that
# matched nothing.
function above_first_item(items::Vector{RawItem}, rejected::Vector{ItemName}, paths::Vector{String}, line::Int32)
    file = relpath_or_path(first(paths))
    starts = [x.line for x in Iterators.flatten((items, rejected)) if matches_path(paths, x.file)]
    isempty(starts) && return "$file holds no test items"
    return "line $line of $file is above its first test item, at line $(minimum(starts))"
end

# Where the item that `line` is inside starts: the last of the items in `paths`, the
# selected and the `rejected`, to start at or above it; 0 above the first.
function item_start(items::Vector{RawItem}, rejected::Vector{ItemName}, paths::Vector{String}, line::Int32)
    best = Int32(0)
    for x in Iterators.flatten((items, rejected))
        x.line <= line && x.line > best && matches_path(paths, x.file) && (best = x.line)
    end
    return best
end

# Over every item in the suite, selected or not: a name that is unique only
# because this run filtered out its twin is not a unique name.
function duplicate_name_errors(items::Vector{RawItem}, rejected::Vector{ItemName} = ItemName[])
    all_names = ItemName[ItemName(it.name, it.file, it.line) for it in items]
    append!(all_names, rejected)
    sort!(all_names; by = n -> (n.file, n.line))
    seen = Dict{String, ItemName}()
    errors = ScanError[]
    for it in all_names
        prev = get(seen, it.name, nothing)
        if prev === nothing
            seen[it.name] = it
        else
            push!(
                errors, ScanError(
                    it.file, it.line,
                    "duplicate test item name $(repr(it.name)); also declared at " *
                        "$(relpath_or_path(prev.file)):$(prev.line). Names identify items in " *
                        "TestItems.toml, in the run state and on the command line, so they must be unique."
                )
            )
        end
    end
    return errors
end
