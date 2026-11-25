# Setups as packages. A module in `test/testsetups/` without a project of its own has
# no UUID, and Julia files the precompile cache of such a module under its name
# alone: one file per depot, rewritten by every checkout with a setup of that name
# and by every set of Julia flags. A package's cache is filed under its UUID, with
# the flags and the active project in the file's name, so each keeps its own.

const JuliaSyntax = Base.JuliaSyntax

"""
    setups_to_packages([path])

Make every module in the package's `test/testsetups/` a package of its own, so that
its precompile cache is kept per checkout and per set of Julia flags instead of in
one file that each of them rewrites. `Name.jl` moves to `Name/src/Name.jl`, beside a
`Name/Project.toml` that gives it a UUID and lists the packages it imports as its
`[deps]`. Test items load it with `using Name`, as before.

A package can import only what its `[deps]` list, so run this again after a setup
starts importing something new: it adds what is missing, changes nothing else, and
keeps the UUIDs. An import it cannot see, such as one in code that the setup
generates or evaluates as it loads, goes into `[deps]` by hand.

In a moved file, `@__DIR__` becomes `pkgdir(MyPkg, "test", "testsetups")`, for the
package under test, which names the directory the file was in from anywhere, the
REPL included; `joinpath(@__DIR__, "..", "data")` becomes `pkgdir(MyPkg, "test",
"data")`. A setup that does not import the package gets an `import MyPkg` for it.
Nothing is written unless every setup can be converted: an import that neither the
test environment nor the standard library provides, a relative `include` and
`@__FILE__` are reported instead, all of them at once.

`path` finds the package as it does for [`runtests`](@ref).
"""
function setups_to_packages(args...)
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    dir = joinpath(target.testdir, TESTSETUPS_DIR)
    modules = setup_modules(target.testdir)
    if isempty(modules)
        println(stdout, label_prefix(), "no setups in ", relpath_or_path(dir))
        return nothing
    end
    plans = plan_setup_packages(target, dir, modules)
    foreach(write_setup_package, plans)
    print_setup_packages(stdout, plans, dir, target.root)
    return nothing
end

# Converting one setup, worked out before anything is written.
struct SetupPackage
    name::String
    source::String                # the module's file as it is
    entry::String                 # and as it will be, `Name/src/Name.jl`
    code::String                  # the text it will have there
    rewritten::Int                # `@__DIR__`s rewritten on the way
    imported::String              # the package an `import` was added for, or ""
    project::String               # `Name/Project.toml`
    toml::Dict{String, Any}       # what that file will hold
    changed::Bool                 # whether that differs from what it holds now
    deps::Vector{String}          # the setup's dependencies after, sorted
    added::Vector{String}         # of those, the ones this adds
end

moves(p::SetupPackage) = p.source != p.entry

function plan_setup_packages(target, dir::String, modules::Dict{Symbol, String})
    names = sort!([String(n) for n in keys(modules)])
    problems = String[]
    shown(path) = relpath_or_path(path)
    # Every setup's UUID first: a setup can import another.
    tomls = Dict{String, Dict{String, Any}}()
    uuids = Dict{String, Base.UUID}()
    for name in names
        project = joinpath(dir, name, "Project.toml")
        toml = isfile(project) ? TOML.parsefile(project) : Dict{String, Any}()
        get(toml, "name", name) == name ||
            push!(problems, "$(shown(project)): names the package `$(toml["name"])`, not `$name`")
        tomls[name] = toml
        uuid = haskey(toml, "uuid") ? tryparse(Base.UUID, string(toml["uuid"])) : random_uuid()
        uuid === nothing && push!(problems, "$(shown(project)): `uuid = $(repr(toml["uuid"]))` is not a UUID")
        uuids[name] = something(uuid, random_uuid())
    end
    own = parse_project(target.project)
    available = test_env_packages(target, own)
    # What a moved setup's `@__DIR__` becomes `pkgdir` of; `nothing` for a project
    # that is not a package.
    pkg = haskey(own, "uuid") ? (own["name"] isa String ? own["name"]::String : String(own["name"])::String) : nothing
    stdlib_cache = Dict{String, Union{Nothing, Base.UUID}}()
    plans = SetupPackage[]
    for name in names
        source = modules[Symbol(name)]
        entry = joinpath(dir, name, "src", name * ".jl")
        project = joinpath(dir, name, "Project.toml")
        code = read(source, String)
        ex = Meta.parseall(code; filename = source)
        err = first_syntax_error(ex)
        if err !== nothing
            push!(problems, "$(shown(source)):$(err[1]): $(err[2])")
            continue
        end
        any(a -> module_expr(a, Symbol(name)) !== nothing, ex.args) ||
            push!(problems, "$(shown(source)): does not define `module $name`")
        if source != entry && ispath(joinpath(dir, name))
            push!(problems, "$(shown(source)): `$name/` is there as well; move one of them aside")
        end
        # The test environment, then the standard library, then the other setups: the
        # order `LOAD_PATH` has them in during a run.
        deps = Dict{String, Base.UUID}()
        unknown = String[]
        for root in imported_roots(ex)
            n = String(root)
            (root in (:Base, :Core, :Main) || n == name) && continue
            u = get(available, n, nothing)
            u === nothing && (u = get!(() -> stdlib_uuid(n), stdlib_cache, n))
            u === nothing && (u = get(uuids, n, nothing))
            u === nothing ? push!(unknown, n) : (deps[n] = u)
        end
        isempty(unknown) || push!(
            problems,
            "$(shown(source)): imports $(join(("`$n`" for n in sort!(unknown)), ", ")), which neither " *
                "the test environment nor the standard library provides"
        )
        toml = tomls[name]
        have = toml_table(toml, "deps")
        for (n, u) in deps
            haskey(have, n) || continue
            listed = tryparse(Base.UUID, string(have[n]))
            listed === nothing ? push!(problems, "$(shown(project)): lists `$n` as $(repr(have[n])), which is not a UUID") :
                listed != u && push!(problems, "$(shown(project)): lists `$n` as $(have[n]); it is $u")
        end
        rewritten, imported = 0, false
        if source != entry
            moved, rewritten, imported, hazards = relocate(code, ex, name, pkg)
            for (at, what) in hazards
                push!(problems, "$(shown(source)):$(line_at(code, at)): $what")
            end
            code = moved
            imported && pkg !== nothing && (deps[pkg] = available[pkg])
        end
        added = sort!(String[n for n in keys(deps) if !haskey(have, n)])
        after = copy(toml)
        after["name"] = name
        after["uuid"] = string(uuids[name])
        alldeps = copy(have)
        for n in added
            alldeps[n] = string(deps[n])
        end
        isempty(alldeps) || (after["deps"] = alldeps)
        imported_pkg = (imported && pkg !== nothing) ? pkg : ""
        push!(plans, SetupPackage(name, source, entry, code, rewritten, imported_pkg, project, after,
                                  (after != toml)::Bool, sort!(collect(String, keys(alldeps))), added))
    end
    isempty(problems) || throw(
        ConfigError("no setup can be made a package until these are fixed:\n" * join(("  " * p for p in problems), "\n"))
    )
    return plans
end

function write_setup_package(p::SetupPackage)
    if moves(p)
        mkpath(dirname(p.entry))
        write(p.entry, p.code)
        rm(p.source)
    end
    p.changed && open(io -> TOML.print(io, p.toml; sorted = true, by = project_key_order), p.project, "w")
    return nothing
end

# `name` and `uuid` first, as `Pkg` writes a project.
project_key_order(k) = (k == "name" ? 0 : k == "uuid" ? 1 : 2, k)

function print_setup_packages(io::IO, plans::Vector{SetupPackage}, dir::String, root::String)
    head = styled() do s
        print(s, "setups as packages: ")
        printstyled(s, relpath_or_path(dir, root); color = :light_black)
    end
    body = styled() do s
        print_setup_changes(s, plans, dir; done = true)
    end
    print(io, bracket(body, "[TEST]", head, "", :default))
    return nothing
end

# A line per setup, names aligned: what making it a package did, or with
# `done = false` what it would do, and `indent` before each.
function print_setup_changes(io::IO, plans::Vector{SetupPackage}, dir::String; done::Bool, indent = "")
    width = maximum(p -> textwidth(p.name), plans) + 3
    cont = " "^(textwidth(indent) + width + 1)
    for p in plans
        lead = string(indent, rpad(string('`', p.name, "`:"), width), " ")
        if moves(p)
            rel = relpath(p.entry, dir)
            mid = string(p.rewritten > 0 ? string(" · `@__DIR__` rewritten ", p.rewritten, "×") : "",
                         isempty(p.imported) ? "" : string(" · `import ", p.imported, "` added"),
                         " · deps: ")
            plain_w = textwidth(lead) + textwidth(done ? "moved to " : "would move to ") +
                      textwidth(rel) + textwidth(mid)
            prefix = sprint() do pio
                pctx = io_context_like(pio, io)
                print(pctx, lead, done ? "moved to " : "would move to ")
                printstyled(pctx, rel; color = :light_black)
                print(pctx, mid)
            end
            if isempty(p.deps)
                println(io, prefix, "none")
            else
                print_wrapped_list(io, prefix, p.deps; indent = cont, prefix_width = plain_w)
            end
        elseif !p.changed
            println(io, lead, "up to date")
        elseif isempty(p.added)
            prefix = string(lead, done ? "project written" : "project to write", " · deps: ")
            if isempty(p.deps)
                println(io, prefix, "none")
            else
                print_wrapped_list(io, prefix, p.deps; indent = cont)
            end
        else
            prefix = string(lead, done ? "added to deps: " : "to add to deps: ")
            print_wrapped_list(io, prefix, p.added; indent = cont)
        end
    end
    return nothing
end

"""
    test_env_packages(target) -> Dict{String,UUID}

The packages a test item can import by name: `test/Project.toml`'s `[deps]` when
there is one, or else the package's `[deps]` and the extras its `test` target
names, and the package itself either way.
"""
function test_env_packages(target, root::Dict{String, Any} = parse_project(target.project))
    out = Dict{String, Base.UUID}()
    if haskey(root, "uuid")
        rn = root["name"]
        ru = root["uuid"]
        out[rn isa String ? rn : String(rn)::String] = Base.UUID(ru isa String ? ru : String(ru)::String)
    end
    testproj = project_file(target.testdir)
    if testproj !== nothing
        for (n, u) in toml_table(parse_project(testproj), "deps")
            out[n] = Base.UUID(u isa String ? u : string(u)::String)
        end
    else
        for (n, u) in toml_table(root, "deps")
            out[n] = Base.UUID(u isa String ? u : string(u)::String)
        end
        raw_test = get(toml_table(root, "targets"), "test", nothing)
        test = raw_test isa AbstractVector ? String[x isa String ? x : String(x)::String for x in raw_test] : String[]
        for section in ("extras", "weakdeps"), (n, u) in toml_table(root, section)
            n in test && (out[n] = Base.UUID(u isa String ? u : string(u)::String))
        end
    end
    return out
end

function stdlib_uuid(name::AbstractString)
    project = joinpath(Sys.STDLIB, name, "Project.toml")
    isfile(project) || return nothing
    u = get(TOML.parsefile(project), "uuid", nothing)
    return u === nothing ? nothing : Base.UUID(u)
end

# A version 4 UUID, made as `UUIDs.uuid4` makes one.
random_uuid() = Base.UUID(
    (rand(RandomDevice(), UInt128) & 0xffffffffffff0fff3fffffffffffffff) | 0x00000000000040008000000000000000
)

# The `module name` a top-level statement defines, or `nothing`. A module with a
# docstring parses as the docstring's macro call around the module. Its name and
# body are its last two arguments: from 1.14 a syntax version comes first.
function module_expr(ex, name::Symbol)
    ex isa Expr || return nothing
    ex.head === :module && return ex.args[end - 1] === name ? ex : nothing
    ex.head === :macrocall && return module_expr(ex.args[end], name)
    return nothing
end

# The name the top level of setup module `name` binds package `pkg` to: `pkg` for a
# plain `using pkg` or `import pkg`, `X` for `import pkg as X`, or `nothing`.
function package_binding(ex::Expr, name::Symbol, pkg::Symbol)
    for a in ex.args
        m = module_expr(a, name)
        m === nothing && continue
        for st in m.args[end].args
            st isa Expr && (st.head === :using || st.head === :import) || continue
            for b in st.args
                b isa Expr && b.head === :. && only_name(b, pkg) && return pkg
                if st.head === :import && b isa Expr && b.head === :as && b.args[1] isa Expr &&
                        only_name(b.args[1]::Expr, pkg)
                    return b.args[2]::Symbol
                end
            end
        end
    end
    return nothing
end

# Whether the path `ex` of an import is `pkg` and nothing more.
only_name(ex::Expr, pkg::Symbol) = length(ex.args) == 1 && ex.args[1] === pkg

# Where `Meta.parseall` put a syntax error in place of a statement: its line and
# message, or `nothing`.
function first_syntax_error(ex::Expr)
    line = 0
    for a in ex.args
        a isa LineNumberNode && (line = a.line; continue)
        if a isa Expr && a.head in (:error, :incomplete)
            msg = a.args[1]
            return (line, msg isa AbstractString ? msg : sprint(showerror, msg))
        end
    end
    return nothing
end

"""
    imported_roots(ex) -> Set{Symbol}

The first name of every module that a `using` or `import` anywhere in `ex` reaches
from outside it: `A` of `using A.B: c` and of `import A as B`, and nothing of
`using .A`.
"""
function imported_roots(ex, out::Set{Symbol} = Set{Symbol}())
    ex isa Expr || return out
    if ex.head === :using || ex.head === :import
        for a in ex.args
            m = module_head(a)
            m !== nothing && m !== :. && push!(out, m)
        end
        return out
    end
    for a in ex.args
        imported_roots(a, out)
    end
    return out
end

"""
    relocate(code, ex, name, pkg) -> (code, rewritten, imported, hazards)

The text of setup `name` for its new place, two directories deeper in `Name/src/`.
Each `@__DIR__` in code, not in strings or comments, becomes
`pkgdir(pkg, "test", "testsetups")`, which names the directory the file was in
wherever the code runs, the REPL included, and the `".."`s of a
`joinpath(@__DIR__, "..", …)` fold into that call. The package is named as the setup
binds it; a setup that does not gets an `import` of it after its `module` line
(`imported`). `hazards` are what would change meaning and is not rewritten: each
`@__FILE__` and each `include` of a relative path written out, by byte offset.
"""
function relocate(code::String, ex::Expr, name::String, pkg::Union{Nothing, String})
    bytes = codeunits(code)
    toks = JuliaSyntax.tokenize(code)
    n = lastindex(toks)
    text(i) = String(view(bytes, Int(first(toks[i].range)):Int(last(toks[i].range))))
    kind(i) = string(JuliaSyntax.kind(toks[i]))
    first_byte(i) = Int(first(toks[i].range))
    last_byte(i) = Int(last(toks[i].range))
    # From 1.14 a zero-width token follows `module`, the syntax version.
    blank(i) = kind(i) in ("Whitespace", "NewlineWs", "Comment") || isempty(toks[i].range)
    next_token(i) = (j = i + 1; while j <= n && blank(j); j += 1; end; j)
    prev_token(i) = (j = i - 1; while j >= 1 && blank(j); j -= 1; end; j)
    # `include("file.jl")`, blanks allowed between the tokens as the parser allows
    # them; the string's own content follows its quote directly.
    function is_relative_include(i)
        p = next_token(i)
        q = p <= n && text(p) == "(" ? next_token(p) : n + 1
        return q + 1 <= n && kind(q) == "\"" && kind(q + 1) == "String" && !isabspath(text(q + 1))
    end
    bound = pkg === nothing ? nothing : package_binding(ex, Symbol(name), Symbol(pkg))
    ref = string(something(bound, pkg, ""))
    edits = Tuple{UnitRange{Int}, String}[]
    hazards = Tuple{Int, String}[]
    for i in eachindex(toks)
        at = first_byte(i)
        # Matched by text: what follows `@` is a `MacroName` on some Julia versions
        # and an `Identifier` on others.
        if kind(i) == "@" && i < n
            macro_name = text(i + 1)
            if macro_name == "__DIR__" && pkg === nothing
                push!(hazards, (at, "`@__DIR__` would become `pkgdir` of the package under test, " *
                                    "and the project is not a package"))
            elseif macro_name == "__DIR__"
                stop, last_tok = last_byte(i + 1), i + 1
                # `@__DIR__()` is the same call.
                if i + 3 <= n && text(i + 2) == "(" && text(i + 3) == ")"
                    stop, last_tok = last_byte(i + 3), i + 3
                end
                parts = ["test", TESTSETUPS_DIR]
                p = prev_token(i)
                f = p >= 1 ? prev_token(p) : 0
                if f >= 1 && text(p) == "(" && kind(f) == "Identifier" && text(f) == "joinpath"
                    # Each `".."` after it climbs out of `parts`; the call's other
                    # arguments and its closing parenthesis are left as they are.
                    at, j = first_byte(f), last_tok
                    while !isempty(parts)
                        c = next_token(j)
                        (c <= n && text(c) == ",") || break
                        q = next_token(c)
                        (q + 2 <= n && kind(q) == "\"" && kind(q + 1) == "String" && text(q + 1) == ".." &&
                            kind(q + 2) == "\"") || break
                        pop!(parts)
                        j = q + 2
                        stop = last_byte(j)
                    end
                    push!(edits, (at:stop, string("pkgdir(", ref, join(", \"$c\"" for c in parts))))
                else
                    push!(edits, (at:stop, string("pkgdir(", ref, join(", \"$c\"" for c in parts), ")")))
                end
            elseif macro_name == "__FILE__"
                push!(hazards, (at, "`@__FILE__` would change with the move; use `@__DIR__`, which is " *
                                    "rewritten to keep its meaning"))
            end
        elseif kind(i) == "Identifier" && text(i) == "include" && is_relative_include(i)
            push!(hazards, (at, "`include` of a relative path would look in `src/` after the move; use " *
                                "`include(joinpath(@__DIR__, …))`, which is rewritten to keep its meaning"))
        end
    end
    rewritten = length(edits)
    imported = rewritten > 0 && bound === nothing && pkg !== nothing
    if imported
        # First in the module's body: on a line of its own after `module Name`,
        # indented as the body is, or, when the body goes on on that line, as a
        # statement of its own there.
        for i in eachindex(toks)
            kind(i) in ("module", "baremodule") || continue
            j = next_token(i)
            (j <= n && text(j) == name) || continue
            k = j + 1
            while k <= n && (kind(k) == "Whitespace" || isempty(toks[k].range))
                k += 1
            end
            if k <= n && !(kind(k) in ("NewlineWs", "Comment"))
                at = last_byte(j) + 1
                push!(edits, (at:(at - 1), string("; import ", pkg, text(k) == ";" ? "" : ";")))
            else
                nl = findnext(==(UInt8('\n')), bytes, last_byte(j))
                at = nl === nothing ? length(bytes) + 1 : nl + 1
                push!(edits, (at:(at - 1), string(nl === nothing ? "\n" : "", body_indent(bytes, at), "import ", pkg, "\n")))
            end
            break
        end
    end
    sort_by!(edits, e -> first(e[1]))
    return replace_ranges(code, edits), rewritten, imported, hazards
end

# The leading blanks of the first line from byte `from` on that has anything else.
function body_indent(bytes, from::Int)
    pos = from
    while pos <= length(bytes)
        stop = something(findnext(==(UInt8('\n')), bytes, pos), length(bytes) + 1)
        k = findfirst(b -> !(b in (UInt8(' '), UInt8('\t'), UInt8('\r'))), view(bytes, pos:(stop - 1)))
        k === nothing || return String(bytes[pos:(pos + k - 2)])
        pos = stop + 1
    end
    return ""
end

# `code` with each range replaced by its text, the ranges in order. An empty range,
# `at:at-1`, inserts at `at`.
function replace_ranges(code::String, edits::Vector{Tuple{UnitRange{Int}, String}})
    isempty(edits) && return code
    bytes = codeunits(code)
    io = IOBuffer()
    pos = 1
    for (r, with) in edits
        write(io, view(bytes, pos:(first(r) - 1)), with)
        pos = last(r) + 1
    end
    write(io, view(bytes, pos:length(bytes)))
    return String(take!(io))
end

line_at(code::String, byte::Integer) = count(==(UInt8('\n')), view(codeunits(code), 1:(byte - 1))) + 1
