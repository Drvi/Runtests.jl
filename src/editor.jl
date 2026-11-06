# The editor protocol: a Runtests process an editor drives over its standard streams.
# Commands arrive on stdin and events leave on stdout, one JSON object per line;
# everything written for people — the run's own lines, `Pkg`, what items print —
# goes to stderr, so nothing but events reaches the stream. What a command holds is
# read in `command!`, and what an event holds is where it is emitted.

const PROTOCOL_VERSION = 3

# An item as the protocol names it: its package and its name, which together tell
# apart the items of a server of several packages.
item_key(package::AbstractString, name::AbstractString) = (; package = String(package), name = String(name))

"""
    EventStream

Where the events go, and what a run's events are tagged with: the `id` of the
command that started it, echoed back so an editor can tell a run's events from a
reply to a later command, and the run itself once `execute` has made it, so that a
run that is stopped can still say what it got through. Every event is written
whole under `lock`, as one line.
"""
mutable struct EventStream
    const io::IO
    const lock::ReentrantLock
    run_id::Any
    run::Any
end
EventStream(io::IO) = EventStream(io, ReentrantLock(), nothing, nothing)

# Set around a run the editor asked for; `execute` gives it to the run it makes.
const EVENTS = ScopedValue{Union{Nothing, EventStream}}(nothing)

function emit(s::EventStream, event::AbstractString; id = nothing, fields...)
    line = sprint() do io
        write(io, "{\"event\":")
        write_json(io, event)
        if id !== nothing
            write(io, ",\"id\":")
            write_json(io, id)
        end
        for (k, v) in fields
            write(io, ',')
            write_json(io, String(k))
            write(io, ':')
            write_json(io, v)
        end
        write(io, "}\n")
    end
    @lock s.lock begin
        write(s.io, line)
        flush(s.io)
    end
    return nothing
end

emit_error(s::EventStream, message::AbstractString; id = nothing, fields...) =
    emit(s, "error"; id, message, fields...)

scan_errors_json(errors) = [(; file = e.file, line = Int(e.line), message = e.msg) for e in errors]

### What a run says as it goes ##############################################

item_json(p::Plan, i::Integer) = (; package = p.packages.name[p.items.package[i]], name = p.items.name[i],
                                    file = p.files[p.items.fileidx[i]], line = Int(p.items.line[i]))

function event_item_started(run, i::ItemIdx, attempt::Integer, slot::Integer, pid::Integer)
    p = run.plan
    emit(run.events, "item_started"; id = run.events.run_id, item_json(p, i)...,
         attempt = Int(attempt), attempts = attempts_for(p, p.items.unit[i]), worker = Int(slot), pid = Int(pid))
    return nothing
end

function event_item_finished(run, i::ItemIdx, state::ItemState, attempt::Integer, slot::Integer, note::AbstractString)
    p = run.plan
    st = run.statuses
    ts = st.testsets[i]
    failures = ts === nothing ? [] : [failure_json(p, r) for r in collect_failures(ts)]
    log = item_logpath(run, i)
    emit(run.events, "item_finished"; id = run.events.run_id, item_json(p, i)...,
         attempt = Int(attempt), attempts = attempts_for(p, p.items.unit[i]), worker = Int(slot),
         pid = Int(st.pid[i]), state = state_name(state), elapsed = st.elapsed[i], compile = st.compile[i],
         note = String(note), log = isfile(log) && filesize(log) > 0 ? log : nothing, failures)
    return nothing
end

state_name(s::ItemState) = lowercase(string(s))

# A failure where `Test` recorded it: in the item's own file when the source is
# relative or missing.
function failure_json(p::Plan, r)
    src = r.source
    file = src.file === nothing ? "" : string(src.file)
    file = isempty(file) ? "" : isabspath(file) ? file : joinpath(p.root, file)
    return (; kind = r isa Test.Fail ? "fail" : "error", message = sprint(show, r), file, line = Int(src.line))
end

### Listing #################################################################

"""
    list_items(root; config = nothing) -> NamedTuple

Every test item of the package at `root`, as the scanner reads it; every problem
that would stop a run: a file that does not parse, a name used twice, a setting
`test/TestItems.toml` does not accept, or `config` when it names another file to
read in its place; and the items that are failing — whose last verdict was not a
pass — which [`runtestsf`](@ref) would run. Items come from the files that parse
even when others do not, so an editor shows what it can beside what is broken. An
item's `end_line` is the line before the next item in its file, or the file's last:
the lines where `runtests("file.jl:line")` picks that item.
"""
function list_items(root::AbstractString; config::Union{Nothing, AbstractString} = nothing)
    target = resolve_target((root,))
    config_file = config === nothing ? joinpath(target.testdir, "TestItems.toml") : abspath(config)
    files, strays, templates, environments = walk_test_dir(target.testdir)
    setups = setup_modules(target.testdir)
    items, errors, _ = scan_files(files, Filter(), setups; strays, templates, environments)
    if !isempty(items)
        # What a run would refuse to start on beyond the files: the settings, the
        # profiles items name, the items `[order]` names.
        try
            plan(items, read_config(target.testdir; config, nunits = length(items)); root = target.root)
        catch e
            e isa ConfigError ? push!(errors, ScanError(config_file, 0, e.msg)) :
                e isa ScanFailure ? append!(errors, e.errors) : rethrow()
        end
    end
    last_lines = Dict(f => countlines(f) for f in unique(it.file for it in items))
    package = something(project_name_of(target.project), "")
    out = map(eachindex(items)) do k
        it = items[k]
        next = k < length(items) && items[k + 1].file == it.file ? items[k + 1].line - 1 : last_lines[it.file]
        (; package, name = it.name, file = it.file, line = Int(it.line), end_line = Int(max(next, it.line)),
            tags = String.(it.tags), setups = String.(it.setups),
            profile = it.profile === DEFAULT_PROFILE ? nothing : String(it.profile),
            sandbox = it.exclusive,
            environment = isempty(it.environment) ? nothing : it.environment,
            chain = it.chain === NO_CHAIN ? nothing : String(it.chain),
            skip = it.skip isa Bool ? it.skip : string(it.skip),
            timeout = it.timeout_s == USE_RUN_DEFAULT ? nothing : Int(it.timeout_s),
            retries = it.retries == USE_RUN_DEFAULT ? nothing : Int(it.retries),
            failfast = it.failfast < 0 ? nothing : it.failfast == 1)
    end
    failed = [item_key(package, n) for n in failing_items(target.root; names = Set(it.name for it in items))]
    return (; root = target.root, testdir = target.testdir,
            packages = [(; name = package, root = target.root, testdir = target.testdir)], items = out,
            errors = scan_errors_json(errors), failed)
end

"""
    list_items_mono(root) -> NamedTuple

[`list_items`](@ref) for the packages of a combined run of the workspace at `root`:
the items of each, with its package, and what would stop a combined run besides
what stops one package's own: setups of one name, and imports that a package's own
test environment cannot load.
"""
function list_items_mono(root::AbstractString)
    ps = find_participants(root)
    items, errors, failed = Any[], Any[], Any[]
    for r in ps.root
        l = list_items(r)
        append!(items, l.items); append!(errors, l.errors); append!(failed, l.failed)
    end
    try
        check_setup_names(ps, [setup_modules(joinpath(r, "test")) for r in ps.root])
    catch e
        e isa ConfigError || rethrow()
        push!(errors, (; file = joinpath(ps.workspace, "Project.toml"), line = 0, message = e.msg))
    end
    append!(errors, scan_errors_json(written_import_problems(ps; all_setups = false)))
    packages = [(; name = ps.name[k], root = ps.root[k], testdir = joinpath(ps.root[k], "test")) for k in eachindex(ps.root)]
    return (; root = ps.workspace, testdir = nothing, packages, items, errors, failed)
end

### The server ##############################################################

# What a run command may set besides its names: the `runtests` keywords that change
# how it runs, or where its output goes, and `group` and `replay`, which select as
# they do for `runtests`.
const RUN_OPTIONS = (
    :workers, :threads, :timeout, :init_timeout, :test_end_timeout, :retries, :failfast,
    :item_failfast, :logs, :verbose, :memory_threshold, :full_stacktraces, :coverage, :seed,
    :group, :replay,
)

mutable struct Session
    const root::String
    const combined::Bool                   # serves the packages of a workspace (`serve_mono`)
    const config::Union{Nothing, String}   # the file read in place of test/TestItems.toml
    const stream::EventStream
    task::Union{Nothing, Task}   # the run in flight, or the last one
    cancelled::Bool              # a cancel that arrived before the run's task started
    # The last run's own temporary directory, kept until the next run: its items' logs
    # when it had no run state to keep them by.
    scratch::String
end

"""
    serve(path = "."; config = nothing, input = stdin, output = stdout)

Drive the test suite of the package at `path` from an editor: read commands from
`input` and write events to `output`, one JSON object per line, until `input` ends
or a `shutdown` command arrives; a run still going is cancelled first. The commands
are `list`, `run`, `cancel` and `shutdown`: each an object naming its `command`, with
an `id` that the events answering it carry, and for `run` the `items` to run, each a
`package` and a `name`, or their `names`, and the `options` to run them with
(`RUN_OPTIONS`). `config` names a file every listing and run of the session reads in
place of `test/TestItems.toml`, relative to the current directory.

Serving over this process's own `stdout` takes it over for the rest of the process:
everything else written there, by the run, by `Pkg` or by C libraries, goes to
`stderr` from then on, so that the stream holds events and nothing else.
"""
function serve(path::AbstractString = "."; config::Union{Nothing, AbstractString} = nothing,
               input::IO = stdin, output::IO = stdout)
    target = resolve_target((path,))
    # Where the session started: a run that changes directory does not move it.
    config = config === nothing ? nothing : abspath(config)
    packages = [(; name = something(project_name_of(target.project), ""), root = target.root)]
    return serving(target.root, false, config, packages, input, output)
end

"""
    serve_mono(root = nothing; input = stdin, output = stdout)

[`serve`](@ref) for the packages of a workspace, as [`runtests_mono`](@ref) runs them:
the listing has the items of every package, each with its package, and a run is a
combined run. A `run` names its items as keys of a `package` and a `name`.
"""
function serve_mono(root::Union{Nothing, AbstractString} = nothing; input::IO = stdin, output::IO = stdout)
    ps = find_participants(root)
    packages = [(; name = ps.name[k], root = ps.root[k]) for k in eachindex(ps.root)]
    return serving(ps.workspace, true, nothing, packages, input, output)
end

function serving(root::String, combined::Bool, config, packages, input::IO, output::IO)
    if output === stdout
        # The events keep a descriptor of their own on what stdout was; stdout itself
        # is pointed at stderr, C level included.
        fd = Libc.dup(RawFD(1))
        output = fdio(reinterpret(Cint, fd), true)
        redirect_stdout(stderr)
    end
    s = Session(root, combined, config, EventStream(output), nothing, false, "")
    emit(s.stream, "hello"; protocol = PROTOCOL_VERSION, runtests = string(pkgversion(@__MODULE__)),
         julia = string(VERSION), pid = getpid(), root, config, combined, packages)
    try
        while !eof(input)
            line = readline(input)
            isempty(strip(line)) && continue
            command!(s, line) || break
        end
    finally
        stop_serving!(s)
    end
    return nothing
end

function stop_serving!(s::Session)
    t = s.task
    if t !== nothing && !istaskdone(t)
        cancel_run!(s, nothing)
        try
            wait(t)
        catch
        end
    end
    isempty(s.scratch) || rm(s.scratch; force = true, recursive = true)
    emit(s.stream, "bye")
    return nothing
end

# One command; `false` when it was the last.
function command!(s::Session, line::AbstractString)
    cmd = try
        read_json(line)
    catch e
        e isa ArgumentError || rethrow()
        emit_error(s.stream, e.msg)
        return true
    end
    if !(cmd isa Dict{String, Any})
        emit_error(s.stream, "a command is a JSON object, got $(json(cmd))")
        return true
    end
    id = get(cmd, "id", nothing)
    name = get(cmd, "command", nothing)
    try
        if name == "list"
            emit(s.stream, "items"; id, (s.combined ? list_items_mono(s.root) : list_items(s.root; s.config))...)
        elseif name == "run"
            start_run!(s, id, cmd)
        elseif name == "cancel"
            cancel_run!(s, id)
        elseif name == "shutdown"
            return false
        else
            emit_error(s.stream, "unknown command $(json(name)); the commands are \"list\", \"run\", \"cancel\" and \"shutdown\""; id)
        end
    catch e
        is_interrupt(e) && rethrow()
        say_failure(s.stream, id, e)
    end
    return true
end

# A command that could not be carried out, with every located problem when there
# were several.
function say_failure(stream::EventStream, id, e)
    if e isa ScanFailure
        emit_error(stream, "the test files cannot be read as a suite"; id, errors = scan_errors_json(e.errors))
    elseif e isa ConfigError || e isa NoTestsError || e isa ArgumentError
        emit_error(stream, e.msg; id)
    else
        emit_error(stream, sprint(showerror, e); id)
    end
    return nothing
end

function start_run!(s::Session, id, cmd::Dict{String, Any})
    if s.task !== nothing && !istaskdone(s.task)
        emit_error(s.stream, "a run is already in progress; cancel it or wait for it to finish"; id)
        return nothing
    end
    names = get(cmd, "names", nothing)
    if names !== nothing && !(names isa Vector{Any} && all(n -> n isa String, names))
        emit_error(s.stream, "`names` is a list of test item names, got $(json(names))"; id)
        return nothing
    end
    keys_ = get(cmd, "items", nothing)
    is_key(k) = k isa Dict{String, Any} && get(k, "package", nothing) isa String && get(k, "name", nothing) isa String
    if keys_ !== nothing && !(keys_ isa Vector{Any} && all(is_key, keys_))
        emit_error(s.stream, "`items` is a list of test items, each an object of a `package` and a `name`, got $(json(keys_))"; id)
        return nothing
    end
    if s.combined && names !== nothing
        emit_error(s.stream, "a server of several packages runs `items`, each a `package` and a `name`, not `names`"; id)
        return nothing
    end
    item_keys = keys_ === nothing ? nothing : Tuple{String, String}[(k["package"], k["name"]) for k in keys_]
    options = get(Dict{String, Any}, cmd, "options")
    if !(options isa Dict{String, Any})
        emit_error(s.stream, "`options` is an object, got $(json(options))"; id)
        return nothing
    end
    kwargs = Pair{Symbol, Any}[]
    for (k, v) in options
        key = Symbol(k)
        if !(key in RUN_OPTIONS)
            emit_error(s.stream, "unknown option $(json(k)); the options are $(join(map(o -> json(String(o)), RUN_OPTIONS), ", "))"; id)
            return nothing
        end
        # A seed as `run_started` gives it, `"0x…"`, since JSON integers stop at 2^63.
        value = key === :logs && v isa String ? Symbol(v) :
            key === :seed && v isa String ? something(tryparse(UInt64, v), v) : v
        push!(kwargs, key => value)
    end
    # The last run's logs were an editor's to read until now.
    isempty(s.scratch) || rm(s.scratch; force = true, recursive = true)
    s.scratch = ""
    claim_process!() || (emit_error(s.stream, BUSY; id); return nothing)
    # From here the process is the run's, released by its task when it ends.
    started = false
    try
        p, target, unknown = s.combined ? prepare_for_editor_mono(s, item_keys, kwargs) :
            prepare_for_editor(s, names, item_keys, kwargs)
        emit(s.stream, "run_started"; id, items = [item_key(p.packages.name[p.items.package[i]], p.items.name[i]) for i in 1:nitems(p)],
             workers = single_process(p) ? 0 : nslots(p), seed = seed_text(p.cfg.seed),
             unknown = [item_key(pkg, n) for (pkg, n) in unknown])
        s.cancelled = false
        s.stream.run_id = id
        s.task = @async run_for_editor(s, id, p, target)
        started = true
    finally
        started || release_process!()
    end
    return nothing
end

# The plan of a run of the one package served: its items of `names`, and of the keys
# of `item_keys` that are its own. The keys asked for that it has no item of are
# returned as unknown.
function prepare_for_editor(s::Session, names, item_keys, kwargs)
    package = something(project_name_of(joinpath(s.root, "Project.toml")), "")
    wanted = names === nothing && item_keys === nothing ? nothing :
        Set{String}([something(names, String[]); [n for (pkg, n) in something(item_keys, Tuple{String, String}[]) if pkg == package]])
    p, target = prepare((s.root,); name = wanted, announce = false, allow_unknown_names = true, s.config, kwargs...)
    suite = Set(p.suite_names)
    unknown = Tuple{String, String}[(package, n) for n in something(names, String[]) if !(n in suite)]
    for (pkg, n) in something(item_keys, Tuple{String, String}[])
        (pkg == package && n in suite) || push!(unknown, (pkg, n))
    end
    return p, target, sort!(unique!(unknown))
end

# The plan of a combined run of the workspace served: every package's items, or those
# of `item_keys`.
function prepare_for_editor_mono(s::Session, item_keys, kwargs)
    r = prepare_mono((s.root,); item_keys, announce = false, kwargs...)
    p = r.plan
    project = something(project_file(p.root), joinpath(p.root, "Project.toml"))
    return p, Target(p.root, project, joinpath(p.root, "test"), String[], Int32(0)), r.unknown
end

function run_for_editor(s::Session, id, p::Plan, target)
    # This task is where a cancel is thrown, from its first moment: `execute` makes
    # it the target too, and puts back what it found here when it is done.
    @atomic RuntestsWorkers.INTERRUPT_TARGET.task = current_task()
    run, ended = nothing, "finished"
    try
        s.cancelled && throw(InterruptException())
        run = with(() -> execute(p, target), EVENTS => s.stream)
        print_conclusion(run)
    catch e
        run = s.stream.run
        ended = is_interrupt(e) ? "cancelled" : e isa RunStalled ? "stalled" : "error"
        ended == "error" && say_failure(s.stream, id, e)
    finally
        @atomic RuntestsWorkers.INTERRUPT_TARGET.task = nothing
        release_process!()
    end
    run === nothing || (s.scratch = run.scratch)
    emit_run_finished(s.stream, id, run, ended)
    s.stream.run, s.stream.run_id = nothing, nothing
    return nothing
end

function emit_run_finished(stream::EventStream, id, run, ended::String)
    if run === nothing
        emit(stream, "run_finished"; id, state = ended == "finished" ? "error" : ended)
        return nothing
    end
    st = run.statuses
    p = run.plan
    state = ended != "finished" ? ended : any(is_non_pass, st.state) ? "failed" : "passed"
    counts = Dict(state_name(k) => count(==(k), st.state) for k in (PASSED, FAILED, ERRORED, TIMEDOUT, SKIPPED, BROKEN_CHAIN, CANCELLED))
    not_run = [item_key(p.packages.name[p.items.package[i]], p.items.name[i]) for i in 1:nitems(p)
               if st.state[i] === UNSEEN || st.state[i] === RUNNING]
    rs = @atomic run.runstate
    # Each package's run state: one, or one for each package of a combined run.
    runstates = rs isa RunStateSet ? [(; package = p.packages.name[k], path = f === nothing ? nothing : f.path)
                                      for (k, f) in enumerate(rs.files)] :
        rs isa RunStateFile ? [(; package = p.packages.name[1], path = rs.path)] : Any[]
    emit(stream, "run_finished"; id, state, counts, not_run, elapsed = time() - run.t0,
         runstate = rs isa RunStateFile ? rs.path : nothing, runstates, logdir = run.logdir)
    return nothing
end

function cancel_run!(s::Session, id)
    t = s.task
    if t === nothing || istaskdone(t)
        emit_error(s.stream, "no run in progress"; id)
        return nothing
    end
    # Thrown into the run's task as Ctrl-C would be, which stops the run and takes
    # its workers with it; a task that has yet to start sees the flag instead.
    RuntestsWorkers.forward_interrupt(InterruptException()) || (s.cancelled = true)
    return nothing
end
