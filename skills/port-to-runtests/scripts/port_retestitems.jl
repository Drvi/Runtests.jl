# Turns a ReTestItems suite into a Runtests one. The items carry over as written; what
# changes is around them:
#
# - every `@testsetup module S ... end`, in whatever file, becomes
#   `testsetups/S.jl` holding `module S ... end`, with the comments directly above it,
#   and leaves the file it was in;
# - `setup = [S, T]` on an item becomes `using S, T` at the top of its body;
# - `skip = :(expr)` becomes `skip = expr`: Runtests evaluates the expression itself,
#   and a quoted one would be an `Expr`, not a `Bool`;
# - `default_imports` and `_id` go: Runtests always imports `Test` and the package;
# - a file left holding nothing but comments is deleted, and a file of items not
#   named `*_test.jl` or `*_tests.jl` is renamed `<stem>_tests.jl`.
#
#     julia port_retestitems.jl <testdir>
#
# It edits the copy of the test directory it is given, in place. It prints each file it
# moved or deleted, as `moved a.jl -> a_tests.jl`, then a list headed "for a person to
# look at": `runtests.jl`, whose call and keywords go into `test/TestItems.toml`;
# code beside the items, which a test file cannot hold; keywords it does not know.
# Setups run their top-level code once, at precompilation, where a `@testsetup` ran it
# in every worker: read each one (SKILL.md, step 4, item 3).

const JS = Base.JuliaSyntax
# Where a node is in the text it was parsed from. Julia 1.11's JuliaSyntax has no
# `byte_range`.
byte_range(n) = JS.first_byte(n):JS.last_byte(n)

kids(n) = something(JS.children(n), JS.SyntaxNode[])
text_of(src, n) = String(codeunits(src)[byte_range(n)])
# The macro's name with its `@` or without: JuliaSyntax's text of it has the `@` from
# Julia 1.13 and not before.
is_macro(n, name) = JS.kind(n) == JS.K"macrocall" && !isempty(kids(n)) &&
    lstrip(JS.sourcetext(kids(n)[1]), '@') == lstrip(name, '@')

# The keywords of a `@testitem` call: (name, node) for each `name = value` argument.
keywords(call) = [(JS.sourcetext(kids(a)[1]), a) for a in kids(call)[2:end] if JS.kind(a) == JS.K"="]

# Where the comment lines directly above byte `at` start: a block of `#` lines with no
# blank line between it and `at`, which goes with what it describes.
function comments_above(src::String, at::Int)
    start = at
    lines = split(src[1:prevind(src, at)], '\n')
    pop!(lines)   # what precedes `at` on its own line
    k = length(lines)
    while k >= 1 && startswith(lstrip(lines[k]), '#')
        start -= ncodeunits(lines[k]) + 1
        k -= 1
    end
    return start
end

# The column the first statement of a block starts at, as spaces, for a line inserted
# before it.
function indent_at(src::String, at::Int)
    line_start = something(findprev(==('\n'), src, prevind(src, at)), 0) + 1
    return src[line_start:prevind(src, at)]
end

is_test_file(f) = endswith(f, "_test.jl") || endswith(f, "_tests.jl")

function port_file!(path, testdir, setupdir, notes, moves)
    src = read(path, String)
    rel = relpath(path, testdir)
    tree = JS.parseall(JS.SyntaxNode, src; filename = path, ignore_errors = true)
    edits = Tuple{UnitRange{Int}, String}[]   # byte ranges and what replaces them
    nitems = 0
    for node in kids(tree)
        r = byte_range(node)
        if is_macro(node, "@testsetup")
            mod = kids(node)[2]
            name = JS.sourcetext(kids(mod)[1])   # (module name body)
            from = comments_above(src, first(r))
            # A comment after the module's `end`, on its line, goes with it.
            eol = something(findnext(==('\n'), src, last(r)), ncodeunits(src) + 1)
            code = replace(src[first(r):prevind(src, eol)], r"^@testsetup\s+" => "")
            # `@__DIR__` was the directory of the file the setup was in, and is now
            # `testsetups/`: say the old one, so the paths built from it stay the same.
            moved = relpath(dirname(path), setupdir)
            occursin("@__DIR__", code) && (code = replace(code, "@__DIR__" => "normpath(joinpath(@__DIR__, $(repr(moved))))");
                push!(notes, "testsetups/$name.jl: `@__DIR__` named $(relpath(dirname(path), testdir) == "." ? "test/" : relpath(dirname(path), testdir)), and now names it as `joinpath(@__DIR__, $(repr(moved)))`"))
            occursin("@__FILE__", code) && push!(notes, "testsetups/$name.jl uses `@__FILE__`, which names the setup's file now: give it the path it needs")
            body = src[from:prevind(src, first(r))] * code * "\n"
            out = joinpath(setupdir, name * ".jl")
            isfile(out) && push!(notes, "two setups are called $name; the one in $rel is not written")
            isfile(out) || (mkpath(setupdir); write(out, body))
            push!(moves, "$rel: @testsetup $name -> testsetups/$name.jl")
            # The setup, the rest of its last line, and the newline that ends it; and the
            # blank lines after it, where they would open the file or follow another.
            stop = min(eol, ncodeunits(src))
            if from == 1 || endswith(src[1:prevind(src, from)], "\n\n")
                while stop < ncodeunits(src)
                    nl = something(findnext(==('\n'), src, nextind(src, stop)), ncodeunits(src))
                    isempty(strip(src[nextind(src, stop):nl])) || break
                    stop = nl
                end
            end
            push!(edits, (from:stop, ""))
        elseif is_macro(node, "@testitem")
            nitems += 1
            item_edits!(edits, notes, src, rel, node)
        elseif JS.kind(node) != JS.K"doc"   # a docstring or comment-only node needs nothing
            line = JS.source_line(node)
            push!(notes, "$rel:$line holds code that is not an item, which a test file cannot hold: move it into a setup, or into the items that use it")
        end
    end
    # Back to front, so each range is still where it was.
    for (r, s) in sort!(edits; by = e -> first(e[1]), rev = true)
        src = string(src[1:prevind(src, first(r))], s, src[nextind(src, last(r)):end])
    end
    if nitems == 0 && isempty(strip(replace(src, r"#[^\n]*" => "")))
        rm(path)
        push!(moves, "deleted $rel: nothing is left in it")
    elseif nitems > 0 && !is_test_file(basename(path))
        to = joinpath(dirname(path), replace(basename(path), r"(_?test(s)?)?\.jl$" => "") * "_tests.jl")
        write(to, src); rm(path)
        push!(moves, "moved $rel -> $(relpath(to, testdir))")
    else
        write(path, src)
    end
    return nothing
end

function item_edits!(edits, notes, src, rel, call)
    name = text_of(src, kids(call)[2])
    used = String[]
    for (key, kw) in keywords(call)
        r = byte_range(kw)
        # The keyword and the blank before it.
        from = something(findprev(!isspace, src, prevind(src, first(r))), 0) + 1
        if key == "setup"
            v = kids(kw)[2]
            append!(used, [JS.sourcetext(x) for x in kids(v)])
            push!(edits, (from:last(r), ""))
        elseif key == "skip"
            v = kids(kw)[2]
            if JS.kind(v) == JS.K"quote"
                inner = text_of(src, v)
                # The parentheses stay: `skip = (a == b)` reads as one value.
                unq = startswith(inner, ":(") && endswith(inner, ")") ? inner[2:end] :
                    (push!(notes, "$rel: @testitem $name: `skip = $inner` quotes something other than an expression in parentheses; write it as an expression that gives a Bool"); continue)
                push!(edits, (byte_range(v), unq))
            end
        elseif key in ("default_imports", "_id")
            push!(edits, (from:last(r), ""))
        elseif !(key in ("tags", "timeout", "retries", "failfast", "skip"))
            push!(notes, "$rel: @testitem $name: Runtests has no `$key`; see the table in reference/source-shapes.md")
        end
    end
    isempty(used) && return nothing
    block = kids(call)[end]
    stmts = kids(block)
    if isempty(stmts)
        # `begin end` with nothing in it: the `using` is all there is.
        r = byte_range(block)
        push!(edits, (r, "begin\n    using $(join(used, ", "))\nend"))
    else
        at = first(byte_range(stmts[1]))
        pad = indent_at(src, at)
        push!(edits, (at:at - 1, "using $(join(used, ", "))\n$pad"))
    end
    return nothing
end

function main(args)
    length(args) == 1 || error("usage: julia port_retestitems.jl <testdir>")
    testdir = abspath(args[1])
    setupdir = joinpath(testdir, "testsetups")
    notes, moves = String[], String[]
    files = String[]
    for (dir, dirs, names) in walkdir(testdir)
        # Hidden directories, setups already moved, and directories with an
        # environment of their own (a profile's, ported in place on its own).
        filter!(d -> !startswith(d, '.') && d != "testsetups" &&
                     !any(p -> isfile(joinpath(dir, d, p)), ("Project.toml", "JuliaProject.toml")), dirs)
        append!(files, (joinpath(dir, f) for f in names if endswith(f, ".jl") && !(dir == testdir && f == "runtests.jl")))
    end
    for f in sort!(files)
        port_file!(f, testdir, setupdir, notes, moves)
    end
    runtests = joinpath(testdir, "runtests.jl")
    if isfile(runtests) && occursin("ReTestItems", read(runtests, String))
        given = unique([m[1] for m in eachmatch(r"\b(nworkers|nworker_threads|testitem_timeout|retries|memory_threshold|failfast|testitem_failfast|worker_init_expr|test_end_expr|report|name|tags|verbose_results|logs)\s*=", read(runtests, String))])
        push!(notes, "runtests.jl calls ReTestItems: make it `using Runtests; Runtests.runtests()`, and move what it gives the call" *
                     (isempty(given) ? "" : " ($(join(given, ", ")))") * " into test/TestItems.toml, as reference/source-shapes.md maps it")
    end
    foreach(println, moves)
    isempty(notes) || println("\nfor a person to look at:\n  ", join(unique(notes), "\n  "))
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
