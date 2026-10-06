# Turns a Test.jl suite into Runtests test items: each top-level
# `@testset "name" begin ... end` becomes `@testitem "name" begin ... end` with the
# same body, inside `let` when it needs the local scope a testset had (see
# `measures_in_place` and `calls_include`); definitions at the top of a file go into
# a setup module the file's items load. And the shapes around testsets:
#
# - A module, or a testset that only wraps testsets and imports, is taken apart into
#   items named for the testsets around them. A module whose tests are one testset stays whole
#   as one item; several modules in a file get a setup each.
# - A loop around testsets becomes one item per testset, the loop inside it.
# - Tests outside any testset, with what runs between them, become an item.
# - A name several files have takes its file's topic in front.
#
#     julia port_testsets.jl <testdir>
#     julia port_testsets.jl <testdir> <shared setup: file.jl=ModuleName or -> <file.jl>...
#
# Given only the test directory, it reads the suite as `runtests.jl` runs it: the
# files it includes, in order, directly or in a `@safetestset`, inside testsets, `if`
# blocks on GROUP or on anything else, functions, and loops over literal lists of
# files, or as SciMLTesting's `run_tests` and ParallelTestRunner's `find_tests` find
# them; files that only run other files, read the same way; the tests `runtests.jl`
# holds itself; and the files of definitions the tests include, which become setups.
# A file that ran in `Main` gets what `runtests.jl` imported before it. Files under a
# directory with a project of its own are left as they are, for a person to port and
# a profile naming that directory as its `environment` to run, and Julia files
# nothing runs move to `.scripts/`. It writes a new `runtests.jl`, and lists what
# moved where. Given a list of files, it ports those.
#
# The ported files are written next to the originals as `<stem>_tests.jl` (a file
# already named like that is replaced) and `testsetups/<Stem>Setup.jl`. What it
# cannot port by rule it reports and keeps as written, for a person to look at.
# It cannot see what the tests assume about Main beyond the imports (names printed
# unqualified) or about paths relative to a file it moved (`@__DIR__`).
using TOML
const JS = Base.JuliaSyntax

# The file's top-level forms as exact source spans, comments included, from the
# lossless tree: SyntaxNode ranges leave out a trailing `end` in some forms. Forms
# joined by `;`, `a; b` or `@testset … end;`, are each a span of their own.
function toplevel_spans(text::String)
    spans = Tuple{UnitRange{Int}, JS.Kind}[]
    at = 1
    function visit(node)
        for c in JS.children(node)
            if JS.kind(c) == JS.K"toplevel"
                visit(c)
            else
                n = JS.span(c)
                push!(spans, (at:(at + n - 1), JS.kind(c)))
                at += n
            end
        end
    end
    visit(JS.parseall(JS.GreenNode, text))
    return spans
end

# Source text by byte range: ranges from the parser need not fall on character starts.
bytes(s, r) = String(codeunits(s)[r])

const TRIVIA = (JS.K"Whitespace", JS.K"NewlineWs", JS.K"Comment", JS.K";")

# `@testset "literal" [options] begin ... end` -> (name, body text between begin and
# end); anything else that is a testset -> (name or "", nothing).
function testset_parts(src::String)
    startswith(src, "@testset") || return nothing
    node = JS.parsestmt(JS.SyntaxNode, src)
    JS.kind(node) == JS.K"macrocall" || return nothing
    args = JS.children(node)
    name = ""
    for a in args[2:end]
        if JS.kind(a) == JS.K"string"
            parts = JS.children(a)
            if all(p -> JS.kind(p) == JS.K"String", parts)
                name = join(JS.sourcetext(p) for p in parts)
            end
            break
        end
    end
    last_ = args[end]
    if JS.kind(last_) == JS.K"block" && !isempty(name)
        r = JS.byte_range(last_)
        block = bytes(src, r)
        startswith(block, "begin") && endswith(block, "end") || return (name, nothing)
        return (name, bytes(block, 6:(ncodeunits(block) - 3)))
    end
    return (name, nothing)
end

# A testset's name up to where it first interpolates something: the part the
# iterations of a loop around it have in common. `"Headers ($(io_t), $(alg))"` is
# `"Headers"`.
function testset_label(src::AbstractString)
    node = JS.parsestmt(JS.SyntaxNode, src)
    for a in JS.children(node)[2:end]
        JS.kind(a) == JS.K"string" || continue
        literal = String[]
        for p in JS.children(a)
            JS.kind(p) == JS.K"String" || break
            push!(literal, JS.sourcetext(p))
        end
        return rstrip(join(literal), [' ', '(', '[', ':', ',', '-'])
    end
    return ""
end

# The variables a `for` header binds.
function loop_vars(header::AbstractString)
    spec = Meta.parse(header * "\nend").args[1]
    vars = Symbol[]
    bind!(x) = x isa Symbol ? push!(vars, x) : x isa Expr && x.head === :tuple ? foreach(bind!, x.args) : nothing
    for s in (spec.head === :block ? spec.args : [spec])
        s isa Expr && s.head === :(=) && bind!(s.args[1])
    end
    return vars
end

# A top-level `for` whose body holds testsets and loops of them, and nothing else, as
# `(headers, testset)` pairs: each testset with the headers of the loops around it,
# outermost first, and its own text from the end of what comes before it, comments
# and indentation included. A loop around one that binds the same variables again
# only repeats it, and is left out. `nothing` for any other statement.
function loop_testsets(src::String)
    startswith(src, "for ") || return nothing
    node = JS.parsestmt(JS.SyntaxNode, src)
    found = Tuple{Vector{String}, String}[]
    function visit(loop, headers)
        iter, body = JS.children(loop)
        header = bytes(src, first(JS.byte_range(loop)):last(JS.byte_range(iter)))
        vars = loop_vars(header)
        headers = [filter(h -> !issubset(loop_vars(h), vars), headers); header]
        before = last(JS.byte_range(iter))
        for c in JS.children(body)
            r = JS.byte_range(c)
            text = bytes(src, (before + 1):last(r))
            if JS.kind(c) == JS.K"for"
                visit(c, headers) || return false
            elseif JS.kind(c) == JS.K"macrocall" && startswith(bytes(src, r), "@testset")
                push!(found, (headers, lstrip(text, '\n')))
            else
                return false
            end
            before = last(r)
        end
        return true
    end
    return visit(node, String[]) && !isempty(found) ? found : nothing
end

# Whether a statement holds tests: a macro named like `Test`'s, `@testset` and
# `@inferred` among them, or a call that runs checks, `doctest` or a `test_` function.
function has_tests(@nospecialize ex)
    ex isa Expr || return false
    if ex.head === :macrocall
        m = ex.args[1]
        name = m isa Symbol ? m : m isa Expr && m.head === :. && m.args[end] isa QuoteNode ? m.args[end].value : nothing
        name isa Symbol && (startswith(string(name), "@test") || name === Symbol("@inferred")) && return true
    elseif ex.head === :call
        f = ex.args[1]
        name = f isa Symbol ? f : f isa Expr && f.head === :. && f.args[end] isa QuoteNode ? f.args[end].value : nothing
        name isa Symbol && (name === :doctest || startswith(string(name), "test_")) && return true
    end
    return any(has_tests, ex.args)
end

# Whether a statement assigns into one of `globals`, the names the file defines: it
# builds state other code reads, and belongs with the definitions. `t[k] = v` and
# `x.f = v` count, and so does `x = v` itself.
function builds_state(@nospecialize(ex), globals)
    ex isa Expr || return false
    if ex.head in (:(=), :(+=), :(-=), :(*=), :(|=))
        target = ex.args[1]
        while target isa Expr && target.head in (:ref, :., :tuple)
            target = target.head === :tuple ? nothing : target.args[1]
        end
        target isa Symbol && target in globals && return true
    end
    return any(a -> builds_state(a, globals), ex.args)
end

# Whether a body declares `local x` at its top level, for a block below to assign:
# at the top of a module, where an item's body runs, the block's `x` is its own.
declares_locals(body) = any(ex -> ex isa Expr && ex.head === :local, Meta.parseall(body).args)

const UPDATES = (:(=), :+=, :-=, :*=, :/=, :^=, :÷=, :%=, :|=, :&=, :⊻=, :<<=, :>>=)

# Whether a function the body defines, `->` and `do` blocks among them, assigns a
# variable the body assigns too: in a testset the function updates the body's
# variable; at the top of a module, where an item's body runs, it makes its own.
function assigns_from_closure(body)
    outer = Set{Symbol}(); inner = Set{Symbol}()
    bound!(set, x) = x isa Symbol ? push!(set, x) :
        x isa Expr && x.head in (:tuple, :(::)) ? foreach(a -> bound!(set, a), x.head === :(::) ? x.args[1:1] : x.args) : nothing
    function visit(@nospecialize(ex), set)
        ex isa Expr && ex.head !== :quote || return
        if ex.head === :-> || ex.head === :function || (ex.head === :(=) && is_function_def(ex))
            length(ex.args) >= 2 && visit(ex.args[2], inner)
        elseif ex.head === :for || ex.head === :generator
            # What a loop or a generator iterates over binds its own variables.
            specs = ex.head === :for ? ex.args[1:1] : ex.args[2:end]
            for spec in specs, a in (spec isa Expr && spec.head === :block ? spec.args : [spec])
                a isa Expr && a.head === :(=) ? visit(a.args[2], set) : visit(a, set)
            end
            ex.head === :for ? visit(ex.args[2], set) : visit(ex.args[1], set)
        else
            ex.head in UPDATES && bound!(set, ex.args[1])
            foreach(a -> visit(a, set), ex.args)
        end
    end
    visit(Meta.parseall(body), outer)
    return !isdisjoint(outer, inner)
end

# Whether a body calls `include`: what it includes defines globals, which the body's
# own assignments then run into, and in a testset, a local scope, they did not.
function calls_include(body)
    found = false
    visit(ex) = ex isa Expr && (
        ex.head === :call && (ex.args[1] === :include || ex.args[1] == :(Base.include)) && (found = true);
        foreach(visit, ex.args))
    visit(Meta.parseall(body))
    return found
end

# How many items a body's tests become: a testset that only wraps testsets counts as
# what it wraps, and a loop around testsets as the testsets in it. A testset is
# tests whatever its body holds, even only definitions.
function count_tests(body)
    n = 0
    for (r, k) in toplevel_spans(body)
        k in TRIVIA && continue
        src = bytes(body, r)
        parts = testset_parts(src)
        loops = loop_testsets(src)
        if parts !== nothing
            n += parts[2] !== nothing && is_wrapper(parts[2]) ? count_tests(parts[2]) : 1
        elseif loops !== nothing
            n += length(loops)
        else
            ex = Meta.parse(src; raise = false)
            n += !is_definition(ex) && has_tests(ex)
        end
    end
    return n
end

# Names a top-level definition binds, for the setup module's export list.
function defined_names(@nospecialize ex)
    ex isa Expr || return Symbol[]
    h = ex.head
    h === :block && return reduce(vcat, map(defined_names, ex.args); init = Symbol[])
    (h === :const || h === :global) && return defined_names(ex.args[1])
    if h === :macrocall
        args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
        # `@enum T A B` defines `T`, `A` and `B`; `@enumx T A B` only `T`, the rest
        # being inside it.
        if ex.args[1] in (Symbol("@enum"), Symbol("@enumx")) && !isempty(args)
            name(x) = x isa Symbol ? x : x isa Expr && x.head in (:(::), :(=)) ? name(x.args[1]) : nothing
            found = ex.args[1] === Symbol("@enum") ? map(name, args) : [name(args[1])]
            return Symbol[x for x in found if x isa Symbol]
        end
        return isempty(args) ? Symbol[] : defined_names(args[end])
    end
    if h === :(=) || h === :function
        lhs = ex.args[1]
        while lhs isa Expr && lhs.head in (:where, :(::))
            lhs = lhs.args[1]
        end
        lhs isa Symbol && return [lhs]
        lhs isa Expr && lhs.head === :call && lhs.args[1] isa Symbol && return [lhs.args[1]]
        lhs isa Expr && lhs.head === :tuple && return Symbol[a for a in lhs.args if a isa Symbol]
        return Symbol[]
    end
    if h === :struct || h === :abstract || h === :primitive
        n = ex.args[h === :struct ? 2 : 1]
        n isa Expr && n.head === :(<:) && (n = n.args[1])
        n isa Expr && n.head === :curly && (n = n.args[1])
        return n isa Symbol ? [n] : Symbol[]
    end
    h === :macro && return [Symbol("@", ex.args[1].args[1])]
    h === :module && return [ex.args[2]]
    return Symbol[]
end

is_definition(@nospecialize ex) = ex isa Expr && (ex.head in (:function, :struct, :abstract, :primitive, :macro, :const, :module) ||
    (ex.head === :(=) && (!isempty(defined_names(ex)) || defines_method(ex.args[1]))) ||
    (ex.head === :macrocall && !has_tests(ex) && is_definition(ex.args[end])) ||
    (ex.head === :block && all(a -> a isa LineNumberNode || is_definition(a), ex.args)))
# `Base.f(x) = ...`, `(::T)(x) = ...`: a method on a name the file does not own.
function defines_method(@nospecialize lhs)
    while lhs isa Expr && lhs.head in (:where, :(::))
        lhs = lhs.args[1]
    end
    return lhs isa Expr && lhs.head === :call
end
is_import(@nospecialize ex) = ex isa Expr && ex.head in (:using, :import)

# Whether a body measures the allocations of anything but a plain call. Julia
# measures `@allocated f(x, y)`, a call whose function and arguments are names or
# literals, from inside `f`; anything else it measures where it stands, which at a
# module's top level includes reaching the body's untyped globals.
function measures_in_place(body)
    found = false
    walk(ex) = ex isa Expr && (
        ex.head === :macrocall && ex.args[1] in (Symbol("@allocated"), Symbol("@allocations")) &&
            !Base.is_simply_call(ex.args[end]) && (found = true);
        foreach(walk, ex.args))
    walk(Meta.parseall(body))
    return found
end

# A body's top-level using/import statements, and the body without them.
function lift_imports(body)
    lifted = String[]; rest = IOBuffer()
    for (r, k) in toplevel_spans(body)
        src = bytes(body, r)
        if !(k in TRIVIA) && is_import(Meta.parse(src; raise = false))
            push!(lifted, strip(src))
        else
            print(rest, src)
        end
    end
    return lifted, String(take!(rest))
end

is_module(src) = startswith(src, "module ") || startswith(src, "baremodule ")
module_body(src) = (node = JS.parsestmt(JS.SyntaxNode, src); bytes(src, JS.byte_range(JS.children(node)[end])))

# Whether a testset's body holds nothing but testsets and imports. One that also
# defines something stays whole: taken apart, its locals would be globals of the
# file's setup, made at precompilation, and two testsets' `x` would be one.
function is_wrapper(body)
    ntests = 0
    for (r, k) in toplevel_spans(body)
        src = bytes(body, r)
        (k in TRIVIA || isempty(strip(src))) && continue
        if testset_parts(src) !== nothing
            ntests += 1
            continue
        end
        ex = Meta.parse(src; raise = false)
        is_import(ex) || return false
    end
    return ntests > 0
end

camel(stem) = join(uppercasefirst.(split(stem, r"[_\-/]")))

# What a `@testset` call is given besides its name and body: `verbose = true`, a
# custom testset type.
function testset_options(@nospecialize ex)
    ex isa Expr && ex.head === :macrocall || return String[]
    args = Any[a for a in ex.args[2:end] if !(a isa LineNumberNode)]
    isempty(args) && return String[]
    return String[string(a) for a in args[1:(end - 1)] if !(a isa String || (a isa Expr && a.head === :string))]
end

# The file a statement `include`s, as a path relative to `testdir`, when the
# statement is `include(p)` and `p` is known without running anything.
function include_target(@nospecialize(ex), dir, testdir)
    arg = include_arg(ex)
    arg === nothing && return nothing
    p = static_value(arg, Dict{Symbol, Any}(), dir)
    p isa AbstractString || return nothing
    return relpath(normpath(isabspath(p) ? p : joinpath(dir, p)), testdir)
end

# `dry`: only the names the items would have, before `collide` is known: the names
# more than one file has, which then take their file's topic in front.
#
# What the file's code saw where it ran, besides its own imports: `shared`, setup
# modules every item loads; `main_imports`, what `runtests.jl` imported before
# running it; `label`, the name it ran under, for items without a name of their own;
# `tags` and `skip`, for every item. A top-level `include` of a file in
# `helper_setups` becomes a `using` of that file's setup, and one of a file in
# `ported` is dropped: that file is ported in its own right.
function port_file(testdir, file; shared = String[], main_imports = String[], label = "",
                   tags = Symbol[], skip = "", helper_setups = Dict{String, String}(),
                   helper_imports = Dict{String, Vector{String}}(),
                   ported = Set{String}(), taken = Set{String}(), log = String[],
                   collide = Set{String}(), dry = false)
    path = joinpath(testdir, file)
    text = read(path, String)
    dir, stem = dirname(file), chopsuffix(basename(file), ".jl")
    # `test_codegen.jl` becomes `codegen_tests.jl`, with `CodegenSetup`.
    base = startswith(stem, "test_") ? chopprefix(stem, "test_") : stem
    setup = camel(joinpath(dir, base)) * "Setup"
    imports = String[]; helpers = String[]; exports = Symbol[]; items = String[]
    item_names = String[]   # each item's name, as claimed
    # The setups every item loads: those given, then those of the helpers the file includes.
    uses = String[shared...]
    # What those helpers import: their `include` brought it into the file's reach, and
    # a module's `using` does not pass it on.
    inherited = String[]
    # Statements every item runs after its imports, as the file ran them before its tests.
    prelude = String[]
    function load_helper!(inc)
        push!(uses, helper_setups[inc])
        append!(inherited, get(helper_imports, inc, String[]))
    end
    # A file of several modules taken apart gives each its own setup, named for it:
    # their definitions may share names, as two generated message types do.
    modules = filter(src -> is_module(src) && holds_tests(Meta.parse(src; raise = false)),
                     [bytes(text, r) for (r, k) in toplevel_spans(text) if !(k in TRIVIA)])
    per_module = count(m -> count_tests(module_body(m)) > 1, modules) > 1
    sections = Tuple{String, Vector{String}, Vector{String}, Vector{Symbol}}[]
    pending = ""   # comments and blank lines waiting for the form they precede
    # Where the statement just read went, when a comment after it on its line goes too.
    local trail::Union{Nothing, Vector{String}} = nothing
    loose = String[]   # tests outside any testset, waiting to become one item
    nloose = 0         # how many such items there are
    # The testsets taken apart around what is being walked, the outermost left out:
    # usually a file's topic, which its items do not need to repeat.
    context = String[]
    depth = 0
    topic = ""   # the outermost of them
    taken_here = Set{String}()
    function claim(name)
        if isempty(name) && !isempty(label)
            name = label
        elseif isempty(name)
            name = "$base $(length(items) + 1)"
            push!(log, "$file: tests without a literal name became $(repr(name))")
        end
        dry && return name
        name in collide && (name = "$base: $name")
        wanted = name; n = 2
        while name in taken
            name = "$wanted ($n)"; n += 1
        end
        push!(taken, name); push!(taken_here, name)
        name != wanted && push!(log, "$file: $(repr(wanted)) is taken; renamed $(repr(name))")
        return name
    end
    # What every item's body starts with: the setups it loads, then the imports. An
    # item that is the whole file has the file's own imports where they were: `using
    # .Bar` has to come after `module Bar`.
    function header(; whole = false)
        lines = String[]
        used = isempty(helpers) ? uses : [uses; setup]
        isempty(used) || push!(lines, "    using " * join(unique(used), ", "))
        append!(lines, "    " * i for i in unique([main_imports; inherited; whole ? String[] : imports]))
        whole || append!(lines, "    " * p for p in unique(prelude))
        return lines
    end
    keywords = string(isempty(tags) ? "" : string(" tags = [", join(repr.(tags), ", "), "]"),
                      isempty(skip) ? "" : string(" skip = ", skip))
    # The comments before a form, at the left edge as the item is: the form may have
    # been nested in something taken apart.
    leading(text) = join((lstrip(l) for l in split(lstrip(text, '\n'), '\n')), '\n')
    # `before` is what goes above it: the comments waiting for the next form, unless
    # the item's text brings its own.
    function item!(name, lines, inner, before = nothing)
        # One without a name of its own, a testset named by what it loops over say,
        # is named for the testsets around it.
        name = isempty(name) ? (isempty(context) ? topic : join(context, ": ")) :
            isempty(context) ? name : join([context; name], ": ")
        name = claim(name)
        push!(item_names, name)
        push!(items, string(leading(something(before, pending)), "@testitem ", repr(name), keywords,
                            " begin\n", join(lines, '\n'), inner, "end\n"))
        before === nothing && (pending = "")
    end
    # A testset's body without its `include`s of helpers, whose setups the items load.
    function without_helper_includes(body)
        out = IOBuffer()
        for (r, k) in toplevel_spans(body)
            part = bytes(body, r)
            inc = k in TRIVIA ? nothing : include_target(Meta.parse(part; raise = false), dirname(path), testdir)
            if inc !== nothing && haskey(helper_setups, inc)
                load_helper!(inc)
            else
                print(out, part)
            end
        end
        return String(take!(out))
    end
    # Blank lines stay empty: indenting one would only add trailing spaces.
    indented(src) = "\n" * join((isempty(l) ? l : "    " * l for l in split(src, '\n')), '\n') * "\n"
    # Tests written outside any testset, one statement after another: one item, named
    # for what ran the file, or for the first testset among them.
    function flush_loose!()
        isempty(loose) && return
        src = strip(join(loose), '\n')
        m = match(r"@testset\s+\"([^\"$\\]+)\"", src)
        push!(log, "$file: tests outside any testset became an item of their own: $(snippet(src))")
        item!(m === nothing || !isempty(label) ? "" : m.captures[1], header(), indented(src), "")
        empty!(loose)
        nloose += 1
    end
    walk(text) = (for (r, k) in toplevel_spans(text)
        src = bytes(text, r)
        # The `;` after `end;` ends a statement: nothing follows it anywhere.
        k == JS.K";" && continue
        if k in TRIVIA || isempty(strip(src))
            if k == JS.K"Comment" && trail !== nothing && !isempty(trail) && !occursin('\n', pending)
                trail[end] *= pending * src
                pending = ""
            else
                pending *= src
            end
            continue
        end
        trail = nothing
        ex = Meta.parse(src; raise = false)
        # A helper the file includes becomes a setup it loads, and a test file it
        # includes is ported in its own right.
        inc = include_target(ex, dirname(path), testdir)
        if inc !== nothing && (haskey(helper_setups, inc) || inc in ported)
            if haskey(helper_setups, inc)
                load_helper!(inc)
            else
                push!(log, "$file: includes $inc, which is ported as a test file of its own; the include is dropped")
            end
            pending = ""
            continue
        end
        # Tests outside any testset, and what runs between them: from the first
        # to the next definition, in order, as one item.
        if !is_definition(ex) && !is_import(ex) && !startswith(src, "@testset") && !is_module(src) &&
                loop_testsets(src) === nothing && (has_tests(ex) || (!isempty(loose) && !builds_state(ex, exports)))
            push!(loose, pending * src)
            pending = ""
            trail = loose
            continue
        end
        flush_loose!()
        # A module or a testset that only wraps testsets is taken apart: what it
        # holds is ported as if it were written at the top of the file.
        if is_module(src) && holds_tests(ex)
            body = module_body(src)
            mod = split(src)[2]
            # One whose tests are a single testset stays whole, as one item: what it
            # defines, and what the testset includes, then share a module as they did.
            if count_tests(body) == 1
                push!(log, "$file: module $mod holds one testset; kept whole as one item")
                m = match(r"@testset\s+\"([^\"$\\]+)\"", body)
                item!(m === nothing ? "" : m.captures[1], header(), indented(strip(body, '\n')))
                continue
            end
            push!(log, "$file: module $mod only wraps testsets; taken apart into items")
            pending = ""
            if per_module
                saved = (setup, imports, helpers, exports)
                setup, imports, helpers, exports = camel(mod) * "Setup", String[], String[], Symbol[]
                walk(body)
                push!(sections, (setup, imports, helpers, exports))
                setup, imports, helpers, exports = saved
            else
                walk(body)
            end
            trail = nothing
            continue
        end
        # A loop around testsets becomes one item per testset, with the loop inside it.
        loops = loop_testsets(src)
        if loops !== nothing
            push!(log, "$file: a loop around $(length(loops)) testsets became an item for each, the loop inside")
            for (headers, testset) in loops
                inner = string("\n", join(("    " * h for h in headers), '\n'), "\n", testset, "\n",
                               join(fill("    end", length(headers)), '\n'), "\n")
                item!(testset_label(testset), header(), inner)
            end
            continue
        end
        parts = testset_parts(src)
        if parts !== nothing && parts[2] !== nothing && is_wrapper(parts[2])
            push!(log, "$file: testset $(repr(parts[1])) only wraps testsets; taken apart into items")
            pending = ""
            outer = copy(context)
            depth += 1
            depth > 1 ? push!(context, parts[1]) : (topic = parts[1])
            walk(parts[2])
            trail = nothing
            depth -= 1
            depth == 0 && (topic = "")
            empty!(context); append!(context, outer)
            continue
        end
        if parts !== nothing
            name, body = parts
            body === nothing || isempty(helper_setups) || (body = without_helper_includes(body))
            # `@testset "case $T" for T in Ts`: named for the part of its name all its
            # iterations share.
            body === nothing && isempty(name) && (name = testset_label(src))
            body === nothing && push!(log, "$file: $(repr(name)) is kept whole: its body is not a begin-end block")
            options = testset_options(ex)
            isempty(options) || push!(log, "$file: $(repr(name)): the testset's options are dropped: $(join(options, ", "))")
            lines = header()
            # A testset's body is a local scope, and an item's body is the top of a
            # module, where its variables are globals: a body whose allocation
            # measurements would count reaching them, whose assignments could meet a
            # global something it includes defines, that declares locals for a block
            # to assign, or whose functions assign its variables, keeps a local scope
            # in `let`.
            # `using` cannot go inside a `let`, so such a body's own come out first.
            inner = if body === nothing
                indented(src)
            elseif measures_in_place(body) || calls_include(body) || declares_locals(body) || assigns_from_closure(body)
                lifted, rest = lift_imports(body)
                append!(lines, "    " * i for i in lifted)
                "\n    let" * rest * "    end\n"
            else
                rest = rstrip(body) * "\n"   # without the indentation of the testset's `end`
                startswith(rest, '\n') ? rest : "\n" * rest
            end
            item!(name, lines, inner)
            continue
        end
        if is_import(ex)
            push!(imports, strip(src))
            pending = ""
        elseif !is_definition(ex) && acts_on_module(ex)
            # `RuntimeGeneratedFunctions.init(@__MODULE__)` was about the module the
            # tests ran in: each item is one, and the setup's code may need it too.
            push!(log, "$file: a statement about the module it runs in goes into $setup and into each item: $(snippet(src))")
            push!(prelude, strip(src))
            push!(helpers, pending * src)
            pending = ""
            trail = helpers
        else
            is_definition(ex) || push!(log, "$file: a top-level statement that is not a definition goes into $setup, where it runs when the setup is precompiled: $(snippet(src))")
            append!(exports, defined_names(ex))
            push!(helpers, pending * src)
            pending = ""
            trail = helpers
        end
    end; flush_loose!())
    walk(text)
    # Tests outside testsets, in several groups or with nothing else: they ran top to
    # bottom among the code they need, so the file is one item, as it ran. Split, the
    # statements between them would run at precompilation, in the setup.
    if nloose > 1 || (nloose == 1 && length(items) == 1)
        empty!(items); empty!(item_names); empty!(sections); empty!(helpers); empty!(exports)
        setdiff!(taken, taken_here); empty!(taken_here)
        filter!(l -> !startswith(l, "$file: "), log)
        body = IOBuffer()
        for (r, k) in toplevel_spans(text)
            part = bytes(text, r)
            inc = k in TRIVIA ? nothing : include_target(Meta.parse(part; raise = false), dirname(path), testdir)
            if inc !== nothing && haskey(helper_setups, inc)
                load_helper!(inc)
            elseif inc !== nothing && inc in ported
                push!(log, "$file: includes $inc, which is ported as a test file of its own; the include is dropped")
            else
                print(body, part)
            end
        end
        whole = isempty(label) ? base : label
        push!(log, "$file: its tests run between the code they need, so the file is one item, $(repr(whole)), as it ran")
        pending = ""
        item!(whole, header(; whole = true), indented(strip(String(take!(body)), '\n')))
    end
    # A file whose tests became one item without a name of its own: the item is the file.
    unnamed = "@testitem " * repr("$base 1")
    if length(items) == 1 && occursin(unnamed, items[1]) && !(base in taken) && !(base in collide)
        dry && return [base]
        delete!(taken, "$base 1"); push!(taken, base)
        items[1] = replace(items[1], unnamed => "@testitem " * repr(base); count = 1)
        item_names[1] = base
        replace!(log, "$file: tests without a literal name became $(repr("$base 1"))" =>
                      "$file: its tests became one item, named $(repr(base)) for the file")
    end
    dry && return item_names
    # A file already named like a test file is replaced, or Runtests would read the
    # original as one too.
    out = joinpath(testdir, dir, occursin(r"_tests?$", stem) ? basename(file) : base * "_tests.jl")
    isempty(items) || open(out, "w") do io
        println(io, "# Ported from ", file, " by port_testsets.jl.\n")
        print(io, join(items, "\n"))
    end
    push!(sections, (setup, imports, helpers, exports))
    for (setup, imports, helpers, exports) in sections
        isempty(helpers) && continue
        mkpath(joinpath(testdir, "testsetups"))
        open(joinpath(testdir, "testsetups", setup * ".jl"), "w") do io
            println(io, "# The top-level definitions of ", file, ", for its test items.")
            println(io, "module ", setup, "\n")
            # Test was in reach wherever the file ran: imported in Main, or by `@safetestset`.
            # `using .Bar` waits for the definitions, `module Bar` among them.
            relative = filter(is_relative_import, imports)
            foreach(i -> println(io, i), unique(["using Test"; main_imports; inherited; setdiff(imports, relative)]))
            isempty(uses) || println(io, "using ", join(unique(uses), ", "))
            println(io)
            # Each brings the blank lines before it; one whose were used up still starts a line.
            print(io, strip(join((i == 1 || startswith(h, '\n') ? h : "\n" * h for (i, h) in enumerate(helpers))), '\n'), "\n\n")
            isempty(relative) || print(io, join(unique(relative), "\n"), "\n\n")
            exported = unique(exports)
            isempty(exported) || println(io, "export ", join(written.(exported), ", "))
            # Code this module includes or evaluates, and what a macro expands to,
            # defines names no list above can know of: the items need them too.
            needs_export_all(helpers) && println(io, EXPORT_ALL)
            println(io, "\nend")
        end
    end
    return isempty(items) ? nothing : out
end

# The start of a statement, on one line, for the list a person reads.
snippet(src, n = 70) = first(replace(strip(src), r"\s*\n\s*" => " ⏎ "), n)

written(n) = Base.isidentifier(n) || startswith(string(n), '@') ? string(n) : string("var", repr(string(n)))

needs_export_all(helpers) = any(h -> occursin(r"\binclude\(|@eval\b|\beval\(|^@(?!doc\b|enum\b|enumx\b)"m, h), helpers)

const EXPORT_ALL = """
for name in names(@__MODULE__; all = true)
    (startswith(string(name), '#') || name in (:eval, :include, nameof(@__MODULE__))) && continue
    Core.eval(@__MODULE__, Expr(:export, name))
end"""

### Reading a suite from runtests.jl ######################################

# `include(p)` or `Base.include(p)`, also with a function to map the code with: the
# expression of `p`.
function include_arg(@nospecialize ex)
    ex isa Expr && ex.head === :call && length(ex.args) >= 2 || return nothing
    f = ex.args[1]
    f === :include || f == :(Base.include) || return nothing
    return ex.args[end]
end

macro_name(@nospecialize m) = m isa Symbol ? m : m isa Expr && m.head === :. && m.args[end] isa QuoteNode ? m.args[end].value :
    m isa GlobalRef ? m.name : nothing

# Whether a statement runs test files: an `include`, a `@safetestset`, SciMLTesting's
# `run_tests`, ParallelTestRunner's `find_tests`, or `PerformanceTestTools.@include`,
# anywhere inside it.
function runs_files(@nospecialize ex)
    ex isa Expr || return false
    ex.head === :quote && return false
    ex.head === :call && ex.args[1] === :find_tests && return true
    include_arg(ex) !== nothing && return true
    ex.head === :. && ex.args[1] === :include && return true
    ex.head === :call && ex.args[1] in (:foreach, :map) && length(ex.args) >= 3 && ex.args[2] === :include && return true
    ex.head === :call && ex.args[1] in (:run_tests, :run_everything) && return true
    ex.head === :macrocall && macro_name(ex.args[1]) in (Symbol("@safetestset"), Symbol("@include")) && return true
    return any(runs_files, ex.args)
end

is_function_def(@nospecialize ex) = ex isa Expr && (ex.head === :function ||
    (ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :call))
function_name(@nospecialize ex) = (sig = ex.args[1]; sig isa Expr && sig.head === :where && (sig = sig.args[1]);
    sig isa Expr && sig.head === :call ? sig.args[1] : nothing)
# The parameter a function's body `include`s, as in `addtests(f) = include(f)`.
function included_param(@nospecialize ex)
    sig = ex.args[1]; sig isa Expr && sig.head === :where && (sig = sig.args[1])
    sig isa Expr && sig.head === :call || return nothing
    params = Symbol[a for a in sig.args[2:end] if a isa Symbol]
    found = nothing
    visit(x) = x isa Expr && (include_arg(x) in params ? (found = include_arg(x)) : foreach(visit, x.args))
    visit(ex.args[2])
    return found
end
# `addtests("a.jl")`, when runtests.jl defined `addtests` to include its argument: the file's expression.
function include_wrapper_call(s, @nospecialize ex)
    ex isa Expr && ex.head === :call && ex.args[1] isa Symbol && length(ex.args) == 2 || return nothing
    haskey(s.env, Symbol("#includes", ex.args[1])) || return nothing
    return ex.args[2]
end

# The value of `ex` known without running anything: strings, paths built from them,
# and lists of them; `nothing` when it is not known.
function static_value(@nospecialize(ex), env::Dict{Symbol, Any}, dir::AbstractString)
    ex isa AbstractString && return String(ex)
    ex isa Symbol && return get(env, ex, nothing)
    ex isa Expr || return nothing
    h = ex.head
    if h === :macrocall && ex.args[1] === Symbol("@__DIR__")
        return String(dir)
    elseif h === :macrocall && ex.args[1] === Symbol("@__FILE__")
        return joinpath(dir, "runtests.jl")
    elseif h === :string
        parts = Any[static_value(a, env, dir) for a in ex.args]
        all(p -> p isa AbstractString, parts) || return nothing
        return join(parts)
    elseif h === :vect || h === :tuple
        vals = Any[static_value(a, env, dir) for a in ex.args]
        any(isnothing, vals) && return nothing
        return vals
    elseif h === :call && ex.args[1] === :pwd && length(ex.args) == 1
        # `Pkg.test` runs runtests.jl in the test directory.
        return String(dir)
    elseif h === :call && ex.args[1] === :readdir && length(ex.args) == 2
        d = static_value(ex.args[2], env, dir)
        return d isa AbstractString && isdir(d) ? Any[f for f in sort(readdir(d)) if isfile(joinpath(d, f))] : nothing
    elseif h === :call && ex.args[1] === :filter && length(ex.args) == 3
        xs = static_value(ex.args[3], env, dir)
        xs isa AbstractVector && all(x -> x isa AbstractString, xs) || return nothing
        f = ex.args[2] isa Symbol ? get(env, Symbol("#fn", ex.args[2]), nothing) : ex.args[2]
        f isa Expr && f.head === :-> && name_only(f) || return nothing
        keep = try
            Core.eval(Module(:Names), :(filter($f, $(Vector{String}(xs)))))
        catch
            return nothing
        end
        return Any[keep...]
    elseif h === :call && ex.args[1] === :sort && length(ex.args) == 2
        xs = static_value(ex.args[2], env, dir)
        return xs isa AbstractVector && all(x -> x isa AbstractString, xs) ? Any[sort(Vector{String}(xs))...] : nothing
    elseif h === :comprehension && ex.args[1] isa Expr && ex.args[1].head === :generator && length(ex.args[1].args) == 2
        # `[f for f in readdir(@__DIR__) if match(r"^test_.*\.jl$", f) !== nothing]`
        body, spec = ex.args[1].args
        cond = spec isa Expr && spec.head === :filter ? spec.args[1] : true
        spec isa Expr && spec.head === :filter && (spec = spec.args[2])
        spec isa Expr && spec.head === :(=) && spec.args[1] isa Symbol || return nothing
        var = spec.args[1]
        xs = static_value(spec.args[2], env, dir)
        xs isa AbstractVector && all(x -> x isa AbstractString, xs) || return nothing
        name_only(Expr(:->, var, body)) && name_only(Expr(:->, var, cond)) || return nothing
        vals = try
            Core.eval(Module(:Names), :([$body for $var in $(Vector{String}(xs)) if $cond]))
        catch
            return nothing
        end
        return vals isa AbstractVector && all(v -> v isa AbstractString, vals) ? Any[vals...] : nothing
    elseif h === :call && ex.args[1] === :pathof && length(ex.args) == 2 && haskey(env, Symbol("#pathof"))
        name, path = env[Symbol("#pathof")]
        return ex.args[2] === Symbol(name) ? path : nothing
    elseif h === :call && ex.args[1] in (:joinpath, :string, :*, :dirname, :normpath)
        args = Any[static_value(a, env, dir) for a in ex.args[2:end]]
        all(a -> a isa AbstractString, args) || return nothing
        f = ex.args[1]
        f === :joinpath && return joinpath(args...)
        f === :dirname && return dirname(args[1])
        f === :normpath && return normpath(args[1])
        return join(args)
    end
    return nothing
end

# A function of file names only: what it can call is string functions.
const NAME_FUNCTIONS = Set{Symbol}([:startswith, :endswith, :occursin, :contains, :splitext, :basename, :dirname,
    :lowercase, :uppercase, :first, :last, :length, :in, :∈, :∉, :!, :(==), :(!=), :&&, :||, :isempty, :string, :*,
    :match, :(===), :(!==), :nothing, Symbol("@r_str")])
function name_only(@nospecialize f)
    params = f.args[1] isa Symbol ? [f.args[1]] : f.args[1] isa Expr ? f.args[1].args : Any[]
    ok(x) = x isa Symbol ? (x in NAME_FUNCTIONS || x in params) : x isa Expr ? x.head !== :quote && all(ok, x.args) : true
    return ok(f.args[2])
end

# A file the suite runs: its path relative to the test directory; whether it ran in
# a module of its own, as `@safetestset` and SciMLTesting run a file, rather than in
# `Main`; the name it ran under; imports written next to its `include`; its tags; and
# the condition it ran under, as a `skip` expression.
struct Entry
    file::String
    isolated::Bool
    label::String
    imports::Vector{String}
    tags::Vector{Symbol}
    skip::String
end

# Where a statement of `runtests.jl` stands: what an `include` there makes of a file.
# `loop` is the body of a loop over files, whose other statements build their paths.
struct Context
    isolated::Bool
    label::String
    imports::Vector{String}
    tags::Vector{Symbol}
    skip::String
    loop::Bool
end
Context() = Context(false, "", String[], Symbol[], "", false)
within(c::Context; kw...) = Context((get(kw, f, getfield(c, f)) for f in fieldnames(Context))...)

mutable struct Suite
    testdir::String
    entries::Vector{Entry}
    own::IOBuffer                  # what runtests.jl holds itself: tests, definitions, imports
    main_imports::Vector{String}   # what it imports into Main before the files it includes there
    exclude::Vector{Symbol}        # tags of the items that did not run with GROUP unset
    notes::Vector{String}
    env::Dict{Symbol, Any}         # names bound to values known without running anything
    groups::Set{Symbol}            # names bound to the GROUP environment variable
    defined::Set{Symbol}           # names its own definitions bind
    runners::Vector{String}        # files it ran that only ran other files, read as it is
end

const NOISE = (:println, :print, :display, :flush, :versioninfo, :exit, :sleep, :include_test, :runtests)

function runner_code(@nospecialize ex)
    ex isa Expr || return false
    if ex.head === :call
        f = ex.args[1]
        (f in NOISE || (f isa Expr && f.head === :. && f.args[1] in (:Pkg, :InteractiveUtils))) && return true
        f isa Symbol && occursin("include", string(f)) && return true
    elseif ex.head === :macrocall
        macro_name(ex.args[1]) in (Symbol("@info"), Symbol("@warn"), Symbol("@debug"), Symbol("@show"), Symbol("@error")) && return true
        # A macro given a file, as a runner of its own is.
        any(a -> a isa String && endswith(a, ".jl"), ex.args) && return true
    end
    return ex.head in (:if, :elseif, :try, :while, :for, :&&, :||) || any(runner_code, ex.args)
end

const FRAMEWORKS = (:SafeTestsets, :SciMLTesting, :PerformanceTestTools, :ReTestItems, :TestItemRunner, :TestEnv)

# An import without the packages that only ran files: `nothing` when that is all it had.
function without_frameworks(src, @nospecialize ex)
    root(a) = (a isa Expr && a.head in (:(:), :as) && (a = a.args[1]); a isa Expr && a.head === :. ? a.args[1] : nothing)
    roots = Any[root(a) for a in ex.args]
    all(r -> r in FRAMEWORKS, roots) && return nothing
    any(r -> r in FRAMEWORKS, roots) || return String(strip(src))
    ex.head === :using && all(a -> a isa Expr && a.head === :., ex.args) || return String(strip(src))
    return "using " * join((join(string.(a.args), ".") for a in ex.args if a.args[1] ∉ FRAMEWORKS), ", ")
end

# `get(ENV, "GROUP", "All")`: its default.
group_default(@nospecialize v) = v isa Expr && v.head === :call && v.args[1] === :get && length(v.args) == 4 &&
    v.args[2] === :ENV && v.args[3] isa String && occursin("GROUP", v.args[3]) && v.args[4] isa String ? v.args[4] : nothing

function bind!(s::Suite, @nospecialize(ex), dir)
    ex isa Expr || return nothing
    ex.head in (:const, :global, :local) && return bind!(s, ex.args[1], dir)
    # `is_test(f) = startswith(f, "test_")`: kept to evaluate `filter(is_test, …)` with.
    if ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :call && ex.args[1].args[1] isa Symbol
        f = Expr(:->, Expr(:tuple, ex.args[1].args[2:end]...), ex.args[2])
        name_only(f) && (s.env[Symbol("#fn", ex.args[1].args[1])] = f)
        return nothing
    end
    ex.head === :(=) && ex.args[1] isa Symbol || return nothing
    x, v = ex.args
    if group_default(v) !== nothing
        s.env[x] = group_default(v)
        push!(s.groups, x)
    else
        val = static_value(v, s.env, dir)
        val === nothing || (s.env[x] = val)
    end
    return nothing
end

kids(n) = something(JS.children(n), JS.SyntaxNode[])
node_text(src, n) = bytes(src, JS.byte_range(n))
# A block's statements, without a `begin` and `end` around them.
function statements(t)
    s = strip(t)
    return startswith(s, "begin") && endswith(s, "end") ? String(s[6:prevind(s, end, 3)]) : String(t)
end

function read_suite(testdir)
    s = Suite(testdir, Entry[], IOBuffer(), String[], Symbol[], String[], Dict{Symbol, Any}(), Set{Symbol}(), Set{Symbol}(), String[])
    project = joinpath(dirname(testdir), "Project.toml")
    name = isfile(project) ? get(TOML.parsefile(project), "name", "") : ""
    isempty(name) || (s.env[Symbol("#pathof")] = (name, joinpath(dirname(testdir), "src", name * ".jl")))
    walk_runs!(s, read(joinpath(testdir, "runtests.jl"), String), testdir, Context())
    return s
end

function walk_runs!(s::Suite, text, dir, ctx::Context)
    text = String(text)
    pending = ""
    for (r, k) in toplevel_spans(text)
        src = bytes(text, r)
        k == JS.K";" && continue
        if k in TRIVIA || isempty(strip(src))
            pending *= src
            continue
        end
        ex = Meta.parse(src; raise = false)
        if ex isa Expr && ex.head in (:error, :incomplete)
            push!(s.notes, "runtests.jl: cannot read $(snippet(src))")
        elseif runs_files(ex) || include_wrapper_call(s, ex) !== nothing
            run_files!(s, src, ex, dir, ctx)
        elseif ctx.loop
            bind!(s, ex, dir)
        elseif is_import(ex)
            line = without_frameworks(src, ex)
            if line !== nothing && ctx.isolated
                push!(ctx.imports, line)
            elseif line !== nothing
                push!(s.main_imports, line)
                print(s.own, pending, line, "\n")
            end
        elseif has_tests(ex) || is_definition(ex) ||
                ((!runner_code(ex) || builds_state(ex, s.defined)) && isempty(ctx.tags) && isempty(ctx.skip))
            # Under a condition, the rest prepared that branch's run, as
            # `activate_qa_env()` under `if GROUP == "QA"` does. A loop that fills
            # what runtests.jl defined, as `tzdata[name] = …` does, is the suite's.
            bind!(s, ex, dir)
            is_definition(ex) && union!(s.defined, defined_names(ex))
            (isempty(ctx.tags) && isempty(ctx.skip)) || has_tests(ex) &&
                push!(s.notes, "runtests.jl runs tests under a condition: they are ported to run always: $(snippet(src))")
            print(s.own, pending, src, "\n")
        else
            push!(s.notes, "runtests.jl runs code that is not a test, which nothing ports: $(snippet(src))")
        end
        pending = ""
    end
    return nothing
end

function add_file!(s::Suite, @nospecialize(arg), dir, ctx::Context, src)
    p = static_value(arg, s.env, dir)
    if !(p isa AbstractString)
        push!(s.notes, "runtests.jl includes a file this cannot name; port it by hand: $(snippet(src))")
        return nothing
    end
    file = relpath(normpath(isabspath(p) ? p : joinpath(dir, p)), s.testdir)
    path = joinpath(s.testdir, file)
    if !(file in s.runners) && isfile(path) && only_runs_files(path)
        # `@safetestset "A" include("a_item.jl")` and nothing else: read as runtests.jl is.
        push!(s.runners, file)
        walk_runs!(s, read(path, String), dirname(path), ctx)
        return nothing
    end
    push!(s.entries, Entry(file, ctx.isolated, ctx.label, copy(ctx.imports), copy(ctx.tags), ctx.skip))
    return nothing
end

# Whether a file only runs other files, files of tests among them: imports, and
# statements that include or `@safetestset` files, with nothing it tests or defines
# itself. One that only includes files of definitions is a file of definitions.
function only_runs_files(path)
    runs_tests = false
    visit(x) = x isa Expr && ((p = include_arg(x)) isa String ?
        (f = joinpath(dirname(path), p); runs_tests |= isfile(f) && file_holds_tests(f)) : foreach(visit, x.args))
    for ex in Meta.parseall(read(path, String); filename = path).args
        (ex isa LineNumberNode || is_import(ex)) && continue
        holds_tests(ex) && return false
        if runs_files(ex)
            visit(ex)
        elseif !runner_code(ex)
            return false
        end
    end
    return runs_tests
end

function add_files!(s::Suite, @nospecialize(arg), dir, ctx::Context, src)
    vals = static_value(arg, s.env, dir)
    if !(vals isa AbstractVector)
        push!(s.notes, "runtests.jl includes files this cannot list; port them by hand: $(snippet(src))")
        return nothing
    end
    foreach(v -> add_file!(s, v, dir, ctx, src), vals)
    return nothing
end

function run_files!(s::Suite, src, @nospecialize(ex), dir, ctx::Context)
    n = JS.parsestmt(JS.SyntaxNode, src)
    arg = include_arg(ex)
    wrapped = include_wrapper_call(s, ex)
    if arg !== nothing
        add_file!(s, arg, dir, ctx, src)
    elseif wrapped !== nothing
        add_file!(s, wrapped, dir, ctx, src)
    elseif is_function_def(ex) && (p = included_param(ex)) !== nothing
        # A function that includes its argument: its calls are what include the files.
        s.env[Symbol("#includes", function_name(ex))] = p
    elseif ex.head === :call && ex.args[1] === :find_tests
        # ParallelTestRunner: every Julia file under the directory but runtests.jl, each on its own.
        d = static_value(ex.args[2], s.env, dir)
        if d isa AbstractString
            for f in julia_files(d)
                f == "runtests.jl" || add_file!(s, f, d, within(ctx; isolated = true, label = chopsuffix(f, ".jl")), src)
            end
        else
            push!(s.notes, "runtests.jl: `find_tests` of a directory this cannot name; port its files by hand")
        end
    elseif ex.head === :. && ex.args[1] === :include
        add_files!(s, ex.args[2].args[1], dir, ctx, src)
    elseif ex.head === :call && ex.args[1] in (:foreach, :map)
        add_files!(s, ex.args[3], dir, ctx, src)
    elseif ex.head === :macrocall && macro_name(ex.args[1]) === Symbol("@safetestset")
        args = Any[a for a in ex.args[2:end] if !(a isa LineNumberNode)]
        inner = within(ctx; isolated = true, label = args[1] isa String ? args[1] : "", imports = String[])
        walk_runs!(s, statements(node_text(src, last(kids(n)))), dir, inner)
    elseif ex.head === :macrocall && macro_name(ex.args[1]) === Symbol("@include")
        add_file!(s, ex.args[end], dir, ctx, src)
        push!(s.notes, "runtests.jl runs a file in a process of its own, with julia flags of its own: give its items a profile with those flags, `sandbox = :name`: $(snippet(src))")
    elseif ex.head === :macrocall
        # A testset around the includes, `@time`, and the like: what is inside.
        walk_runs!(s, statements(node_text(src, last(kids(n)))), dir, ctx)
    elseif ex.head === :if
        branches!(s, src, n, dir, ctx)
    elseif ex.head in (:&&, :||)
        # `cond && include(…)`
        cond = ex.head === :&& ? ex.args[1] : Expr(:call, :!, ex.args[1])
        walk_runs!(s, node_text(src, last(kids(n))), dir, condition(s, cond, ctx, true))
    elseif ex.head === :for
        loop!(s, src, n, ex, dir, ctx)
    elseif ex.head === :call && ex.args[1] in (:run_tests, :run_everything)
        sciml!(s, src, n, ex, dir, ctx)
    elseif ex.head === :(=) && !(ex.args[1] isa Expr && ex.args[1].head === :call)
        # `t = @elapsed include(…)`
        walk_runs!(s, node_text(src, last(kids(n))), dir, ctx)
    elseif ex.head === :try
        walk_runs!(s, statements(node_text(src, kids(n)[1])), dir, ctx)
    elseif ex.head === :module
        # A module around the files is a namespace of their own, as a `@safetestset` is.
        walk_runs!(s, statements(node_text(src, last(kids(n)))), dir,
                   within(ctx; isolated = true, label = string(ex.args[2]), imports = String[]))
    elseif ex.head === :toplevel
        # `a; b` on one line: each statement on its own.
        foreach(c -> walk_runs!(s, node_text(src, c), dir, ctx), kids(n))
    elseif ex.head in (:function, :->, :let, :return) || (ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head === :call)
        walk_runs!(s, statements(node_text(src, last(kids(n)))), dir, ctx)
    elseif ex.head === :block
        walk_runs!(s, statements(src), dir, ctx)
    else
        push!(s.notes, "runtests.jl runs files in a way this cannot follow; port them by hand: $(snippet(src))")
    end
    return nothing
end

# The literal names a condition compares GROUP with.
function group_literals(@nospecialize(ex), groups, out = String[])
    ex isa Expr || return out
    is_group(x) = (x isa Symbol && x in groups) || group_default(x) !== nothing ||
        (x isa Expr && x.head === :call && x.args[1] in (:lowercase, :uppercase) && is_group(x.args[2]))
    if ex.head === :call && ex.args[1] in (:(==), :(===), :(!=), :in, :∈) && length(ex.args) == 3 &&
            (is_group(ex.args[2]) || is_group(ex.args[3]))
        for v in ex.args[2:3]
            v isa String && push!(out, v)
            v isa Expr && v.head in (:tuple, :vect) && append!(out, String[x for x in v.args if x isa String])
        end
    end
    foreach(a -> group_literals(a, groups, out), ex.args)
    return out
end

# Names a condition may use and still be decided by this process: Base's own.
const CONDITION_NAMES = Set{Symbol}([:VERSION, :Sys, :ENV, :Base, :Threads, :nthreads, :get, :haskey, :isempty,
    :(==), :(===), :(!=), :(!==), :(>=), :(<=), :(>), :(<), :!, :in, :∈, :∉, :lowercase, :uppercase, :occursin,
    :startswith, :endswith, :parse, :Int, :string, :isnothing, :prerelease, :iswindows, :isapple, :islinux, :isunix,
    :isbsd, :WORD_SIZE, :ARCH, :KERNEL, :major, :minor, :patch, Symbol("@v_str"), :nothing])

function decidable(@nospecialize(ex), groups)
    ex isa Symbol && return ex in CONDITION_NAMES || ex in groups
    ex isa Expr || return true
    ex.head === :quote && return false
    return all(a -> decidable(a, groups), ex.args)
end

# Whether `cond` holds with GROUP unset, or `missing` when that needs running more
# than Base.
function holds_by_default(@nospecialize(cond), s::Suite)
    decidable(cond, s.groups) || return missing
    subst(x) = x isa Symbol && x in s.groups ? s.env[x] : group_default(x) !== nothing ? group_default(x) :
        x isa Expr ? Expr(x.head, Any[subst(a) for a in x.args]...) : x
    v = try
        Core.eval(Module(:Condition), subst(cond))
    catch
        return missing
    end
    return v isa Bool ? v : missing
end

# What the statements under `cond` (or under its negation, `holds = false`) become:
# items tagged with the GROUP values the condition names, left out by default when
# they did not run with GROUP unset; or, for a condition on anything else, items that
# skip unless it holds.
# The tag of a GROUP value: a tag is written `:name`, so `2D_Diffusion` is `:_2d_diffusion`.
# When a value needs that, the new runtests.jl maps GROUP the same way.
const GROUP_TO_TAG = (r"\W" => "_", r"^(?=\d)" => "_")
function group_tag(s::Suite, g)
    name = lowercase(string(g))
    tag = replace(name, GROUP_TO_TAG...)
    tag == name || (s.env[Symbol("#group_to_tag")] = true)
    return Symbol(tag)
end

function condition(s::Suite, @nospecialize(cond), ctx::Context, holds::Bool)
    names = unique(lowercase.(group_literals(cond, s.groups)))
    filter!(g -> !(g in ("all", "everything")), names)
    if !isempty(names) || (cond isa Expr && any(g -> g in s.groups, collect_symbols(cond)))
        tags = holds ? Symbol[group_tag(s, g) for g in names] : Symbol[]
        runs = holds_by_default(cond, s)
        runs === missing && push!(s.notes, "runtests.jl: cannot tell whether files under `$cond` ran with GROUP unset; they are ported to")
        if runs === (!holds) && !isempty(tags)
            append!(s.exclude, tags)
        end
        return within(ctx; tags = unique([ctx.tags; tags]))
    end
    if !decidable(cond, s.groups)
        push!(s.notes, "runtests.jl ran some files only when `$cond`; their items run always: give them a `skip` or tags")
        return ctx
    end
    c = holds ? "!($cond)" : string(cond)
    return within(ctx; skip = isempty(ctx.skip) ? c : "$(ctx.skip) || $c")
end

collect_symbols(@nospecialize(ex), out = Symbol[]) = (ex isa Symbol && push!(out, ex);
    ex isa Expr && foreach(a -> collect_symbols(a, out), ex.args); out)

function branches!(s::Suite, src, n, dir, ctx::Context)
    ks = kids(n)
    cond = Expr(ks[1])
    walk_runs!(s, node_text(src, ks[2]), dir, condition(s, cond, ctx, true))
    if length(ks) >= 3
        rest = within(condition(s, cond, ctx, false))
        if JS.kind(ks[3]) == JS.K"elseif"
            branches!(s, src, ks[3], dir, rest)
        else
            walk_runs!(s, node_text(src, ks[3]), dir, rest)
        end
    end
    return nothing
end

function loop!(s::Suite, src, n, @nospecialize(ex), dir, ctx::Context)
    spec = ex.args[1]
    if !(spec isa Expr && spec.head === :(=) && spec.args[1] isa Symbol)
        push!(s.notes, "runtests.jl includes files in a loop this cannot follow; port them by hand: $(snippet(src))")
        return nothing
    end
    values = static_value(spec.args[2], s.env, dir)
    if !(values isa AbstractVector)
        push!(s.notes, "runtests.jl includes files in a loop over `$(spec.args[2])`, which this cannot list; port them by hand")
        return nothing
    end
    body = statements(node_text(src, last(kids(n))))
    saved = copy(s.env)
    for v in values
        s.env[spec.args[1]] = v
        walk_runs!(s, body, dir, within(ctx; loop = true))
    end
    s.env = saved
    return nothing
end

# SciMLTesting's `run_tests`. Without `core`, `groups` or `qa` it finds the files
# itself: every `test/*.jl` but runtests.jl is the group Core, and each group in
# `test_groups.toml` is a folder, run unless marked `in_all = false`, QA never.
# Every file runs in a `@safetestset` of its own.
function sciml!(s::Suite, src, n, @nospecialize(ex), dir, ctx::Context)
    kws = Dict{Symbol, Any}()   # keyword => (expression, node)
    flat = JS.SyntaxNode[]
    for c in kids(n)
        JS.kind(c) == JS.K"parameters" ? append!(flat, kids(c)) : push!(flat, c)
    end
    for c in flat
        JS.kind(c) == JS.K"=" || continue
        k = Expr(kids(c)[1])
        k isa Symbol && (kws[k] = (Expr(kids(c)[2]), kids(c)[2]))
    end
    everything = ex.args[1] === :run_everything
    if !any(k -> k in (:core, :groups, :qa), keys(kws))
        sciml_folders!(s, ctx, everything)
        return nothing
    end
    run(value, valnode, c) = if value isa Expr && value.head in (:function, :->)
        walk_runs!(s, statements(node_text(src, last(kids(valnode)))), dir, c)
    elseif value isa Expr && value.head === :tuple && any(a -> a isa Expr && a.head === :parameters, value.args)
        fields = Dict(a.args[1] => a.args[2] for p in value.args if p isa Expr && p.head === :parameters for a in p.args if a isa Expr)
        if haskey(fields, :env)
            push!(s.notes, "runtests.jl runs `$(snippet(node_text(src, valnode)))` in an environment of its own; " *
                           "Runtests runs such tests under a profile whose `environment` is a directory under test/ holding them and its Project.toml")
        elseif haskey(fields, :body)
            add_file!(s, fields[:body], dir, within(c; isolated = true), src)
        end
    else
        add_file!(s, value, dir, within(c; isolated = true), src)
    end
    haskey(kws, :core) && run(kws[:core]..., ctx)
    run_by_default = haskey(kws, :all) ? static_value(kws[:all][1], s.env, dir) : nothing
    for key in (:groups, :qa)
        haskey(kws, key) || continue
        value, valnode = kws[key]
        pairs = if key === :qa
            [("QA", value, valnode)]
        elseif value isa Expr && value.head === :call && value.args[1] === :Dict
            pnodes = [c for c in kids(valnode) if JS.kind(c) == JS.K"call"]
            [(p.args[2], p.args[3], last(kids(pn))) for (p, pn) in zip(value.args[2:end], pnodes) if p isa Expr]
        else
            push!(s.notes, "runtests.jl: SciMLTesting `$key` this cannot read; port its files by hand")
            continue
        end
        for (name, v, vn) in pairs
            tag = group_tag(s, name)
            by_default = run_by_default isa AbstractVector ? string(name) in run_by_default : true
            (everything || by_default) || push!(s.exclude, tag)
            run(v, vn, within(ctx; tags = [ctx.tags; tag]))
        end
    end
    return nothing
end

function sciml_folders!(s::Suite, ctx::Context, everything::Bool)
    testdir = s.testdir
    for f in sort(readdir(testdir))
        endswith(f, ".jl") && f != "runtests.jl" && isfile(joinpath(testdir, f)) || continue
        push!(s.entries, Entry(f, true, replace(chopsuffix(f, ".jl"), r"_tests?$" => ""), String[], copy(ctx.tags), ctx.skip))
    end
    groups_file = joinpath(testdir, "test_groups.toml")
    isfile(groups_file) || return nothing
    for (g, conf) in sort!(collect(TOML.parsefile(groups_file)); by = first)
        conf isa AbstractDict && g != "Core" && !haskey(conf, "group") || continue
        names = g == "QA" ? ["qa", "QA"] : [g, lowercase(g)]
        folder = findfirst(d -> isdir(joinpath(testdir, d)), names)
        if folder === nothing
            push!(s.notes, "SciMLTesting group $g has no folder under test/")
            continue
        end
        rel = names[folder]
        if any(p -> isfile(joinpath(testdir, rel, p)), ("Project.toml", "JuliaProject.toml"))
            push!(s.notes, "SciMLTesting group $g runs in an environment of its own, test/$rel/; once its files are ported, " *
                           "a profile with `environment = $(repr(rel))` in TestItems.toml runs them there")
            continue
        end
        tag = group_tag(s, g)
        (everything || (g != "QA" && get(conf, "in_all", true) == true)) || push!(s.exclude, tag)
        for f in sort(readdir(joinpath(testdir, rel)))
            endswith(f, ".jl") && isfile(joinpath(testdir, rel, f)) || continue
            push!(s.entries, Entry(joinpath(rel, f), true, "$g/$(replace(chopsuffix(f, ".jl"), r"_tests?$" => ""))",
                                   String[], [ctx.tags; tag], ctx.skip))
        end
    end
    return nothing
end

# A file of tests, not of helpers: tests in its top-level statements, or in those of a
# module around them, not only inside the functions it defines.
holds_tests(@nospecialize ex) = ex isa Expr && ex.head === :module ? any(holds_tests, ex.args[3].args) :
    !is_definition(ex) && has_tests(ex)
file_holds_tests(path) = any(holds_tests, Meta.parseall(read(path, String); filename = path).args)

# The files a file includes, at its top level or inside its testsets, as paths
# relative to `testdir`.
function top_includes(testdir, file)
    path = joinpath(testdir, file)
    out = String[]
    visit(x) = x isa Expr && x.head !== :quote &&
        ((inc = include_target(x, dirname(path), testdir)) === nothing ? foreach(visit, x.args) : push!(out, inc))
    foreach(visit, Meta.parseall(read(path, String); filename = path).args)
    return out
end

is_relative_import(src) = occursin(r"^(using|import)\s+\.", strip(src))

# A call given `@__MODULE__`: one about the module the code runs in.
acts_on_module(@nospecialize ex) = ex isa Expr && ex.head in (:call, :macrocall) && mentions_module(ex)
mentions_module(@nospecialize ex) = ex isa Expr &&
    ((ex.head === :macrocall && ex.args[1] === Symbol("@__MODULE__")) || any(mentions_module, ex.args))

# A file's top-level `using` and `import` statements, but those of its own modules.
function file_imports(path)
    text = read(path, String)
    out = String[]
    for (r, k) in toplevel_spans(text)
        k in TRIVIA && continue
        src = strip(bytes(text, r))
        is_import(Meta.parse(src; raise = false)) && !is_relative_import(src) && push!(out, src)
    end
    return out
end

# The module a helper file becomes: `shared/test_setup.jl` is `SharedTestSetup`.
function helper_setup(file)
    name = camel(chopsuffix(file, ".jl"))
    return endswith(name, "Setup") ? name : name * "Setup"
end

# A file of definitions the tests include, as a setup module: what it imports, what
# `runtests.jl` imported before it when it ran in Main (`imports`), and every name it
# defines, exported.
function write_helper_setup(testdir, file, setup, pkg, imports)
    text = read(joinpath(testdir, file), String)
    exports = Symbol[]; statements_ = String[]
    for (r, k) in toplevel_spans(text)
        k in TRIVIA && continue
        src = bytes(text, r)
        append!(exports, defined_names(Meta.parse(src; raise = false)))
        push!(statements_, src)
    end
    mkpath(joinpath(testdir, "testsetups"))
    open(joinpath(testdir, "testsetups", setup * ".jl"), "w") do io
        println(io, "# The definitions of ", file, ", which the tests include.\nmodule ", setup, "\n")
        foreach(l -> println(io, l), unique(["using Test"; isempty(pkg) ? String[] : ["using " * pkg]; imports]))
        println(io)
        print(io, strip(text), "\n\n")
        isempty(exports) || println(io, "export ", join(written.(unique(exports)), ", "))
        needs_export_all(statements_) && println(io, EXPORT_ALL)
        println(io, "\nend")
    end
    return nothing
end

# Every Julia file under `testdir` that a run would read or refuse: what the port has
# to account for.
function julia_files(testdir)
    out = String[]
    for (dir, dirs, files) in walkdir(testdir)
        filter!(d -> !startswith(d, '.') && d != "testsetups" && d != "testtemplates" &&
                     !any(p -> isfile(joinpath(dir, d, p)), ("Project.toml", "JuliaProject.toml")), dirs)
        for f in files
            endswith(f, ".jl") && push!(out, relpath(joinpath(dir, f), testdir))
        end
    end
    return out
end

# `text`, runtests.jl's own statements, without the definitions that neither `files`,
# those that ran in Main, nor the rest of `text` mention: `const GROUP = …`, a predicate picking files. They
# steered the run; ported, they would be a setup every item loads for nothing.
function without_unused(text, testdir, files, notes)
    used = Set{Symbol}()
    for f in files
        collect_symbols(Meta.parseall(read(joinpath(testdir, f), String); filename = f), used)
    end
    parts = [(bytes(text, r), k in TRIVIA ? nothing : Meta.parse(bytes(text, r); raise = false)) for (r, k) in toplevel_spans(text)]
    names = [ex === nothing || has_tests(ex) || !is_definition(ex) ? Symbol[] : defined_names(ex) for (_, ex) in parts]
    dead = falses(length(parts))
    # Until nothing changes: a definition only a dropped one mentions goes too.
    changed = true
    while changed
        changed = false
        for i in eachindex(parts, names, dead)
            (dead[i] || isempty(names[i])) && continue
            others = Set{Symbol}()
            for j in eachindex(parts, dead)
                j == i || dead[j] || parts[j][2] === nothing || collect_symbols(parts[j][2], others)
            end
            if !any(n -> n in used || n in others, names[i])
                dead[i] = changed = true
            end
        end
    end
    any(dead) && push!(notes, "runtests.jl defines $(join(unique(reduce(vcat, names[dead])), ", ")), which no test uses: dropped")
    # With the comments above them.
    for i in reverse(eachindex(parts, dead))
        if dead[i] && parts[i][2] !== nothing
            j = i - 1
            while j >= firstindex(parts) && parts[j][2] === nothing
                dead[j] = true; j -= 1
            end
        end
    end
    return join(first(p) for (p, d) in zip(parts, dead) if !d)
end

function port_suite(testdir)
    s = read_suite(testdir)
    project = joinpath(dirname(testdir), "Project.toml")
    pkg = isfile(project) ? get(TOML.parsefile(project), "name", "") : ""
    tests = Entry[]; helpers = Dict{String, Tuple{String, Bool}}()   # file => (setup, ran in Main)
    seen = Set{String}()
    # A file under a directory with a project of its own ran in that environment, as
    # `Pkg.activate("qa")` first had it, and is left as it is, with a note saying so.
    function env_of(file)
        d = dirname(file)
        while !isempty(d)
            any(p -> isfile(joinpath(testdir, d, p)), ("Project.toml", "JuliaProject.toml")) && return d
            d = dirname(d)
        end
        return nothing
    end
    elsewhere = Dict{String, Vector{String}}()
    union!(seen, s.runners)
    for e in s.entries
        e.file in seen && continue
        push!(seen, e.file)
        if !isfile(joinpath(testdir, e.file))
            push!(s.notes, "runtests.jl includes $(e.file), which does not exist")
        elseif env_of(e.file) !== nothing
            push!(get!(elsewhere, env_of(e.file), String[]), e.file)
        elseif file_holds_tests(joinpath(testdir, e.file))
            push!(tests, e)
        else
            helpers[e.file] = (helper_setup(e.file), !e.isolated)
        end
    end
    # What the tests include themselves: helpers, and test files to port in their own right.
    queue = copy(tests)
    while !isempty(queue)
        e = popfirst!(queue)
        for inc in top_includes(testdir, e.file)
            inc in seen && continue
            push!(seen, inc)
            if !isfile(joinpath(testdir, inc))
                push!(s.notes, "$(e.file) includes $inc, which does not exist")
            elseif env_of(inc) !== nothing
                push!(get!(elsewhere, env_of(inc), String[]), inc)
            elseif file_holds_tests(joinpath(testdir, inc))
                e2 = Entry(inc, e.isolated, "", e.imports, e.tags, e.skip)
                push!(tests, e2); push!(queue, e2)
            else
                helpers[inc] = (helper_setup(inc), !e.isolated)
            end
        end
    end
    for (d, files) in sort!(collect(elsewhere); by = first)
        push!(s.notes, "test/$d/ is an environment of its own, where $(join(files, ", ")) ran; once they are ported, " *
                       "a profile with `environment = $(repr(d))` in TestItems.toml runs them there")
    end
    for (file, (setup, main)) in helpers
        write_helper_setup(testdir, file, setup, pkg, main ? s.main_imports : String[])
    end
    helper_setups = Dict(file => setup for (file, (setup, _)) in helpers)
    helper_imports = Dict(file => file_imports(joinpath(testdir, file)) for file in keys(helpers))
    # What runtests.jl holds itself is a test file of its own, named for the package.
    # The files that ran in Main, where runtests.jl's definitions were in reach.
    in_main = [[e.file for e in tests if !e.isolated]; [f for (f, (_, main)) in helpers if main]]
    own = without_unused(String(take!(s.own)), testdir, in_main, s.notes)
    ownfile = nothing
    if any(src -> !is_import(Meta.parse(src; raise = false)), [bytes(own, r) for (r, k) in toplevel_spans(own) if !(k in TRIVIA)])
        # `SymbolicUtils`: `symbolic_utils.jl`, ported as `symbolic_utils_tests.jl`
        # with `SymbolicUtilsSetup`.
        stem = isempty(pkg) ? "main" : lowercase(replace(pkg, r"(?<=[a-z0-9])(?=[A-Z])" => "_"))
        taken_stem(t) = isfile(joinpath(testdir, t * ".jl")) || isfile(joinpath(testdir, t * "_tests.jl"))
        taken_stem(stem) && (stem *= "_main")
        n = 2
        while taken_stem(stem)
            stem = replace(stem, r"_main\d*$" => "_main$n"); n += 1
        end
        ownfile = stem * ".jl"
        write(joinpath(testdir, ownfile), own)
    end
    # Code that ran in Main before the files: runtests.jl's definitions, and the
    # helpers it included.
    main_setups = String[helpers[e.file][1] for e in s.entries if haskey(helpers, e.file) && !e.isolated]
    ported = Set(e.file for e in tests)
    function options(e, ownsetup)
        e === nothing && return (; shared = String[], main_imports = String[], label = pkg, tags = Symbol[], skip = "")
        shared = e.isolated ? String[] : String[(ownsetup === nothing ? String[] : [ownsetup])...; main_setups...]
        main_imports = e.isolated ? e.imports : [s.main_imports; e.imports]
        return (; shared, main_imports, label = e.label, tags = e.tags, skip = e.skip)
    end
    jobs = Tuple{String, Union{Nothing, Entry}}[]
    ownfile === nothing || push!(jobs, (ownfile, nothing))
    append!(jobs, ((e.file, e) for e in tests))
    names = reduce(vcat, (port_file(testdir, f; options(e, nothing)..., helper_setups, helper_imports, ported, dry = true) for (f, e) in jobs);
                   init = String[])
    collide = Set(n for n in names if count(==(n), names) > 1)
    log = String[]; taken = Set{String}(); moves = Pair{String, String}[]
    ownsetup = nothing
    for (f, e) in jobs
        out = port_file(testdir, f; options(e, ownsetup)..., helper_setups, helper_imports, ported, taken, log, collide)
        from = e === nothing ? "runtests.jl" : f
        out === nothing ? push!(log, "$from: holds no tests once ported") : push!(moves, from => relpath(out, testdir))
        # runtests.jl's own definitions, for the files that ran in Main after them.
        if e === nothing
            name = camel(chopsuffix(f, ".jl")) * "Setup"
            isfile(joinpath(testdir, "testsetups", name * ".jl")) && (ownsetup = name)
        end
    end
    if ownfile !== nothing
        rm(joinpath(testdir, ownfile))
        log = [replace(l, Regex("^" * ownfile * ":") => "runtests.jl:") for l in log]
    end
    for (file, (setup, _)) in sort!(collect(helpers); by = first)
        push!(moves, file => joinpath("testsetups", setup * ".jl"))
    end
    tagged = unique(reduce(vcat, (e.tags for e in tests); init = Symbol[]))
    excluded = unique(filter(in(tagged), s.exclude))
    open(joinpath(testdir, "runtests.jl"), "w") do io
        println(io, "using Runtests")
        if isempty(tagged)
            println(io, "Runtests.runtests()")
        else
            println(io, "# GROUP picks the items tagged with it; unset, the items runtests.jl ran by default.")
            println(io, "group = lowercase(get(ENV, \"GROUP\", \"\"))")
            dflt = isempty(excluded) ? "nothing" : repr(join(("!" * string(t) for t in excluded), " && "))
            selected = haskey(s.env, Symbol("#group_to_tag")) ? "Symbol(replace(group, r\"\\W\" => \"_\", r\"^(?=\\d)\" => \"_\"))" : "Symbol(group)"
            println(io, "Runtests.runtests(; tags = isempty(group) || group == \"all\" ? $dflt : $selected)")
        end
    end
    # A file that only ran others has nothing left to run.
    for f in s.runners
        to = joinpath(".scripts", f)
        mkpath(dirname(joinpath(testdir, to)))
        cp(joinpath(testdir, f), joinpath(testdir, to); force = true)
        push!(moves, f => to)
        push!(s.notes, "$f only ran other files, each ported on its own, so it moves to .scripts/")
    end
    # A Julia file nothing runs would stop a run: it goes where Runtests does not read.
    accounted = Set([seen..., "runtests.jl"])
    for f in julia_files(testdir)
        (f in accounted || any(m -> last(m) == f, moves)) && continue
        to = joinpath(".scripts", f)
        mkpath(dirname(joinpath(testdir, to)))
        cp(joinpath(testdir, f), joinpath(testdir, to); force = true)
        push!(moves, f => to)
        push!(s.notes, "$f is not run by runtests.jl, so it moves to .scripts/: port it if it should run, and update any path that names it")
    end
    for (from, to) in moves
        println(from == to ? "replaced $from" : "moved $from -> $to")
    end
    notes = [s.notes; log]
    isempty(notes) || println("\nfor a person to look at:\n  ", join(unique(notes), "\n  "))
    return nothing
end

function main(args)
    testdir = rstrip(abspath(args[1]), '/')
    length(args) == 1 && return port_suite(testdir)
    shared = args[2] == "-" ? nothing : String(split(args[2], '=')[2])
    if shared !== nothing
        # A file of shared helpers becomes a setup module that every ported file uses.
        file = String(split(args[2], '=')[1])
        text = read(joinpath(testdir, file), String)
        exports = Symbol[]
        for (r, k) in toplevel_spans(text)
            k in TRIVIA && continue
            append!(exports, defined_names(Meta.parse(bytes(text, r); raise = false)))
        end
        mkpath(joinpath(testdir, "testsetups"))
        open(joinpath(testdir, "testsetups", shared * ".jl"), "w") do io
            pkg = get(TOML.parsefile(joinpath(dirname(testdir), "Project.toml")), "name", "")
            println(io, "# Helpers shared by every test file (", file, ").\nmodule ", shared, "\n")
            # The file ran in Main after every test file's imports; it may use any of them.
            lines = ["using Test" * (isempty(pkg) ? "" : ", " * pkg)]
            for f in args[3:end]
                t = read(joinpath(testdir, f), String)
                for (r2, k2) in toplevel_spans(t)
                    src2 = bytes(t, r2)
                    k2 in TRIVIA || !is_import(Meta.parse(src2; raise = false)) || push!(lines, strip(src2))
                end
            end
            foreach(l -> println(io, l), unique(lines))
            println(io)
            print(io, strip(text), "\n\nexport ", join(unique(exports), ", "), "\n\nend\n")
        end
    end
    log = String[]; taken = Set{String}()
    files = args[3:end]
    given = shared === nothing ? String[] : [shared]
    names = reduce(vcat, (port_file(testdir, f; shared = given, dry = true) for f in files); init = String[])
    collide = Set(n for n in names if count(==(n), names) > 1)
    for file in files
        out = port_file(testdir, file; shared = given, taken, log, collide)
        println("ported ", file, " -> ", out === nothing ? "nothing: it holds no tests" : basename(out))
    end
    isempty(log) || println("\nfor a person to look at:\n  ", join(log, "\n  "))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
