# The converter in skills/port-to-runtests: each shape of Test.jl suite it reads from
# runtests.jl, ported, gives a suite Runtests reads without a scan error, with the items,
# names, tags and setups the original's structure calls for.

using Runtests.Private: prepare, tags_of, PASSED

module PortScript
include(joinpath(dirname(@__DIR__), "skills", "port-to-runtests", "scripts", "port_testsets.jl"))
end

# A package whose tests may use Test and Random, as test dependencies.
function port_pkg(name, files...)
    pkg = make_pkg(name, files...)
    open(joinpath(pkg, "Project.toml"), "a") do io
        print(io, """

            [extras]
            Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

            [targets]
            test = ["Random", "Test"]
            """)
    end
    return pkg
end

# Port `pkg`'s suite in place, as an agent applies the converter's list: each file it
# moved is gone from where it was. What the converter printed.
function port!(pkg)
    testdir = joinpath(pkg, "test")
    out = mktemp() do path, io
        redirect_stdout(io) do
            PortScript.port_suite(testdir)
        end
        close(io)
        read(path, String)
    end
    for line in split(out, '\n')
        m = match(r"^moved (.+) -> (.+)$", line)
        m === nothing || m[1] == "runtests.jl" || rm(joinpath(testdir, m[1]))
    end
    return out
end

# The suite as a run reads it: item name => (tags, skip).
function ported_items(pkg)
    p, _ = prepare((pkg,); announce = false)
    return Dict(p.items.name[i] => (collect(tags_of(p.items, i)), p.items.skip[i]) for i in eachindex(p.items.name))
end

@testset "port_testsets.jl" begin
    @testset "included files: their testsets are items, and runtests.jl's imports reach items and setups" begin
        pkg = port_pkg("PortIncluded",
            "test/runtests.jl" => """
                using Test, PortIncluded
                using Random
                include("helpers.jl")
                const SCALE = 2
                @testset "PortIncluded" begin
                    include("parsing.jl")
                    include("test_writing.jl")
                end
                """,
            "test/helpers.jl" => "twice(x) = 2x\n",
            "test/bench.jl" => "println(twice(1))\n",
            "test/parsing.jl" => """
                const DATA = [1, 2]
                @testset "basics" begin
                    @test twice(DATA[1]) == 2
                end
                @testset "random" begin
                    @test length(randstring(3)) == 3
                end
                """,
            "test/test_writing.jl" => """
                @testset "basics" begin
                    @test twice(3) == 3SCALE
                end
                """)
        out = port!(pkg)
        @test occursin("moved parsing.jl -> parsing_tests.jl", out)
        @test occursin("moved test_writing.jl -> writing_tests.jl", out)
        @test occursin("moved helpers.jl -> testsetups/HelpersSetup.jl", out)
        # Nothing ran it, and where it was it would stop a run.
        @test occursin("moved bench.jl -> .scripts/bench.jl", out)
        @test isfile(joinpath(pkg, "test", ".scripts", "bench.jl"))
        @test read(joinpath(pkg, "test", "runtests.jl"), String) == "using Runtests\nRuntests.runtests()\n"
        # The setup of the file's definitions sees what runtests.jl imported, as the file did.
        @test occursin("using Random", read(joinpath(pkg, "test", "testsetups", "ParsingSetup.jl"), String))
        items = ported_items(pkg)
        @test sort!(collect(keys(items))) == ["parsing: basics", "random", "writing: basics"]
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
        end
    end

    @testset "SafeTestsets: a file of bare tests is one item, named for its @safetestset" begin
        pkg = port_pkg("PortSafe",
            "test/runtests.jl" => """
                using SafeTestsets
                const x = 5
                @safetestset "Quadrature" include("quad.jl")
                @safetestset "Interpolation" begin include("interp.jl") end
                @safetestset "Checks" include("checks.jl")
                include("group.jl")
                """,
            # A file that only runs others is read as runtests.jl is.
            "test/group.jl" => "using SafeTestsets\n@safetestset \"Sub\" include(\"sub_item.jl\")\n",
            "test/sub_item.jl" => "using Test\n@testset \"sub\" begin\n    @test true\nend\n",
            # `@safetestset` imported Test for the file, and its helper's `@test` relied on it.
            "test/checks.jl" => """
                check(x) = @test x > 0
                @testset "positive" begin
                    check(1)
                end
                @testset "also positive" begin
                    check(2)
                end
                """,
            "test/quad.jl" => "using Test\nx = 2\n@test x + x == 4\ny = x * 3\n@test y == 6\n",
            "test/interp.jl" => """
                using Test
                @testset "linear" begin
                    @test true
                end
                @testset "cubic" begin
                    @test true
                end
                """)
        out = port!(pkg)
        @test occursin("the file is one item, \"Quadrature\", as it ran", out)
        @test occursin("moved group.jl -> .scripts/group.jl", out)
        items = ported_items(pkg)
        @test sort!(collect(keys(items))) == ["Quadrature", "also positive", "cubic", "linear", "positive", "sub"]
        # Ported whole, quad.jl keeps its order and needs no setup; runtests.jl's `x`
        # was out of its reach.
        @test readdir(joinpath(pkg, "test", "testsetups")) == ["ChecksSetup.jl"]
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
        end
    end

    @testset "GROUP: files under a group are tagged with it, and those that did not run by default still do not" begin
        pkg = port_pkg("PortGroups",
            "test/runtests.jl" => """
                using Test
                const GROUP = get(ENV, "GROUP", "All")
                prepare_gpu() = error("not here")
                if GROUP == "All" || GROUP == "Core"
                    include("core.jl")
                end
                if GROUP == "GPU"
                    prepare_gpu()
                    include("gpu.jl")
                end
                if GROUP == "QA"
                    include("qa/qa.jl")
                end
                if GROUP == "2D"
                    include("twod.jl")
                end
                """,
            "test/twod.jl" => "@testset \"2d\" begin\n    @test true\nend\n",
            "test/core.jl" => "@testset \"core\" begin\n    @test true\nend\n",
            "test/gpu.jl" => "@testset \"gpu\" begin\n    @test true\nend\n",
            "test/qa/Project.toml" => "[deps]\n",
            "test/qa/qa.jl" => "run_qa(PortGroups)\n")
        out = port!(pkg)
        items = ported_items(pkg)
        @test first(items["core"]) == [:core] && first(items["gpu"]) == [:gpu]
        # A tag is a name: GROUP=2D selects `:_2d`.
        @test first(items["2d"]) == [:_2d]
        runtests = read(joinpath(pkg, "test", "runtests.jl"), String)
        @test occursin("isempty(group) || group == \"all\" ? \"!gpu && !_2d\" : Symbol(replace(group, ", runtests)
        # GROUP only picked the files, and `prepare_gpu()` prepared their run: no item needs them.
        @test occursin("runtests.jl runs code that is not a test, which nothing ports: prepare_gpu()", out)
        @test occursin("runtests.jl defines GROUP, prepare_gpu, which no test uses: dropped", out)
        @test !isdir(joinpath(pkg, "test", "testsetups"))
        # What ran in an environment of its own stays there, as it was.
        @test occursin("test/qa/ is an environment of its own, where qa/qa.jl ran", out)
        @test isfile(joinpath(pkg, "test", "qa", "qa.jl"))
    end

    @testset "runtests.jl's own tests are a file and items named for the package; a condition on the platform is a skip" begin
        pkg = port_pkg("PortOwn",
            "test/runtests.jl" => """
                using Test, PortOwn
                @test 1 + 1 == 2
                @testset "own" begin
                    @test true
                end
                const REGIONS = ["asia", "europe"]
                tables = Dict{String, Int}()
                for r in REGIONS
                    tables[r] = length(r)
                end
                include("tables.jl")
                if Sys.iswindows()
                    include("win.jl")
                end
                """,
            "test/tables.jl" => "@testset \"tables\" begin\n    @test tables[\"asia\"] == 4\nend\n",
            "test/win.jl" => "@testset \"windows only\" begin\n    @test true\nend\n")
        out = port!(pkg)
        @test occursin("moved runtests.jl -> port_own_tests.jl", out)
        items = ported_items(pkg)
        @test haskey(items, "own") && haskey(items, "PortOwn")
        @test last(items["windows only"]) == :(!(Sys.iswindows()))
        # The loop filled what a test reads: it is the suite's, in runtests.jl's setup.
        @test occursin("tables[r] = length(r)", read(joinpath(pkg, "test", "testsetups", "PortOwnSetup.jl"), String))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test states["tables"] == states["own"] == states["PortOwn"] == PASSED
        end
    end

    @testset "SciMLTesting folders: Core files, a group's folder tagged, a group with an environment of its own left alone" begin
        pkg = port_pkg("PortSciML",
            "test/runtests.jl" => "using SciMLTesting\nrun_tests()\n",
            "test/test_groups.toml" => "[Core]\n\n[Interface]\nin_all = false\n\n[QA]\n",
            "test/basic_tests.jl" => "@testset \"basic\" begin\n    @test true\nend\n",
            "test/Interface/iface.jl" => "@testset \"iface\" begin\n    @test true\nend\n",
            "test/qa/Project.toml" => "[deps]\n",
            "test/qa/qa.jl" => "@test true\n")
        out = port!(pkg)
        @test occursin("group QA runs in an environment of its own", out)
        items = ported_items(pkg)
        @test first(items["basic"]) == Symbol[] && first(items["iface"]) == [:interface]
        @test occursin("\"!interface\"", read(joinpath(pkg, "test", "runtests.jl"), String))
    end

    @testset "tests between the code they need: the file is one item, and a test macro is no definition" begin
        pkg = port_pkg("PortMixed",
            "test/runtests.jl" => "using Test\ninclude(\"mixed.jl\")\n",
            "test/mixed.jl" => "A = [1, 2]\n@test_throws BoundsError A[3]\nB = copy(A)\n@test B == A\n")
        out = port!(pkg)
        items = ported_items(pkg)
        @test collect(keys(items)) == ["mixed"]
        @test !isdir(joinpath(pkg, "test", "testsetups"))
        @test occursin("@test_throws BoundsError A[3]", read(joinpath(pkg, "test", "mixed_tests.jl"), String))
    end

    @testset "a testset of testsets is taken apart, one that defines something stays whole; bodies keep their scope" begin
        pkg = port_pkg("PortWrappers",
            "test/runtests.jl" => "using Test\ninclude(\"wrapped.jl\")\n",
            "test/wrapped.jl" => """
                const BASE = 10   # what every check adds
                @testset "first" begin
                    x = 1
                    @testset "a" begin
                        @test x + BASE == 11
                    end
                    @testset "b" begin
                        @test x == 1
                    end
                end
                @testset "second" begin
                    x = 2
                    @testset "c" begin
                        @test x + BASE == 12
                    end
                end
                @testset "outer" begin
                    @testset "d" begin
                        @test true
                    end
                    @testset "e" begin
                        @test true
                    end
                end
                @testset "a local for a block to assign" begin
                    local y
                    try
                        y = 3
                    finally
                    end
                    @test y == 3
                end
                @testset verbose = true "after a semicolon" begin
                    @test true
                end;
                #= generated =# @testset "after a block comment" begin
                    @test true
                end
                @testset "a function that updates a variable of the testset" begin
                    counter = 0
                    bump() = (counter += 1)
                    bump(); bump()
                    @test counter == 2
                end
                """)
        port!(pkg)
        @test sort!(collect(keys(ported_items(pkg)))) ==
            ["a function that updates a variable of the testset", "a local for a block to assign", "after a block comment",
             "after a semicolon", "d", "e", "first", "second"]
        setup = read(joinpath(pkg, "test", "testsetups", "WrappedSetup.jl"), String)
        @test occursin("const BASE = 10   # what every check adds\n", setup)
        @test !occursin("x = ", setup)
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
        end
    end

    @testset "`using .Bar` after `module Bar`: in a setup, and in an item that is the whole file" begin
        pkg = port_pkg("PortRelative",
            "test/runtests.jl" => "using Test\ninclude(\"split.jl\")\ninclude(\"whole.jl\")\n",
            "test/split.jl" => """
                module Bar
                export h
                h() = 1
                end
                using .Bar
                @testset "split a" begin
                    @test h() == 1
                end
                @testset "split b" begin
                    @test Bar.h() == 1
                end
                """,
            "test/whole.jl" => """
                module Baz
                export k
                k() = 2
                end
                using .Baz
                x = k()
                @test x == 2
                y = x + 1
                @test y == 3
                """)
        port!(pkg)
        @test sort!(collect(keys(ported_items(pkg)))) == ["split a", "split b", "whole"]
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
        end
    end

    @testset "a call given `@__MODULE__` runs in each item, the module its tests run in" begin
        pkg = port_pkg("PortModule",
            "test/runtests.jl" => "using Test\ninclude(\"mod.jl\")\n",
            "test/mod.jl" => """
                const REGISTERED = Module[]
                register!(m) = push!(REGISTERED, m)
                register!(@__MODULE__)
                @testset "registered" begin
                    @test @__MODULE__() in REGISTERED
                end
                @testset "registered too" begin
                    @test @__MODULE__() in REGISTERED
                end
                """)
        port!(pkg)
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test sort!(collect(keys(states))) == ["registered", "registered too"]
            @test all(==(PASSED), values(states))
        end
    end

    @testset "files from a loop, a computed list and a function that includes; a helper included in a testset" begin
        pkg = port_pkg("PortLists",
            "test/runtests.jl" => """
                using Test
                is_test(f) = startswith(f, "t_") && endswith(f, ".jl")
                for f in filter(is_test, readdir(@__DIR__))
                    include(f)
                end
                addtests(f) = include(f)
                addtests("extra.jl")
                for name in ["listed"]
                    include("\$name.jl")
                end
                @testset "\$file" for file in sort([file for file in readdir(@__DIR__) if match(r"^u_.*\\.jl\$", file) !== nothing])
                    include(file)
                end
                """,
            "test/u_two.jl" => "@testset \"two\" begin\n    @test true\nend\n",
            "test/t_one.jl" => "@testset \"one\" begin\n    include(\"fixture.jl\")\n    @test FIX == length(randstring(1))\nend\n",
            "test/fixture.jl" => "using Random\nconst FIX = 1\n",
            "test/extra.jl" => "@testset \"extra\" begin\n    @test true\nend\n",
            "test/listed.jl" => "@testset \"listed\" begin\n    @test true\nend\n")
        out = port!(pkg)
        @test occursin("moved fixture.jl -> testsetups/FixtureSetup.jl", out)
        items = ported_items(pkg)
        @test issubset(["one", "extra", "listed", "two"], keys(items))
        one = read(joinpath(pkg, "test", "t_one_tests.jl"), String)
        @test occursin("using FixtureSetup\n", one) && !occursin("include(\"fixture.jl\")", one)
        # What the helper imported was in the testset's reach; the setup's `using` does not pass it on.
        @test occursin("    using Random\n", one)
        # The predicate only picked the files.
        @test readdir(joinpath(pkg, "test", "testsetups")) == ["FixtureSetup.jl"]
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            states, _, _ = run_states(pkg; workers = 1, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
        end
    end

    @testset "ParallelTestRunner: every file under test/ is run, each on its own" begin
        pkg = port_pkg("PortParallel",
            "test/runtests.jl" => """
                using PortParallel
                using ParallelTestRunner
                testsuite = find_tests(pwd())
                runtests(PortParallel, ARGS; testsuite)
                """,
            # A file of tests in a module of its own is a file of tests.
            "test/alpha.jl" => "module AlphaTests\nusing Test\n@testset \"alpha\" begin\n    @test true\nend\nend\n",
            "test/sub/beta.jl" => "using Test\n@testset \"beta\" begin\n    @test true\nend\n",
            # Even with no testset in it.
            "test/gamma.jl" => "module GammaTests\nusing Test\nx = 1\n@test x == 1\n@test x + 1 == 2\nend\n")
        port!(pkg)
        @test sort!(collect(keys(ported_items(pkg)))) == ["alpha", "beta", "gamma"]
    end
end
