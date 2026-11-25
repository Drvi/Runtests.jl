# Static coverage-checked dispatch over a fixed set of `runtests` variants.

const DISPATCH_SELECTION_KEYS = (:name, :tags, :group, :paths, :replay, :skip_environment)
const DISPATCH_MONO_SELECTION_KEYS = (:name, :tags, :group, :paths, :packages, :replay, :skip_environment)
const DISPATCH_EXCLUDE_KEYS = (:name, :tags, :group, :skip_environment)
const DISPATCH_MONO_EXCLUDE_KEYS = (:name, :tags, :group, :packages, :skip_environment)

function validate_dispatch_spec_kwargs(caller::AbstractString, label::AbstractString, kw::NamedTuple;
                                       mono::Bool, is_exclude::Bool)
    prefix = string("`", caller, "`: ", label, ": ")
    if is_exclude
        allowed = mono ? DISPATCH_MONO_EXCLUDE_KEYS : DISPATCH_EXCLUDE_KEYS
        candidates = String["paths"]
        for x in allowed
            push!(candidates, String(x))
        end
        for (k, v) in pairs(kw)
            if !(k in allowed)
                near = nearest(String(k), candidates; cutoff = max(1, length(String(k)) ÷ 3))
                hint = isempty(near) ? "" : string(" (did you mean ", join(("`$n`" for n in near), " or "), "?)")
                throw(ArgumentError(string(
                    prefix, "unexpected keyword `", k, "`", hint,
                    "; `exclude` only accepts selection keywords: ", join(("`$x`" for x in candidates), ", ")
                )))
            end
            if k === :skip_environment
                validate_run_setting(k, v; prefix)
            else
                validate_call_kwarg(k, v; mono, prefix)
            end
        end
        return nothing
    end
    if mono && haskey(kw, :config)
        throw(ArgumentError(
            "`runtests_dispatch_mono`: $(label) cannot pass `config` (a combined run reads each package's own file)"
        ))
    end
    validate_run_kwargs(kwargs_dict(kw); mono, allow_call_keys = true, prefix)
    return nothing
end

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
    top_opts = kwargs_dict(kwargs)
    validate_run_kwargs(top_opts; mono = false, allow_call_keys = true, prefix = "`runtests_dispatch`: ")
    if !haskey(variants, selected)
        supported = sort_by!(collect(keys(variants)), string)
        throw(ArgumentError(
            "`runtests_dispatch`: unknown variant $(repr(selected)); supported variants are " *
            join(repr.(supported), ", ")
        ))
    end

    target = root isa Module ? target_from_dir(_pkgdir(root)) : target_from_dir(abspath(String(root)))
    ordered_keys = sort_by!(collect(keys(variants)), string)
    specs = Dict{Any, DispatchSpec}(
        k => parse_dispatch_spec("variant $(repr(k))", variants[k], target.root) for k in ordered_keys
    )
    excludes = parse_dispatch_excludes(exclude, target.root)
    for k in ordered_keys
        validate_dispatch_spec_kwargs("runtests_dispatch", "variant $(repr(k))", specs[k].kwargs;
                                      mono = false, is_exclude = false)
    end
    for (i, s) in enumerate(excludes)
        label = length(excludes) == 1 ? "`exclude`" : "`exclude[$i]`"
        validate_dispatch_spec_kwargs("runtests_dispatch", label, s.kwargs;
                                      mono = false, is_exclude = true)
    end
    validate_run_kwargs(merge(top_opts, kwargs_dict(specs[selected].kwargs));
                        mono = false, allow_call_keys = true, prefix = "`runtests_dispatch`: ")

    config_path, toml = config_toml(target.testdir, get(kwargs, :config, nothing))
    groups = read_groups(config_path, toml)
    files, strays, templates, environments = walk_test_dir(target.testdir)
    if isempty(files)
        errors = copy(strays)
        append!(errors, expansion_errors(files, templates))
        isempty(errors) || throw(ScanFailure(errors))
        throw(no_test_files_error(target; from_default = false))
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

# Build the static per-item predicate for one monorepo variant or `exclude` spec,
# matching `prepare_mono` semantics (including `packages`, workspace-relative `paths`,
# per-package `groups`, and `skip_environment`).
function dispatch_mono_predicate(label::AbstractString, spec::DispatchSpec, workspace::AbstractString,
                                 ps::Participants, pkg_groups::Vector{Dict{String, TagExpr}},
                                 config_paths::Vector{String}, known_envs::Vector{String},
                                 naming::AbstractString)
    haskey(spec.kwargs, :config) && throw(ArgumentError(
        "`runtests_dispatch_mono`: $(label) cannot pass `config` (a combined run reads each package's own file)"
    ))
    n = length(ps)
    pkgs_arg = get(spec.kwargs, :packages, nothing)
    allowed_pkgs = if pkgs_arg === nothing
        trues(n)
    else
        sub = find_participants(workspace; packages = pkgs_arg)
        sub_roots = Set(sub.root)
        BitVector([r in sub_roots for r in ps.root])
    end

    chosen = String[]
    narrowing = [String[] for _ in 1:n]
    whole = falses(n)
    if !isempty(spec.paths)
        ws_p, chosen, _ = mono_paths(Tuple(spec.paths))
        ws_p == workspace || throw(ArgumentError(
            "`runtests_dispatch_mono`: $(label) targets workspace $(ws_p), not $(workspace)"
        ))
        narrowing, whole = assign_paths(ps, chosen)
    end

    name = get(spec.kwargs, :name, nothing)
    tags = get(spec.kwargs, :tags, nothing)
    group_req = get(spec.kwargs, :group, nothing)
    gsel, lacking, _ = if group_req === nothing
        Union{Nothing, GroupSelection}[nothing for _ in 1:n], falses(n), ALL_GROUP
    else
        mono_groups(pkg_groups, config_paths, group_req, true)
    end
    base_filter = Filter(; name, tags)

    skip_raw = get(spec.kwargs, :skip_environment, nothing)
    skip_envs = Set{String}()
    if skip_raw !== nothing
        list = skip_raw isa AbstractString ? String[String(skip_raw)] :
               skip_raw isa AbstractVector{<:AbstractString} ? String[String(s) for s in skip_raw] :
               throw(ArgumentError("`runtests_dispatch_mono`: `skip_environment` of $(label) must be a String or Vector{String}"))
        normed = unique!(String[rstrip(replace(s, '\\' => '/'), '/') for s in list])
        check_skip_environment(normed, known_envs, naming, ArgumentError)
        union!(skip_envs, normed)
    end

    has_paths = !isempty(chosen)
    return (it::RawItem) -> begin
        k = it.package
        allowed_pkgs[k] || return false
        lacking[k] && return false
        if has_paths && !whole[k]
            isempty(narrowing[k]) && return false
            matches_path(narrowing[k], it.file) || return false
        end
        if !isempty(skip_envs) && !isempty(it.environment)
            rel_slash(it.environment, naming) in skip_envs && return false
        end
        return matches_name(base_filter.name, it.name) &&
               matches_tags(base_filter.tags, it.tags) &&
               matches_tags(gsel[k], it.tags)
    end
end

"""
    runtests_dispatch_mono([root], selected, variants::AbstractDict;
                           exclude = nothing, allow_overlaps = true, kwargs...)

Combined-workspace counterpart to [`runtests_dispatch`](@ref), dispatching one named
variant from `variants` to [`runtests_mono`](@ref) (Julia 1.12 or later).

Before starting any worker, statically scans every participating package in the
workspace (per `[monorepo]` in the workspace root's `test/TestItems.toml`) and verifies:

1. `selected` is a declared key of `variants`, and no selection keyword — `name`, `tags`,
   `group`, `paths`, `packages`, `skip_environment`, or `replay` — is passed outside
   `variants` (`replay` and `config` are forbidden everywhere).
2. Every test item across every participating workspace package is covered by at least
   one variant in `variants` (excluding items in environments skipped by that variant's
   `skip_environment`) or by `exclude`. Adding a new workspace package whose items no
   variant selects fails here with [`ConfigError`](@ref).
3. When `allow_overlaps = false`, no test item is covered by more than one variant (or by
   both a variant and `exclude`).

`root`, when given, is a directory inside the workspace or a `Module` (defaulting to the
active workspace). Variant `paths` are resolved relative to the workspace root, and
`packages` narrows by package name or workspace-relative directory as in
[`runtests_mono`](@ref). As in [`runtests_mono`](@ref), a `group` declared by only some
packages matches no items in the others without erroring. If the chosen variant declares
no `group`, `group = "all"` is passed so `RUNTESTS_GROUP` cannot silently narrow it.

Returns what [`runtests_mono`](@ref) returns (a [`RunTestSet`](@ref), or `nothing` for
`dry_run = true`).
"""
function runtests_dispatch_mono(selected, variants::AbstractDict;
                                exclude = nothing, allow_overlaps::Bool = true, kwargs...)
    return runtests_dispatch_mono(nothing, selected, variants; exclude, allow_overlaps, kwargs...)
end

function runtests_dispatch_mono(root::Union{Nothing, AbstractString, Module}, selected, variants::AbstractDict;
                                exclude = nothing, allow_overlaps::Bool = true, kwargs...)
    isempty(variants) && throw(ArgumentError("`runtests_dispatch_mono`: `variants` must not be empty"))
    haskey(kwargs, :config) && throw(ArgumentError(
        "`runtests_dispatch_mono`: `config` is not supported (a combined run reads each package's own file)"
    ))
    for k in keys(kwargs)
        k in DISPATCH_MONO_SELECTION_KEYS && throw(ArgumentError(
            "`runtests_dispatch_mono`: selection keyword `$(k)` must be declared inside `variants`, " *
            "not passed as a top-level argument"
        ))
    end
    top_opts = kwargs_dict(kwargs)
    validate_run_kwargs(top_opts; mono = true, allow_call_keys = true, prefix = "`runtests_dispatch_mono`: ")
    if !haskey(variants, selected)
        supported = sort_by!(collect(keys(variants)), string)
        throw(ArgumentError(
            "`runtests_dispatch_mono`: unknown variant $(repr(selected)); supported variants are " *
            join(repr.(supported), ", ")
        ))
    end

    start_dir = root === nothing ? nothing : root isa Module ? _pkgdir(root) : abspath(String(root))
    workspace, _ = monorepo_workspace(start_dir)
    ps = find_participants(workspace)
    n = length(ps)

    ordered_keys = sort_by!(collect(keys(variants)), string)
    specs = Dict{Any, DispatchSpec}(
        k => parse_dispatch_spec("variant $(repr(k))", variants[k], workspace) for k in ordered_keys
    )
    excludes = parse_dispatch_excludes(exclude, workspace)
    for k in ordered_keys
        validate_dispatch_spec_kwargs("runtests_dispatch_mono", "variant $(repr(k))", specs[k].kwargs;
                                      mono = true, is_exclude = false)
    end
    for (i, s) in enumerate(excludes)
        label = length(excludes) == 1 ? "`exclude`" : "`exclude[$i]`"
        validate_dispatch_spec_kwargs("runtests_dispatch_mono", label, s.kwargs;
                                      mono = true, is_exclude = true)
    end
    validate_run_kwargs(merge(top_opts, kwargs_dict(specs[selected].kwargs));
                        mono = true, allow_call_keys = true, prefix = "`runtests_dispatch_mono`: ")

    configs = [config_toml(joinpath(ps.root[k], "test"), nothing) for k in 1:n]
    pkg_groups = [read_groups(path, toml) for (path, toml) in configs]
    config_paths = String[path for (path, _) in configs]

    naming = naming_root(workspace)
    all_items = RawItem[]
    errors = ScanError[]
    env_names = String[]
    for k in 1:n
        testdir = joinpath(ps.root[k], "test")
        files, strays, templates, environments = walk_test_dir(testdir)
        append!(env_names, rel_slash(dir, naming) for dir in environments)
        setups = setup_modules(testdir)
        its = try
            scan(files, Filter(), setups; strays, templates, expansions = true, environments)
        catch e
            e isa ScanFailure || rethrow()
            append!(errors, e.errors)
            continue
        end
        append!(all_items, with_package(it, k) for it in its)
    end
    isempty(errors) || throw(ScanFailure(sort_by!(errors, e -> (e.file, e.line))))
    isempty(all_items) && throw(NoTestsError("no test items found in the workspace at $(workspace)"))

    known_envs = unique!(env_names)
    preds = Pair{Any, Function}[
        k => dispatch_mono_predicate("variant $(repr(k))", specs[k], workspace, ps, pkg_groups, config_paths, known_envs, naming)
        for k in ordered_keys
    ]
    ex_preds = Function[
        dispatch_mono_predicate("`exclude`", s, workspace, ps, pkg_groups, config_paths, known_envs, naming)
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
            println(io, "`runtests_dispatch_mono`: ", plural(length(uncovered), "test item"),
                    " not covered by any variant or `exclude`:")
            for it in first(uncovered, 20)
                println(io, "  ", ps.name[it.package], " ", repr(it.name), " at ",
                        relpath_or_path(it.file, workspace), ":", it.line)
            end
            length(uncovered) > 20 && println(io, "  … and ", length(uncovered) - 20, " more")
        end))
    end
    if !isempty(overlaps)
        throw(ConfigError(sprint() do io
            println(io, "`runtests_dispatch_mono`: ", plural(length(overlaps), "test item"),
                    " matched by multiple variants (`allow_overlaps = false`):")
            for (it, hits) in first(overlaps, 20)
                println(io, "  ", ps.name[it.package], " ", repr(it.name), " (", join(hits, ", "), ") at ",
                        relpath_or_path(it.file, workspace), ":", it.line)
            end
            length(overlaps) > 20 && println(io, "  … and ", length(overlaps) - 20, " more")
        end))
    end

    chosen = specs[selected]
    merged = merge(NamedTuple(kwargs), chosen.kwargs)
    if !haskey(merged, :group)
        merged = merge(merged, (; group = ALL_GROUP))
    end
    call_args = isempty(chosen.paths) ? (workspace,) : Tuple(chosen.paths)
    return runtests_mono(call_args...; merged...)
end
