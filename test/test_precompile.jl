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
            @test !Runtests.Private.has_fresh_cache(pkg, flags)
            @test Runtests.Private.compile_setup((; pkg, args, flags, after = Int[])) === nothing
            @test Runtests.Private.has_fresh_cache(pkg, flags)
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
            """,
            "test/TestItems.toml" => """
            [profiles.bounds]
            julia_args = ["$(OTHER_BOUNDS.arg)"]

            [profiles.quiet]
            julia_args = ["--banner=no"]
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
        @test !occursin("quiet", line)
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

@testset "one call of the precompiler for the sets of flags that need the same packages" begin
    # A call has one queue for all its sets of flags, and calls run one after the
    # other, so the fewest calls that compile nothing unasked leave the fewest free
    # slots waiting on the last packages of a call.
    default = `` => Base.CacheFlags()
    bounds = `--check-bounds=yes` => Base.CacheFlags(Base.CacheFlags(); check_bounds = 1)
    inline = `--inline=no` => Base.CacheFlags(Base.CacheFlags(); inline = false)
    need(project, config, whole, names, profiles = String[]) =
        (; project, config, whole, names = Set{String}(names), subject = "the test environment", profiles = Set{String}(profiles))
    calls(needs...) = [(c.project, c.configs, c.names, c.profiles) for c in
                       Runtests.Private.precompile_calls(Runtests.Private.PrecompileNeed[needs...])]

    @testset "a project that every set of flags needs whole is one call, this process's flags first" begin
        @test calls(need("/t", bounds, true, [], ["bounds"]), need("/t", default, true, [])) ==
            [("/t", [default, bounds], String[], ["bounds"])]
    end

    @testset "names that the same sets of flags need are one call" begin
        # A's items run under both sets, B's under the default one.
        @test calls(need("/u", default, false, ["A", "B", "Runtests"]), need("/u", bounds, false, ["A", "Runtests"], ["bounds"])) ==
            [("/u", [default, bounds], ["A", "Runtests"], ["bounds"]), ("/u", [default], ["B"], String[])]
    end

    @testset "never more calls than sets of flags" begin
        # Seven groups of names for three sets of flags: a call for each set.
        got = calls(need("/u", default, false, ["A", "B", "D", "R"]), need("/u", bounds, false, ["A", "C", "E", "R"]),
                    need("/u", inline, false, ["B", "C", "F", "R"]))
        @test got == [("/u", [default], ["A", "B", "D", "R"], String[]), ("/u", [bounds], ["A", "C", "E", "R"], String[]),
                      ("/u", [inline], ["B", "C", "F", "R"], String[])]
    end

    @testset "each project has calls of its own, and a need without names has none" begin
        got = calls(need("/u", default, false, ["A"]), need("/qa", default, true, [], ["default"]),
                    need("/qa", bounds, true, [], ["bounds"]), need("/u", bounds, false, []))
        @test got == [("/qa", [default, bounds], String[], ["bounds", "default"]), ("/u", [default], ["A"], String[])]
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
        "test/TestItems.toml" => "[profiles.tuned]\npreferences = \"prefs.toml\"\n"
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
        cached(n) = Runtests.Private.has_fresh_cache(Base.PkgId(Base.UUID(uuids[n]), n), flags;
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
        cached(name, f) = Runtests.Private.has_fresh_cache(
            Base.PkgId(p.packages.uuid[findfirst(==(name), p.packages.name)], name), f;
            sourcepath = joinpath(ws, "lib", name, "src", "$name.jl"))
        @test cached("A", flags)
        @test cached("B", Base.CacheFlags())
        @test !cached("B", flags)
    end
end
