# Where code runs, as the syntax reference documents it: the process, the module, the
# names in scope and the working directory of each piece of a suite's code, a
# profile's `init` and `test_end`, an item's `skip` and body, and a failure producer.
# A fixture whose code writes down what it sees runs in each way a suite runs: in the
# calling process (`workers = 0`), on workers, under `Pkg.test`, and in a combined run,
# in a member package and in the root. Each run has a sandboxed item, an item of a
# named profile and an item of an environment directory too, which get workers of
# their own whatever the run's mode.

using Runtests.Private: PASSED, FAILED, SKIPPED

# The source of package `name`. Its `note` writes what the code at `tag` sees, as
# tab-separated `key=value` facts, to a file of its own in the directory `out`: pieces
# in several processes note at the same time.
note_source(name, out) = """
    module $name
    const NOTES = Threads.Atomic{Int}(0)
    function note(tag, m::Module; facts...)
        line = sprint() do io
            print(io, tag, "\\tmodule=", m, "\\tparent=", parentmodule(m), "\\tpwd=", pwd(), "\\tpid=", getpid())
            for (k, v) in pairs(facts)
                print(io, '\\t', k, '=', v)
            end
        end
        write(joinpath($(repr(out)), string(getpid(), "-$name-", Threads.atomic_add!(NOTES, 1))), line)
    end
    end
    """

# Code that notes as `note` does, written out: a profile's hooks have no package of
# the suite they can count on, a shared one in a combined run least of all. `facts` is
# more of the line, as code.
const INLINE_NOTE = raw"""write(joinpath(OUT, string(getpid(), "-", hash("TAG"), "-", time_ns())), string("TAG\tmodule=", @__MODULE__, "\tparent=", parentmodule(@__MODULE__), "\tpwd=", pwd(), "\tpid=", getpid()FACTS))"""
inline_note(tag, out, facts = "") = replace(INLINE_NOTE, "TAG" => tag, "FACTS" => facts, "OUT" => repr(out))

# The profiles of package `name`: the default one, shared with the members of a
# workspace when `shared`, and `named`. Each `init` imports a test dependency, `Test`.
hooks_config(name, out; shared = false) = """
    [profiles.default]
    $(shared ? "monorepo_default = true" : "")
    init = 'using Test; global WHERE_INIT = 1; $(inline_note("$name:init default", out))'
    test_end = '$(inline_note("$name:test_end", out, raw""", "\titem_global=", isdefined(@__MODULE__, :item_global), "\tinit=", isdefined(@__MODULE__, :WHERE_INIT), "\ttest=", isdefined(@__MODULE__, :Test)"""))'

    [profiles.named]
    init = 'using Test; global WHERE_INIT = 1; $(inline_note("$name:init named", out))'
    """

# First in its file, so that it runs before the others on its process: the directory it
# changes to must not be where any later piece runs.
items_source(name) = """
    @testitem "moves away" begin
        cd(mktempdir())
        @test true
    end

    @testitem "plain" skip=(SKIP_DEF = 1; $name.note("$name:skip", @__MODULE__; draw = rand(), test = isdefined(@__MODULE__, :Test), package = isdefined(@__MODULE__, :$name)); println("printed by skip"); false) begin
        item_global = 1
        $name.note("$name:body plain", @__MODULE__; draw = rand(), dir = @__DIR__,
                   init = isdefined(@__MODULE__, :WHERE_INIT), main_init = isdefined(Main, :WHERE_INIT),
                   skip_def = isdefined(@__MODULE__, :SKIP_DEF), test = isdefined(@__MODULE__, :Test),
                   package = isdefined(@__MODULE__, :$name))
        @test true
    end

    @testitem "fails" begin
        value = 7
        Main.Runtests.on_failure() do dir
            $name.note("$name:producer", @__MODULE__; value = value)
        end
        value = 8
        @test false
    end

    @testitem "sandboxed" sandbox=true begin
        $name.note("$name:body sandboxed", @__MODULE__; dir = @__DIR__)
        @test true
    end

    @testitem "named" profile=:named begin
        $name.note("$name:body named", @__MODULE__; init = isdefined(@__MODULE__, :WHERE_INIT),
                   main_init = isdefined(Main, :WHERE_INIT))
        @test true
    end

    @testitem "skipped" skip=true begin
        @test false
    end
    """

env_items(name) = """
    @testitem "in an environment" begin
        $name.note("$name:body env", @__MODULE__; dir = @__DIR__)
        @test true
    end
    """

# The files of package `name`, which notes into `out`, under its directory.
where_files(name, out; shared = false) = [
    "src/$name.jl" => note_source(name, out),
    "test/TestItems.toml" => hooks_config(name, out; shared),
    "test/where_test.jl" => items_source(name),
    "test/envdir/Project.toml" => "[deps]\n",
    "test/envdir/env_test.jl" => env_items(name),
]

const WHERE_STATES = Dict("moves away" => PASSED, "plain" => PASSED, "fails" => FAILED, "sandboxed" => PASSED,
                          "named" => PASSED, "in an environment" => PASSED, "skipped" => SKIPPED)

# How many times the default profile's `test_end` runs for one package: after each
# attempt at an item of that profile that was not skipped, `named` having none.
const WHERE_TEST_ENDS = 5

# What the code wrote down, by tag: one `Dict` of facts for each time it ran.
function notes(out)
    seen = Dict{String, Vector{Dict{String, String}}}()
    for file in readdir(out; join = true)
        tag, facts... = split(read(file, String), '\t')
        push!(get!(seen, String(tag), Dict{String, String}[]),
              Dict(String(k) => String(v) for (k, v) in (split(f, '='; limit = 2) for f in facts)))
    end
    return seen
end

same(a, b) = ispath(a) && ispath(b) && samefile(a, b)
child_of_main(n) = n["parent"] == "Main" && startswith(n["module"], "Main.")
here(n) = n["pid"] == string(getpid())

# What holds in every mode, for package `name` with root `root`: each piece in its
# module, with the names the reference says it has, and `skip` and the body drawing
# the same first number from the item's seed. `hooks` is the package whose default
# profile the items run under: their own, or the workspace root that shares it.
function check_scopes(seen, name, root; hooks = name)
    skip, body = only(seen["$name:skip"]), only(seen["$name:body plain"])
    @test startswith(skip["module"], "Main.skip_") && child_of_main(skip)
    @test skip["test"] == "true" && skip["package"] == "true"
    @test child_of_main(body) && body["module"] != skip["module"]
    @test body["test"] == "true" && body["package"] == "true"
    @test same(body["dir"], joinpath(root, "test"))
    # Neither `skip` nor `init` leaves a name in the body's scope; `init`'s is in `Main`.
    @test body["skip_def"] == "false" && body["init"] == "false" && body["main_init"] == "true"
    @test skip["draw"] == body["draw"]
    named = only(seen["$name:body named"])
    @test named["init"] == "false" && named["main_init"] == "true"
    for t in seen["$hooks:test_end"]
        @test occursin("test_end", t["module"]) && child_of_main(t)
        @test t["item_global"] == "false" && t["init"] == "false" && t["test"] == "true"
    end
    # A producer is a closure of its item: the item's module, and the value as it is
    # when the producer runs.
    producer = only(seen["$name:producer"])
    @test occursin("fails", producer["module"]) && child_of_main(producer)
    @test producer["value"] == "8"
    @test same(only(seen["$name:body sandboxed"])["dir"], joinpath(root, "test"))
    @test same(only(seen["$name:body env"])["dir"], joinpath(root, "test", "envdir"))
    @test all(n -> n["module"] == "Main", seen["$hooks:init default"])
    @test all(n -> n["module"] == "Main", seen["$name:init named"])
end

# What `skip` printed, in the log of item "plain" of `package` (any package for `nothing`).
function skip_logged(run, p, package = nothing)
    i = findfirst(j -> p.items.name[j] == "plain" &&
                       (package === nothing || p.packages.name[p.items.package[j]] == package), eachindex(p.items.name))
    log = Runtests.Private.item_log(run, i, 1)
    return isfile(log) && occursin("printed by skip", read(log, String))
end

@testset "where code runs" begin
    @testset "on workers, every piece runs in the root of the package" begin
        out = mktempdir()
        pkg = write_package(mktempdir(), "WhereOnWorkers", where_files("WhereOnWorkers", out))
        elsewhere = mktempdir()
        with_runstate_dir() do _
            (states, run, p), _ = cd(() -> capture_run(() -> run_states(pkg; workers = 1, logs = :issues, monitor = false)),
                                     elsewhere)
            @test states == WHERE_STATES
            seen = notes(out)
            check_scopes(seen, "WhereOnWorkers", pkg)
            @test length(seen["WhereOnWorkers:test_end"]) == WHERE_TEST_ENDS
            for ns in values(seen), n in ns
                @test !here(n)
                @test same(n["pwd"], pkg)
            end
            @test skip_logged(run, p)
        end
    end

    @testset "under workers = 0, ordinary items and the default profile's init run here, in the root of the package" begin
        out = mktempdir()
        pkg = write_package(mktempdir(), "WhereHere", where_files("WhereHere", out))
        elsewhere = mktempdir()
        # A run state directory relative to the caller's directory, which the items leave:
        # their logs still land in it.
        (states, run, p), output = cd(elsewhere) do
            withenv("RUNTESTS_RUNSTATE_DIR" => "runs") do
                capture_run(() -> run_states(pkg; workers = 0, logs = :issues, monitor = false))
            end
        end
        @test states == WHERE_STATES
        # The run says so, as it evaluates `init` in this process.
        @test occursin("`init` expression is evaluated in this process", output)
        seen = notes(out)
        check_scopes(seen, "WhereHere", pkg)
        @test length(seen["WhereHere:test_end"]) == WHERE_TEST_ENDS
        # Every piece in the root of the package, in this process or on a worker of its own.
        for ns in values(seen), n in ns
            @test same(n["pwd"], pkg)
        end
        # This process: `skip`, the body, `test_end` and the producer of the ordinary
        # items, and the default profile's `init`, once, in this process's `Main`.
        for tag in ("skip", "body plain", "producer")
            @test here(only(seen["WhereHere:$tag"]))
        end
        @test count(here, seen["WhereHere:init default"]) == 1
        @test count(here, seen["WhereHere:test_end"]) == 3
        # A worker of its own: the sandboxed item, the item of the named profile and the
        # item of the environment directory, with the `init` and `test_end` of their profiles.
        for tag in ("body sandboxed", "body named", "body env", "init named")
            @test !here(only(seen["WhereHere:$tag"]))
        end
        @test same(dirname(Runtests.Private.rundata_dir(run.runstate.path)), joinpath(elsewhere, "runs"))
        @test skip_logged(run, p)
    end

    @testset "under Pkg.test, which starts in test/, items in this process run in the root of the package" begin
        out = mktempdir()
        pkg = write_package(mktempdir(), "WhereUnderPkg",
                            [where_files("WhereUnderPkg", out); "test/runtests.jl" => "using Runtests\nRuntests.runtests()\n"])
        with_runtests_dep!(pkg, ["."])
        script = joinpath(mktempdir(), "pkgtest.jl")
        write(script, "using Pkg\nPkg.activate($(repr(pkg)); io = devnull)\nPkg.test(\"WhereUnderPkg\")\n")
        log = joinpath(mktempdir(), "pkgtest.log")
        cmd = addenv(`$(Base.julia_cmd()) --startup-file=no $script`, "RUNTESTS_WORKERS" => "0",
                     "RUNTESTS_RUNSTATE_DIR" => mktempdir(), "JULIA_LOAD_PATH" => nothing)
        # The item that fails on purpose fails the tests.
        @test !success(pipeline(ignorestatus(cmd); stdout = log, stderr = log))
        seen = notes(out)
        isempty(seen) && echo_captured(read(log, String))
        check_scopes(seen, "WhereUnderPkg", pkg)
        @test length(seen["WhereUnderPkg:test_end"]) == WHERE_TEST_ENDS
        for ns in values(seen), n in ns
            @test same(n["pwd"], pkg)
        end
        # The process that `Pkg.test` started runs the ordinary items and the default
        # profile's `init`; the others get workers.
        inproc = only(seen["WhereUnderPkg:body plain"])["pid"]
        @test count(n -> n["pid"] == inproc, seen["WhereUnderPkg:init default"]) == 1
        for tag in ("skip", "producer")
            @test only(seen["WhereUnderPkg:$tag"])["pid"] == inproc
        end
        for tag in ("body sandboxed", "body named", "body env", "init named")
            @test only(seen["WhereUnderPkg:$tag"])["pid"] != inproc
        end
    end

    if VERSION >= v"1.12"
        @testset "in a combined run, each item runs in the root of its package, and a shared init in the workspace root" begin
            out = mktempdir()
            # The root shares its default profile; A declares only `named`, its own.
            a_files = filter(f -> first(f) != "test/TestItems.toml", where_files("A", out))
            push!(a_files, "test/TestItems.toml" => """
                [profiles.named]
                init = 'using Test; global WHERE_INIT = 1; $(inline_note("A:init named", out))'
                """)
            ws = e2e_workspace("A" => a_files; root = where_files("Root", out; shared = true))
            a = joinpath(ws, "lib", "A")
            with_runstate_dir() do _
                (states, run, p), _ = capture_run(() -> run_mono(ws; workers = 2, logs = :issues, monitor = false))
                @test states == Dict((pkg, item) => s for pkg in ("Root", "A") for (item, s) in WHERE_STATES)
                seen = notes(out)
                # A's default profile is the root's, so its hooks note as the root's.
                check_scopes(seen, "Root", ws)
                check_scopes(seen, "A", a; hooks = "Root")
                for name in ("Root", "A")
                    root = name == "Root" ? ws : a
                    for tag in ("skip", "body plain", "producer", "body sandboxed", "body named", "body env")
                        n = only(seen["$name:$tag"])
                        @test !here(n) && same(n["pwd"], root)
                    end
                    @test same(only(seen["$name:body plain"])["dir"], joinpath(root, "test"))
                    @test only(seen["$name:skip"])["draw"] == only(seen["$name:body plain"])["draw"]
                end
                # The shared `init` runs in the workspace root, on every worker of the
                # default profile, A's items' too; a package's own profile, in its root.
                @test all(n -> same(n["pwd"], ws), seen["Root:init default"])
                @test same(only(seen["A:init named"])["pwd"], a)
                @test same(only(seen["Root:init named"])["pwd"], ws)
                # The shared `test_end` runs in the root of each item's package.
                ends = seen["Root:test_end"]
                @test length(ends) == 2 * WHERE_TEST_ENDS
                @test any(n -> same(n["pwd"], a), ends) && any(n -> same(n["pwd"], ws), ends)
                @test all(n -> occursin("test_end", n["module"]) && n["item_global"] == "false", ends)
                @test skip_logged(run, p, "A") && skip_logged(run, p, "Root")
            end
        end
    end
end
