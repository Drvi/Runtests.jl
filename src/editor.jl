# The editor protocol: a YATF process an editor drives over its standard streams.
# Commands arrive on stdin and events leave on stdout, one JSON object per line;
# everything written for people — the run's own lines, `Pkg`, what items print —
# goes to stderr, so nothing but events reaches the stream. What each command and
# event holds is in `docs/editor-protocol.md`.

const PROTOCOL_VERSION = 1

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

item_json(p::Plan, i::Integer) = (; name = p.items.name[i], file = p.files[p.items.fileidx[i]], line = Int(p.items.line[i]))

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
    list_items(root) -> NamedTuple

Every test item of the package at `root`, as the scanner reads it; every problem
that would stop a run: a file that does not parse, a name used twice, a setting
`test/TestItems.toml` does not accept; and the items that are failing — whose last
verdict was not a pass — which [`runtestsf`](@ref) would run. Items come from the files that parse even
when others do not, so an editor shows what it can beside what is broken.
An item's `end_line` is the line before the next item in its file, or the file's
last: the lines where `runtests("file.jl:line")` picks that item.
"""
function list_items(root::AbstractString)
    target = resolve_target((root,))
    files, strays = walk_test_dir(target.testdir)
    setups = setup_modules(target.testdir)
    items, errors, _ = scan_files(files, Filter(), setups; strays)
    config = joinpath(target.testdir, "TestItems.toml")
    if !isempty(items)
        # What a run would refuse to start on beyond the files: the settings, the
        # profiles items name, the items `[order]` names.
        try
            plan(items, read_config(target.testdir; nunits = length(items)); root = target.root)
        catch e
            e isa ConfigError ? push!(errors, ScanError(config, 0, e.msg)) :
                e isa ScanFailure ? append!(errors, e.errors) : rethrow()
        end
    end
    last_lines = Dict(f => countlines(f) for f in unique(it.file for it in items))
    out = map(eachindex(items)) do k
        it = items[k]
        next = k < length(items) && items[k + 1].file == it.file ? items[k + 1].line - 1 : last_lines[it.file]
        (; name = it.name, file = it.file, line = Int(it.line), end_line = Int(max(next, it.line)),
            tags = String.(it.tags), setups = String.(it.setups),
            profile = it.profile === DEFAULT_PROFILE ? nothing : String(it.profile),
            sandbox = it.exclusive || it.profile !== DEFAULT_PROFILE,
            chain = it.chain === NO_CHAIN ? nothing : String(it.chain),
            skip = it.skip isa Bool ? it.skip : string(it.skip),
            timeout = it.timeout_s == USE_RUN_DEFAULT ? nothing : Int(it.timeout_s),
            retries = it.retries == USE_RUN_DEFAULT ? nothing : Int(it.retries),
            failfast = it.failfast < 0 ? nothing : it.failfast == 1)
    end
    failed = failing_items(target.root; names = Set(it.name for it in items))
    return (; root = target.root, testdir = target.testdir, items = out, errors = scan_errors_json(errors), failed)
end

### The server ##############################################################

# What a run command may set, beyond which items: the `runtests` keywords that
# change how it runs rather than what, or where its output goes.
const RUN_OPTIONS = (
    :workers, :threads, :timeout, :init_timeout, :test_end_timeout, :retries, :failfast,
    :item_failfast, :logs, :verbose, :memory_threshold, :full_stacktraces, :coverage, :seed,
)

mutable struct Session
    const root::String
    const stream::EventStream
    task::Union{Nothing, Task}   # the run in flight, or the last one
    cancelled::Bool              # a cancel that arrived before the run's task started
    logdir::String               # the last run's item logs, kept until the next run
end

"""
    serve(path = "."; input = stdin, output = stdout)

Drive the test suite of the package at `path` from an editor: read commands from
`input` and write events to `output`, one JSON object per line, until `input` ends
or a `shutdown` command arrives; a run still going is cancelled first. The commands
are `list`, `run`, `cancel` and `shutdown`; `docs/editor-protocol.md` has them and
the events they answer with.

Serving over this process's own `stdout` takes it over for the rest of the process:
everything else written there, by the run, by `Pkg` or by C libraries, goes to
`stderr` from then on, so that the stream holds events and nothing else.
"""
function serve(path::AbstractString = "."; input::IO = stdin, output::IO = stdout)
    target = resolve_target((path,))
    if output === stdout
        # The events keep a descriptor of their own on what stdout was; stdout itself
        # is pointed at stderr, C level included.
        fd = Libc.dup(RawFD(1))
        output = fdio(reinterpret(Cint, fd), true)
        redirect_stdout(stderr)
    end
    s = Session(target.root, EventStream(output), nothing, false, "")
    emit(s.stream, "hello"; protocol = PROTOCOL_VERSION, yatf = string(pkgversion(@__MODULE__)),
         julia = string(VERSION), pid = getpid(), root = target.root)
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
    isempty(s.logdir) || rm(s.logdir; force = true, recursive = true)
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
            emit(s.stream, "items"; id, list_items(s.root)...)
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
    elseif e isa ConfigError || e isa NoTestsError
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
    options = get(cmd, "options", Dict{String, Any}())
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
    isempty(s.logdir) || rm(s.logdir; force = true, recursive = true)
    s.logdir = ""
    p, target = prepare((s.root,); name = names === nothing ? nothing : Set{String}(names), announce = false, kwargs...)
    unknown = names === nothing ? String[] : sort!(setdiff(Set{String}(names), Set(p.suite_names)) |> collect)
    emit(s.stream, "run_started"; id, items = p.items.name, workers = single_process(p) ? 0 : nslots(p),
         seed = seed_text(p.cfg.seed), unknown)
    s.cancelled = false
    s.stream.run_id = id
    s.task = @async run_for_editor(s, id, p, target)
    return nothing
end

function run_for_editor(s::Session, id, p::Plan, target)
    # This task is where a cancel is thrown, from its first moment: `execute` makes
    # it the target too, and puts back what it found here when it is done.
    @atomic YATFWorkers.INTERRUPT_TARGET.task = current_task()
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
        @atomic YATFWorkers.INTERRUPT_TARGET.task = nothing
    end
    run === nothing || (s.logdir = run.logdir)
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
    names = run.plan.items.name
    state = ended != "finished" ? ended : any(is_non_pass, st.state) ? "failed" : "passed"
    counts = Dict(state_name(k) => count(==(k), st.state) for k in (PASSED, FAILED, ERRORED, TIMEDOUT, SKIPPED, BROKEN_CHAIN, CANCELLED))
    not_run = [names[i] for i in eachindex(names) if st.state[i] === UNSEEN || st.state[i] === RUNNING]
    rs = @atomic run.runstate
    emit(stream, "run_finished"; id, state, counts, not_run, elapsed = time() - run.t0,
         runstate = rs === nothing ? nothing : rs.path, logdir = run.logdir)
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
    YATFWorkers.forward_interrupt(InterruptException()) || (s.cancelled = true)
    return nothing
end
