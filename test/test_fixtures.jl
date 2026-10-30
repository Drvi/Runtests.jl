# The fixture boundary. `test/testfixtures/` holds input to the suite's tests, which
# the suite itself never reads; every other directory under `test/` with a project of
# its own is a profile's environment, or an error.

using Runtests.Private: prepare, walk_test_dir, list_items, find_item, resolve_target, read_config, Plan,
    Profile, init_run_state, finish_run_state!, ScanFailure, ConfigError, NoTestsError, PASSED

# A suite with one item of its own and a `test/testfixtures/` full of what the suite
# must not read: a package with tests, a template and a setup of its own; a project
# and a test file that do not parse; a loose Julia file; data; and an item with the
# suite's own item's name.
function fixtured_pkg(name::AbstractString, files::Pair{<:AbstractString, <:AbstractString}...)
    inner = name * "Inner"
    return make_pkg(
        name,
        "test/a_tests.jl" => "@testitem \"main\" begin\n    @test true\nend\n",
        "test/testfixtures/Inner/Project.toml" => "name = \"$inner\"\nuuid = \"$(next_uuid())\"\n",
        "test/testfixtures/Inner/src/$inner.jl" => "module $inner\nanswer() = 42\nend\n",
        "test/testfixtures/Inner/test/inner_tests.jl" =>
            "@testitem \"inner\" begin\n    using InnerSetup\n    @test $inner.answer() == InnerSetup.expected\nend\n",
        "test/testfixtures/Inner/test/testsetups/InnerSetup.jl" => "module InnerSetup\nconst expected = 42\nend\n",
        "test/testfixtures/templated/test/testtemplates/x_tests_template.jl" =>
            "@testtemplate \"x \$n\" for n in 1:2\n    @test true\nend\n",
        "test/testfixtures/broken/Project.toml" => "this is = = not toml\n",
        "test/testfixtures/broken/bad_tests.jl" => "@testitem \"broken\" begin\n",
        "test/testfixtures/loose.jl" => "x = \n",
        "test/testfixtures/reference.csv" => "a,b\n1,2\n",
        "test/testfixtures/main_tests.jl" => "@testitem \"main\" begin\nend\n",
        files...,
    )
end

fx_plan(dir; kwargs...) = first(prepare((dir,); announce = false, kwargs...))

# What `f` throws, or `nothing`.
function fx_thrown(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

fx_message(f) = (e = fx_thrown(f); e === nothing ? "" : sprint(showerror, e))

# Every file under `dir` with what it holds, to tell that nothing changed it.
function fx_snapshot(dir::AbstractString)
    out = Dict{String, Vector{UInt8}}()
    for (root, _, files) in walkdir(dir), f in files
        path = joinpath(root, f)
        out[relpath(path, dir)] = read(path)
    end
    return out
end

@testset "fixtures" begin
    withenv("RUNTESTS_GROUP" => nothing) do; with_runstate_dir() do states

    dir = fixtured_pkg("FxSuite")
    fixtures = joinpath(dir, "test", "testfixtures")
    before = fx_snapshot(fixtures)

    @testset "the suite never reads them" begin
        walked = walk_test_dir(joinpath(dir, "test"))
        @test walked.tests == [joinpath(dir, "test", "a_tests.jl")]
        @test isempty(walked.strays) && isempty(walked.templates)
        @test fx_plan(dir).items.name == ["main"]
    end

    @testset "a run, a dry run, the editor, chores, debug and a replay agree" begin
        states_ = first(first(capture_run(() -> run_states(dir; workers = 0, monitor = false))))
        @test states_ == Dict("main" => PASSED)
        _, dry = capture_run(() -> Runtests.runtests(dir; dry_run = true, name = "main"))
        @test occursin("1 test item in 1 file", dry)
        @test fx_plan(joinpath(dir, "test", "a_tests.jl")).items.name == ["main"]
        listed = list_items(dir)
        @test [it.name for it in listed.items] == ["main"]
        @test isempty(listed.errors)
        ok, out = capture_run(() -> Runtests.chores(dir; dry_run = true))
        @test ok === true
        @test occursin("test items: 1 in 1 file, all valid", out)
        target = resolve_target((dir,))
        @test find_item(target, "main").file == joinpath(dir, "test", "a_tests.jl")
        @test fx_thrown(() -> find_item(target, "inner")) isa NoTestsError
        recorded = joinpath(states, "fixtures.runstate")
        finish_run_state!(init_run_state(recorded, fx_plan(dir)))
        @test fx_plan(dir; replay = recorded).items.name == ["main"]
    end

    @testset "chores leaves them as they are" begin
        ok, _ = capture_run(() -> Runtests.chores(dir))
        @test ok === true
        @test fx_snapshot(fixtures) == before
    end

    @testset "what is in them is refused as part of the suite's selection" begin
        for path in (fixtures, joinpath(fixtures, "reference.csv"), joinpath(fixtures, "main_tests.jl"),
                     joinpath(fixtures, "broken", "bad_tests.jl"))
            e = fx_thrown(() -> fx_plan(path))
            @test e isa ArgumentError
            @test occursin("which holds input for the tests and is not read as part of the suite", sprint(showerror, e))
        end
        # A path of the suite's and a path of a package kept there: one call runs one
        # package's tests, whichever comes first.
        mine = joinpath(dir, "test", "a_tests.jl")
        theirs = joinpath(fixtures, "Inner", "test", "inner_tests.jl")
        for args in ((mine, theirs), (theirs, mine))
            e = fx_thrown(() -> prepare(args; announce = false))
            @test e isa ArgumentError
            @test occursin("belongs to the package at", sprint(showerror, e))
        end
        @test fx_snapshot(fixtures) == before
    end

    @testset "a package kept there runs as a suite of its own" begin
        inner = joinpath(fixtures, "Inner")
        @test resolve_target((joinpath(inner, "test", "inner_tests.jl"),)).root == inner
        states_ = first(first(capture_run(() -> run_states(inner; workers = 0, monitor = false))))
        @test states_ == Dict("inner" => PASSED)
    end

    @testset "a nested project nothing names is an error, wherever it is and whatever it holds" begin
        unnamed(rel) = "$(joinpath("test", rel)) has an environment of its own, which no profile names"
        for (rel, file) in (("qa", "Project.toml"), ("tools", "JuliaProject.toml"),
                            # A package is held to it too: it is not a suite of its own here.
                            (joinpath("packages", "Pkg"), "Project.toml"),
                            # Only the `testfixtures` at the top of `test/` is reserved.
                            (joinpath("sub", "testfixtures"), "Project.toml"))
            bad = fixtured_pkg("FxNested", "test/$rel/$file" => "name = \"Nested\"\n")
            e = fx_thrown(() -> fx_plan(bad))
            @test e isa ScanFailure
            @test only(e.errors).file == joinpath(bad, "test", rel, file)
            @test occursin(unnamed(rel), only(e.errors).msg)
            @test occursin("`environment = $(repr(rel))`", only(e.errors).msg)
            @test occursin("move it under `test/testfixtures/`", only(e.errors).msg)
            # The editor shows the items it can read beside the problem.
            listed = list_items(bad)
            @test [it.name for it in listed.items] == ["main"]
            @test [e.file for e in listed.errors] == [joinpath(bad, "test", rel, file)]
        end
        deeper = fixtured_pkg("FxDeeper", "test/sub/testfixtures/deep_tests.jl" => "@testitem \"deep\" begin\nend\n")
        @test sort(fx_plan(deeper).items.name) == ["deep", "main"]
    end

    @testset "the test environment, setups and hidden directories hold projects of their own" begin
        for files in (("test/Project.toml" => "[deps]\n",), ("test/JuliaProject.toml" => "[deps]\n",),
                      ("test/testsetups/S/Project.toml" => "name = \"S\"\nuuid = \"$(next_uuid())\"\n",
                       "test/testsetups/S/src/S.jl" => "module S end\n"),
                      ("test/.cache/Project.toml" => "[deps]\n",))
            @test fx_plan(fixtured_pkg("FxAllowed", files...)).items.name == ["main"]
        end
    end

    @testset "a profile's environment is never in reserved storage, nor the suite itself" begin
        claims = fixtured_pkg(
            "FxClaims",
            "test/testsetups/S/Project.toml" => "[deps]\n",
            "test/testtemplates/env/Project.toml" => "[deps]\n",
            "test/Project.toml" => "[deps]\n",
            "envs/ext/Project.toml" => "[deps]\n",
            "envs/ext/ext_tests.jl" => "@testitem \"ext\" begin\nend\n",
        )
        testdir = joinpath(claims, "test")
        config(text) = write(joinpath(testdir, "TestItems.toml"), "[profiles.p]\nenvironment = $(repr(text))\n")
        for (text, why) in ("testfixtures/Inner" => "kept for input to the tests",
                            # However it is spelled.
                            "qa/../testfixtures/Inner" => "kept for input to the tests",
                            "testsetups/S" => "kept for the suite's test setups",
                            "testtemplates/env" => "kept for the suite's test templates",
                            "." => "which holds the whole suite",
                            ".." => "which holds the whole suite")
            config(text)
            for f in (() -> read_config(testdir), () -> fx_plan(claims), () -> list_items(claims).errors)
                got = fx_thrown(f)
                msg = got isa Exception ? sprint(showerror, got) : join((e.message for e in f()), "\n")
                @test occursin(why, msg)
            end
        end
        # A config file elsewhere is read relative to itself, and the reserved
        # directories are still the suite's.
        ci = mkpath(joinpath(claims, "ci"))
        write(joinpath(ci, "TestItems.toml"), "[profiles.p]\nenvironment = \"../test/testfixtures/Inner\"\n")
        rm(joinpath(testdir, "TestItems.toml"))
        e = fx_thrown(() -> fx_plan(claims; config = joinpath(ci, "TestItems.toml")))
        @test e isa ConfigError && occursin("kept for input to the tests", sprint(showerror, e))
        # An environment outside the suite is a profile's, and the suite is still what
        # is read: its own tests are not.
        config("../envs/ext")
        @test fx_plan(claims).items.name == ["main"]
        @test read_config(testdir).profiles[:p].environment == joinpath(claims, "envs", "ext")
    end

    @testset "a link to a directory is not followed" begin
        if !Sys.iswindows()
            linked = fixtured_pkg("FxLinked")
            symlink(joinpath(linked, "test", "testfixtures", "Inner"), joinpath(linked, "test", "inner"))
            @test fx_plan(linked).items.name == ["main"]
        end
    end

    @testset "a replay's profiles are held to the same" begin
        replayed = fixtured_pkg("FxReplay", "test/qa/Project.toml" => "[deps]\n",
                                "test/TestItems.toml" => "[profiles.qa]\nenvironment = \"qa\"\n")
        recorded = joinpath(states, "replayed.runstate")
        finish_run_state!(init_run_state(recorded, fx_plan(replayed)))
        # A directory this checkout gives another profile is two profiles' at once.
        write(joinpath(replayed, "test", "TestItems.toml"), "[profiles.other]\nenvironment = \"qa\"\n")
        msg = fx_message(() -> fx_plan(replayed; replay = recorded))
        @test occursin("is the `environment` of both [profiles.other] and [profiles.qa]", msg)
        # A recorded profile whose environment is in reserved storage, as no config
        # file of this version could have declared it.
        write(joinpath(replayed, "test", "TestItems.toml"), "[profiles.qa]\nenvironment = \"qa\"\n")
        p = fx_plan(replayed)
        profiles = [prof.name === :qa ? Profile(:qa; environment = joinpath(replayed, "test", "testfixtures", "Inner")) : prof
                    for prof in p.profiles]
        forged = Plan((f === :profiles ? profiles : getfield(p, f) for f in fieldnames(Plan))...)
        finish_run_state!(init_run_state(recorded, forged))
        msg = fx_message(() -> fx_plan(replayed; replay = recorded))
        @test occursin("kept for input to the tests", msg)
        @test occursin("the run state's profiles", msg)
    end

    end; end
end
