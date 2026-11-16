# What the packages precompile before a run starts.
#
# `precompile(f, types)` answers `false` when the signature matches no method and
# says nothing else, so a list of them rots silently: the build keeps paying for a
# workload that covers less and less. The build asserts, and this checks the same
# thing from a session that loaded the package out of a cache built earlier.

using Runtests.RuntestsWorkers: precompile_or_throw
using Runtests.Private: PASSED, ConfigError

@testset "precompile coverage" begin
    @testset "every signature the packages list still names a method" begin
        for (f, types) in Runtests.Private.PRECOMPILE_SIGNATURES
            @test precompile(f, types)
        end
        for (f, types) in RuntestsWorkers.PRECOMPILE_SIGNATURES
            @test precompile(f, types)
        end
        @test !isempty(Runtests.Private.PRECOMPILE_SIGNATURES)
        @test !isempty(RuntestsWorkers.PRECOMPILE_SIGNATURES)
    end

    @testset "a signature that names no method is an error, not a shrug" begin
        @test precompile_or_throw(identity, (Int,)) === nothing
        # A method that does not exist.
        @test_throws ErrorException precompile_or_throw(Runtests.Private.nitems, (String,))
        # An abstract argument the compiler declines to specialize for, which is
        # why `with_test_env` is not on the list: it takes a closure. If this ever
        # stops throwing the compiler has got better and the signature belongs on
        # the list, so the failure is the notification.
        @test_throws ErrorException precompile_or_throw(
            Runtests.Private.with_test_env, (Function, Runtests.Private.Target, Any)
        )
    end

    @testset "the run state and the report shapes are covered by the workload" begin
        # These run for real while the package is built rather than being named as
        # signatures, so what this checks is that they are still callable the way
        # the workload calls them.
        dir = mktempdir()
        p = first(Runtests.Private.prepare((fixture("Basic.jl"),); workers=1, monitor=false))
        path = joinpath(dir, "covered.runstate")
        rsf = Runtests.Private.init_run_state(path, p)
        Runtests.Private.write_status!(rsf, 1, Runtests.Private.RUNNING, 1, 1)
        Runtests.Private.write_status!(rsf, 1, Runtests.Private.PASSED, 1, 1; elapsed=0.1, compile=0.05)
        Runtests.Private.write_memory!(rsf, Runtests.Private.MemStats())
        Runtests.Private.finish_run_state!(rsf)
        @test Runtests.Private.read_run_state(path) !== nothing

        buf = IOBuffer()
        Runtests.Private.print_bytes(buf, 3.5 * 2^30, Runtests.Private.BYTES_WIDTH)
        Runtests.Private.print_1dp(buf, 2.5, 4)
        Runtests.Private.print_int(buf, 42, 4)
        @test !isempty(String(take!(buf)))
        @test Runtests.Private.item_log_path("/precompile/item_", 1, 1) == "/precompile/item_1_1.log"
    end
end

@testset "the precompile stage and the workers" begin
    # A setup module nothing has compiled before, used by one item under the
    # default profile and one under julia flags of its own.
    dir = make_pkg("SetupCache")
    setup = string("Shared", string(hash(dir); base=16))
    mkpath(joinpath(dir, "test", "testsetups"))
    write(joinpath(dir, "test", "testsetups", setup * ".jl"),
          "module $setup\n" * join(["f$i(x) = x + $i" for i in 1:200], "\n") * "\nend\n")
    write(joinpath(dir, "test", "TestItems.toml"),
          "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n")

    # A setup module is loaded from a file rather than as a registered package, so
    # its cache is a flat `<name>*.ji` beside the package directories, not inside
    # one of them.
    cache_root = joinpath(Base.DEPOT_PATH[1], "compiled", "v$(VERSION.major).$(VERSION.minor)")
    caches() = filter(f -> startswith(f, setup) && endswith(f, ".ji"), readdir(cache_root))

    @testset "a worker on the same flags reuses what the stage compiled" begin
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "plain" begin
            using $setup
            @test $setup.f1(1) == 2
        end
        """)
        @test isempty(caches())
        _, out = capture_run() do
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
        end
        @test occursin("precompiling $setup", out)
        # One cache, written by the stage and loaded by the worker. A worker that
        # had to compile it again would write a second one under its own flags.
        @test length(caches()) == 1
    end

    @testset "a profile with other julia flags undoes the stage's work" begin
        # `--check-bounds` changes code generation, so a worker under another setting
        # will not accept a cache compiled under this one. A setup module has no UUID, so
        # Julia keys its cache by name alone with no room for the flags — the
        # worker recompiles into the same file and the next run under the ordinary
        # flags finds it stale.
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "checked" profile=:bounds begin
            using $setup
            @test $setup.f1(1) == 2
            @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
        end
        """)
        @test length(caches()) == 1
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test all(==(PASSED), values(states))
        # One file still: the two sets of flags have nowhere separate to live.
        @test length(caches()) == 1

        # ...and what it now holds is no good to the ordinary flags, so the stage
        # runs again. This assertion documents the cost, and should be deleted by
        # whoever removes it.
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "plain" begin
            using $setup
            @test $setup.f1(1) == 2
        end
        """)
        _, out = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false)
        end
        @test occursin("precompiling $setup", out)
    end
end

@testset "a setup compiles in the form of `compilecache` that this Julia takes" begin
    # From 1.14 the positional form takes a `Base.PkgLoadSpec` where it took the path
    # of the source, and a call with the path is a `MethodError`, which a run reports
    # as a setup that failed to precompile. A depot of its own, so that the setup has
    # no cache yet and the call is made.
    setups, depot, load_path = mktempdir(), mktempdir(), copy(LOAD_PATH)
    name = string("Fresh", string(hash(setups); base=16))
    write(joinpath(setups, name * ".jl"), "module $name\nf() = 1\nend\n")
    pushfirst!(DEPOT_PATH, depot)
    pushfirst!(LOAD_PATH, setups)
    try
        pkg = Base.identify_package(name)
        bounds = Base.CacheFlags(Base.CacheFlags(); check_bounds = OTHER_BOUNDS.value)
        for (args, flags) in (`` => Base.CacheFlags(), `$(OTHER_BOUNDS.arg)` => bounds)
            @test !Runtests.Private.PrecompileHelper.has_fresh_cache(pkg, flags)
            @test first(Runtests.Private.PrecompileHelper.compile(pkg, args, flags)) === :built
            @test Runtests.Private.PrecompileHelper.has_fresh_cache(pkg, flags)
        end
    finally
        first(DEPOT_PATH) == depot && popfirst!(DEPOT_PATH)
        copy!(LOAD_PATH, load_path)
    end
end

@testset "the test environment is precompiled for the profiles' flags" begin
    # Every item's module loads the package under test, so a pool with julia
    # arguments of its own needs that package — and everything it depends on —
    # compiled again under those flags. Doing it here makes one parallel pass of
    # what would otherwise happen inside the first worker of the pool, serially
    # and with nothing printed while the run appears to sit on its first item.

    @testset "the flags come from a process started the same way" begin
        @test Runtests.Private.cache_flags_for(``) == Base.CacheFlags()
        @test Runtests.Private.cache_flags_for(`$(OTHER_BOUNDS.arg)`).check_bounds == OTHER_BOUNDS.value
        @test Runtests.Private.cache_flags_for(`$(OTHER_BOUNDS.arg)`) != Base.CacheFlags()
        # From 1.14 the flags hold the path that coverage is tracked under, or
        # `nothing`. A coverage run gives the root of the package, which can hold a space.
        root = mkpath(joinpath(realpath(mktempdir()), "with space"))
        flags = Runtests.Private.cache_flags_for(Cmd(Runtests.Private.coverage_flags(root, mktempdir())))
        @test !hasfield(Base.CacheFlags, :coverage_path) || flags.coverage_path == root
    end

    @testset "only profiles that change the cache flags are precompiled" begin
        # `bounds` changes code generation; `quiet` does not, so its workers can
        # use what this process already compiled and asking for it again would be
        # a whole environment's worth of work for no cache entry.
        dir = make_pkg(
            "ProfilePrecompile",
            "test/t_test.jl" => """
            @testitem "plain" begin
                @test true
            end
            @testitem "checked" profile=:bounds begin
                @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
            end
            @testitem "hushed" profile=:quiet begin
                @test true
            end
            @testitem "threaded" profile=:threaded begin
                @test Threads.nthreads() == 1
            end
            """,
            "test/TestItems.toml" => """
            [profiles.bounds]
            julia_args = ["$(OTHER_BOUNDS.arg)"]

            [profiles.quiet]
            julia_args = ["--banner=no"]

            # The number of threads compiles no code differently.
            [profiles.threaded]
            julia_args = ["--threads=1"]
            """
        )
        states, _, _ = nothing, nothing, nothing
        _, out = capture_run() do
            states, _, _ = run_states(dir; workers=3, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
        line = only(filter(l -> occursin("precompiling the test environment", l),
                           collect(eachsplit(out, '\n'))))
        @test occursin("bounds", line)
        @test !occursin("quiet", line) && !occursin("threaded", line)
        @test occursin("1 profile", line)
    end

    @testset "Runtests is compiled for a profile's flags once, before its workers start" begin
        # A worker loads Runtests before it connects, and compiling it there can take
        # longer than a worker is given to connect.
        dir = make_pkg(
            "SelfPrecompile",
            "test/t_test.jl" => """
            @testitem "checked" profile=:bounds begin
                @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
            end
            """,
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n"
        )
        outs = map(1:2) do _
            _, out = capture_run() do
                states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                @test all(==(PASSED), values(states))
            end
            out
        end
        @test !occursin("could not precompile Runtests", outs[1])
        @test !occursin("precompiling Runtests", outs[2])
    end

    @testset "a run with no profile flags says nothing about it" begin
        dir = make_pkg("NoProfilePrecompile", "test/t_test.jl" => """
        @testitem "plain" begin
            @test true
        end
        """)
        _, out = capture_run() do
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
        end
        @test !occursin("precompiling the test environment", out)
    end

    @testset "a run whose test environment is ready leaves the depot's manifest usage log alone" begin
        # Every `Pkg` context rewrites the whole log and records its environment in
        # it: a run that made one would add its temporary test environment each
        # time, and pay for rewriting a log that only grows.
        dir = make_pkg("UsageLog", "test/t_test.jl" => """
        @testitem "plain" begin
            @test true
        end
        """)
        capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))   # the environment, built and cached
        # `Pkg` writes its logs to the first depot; this one starts empty.
        depot = mktempdir()
        pushfirst!(DEPOT_PATH, depot)
        try
            capture_run() do
                states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                @test all(==(PASSED), values(states))
            end
        finally
            first(DEPOT_PATH) == depot && popfirst!(DEPOT_PATH)
        end
        @test !ispath(joinpath(depot, "logs", "manifest_usage.toml"))
    end
end

@testset "the queue's graph is the one Julia's precompiler builds" begin
    # Read from the manifest alone, so the packages need no source.
    dir = mktempdir()
    u = Dict(n => next_uuid() for n in ("A", "B", "C", "D", "E", "F", "H"))
    write(joinpath(dir, "Project.toml"), "[deps]\n" * join("$n = \"$(u[n])\"\n" for n in ("A", "B", "C", "F", "H")))
    entry(n, extra = "") = "[[deps.$n]]\nuuid = \"$(u[n])\"\npath = \"$n\"\n$extra\n"
    write(joinpath(dir, "Manifest.toml"), "julia_version = \"$VERSION\"\nmanifest_format = \"2.0\"\n\n" *
          entry("A", "weakdeps = [\"B\", \"H\"]\n\n    [deps.A.extensions]\n    AExt = \"B\"\n    ABHExt = [\"B\", \"H\"]\n") *
          entry("B") * entry("C", "deps = [\"A\", \"B\"]") * entry("D", "deps = [\"E\"]") * entry("E", "deps = [\"D\"]") *
          entry("F", "deps = [\"D\"]") * entry("H"))
    g = Runtests.Private.env_graph(joinpath(dir, "Project.toml"))
    id(n) = Base.PkgId(Base.UUID(u[n]), n)
    ext = Base.PkgId(Base.uuid5(Base.UUID(u["A"]), "AExt"), "AExt")
    wider = Base.PkgId(Base.uuid5(Base.UUID(u["A"]), "ABHExt"), "ABHExt")
    # An extension whose package and trigger are both there waits for both.
    @test g.parent[ext] == id("A") && Set(g.deps[ext]) == Set([id("A"), id("B")])
    # One whose triggers hold all of another's waits for that one too.
    @test Set(g.deps[wider]) == Set([id("A"), id("B"), id("H"), ext])
    # A package that loads both loads the extension while it compiles, so it waits for it.
    @test ext in g.deps[id("C")]
    # D and E wait for each other, and F for them: the precompiler leaves all three out.
    @test g.circular == Set([id("D"), id("E"), id("F")])
    # Names compile with what they wait for, and an extension with all it waits for,
    # also when that is another extension.
    @test Runtests.Private.compile_set(g, Set(["A"])) == Set([id("A")])
    @test Runtests.Private.compile_set(g, Set(["C"])) == Set([id("A"), id("B"), id("C"), ext])
    @test Runtests.Private.compile_set(g, Set(["A", "B", "H"])) == Set([id("A"), id("B"), id("H"), ext, wider])
end

@testset "one queue compiles every environment and the setups" begin
    # Packages whose compile takes a while and records when it ran, as the top level of a
    # module runs while it compiles: the time in a file `<name>.start`, and one `<name>.end`.
    # A file each, as two processes that append to one file can mix their lines.
    tag = string(hash(mktempdir()); base = 16)
    log = mktempdir()
    stamp(name, what) = "write($(repr(joinpath(log, name * "." * what))), string(time()))"
    function timed_pkg!(files, name; body = "sleep(2)")
        uuid = next_uuid()
        push!(files, "deps/$name/Project.toml" => "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
                     "deps/$name/src/$name.jl" => "module $name\n$(stamp(name, "start"))\n$body\n$(stamp(name, "end"))\nend\n")
        return uuid
    end
    dep(name, uuid, up) = "[deps]\n$name = \"$uuid\"\n\n[sources]\n$name = {path = \"$up/deps/$name\"}\n"
    spans() = Dict(name => [parse(Float64, read(joinpath(log, "$name.$what"), String)) for what in ("start", "end")]
                   for name in unique(first.(splitext.(readdir(log)))))
    item(name) = "@testitem \"$name\" begin\n    @test true\nend\n"
    run_once(dir) = with_runstate_dir(_ -> capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false)))

    @testset "the compiles of two environments run at the same time" begin
        foreach(f -> rm(joinpath(log, f)), readdir(log))
        t, q = "SlowTest$tag", "SlowQa$tag"
        files = Pair{String, String}[]
        ut, uq = timed_pkg!(files, t), timed_pkg!(files, q)
        dir = make_pkg("TwoEnvs$tag", files..., "test/Project.toml" => dep(t, ut, ".."), "test/t_test.jl" => item("t"),
                       "test/qa/Project.toml" => dep(q, uq, "../.."), "test/qa/q_test.jl" => item("q"))
        (states, _, _), out = run_once(dir)
        @test all(==(PASSED), values(states))
        s = spans()
        # Each started before the other ended.
        @test s[t][1] < s[q][2] && s[q][1] < s[t][2]
    end

    @testset "a setup compiles once what it loads is compiled, not after the whole environment" begin
        foreach(f -> rm(joinpath(log, f)), readdir(log))
        slow, setup = "SlowEnv$tag", "QuickSetup$tag"
        files = Pair{String, String}[]
        us = timed_pkg!(files, slow; body = "sleep(4)")
        dir = make_pkg("SetupEarly$tag", files..., "test/Project.toml" => dep(slow, us, ".."),
                       "test/testsetups/$setup.jl" => "module $setup\n$(stamp(setup, "start"))\n$(stamp(setup, "end"))\nend\n",
                       "test/t_test.jl" => "@testitem \"t\" begin\n    using $setup\n    @test true\nend\n")
        (states, _, _), out = run_once(dir)
        @test all(==(PASSED), values(states))
        s = spans()
        @test s[setup][1] < s[slow][2]
    end

    @testset "a setup waits for what it loads under julia arguments that leave the cache flags" begin
        # `--depwarn=no` compiles no code differently: the package and the setup have one
        # set of cache flags under two sets of arguments, and the setup waits all the same.
        foreach(f -> rm(joinpath(log, f)), readdir(log))
        slow, setup = "SlowLoaded$tag", "LoadingSetup$tag"
        files = Pair{String, String}[]
        us = timed_pkg!(files, slow)
        dir = make_pkg("SetupArgs$tag", files..., "test/Project.toml" => dep(slow, us, ".."),
                       "test/testsetups/$setup.jl" =>
                           "module $setup\n$(stamp(setup, "start"))\nusing $slow\n$(stamp(setup, "end"))\nend\n",
                       "test/TestItems.toml" => "[profiles.quiet]\njulia_args = [\"--depwarn=no\"]\n",
                       "test/t_test.jl" => "@testitem \"t\" profile=:quiet begin\n    using $setup\n    @test true\nend\n")
        (states, _, _), out = run_once(dir)
        @test all(==(PASSED), values(states))
        s = spans()
        @test s[setup][1] >= s[slow][2]
    end

    @testset "a package that fails to compile is said, what waits for it is left, and the run goes on" begin
        broken, after = "Broken$tag", "AfterBroken$tag"
        ub, ua = next_uuid(), next_uuid()
        dir = make_pkg("FailedCompile$tag",
                       "deps/$broken/Project.toml" => "name = \"$broken\"\nuuid = \"$ub\"\nversion = \"0.1.0\"\n",
                       "deps/$broken/src/$broken.jl" => "module $broken\nerror(\"broken on purpose\")\nend\n",
                       "deps/$after/Project.toml" => "name = \"$after\"\nuuid = \"$ua\"\nversion = \"0.1.0\"\n\n" *
                           dep(broken, ub, "../.."),
                       "deps/$after/src/$after.jl" => "module $after\nusing $broken\nend\n",
                       "test/Project.toml" => dep(after, ua, ".."),
                       "test/t_test.jl" => item("t"))
        (states, _, _), out = run_once(dir)
        @test all(==(PASSED), values(states))
        # A line as a test item's, and its output in the bracket of a failed item.
        @test occursin(Regex("COMP · +\\d+/\\d+ · \"$broken\" +· v0\\.1\\.0 +· FAIL"), out)
        @test occursin("broken on purpose", out)
        # Its compile could only have failed too: it is said skipped, not run.
        @test occursin(Regex("COMP · +\\d+/\\d+ · \"$after\" +· v0\\.1\\.0 +· SKIP"), out)
        # The queue's own count of the run says the same, with what it did compile.
        @test occursin(r"\[TEST\] precompiled \d+ compiles?( \(\d+ reused\))?, 1 failed, 1 skipped in ", out)
    end
end

@testset "a coverage run precompiles for the flags its workers count lines under" begin
    # From 1.14 the path whose lines are counted is in the cache flags, and the package
    # there needs a cache built under them. Before, coverage leaves the flags as they are.
    dir = make_pkg("CoveragePrecompile", "test/t_test.jl" => "@testitem \"plain\" begin\n    @test true\nend\n")
    with_runstate_dir() do _
        (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false, coverage = true))
        @test all(==(PASSED), values(states))
        @test occursin("precompiling the test environment for 1 profile: default", out) == (VERSION >= v"1.14-")
    end
end

@testset "a profile whose items the run leaves out is not precompiled" begin
    # Its preferences give it a project of its own, which only its own items load.
    dir = make_pkg(
        "IdleProfile",
        "test/t_test.jl" => """
        @testitem "plain" begin
            @test true
        end
        @testitem "tuned" profile=:tuned begin
            @test true
        end
        """,
        "test/prefs.toml" => "[IdleProfile]\nlevel = 3\n",
        "test/TestItems.toml" => "[profiles.tuned]\npreferences = \"prefs.toml\"\n",
        # Read as it compiles, as Preferences.jl reads one: a cache built under other
        # preferences is no good to the profile's project.
        "src/IdleProfile.jl" => """
        module IdleProfile
        const UUID = Base.PkgId(@__MODULE__).uuid
        Base.record_compiletime_preference(UUID, "level")
        const LEVEL = get(Base.get_preferences(UUID), "level", 0)
        end
        """
    )
    with_runstate_dir() do _
        (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false, name = "plain"))
        @test states == Dict("plain" => PASSED)
        @test !occursin("precompiling the test environment", out)
        (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
        @test all(==(PASSED), values(states))
        @test occursin("precompiling the test environment for 1 profile: tuned", out)
    end
end

@testset "a profile's `precompile` list is what the run compiles for it" begin
    # The items run in an environment directory with two packages that they never
    # load. Only the run's compile builds them.
    flags = Runtests.Private.cache_flags_for(`$(OTHER_BOUNDS.arg)`)
    profile(extra = "") = "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n" * extra
    function unloaded_pkg(name)
        kept, left = name * "Kept", name * "Left"
        uuids = Dict(kept => next_uuid(), left => next_uuid())
        files = Pair{String, String}[]
        for (n, u) in uuids
            push!(files, "deps/$n/Project.toml" => "name = \"$n\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n",
                         "deps/$n/src/$n.jl" => "module $n\nend\n")
        end
        dir = make_pkg(
            name, files...,
            "test/qa/Project.toml" => "[deps]\n" * join(("$n = \"$u\"\n" for (n, u) in uuids)) * "\n[sources]\n" *
                join(("$n = {path = \"../../deps/$n\"}\n" for n in keys(uuids))),
            "test/qa/q_test.jl" => """
            @testitem "checked" profile=:bounds begin
                @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
            end
            """
        )
        cached(n) = Runtests.Private.PrecompileHelper.has_fresh_cache(Base.PkgId(Base.UUID(uuids[n]), n), flags;
                                                     sourcepath = joinpath(dir, "deps", n, "src", "$n.jl"))
        return dir, kept, left, cached
    end
    # The output with `/` between directories, as Windows writes `test\qa`.
    function run_once(dir)
        value, out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
        return value, replace(out, '\\' => '/')
    end
    stage = "precompiling the environment of test/qa for 1 profile: bounds"

    with_runstate_dir() do _
        @testset "an empty list compiles Runtests only, and the workers what the items load" begin
            dir, kept, left, cached = unloaded_pkg("NoPrecompile")
            write(joinpath(dir, "test", "TestItems.toml"), profile("precompile = []\n"))
            (states, _, _), out = run_once(dir)
            @test all(==(PASSED), values(states))
            @test !occursin(stage, out)
            @test !cached(kept) && !cached(left)
            # Without the key, the run compiles the whole environment for the flags.
            write(joinpath(dir, "test", "TestItems.toml"), profile())
            (states, _, _), out = run_once(dir)
            @test all(==(PASSED), values(states))
            @test occursin(stage, out)
            @test cached(kept) && cached(left)
        end

        @testset "a list compiles the packages it names" begin
            dir, kept, left, cached = unloaded_pkg("SomePrecompile")
            write(joinpath(dir, "test", "TestItems.toml"), profile("precompile = [\"$kept\"]\n"))
            (states, _, _), out = run_once(dir)
            @test all(==(PASSED), values(states))
            @test occursin(stage, out)
            @test cached(kept)
            @test !cached(left)
        end

        @testset "a name that the environment does not hold stops the run before the workers start" begin
            dir, kept, _, _ = unloaded_pkg("MisnamedPrecompile")
            write(joinpath(dir, "test", "TestItems.toml"), profile("precompile = [\"$kept\", \"Nope\"]\n"))
            err = try
                run_once(dir)
                nothing
            catch e
                e
            end
            @test err isa ConfigError
            @test occursin("`precompile` of profile `bounds` names `Nope`, which is not a package of the environment of its items",
                           sprint(showerror, err))
        end
    end
end

VERSION >= v"1.12" && @testset "a profile's julia arguments compile only the packages that need them" begin
    # A's item runs under other julia arguments, B's under the default ones. The
    # arguments invalidate every cache built for the default, so their cost is
    # answered for each package that asks: nothing of B's is compiled under them.
    # Combined runs are 1.12's.
    ws = e2e_workspace(
        "A" => ["test/a_test.jl" => """
            @testitem "checked" profile=:bounds begin
                @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
            end
            @testitem "plain" begin
                @test true
            end
            """,
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n"],
        "B" => ["test/b_test.jl" => "@testitem \"b\" begin\n    @test true\nend\n"])
    flags = Runtests.Private.cache_flags_for(`$(OTHER_BOUNDS.arg)`)
    with_runstate_dir() do _
        (states, _, p), out = capture_run(() -> run_mono(ws; workers = 1, logs = :issues, monitor = false))
        @test all(==(PASSED), values(states))
        @test occursin("precompiling the test environment for 1 profile: bounds", out)
        cached(name, f) = Runtests.Private.PrecompileHelper.has_fresh_cache(
            Base.PkgId(p.packages.uuid[findfirst(==(name), p.packages.name)], name), f;
            sourcepath = joinpath(ws, "lib", name, "src", "$name.jl"))
        @test cached("A", flags)
        @test cached("B", Base.CacheFlags())
        @test !cached("B", flags)
    end
end

@testset "the queue's log is one block, and every compile a line" begin
    # A package with a profile whose julia flags differ, with items under it in the
    # test environment and in an environment directory: the announcement, the helper
    # lines and the job lines are asserted against its run's output.
    u = next_uuid()
    dir = make_pkg(
        "LogShape",
        "deps/QaDep/Project.toml" => "name = \"QaDep\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n",
        "deps/QaDep/src/QaDep.jl" => "module QaDep\nend\n",
        "test/t_test.jl" => """
        @testitem "checked" profile=:bounds begin
            @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
        end
        """,
        "test/qa/Project.toml" => "[deps]\nQaDep = \"$u\"\n\n[sources]\nQaDep = {path = \"../../deps/QaDep\"}\n",
        "test/qa/qa_test.jl" => """
        @testitem "qa checked" profile=:bounds begin
            using QaDep
            @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
        end
        """,
        "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n",
    )
    (states, _, _), out = with_runstate_dir(_ -> capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false)))
    @test all(==(PASSED), values(states))
    lines = collect(eachsplit(out, '\n'))
    qa = joinpath("test", "qa")

    # One bracketed block announces the work: the compiles, the helper processes
    # they spread over, and the shared ceiling on how many run at once.
    heads = filter(l -> occursin(r"\[TEST\] precompiling \d+ compile", l), lines)
    @test length(heads) == 1
    @test occursin("with 1 worker,", only(heads))
    @test occursin("at most $(Runtests.Private.precompile_tasks()) at once", only(heads))

    # The coordinator compiles for its own environment, and the environment directory
    # has a helper. The helper comes up and goes down as a worker does, its square
    # black, and its UP line is the worker's own: pid, profile, environment, arguments.
    ups = filter(l -> occursin(r"⬛ w\d+ · \d\d:\d\d:\d\d · UP ", l), lines)
    @test length(ups) == 1
    @test occursin(r"^⬛ w1 · \d\d:\d\d:\d\d · UP   · pid \d+ · profile bounds · env ", only(ups))
    @test endswith(only(ups), "· env $qa · $(OTHER_BOUNDS.arg)")
    @test any(l -> occursin(r"⬛ w1 · \d\d:\d\d:\d\d · EXIT", l) && occursin(r"\d+ compiles?", l), lines)

    # On a job line the profile names the flags; the arguments themselves are not
    # there. The lines are numbered in one count, in the order they are printed.
    pre = filter(l -> occursin("COMP", l), lines)
    @test !any(l -> occursin(OTHER_BOUNDS.arg, l), pre)
    @test any(l -> occursin("profile bounds", l), pre)
    @test [parse(Int, match(r"· \s*(\d+)/\d+ ·", l).captures[1]) for l in pre] == 1:length(pre)
    here = filter(l -> occursin(r"^\S+ w0 ", l), pre)
    helper = filter(l -> occursin(r"^\S+ w1 ", l), pre)
    @test !isempty(here) && !isempty(helper)
    @test all(l -> occursin("· env $qa", l), helper)
    # A helper's built line carries the resident peak of its compiles, after its time,
    # as a DONE line carries its worker's. The children of the coordinator are its test
    # workers too, so its own lines carry none.
    @test Sys.iswindows() || all(l -> occursin(r"· maxrss [\d.]+ GiB", l), helper)
    @test !any(l -> occursin("maxrss", l), here)

    # When the queue ends a line accounts for it: what compiled, what was reused,
    # and how long the phase took.
    @test occursin(r"\[TEST\] precompiled \d+ compiles?( \(\d+ reused\))? in [\d.ms]+", out)
end

@testset "the queue's tasks share no variable of `run_queue`" begin
    # A variable of `run_queue` that one of its closures assigns is one box that every
    # closure shares, and the queue's tasks would race on it.
    P = Runtests.Private
    @test !occursin("Core.Box", string(only(code_lowered(P.run_queue, (P.Run, P.PrecompileQueue)))))
end

@testset "a job already fresh is counted but not listed" begin
    dir = make_pkg(
        "FreshLog",
        "test/t_test.jl" => """
        @testitem "checked" profile=:bounds begin
            @test Base.JLOptions().check_bounds == $(OTHER_BOUNDS.value)
        end
        """,
        "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n",
    )
    (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
    @test all(==(PASSED), values(states))
    # A change only to the package's source: its compiles run again, and what the
    # first run compiled for the profile the head counts as reused. A reused job
    # prints no line.
    open(io -> println(io, "# touched"), joinpath(dir, "src", "FreshLog.jl"), "a")
    (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
    @test all(==(PASSED), values(states))
    # One environment, the coordinator's own: it compiles there itself, and starts no helper.
    @test !occursin(Runtests.Private.PRECOMPILE_MARK_WORKER, out)
    @test occursin(r"\(\d+ reused\)", out)
    @test occursin(r"\[TEST\] precompiled \d+ compiles? \(\d+ reused\) in ", out)
    @test !occursin(r"\bREUSED\b", out)
    @test !occursin(r"⬜ w\d+ · \d\d:\d\d:\d\d · COMP", out)
    # Only the compiles number into the total: there is no hole for a reused job.
    pre = filter(l -> occursin("COMP", l), collect(eachsplit(out, '\n')))
    total = maximum(l -> parse(Int, match(r"(\d+)/(\d+)", l).captures[2]), pre)
    @test total == length(pre)
end

@testset "a run off a terminal says what still compiles" begin
    # Without a pinned status line there is nothing to see during a long compile,
    # so a quiet run names what is still compiling after a monitor interval goes
    # by without a completion. `monitor_interval = 0` asks for it at once.
    u = next_uuid()
    dir = make_pkg(
        "SlowLog",
        "deps/SlowPkg/Project.toml" => "name = \"SlowPkg\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n",
        "deps/SlowPkg/src/SlowPkg.jl" => "module SlowPkg\nsleep(2)\nend\n",
        "test/Project.toml" => "[deps]\nSlowPkg = \"$u\"\n\n[sources]\nSlowPkg = {path = \"../deps/SlowPkg\"}\n",
        "test/t_test.jl" => "@testitem \"t\" begin\n    @test true\nend\n",
    )
    (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false, monitor_interval = 0))
    @test all(==(PASSED), values(states))
    @test occursin("still precompiling SlowPkg", out)
    @test occursin(Regex("COMP · +\\d+/\\d+ · \"SlowPkg\" +· v0\\.1\\.0 +· PASS"), out)
end

@testset "a name longer than the name column leaves the version unpadded" begin
    # The name column stops at sixty: a name longer than it — an extension's
    # `Package → PackageExt` is the usual case — pushes every column after it
    # out of place, so the version's own padding would only lengthen the line.
    u1, u2, u3 = next_uuid(), next_uuid(), next_uuid()
    longname = "A" * "b"^70
    dir = make_pkg(
        "PadLog",
        "deps/$longname/Project.toml" => "name = \"$longname\"\nuuid = \"$u1\"\nversion = \"0.1.0\"\n",
        "deps/$longname/src/$longname.jl" => "module $longname\nend\n",
        "deps/Versioned/Project.toml" => "name = \"Versioned\"\nuuid = \"$u2\"\nversion = \"100.200.300\"\n",
        "deps/Versioned/src/Versioned.jl" => "module Versioned\nend\n",
        "deps/Dep2/Project.toml" => "name = \"Dep2\"\nuuid = \"$u3\"\nversion = \"0.1.0\"\n",
        "deps/Dep2/src/Dep2.jl" => "module Dep2\nend\n",
        "test/Project.toml" => "[deps]\n$longname = \"$u1\"\nVersioned = \"$u2\"\nDep2 = \"$u3\"\n\n[sources]\n$longname = {path = \"../deps/$longname\"}\nVersioned = {path = \"../deps/Versioned\"}\nDep2 = {path = \"../deps/Dep2\"}\n",
        "test/t_test.jl" => "@testitem \"t\" begin\n    @test true\nend\n",
    )
    (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
    @test all(==(PASSED), values(states))
    pre = filter(l -> occursin("COMP", l), collect(eachsplit(out, '\n')))
    line = only(filter(l -> occursin(longname, l), pre))
    # `v100.200.300` sets the version column: with the padding a shorter version
    # would carry spaces before its `·`. The overflowing name's does not.
    @test occursin(Regex("\"$longname\" · v0\\.1\\.0 · PASS"), line)
    # A name that fits still has its version padded to the column.
    @test occursin(r"v0\.1\.0 {2,}· PASS", only(filter(l -> occursin("\"Dep2\"", l), pre)))
end

@testset "a helper's EXIT counts what it reused as well as what it compiled" begin
    # `Shared` is a dependency of the test environment and of `test/qa`, so the
    # queue holds two jobs for its one cache: the first to build wins, and the
    # other environment's helper answers a job it did not have to compile.
    u = next_uuid()
    dir = make_pkg(
        "ReuseExit",
        "deps/Shared/Project.toml" => "name = \"Shared\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n",
        "deps/Shared/src/Shared.jl" => "module Shared\nend\n",
        "test/Project.toml" => "[deps]\nShared = \"$u\"\n\n[sources]\nShared = {path = \"../deps/Shared\"}\n",
        "test/qa/Project.toml" => "[deps]\nShared = \"$u\"\n\n[sources]\nShared = {path = \"../../deps/Shared\"}\n",
        "test/t_test.jl" => "@testitem \"t\" begin\n    @test true\nend\n",
        "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\n    @test true\nend\n",
    )
    (states, _, _), out = capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false))
    @test all(==(PASSED), values(states))
    lines = collect(eachsplit(out, '\n'))
    exits = filter(l -> occursin(r"⬛ w\d+ · \d\d:\d\d:\d\d · EXIT", l), lines)
    @test !isempty(exits)
    @test any(l -> occursin(r"\(\d+ reused\)", l), exits)
    # Its environment is named as a worker's own would name it.
    @test any(l -> occursin(r"⬛ w\d+ · \d\d:\d\d:\d\d · UP   · pid \d+ · ", l) &&
                   occursin("· env $(joinpath("test", "qa"))", l), lines)
end
