# Test setups are ordinary modules under `test/testsetups/`, loaded through
# LOAD_PATH. That is the whole mechanism, and it is what lets a setup use anything
# the package declares for testing — including another setup.

using Runtests.Private: PASSED, FAILED, ERRORED, ConfigError, prepare, execute, nitems, setup_modules, TOML

# A setup that is a package, `test/testsetups/<name>` in the package at `dir`, with
# `deps`, pairs of a name and a UUID, in its `[deps]`. Returns its UUID.
function write_setup(dir, name, body = ""; deps = Pair{String, String}[], uuid = next_uuid())
    src = mkpath(joinpath(dir, "test", "testsetups", name, "src"))
    write(joinpath(src, name * ".jl"), "module $name\n$body\nend\n")
    write(joinpath(dir, "test", "testsetups", name, "Project.toml"),
          "name = \"$name\"\nuuid = \"$uuid\"\n" * (isempty(deps) ? "" : "\n[deps]\n" * join("$n = \"$u\"\n" for (n, u) in deps)))
    return uuid
end

# The cache files of setup `name` in the depot that new caches go to.
setup_caches(name) =
    filter(endswith(".ji"), readdir(joinpath(first(DEPOT_PATH), "compiled", "v$(VERSION.major).$(VERSION.minor)", name)))

@testset "test setups" begin
    @testset "a setup may use any of the package's test-time dependencies" begin
        pkg = fixture("TestDeps.jl")
        for workers in (0, 1)
            states, _, _ = run_states(pkg; workers, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            @test length(states) == 3
        end
    end

    @testset "the setups an item names are the ones the run arranges for" begin
        pkg = fixture("TestDeps.jl")
        p, _ = prepare((pkg,); workers=1, logs=:issues, monitor=false)
        @test Set(p.setups) == Set([:DepSetup, :TimeSetup])
    end

    @testset "setups are precompiled once, before any worker starts" begin
        dir = make_pkg("PrecompiledSetup")
        # A module nothing has compiled before. Julia caches a setup under its own
        # name, so a fixed one would be warm from whichever earlier run of this
        # suite happened to compile it.
        setup = string("Once", string(hash(dir); base=16))
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses it" begin
            using $setup
            @test $setup.value() == 7
        end
        """)
        mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(dir, "test", "testsetups", setup * ".jl"), "module $setup\nvalue() = 7\nend\n")

        (states, _, p), out = capture_run() do
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test states["uses it"] === PASSED
        @test p.setups == [Symbol(setup)]
        # One process does it, before the workers exist: without this, N workers
        # hit the same cold cache at once and serialize on Julia's precompile lock.
        @test occursin("precompiling " * setup, out)
        _, again = capture_run() do
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test !occursin("precompiling", again)
    end

    @testset "a setup that is a package is precompiled for every profile's flags" begin
        # A package keeps a cache per set of flags, so the `checked` pool's can be
        # built before its worker starts rather than inside its first item.
        dir = make_pkg("ProfiledSetup")
        setup = string("Flagged", string(hash(dir); base=16))
        write(joinpath(dir, "test", "TestItems.toml"), "[profiles.checked]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n")
        # Each item asks, before it loads the setup, whether its own process has a
        # cache to load: `false` would mean the worker compiles it itself. (Loading a
        # cache touches its file, so the file's time cannot say who wrote it.)
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "plain" begin
            @test Base.isprecompiled(Base.identify_package("$setup"))
            using $setup
            @test $setup.value() == 7
        end
        @testitem "checked" profile=:checked begin
            @test Base.isprecompiled(Base.identify_package("$setup"))
            using $setup
            @test $setup.value() == 7
        end
        """)
        src = mkpath(joinpath(dir, "test", "testsetups", setup, "src"))
        write(joinpath(src, setup * ".jl"), "module $setup\nvalue() = 7\nend\n")
        write(joinpath(dir, "test", "testsetups", setup, "Project.toml"), "name = \"$setup\"\nuuid = \"$(next_uuid())\"\n")

        (states, _, _), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["plain"] === PASSED && states["checked"] === PASSED
        @test occursin("precompiling $setup", out)
        # A cache for each set of flags, and nothing left to compile the next time.
        cachedir = joinpath(first(DEPOT_PATH), "compiled", "v$(VERSION.major).$(VERSION.minor)", setup)
        @test count(endswith(".ji"), readdir(cachedir)) == 2
        (states, _, _), again = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["plain"] === PASSED && states["checked"] === PASSED
        @test !occursin("precompiling $setup", again)
    end

    @testset "a setup is precompiled for the profiles whose items load it, and for no other" begin
        # Each item asks, before it loads its setup, whether its process has a cache to
        # load. `Plain` is loaded under this process's flags only, `Checked` under the
        # `checked` profile's only, and each has the one cache it is loaded from.
        for workers in (0, 1)
            dir = make_pkg("ExactSetups")
            plain, checked = (string(n, string(hash(dir); base=16)) for n in ("Plain", "Checked"))
            write(joinpath(dir, "test", "TestItems.toml"), "[profiles.checked]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n")
            write(joinpath(dir, "test", "a_test.jl"), """
            @testitem "plain" begin
                @test Base.isprecompiled(Base.identify_package("$plain"))
                using $plain
            end
            @testitem "checked" profile=:checked begin
                @test Base.isprecompiled(Base.identify_package("$checked"))
                using $checked
            end
            """)
            write_setup(dir, plain); write_setup(dir, checked)
            states, _, _ = run_states(dir; workers, logs=:issues, monitor=false)
            @test states["plain"] === PASSED && states["checked"] === PASSED
            @test length(setup_caches(plain)) == 1 && length(setup_caches(checked)) == 1
        end
    end

    @testset "an item in this process loads its setup under this process's flags" begin
        # With workers = 0 the default profile's items run here, whatever julia arguments
        # the profile gives its workers; with a worker, the setup is compiled for those.
        for workers in (0, 1)
            dir = make_pkg("HereSetup")
            setup = string("Here", string(hash(dir); base=16))
            write(joinpath(dir, "test", "TestItems.toml"), "[profiles.default]\njulia_args = [\"$(OTHER_BOUNDS.arg)\"]\n")
            write(joinpath(dir, "test", "a_test.jl"), """
            @testitem "uses it" begin
                @test Base.isprecompiled(Base.identify_package("$setup"))
                using $setup
            end
            """)
            write_setup(dir, setup)
            states, _, _ = run_states(dir; workers, logs=:issues, monitor=false)
            @test states["uses it"] === PASSED
        end
    end

    @testset "a setup is precompiled with the setups it depends on, and in an environment directory" begin
        # `Outer` depends on `Inner`; an item of the environment directory `qa` loads
        # `Outer` there, and an item of the test environment loads `Inner`.
        dir = make_pkg("SetupChain")
        inner, outer = (string(n, string(hash(dir); base=16)) for n in ("Inner", "Outer"))
        u = write_setup(dir, inner, "value() = 7")
        write_setup(dir, outer, "using $inner\nvalue() = $inner.value() + 1"; deps = [inner => u])
        mkpath(joinpath(dir, "test", "qa"))
        write(joinpath(dir, "test", "qa", "Project.toml"), "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n")
        write(joinpath(dir, "test", "qa", "qa_test.jl"), """
        @testitem "outer" begin
            @test Base.isprecompiled(Base.identify_package("$outer"))
            @test Base.isprecompiled(Base.identify_package("$inner"))
            using $outer
            @test $outer.value() == 8
        end
        """)
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "inner" begin
            @test Base.isprecompiled(Base.identify_package("$inner"))
            using $inner
            @test $inner.value() == 7
        end
        """)
        (states, _, _), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["outer"] === PASSED && states["inner"] === PASSED
        @test occursin("precompiling $inner", out)
    end

    @testset "a setup's compile waits for the compiles of the setups it loads" begin
        # `[deps]` says what a setup that is a package loads, and the imports in its source
        # what one that is not loads. Of two setups that name each other, one waits.
        dir = make_pkg("SetupOrder")
        tag = string(hash(dir); base=16)
        file, filedep, pkg, pkgdep, one, other = (n * tag for n in ("File", "FileDep", "Pkg", "PkgDep", "One", "Other"))
        setups = mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(setups, filedep * ".jl"), "module $filedep\nend\n")
        write(joinpath(setups, file * ".jl"), "module $file\nusing $filedep\nend\n")
        write_setup(dir, pkg, "using $pkgdep"; deps = [pkgdep => write_setup(dir, pkgdep)])
        uone, uother = next_uuid(), next_uuid()
        write_setup(dir, one, "using $other"; deps = [other => uother], uuid = uone)
        write_setup(dir, other, "using $one"; deps = [one => uone], uuid = uother)
        needs = Runtests.Private.SetupNeed[(; name = Symbol(n), args = ``, flags = Base.CacheFlags(), dir = setups)
                                           for n in (file, filedep, pkg, pkgdep, one, other)]
        jobs = Runtests.Private.with_load_path(setups) do
            Runtests.Private.stale_setups(needs, Dict{Symbol, String}())
        end
        at(n) = findfirst(j -> j.pkg.name == n, jobs)
        @test jobs[at(file)].after == [at(filedep)] && isempty(jobs[at(filedep)].after)
        @test jobs[at(pkg)].after == [at(pkgdep)] && isempty(jobs[at(pkgdep)].after)
        @test length(jobs[at(one)].after) + length(jobs[at(other)].after) == 1
    end

    @testset "a setup stays precompiled when it loads another that compiles after it" begin
        # One compile at a time, in the order the item names them. `Loader` loads `Loaded`
        # through generated code, which its source does not show, so nothing orders the
        # two: `Loader`'s compile builds `Loaded` too, and `Loaded`'s own compile, which
        # comes next, finds it built.
        dir = make_pkg("HiddenLoad")
        loader, loaded = (n * string(hash(dir); base=16) for n in ("Loader", "Loaded"))
        setups = mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(setups, loaded * ".jl"), "module $loaded\nvalue() = 1\nend\n")
        write(joinpath(setups, loader * ".jl"), """
        module $loader
        Core.eval(@__MODULE__, Meta.parse("using " * "$loaded"))
        value() = $loaded.value() + 1
        end
        """)
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "loads both" begin
            @test Base.isprecompiled(Base.identify_package("$loader"))
            @test Base.isprecompiled(Base.identify_package("$loaded"))
            using $loader, $loaded
            @test $loader.value() == 2
        end
        """)
        states, _, _ = withenv("JULIA_NUM_PRECOMPILE_TASKS" => "1") do
            run_states(dir; workers=1, logs=:issues, monitor=false)
        end
        @test states["loads both"] === PASSED
    end

    @testset "setups that depend on each other do not stall the setup of the run" begin
        # Neither compile waits for the other, so the run reaches its item. Whether Julia
        # then loads the pair depends on its version: 1.11 does, and 1.12 and later
        # refuse with a deadlock error.
        dir = make_pkg("SetupCycle")
        a, b = (string(n, string(hash(dir); base=16)) for n in ("CycleA", "CycleB"))
        ua, ub = next_uuid(), next_uuid()
        write_setup(dir, a, "using $b"; deps = [b => ub], uuid = ua)
        write_setup(dir, b, "using $a"; deps = [a => ua], uuid = ub)
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses both" begin
            using $a
            using $b
        end
        """)
        (states, _, _), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["uses both"] in (PASSED, FAILED, ERRORED)
        VERSION >= v"1.12" && @test occursin("deadlock detected in loading", out)
    end

    @testset "a run warns about each setup it loads that is not a package" begin
        # A file and a directory without a project are not packages; a setup no
        # selected item loads, and a setup that is a package, are not named.
        dir = make_pkg("UnconvertedSetups")
        flat, nested, unused, converted = (string(n, string(hash(dir); base=16)) for n in ("Flat", "Nested", "Unused", "Converted"))
        write(joinpath(mkpath(joinpath(dir, "test", "testsetups")), flat * ".jl"), "module $flat\nend\n")
        write(joinpath(mkpath(joinpath(dir, "test", "testsetups", nested, "src")), nested * ".jl"), "module $nested\nend\n")
        write(joinpath(dir, "test", "testsetups", unused * ".jl"), "module $unused\nend\n")
        write_setup(dir, converted)
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses three" begin
            using $flat, $nested, $converted
        end
        """)
        (states, _, _), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["uses three"] === PASSED
        @test occursin("are not packages", out)
        @test occursin("`$(joinpath("test", "testsetups", flat * ".jl"))`", out)
        @test occursin("`$(joinpath("test", "testsetups", nested, "src", nested * ".jl"))`", out)
        @test !occursin(unused, out)
        @test !occursin(joinpath(converted, "src", converted * ".jl"), out)
        # Converted, they are not warned about.
        capture_run(() -> Runtests.setups_to_packages(dir))
        (states, _, _), again = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false))
        @test states["uses three"] === PASSED
        @test !occursin("not a package", again) && !occursin("not packages", again)
    end

    @testset "setups are found as a file or as a directory" begin
        dir = make_pkg(
            "SetupShapes",
            "test/a_test.jl" => """
            @testitem "uses both" begin
                using Flat
                using Nested
                @test Flat.value() + Nested.value() == 3
            end
            """,
            "test/testsetups/Flat.jl" => "module Flat\nvalue() = 1\nend\n",
            "test/testsetups/Nested/src/Nested.jl" => "module Nested\nvalue() = 2\nend\n",
        )
        setups = setup_modules(joinpath(dir, "test"))
        @test sort(collect(keys(setups))) == [:Flat, :Nested]
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["uses both"] === PASSED
    end

    @testset "a setup that will not precompile stops the run and names itself" begin
        dir = make_pkg(
            "BrokenSetup",
            "test/a_test.jl" => """
            @testitem "needs it" begin
                using Broken
                @test true
            end
            """,
            "test/testsetups/Broken.jl" => "module Broken\nerror(\"this setup is broken\")\nend\n",
        )
        err = try
            run_states(dir; workers=1, logs=:issues, monitor=false)
            nothing
        catch e
            e
        end
        @test err isa ConfigError
        msg = sprint(showerror, err)
        @test occursin("Broken", msg)
        @test occursin("failed to precompile", msg)
        # The reason, not just the fact.
        @test occursin("this setup is broken", msg)
    end

    @testset "a module that is not a setup is an ordinary load failure" begin
        # Nothing under `testsetups/` is named `Absent`, so this is not a setup the
        # run has to arrange for: it is the item asking for a package it has not got.
        dir = make_pkg("NoSuchSetup", "test/a_test.jl" => """
        @testitem "asks for a package it has not got" begin
            using Absent
            @test true
        end
        """)
        p, target = prepare((dir,); workers=1, logs=:issues, monitor=false)
        @test isempty(p.setups)
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["asks for a package it has not got"] === ERRORED
    end

    @testset "the setups directory is left off LOAD_PATH afterwards" begin
        before = copy(LOAD_PATH)
        run_states(fixture("TestDeps.jl"); workers=1, logs=:issues, monitor=false)
        @test LOAD_PATH == before
    end
end

@testset "setups as packages" begin
    stdlib_uuid(name) = TOML.parsefile(joinpath(Sys.STDLIB, name, "Project.toml"))["uuid"]
    # A setup that reads a file beside `testsetups/`, one that imports it, and an item
    # that uses both: what making them packages has to keep working.
    convertible() = make_pkg(
        "SetupPkgs",
        "test/a_test.jl" => """
        @testitem "uses both" begin
            using Uses, Helpers
            @test Uses.two() == 2
            @test Helpers.DATA == "beside the setups"
            @test basename(Helpers.here()) == "testsetups"
            @test basename(Uses.HERE) == "testsetups"
        end
        """,
        "test/data.txt" => "beside the setups",
        "test/testsetups/Helpers.jl" => """
        module Helpers
        using Random
        using SetupPkgs
        # Read from the directory above this one, @__DIR__/..
        const DATA = read(joinpath(@__DIR__, "..", "data.txt"), String)
        const WHERE = "@__DIR__"
        here() = @__DIR__()
        value() = 1
        end
        """,
        "test/testsetups/Uses.jl" => """
        "One more than `Helpers` has."
        module Uses
        using Helpers: value
        import Dates
        const HERE = @__DIR__
        two() = value() + 1
        end
        """,
    )

    @testset "each setup moves into a package of its own, and items load it as before" begin
        dir = convertible()
        setups = joinpath(dir, "test", "testsetups")
        _, out = capture_run(() -> Runtests.setups_to_packages(dir))
        for name in ("Helpers", "Uses")
            @test isfile(joinpath(setups, name, "src", name * ".jl"))
            @test !ispath(joinpath(setups, name * ".jl"))
        end
        project = joinpath(setups, "Helpers", "Project.toml")
        @test startswith(read(project, String), "name = \"Helpers\"\nuuid = ")
        helpers = TOML.parsefile(project)
        uses = TOML.parsefile(joinpath(setups, "Uses", "Project.toml"))
        # What each imports: a standard library, the package under test, another setup.
        @test helpers["deps"] == Dict(
            "Random" => stdlib_uuid("Random"),
            "SetupPkgs" => TOML.parsefile(joinpath(dir, "Project.toml"))["uuid"],
        )
        # `Uses` imports the package under test only to name its directory.
        @test uses["deps"] == Dict("Dates" => stdlib_uuid("Dates"), "Helpers" => helpers["uuid"],
                                   "SetupPkgs" => helpers["deps"]["SetupPkgs"])
        @test helpers["uuid"] != uses["uuid"]
        # `@__DIR__` in code is the package's `test/testsetups/`, by the name the setup
        # gives the package; in a comment or a string it is text.
        code = read(joinpath(setups, "Helpers", "src", "Helpers.jl"), String)
        @test occursin("read(pkgdir(SetupPkgs, \"test\", \"data.txt\"), String)", code)
        @test occursin("here() = pkgdir(SetupPkgs, \"test\", \"testsetups\")\n", code)
        @test occursin("# Read from the directory above this one, @__DIR__/..", code)
        @test occursin("const WHERE = \"@__DIR__\"", code)
        code = read(joinpath(setups, "Uses", "src", "Uses.jl"), String)
        @test occursin("module Uses\nimport SetupPkgs\nusing Helpers: value\n", code)
        @test occursin("const HERE = pkgdir(SetupPkgs, \"test\", \"testsetups\")\n", code)
        @test occursin(
            "`Helpers`: moved to $(joinpath("Helpers", "src", "Helpers.jl")) · `@__DIR__` rewritten 2× · " *
                "deps: Random, SetupPkgs",
            out
        )
        @test occursin(
            "`Uses`:    moved to $(joinpath("Uses", "src", "Uses.jl")) · `@__DIR__` rewritten 1× · " *
                "`import SetupPkgs` added · deps: Dates, Helpers, SetupPkgs",
            out
        )
        # A package, and so a cache filed under its UUID.
        Runtests.Private.with_load_path(setups) do
            @test Base.identify_package("Helpers") == Base.PkgId(Base.UUID(helpers["uuid"]), "Helpers")
        end
        for workers in (0, 1)
            states, _, _ = run_states(dir; workers, logs=:issues, monitor=false)
            @test states["uses both"] === PASSED
        end
    end

    @testset "run again, it adds what a setup has come to import and changes nothing else" begin
        dir = convertible()
        setups = joinpath(dir, "test", "testsetups")
        capture_run(() -> Runtests.setups_to_packages(dir))
        project = joinpath(setups, "Uses", "Project.toml")
        helpers = read(joinpath(setups, "Helpers", "Project.toml"), String)
        before = read(project, String)
        _, out = capture_run(() -> Runtests.setups_to_packages(dir))
        @test read(project, String) == before
        @test occursin("`Uses`:    up to date", out)
        # A dependency added by hand stays, and an import added since is added.
        entry = joinpath(setups, "Uses", "src", "Uses.jl")
        write(entry, replace(read(entry, String), "import Dates" => "import Dates\nusing Test"))
        toml = TOML.parsefile(project)
        toml["deps"]["Logging"] = stdlib_uuid("Logging")
        open(io -> TOML.print(io, toml), project, "w")
        _, out = capture_run(() -> Runtests.setups_to_packages(dir))
        after = TOML.parsefile(project)
        @test after["uuid"] == toml["uuid"]
        @test after["deps"] == merge(toml["deps"], Dict("Test" => stdlib_uuid("Test")))
        @test occursin("`Uses`:    added to deps: Test", out)
        @test read(joinpath(setups, "Helpers", "Project.toml"), String) == helpers
    end

    @testset "nothing is written unless every setup can be made a package" begin
        dir = make_pkg(
            "UnconvertibleSetups",
            "test/testsetups/Fine.jl" => "module Fine\nusing Random\nend\n",
            "test/testsetups/Unknown.jl" => "module Unknown\nusing NotInTheEnvironment\nend\n",
            "test/testsetups/Relative.jl" => "module Relative\ninclude(\"helpers.jl\")\nend\n",
            "test/testsetups/OwnFile.jl" => "module OwnFile\nconst F = @__FILE__\nend\n",
            "test/testsetups/Misnamed.jl" => "module SomethingElse\nend\n",
            "test/testsetups/Clash.jl" => "module Clash\nend\n",
            "test/testsetups/Clash/notes.txt" => "not a setup\n",
            "test/testsetups/Stale/src/Stale.jl" => "module Stale\nusing Random\nend\n",
            "test/testsetups/Stale/Project.toml" =>
                "name = \"Stale\"\n\n[deps]\nRandom = \"00000000-0000-0000-0000-000000000001\"\n",
            "test/testsetups/Renamed/src/Renamed.jl" => "module Renamed\nend\n",
            "test/testsetups/Renamed/Project.toml" => "name = \"Other\"\n",
            "test/testsetups/BadUuid/src/BadUuid.jl" => "module BadUuid\nend\n",
            "test/testsetups/BadUuid/Project.toml" => "name = \"BadUuid\"\nuuid = \"not-a-uuid\"\n",
            "test/testsetups/BadDep/src/BadDep.jl" => "module BadDep\nusing Random\nend\n",
            "test/testsetups/BadDep/Project.toml" => "name = \"BadDep\"\n\n[deps]\nRandom = \"not-a-uuid\"\n",
        )
        setups = joinpath(dir, "test", "testsetups")
        listing() = sort([relpath(joinpath(d, f), setups) for (d, _, fs) in walkdir(setups) for f in fs])
        before = listing()
        err = try
            Runtests.setups_to_packages(dir)
            nothing
        catch e
            e
        end
        @test err isa ConfigError
        msg = sprint(showerror, err)
        at(name) = joinpath("test", "testsetups", name)
        @test occursin("$(at("Unknown.jl")): imports `NotInTheEnvironment`, which neither", msg)
        @test occursin("$(at("Relative.jl")):2: `include` of a relative path", msg)
        @test occursin("$(at("OwnFile.jl")):2: `@__FILE__` would change with the move", msg)
        @test occursin("$(at("Misnamed.jl")): does not define `module Misnamed`", msg)
        @test occursin("$(at("Clash.jl")): `Clash/` is there as well", msg)
        @test occursin("$(at(joinpath("Stale", "Project.toml"))): lists `Random` as 00000000-0000-0000-0000-000000000001; " *
                       "it is $(stdlib_uuid("Random"))", msg)
        @test occursin("$(at(joinpath("Renamed", "Project.toml"))): names the package `Other`, not `Renamed`", msg)
        @test occursin("$(at(joinpath("BadUuid", "Project.toml"))): `uuid = \"not-a-uuid\"` is not a UUID", msg)
        @test occursin("$(at(joinpath("BadDep", "Project.toml"))): lists `Random` as \"not-a-uuid\", which is not a UUID", msg)
        @test !occursin("Fine", msg)
        @test listing() == before
        # A dry run of `chores` says the same, and returns rather than throws.
        dry, out = with_runstate_dir(_ -> capture_run(() -> Runtests.chores(dir; dry_run = true)))
        @test dry === false
        @test occursin("is not a UUID", out)
        @test listing() == before
    end

    @testset "a moved setup's `@__DIR__` becomes `pkgdir`, however it is written" begin
        relocated(code) = first(Runtests.Private.relocate(code, Meta.parseall(code), "S", "MyPkg"))
        # By the name the setup already gives the package.
        @test relocated("module S\nimport MyPkg as P\nconst D = @__DIR__\nend\n") ==
              "module S\nimport MyPkg as P\nconst D = pkgdir(P, \"test\", \"testsetups\")\nend\n"
        # The `".."`s fold as far as the package's root and no further.
        @test relocated("module S\nusing MyPkg\nf(x) = joinpath(@__DIR__, \"..\", \"..\", \"..\", x)\nend\n") ==
              "module S\nusing MyPkg\nf(x) = pkgdir(MyPkg, \"..\", x)\nend\n"
        # A call written over several lines.
        @test relocated("module S\nusing MyPkg\nf() = joinpath(\n    @__DIR__,\n    \"..\",\n    \"data\",\n)\nend\n") ==
              "module S\nusing MyPkg\nf() = pkgdir(MyPkg, \"test\",\n    \"data\",\n)\nend\n"
        # Inside an interpolation it is code. Without an import of the package, one is
        # added, indented as the module's body is.
        @test relocated("module S\n    p = \"\$(@__DIR__)/x\"\nend\n") ==
              "module S\n    import MyPkg\n    p = \"\$(pkgdir(MyPkg, \"test\", \"testsetups\"))/x\"\nend\n"
        # A body that goes on on the module's own line gets the import first in it,
        # inside the module; evaluated, the setup finds the directory it was in.
        for (code, expected) in (
                "module S; p = @__DIR__; end\n" => "module S; import MyPkg; p = pkgdir(MyPkg, \"test\", \"testsetups\"); end\n",
                "module S p = @__DIR__ end\n" => "module S; import MyPkg; p = pkgdir(MyPkg, \"test\", \"testsetups\") end\n",
            )
            @test relocated(code) == expected
            runtests = replace(code, "S" => "Setup")
            m = Module()
            Core.eval(m, Meta.parseall(first(Runtests.Private.relocate(runtests, Meta.parseall(runtests), "Setup", "Runtests"))))
            @test Core.eval(m, :(Setup.p)) == pkgdir(Runtests, "test", "testsetups")
        end
    end

    @testset "a relative include is found however it is spaced" begin
        hazards(code) = last(Runtests.Private.relocate(code, Meta.parseall(code), "S", "MyPkg"))
        for call in ("include(\"helper.jl\")", "include( \"helper.jl\")", "include(\n    \"helper.jl\",\n)")
            @test length(hazards("module S\n$call\nend\n")) == 1
        end
        @test isempty(hazards("module S\ninclude(\"/abs/helper.jl\")\nend\n"))
        @test isempty(hazards("module S\ninclude(joinpath(@__DIR__, \"helper.jl\"))\nend\n"))
    end

    @testset "every module a setup imports from outside is found" begin
        ex = Meta.parseall("""
        using A, B.C
        using D.E: f
        import G as H
        import I.J as K
        import L: m as n
        using .Relative, ..Parent
        @reexport using M
        module Inner
            using N
        end
        f() = @eval using O
        """)
        @test Runtests.Private.imported_roots(ex) == Set([:A, :B, :D, :G, :I, :L, :M, :N, :O])
    end

    @testset "a package without setups is left as it is" begin
        dir = make_pkg("NoSetups")
        _, out = capture_run(() -> Runtests.setups_to_packages(dir))
        @test occursin("no setups in $(joinpath("test", "testsetups"))", out)
        @test !ispath(joinpath(dir, "test", "testsetups"))
    end
end
@testset "profile preferences" begin
    @testset "a profile's preferences reach the items that run under it" begin
        dir = make_pkg("PrefProfile")
        # A package the test environment can see, which reads a preference when it
        # is compiled.
        pkgdir = joinpath(dir, "PrefTarget")
        mkpath(joinpath(pkgdir, "src"))
        u = "9f2b1c3d-0000-4000-8000-00000000abcd"
        write(joinpath(pkgdir, "Project.toml"),
              "name = \"PrefTarget\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n")
        write(joinpath(pkgdir, "src", "PrefTarget.jl"), """
        module PrefTarget
        const UUID = Base.UUID("$u")
        Base.record_compiletime_preference(UUID, "mode")
        const MODE = get(Base.get_preferences(UUID), "mode", "unset")
        end
        """)
        write(joinpath(dir, "prefs.toml"), "[PrefTarget]\nmode = \"fast\"\n")
        write(joinpath(dir, "test", "TestItems.toml"), """
        [profiles.tuned]
        preferences = "../prefs.toml"
        """)
        write(joinpath(dir, "test", "t_test.jl"), """
        @testitem "default sees no preference" begin
            using PrefTarget
            @test PrefTarget.MODE == "unset"
        end
        @testitem "tuned sees it" profile=:tuned begin
            using PrefTarget
            @test PrefTarget.MODE == "fast"
        end
        """)
        Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
        orig = Base.active_project()
        Pkg.activate(dir; io=devnull)
        Pkg.develop(path=pkgdir; io=devnull)
        Pkg.activate(orig; io=devnull)

        states, run, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
        @test states["default sees no preference"] === PASSED
        @test states["tuned sees it"] === PASSED
        # The tuned profile ran in a project of its own, carrying the same manifest.
        proj = run.profile_projects[findfirst(pr -> pr.name === :tuned && isempty(pr.environment), run.plan.profiles)]
        @test isfile(joinpath(proj, "Manifest.toml"))
        @test occursin("fast", read(joinpath(proj, "LocalPreferences.toml"), String))
        # Every package that manifest names is findable from where it now sits.
        for entries in values(Runtests.Private.TOML.parsefile(joinpath(proj, "Manifest.toml"))["deps"])
            for entry in entries
                haskey(entry, "path") && @test isdir(joinpath(proj, entry["path"]))
            end
        end
    end

    @testset "a setup is precompiled in the project of each profile that loads it" begin
        # The setup depends on a package that reads a preference when it is compiled. The
        # `tuned` profile's project holds another build of that package, and a cache of
        # the setup built against one build cannot be loaded with the other.
        dir = make_pkg("PrefSetup")
        pkgdir = joinpath(dir, "PrefSource")
        mkpath(joinpath(pkgdir, "src"))
        u = next_uuid()
        write(joinpath(pkgdir, "Project.toml"), "name = \"PrefSource\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n")
        write(joinpath(pkgdir, "src", "PrefSource.jl"), """
        module PrefSource
        const UUID = Base.UUID("$u")
        Base.record_compiletime_preference(UUID, "mode")
        const MODE = get(Base.get_preferences(UUID), "mode", "unset")
        end
        """)
        write(joinpath(dir, "prefs.toml"), "[PrefSource]\nmode = \"fast\"\n")
        write(joinpath(dir, "test", "TestItems.toml"), "[profiles.tuned]\npreferences = \"../prefs.toml\"\n")
        setup = string("Tuned", string(hash(dir); base=16))
        write_setup(dir, setup, "using PrefSource\nmode() = PrefSource.MODE"; deps = ["PrefSource" => u])
        write(joinpath(dir, "test", "t_test.jl"), """
        @testitem "default" begin
            @test Base.isprecompiled(Base.identify_package("$setup"))
            using $setup
            @test $setup.mode() == "unset"
        end
        @testitem "tuned" profile=:tuned begin
            @test Base.isprecompiled(Base.identify_package("$setup"))
            using $setup
            @test $setup.mode() == "fast"
        end
        """)
        Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
        orig = Base.active_project()
        Pkg.activate(dir; io=devnull)
        Pkg.develop(path=pkgdir; io=devnull)
        Pkg.activate(orig; io=devnull)
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["default"] === PASSED && states["tuned"] === PASSED
    end

    @testset "a profile's project finds every package the environment found" begin
        # The copy sits elsewhere than the environment it is taken from (here, a
        # directory below it), so a path written relative to the environment names
        # the wrong place from there — and Pkg writes a relative one for any package it reached through
        # another package's checkout, which is how a developed package is reached.
        base = mktempdir()
        env = joinpath(base, "env")
        outside = joinpath(base, "Outside")
        inside = joinpath(env, "Inside")
        foreach(mkpath, (env, outside, inside))
        write(joinpath(env, "Project.toml"), """
        [deps]
        Outside = "11111111-0000-4000-8000-000000000001"

        [sources]
        Outside = {path = "../Outside"}
        """)
        write(joinpath(env, "Manifest.toml"), """
        julia_version = "1.13.0"
        manifest_format = "2.0"
        project_hash = "6aba1e0a1b0ee9b0cb2b0b0e2d0e7e9f0a0b0c0d"

        [[deps.Outside]]
        uuid = "11111111-0000-4000-8000-000000000001"
        path = "../Outside"
        version = "0.1.0"

        [[deps.Inside]]
        uuid = "11111111-0000-4000-8000-000000000002"
        path = "Inside"
        version = "0.2.0"

        [[deps.Fixed]]
        uuid = "11111111-0000-4000-8000-000000000003"
        path = '$(base)'
        version = "0.3.0"

        [[deps.Itself]]
        uuid = "11111111-0000-4000-8000-000000000004"
        path = "."
        version = "0.4.0"
        """)
        dir = joinpath(env, "runtests_profile_tuned")
        mkpath(dir)
        Runtests.Private.copy_env_files(dir, env)

        manifest = Runtests.Private.TOML.parsefile(joinpath(dir, "Manifest.toml"))
        paths = Dict(name => only(entries)["path"] for (name, entries) in manifest["deps"])
        @test realpath(paths["Outside"]) == realpath(outside)
        @test realpath(paths["Inside"]) == realpath(inside)
        @test realpath(paths["Fixed"]) == realpath(base)
        @test realpath(paths["Itself"]) == realpath(env)
        # Read from the copy's own directory, which is what a worker does.
        @test all(p -> isdir(joinpath(dir, p)), values(paths))
        # An environment's own package is written `.`; the copy names a directory,
        # not a directory with a separator after it.
        @test !isdirpath(paths["Itself"])
        # Everything else crosses as it was, versions and the manifest's own keys.
        @test manifest["manifest_format"] == "2.0"
        @test manifest["julia_version"] == "1.13.0"
        @test manifest["project_hash"] == "6aba1e0a1b0ee9b0cb2b0b0e2d0e7e9f0a0b0c0d"
        @test only(manifest["deps"]["Inside"])["version"] == "0.2.0"
        @test only(manifest["deps"]["Inside"])["uuid"] ==
            "11111111-0000-4000-8000-000000000002"
        # A `[sources]` path is read relative to the project file, so it moves too.
        sources = Runtests.Private.TOML.parsefile(joinpath(dir, "Project.toml"))["sources"]
        @test realpath(sources["Outside"]["path"]) == realpath(outside)
    end

    @testset "a profile's project is never written into the package" begin
        # With `--project=test`, and in the editor, the environment is the package's
        # own `test/Project.toml`: its profile projects would land in `test/`.
        dir = make_pkg("PrefsOutside", "test/a_test.jl" => "@testitem \"x\" begin\nend\n",
                       "test/Project.toml" => "[deps]\n", "test/prefs.toml" => "[PrefsOutside]\nk = 1\n")
        before = readdir(joinpath(dir, "test"))
        prof = Runtests.Private.Profile(:tuned; preferences = joinpath(dir, "test", "prefs.toml"))
        proj = Runtests.Private.profile_project(prof, joinpath(dir, "test", "Project.toml"))
        @test !startswith(proj, dir)
        @test readdir(joinpath(dir, "test")) == before
        @test isfile(joinpath(proj, "Project.toml"))
        @test occursin("k = 1", read(joinpath(proj, "LocalPreferences.toml"), String))
        # One per environment and profile, and the same one each time.
        @test Runtests.Private.profile_project(prof, joinpath(dir, "test", "Project.toml")) == proj
        other = make_pkg("PrefsOutsideToo", "test/Project.toml" => "[deps]\n")
        @test Runtests.Private.profile_project(prof, joinpath(other, "test", "Project.toml")) != proj
    end

    @testset "a preferences file that is missing or broken is a config error" begin
        dir = make_pkg("BadPrefs", "test/t_test.jl" => """
        @testitem "x" begin
            @test true
        end
        """, "test/TestItems.toml" => "[profiles.p]\npreferences = \"nope.toml\"\n")
        @test_throws Runtests.ConfigError Runtests.Private.prepare((dir,); workers=1, monitor=false)
    end
end
