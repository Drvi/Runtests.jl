# Environment directories. A directory under `test/` with a Project.toml of its own is
# the environment of the test files in it: its items run in a copy of that
# environment with the package under test added by path, under whatever profile they
# ask for. See test_fixtures.jl for `test/testfixtures/`, which holds the projects the
# suite does not read.

using Runtests.Private: prepare, nitems, read_config, ConfigError, ScanFailure, environment_project,
    write_environment, read_run_state, runstate_files, failing_items, suite_item_names, resolve_target,
    list_items, Profile, PASSED, FAILED, init_run_state, finish_run_state!, walk_test_dir, in_environment
using Runtests.RuntestsWorkers: state_of
using Runtests.Private: TOML

"""
    env_pkg(name, "test/x_test.jl" => content, ...) -> dir

A package that takes a sibling, `<name>Core` under `lib/`, by `[sources]`, as a package
of a monorepo does; and `test/qa`, an environment of its own holding `<name>Tools`, a
package the package under test does not depend on.
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
        files...,
    )
    open(joinpath(dir, "Project.toml"), "a") do io
        print(io, "\n[deps]\n$core = \"$ucore\"\n\n[sources]\n$core = {path = \"lib/$core\"}\n")
    end
    return dir
end

uuid_of(project_dir) = TOML.parsefile(joinpath(project_dir, "Project.toml"))["uuid"]

# Each item's profile, environment and whether it has a process of its own, by name.
function pools_of(p)
    return Dict(begin
                    prof = p.profiles[p.units.profile[p.items.unit[i]]]
                    p.items.name[i] => (prof.name, prof.environment, p.units.exclusive[p.items.unit[i]])
                end for i in 1:nitems(p))
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
    @test Main.Runtests.current_testitem().profile === :default
end

@testitem "qa fails" begin
    @test false
end
"""

@testset "environments" begin
    # Run states go to a directory of this file's, not to the depot.
    withenv("RUNTESTS_GROUP" => nothing) do; with_runstate_dir() do _

    @testset "a profile has no environment, and says where environments come from" begin
        dir = env_pkg("EnvConfig", "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\nend\n",
                      "test/TestItems.toml" => "[profiles.qa]\nenvironment = \"qa\"\n")
        msg = message_of(() -> read_config(joinpath(dir, "test")))
        @test occursin("`environment` of [profiles.qa]", msg)
        @test occursin("a directory under `test/` with a Project.toml of its own run in that environment", msg)
        @test occursin("`profile = :qa`", msg)
        @test occursin("`environment` of [profiles.qa]", message_of(() -> plan_of(dir)))
        _, out = capture_run(() -> Runtests.chores(dir; dry_run = true))
        @test occursin("`environment` of [profiles.qa]", out)
    end

    @testset "reading the test files" begin
        dir = env_pkg(
            "EnvRead",
            "test/main_tests.jl" => """
            @testitem "main" begin
            end
            @testitem "main profiled" profile=:fast begin
            end
            """,
            "test/qa/qa_tests.jl" => """
            @testitem "qa plain" begin
            end
            @testitem "qa alone" sandbox=true begin
            end
            @testitem "qa profiled" profile=:fast begin
            end
            @testitem "qa alone profiled" sandbox=true profile=:fast begin
            end
            """,
            "test/qa/sub/deeper_tests.jl" => """
            @testitem "qa deeper" begin
            end
            """,
            "test/qa/inner/JuliaProject.toml" => "[deps]\n",
            "test/qa/inner/inner_tests.jl" => """
            @testitem "qa inner" begin
            end
            """,
            # A project without test files is an environment nothing runs in.
            "test/vendor/Project.toml" => "[deps]\n",
            # Not environments: what the suite keeps for something else, and hidden.
            "test/testfixtures/Fixture/Project.toml" => "[deps]\n",
            "test/.hidden/Project.toml" => "[deps]\n",
            "test/TestItems.toml" => "[profiles.fast]\nthreads = \"1\"\n",
        )
        qa = joinpath(dir, "test", "qa")

        @testset "every directory with a project under test/ is an environment" begin
            walked = walk_test_dir(joinpath(dir, "test"))
            @test walked.environments == [qa, joinpath(qa, "inner"), joinpath(dir, "test", "vendor")]
        end

        @testset "an item runs in the innermost environment that holds its file, under the profile it asks for" begin
            byname = pools_of(plan_of(dir))
            @test byname["main"] == (:default, "", false)
            @test byname["main profiled"] == (:fast, "", false)
            @test byname["qa plain"] == (:default, qa, false)
            @test byname["qa alone"] == (:default, qa, true)
            @test byname["qa profiled"] == (:fast, qa, false)
            @test byname["qa alone profiled"] == (:fast, qa, true)
            @test byname["qa deeper"] == (:default, qa, false)
            @test byname["qa inner"] == (:default, joinpath(qa, "inner"), false)
        end

        @testset "each pair of a profile and an environment is a pool of its own" begin
            p = plan_of(dir)
            pairs = [(pr.name, pr.environment) for pr in p.profiles]
            @test first(pairs) == (:default, "")
            @test allunique(pairs)
            @test (:fast, qa) in pairs && (:default, joinpath(qa, "inner")) in pairs
            # The dry run's header names the profiles once and the environments the items use.
            _, out = capture_run(() -> Runtests.runtests(dir; dry_run = true))
            @test count("profile `fast`: ", out) == 1
            @test occursin("environments: $(joinpath("test", "qa")), $(joinpath("test", "qa", "inner"))", out)
        end

        @testset "every entry point reads the environment's items" begin
            target = resolve_target((dir,))
            @test suite_item_names(target) == Set(["main", "main profiled", "qa plain", "qa alone", "qa profiled",
                                                   "qa alone profiled", "qa deeper", "qa inner"])
            listed = Dict(it.name => it for it in list_items(dir).items)
            @test (listed["qa plain"].profile, listed["qa plain"].sandbox, listed["qa plain"].environment) == (nothing, false, qa)
            @test (listed["qa alone profiled"].profile, listed["qa alone profiled"].sandbox) == ("fast", true)
            @test (listed["main"].profile, listed["main"].sandbox, listed["main"].environment) === (nothing, false, nothing)
            @test listed["qa deeper"].file == joinpath(qa, "sub", "deeper_tests.jl")
            # A selection by path reaches into the environment.
            p = plan_of(joinpath(qa, "sub"))
            @test p.items.name == ["qa deeper"]
        end

        @testset "a chain cannot reach across environments" begin
            bad = env_pkg("EnvChain", "test/a_tests.jl" => "@testitem \"here\" chain=:c begin\nend\n",
                          "test/qa/qa_tests.jl" => "@testitem \"there\" chain=:c begin\nend\n")
            msg = message_of(() -> plan_of(bad))
            @test occursin("chain `:c` spans environments", msg)
            @test occursin("in the environment of $(joinpath("test", "qa"))", msg)
            @test occursin("in the test environment", msg)
        end

        @testset "a file there that is not a test file is a stray, as anywhere under test/" begin
            bad = env_pkg("EnvStray", "test/qa/qa_tests.jl" => "@testitem \"fine\" begin\nend\n",
                          "test/qa/helpers.jl" => "x = 1\n")
            msg = message_of(() -> plan_of(bad))
            @test occursin(joinpath("qa", "helpers.jl"), msg)
            @test occursin("not a test file", msg)
            @test occursin("goes in `test/testfixtures/`", msg)
        end

        @testset "a path into an environment's directory is a path of the package's tests" begin
            paths = env_pkg(
                "EnvPaths",
                "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\nend\n",
                "test/vendor/Project.toml" => "[deps]\n",
                "test/vendor/v_tests.jl" => "@testitem \"vendored\" begin\nend\n",
                "test/named/Project.toml" => "name = \"Named\"\nuuid = \"$(next_uuid())\"\n",
                "test/named/n_tests.jl" => "@testitem \"named\" begin\nend\n",
                "test/testfixtures/Fixture/Project.toml" => "name = \"Fixture\"\nuuid = \"$(next_uuid())\"\n",
                "test/testfixtures/Fixture/test/f_tests.jl" => "@testitem \"fixture\" begin\nend\n",
                "test/.cache/Hidden/Project.toml" => "name = \"Hidden\"\nuuid = \"$(next_uuid())\"\n",
                "test/.cache/Hidden/test/h_tests.jl" => "@testitem \"hidden\" begin\nend\n",
            )
            root(path...) = resolve_target((joinpath(paths, "test", path...),)).root
            @test root("qa") == paths
            @test root("qa", "") == paths
            @test root("qa", "qa_tests.jl") == paths
            @test root("vendor", "v_tests.jl") == paths
            # One whose project declares a package is an environment of the tests too.
            @test root("named", "n_tests.jl") == paths
            @test pools_of(plan_of(joinpath(paths, "test", "named")))["named"] == (:default, joinpath(paths, "test", "named"), false)
            # A package in `test/testfixtures/` is a package of its own, and so is one in a
            # hidden directory: the suite reads neither.
            @test root("testfixtures", "Fixture", "test", "f_tests.jl") == joinpath(paths, "test", "testfixtures", "Fixture")
            @test root(".cache", "Hidden", "test", "h_tests.jl") == joinpath(paths, "test", ".cache", "Hidden")
        end

        @testset "a package where the suite reads is warned about, with where it belongs" begin
            pkgs = env_pkg(
                "EnvPackage",
                "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\nend\n",
                "test/vendored/Project.toml" => "name = \"Vendored\"\nuuid = \"$(next_uuid())\"\n",
                "test/testfixtures/Fixture/Project.toml" => "name = \"Fixture\"\nuuid = \"$(next_uuid())\"\n",
                "test/testsetups/Setup/Project.toml" => "name = \"Setup\"\nuuid = \"$(next_uuid())\"\n",
                "test/testsetups/Setup/src/Setup.jl" => "module Setup end\n",
                "test/.cache/Hidden/Project.toml" => "name = \"Hidden\"\nuuid = \"$(next_uuid())\"\n",
            )
            logs, p = Test.collect_test_logs(() -> plan_of(pkgs))
            said = [string(l.message) for l in logs if l.level == Base.CoreLogging.Warn && occursin("holds the package", string(l.message))]
            # The vendored package alone: not the plain environment, the fixture, the setup or the hidden one.
            @test length(said) == 1
            @test occursin("holds the package `Vendored`. The suite reads it as an environment", only(said))
            @test occursin("move it to `test/testfixtures/`", only(said)) && occursin("move it to `test/testsetups/`", only(said))
            # A warning, not an error: the run goes on.
            @test p.items.name == ["qa"]
        end

        @testset "item names are one namespace across environments" begin
            bad = env_pkg("EnvDup", "test/a_tests.jl" => "@testitem \"same\" begin\nend\n",
                          "test/qa/qa_tests.jl" => "@testitem \"same\" begin\nend\n")
            @test occursin("duplicate test item name", message_of(() -> plan_of(bad)))
        end

        @testset "a suite whose only tests are in an environment runs them" begin
            only_there = make_pkg("EnvOnlyThere", "test/qa/Project.toml" => "[deps]\n",
                                  "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\nend\n")
            @test plan_of(only_there).items.name == ["qa"]
        end

        @testset "a replay finds each item's environment where its file is" begin
            replayed = env_pkg("EnvReplay",
                               "test/main_tests.jl" => "@testitem \"main\" begin\n    @test true\nend\n",
                               "test/qa/qa_tests.jl" => "@testitem \"qa\" profile=:fast begin\n    @test true\nend\n",
                               "test/TestItems.toml" => "[profiles.fast]\nthreads = \"1\"\n")
            with_runstate_dir() do states
                path = joinpath(states, "recorded.runstate")
                finish_run_state!(init_run_state(path, plan_of(replayed)))
                # The recorded profile stands in for the checkout's, which is gone now.
                write(joinpath(replayed, "test", "TestItems.toml"), "")
                p = plan_of(replayed; replay = path)
                @test sort(p.items.name) == ["main", "qa"]
                @test pools_of(p)["qa"] == (:fast, joinpath(replayed, "test", "qa"), false)
                # A recorded item the suite no longer has cannot run again, and is named.
                rm(joinpath(replayed, "test", "main_tests.jl"))
                p = @test_logs (:warn, r"the run state recorded.*\"main\"") match_mode=:any plan_of(replayed; replay = path)
                @test p.items.name == ["qa"]
            end
        end
    end

    @testset "building an environment" begin
        dir = env_pkg("EnvBuild",
                      "test/qa/LocalPreferences.toml" => "[EnvBuildTools]\nmode = \"env\"\n\n[EnvBuild]\nlevel = 1\nother = true\n",
                      "test/qa_prefs.toml" => "[EnvBuild]\nlevel = 3\n")
        qa = joinpath(dir, "test", "qa")
        prof = Profile(:tuned; environment = qa, preferences = joinpath(dir, "test", "qa_prefs.toml"))

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
            # Two profiles without preferences in one environment share one copy.
            plain(name) = environment_project(Profile(name; environment = qa), dir, () -> builds[] += 1)
            n = builds[]
            @test plain(:default) == plain(:fast)
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
                @test occursin("could not build the environment of $(joinpath("test", "qa"))", sprint(showerror, err))
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
                # The environment's packages are its directory's alone.
                @test Base.find_package("EnvRunTools") === nothing
                @test Main.Runtests.current_testitem().profile === :default
            end
            """,
            "test/qa/qa_tests.jl" => QA_ITEMS,
            "test/qa/sub/nested_tests.jl" => """
            @testitem "qa nested" begin
                using EnvRunTools
                @test EnvRunTools.marker() === :tools
                @test Main.Runtests.current_testitem().profile === :default
            end
            """,
            "test/qa/LocalPreferences.toml" => "[EnvRunTools]\nmode = \"env\"\n",
            "test/qa_prefs.toml" => "[EnvRun]\nlevel = 3\n",
            "test/TestItems.toml" => "[profiles.tuned]\npreferences = \"qa_prefs.toml\"\n",
        )
        pkg_uuid, tools_uuid = uuid_of(dir), uuid_of(joinpath(dir, "deps", "EnvRunTools"))
        write(joinpath(dir, "test", "qa", "prefs_tests.jl"), """
        @testitem "qa sees both preferences" profile=:tuned begin
            @test get(Base.get_preferences(Base.UUID("$tools_uuid")), "mode", "unset") == "env"
            @test get(Base.get_preferences(Base.UUID("$pkg_uuid")), "level", 0) == 3
            @test Main.Runtests.current_testitem().profile === :tuned
        end
        """)
        qa = joinpath(dir, "test", "qa")
        before = sort(readdir(qa))

        with_runstate_dir() do _
            (states, run, _), out = capture_run(() -> run_states(dir; workers = 1, monitor = false))

            @testset "each item runs in its directory's environment, under the profile it asks for" begin
                @test states["main sees the package"] === PASSED
                @test states["qa sees its environment"] === PASSED
                @test states["qa nested"] === PASSED
                @test states["qa sees both preferences"] === PASSED
                @test states["qa fails"] === FAILED
            end

            @testset "the run says which environment, and builds it outside the package" begin
                @test occursin("environment: $(joinpath("test", "qa"))", out)
                # Each worker says whose profile and which environment it is.
                ups = filter(l -> occursin("· UP ", l), split(out, '\n'))
                @test any(l -> occursin("· profile default · test environment", l), ups)
                @test any(l -> occursin("· profile default · environment $(joinpath("test", "qa"))", l), ups)
                @test any(l -> occursin("· profile tuned · environment $(joinpath("test", "qa"))", l), ups)
                @test occursin("resolving the environment of $(joinpath("test", "qa"))", out)
                project = run.profile_projects[(:default, qa)]
                @test !startswith(project, dir)
                @test isfile(joinpath(project, "Manifest.toml"))
                @test run.profile_projects[(:tuned, qa)] != project   # its preferences make it a copy of its own
                @test sort(readdir(qa)) == before
            end

            @testset "a replay runs them in the environment of this checkout" begin
                rs = read_run_state(only(runstate_files(dir)))
                replayed = plan_of(dir; replay = rs.path)
                @test pools_of(replayed)["qa nested"] == (:default, qa, false)
                @test pools_of(replayed)["qa sees both preferences"] == (:tuned, qa, false)
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

            @testset "a run of the test environment's items alone names no profile and no environment" begin
                (alone, _, _), out3 = capture_run(() -> run_states(dir; workers = 1, monitor = false, name = "main sees the package"))
                @test alone["main sees the package"] === PASSED
                ups = filter(l -> occursin("· UP ", l), split(out3, '\n'))
                @test length(ups) == 1 && !occursin("· profile", only(ups)) && !occursin("environment", only(ups))
            end
        end

        @testset "workers=0 runs the default profile's init only where items run" begin
            # The init loads what only the environment has: it runs on the environment's
            # worker, and this process, where no item runs, does not run it.
            only_qa = env_pkg("EnvInit",
                              "test/qa/qa_tests.jl" => "@testitem \"qa\" begin\n    @test isdefined(Main, :EnvInitTools)\nend\n",
                              "test/TestItems.toml" => "[profiles.default]\ninit = \"using EnvInitTools\"\n")
            with_runstate_dir() do _
                (states, _, _), _ = capture_run(() -> run_states(only_qa; workers = 0, monitor = false))
                @test states["qa"] === PASSED
            end
        end

        @testset "a pasted item from the environment's directory runs in it" begin
            with_activated(dir) do _
                ts, _ = capture_run() do
                    include_string(Main, """
                    @testitem "pasted in qa" begin
                        using EnvRunTools
                        @test Main.Runtests.current_testitem().profile === :default
                    end
                    """, joinpath(qa, "pasted_tests.jl"))
                end
                @test state_of(ts) === PASSED
                ts, _ = capture_run() do
                    include_string(Main, """
                    @testitem "pasted in qa, tuned" profile=:tuned begin
                        using EnvRunTools
                        @test Main.Runtests.current_testitem().profile === :tuned
                    end
                    """, joinpath(qa, "pasted_tests.jl"))
                end
                @test state_of(ts) === PASSED
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
                @test test_env in given(Profile(:default; environment = qa))
                @test given(Profile(:plain)) == LOAD_PATH
            finally
                Base.set_active_project(active)
            end
            # An item run here has what its workers have.
            with_activated(dir) do env
                prof = in_environment(read_config(joinpath(dir, "test")).profiles[:default], qa)
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
                ts, out = capture_run(() -> Runtests.Private.debug_item(body -> body(), "qa sees both preferences", nothing))
                @test ts.n_passed == 3
                # The environment's copy holds the profile's preferences, so they apply here.
                @test !occursin("preferences of profile", out)
                # Back in the test environment afterwards.
                @test Base.active_project() == active
            end
        end
    end

    end; end
end
