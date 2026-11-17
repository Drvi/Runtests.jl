# A process that compiles packages for the run's precompile queue (`precompile_queue.jl`).
# Julia's active project and load path are one value for the whole process, and both
# decide which package a name is, whether a cache is fresh, and the name of the cache
# file. So each environment the queue compiles in, other than the coordinator's own,
# has a process of its own, started with that project and load path. The coordinator
# decides what compiles when and how many compile at once; this process only answers
# its requests.
#
# Base only: it runs in any environment, also one that cannot load Runtests. Runtests
# includes this file as well, for the checks and the compiles it makes in its own
# process.
module PrecompileHelper

# The protocol, one line a message, fields split by tabs:
#
#     config <i> <cache flags> <julia argument>...     defines set of flags `i`
#     fresh <i> <uuid> <name> <path>                  the cache of a dependency under `i`
#     build <job> <i> <uuid> <name> <strict> <exts>   compile it, unless fresh
#
# `<uuid>` is `-` for a package without one. `<cache flags>` is the tuple that
# `cache_flags_text` writes. `fresh` names the cache file that a package compiled for
# set `i` loads its dependency from: as Julia's precompiler does, a cache is fresh only
# against those files. `<strict>` is `1` to refuse to compile a dependency in the
# compile process, `0` to let it. `<exts>` is `-`, or the extensions that may load while
# the package compiles, as `<uuid>=<name>` joined by commas. A build gets one reply, in
# any order:
#
#     <job> <status> <seconds> <path> <rss> <text>
#
# `<status>` is `built`, `fresh` (found fresh), `waited` (another process held the lock
# and built it), `unprecompilable` (the module cannot be precompiled, and loads from its
# source) or `failed`. `<path>` is the fresh cache file, or `-`. `<rss>` is the largest
# resident size in bytes of a compile this process has reaped, or 0 where the platform
# keeps none. `<text>` is the output of a compile that did not build, escaped by
# `escape_field`.

const FILEWATCHING = Base.PkgId(Base.UUID("7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"), "FileWatching")

# Every field of a `Base.CacheFlags`, in order, as a tuple of literals: the fields
# differ between versions (1.14 adds `coverage` and `coverage_path`, a path that can
# hold a space, or `nothing`).
cache_flags_text(f::Base.CacheFlags) = repr(ntuple(i -> getfield(f, i), nfields(f)))

# The flags that `cache_flags_text` wrote, or `nothing` for text it did not write.
# Read, not evaluated: `nothing` reads as a name, and every other field as a literal.
function cache_flags_from(text::AbstractString)
    ex = Meta.parse(text; raise = false)
    f = ex isa Expr && ex.head === :tuple ? Any[a === :nothing ? nothing : a for a in ex.args] : Any[]
    T = Base.CacheFlags
    length(f) == fieldcount(T) || return nothing
    return T((convert(fieldtype(T, i), f[i]) for i in 1:fieldcount(T))...)
end

# A field may hold any text: backslashes, tabs and line ends are escaped.
escape_field(s::AbstractString) = replace(s, '\\' => "\\\\", '\t' => "\\t", '\n' => "\\n", '\r' => "\\r")
function unescape_field(s::AbstractString)
    out = IOBuffer()
    escaped = false
    for c in s
        if escaped
            write(out, c == 't' ? '\t' : c == 'n' ? '\n' : c == 'r' ? '\r' : c)
            escaped = false
        elseif c == '\\'
            escaped = true
        else
            write(out, c)
        end
    end
    return String(take!(out))
end

pkgid_field(pkg::Base.PkgId) = string(pkg.uuid === nothing ? "-" : string(pkg.uuid), '\t', pkg.name)
pkgid_from(uuid::AbstractString, name::AbstractString) =
    Base.PkgId(uuid == "-" ? nothing : Base.UUID(uuid), String(name))

exts_field(::Nothing) = "-"
exts_field(exts::Vector{Base.PkgId}) = join((string(e.uuid, '=', e.name) for e in exts), ',')
function exts_from(s::AbstractString)
    s == "-" && return nothing
    isempty(s) && return Base.PkgId[]
    return [Base.PkgId(Base.UUID(first(kv)), String(last(kv))) for kv in (split(e, '='; limit = 2) for e in split(s, ','))]
end

"""
    has_fresh_cache(pkg, flags; sourcepath = nothing) -> Bool

Whether a new process with cache flags `flags`, in this process's environment, finds a
cache of `pkg` that it can load. Asked as of a fresh session (`ignore_loaded`), as a
worker is one: otherwise the answer is about the builds this process has loaded, which
for other flags is no. `sourcepath` names the source directly, for a package this
process cannot locate.
"""
function has_fresh_cache(pkg::Base.PkgId, flags::Base.CacheFlags;
                         sourcepath::Union{String, Nothing} = nothing)
    # `nothing` is not theirs to pass on: their own fallback locates the package.
    kw = sourcepath === nothing ? (;) : source_kwarg(sourcepath)
    # 1.12's `isprecompiled` takes the flags; from 1.13 it asks for this process's
    # only, and the function behind it takes them.
    @static if hasmethod(Base.isprecompiled, Tuple{Base.PkgId}, (:flags,))
        return Base.isprecompiled(pkg; flags, ignore_loaded = true, kw...)
    else
        return Base.compilecache_freshest_path(pkg; flags, ignore_loaded = true,
                                               verify_checksums = false, kw...) !== nothing
    end
end
"""
    freshest_path(pkg, flags; stale_cache, cachepath_cache) -> Union{Nothing, String}

The cache file of `pkg` that a new process with cache flags `flags` loads, in this
process's environment, or `nothing`. A dependency in `cachepath_cache` must be loaded
from one of the files it holds for it, as Julia's precompiler holds each dependency to
the file it found or built: a cache built against another build of a dependency is not
fresh, though both files are. `stale_cache` holds the verdicts on single files, for
checks that build nothing in between. A package whose source cannot be found has none.
"""
function freshest_path(pkg::Base.PkgId, flags::Base.CacheFlags;
                       stale_cache::Dict{Base.StaleCacheKey, Bool} = Dict{Base.StaleCacheKey, Bool}(),
                       cachepath_cache::Dict{Base.PkgId, Vector{String}} = Dict{Base.PkgId, Vector{String}}())
    # The package's own files from the depot, whatever `cachepath_cache` holds for it.
    cachepaths = Base.find_all_in_cache_path(pkg)
    isempty(cachepaths) && return nothing
    try
        # 1.13 renamed the function; before, `compilecache_path` takes the same keywords.
        # From 1.13 the checksum of each image file is left out: reading every image is
        # most of the cost of the check, and Julia checks it when a worker loads the image.
        @static if isdefined(Base, :compilecache_freshest_path)
            return Base.compilecache_freshest_path(pkg; ignore_loaded = true, stale_cache, cachepath_cache, cachepaths, flags,
                                                   verify_checksums = false)
        else
            return Base.compilecache_path(pkg; ignore_loaded = true, stale_cache, cachepath_cache, cachepaths, flags)
        end
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

# The largest resident size of a compile this process has reaped, in bytes, or 0
# where the platform keeps no rusage (Windows). `getrusage` counts a child once it
# has been waited for, as the compile process of `compilecache` has been; it is a
# peak over every child so far, so a job's number can only move upward.
function children_maxrss()
    Sys.iswindows() && return 0.0
    buf = zeros(UInt8, 256)
    ccall(:getrusage, Cint, (Cint, Ptr{UInt8}), Cint(-1), buf) == 0 || return 0.0
    # `ru_maxrss` follows the two `timeval`s, of two `long`s each (macOS's `int32_t`
    # usec pads its `timeval` out to the same): bytes on macOS, kilobytes elsewhere.
    peak = GC.@preserve buf unsafe_load(Ptr{Clong}(pointer(buf) + 4 * sizeof(Clong)))
    return Sys.isapple() ? Float64(peak) : Float64(peak) * 1024.0
end

# From 1.14 the source is a `Base.PkgLoadSpec`, the path with the syntax edition that
# Base gives a package it knows only by the path of its source.
@static if isdefined(Base, :PkgLoadSpec)
    # `LATEST_EDITION` from 1.14.0-beta1, `VERSION_EDITION` in the builds before it.
    const SOURCE_EDITION = isdefined(Base, :LATEST_EDITION) ? Base.LATEST_EDITION : Base.VERSION_EDITION
    source_kwarg(path) = (; sourcespec = Base.PkgLoadSpec(path, SOURCE_EDITION))
else
    source_kwarg(path) = (; sourcepath = path)
end

# The source of `pkg` in the form that the positional `Base.compilecache` takes, or
# `nothing`: from 1.14 a load spec, and before that the path alone.
@static if isdefined(Base, :locate_package_load_spec)
    package_source(pkg::Base.PkgId) = Base.locate_package_load_spec(pkg)
else
    package_source(pkg::Base.PkgId) = Base.locate_package(pkg)
end

# Julia's own precompiler compiles a package that has dependencies with
# `--compiled-modules=strict` from 1.13: a dependency without a cache is then an error
# in the compile process, not a compile of its own there, one at a time. From 1.13 it
# also hands the compile process the cache file of each dependency (`preresolved`),
# so that it loads the files the cache was found fresh against.
const STRICT = VERSION >= v"1.13.0-"
preresolved(cachepath_cache::Dict{Base.PkgId, Vector{String}}) =
    Pair{Base.PkgId, String}[k => first(v) for (k, v) in cachepath_cache if !isempty(v)]

# `f()` under the lock that stops two processes from compiling one cache, as Julia's
# precompiler takes it, or `nothing` once another process that held it is done. Without
# FileWatching's hooks, `f()` alone, as Base does.
function with_cache_lock(f, pkg::Base.PkgId, flags::Base.CacheFlags)
    (isdefined(Base, :mkpidlock_hook) && isdefined(Base, :trymkpidlock_hook)) || return f()
    pidfile = Base.compilecache_pidfile_path(pkg; flags)
    stale_age = Base.compilecache_pidlock_stale_age
    got = @invokelatest Base.trymkpidlock_hook(f, pidfile; stale_age)
    got === false || return got
    return @invokelatest Base.mkpidlock_hook(Returns(nothing), pidfile; stale_age)
end

"""
    compile(pkg, args, flags; strict, loadable_exts, cachepath_cache) -> (status, seconds, path, rss, text)

Compile `pkg` in this process's environment, for a process started with julia
arguments `args` and so with cache flags `flags`, unless a fresh cache is found once
the lock is held. `cachepath_cache` holds the cache files of its dependencies
(`freshest_path`). `status` is `:built`, `:fresh`, `:waited`, `:unprecompilable` or
`:failed`; `path` is the fresh cache file, or `nothing`; `rss` is the largest
resident size of a compile this process has reaped; `text` is the output of a
compile that did not build.
"""
function compile(pkg::Base.PkgId, args::Cmd, flags::Base.CacheFlags;
                 strict::Bool = false, loadable_exts::Union{Nothing, Vector{Base.PkgId}} = nothing,
                 cachepath_cache::Dict{Base.PkgId, Vector{String}} = Dict{Base.PkgId, Vector{String}}())
    t0 = time()
    # Julia writes why a module would not precompile to the stream it is given, and
    # throws an exception saying only that it failed; both go in the text.
    out = IOBuffer()
    local status, path
    try
        source = package_source(pkg)
        source === nothing && throw(ArgumentError("$pkg not found during precompilation"))
        fresh() = freshest_path(pkg, flags; cachepath_cache)
        build() = with_cache_lock(pkg, flags) do
            p = fresh()
            p === nothing || return (:fresh, p)
            kw = STRICT ? (; preresolved = preresolved(cachepath_cache)) : (;)
            # Without this process's modules (`false`): the child would be held to the
            # builds of them loaded here.
            c = Base.compilecache(pkg, source, out, out, false;
                                  flags = strict && STRICT ? `$args --compiled-modules=strict` : args,
                                  cacheflags = flags, loadable_exts, kw...)
            # Returned, not thrown: the module cannot be precompiled, as a module that
            # declares `__precompile__(false)` or that loads a module that loads it.
            # Julia's precompiler marks it and goes on.
            c isa Exception && return (:unprecompilable, nothing)
            return (:built, String(first(c)))
        end
        # The lock is one file for every project and set of preferences: what another
        # process built while this one waited can be a cache for another project.
        r = build()
        if r === nothing
            p = fresh()
            r = p === nothing ? something(build(), (:waited, nothing)) : (:waited, p)
        end
        status, path = r
    catch e
        e isa InterruptException && rethrow()
        detail = strip(String(take!(out)))
        return (:failed, time() - t0, nothing, children_maxrss(), string(sprint(showerror, e), isempty(detail) ? "" : "\n" * detail))
    end
    text = status === :unprecompilable ? String(strip(String(take!(out)))) : ""
    return (status, time() - t0, path, children_maxrss(), text)
end

"""
    serve(input = stdin)

Answer the requests on `input` until it ends, each reply on this process's standard
output, which carries nothing else. Requests run at the same time; the coordinator
decides how many builds it has out at once.
"""
function serve(input::IO = stdin)
    output = stdout
    # Anything printed by accident goes where the coordinator reads it as text.
    redirect_stdout(stderr)
    # Its hooks are the lock on a cache file.
    Base.require(FILEWATCHING)
    configs = Dict{Int, Tuple{Cmd, Base.CacheFlags, Dict{Base.PkgId, Vector{String}}}}()
    lock = ReentrantLock()
    reply(job, status, seconds, path, rss, text) = @lock lock begin
        println(output, job, '\t', status, '\t', round(seconds; digits = 2), '\t', something(path, "-"), '\t',
                round(Int, rss), '\t', escape_field(text))
        flush(output)
    end
    @sync for line in eachline(input)
        f = split(line, '\t')
        if f[1] == "config"
            flags = cache_flags_from(f[3])
            flags === nothing && error("unreadable cache flags: $(f[3])")
            configs[parse(Int, f[2])] = (Cmd(String[a for a in f[4:end]]), flags, Dict{Base.PkgId, Vector{String}}())
        elseif f[1] == "fresh"
            last(configs[parse(Int, f[2])])[pkgid_from(f[3], f[4])] = [String(f[5])]
        elseif f[1] == "build"
            job, (args, flags, caches) = f[2], configs[parse(Int, f[3])]
            pkg = pkgid_from(f[4], f[5])
            strict, exts = f[6] == "1", exts_from(f[7])
            @async begin
                status, seconds, path, rss, text = try
                    compile(pkg, args, flags; strict, loadable_exts = exts, cachepath_cache = caches)
                catch e
                    (:failed, 0.0, nothing, 0.0, sprint(showerror, e))
                end
                path === nothing || (caches[pkg] = [path])
                reply(job, status, seconds, path, rss, text)
            end
        end
    end
    return nothing
end

end # module PrecompileHelper
