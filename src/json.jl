# JSON, as far as the editor protocol needs it: a writer for every value it sends,
# and a strict reader for the commands it receives. Written here rather than taken
# from a package because YATF is loaded into the test environment of the package it
# tests, where a JSON dependency of its own would constrain that package's choice of
# version.

"""
    write_json(io, x)

`x` as JSON: strings (invalid UTF-8 replaced by U+FFFD, which JSON cannot carry
otherwise), symbols as strings, integers, finite floats (a non-finite one as
`null`, which is what JSON has for it), booleans, `nothing` as `null`, vectors and
tuples as arrays, and dictionaries, named tuples and pairs as objects.
"""
function write_json(io::IO, s::AbstractString)
    write(io, '"')
    for c in s
        if !isvalid(c)
            write(io, "\\ufffd")
        elseif c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif c < ' '
            write(io, "\\u", string(UInt16(c); base = 16, pad = 4))
        else
            write(io, c)
        end
    end
    write(io, '"')
    return nothing
end
write_json(io::IO, s::Symbol) = write_json(io, String(s))
write_json(io::IO, b::Bool) = (write(io, b ? "true" : "false"); nothing)
write_json(io::IO, ::Nothing) = (write(io, "null"); nothing)
write_json(io::IO, n::Integer) = (print(io, n); nothing)
write_json(io::IO, x::AbstractFloat) = (isfinite(x) ? print(io, Float64(x)) : write(io, "null"); nothing)
# A `Float32` printed as a `Float64` shows digits the `Float32` never had.
write_json(io::IO, x::Float32) = write_json(io, isfinite(x) ? round(Float64(x); sigdigits = 7) : Float64(x))
function write_json(io::IO, v::Union{AbstractVector, Tuple})
    write(io, '[')
    for (k, x) in enumerate(v)
        k > 1 && write(io, ',')
        write_json(io, x)
    end
    write(io, ']')
    return nothing
end
function write_json(io::IO, d::Union{AbstractDict, NamedTuple, Base.Pairs})
    write(io, '{')
    for (k, (key, x)) in enumerate(pairs(d))
        k > 1 && write(io, ',')
        write_json(io, string(key))
        write(io, ':')
        write_json(io, x)
    end
    write(io, '}')
    return nothing
end

json(x) = sprint(write_json, x)

"""
    read_json(text) -> Any

One JSON value: objects as `Dict{String, Any}`, arrays as `Vector{Any}`, strings,
numbers as `Int64` when written without a fraction or exponent and `Float64`
otherwise, booleans, and `null` as `nothing`. Anything else, including text after
the value, throws an `ArgumentError` saying what was expected and at which byte.
"""
function read_json(text::AbstractString)
    s = String(text)
    v, i = json_value(s, json_skip(s, 1))
    i = json_skip(s, i)
    i <= ncodeunits(s) && json_error(s, i, "the end of the text")
    return v
end

json_error(s, i, expected) = throw(ArgumentError(string(
    "malformed JSON: expected ", expected, " at byte ", i,
    i <= ncodeunits(s) ? string(", found ", repr(s[thisind(s, i)])) : ", found the end of the text"
)))

function json_skip(s::String, i::Int)
    while i <= ncodeunits(s) && codeunit(s, i) in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
        i += 1
    end
    return i
end

function json_value(s::String, i::Int)
    i > ncodeunits(s) && json_error(s, i, "a value")
    c = codeunit(s, i)
    c == UInt8('{') && return json_object(s, i + 1)
    c == UInt8('[') && return json_array(s, i + 1)
    c == UInt8('"') && return json_string(s, i + 1)
    (c == UInt8('-') || UInt8('0') <= c <= UInt8('9')) && return json_number(s, i)
    for (word, v) in (("true", true), ("false", false), ("null", nothing))
        startswith(SubString(s, i), word) && return v, i + ncodeunits(word)
    end
    json_error(s, i, "a value")
end

function json_object(s::String, i::Int)
    d = Dict{String, Any}()
    i = json_skip(s, i)
    i <= ncodeunits(s) && codeunit(s, i) == UInt8('}') && return d, i + 1
    while true
        (i <= ncodeunits(s) && codeunit(s, i) == UInt8('"')) || json_error(s, i, "a key in double quotes")
        key, i = json_string(s, i + 1)
        i = json_skip(s, i)
        (i <= ncodeunits(s) && codeunit(s, i) == UInt8(':')) || json_error(s, i, "`:`")
        d[key], i = json_value(s, json_skip(s, i + 1))
        i = json_skip(s, i)
        i > ncodeunits(s) && json_error(s, i, "`,` or `}`")
        c = codeunit(s, i)
        c == UInt8('}') && return d, i + 1
        c == UInt8(',') || json_error(s, i, "`,` or `}`")
        i = json_skip(s, i + 1)
    end
end

function json_array(s::String, i::Int)
    v = Any[]
    i = json_skip(s, i)
    i <= ncodeunits(s) && codeunit(s, i) == UInt8(']') && return v, i + 1
    while true
        x, i = json_value(s, json_skip(s, i))
        push!(v, x)
        i = json_skip(s, i)
        i > ncodeunits(s) && json_error(s, i, "`,` or `]`")
        c = codeunit(s, i)
        c == UInt8(']') && return v, i + 1
        c == UInt8(',') || json_error(s, i, "`,` or `]`")
        i += 1
    end
end

function json_string(s::String, i::Int)
    out = IOBuffer()
    while true
        i > ncodeunits(s) && json_error(s, i, "a closing `\"`")
        c = codeunit(s, i)
        if c == UInt8('"')
            return String(take!(out)), i + 1
        elseif c < 0x20
            json_error(s, i, "a character other than a raw control character")
        elseif c != UInt8('\\')
            write(out, c)
            i += 1
            continue
        end
        i + 1 > ncodeunits(s) && json_error(s, i + 1, "an escape")
        e = codeunit(s, i + 1)
        simple = e == UInt8('"') ? '"' : e == UInt8('\\') ? '\\' : e == UInt8('/') ? '/' :
            e == UInt8('b') ? '\b' : e == UInt8('f') ? '\f' : e == UInt8('n') ? '\n' :
            e == UInt8('r') ? '\r' : e == UInt8('t') ? '\t' : nothing
        if simple !== nothing
            write(out, simple)
            i += 2
            continue
        end
        e == UInt8('u') || json_error(s, i + 1, "one of `\"\\/bfnrtu` after `\\`")
        u, i = json_hex4(s, i + 2)
        # A character beyond U+FFFF comes as a surrogate pair; a lone half is not a
        # character, and stands as U+FFFD.
        if 0xd800 <= u <= 0xdbff && i + 1 <= ncodeunits(s) && codeunit(s, i) == UInt8('\\') &&
                codeunit(s, i + 1) == UInt8('u')
            lo, j = json_hex4(s, i + 2)
            if 0xdc00 <= lo <= 0xdfff
                write(out, Char(0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)))
                i = j
                continue
            end
        end
        write(out, 0xd800 <= u <= 0xdfff ? '�' : Char(u))
    end
end

function json_hex4(s::String, i::Int)
    i + 3 <= ncodeunits(s) || json_error(s, i, "four hexadecimal digits")
    u = tryparse(UInt32, SubString(s, i, i + 3); base = 16)
    u === nothing && json_error(s, i, "four hexadecimal digits")
    return u, i + 4
end

function json_number(s::String, i::Int)
    j = i
    j <= ncodeunits(s) && codeunit(s, j) == UInt8('-') && (j += 1)
    digits(j) = (while j <= ncodeunits(s) && UInt8('0') <= codeunit(s, j) <= UInt8('9'); j += 1; end; j)
    start = j
    j = digits(j)
    j == start && json_error(s, j, "a digit")
    # A leading zero stands alone: `012` is not a JSON number.
    codeunit(s, start) == UInt8('0') && j > start + 1 && json_error(s, start + 1, "`.`, `e` or the end of the number")
    integral = true
    if j <= ncodeunits(s) && codeunit(s, j) == UInt8('.')
        integral = false
        k = j + 1
        j = digits(k)
        j == k && json_error(s, j, "a digit after `.`")
    end
    if j <= ncodeunits(s) && codeunit(s, j) in (UInt8('e'), UInt8('E'))
        integral = false
        j += 1
        j <= ncodeunits(s) && codeunit(s, j) in (UInt8('+'), UInt8('-')) && (j += 1)
        k = j
        j = digits(k)
        j == k && json_error(s, j, "a digit in the exponent")
    end
    text = SubString(s, i, j - 1)
    if integral
        n = tryparse(Int64, text)
        n === nothing || return n, j
    end
    return parse(Float64, text), j
end
