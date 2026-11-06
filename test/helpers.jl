# Shared machinery for the tests that run a whole suite: building a throwaway
# package, running it, and reading back what happened and what was printed.

using Runtests.Private: prepare, execute, exclusively, report, nitems, prepare_mono, Target
using Runtests: RuntestsWorkers
using TOML: TOML

# Fixture packages are written to a tempdir rather than checked in when their
# content is the thing under test: a profile, a broken layout, an item that has to
# crash in a particular place. Each needs a UUID of its own, because they are all
# resolved into environments in the same session.
const PKG_SERIAL = Ref(200)

function next_uuid()
    PKG_SERIAL[] += 1
    return string("1a2b3c4d-0000-4000-8000-", lpad(PKG_SERIAL[], 12, '0'))
end

# The record of run `stem` in the run state directory `dir`, as a run writes it: in a
# directory of the run's own.
record_in(dir::AbstractString, stem::AbstractString) = joinpath(dir, stem * ".rundata", "run.runstate")

# The records in the run state directory `dir`, oldest first.
records_in(dir::AbstractString) =
    sort!(filter!(isfile, [joinpath(dir, d, "run.runstate") for d in readdir(dir) if endswith(d, ".rundata")]))

"""
    make_pkg(name, "test/a_test.jl" => content, ...) -> dir

A package directory holding `name`, plus the given files written relative to it.
"""
function make_pkg(name::AbstractString, files::Pair{<:AbstractString,<:AbstractString}...)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"),
          "name = $(repr(name))\nuuid = $(repr(next_uuid()))\nversion = \"0.1.0\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", name * ".jl"), "module $name\nend\n")
    mkpath(joinpath(dir, "test"))
    for (rel, content) in files
        path = joinpath(dir, rel)
        mkpath(dirname(path))
        write(path, content)
    end
    return dir
end

# A package `name` in `dir`: its source, a test project that depends on it, on Test
# and on `deps`, and `files`, relative to `dir`.
function write_package(dir::AbstractString, name::AbstractString, files; uuid = next_uuid(), test_project = true,
                       deps = String[])
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Project.toml"), "name = $(repr(name))\nuuid = $(repr(uuid))\nversion = \"0.1.0\"\n")
    write(joinpath(dir, "src", name * ".jl"), "module $name\nend\n")
    mkpath(joinpath(dir, "test"))
    test_project && write(joinpath(dir, "test", "Project.toml"),
        "[deps]\n$name = $(repr(uuid))\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n" *
        join("$d = $(repr(next_uuid()))\n" for d in deps) * "\n[sources]\n$name = {path = \"..\"}\n")
    for (rel, content) in files
        path = joinpath(dir, rel)
        mkpath(dirname(path))
        write(path, content)
    end
    return dir
end

toml_list(v) = string("[", join(repr.(v), ", "), "]")

"""
    make_workspace(packages...; root, layout, outside, members) -> workspace root

A workspace in a fresh directory. Each of `packages`, a name and its files, is a
package under `lib/`. The root is the package `Root` with `root` as its files, or no
package when `root === nothing`. With `layout = :flat`, the root's `[workspace]`
lists each package and its test project; with `:nested`, it lists each package, and
the package's own `[workspace]` lists its test project. A package in `outside` keeps
its test project out of the workspace. `members` are more directories to list.
"""
function make_workspace(packages::Pair{String}...; root = (), layout = :flat, outside = String[], members = String[],
                        deps = Dict{String, Vector{String}}())
    ws = realpath(mktempdir())
    listed = String[]
    for (name, files) in packages
        dir = write_package(joinpath(ws, "lib", name), name, files; deps = get(deps, name, String[]))
        push!(listed, "lib/$name")
        name in outside && continue
        if layout === :flat
            push!(listed, "lib/$name/test")
        else
            open(io -> print(io, "\n[workspace]\nprojects = [\"test\"]\n"), joinpath(dir, "Project.toml"), "a")
        end
    end
    if root === nothing
        write(joinpath(ws, "Project.toml"), "")
    else
        write_package(ws, "Root", root)
        push!(listed, "test")
    end
    append!(listed, members)
    open(io -> print(io, "\n[workspace]\nprojects = $(toml_list(listed))\n"), joinpath(ws, "Project.toml"), "a")
    return ws
end

# Runtests in each package's test project, by path, as a workspace that runs
# `runtests_mono` has it; `"."` is the root package's.
function with_runtests_dep!(ws, names)
    for name in names
        path = joinpath(ws, name == "." ? "" : joinpath("lib", name), "test", "Project.toml")
        t = TOML.parsefile(path)
        t["deps"]["Runtests"] = "632efd68-cd41-4e05-bd25-b86dc2150078"
        get!(Dict{String, Any}, t, "sources")["Runtests"] = Dict("path" => pkgdir(Runtests))
        open(io -> TOML.print(io, t), path, "w")
    end
    return ws
end

# A workspace that runs `runtests_mono`: `make_workspace`'s, with Runtests in every
# test project, and the packages in `isolated` listed as isolated.
function e2e_workspace(packages::Pair{String}...; isolated = String[], root = nothing, kwargs...)
    ws = make_workspace(packages...; root, kwargs...)
    with_runtests_dep!(ws, [collect(String, first.(packages)); root === nothing ? String[] : ["."]])
    mkpath(joinpath(ws, "test"))
    isempty(isolated) || open(io -> print(io, "\n[monorepo]\nisolated = ", toml_list(isolated), "\n"),
                              joinpath(ws, "test", "TestItems.toml"), "a")
    return ws
end

# A combined run of the workspace at `ws`: each item's state by package and name, the
# run, and the plan.
function run_mono(ws; on_item = nothing, kwargs...)
    return exclusively() do
        r = prepare_mono((ws,); announce = false, kwargs...)
        p = r.plan
        run = execute(p, Target(p.root, joinpath(p.root, "Project.toml"), joinpath(p.root, "test"), String[], Int32(0));
                      on_item)
        try
            states = Dict((p.packages.name[p.items.package[i]], p.items.name[i]) => run.statuses.state[i] for i in 1:nitems(p))
            return states, run, p
        finally
            rm(run.scratch; force = true, recursive = true)
        end
    end
end

# A `--check-bounds` setting other than this process's, for a profile whose julia
# flags must differ from the ones the workers inherit. The suite does not always
# run with the default: `Pkg.test` on Julia 1.12 passes `--check-bounds=yes`, and
# later versions pass on the caller's setting. `value` is what
# `Base.JLOptions().check_bounds` reads under it.
const OTHER_BOUNDS = Base.JLOptions().check_bounds == 1 ?
    (arg = "--check-bounds=no", value = 2) : (arg = "--check-bounds=yes", value = 1)

# `Runtests.activate(pkg)` for the length of `f`, leaving the session as it found it:
# activating changes the active project and LOAD_PATH, and a test that leaked
# either would take the rest of the file with it.
function with_activated(f, pkg)
    project, load_path = Base.active_project(), copy(LOAD_PATH)
    try
        f(Runtests.activate(pkg))
    finally
        Runtests.is_activated() && Runtests.deactivate()
        Base.set_active_project(project)
        copy!(LOAD_PATH, load_path)
    end
end

# Run a suite and hand back the per-item states by name. Never throws for a
# failing test item: the point is to assert on what was recorded.
function run_states(pkg; kwargs...)
    return exclusively() do
        p, target = prepare((pkg,); kwargs...)
        run = execute(p, target)
        try
            states = Dict(p.items.name[i] => run.statuses.state[i] for i in 1:nitems(p))
            return states, run, p
        finally
            rm(run.scratch; force=true, recursive=true)
        end
    end
end

"""
    capture_run(f) -> (value, output)

Everything the run printed, captured whole. A run writes through one stream,
relayed worker lines included, so redirecting it here catches all of it — which
is the only way to assert on output that a worker process produced.
"""
function capture_run(f)
    path, io = mktemp()
    value = try
        redirect_stdout(io) do
            f()
        end
    finally
        close(io)
    end
    output = read(path, String)
    rm(path; force=true)
    echo_captured(output)
    return value, output
end

# The runner shows a child's output only when its file fails, so there each
# captured output is echoed: an assertion about it fails next to what it read.
function echo_captured(output::AbstractString)
    get(ENV, "RUNTESTS_TEST_ECHO", "") == "1" || return nothing
    ts = Test.get_testset()
    println(stdout, "┄┄┄┄ output captured in ", repr(ts isa Test.DefaultTestSet ? ts.description : "?"), " ┄┄┄┄")
    print(stdout, output)
    endswith(output, '\n') || println(stdout)
    println(stdout, "┄┄┄┄ end of captured output ┄┄┄┄")
    return nothing
end

# Fixtures that have to know whether they have run before write marker files; keep
# them out of a shared tempdir so a test can tell "this ran" from "this ran in
# some earlier test".
function with_marker_dir(f)
    dir = mktempdir()
    try
        withenv("RUNTESTS_FAULTY_DIR" => dir) do
            f(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

marker_dir() = ENV["RUNTESTS_FAULTY_DIR"]

# How many times a fixture has reached a marker, and one more.
function bump_marker(dir::AbstractString, name::AbstractString)
    path = joinpath(dir, name)
    n = isfile(path) ? parse(Int, read(path, String)) : 0
    write(path, string(n + 1))
    return n
end

live_worker_processes() = @lock RuntestsWorkers.LIVE_LOCK count(Base.process_running, RuntestsWorkers.LIVE_PROCESSES)
live_worker_pids() = Set(RuntestsWorkers.live_worker_pids())

# Whether a pid belongs to a process that is still there. Signal 0 checks for one
# without sending anything. Not on Windows, where `kill` terminates the process.
process_alive(pid::Integer) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

# Asked of the operating system rather than of Runtests' own bookkeeping: none of
# `pids` is still running. A worker takes a moment to die after the signal reaches it.
function all_gone(pids)
    deadline = time() + 10
    while time() < deadline && any(process_alive, pids)
        sleep(0.2)
    end
    return !any(process_alive, pids)
end

# Run states live under the depot by default, keyed by project. A test that reads
# one back, or that must not see an earlier run's history, gets a directory of
# its own.
function with_runstate_dir(f)
    dir = mktempdir()
    try
        withenv("RUNTESTS_RUNSTATE_DIR" => dir) do
            f(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

# An item that records that it ran, in which process and when, so a test can
# assert what ran, in what order, where, and how many times.
#
# One file per *run* of the item rather than one shared file: items run at the
# same time in different processes, and two of them appending to one file is a
# race that shows up as a line quietly missing. The name is a timestamp and a pid,
# so a retry of the same item leaves a record of its own.
function journal_item(name::AbstractString; opts::AbstractString="", body::AbstractString="@test true")
    return """
    @testitem $(repr(name)) $opts begin
        let dir = ENV["RUNTESTS_JOURNAL"], now = time()
            open(joinpath(dir, string(time_ns(), "-", getpid())), "w") do io
                println(io, $(repr(name)), "\\t", getpid(), "\\t", now)
            end
        end
        $body
    end
    """
end

"""
    journal(dir) -> Vector{@NamedTuple{name::String, pid::Int}}

What the journalled items recorded, in the order they ran, one entry per run.

Ordered by the time each item wrote its record. Items in one process run one
after another, so that order is real; between processes there is no order to
have, and no test asserts one.
"""
function journal(dir::AbstractString)
    isdir(dir) || return NamedTuple{(:name, :pid), Tuple{String, Int}}[]
    rows = NamedTuple{(:name, :pid, :t), Tuple{String, Int, Float64}}[]
    for file in readdir(dir; join=true)
        parts = split(strip(read(file, String)), '\t')
        length(parts) == 3 || continue
        push!(rows, (name=String(parts[1]), pid=parse(Int, parts[2]), t=parse(Float64, parts[3])))
    end
    sort!(rows; by=r -> r.t)
    return [(name=r.name, pid=r.pid) for r in rows]
end

function with_journal(f)
    dir = mktempdir()
    try
        withenv("RUNTESTS_JOURNAL" => dir) do
            f(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

"""
    started_elsewhere(names; seconds=60) -> String

Code for a journalled item's body: hold the worker until one of the items `names`
has started in another process. A test about work moving between slots holds the
slot the work should move away from, so the move happens on every run rather than
only when one worker happens to start before the other.

When the move never comes, the first item to give up leaves a marker that
releases the rest, so a broken run costs `seconds` once rather than once per item.
"""
started_elsewhere(names; seconds::Real=60) = """
    let dir = ENV["RUNTESTS_JOURNAL"], names = $(repr(collect(String, names))), deadline = time() + $seconds
        gave_up = joinpath(dir, "gave-up")
        moved() = any(readdir(dir; join=true)) do f
            r = split(strip(read(f, String)), '\\t')
            length(r) == 3 && r[1] in names && parse(Int, r[2]) != getpid()
        end
        while !isfile(gave_up) && !moved()
            time() > deadline && (touch(gave_up); break)
            sleep(0.05)
        end
    end
    """

"""
    plain_julia(args...) -> Cmd

A julia command whose output carries no colour.

`Base.julia_cmd()` reproduces this process's flags, `--color` among them, so a
child of a suite run in a terminal writes SGR codes into the log it is spawned to
produce. A test that reads a child's output as text builds the child with this;
the trailing `--color=no` is what decides, because julia takes the last `--color`
on the line.
"""
plain_julia(args...) = `$(Base.julia_cmd()) --startup-file=no --color=no $args`
