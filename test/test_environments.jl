# Profiles that name an environment. A directory under `test/` with a Project.toml of
# its own is read only when a profile names it as its `environment`; its items then
# run under that profile, in a copy of that environment with the package under test
# added by path, and a directory no profile names is reported as tests not run.

using Runtests.Private: prepare, nitems, read_config, claimed_environments, config_toml, ConfigError,
    ScanFailure, NoTestsError, environment_project, write_environment, replayed_config, read_run_state,
    runstate_files, failing_items, suite_item_names, resolve_target, list_items, Profile, PASSED, FAILED
using RuntestsWorkers: state_of
using Runtests.Private: TOML

"""
    env_pkg(name, "test/x_test.jl" => content, ...) -> dir

A package that takes a sibling, `<name>Core` under `lib/`, by `[sources]`, as a package
of a monorepo does; and `test/qa`, an environment of its own holding `<name>Tools`, a
package the package under test does not depend on, which `[profiles.qa]` names.
"""
function env_pkg(name::AbstractString, files::Pair{<:AbstractString, <:AbstractString}...)
    core, tools = name * "Core", name * "Tools"
    ucore, utools = next_uuid(), next_uuid()
    dir = make_pkg(
        name,
        "lib/$core/Project.toml" => "name = \"$core\"\nuuid = \"$ucore\"\nversion = \"0.1.0\"\n",
        "lib/$core/src/$core.jl" => "module $core\none_more(x) = x + 1\nend\n",
        "deps/$tools/Project.toml" => "name = \"$tools\"\nuuid = \"$utools\"\nversion = \"0.1.0\"\n",
        "deps/$tools/src/$tools.jl" => "module $tools\nmarker() = :tools\nend\n",
        "src/$name.jl" => "module $name\nusing $core\ndouble(x) = 2 * $core.one_more(x)\nend\n",
        "test/qa/Project.toml" => "[deps]\n$tools = \"$utools\"\n\n[sources]\n$tools = {path = \"../../deps/$tools\"}\n",
        "test/TestItems.toml" => "[profiles.qa]\nenvironment = \"qa\"\n",
        files...,
    )
    open(joinpath(dir, "Project.toml"), "a") do io
        print(io, "\n[deps]\n$core = \"$ucore\"\n\n[sources]\n$core = {path = \"lib/$core\"}\n")
    end
    return dir
end

uuid_of(project_dir) = TOML.parsefile(joinpath(project_dir, "Project.toml"))["uuid"]

# Each item's profile and whether it has a process of its own, by name.
function profiles_of(p)
    return Dict(p.items.name[i] => (p.profiles[p.units.profile[p.items.unit[i]]].name, p.units.exclusive[p.items.unit[i]])
                for i in 1:nitems(p))
end

plan_of(dir; kwargs...) = first(prepare((dir,); announce = false, kwargs...))

# The message of what `f` throws, or "" when it throws nothing.
message_of(f) = try
    f()
    ""
catch e
    sprint(showerror, e)
end

const QA_ITEMS = """
@testitem "qa sees its environment" begin
    using EnvRunTools
    @test EnvRunTools.marker() === :tools
    # The package under test, and the sibling it takes by `[sources]`.
    @test EnvRun.double(1) == 4
    @test Main.RuntestsWorkers.current_testitem().profile === :qa
end

@testitem "qa fails" begin
    @test false
end
"""

@testset "environments" begin
    # Run states go to a directory of this file's, not to the depot.
    withenv("RUNTESTS_GROUP" => nothing) do; with_runstate_dir() do _

    @testset "the `environment` setting" begin
        dir = env_pkg("EnvConfig", "test/qa/qa_tests.jl" => "")
        qa = joinpath(dir, "test", "qa")
        cfg(text) = (write(joinpath(dir, "test", "TestItems.toml"), text); read_config(joinpath(dir, "test")))

        @testset "relative to the config file's directory, however it is written" begin
            for text in ("qa", "qa/", "./qa", "qa/../qa", qa, qa * "/")
                @test cfg("[profiles.qa]\nenvironment = $(repr(text))\n").profiles[:qa].environment == qa
            end
            # A profile without one, and one that names none, run in the test environment.
            @test cfg("[profiles.qa]\nthreads = \"1\"\n").profiles[:qa].environment == ""
            @test cfg("[profiles.qa]\nenvironment = \"\"\n").profiles[:qa].environment == ""
        end

        @testset "a JuliaProject.toml is a project file too" begin
            other = joinpath(dir, "test", "other")
            mkpath(other)
            write(joinpath(other, "JuliaProject.toml"), "[deps]\n")
            @test cfg("[profiles.other]\nenvironment = \"other\"\n").profiles[:other].environment == other
        end

        @testset "what is not an environment is a config error that says why" begin
            for (text, why) in (
                    "environment = \"nowhere\"" => "which is not a directory",
                    "environment = \"qa/qa_tests.jl\"" => "which is not a directory",
                    "environment = \"../src\"" => "has no Project.toml",
                    "environment = 1" => "must be the path of a directory with a Project.toml",
                    "environment = [\"qa\"]" => "must be the path of a directory with a Project.toml",
                )
                msg = message_of(() -> cfg("[profiles.qa]\n$text\n"))
                @test occursin(why, msg)
                @test occursin("`environment` of [profiles.qa]", msg)
            end
        end

        @testset "a directory is one profile's environment, and never the default profile's" begin
            msg = message_of(() -> cfg("[profiles.default]\nenvironment = \"qa\"\n"))
            @test occursin("the default profile's workers run in the test environment", msg)
            # However the two spell it.
            msg = message_of(() -> cfg("[profiles.a]\nenvironment = \"qa\"\n[profiles.b]\nenvironment = \"./qa/\"\n"))
            @test occursin("is the `environment` of both [profiles.a] and [profiles.b]", msg)
            # Reading the test files checks the same, before the rest of the settings.
            write(joinpath(dir, "test", "TestItems.toml"), "[profiles.a]\nenvironment = \"qa\"\n[profiles.b]\nenvironment = \"qa\"\n")
            @test_throws ConfigError claimed_environments(config_toml(joinpath(dir, "test"), nothing)...)
            @test_throws ConfigError plan_of(dir)
        end

        @testset "the directories profiles name, and nothing else, are claimed" begin
            write(joinpath(dir, "test", "TestItems.toml"),
                  "[profiles.qa]\nenvironment = \"qa\"\n[profiles.fast]\nthreads = \"1\"\n")
            @test claimed_environments(config_toml(joinpath(dir, "test"), nothing)...) == Dict(qa => :qa)
            rm(joinpath(dir, "test", "TestItems.toml"))
            @test isempty(claimed_environments(config_toml(joinpath(dir, "test"), nothing)...))
        end

        @testset "a config file elsewhere names an environment relative to itself" begin
            elsewhere = joinpath(dir, "ci")
            mkpath(joinpath(elsewhere, "env"))
            write(joinpath(elsewhere, "env", "Project.toml"), "[deps]\n")
            write(joinpath(elsewhere, "TestItems.toml"), "[profiles.ci]\nenvironment = \"env\"\n")
            c = read_config(joinpath(dir, "test"); config = joinpath(elsewhere, "TestItems.toml"))
            @test c.profiles[:ci].environment == joinpath(elsewhere, "env")
        end
    end

    @testset "reading the test files" begin
        dir = env_pkg(
            "EnvRead",
            "test/main_tests.jl" => """
            @testitem "main" begin
            end
            @testitem "main opts in" sandbox=:qa begin
            end
            """,
            "test/qa/qa_tests.jl" => """
            @testitem "qa plain" begin
            end
            @testitem "qa alone" sandbox=true begin
            end
            @testitem "qa names its own profile" sandbox=:qa begin
            end
            """,
            "test/qa/sub/deeper_tests.jl" => """
            @testitem "qa deeper" begin
            end
            """,
        )

        @testset "an item in the environment's directory runs under its profile, wherever below it" begin
            byname = profiles_of(plan_of(dir))
            @test byname["main"] == (:default, false)
            @test byname["main opts in"] == (:qa, false)
            @test byname["qa plain"] == (:qa, false)
            @test byname["qa alone"] == (:qa, true)
            @test byname["qa names its own profile"] == (:qa, false)
            @test byname["qa deeper"] == (:qa, false)
        end

        @testset "every entry point reads the environment's items" begin
            target = resolve_target((dir,))
            @test suite_item_names(target) ==
                Set(["main", "main opts in", "qa plain", "qa alone", "qa names its own profile", "qa deeper"])
            listed = Dict(it.name => it for it in list_items(dir).items)
            @test (listed["qa plain"].profile, listed["qa plain"].sandbox) == ("qa", true)
            @test (listed["main"].profile, listed["main"].sandbox) === (nothing, false)
            @test listed["qa deeper"].file == joinpath(dir, "test", "qa", "sub", "deeper_tests.jl")
            # A selection by path reaches into the environment.
            p = plan_of(joinpath(dir, "test", "qa", "sub"))
            @test p.items.name == ["qa deeper"]
        end

        @testset "an item there that asks for another profile is a scan error" begin
            for other in (":default", ":fast")
                bad = env_pkg("EnvOther", "test/qa/qa_tests.jl" => "@testitem \"wanders\" sandbox=$other begin\nend\n",
                              "test/TestItems.toml" => "[profiles.qa]\nenvironment = \"qa\"\n[profiles.fast]\nthreads = \"1\"\n")
                err = try
                    plan_of(bad)
                    nothing
                catch e
                    e
                end
                @test err isa ScanFailure
                msg = sprint(showerror, err)
                @test occursin("`@testitem \"wanders\"`: its file is in the environment of profile `qa`, " *
                               "so it runs under `qa`, and `sandbox = $other` asks for another profile", msg)
            end
        end

        @testset "a chain cannot reach across environments" begin
            bad = env_pkg("EnvChain", "test/a_tests.jl" => "@testitem \"here\" chain=:c begin\nend\n",
                          "test/qa/qa_tests.jl" => "@testitem \"there\" chain=:c begin\nend\n")
            msg = message_of(() -> plan_of(bad))
            @test occursin("chain `:c` mixes sandbox profiles", msg)
        end

        @testset "a file there that is not a test file is a stray, as anywhere under test/" begin
            bad = env_pkg("EnvStray", "test/qa/qa_tests.jl" => "@testitem \"fine\" begin\nend\n",
                          "test/qa/helpers.jl" => "x = 1\n")
            msg = message_of(() -> plan_of(bad))
            @test occursin(joinpath("qa", "helpers.jl"), msg)
            @test occursin("not a test file", msg)
            @test occursin("is read only when a profile names it as its `environment`", msg)
        end

        @testset "a path into an environment's directory is a path of the package's tests" begin
            paths = env_pkg(
                "EnvPaths",
                "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\nend\n",
                "test/vendor/Project.toml" => "[deps]\n",
                "test/vendor/v_tests.jl" => "@testitem \"vendored\" begin\nend\n",
                "test/fixture/Project.toml" => "name = \"Fixture\"\nuuid = \"$(next_uuid())\"\n",
                "test/fixture/test/f_tests.jl" => "@testitem \"fixture\" begin\nend\n",
            )
            root(path...) = resolve_target((joinpath(paths, "test", path...),)).root
            @test root("qa") == paths
            @test root("qa", "") == paths
            @test root("qa", "qa_tests.jl") == paths
            # One whose project declares no package is an environment, named or not.
            @test root("vendor", "v_tests.jl") == paths
            # A package kept there is a package of its own, until a profile names it.
            @test root("fixture", "test", "f_tests.jl") == joinpath(paths, "test", "fixture")
            write(joinpath(paths, "test", "TestItems.toml"),
                  "[profiles.qa]\nenvironment = \"qa\"\n[profiles.fx]\nenvironment = \"fixture\"\n")
            @test root("fixture", "test", "f_tests.jl") == paths
            @test profiles_of(plan_of(joinpath(paths, "test", "fixture")))["fixture"] == (:fx, false)
            # A path into one no profile names selects nothing, and says why.
            msg = message_of(() -> plan_of(joinpath(paths, "test", "vendor", "v_tests.jl")))
            @test occursin("$(joinpath("test", "vendor", "v_tests.jl")) is in $(joinpath("test", "vendor")), which " *
                           "has an environment of its own; a profile with `environment = \"vendor\"` runs the tests there", msg)
            # Given the directory itself, it says so of the directory.
            msg = message_of(() -> plan_of(joinpath(paths, "test", "vendor")))
            @test occursin("$(joinpath("test", "vendor")) has an environment of its own; a profile with `environment = \"vendor\"`", msg)
            @test !occursin(" is in ", msg)
        end

        @testset "item names are one namespace across environments" begin
            bad = env_pkg("EnvDup", "test/a_tests.jl" => "@testitem \"same\" begin\nend\n",
                          "test/qa/qa_tests.jl" => "@testitem \"same\" begin\nend\n")
            @test occursin("duplicate test item name", message_of(() -> plan_of(bad)))
        end
    end

    @testset "directories no profile names" begin
        dir = make_pkg(
            "EnvUnclaimed",
            "test/a_test.jl" => "@testitem \"main\" begin\n    @test true\nend\n",
            "test/qa/Project.toml" => "[deps]\n",
            "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\n    @test false\nend\n",
            "test/qa/sub/more_tests.jl" => "@testitem \"qa more\" begin\n    @test false\nend\n",
            "test/qa/notes.jl" => "# not a test file, and not this suite's to judge\n",
            # No test files: nothing is being left out.
            "test/vendor/Project.toml" => "[deps]\n",
            "test/vendor/vendored.jl" => "x = 1\n",
        )
        note = "not run: 2 test files in $(joinpath("test", "qa")), which has an environment of its own; " *
            "a profile with `environment = \"qa\"` runs them"

        @testset "are not read, and are counted" begin
            p = plan_of(dir)
            @test p.items.name == ["main"]
            @test p.unclaimed == [joinpath(dir, "test", "qa") => 2]
        end

        @testset "the dry run, the header and the conclusion say what was left out" begin
            _, dry = capture_run(() -> Runtests.runtests(dir; dry_run = true))
            @test occursin(note, dry)
            @test !occursin("vendor", dry)
            _, out = capture_run(() -> Runtests.runtests(dir; workers = 0, monitor = false))
            @test count(note, out) == 2
        end

        @testset "chores says so too" begin
            _, out = capture_run(() -> Runtests.chores(dir; dry_run = true))
            @test occursin(note, out)
        end

        @testset "naming it runs it, and a project inside it that nothing names is left out" begin
            write(joinpath(dir, "test", "TestItems.toml"), "[profiles.qa]\nenvironment = \"qa\"\n")
            inner = joinpath(dir, "test", "qa", "inner")
            mkpath(inner)
            write(joinpath(inner, "Project.toml"), "[deps]\n")
            write(joinpath(inner, "inner_tests.jl"), "@testitem \"inner\" begin\nend\n")
            # Read now, it is held to what any directory under `test/` is held to.
            @test occursin(joinpath("qa", "notes.jl"), message_of(() -> plan_of(dir)))
            rm(joinpath(dir, "test", "qa", "notes.jl"))
            p = plan_of(dir)
            @test sort(p.items.name) == ["main", "qa", "qa more"]
            @test p.unclaimed == [inner => 1]
            _, dry = capture_run(() -> Runtests.runtests(dir; dry_run = true))
            @test occursin("a profile with `environment = $(repr(joinpath("qa", "inner")))` runs them", dry)
            rm(joinpath(dir, "test", "TestItems.toml"))
        end

        @testset "a suite whose only tests are in one is told why there is nothing to run" begin
            only_there = make_pkg("EnvOnlyThere", "test/qa/Project.toml" => "[deps]\n",
                                  "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\nend\n")
            @test_throws NoTestsError plan_of(only_there)
        end
    end

    @testset "building an environment" begin
        dir = env_pkg("EnvBuild",
                      "test/qa/LocalPreferences.toml" => "[EnvBuildTools]\nmode = \"env\"\n\n[EnvBuild]\nlevel = 1\nother = true\n",
                      "test/qa_prefs.toml" => "[EnvBuild]\nlevel = 3\n")
        qa = joinpath(dir, "test", "qa")
        prof = Profile(:qa; environment = qa, preferences = joinpath(dir, "test", "qa_prefs.toml"))

        @testset "the copy holds the environment, the package by path, and the preferences" begin
            out = mktempdir()
            write_environment(out, prof, dir)
            project = TOML.parsefile(joinpath(out, "Project.toml"))
            @test project["deps"]["EnvBuild"] == uuid_of(dir)
            @test project["deps"]["EnvBuildTools"] == uuid_of(joinpath(dir, "deps", "EnvBuildTools"))
            @test realpath(project["sources"]["EnvBuild"]["path"]) == realpath(dir)
            # The environment's own path, made absolute: the copy is elsewhere.
            @test realpath(project["sources"]["EnvBuildTools"]["path"]) == realpath(joinpath(dir, "deps", "EnvBuildTools"))
            prefs = TOML.parsefile(joinpath(out, "LocalPreferences.toml"))
            @test prefs["EnvBuildTools"] == Dict("mode" => "env")
            # A package's table is the profile's when it has one, not a merge of keys.
            @test prefs["EnvBuild"] == Dict("level" => 3)
        end

        @testset "kept for the session, and built again when what it was built from changes" begin
            builds = Ref(0)
            build() = environment_project(prof, dir, () -> builds[] += 1)
            first_ = build()
            @test builds[] == 1
            @test !startswith(first_, dir)
            manifest = TOML.parsefile(joinpath(first_, "Manifest.toml"))
            @test haskey(manifest["deps"], "EnvBuildCore")   # the sibling, from the package's `[sources]`
            @test build() == first_
            @test builds[] == 1
            for file in (joinpath(qa, "Project.toml"), joinpath(qa, "LocalPreferences.toml"),
                         joinpath(dir, "test", "qa_prefs.toml"), joinpath(dir, "Project.toml"),
                         joinpath(dir, "lib", "EnvBuildCore", "Project.toml"))
                n = builds[]
                write(file, read(file))
                again = build()
                @test builds[] == n + 1
                @test again != first_
                @test build() == again
                @test builds[] == n + 1
            end
            # A copy something deleted is built again rather than handed out.
            n = builds[]
            rm(build(); recursive = true)
            @test isdir(build())
            @test builds[] == n + 1
        end

        @testset "nothing is written to the environment's own directory" begin
            before = Dict(f => read(joinpath(qa, f)) for f in readdir(qa))
            environment_project(prof, dir)
            @test Dict(f => read(joinpath(qa, f)) for f in readdir(qa)) == before
        end

        @testset "an environment that does not resolve stops the run before anything runs" begin
            bad = env_pkg("EnvBroken")
            write(joinpath(bad, "test", "qa", "Project.toml"),
                  "[deps]\nGhost = \"$(next_uuid())\"\n\n[sources]\nGhost = {path = \"../ghost\"}\n")
            write(joinpath(bad, "test", "qa", "qa_tests.jl"), "@testitem \"qa\" begin\nend\n")
            write(joinpath(bad, "test", "main_tests.jl"), "@testitem \"main\" begin\nend\n")
            with_runstate_dir() do _
                err = try
                    capture_run(() -> run_states(bad; workers = 1, monitor = false))
                    nothing
                catch e
                    e
                end
                @test err isa ConfigError
                @test occursin("could not build the environment of profile `qa` from $(joinpath("test", "qa"))",
                               sprint(showerror, err))
                @test isempty(runstate_files(bad))
                @test live_worker_processes() == 0
            end
        end
    end

    @testset "running in an environment" begin
        dir = env_pkg(
            "EnvRun",
            "test/main_tests.jl" => """
            @testitem "main sees the package" begin
                @test EnvRun.double(1) == 4
                # The environment's packages are its profile's alone.
                @test Base.find_package("EnvRunTools") === nothing
                @test Main.RuntestsWorkers.current_testitem().profile === :default
            end
            """,
            "test/opts_in_tests.jl" => """
            @testitem "elsewhere opts in" sandbox=:qa begin
                using EnvRunTools
                @test EnvRunTools.marker() === :tools
            end
            """,
            "test/qa/qa_tests.jl" => QA_ITEMS,
            "test/qa/sub/nested_tests.jl" => """
            @testitem "qa nested" begin
                using EnvRunTools
                @test EnvRunTools.marker() === :tools
                @test Main.RuntestsWorkers.current_testitem().profile === :qa
            end
            """,
            "test/qa/LocalPreferences.toml" => "[EnvRunTools]\nmode = \"env\"\n",
            "test/qa_prefs.toml" => "[EnvRun]\nlevel = 3\n",
            "test/TestItems.toml" => "[profiles.qa]\nenvironment = \"qa\"\npreferences = \"qa_prefs.toml\"\n",
        )
        pkg_uuid, tools_uuid = uuid_of(dir), uuid_of(joinpath(dir, "deps", "EnvRunTools"))
        write(joinpath(dir, "test", "qa", "prefs_tests.jl"), """
        @testitem "qa sees both preferences" begin
            @test get(Base.get_preferences(Base.UUID("$tools_uuid")), "mode", "unset") == "env"
            @test get(Base.get_preferences(Base.UUID("$pkg_uuid")), "level", 0) == 3
        end
        """)
        qa = joinpath(dir, "test", "qa")
        before = sort(readdir(qa))

        with_runstate_dir() do _
            (states, run, p), out = capture_run(() -> run_states(dir; workers = 1, monitor = false))

            @testset "each item runs where its profile says, with what that environment holds" begin
                @test states["main sees the package"] === PASSED
                @test states["elsewhere opts in"] === PASSED
                @test states["qa sees its environment"] === PASSED
                @test states["qa nested"] === PASSED
                @test states["qa sees both preferences"] === PASSED
                @test states["qa fails"] === FAILED
            end

            @testset "the run says which environment, and builds it outside the package" begin
                @test occursin("profile `qa`: environment $(joinpath("test", "qa"))", out)
                # In a run of several profiles each worker says whose it is, the
                # default profile's included.
                ups = filter(l -> occursin("· UP ", l), split(out, '\n'))
                @test all(l -> endswith(l, "· profile default") || endswith(l, "· profile qa"), ups)
                @test any(l -> endswith(l, "· profile default"), ups) && any(l -> endswith(l, "· profile qa"), ups)
                @test occursin("resolving the environment of profile qa, $(joinpath("test", "qa"))", out)
                project = run.profile_projects[:qa]
                @test !startswith(project, dir)
                @test isfile(joinpath(project, "Manifest.toml"))
                @test sort(readdir(qa)) == before
            end

            @testset "the run state records the environment, relative to the package" begin
                rs = read_run_state(only(runstate_files(dir)))
                @test rs.profiles[:qa].environment == joinpath("test", "qa")
                # A replay finds it in the checkout it runs in.
                @test replayed_config(p.cfg, rs, dir).profiles[:qa].environment == qa
                elsewhere = make_pkg("EnvReplayElsewhere")
                msg = message_of(() -> replayed_config(p.cfg, rs, elsewhere))
                @test occursin("the run state's profile `qa` runs in $(joinpath("test", "qa")), which this checkout does not have", msg)
                replayed = plan_of(dir; replay = rs.path)
                @test only(pr for pr in replayed.profiles if pr.name === :qa).environment == qa
            end

            @testset "its failures are the suite's failures" begin
                @test "qa fails" in failing_items(dir; names = suite_item_names(resolve_target((dir,))))
            end

            @testset "a second run reuses the environment, and workers=0 still runs these on a worker" begin
                (again, _, _), out2 = capture_run() do
                    run_states(dir; workers = 0, monitor = false, name = Set(["qa nested", "main sees the package"]))
                end
                @test again["qa nested"] === PASSED
                @test again["main sees the package"] === PASSED
                @test !occursin("resolving the environment", out2)
            end

            @testset "a run of the default profile's items alone names no profile" begin
                (alone, _, _), out3 = capture_run(() -> run_states(dir; workers = 1, monitor = false, name = "main sees the package"))
                @test alone["main sees the package"] === PASSED
                ups = filter(l -> occursin("· UP ", l), split(out3, '\n'))
                @test length(ups) == 1 && !occursin("· profile", only(ups))
            end
        end

        @testset "a pasted item from the environment's directory runs under its profile" begin
            with_activated(dir) do _
                ts, _ = capture_run() do
                    include_string(Main, """
                    @testitem "pasted in qa" begin
                        using EnvRunTools
                        @test Main.RuntestsWorkers.current_testitem().profile === :qa
                    end
                    """, joinpath(qa, "pasted_tests.jl"))
                end
                @test state_of(ts) === PASSED
                err = try
                    include_string(Main, "@testitem \"pasted elsewhere\" sandbox=:default begin\nend\n",
                                   joinpath(qa, "pasted_tests.jl"))
                    nothing
                catch e
                    e isa LoadError ? e.error : e
                end
                @test err isa ScanFailure
            end
        end

        @testset "the environment is stacked over the test environment, as Pkg.test stacks its sandbox" begin
            # The worker loads RuntestsWorkers through the test environment's manifest,
            # which the environment's copy need not have.
            stacked = Runtests.Private.stacked_load_path
            @test stacked(["@", "@v#.#", "@stdlib"], "/t/Project.toml") == ["@", "/t/Project.toml", "@v#.#", "@stdlib"]
            # Once: under `Pkg.test` the load path names the sandbox already.
            @test stacked(["@", "/t"], "/t/Project.toml") == ["@", "/t"]
            @test stacked(["@", "/t/Project.toml"], "/t/Project.toml") == ["@", "/t/Project.toml"]
            @test stacked(["@stdlib"], "/t/Project.toml") == ["/t/Project.toml", "@stdlib"]
            @test stacked(["@", "@stdlib"], nothing) == ["@", "@stdlib"]
            given(prof) = split(Dict(Runtests.Private.worker_env(1, 1, "/w", prof))["JULIA_LOAD_PATH"],
                                Sys.iswindows() ? ';' : ':')
            test_env = joinpath(mktempdir(), "Project.toml")
            write(test_env, "[deps]\n")
            active = Base.active_project()
            try
                Base.set_active_project(test_env)
                @test test_env in given(Profile(:qa; environment = qa))
                @test given(Profile(:plain)) == LOAD_PATH
            finally
                Base.set_active_project(active)
            end
            # An item run here has what its workers have.
            with_activated(dir) do env
                prof = read_config(joinpath(dir, "test")).profiles[:qa]
                before = copy(LOAD_PATH)
                Runtests.Private.with_interactive_env(Runtests.Private.interactive_target(), prof) do
                    @test Base.active_project() != env
                    @test env in LOAD_PATH
                    @test Base.find_package("EnvRunTools") !== nothing
                end
                @test Base.active_project() == env
                @test LOAD_PATH == before
            end
        end

        @testset "debugging an item of the environment steps into it there" begin
            with_activated(dir) do _
                active = Base.active_project()
                ts, out = capture_run(() -> Runtests.Private.debug_item(body -> body(), "qa nested", nothing))
                @test ts.n_passed == 2
                # The environment's copy holds the profile's preferences, so they apply here.
                @test !occursin("preferences of profile", out)
                # Back in the test environment afterwards.
                @test Base.active_project() == active
            end
        end
    end

    end; end
end
