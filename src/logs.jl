# Reading captured item logs from recorded runs (including `logs = :quiet` runs).

function resolve_logs_run(run)
    run isa RunStateRecord && return run
    if run === nothing
        root = target_from_dir(default_search_dir()).root
        return latest_run_record(root)
    elseif run isa Module
        return latest_run_record(_pkgdir(run))
    elseif run isa AbstractString
        rs = read_run_state(run; full = false)
        rs === nothing || return rs
        if isdir(run)
            proj = find_project(abspath(run))
            proj === nothing || return latest_run_record(dirname(proj))
        end
        throw(ConfigError("could not read a run state from $(run)"))
    end
    throw(ArgumentError(
        "`Runtests.logs` expects a RunStateRecord, a run state or package path, a Module, or nothing; got $(typeof(run))"
    ))
end

function latest_run_record(root::AbstractString)
    runs = project_runs(root)
    isempty(runs) && throw(ConfigError("no recorded run state found for $(root)"))
    return last(runs)[2]
end

"""
    logs([run]; name = nothing, failed = false, attempt = nothing, io = stdout) -> Nothing

Print captured item logs from any recorded run (including `logs = :quiet` runs, which
keep every non-empty item log beside the run state without printing it during the run).

`run` may be omitted (the newest run of the active package), a package directory or
`Module` (its newest run), a `.runstate` file or `.rundata` directory path, or a
`RunStateRecord` returned by [`read_run_state`](@ref).

Keywords:
- `name`: filter items by exact name (`String`), `Regex`, or collection of names.
- `failed::Bool`: when `true`, show only non-passing items (failed, errored, timed out,
  or cancelled; excludes passed and skipped items).
- `attempt::Union{Nothing, Integer}`: show only that attempt number (default: every
  attempt of each matching item that wrote output).
- `io::IO`: output stream (default: `stdout`).
"""
function logs(run = nothing; name = nothing, failed::Bool = false,
              attempt::Union{Nothing, Integer} = nothing, @nospecialize(io::IO = stdout))
    attempt === nothing || attempt >= 1 ||
        throw(ArgumentError("`attempt` must be >= 1, got $(repr(attempt))"))
    buf = IOBuffer()
    ctx = io_context_like(buf, io)
    logs_impl(ctx, run, name, failed, attempt === nothing ? 0 : Int(attempt))
    write(io, take!(buf))
    return nothing
end

function logs_impl(io::IOContext{IOBuffer}, @nospecialize(run), @nospecialize(name),
                   failed::Bool, attempt_i::Int)
    name_filter = name === nothing ? nothing : Filter(; name).name
    rs = resolve_logs_run(run)
    prefix = joinpath(rundata_dir(rs.path), "item_")
    shown = 0
    for (i, it) in enumerate(rs.items)
        matches_name(name_filter, it.name) || continue
        st = i <= length(rs.statuses) ? rs.statuses[i] : nothing
        state = st === nothing ? UNSEEN : st.state
        failed && !is_non_pass(state) && continue
        max_att = st === nothing ? 1 : max(Int(st.attempt), 1)
        atts = attempt_i == 0 ? (1:max_att) : (attempt_i:attempt_i)
        for a in atts
            path = item_log_path(prefix, i, a)
            (isfile(path) && filesize(path) > 0) || continue
            text = trim_blank_lines(open(f -> read(f, String), path, "r"))
            isempty(text) && continue
            title = string(
                repr(it.name), " · ", state,
                (a > 1 || max_att > 1) ? string(" · attempt ", a) : "",
                " · ", it.file, ":", it.line
            )
            color = is_non_pass(state) ? Base.error_color() : Base.info_color()
            print(io, bracket(text, title, "", "", color))
            shown += 1
        end
    end
    if shown == 0
        println(io, label_prefix(io), "no captured logs matched in ", basename(run_location(rs.path)))
    end
    return nothing
end
