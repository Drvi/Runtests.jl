# Static coverage-checked dispatch over a fixed set of `runtests` variants.

const DISPATCH_SELECTION_KEYS = (:name, :tags, :group, :paths, :replay, :skip_environment)

struct DispatchSpec
    paths::Vector{String}
    kwargs::NamedTuple
end

# Normalize one variant or exclude entry into `(resolved_paths, runtests_kwargs)`.
# Paths given relative are resolved against `root` so `test/runtests.jl` can write
# `"test/qa"` regardless of `pwd()`.
function parse_dispatch_spec(label::AbstractString, spec, root::AbstractString)
    raw_paths, kw = if spec isa NamedTuple
        if haskey(spec, :paths)
            spec.paths, Base.structdiff(spec, NamedTuple{(:paths,)})
        else
            nothing, spec
        end
    elseif spec isa Pair
        first(spec), last(spec)
    elseif spec isa Union{AbstractString, AbstractVector{<:AbstractString}, Tuple{Vararg{AbstractString}}}
        spec, (;)
    else
        throw(ArgumentError(
            "`runtests_dispatch`: $(label) must be a NamedTuple of `runtests` keywords, " *
            "a `paths => (; kwargs...)` pair, or path(s); got $(typeof(spec))"
        ))
    end
    kw isa NamedTuple || throw(ArgumentError(
        "`runtests_dispatch`: keywords of $(label) must be a NamedTuple, got $(typeof(kw))"
    ))
    haskey(kw, :paths) && throw(ArgumentError(
        "`runtests_dispatch`: $(label) specifies `paths` both positionally and as a keyword"
    ))
    haskey(kw, :replay) && throw(ArgumentError(
        "`runtests_dispatch`: $(label) cannot pass `replay`"
    ))
    paths = normalize_dispatch_paths(label, raw_paths, root)
    return DispatchSpec(paths, kw)
end

function normalize_dispatch_paths(label::AbstractString, raw, root::AbstractString)
    raw === nothing && return String[]
    list = if raw isa AbstractString
        String[String(raw)]
    elseif raw isa AbstractVector{<:AbstractString} || raw isa Tuple{Vararg{AbstractString}}
        String[String(p) for p in raw]
    else
        throw(ArgumentError(
            "`runtests_dispatch`: `paths` of $(label) must be a String or collection of Strings, got $(typeof(raw))"
        ))
    end
    return String[isabspath(p) ? p : joinpath(root, p) for p in list]
end

# Normalize `exclude` into zero or more `DispatchSpec`s.
function parse_dispatch_excludes(exclude, root::AbstractString)
    exclude === nothing && return DispatchSpec[]
    if exclude isa AbstractVector || (exclude isa Tuple && !(exclude isa Tuple{Vararg{AbstractString}}))
        return DispatchSpec[parse_dispatch_spec("`exclude[$i]`", s, root) for (i, s) in enumerate(exclude)]
    end
    return DispatchSpec[parse_dispatch_spec("`exclude`", exclude, root)]
end

# Build the static item predicate for one `DispatchSpec` using the exact same rules
# `prepare` / `scan` use, without reading `RUNTESTS_GROUP` from the environment.
function dispatch_predicate(label::AbstractString, spec::DispatchSpec, target::Target,
                            groups::Dict{String, TagExpr}, config_path::AbstractString,
                            known_envs::Vector{String}, naming::AbstractString)
    # Validate target paths belong to this package and live under `test/`.
    narrowing = if isempty(spec.paths)
        String[]
    else
        t = resolve_target(Tuple(spec.paths))
        t.root == target.root || throw(ArgumentError(
            "`runtests_dispatch`: $(label) targets $(t.root), not $(target.root)"
        ))
        t.paths
    end
    name = get(spec.kwargs, :name, nothing)
    tags = get(spec.kwargs, :tags, nothing)
    group_req = get(spec.kwargs, :group, nothing)
    group_sel = group_req === nothing ? nothing : select_group(groups, config_path, group_req, true)
    filter = Filter(; name, tags, paths = narrowing, group = group_sel)

    skip_raw = get(spec.kwargs, :skip_environment, nothing)
    skip_envs = Set{String}()
    if skip_raw !== nothing
        list = skip_raw isa AbstractString ? String[String(skip_raw)] :
               skip_raw isa AbstractVector{<:AbstractString} ? String[String(s) for s in skip_raw] :
               throw(ArgumentError("`runtests_dispatch`: `skip_environment` of $(label) must be a String or Vector{String}"))
        normed = unique!(String[rstrip(replace(s, '\\' => '/'), '/') for s in list])
        check_skip_environment(normed, known_envs, naming, ArgumentError)
        union!(skip_envs, normed)
    end
    return (it::RawItem) -> begin
        if !isempty(skip_envs) && !isempty(it.environment)
            rel_slash(it.environment, naming) in skip_envs && return false
        end
        return matches_path(filter.paths, it.file) &&
               matches_name(filter.name, it.name) &&
               matches_tags(filter.tags, it.tags) &&
               matches_tags(filter.group, it.tags)
    end
end

"""
    runtests_dispatch([root], selected, variants::AbstractDict;
                      exclude = nothing, allow_overlaps = true, kwargs...)

Dispatch one named variant from `variants` to [`runtests`](@ref), statically verifying
before running that:

1. `selected` is a declared key of `variants` (and no selection keyword — `name`, `tags`,
   `group`, `paths`, `skip_environment`, or `replay` — is passed outside `variants`;
   `replay` is also forbidden inside `variants` and `exclude`).
2. Every test item in the package's suite is covered by at least one variant in `variants`
   (items in an environment directory skipped by a variant's `skip_environment` are not
   counted as covered by that variant) or by `exclude`.
3. When `allow_overlaps = false`, no test item is covered by more than one variant (or by
   both a variant and `exclude`).

`root`, when given, is a package directory or `Module` (defaulting to the active
package). `variants` is a non-empty `AbstractDict` mapping each variant key to a
`NamedTuple` of `runtests` keywords (with an optional `paths` entry for positional path
arguments, resolved relative to the package root), a `paths => (; kwargs...)` pair, or
path(s). `exclude` takes one such selection spec or a collection of them. Shared runtime
keywords (such as `workers`, `logs`, or `dry_run`) may be passed in `kwargs...` and are
overridden by any keyword set on the selected variant. If the chosen variant declares no
`group`, `group = "all"` is passed so `RUNTESTS_GROUP` in the environment cannot silently
narrow it.

Returns what [`runtests`](@ref) returns (a [`RunTestSet`](@ref), or `nothing` for
`dry_run = true`). Throws `ArgumentError` for empty/invalid specs, an unknown `selected`
key, or disallowed top-level selection keywords; throws [`ConfigError`](@ref) for
uncovered items or disallowed overlaps.
"""
function runtests_dispatch(selected, variants::AbstractDict;
                           exclude = nothing, allow_overlaps::Bool = true, kwargs...)
    return runtests_dispatch(default_search_dir(), selected, variants; exclude, allow_overlaps, kwargs...)
end

function runtests_dispatch(root::Union{AbstractString, Module}, selected, variants::AbstractDict;
                           exclude = nothing, allow_overlaps::Bool = true, kwargs...)
    isempty(variants) && throw(ArgumentError("`runtests_dispatch`: `variants` must not be empty"))
    for k in keys(kwargs)
        k in DISPATCH_SELECTION_KEYS && throw(ArgumentError(
            "`runtests_dispatch`: selection keyword `$(k)` must be declared inside `variants`, " *
            "not passed as a top-level argument"
        ))
    end
    if !haskey(variants, selected)
        supported = sort!(collect(keys(variants)); by = string)
        throw(ArgumentError(
            "`runtests_dispatch`: unknown variant $(repr(selected)); supported variants are " *
            join(repr.(supported), ", ")
        ))
    end

    target = root isa Module ? target_from_dir(_pkgdir(root)) : target_from_dir(abspath(String(root)))
    ordered_keys = sort!(collect(keys(variants)); by = string)
    specs = Dict{Any, DispatchSpec}(
        k => parse_dispatch_spec("variant $(repr(k))", variants[k], target.root) for k in ordered_keys
    )
    excludes = parse_dispatch_excludes(exclude, target.root)

    config_path, toml = config_toml(target.testdir, get(kwargs, :config, nothing))
    groups = read_groups(config_path, toml)
    files, strays, templates, environments = walk_test_dir(target.testdir)
    if isempty(files)
        errors = copy(strays)
        append!(errors, expansion_errors(files, templates))
        isempty(errors) || throw(ScanFailure(errors))
        throw(NoTestsError("no test files found under $(joinpath(relpath_or_path(target.testdir), ""))"))
    end
    setups = setup_modules(target.testdir)
    all_items = scan(files, Filter(), setups; strays, templates, expansions = true, environments)

    naming = naming_root(target.root)
    known_envs = String[rel_slash(dir, naming) for dir in environments]
    preds = Pair{Any, Function}[
        k => dispatch_predicate("variant $(repr(k))", specs[k], target, groups, config_path, known_envs, naming)
        for k in ordered_keys
    ]
    ex_preds = Function[
        dispatch_predicate("`exclude`", s, target, groups, config_path, known_envs, naming)
        for s in excludes
    ]

    uncovered = RawItem[]
    overlaps = Tuple{RawItem, Vector{String}}[]
    for it in all_items
        hits = String[]
        for (k, pred) in preds
            pred(it) && push!(hits, repr(k))
        end
        ex_hit = any(pred -> pred(it), ex_preds)
        if isempty(hits) && !ex_hit
            push!(uncovered, it)
        elseif !allow_overlaps && (length(hits) > 1 || (!isempty(hits) && ex_hit))
            ex_hit && push!(hits, "exclude")
            push!(overlaps, (it, hits))
        end
    end

    if !isempty(uncovered)
        throw(ConfigError(sprint() do io
            println(io, "`runtests_dispatch`: ", plural(length(uncovered), "test item"),
                    " not covered by any variant or `exclude`:")
            for it in first(uncovered, 20)
                println(io, "  ", repr(it.name), " at ", relpath_or_path(it.file, target.root), ":", it.line)
            end
            length(uncovered) > 20 && println(io, "  … and ", length(uncovered) - 20, " more")
        end))
    end
    if !isempty(overlaps)
        throw(ConfigError(sprint() do io
            println(io, "`runtests_dispatch`: ", plural(length(overlaps), "test item"),
                    " matched by multiple variants (`allow_overlaps = false`):")
            for (it, hits) in first(overlaps, 20)
                println(io, "  ", repr(it.name), " (", join(hits, ", "), ") at ",
                        relpath_or_path(it.file, target.root), ":", it.line)
            end
            length(overlaps) > 20 && println(io, "  … and ", length(overlaps) - 20, " more")
        end))
    end

    chosen = specs[selected]
    merged = merge(NamedTuple(kwargs), chosen.kwargs)
    # Prevent `RUNTESTS_GROUP` from silently narrowing a variant that declared no `group`.
    if !haskey(merged, :group)
        merged = merge(merged, (; group = ALL_GROUP))
    end
    call_args = isempty(chosen.paths) ? (target.root,) : Tuple(chosen.paths)
    return runtests(call_args...; merged...)
end
