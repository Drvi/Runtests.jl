# Test templates. `test/testtemplates/foo_tests_template.jl` holds `@testtemplate`s, each
# of which declares a test item per iteration of a loop; `Runtests.chores()` runs the
# loops in a process of its own and writes the items they declare to the ordinary test
# file `test/foo_tests.jl`, which is committed like any other. A run reads only that
# file, and checks from the bytes of the two that it is the template's expansion as the
# template is now.

const TEMPLATE_SUFFIXES = ("_test_template.jl", "_tests_template.jl")

is_template_file(path::AbstractString) = any(s -> endswith(path, s), TEMPLATE_SUFFIXES)

# `test/testtemplates/foo_tests_template.jl` and `test/foo_tests.jl`, each from the other.
expansion_of(template::AbstractString) =
    joinpath(dirname(dirname(template)), string(chop(basename(template); tail = length("_template.jl")), ".jl"))
template_of(expansion::AbstractString) =
    joinpath(dirname(expansion), TESTTEMPLATES_DIR, string(chop(basename(expansion); tail = length(".jl")), "_template.jl"))

"""
    canonical_text(text) -> String

`text` as a stamp hashes it: without a byte-order mark, with every line ending a
`\\n`, and without the whitespace at its end. Git on Windows writes other line
endings, some editors add the mark, and editors differ over a final newline, none of
which is a change its author made; whitespace at the end of a file belongs to no
code. Whitespace anywhere else may be inside a string literal, so it counts.
"""
function canonical_text(text::AbstractString)
    t = String(text)
    startswith(t, '\ufeff') && (t = t[nextind(t, 1):end])
    return String(rstrip(replace(t, "\r\n" => "\n", '\r' => '\n')))
end

text_crc(text::AbstractString) = crc32c(canonical_text(text))

hex8(x::UInt32) = string(x; base = 16, pad = 8)

# The third line of an expansion: the stamp's format, then the CRC32c of the template's
# text and of the expansion's own text below this line, each canonical.
const STAMP = r"^# runtests-expansion (\d+) ([0-9a-f]{8}) ([0-9a-f]{8})$"
const STAMP_FORMAT = 1
const STAMP_LINE = 3

struct Stamp
    format::Int
    template::UInt32
    expansion::UInt32   # as recorded
    actual::UInt32      # the expansion's text as it is now
end

# The stamp of the test file at `path`, or `nothing` when `chores` did not write it.
# Only a file that mentions one near its top is read in full.
function read_stamp(path::AbstractString)
    head = try
        open(io -> String(read(io, 1024)), path)
    catch
        return nothing
    end
    occursin("# runtests-expansion ", head) || return nothing
    lines = split(canonical_text(read(path, String)), '\n'; limit = STAMP_LINE + 1)
    length(lines) >= STAMP_LINE || return nothing
    m = match(STAMP, lines[STAMP_LINE])
    m === nothing && return nothing
    rest = length(lines) > STAMP_LINE ? lines[end] : ""
    return Stamp(parse(Int, m[1]::AbstractString), parse(UInt32, m[2]::AbstractString; base = 16),
                 parse(UInt32, m[3]::AbstractString; base = 16), crc32c(rest))
end

"""
    expansion_state(template[, stamp]) -> Symbol

Where `template`'s expansion stands, from the two files alone: `:missing`;
`:in_the_way`, a test file there that `chores` did not write; `:other_format`,
stamped by a Runtests that stamps otherwise; `:edited` since `chores` wrote it;
`:stale`, the template changed since; or `:current`.
"""
function expansion_state(template::AbstractString, stamp = read_stamp(expansion_of(template)))
    isfile(expansion_of(template)) || return :missing
    stamp === nothing && return :in_the_way
    stamp.format == STAMP_FORMAT || return :other_format
    stamp.actual == stamp.expansion || return :edited
    text_crc(read(template, String)) == stamp.template || return :stale
    return :current
end

function expansion_message(state::Symbol, template::AbstractString)
    t = relpath_or_path(template)
    state === :missing && return "not expanded yet: `Runtests.chores()` expands it into $(relpath_or_path(expansion_of(template)))"
    state === :in_the_way && return "in the way of $t's expansion: `Runtests.chores()` did not write this file and will not overwrite it, so rename one of the two"
    state === :other_format && return "expanded from $t by a Runtests that stamps expansions differently: run `Runtests.chores()` to expand it again"
    state === :edited && return "edited since `Runtests.chores()` expanded it from $t: make the change in the template, then delete this file and run `Runtests.chores()`"
    state === :stale && return "expanded from an older $t: run `Runtests.chores()` to expand it again"
    state === :orphan && return "expanded from $t, which is gone: delete this file, or run `Runtests.chores()`, which does"
    error("no message for expansion state $state")
end

"""
    expansion_errors(files, templates) -> Vector{ScanError}

Every expansion that stops a run, read from the files without running anything: a
template in `templates` not expanded yet, or with a test file in its way that
`chores` did not write; and among `files`, an expansion whose template changed since,
that was edited by hand, or whose template is gone.
"""
function expansion_errors(files::Vector{String}, templates::Vector{String})
    errors = ScanError[]
    for t in templates
        o = expansion_of(t)
        state = isfile(o) ? (read_stamp(o) === nothing ? :in_the_way : :current) : :missing
        state === :missing && push!(errors, ScanError(t, 0, expansion_message(state, t)))
        state === :in_the_way && push!(errors, ScanError(o, 0, expansion_message(state, t)))
    end
    for f in files
        stamp = read_stamp(f)
        stamp === nothing && continue
        t = template_of(f)
        state = isfile(t) ? expansion_state(t, stamp) : :orphan
        state === :current || push!(errors, ScanError(f, 0, expansion_message(state, t)))
    end
    return errors
end

### Writing an expansion ###################################################

byte_slice(text::String, r::UnitRange{Int}) = String(codeunits(text)[r])

# A node's children, none for a leaf.
children_of(node) = something(JuliaSyntax.children(node), JuliaSyntax.SyntaxNode[])

declaration_nodes(tree) = [c for c in children_of(tree) if Expander.is_testtemplate(Expr(c))]

"""
    render_expansion(template, text, items) -> String

The test file `template` expands to, from the `text` the expanding process ran and
what it answered for each of its `@testtemplate`s: a `@testitem` per instance, its
name a literal, each `\$x` replaced by the code of `x`'s value and each other `\$(...)`
of its keywords by the code of what it computed, the rest as written. The stamp on
its third line is what a run checks it by.
"""
function render_expansion(template::AbstractString, text::String, items::Vector)
    nodes = declaration_nodes(JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, text; filename = String(template)))
    length(nodes) == length(items) ||
        error("the expanding process read $(length(items)) `@testtemplate`s in the template, and Runtests $(length(nodes))")
    pieces = String[]
    for (node, item) in zip(nodes, items), inst in item["instances"]
        values = Dict{Symbol, String}(Symbol(v) => String(code) for (v, code) in inst["values"])
        computed = Dict{String, String}(String(k) => String(code) for (k, code) in inst["computed"])
        push!(pieces, render_instance(text, node, String(inst["name"]), values, computed))
    end
    body = string("\n", join(pieces, "\n\n"), "\n")
    # With `/` on every system: the header is part of the file that is committed.
    return string(
        "# Expanded from ", TESTTEMPLATES_DIR, "/", basename(template), " by `Runtests.chores()`.\n",
        "# Change the template and run `Runtests.chores()` again, rather than editing this file.\n",
        "# runtests-expansion ", STAMP_FORMAT, " ", hex8(text_crc(text)), " ", hex8(text_crc(body)), "\n",
        body
    )
end

# One instance of `@testtemplate <name> <keywords> for <specs> <body> end`, as
# `@testitem <name> <keywords> begin <body> end` with every `$x` of the loop variables
# in `values` replaced, in the text, by the code of its value, and every other `$(...)`
# of the keywords by the code `computed` holds for it. It has to read as the template's
# own code does with those values in place, or the code would be binding to what
# surrounds it. Code in parentheses cannot, so the text has them where it would
# otherwise not read so: `-$x` of a `1` reads as the literal `-1`.
function render_instance(text::String, node, name::String, values::Dict{Symbol, String}, computed::Dict{String, String})
    kids = children_of(node)
    loop = kids[end]
    body = children_of(loop)[2]
    at = Pair{UnitRange{Int}, String}[]
    for k in 3:(length(kids) - 1)
        interpolation_ranges!(at, text, kids[k], values, computed)
    end
    interpolation_ranges!(at, text, body, values, nothing)
    sort!(at; by = first ∘ first)
    ranges = (JuliaSyntax.byte_range(kids[2]), JuliaSyntax.byte_range(loop), JuliaSyntax.byte_range(body))
    want = instance_code(Expr(node), values, computed)
    for parenthesize in (false, true)
        instance = splice_instance(text, name, ranges..., at, parenthesize)
        reads_as(instance, want) && return instance
    end
    error("$(repr(name)): written in, the values do not read as the template's code does with them in " *
          "place; a `\$x` or a `\$(...)` has to stand where a value can")
end

# The instance's text: the header up to the `for` becoming `@testitem <name> ... begin`,
# and each interpolation in the keywords and the body replaced.
function splice_instance(text, name, name_range, loop_range, body_range, at, parenthesize::Bool)
    out = IOBuffer()
    print(out, "@testitem ", repr(name))
    k = 1
    for (region, after) in (((last(name_range) + 1):(first(loop_range) - 1), "begin"), (body_range, ""))
        from = first(region)
        while k <= length(at) && first(first(at[k])) <= last(region)
            r, code = at[k]
            print(out, byte_slice(text, from:(first(r) - 1)), parenthesize ? string("(", code, ")") :
                as_operand(code, byte_before(text, first(r)), byte_before(text, last(r) + 2)))
            from = last(r) + 1
            k += 1
        end
        print(out, byte_slice(text, from:last(region)), after)
    end
    print(out, byte_slice(text, (last(body_range) + 1):last(loop_range)))
    return String(take!(out))
end

# The byte range of each interpolation under `node` that is the template's, with the
# code that replaces it (see `interpolated_code`); none from inside a quoted
# expression, where every `$` is the quote's.
function interpolation_ranges!(out, text::String, node, values, computed)
    r = JuliaSyntax.byte_range(node)
    isempty(r) && return out
    c = codeunits(text)[first(r)]
    if c == UInt8('$') || c == UInt8(':') || c == UInt8('q')
        e = Expr(node)
        if e isa Expr && e.head === :$ && length(e.args) == 1
            code = interpolated_code(e.args[1], values, computed)
            code === nothing || (push!(out, r => code); return out)
        end
        e isa Expr && e.head === :quote && return out
    end
    foreach(k -> interpolation_ranges!(out, text, k, values, computed), children_of(node))
    return out
end

# The code that replaces `\$a`: a loop variable's value from `values`, and in the
# keywords, where `computed` is given and every `\$` is the template's, what the
# expanding process computed for it. `nothing` for a `\$` in the body that is not a loop
# variable's, which belongs to the code it is in.
function interpolated_code(@nospecialize(a), values::Dict{Symbol, String}, computed::Union{Nothing, Dict{String, String}})
    a isa Symbol && haskey(values, a) && return values[a]
    computed === nothing && return nothing
    key = Expander.interpolation_key(a)
    haskey(computed, key) || error("the expanding process computed nothing for `\$($key)`")
    return computed[key]
end

# Code to stand where an expression goes, between the bytes `before` and `after`: as
# written when nothing beside it can bind to it, and in parentheses otherwise. A name,
# `true` and `false`, a string, a type, a dotted name, a tuple, a vector and a call such
# as `Day(1)` stand alone anywhere; a number does unless a sign comes before it, `-$x` of a `1` reading
# as the literal `-1`, or a `.` or a name after it; a quoted symbol does unless a `.`
# comes after it; anything else, a range or another operator's call, gets them.
function as_operand(code::String, before::UInt8, after::UInt8)
    ex = Meta.parse(code)
    joins(c) = c == UInt8('.') || UInt8('0') <= c <= UInt8('9') || UInt8('a') <= c <= UInt8('z') ||
        UInt8('A') <= c <= UInt8('Z') || c == UInt8('_')
    alone = ex isa Symbol || ex isa Bool || ex isa AbstractString || ex isa AbstractChar ||
        (ex isa Expr && (ex.head in (:., :curly, :tuple, :vect, :string) ||
                         (ex.head === :call && !(ex.args[1] isa Symbol && Base.isoperator(ex.args[1]))))) ||
        (ex isa Number && !signbit(ex) && before != UInt8('-') && before != UInt8('+') && !joins(after)) ||
        (ex isa QuoteNode && ex.value isa Symbol && after != UInt8('.'))
    return alone ? code : string("(", code, ")")
end

# The byte before position `i`, a space at either end of the text.
byte_before(text::String, i::Int) = 2 <= i <= ncodeunits(text) + 1 ? codeunits(text)[i - 1] : UInt8(' ')

function substitute(@nospecialize(ex), values, computed)
    ex isa Expr || return ex
    ex.head === :quote && return ex
    if ex.head === :$ && length(ex.args) == 1
        code = interpolated_code(ex.args[1], values, computed)
        code === nothing || return Meta.parse(code)
    end
    return Expr(ex.head, Any[substitute(a, values, computed) for a in ex.args]...)
end

# The keywords and the body of a `@testtemplate` call, its interpolations' values in
# place, as the item that instance is should read.
function instance_code(template::Expr, values::Dict{Symbol, String}, computed::Dict{String, String})
    args = Any[a for a in template.args[2:end] if !(a isa LineNumberNode)]
    return Expander.unlined(Expr(:block, Any[substitute(a, values, computed) for a in args[2:(end - 1)]]...,
                            substitute(args[end].args[2], values, nothing)))
end

function reads_as(instance::String, want::Expr)
    got = try
        Meta.parse(instance)
    catch e
        e isa Meta.ParseError || rethrow()
        return false
    end
    got isa Expr && got.head === :macrocall || return false
    args = Any[a for a in got.args[2:end] if !(a isa LineNumberNode)]
    return Expander.unlined(Expr(:block, args[2:(end - 1)]..., args[end])) == want
end

# `text` written to `path` whole or not at all: a reader never sees half a file.
function write_whole(path::AbstractString, text::AbstractString)
    tmp = string(path, ".", getpid(), ".tmp")
    try
        write(tmp, text)
        mv(tmp, path; force = true)
    finally
        rm(tmp; force = true)
    end
    return nothing
end

### Expanding ##############################################################

const EXPANDER_FILE = joinpath(@__DIR__, "expander.jl")

"""
    expand_templates(target, templates) -> Union{String, Vector{Dict{String,Any}}}

Run `templates` in one process with the test environment active and the setups
loadable, as a worker has them, and return what it answered for each, or why it
gave no answer. The process has as long as a profile's `init` may take.
"""
function expand_templates(target, templates::Vector{String})
    limit = try
        read_config(target.testdir).init_timeout_s
    catch e
        e isa ConfigError || rethrow()
        30 * 60
    end
    request, response = tempname() * ".toml", tempname() * ".toml"
    try
        project = something(project_name_of(target.project), "")
        open(io -> TOML.print(io, Dict("project" => project, "templates" => templates)), request, "w")
        failure = with_test_env(target) do
            with_load_path(joinpath(target.testdir, TESTSETUPS_DIR)) do
                # The process's own `TOML` is a standard library, which a load path such
                # as `Pkg.test` gives a package's tests leaves out.
                paths = "@stdlib" in LOAD_PATH ? LOAD_PATH : [LOAD_PATH; "@stdlib"]
                env = ["JULIA_LOAD_PATH" => join(paths, PATHSEP)]
                Base.active_project() === nothing || push!(env, "JULIA_PROJECT" => Base.active_project())
                # Without colour, whatever this process's own: what it says goes to a
                # file, and from there into the report.
                cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no --color=no
                       -e "include(ARGS[1]); Expander.main(ARGS[2], ARGS[3])" $EXPANDER_FILE $request $response`
                run_expander(addenv(cmd, env...), limit)
            end
        end
        failure === nothing || return failure
        isfile(response) || return "the process expanding the templates ended without an answer"
        return Dict{String, Any}[d for d in TOML.parsefile(response)["templates"]]
    finally
        rm(request; force = true)
        rm(response; force = true)
    end
end

# `nothing` once the process has exited cleanly; otherwise why it did not, with what it
# said that shows why. One past `limit` gets SIGTERM first, on which Julia says which
# line of a template it was running, and SIGKILL if it is still there.
function run_expander(cmd::Cmd, limit::Real)
    said = tempname()
    try
        proc = open(io -> run(pipeline(cmd; stdout = io, stderr = io); wait = false), said, "w")
        try
            if timedwait(() -> process_exited(proc), limit; pollint = 0.2) === :timed_out
                kill(proc, Base.SIGTERM)
                timedwait(() -> process_exited(proc), 5.0; pollint = 0.2) === :timed_out && kill(proc, Base.SIGKILL)
                wait(proc)
                return "the process expanding the templates took longer than $(fmt_seconds(limit)), " *
                    "the `init_timeout` setting, and was stopped" * why_it_failed(read(said, String))
            end
        catch
            process_exited(proc) || kill(proc)
            rethrow()
        end
        success(proc) && return nothing
        return "the process expanding the templates failed" *
            (proc.termsignal != 0 ? ", killed by signal $(proc.termsignal)" : ", exiting with $(proc.exitcode)") *
            why_it_failed(read(said, String))
    finally
        rm(said; force = true)
    end
end

# What a failed expanding process said that shows why, indented under the report's
# line: its error up to the stacktrace, and Julia's `in expression starting at`
# lines, which say where it was. Empty when it said neither.
function why_it_failed(said::AbstractString)
    lines = split(said, '\n')
    shown = String[]
    at = findfirst(l -> startswith(l, "ERROR:"), lines)
    if at !== nothing
        for l in lines[at:end]
            startswith(l, "Stacktrace:") && break
            isempty(strip(l)) || push!(shown, l)
        end
    end
    append!(shown, unique(l for l in lines if startswith(l, "in expression starting at")))
    isempty(shown) && return ""
    return string(":\n", join(("    " * l for l in first(shown, 10)), "\n"))
end

### Chores #################################################################

# Under `fix`, expands every template whose expansion is `chores`' to write and
# deletes the expansions of templates that are gone; otherwise reads the stamps and
# runs nothing. Every template is expanded, its stamp current or not: what its code
# computes can change while its text does not. The number of expansions written or
# deleted, or to be, and of problems a person has to fix.
function chore_templates!(io::IO, target, fix::Bool)
    files, _, templates = walk_test_dir(target.testdir)
    orphans = String[f for f in files if !isfile(template_of(f)) && read_stamp(f) !== nothing]
    if isempty(templates) && isempty(orphans)
        println(io, "templates: none")
        return (0, 0)
    end
    expanded = Pair{String, String}[]   # file => what it is expanded from, or why it is to be
    deleted = Pair{String, String}[]    # file => why it goes
    problems = Pair{String, String}[]   # file => what a person has to fix
    states = Dict(t => expansion_state(t) for t in templates)
    for t in templates
        state = states[t]
        state in (:edited, :in_the_way) && push!(problems, expansion_of(t) => expansion_message(state, t))
    end
    if fix
        todo = filter(t -> !(states[t] in (:edited, :in_the_way)), templates)
        answers = isempty(todo) ? Dict{String, Any}[] : expand_templates(target, todo)
        answers isa String && push!(problems, target.testdir => answers)
        for answer in (answers isa String ? Dict{String, Any}[] : answers)
            t = String(answer["path"])
            if haskey(answer, "error")
                line = Int(get(answer, "line", 0))
                push!(problems, t => string(line == 0 ? "" : "line $line: ", answer["error"]))
                continue
            end
            text = try
                render_expansion(t, String(answer["text"]), answer["items"])
            catch e
                e isa InterruptException && rethrow()
                push!(problems, t => sprint(showerror, e))
                continue
            end
            o = expansion_of(t)
            isfile(o) && canonical_text(read(o, String)) == canonical_text(text) && continue
            write_whole(o, text)
            n = sum(item -> length(item["instances"]), answer["items"]; init = 0)
            push!(expanded, o => string("from ", relpath_or_path(t), ", ", plural(n, "test item")))
        end
    else
        for t in templates
            state = states[t]
            state in (:missing, :stale, :other_format) && push!(expanded, expansion_of(t) =>
                (state === :missing ? string("from ", relpath_or_path(t), ", not expanded yet") :
                    string("from ", relpath_or_path(t), ", which changed since it was expanded")))
        end
    end
    for f in orphans
        stamp = read_stamp(f)::Stamp
        if stamp.actual != stamp.expansion
            push!(problems, f => "expanded from $(relpath_or_path(template_of(f))), which is gone, and edited since: delete it by hand if it is no longer wanted")
        else
            fix && rm(f; force = true)
            push!(deleted, f => string("its template, ", relpath_or_path(template_of(f)), ", is gone"))
        end
    end
    parts = String[]
    isempty(expanded) || push!(parts, string(length(expanded), fix ? " expanded" : " to expand"))
    isempty(deleted) || push!(parts, string(length(deleted), fix ? " deleted" : " to delete"))
    isempty(problems) || push!(parts, string(length(problems), " to fix by hand"))
    println(io, "templates: ", length(templates), ", ", isempty(parts) ? "every expansion current" : join(parts, ", ") * ":")
    for (f, what) in expanded
        println(io, "  ", relpath_or_path(f), ": ", fix ? "expanded " : "to expand ", what)
    end
    for (f, why) in deleted
        println(io, "  ", relpath_or_path(f), ": ", fix ? "deleted" : "to delete", ", as ", why)
    end
    for (f, msg) in problems
        print(io, "  ")
        printstyled(io, relpath_or_path(f), ": ", msg; color = :red)
        println(io)
    end
    return (length(expanded) + length(deleted), length(problems))
end
