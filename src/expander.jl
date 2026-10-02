"""
    Expander

What expands a test template, `test/testtemplates/foo_tests_template.jl`, into the
test items that `Runtests.chores()` writes to `test/foo_tests.jl`. It runs in a process
of its own, with the test environment active and the setups loadable, because a
template is the suite's own code and the process coordinating a run never evaluates
any. The coordinator includes this file too, for the rules both sides have to agree on.

A template holds `@testtemplate`s and nothing else, and each,
`@testtemplate "name \$x" for x in xs ... end`, declares a test item per iteration.
Julia runs the loop as written, in a module holding what the item's will, the package
and the body's `using` and `import` statements, and interpolates the name; each `\$x`
in the keywords and the body, `x` a loop variable, is where its value goes, written as
code, as `Threads.@spawn` takes `\$x`, and each other `\$(...)` in the keywords is
computed as the loop runs and its value written the same way. Nothing binds the loop
variables in the item: what a name means there is the template's to say. The code is
`repr(value)` as such a module sees it, and it has to give back an `isequal` value
there, so a value no file can hold is refused rather than written.

It depends on `Base` and `TOML` alone: the process runs this file, the coordinator's,
whichever Runtests the test environment holds.
"""
module Expander

import TOML

const TESTITEM = Symbol("@testitem")
const TESTTEMPLATE = Symbol("@testtemplate")

is_testitem(@nospecialize ex) = ex isa Expr && ex.head === :macrocall && ex.args[1] === TESTITEM
is_testtemplate(@nospecialize ex) = ex isa Expr && ex.head === :macrocall && ex.args[1] === TESTTEMPLATE
is_declaration(@nospecialize ex) = is_testitem(ex) || is_testtemplate(ex)

is_import(@nospecialize ex) = ex isa Expr && (ex.head === :using || ex.head === :import)

struct TemplateError <: Exception
    line::Int
    msg::String
end

"""
    interpolations(f, ex, vars, line)

Call `f(x)` for every `\$x` in the body `ex` that is the template's: `x` one of the
loop variables `vars`, outside any quoted expression, whose `\$`s are the quote's own.
A `\$` before anything else is left to the code it is in, a macro of the body's own
such as BenchmarkTools' `@btime`; one before an expression that uses a loop variable
is refused, since in the body only a loop variable's value is written in.
"""
function interpolations(f, @nospecialize(ex), vars::Vector{Symbol}, line::Int)
    ex isa Expr || return nothing
    ex.head === :quote && return nothing
    if ex.head === :$ && length(ex.args) == 1
        a = ex.args[1]
        a isa Symbol && a in vars && return f(a)
        mentions(a, vars) && throw(TemplateError(line,
            "the body interpolates only a loop variable, as `\$x`, since a `\$(...)` there may be a macro's: " *
            "compute the rest in the item, writing `f(\$x)` rather than `\$(f(x))`; a keyword's `\$(...)` is " *
            "computed as the template expands. Got `$ex`"))
        return nothing
    end
    foreach(a -> interpolations(f, a, vars, line), ex.args)
    return nothing
end

mentions(@nospecialize(ex), vars) = ex isa Symbol ? ex in vars : ex isa Expr && any(a -> mentions(a, vars), ex.args)

# Call `f(a)` for every `\$a` in a keyword, outside quoted code: in the header every
# `\$` is the template's.
function header_interpolations(f, @nospecialize(ex))
    ex isa Expr || return nothing
    ex.head === :quote && return nothing
    ex.head === :$ && length(ex.args) == 1 && return f(ex.args[1])
    foreach(a -> header_interpolations(f, a), ex.args)
    return nothing
end

# What names a keyword's `\$(...)` in the answer, the same in this process and in the
# coordinator, which reads the template with a parser of its own: the code as it prints
# without its line numbers.
interpolation_key(@nospecialize ex) = string(unlined(ex))

unlined(@nospecialize ex) = ex isa Expr ? Expr(ex.head, Any[unlined(a) for a in ex.args if !(a isa LineNumberNode)]...) : ex

# A loop variable named outside a `$`: a slip, as nothing binds it in the item. Not
# a name inside quoted code, nor a keyword's name in a call.
function bare_mention(@nospecialize(ex), vars)
    ex isa Symbol && return ex in vars
    ex isa Expr || return false
    (ex.head === :$ || ex.head === :quote) && return false
    ex.head === :kw && return bare_mention(ex.args[2], vars)
    return any(a -> bare_mention(a, vars), ex.args)
end

# The names `ex` binds anywhere in it, over-counted rather than under: what an
# assignment, a `for` or a comprehension, a function's or a lambda's parameters, a
# `let`, `local` and `global`, a `catch` and a `where` name.
function bound_names!(out::Set{Symbol}, @nospecialize(ex))
    ex isa Expr || return out
    ex.head === :quote && return out
    h = ex.head
    if h === :(=) || h === :-> || h === :function || h === :local || h === :global || h === :where
        targets!(out, ex.args[1])
        h === :where && foreach(a -> targets!(out, a), ex.args[2:end])
    elseif h === :try && length(ex.args) >= 2 && ex.args[2] isa Symbol
        push!(out, ex.args[2])
    elseif h in (:+=, :-=, :*=, :/=, :^=, :|=, :&=)
        targets!(out, ex.args[1])
    end
    foreach(a -> bound_names!(out, a), ex.args)
    return out
end

# Every name in a binding's target: `x`, `(x, y)`, `x::T`, `f(x; k)`, `x = 1` as a
# default.
targets!(out::Set{Symbol}, @nospecialize(t)) = t isa Symbol ? push!(out, t) :
    t isa Expr && t.head !== :quote ? (foreach(a -> targets!(out, a), t.args); out) : out

"""
    main(request, response)

Expand the templates `request`, a TOML file, names, and write what each declares to
`response`: per template, the text it evaluated, and either an error with its line
or, for each `@testtemplate` in order, its line and the items it declares: each one's
name, the code each interpolated loop variable's value is written as, and the code of
each other `\$(...)` its keywords computed, by [`interpolation_key`](@ref).
"""
function main(request::AbstractString, response::AbstractString)
    req = TOML.parsefile(request)
    project = String(req["project"])
    out = Dict{String, Any}[expand_file(String(path), project) for path in req["templates"]]
    open(io -> TOML.print(io, Dict("templates" => out)), response, "w")
    return nothing
end

function expand_file(path::String, project::String)
    text = read(path, String)
    out = Dict{String, Any}("path" => path, "text" => text)
    try
        out["items"] = expand(text, path, project)
    catch e
        e isa InterruptException && rethrow()
        out["line"] = e isa TemplateError ? e.line : failing_line(catch_backtrace(), path)
        out["error"] = e isa TemplateError ? e.msg : sprint(showerror, e)
    end
    return out
end

# The template's line the error was raised from, the innermost; 0 when none was.
function failing_line(bt, path::String)
    for frame in Base.stacktrace(bt)
        String(frame.file) == path && return frame.line
    end
    return 0
end

const NESTED = "a `@testtemplate` belongs at the top level of a template, its loop in its header: " *
    "`@testtemplate \"name \$x\" for x in xs ... end`"

const ONLY_TEMPLATES = "a template holds `@testtemplate`s and nothing else: a `@testtemplate`'s loop " *
    "sees what its item does, the package and the body's `using` and `import` statements, and code " *
    "that several share goes in a module under `test/testsetups/`"

const NO_TESTITEM = "a template holds `@testtemplate`s and nothing else: a `@testitem` belongs in a " *
    "test file, under `test/`"

const LOOPED_TESTITEM = "a `@testitem` declares one item; to declare one per iteration, write " *
    "`@testtemplate`: `@testtemplate \"name \$x\" for x in xs ... end`"

function expand(text::String, path::String, project::String)
    statements = Meta.parseall(text; filename = path).args
    items = Dict{String, Any}[]
    names = Dict{String, Int}()
    line = 0
    # `include` from a template is relative to it, as from any file.
    task_local_storage(:SOURCE_PATH, path) do
        for ex in statements
            if ex isa LineNumberNode
                line = ex.line
            elseif ex isa Expr && (ex.head === :error || ex.head === :incomplete)
                msg = ex.args[1]
                throw(TemplateError(line, msg isa AbstractString ? msg : sprint(showerror, msg)))
            elseif is_testtemplate(ex)
                push!(items, declaration(ex, line, path, project, names))
            elseif is_testitem(ex)
                args = call_args(ex)
                throw(TemplateError(line, !isempty(args) && is_loop(args[end]) ? LOOPED_TESTITEM : NO_TESTITEM))
            else
                throw(TemplateError(line, holds_declaration(ex) ? NESTED : ONLY_TEMPLATES))
            end
        end
    end
    return items
end

holds_declaration(@nospecialize ex) = ex isa Expr && (is_declaration(ex) || any(holds_declaration, ex.args))

call_args(ex::Expr) = Any[a for a in ex.args[2:end] if !(a isa LineNumberNode)]

is_loop(@nospecialize ex) = ex isa Expr && ex.head === :for

function declaration(ex::Expr, line::Int, path::String, project::String, names::Dict{String, Int})
    args = call_args(ex)
    (length(args) >= 2 && is_loop(args[end])) || throw(TemplateError(line,
        "`@testtemplate` needs a name, and a `for` holding the item's body: `@testtemplate \"name \$x\" for x in xs ... end`"))
    name, keywords, loop = args[1], args[2:(end - 1)], args[end]
    specs, body = loop.args[1], loop.args[2]
    vars = Symbol[]
    for spec in (specs isa Expr && specs.head === :block ? specs.args : Any[specs])
        spec isa LineNumberNode && continue
        (spec isa Expr && spec.head === :(=) && pattern_names!(vars, spec.args[1])) ||
            throw(TemplateError(line, "expected `x in xs` in the `for` of a `@testtemplate`, got `$spec`"))
    end
    # The loop variables whose values go into the items, and the keywords' other
    # interpolations, each computed as the loop runs.
    used = Symbol[]
    use!(v) = (v in used || push!(used, v); nothing)
    computed = Pair{String, Any}[]
    function header!(@nospecialize a)
        a isa Symbol && a in vars && return use!(a)
        key = interpolation_key(a)
        any(p -> first(p) == key, computed) || push!(computed, key => a)
        return nothing
    end
    for kw in keywords
        kw isa Expr && kw.head === :(=) || continue
        for v in vars
            bare_mention(kw.args[2], [v]) && throw(TemplateError(line,
                "`$(kw.args[1])` names the loop variable `$v`, which nothing binds in the item: write `\$$v` " *
                "where its value goes, or `\$(...)` around what is computed from it as the template expands"))
        end
        header_interpolations(header!, kw.args[2])
    end
    interpolations(use!, body, vars, line)
    bound = bound_names!(Set{Symbol}(), body)
    for v in vars
        v in bound || !bare_mention(body, [v]) || throw(TemplateError(line,
            "`$v` in the body names a loop variable, which nothing binds in the item: write `\$$v` " *
            "where its value goes, `\"\$(\$$v)\"` in a string, or bind it first, as in `$v = \$$v`"))
    end
    # The loop runs among the names the item will have. Its values' code is checked in a
    # second module of the same names, where nothing the loop itself defined, a closure
    # in its header say, is any more visible than it is to the item.
    found = run_loop(item_module(body, project, line), specs, name, vars, Any[last(p) for p in computed],
                     LineNumberNode(line, Symbol(path)))
    isempty(found) && throw(TemplateError(line, "the `for` of this `@testtemplate` ran no iteration, so it declares no test item"))
    item = item_module(body, project, line)
    instances = Dict{String, Any}[]
    for (n, values, results) in found
        n isa AbstractString || throw(TemplateError(line, "a test item's name must be a string, and this one's is $(repr(n))"))
        n = String(n)
        isempty(strip(n)) && throw(TemplateError(line, "a test item's name must not be blank"))
        claim!(names, n, line)
        codes = Vector{String}[[String(v), value_code(item, "\$$v", x, n, line)] for (v, x) in zip(vars, values) if v in used]
        sums = Vector{String}[[key, value_code(item, label(a), x, n, line)] for ((key, a), x) in zip(computed, results)]
        push!(instances, Dict{String, Any}("name" => n, "values" => codes, "computed" => sums))
    end
    return Dict{String, Any}("line" => line, "instances" => instances)
end

function claim!(names::Dict{String, Int}, name::String, line::Int)
    at = get(names, name, 0)
    at == 0 || throw(TemplateError(line, "declares the test item name $(repr(name)) a second time; the first is at line $at"))
    names[name] = line
    return nothing
end

# The names a loop variable pattern binds, `x` or `(x, (y, z))`; false for any other.
function pattern_names!(out::Vector{Symbol}, @nospecialize p)
    p isa Symbol && (push!(out, p); return true)
    p isa Expr && p.head === :tuple && return all(a -> pattern_names!(out, a), p.args)
    return false
end

# How a message shows an interpolation.
label(@nospecialize a) = a isa Symbol ? string("\$", a) : string("\$(", interpolation_key(a), ")")

# The loop as written, in `mod`: per iteration, the name, the loop variables' values,
# and the value of each of `computed`. An interpolated name prints its values as `mod`
# sees them, `Day` once it has `using Dates`, where a plain `string` would print them as
# `Main` does.
function run_loop(mod::Module, specs, name, vars::Vector{Symbol}, computed::Vector{Any}, at::LineNumberNode)
    acc = gensym("instances")
    if name isa Expr && name.head === :string
        io = gensym("io")
        prints = Any[Expr(:call, GlobalRef(Base, :print), io, part) for part in name.args]
        name = Expr(:call, GlobalRef(Base, :sprint), Expr(:->, io, Expr(:block, prints...)),
                    Expr(:kw, :context, Expr(:call, GlobalRef(Base, :(=>)), QuoteNode(:module), mod)))
    end
    push = Expr(:call, GlobalRef(Base, :push!), acc, Expr(:tuple, name, Expr(:tuple, vars...), Expr(:tuple, computed...)))
    ex = Expr(:let, Expr(:block), Expr(:block,
        Expr(:(=), acc, Expr(:ref, GlobalRef(Core, :Any))),
        Expr(:for, specs, Expr(:block, push)),
        acc))
    return Core.eval(mod, Expr(:toplevel, at, ex))::Vector{Any}
end

# A module holding what the item's will once its imports have run: `Test`, the
# package under test, and the body's `using` and `import` statements.
function item_module(body::Expr, project::String, line::Int)
    m = Module(:Item)
    Core.eval(m, :(using Test))
    isempty(project) || Core.eval(m, :(using $(Symbol(project))))
    for ex in body.args
        is_import(ex) || continue
        try
            Core.eval(m, ex)
        catch e
            e isa InterruptException && rethrow()
            throw(TemplateError(line, "the item's `$ex` failed: $(sprint(showerror, e))"))
        end
    end
    return m
end

struct NotGivenBack end

# In the latest world, like everything that follows evaluating the item's imports:
# from an older one, the names they brought in are not visible, and the methods of
# `show` and `isequal` they define do not exist.
function value_code(item::Module, shown::String, @nospecialize(x), name::String, line::Int)
    code = Base.invokelatest(repr, x; context = :module => item)::String
    back = try
        Core.eval(item, Meta.parse(code))
    catch e
        e isa InterruptException && rethrow()
        NotGivenBack()
    end
    same = try
        Base.invokelatest(isequal, back, x) === true
    catch
        false
    end
    same || throw(TemplateError(line,
        "$(repr(name)): `$shown` would be written `$code`, which does not give its value back in the item. " *
        "An item can hold a value only as code that rebuilds it with the `using` statements in its body: " *
        "import what that code names there, or loop over something that rebuilds it"))
    return code
end

end # module Expander
