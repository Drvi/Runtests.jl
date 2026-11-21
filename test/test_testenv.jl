using Runtests.Private: prepare, execute, test_env, with_test_env, TEST_ENVS, Target, PASSED, nitems,
                        clear_disk_test_env!, load_disk_test_env, manifest_packages_present, sweep_runstate_dirs,
                        ENV_CACHE_DIR, runstate_dir
using TOML: TOML

@testset "test environment" begin
    @testset "a test-only dependency is loadable" begin
        # TestDeps declares Random in [extras]/[targets] only: without a generated
        # test environment, the item cannot load it.
        pkg = fixture("TestDeps.jl")
        for workers in (0, 1)
            p, target = prepare((pkg,); workers, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.scratch; force=true, recursive=true)
            @test all(==(PASSED), run.statuses.state)
            # One item imports the test-only dependency itself; the other reaches it
            # through a setup module, which resolves its own imports against the
            # environment the run built.
            @test nitems(p) == 3
        end
    end

    @testset "building the environment is announced, hitting the cache is not" begin
        # Resolving takes seconds and is the longest pause a run has before it
        # prints anything else, so it says what it is waiting for. A cache hit is
        # immediate, and at the REPL — where the cache is the point — a line about
        # it would be noise on every call.
        pkg = fixture("TestDeps.jl")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        delete!(TEST_ENVS, abspath(joinpath(pkg, "Project.toml")))
        clear_disk_test_env!(target)
        _, cold = capture_run() do
            p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.scratch; force=true, recursive=true)
        end
        @test occursin("resolving the test environment", cold)
        _, warm = capture_run() do
            p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.scratch; force=true, recursive=true)
        end
        @test !occursin("resolving the test environment", warm)
        # Clearing the in-memory cache still hits the on-disk cache without resolving.
        delete!(TEST_ENVS, abspath(joinpath(pkg, "Project.toml")))
        _, disk_hit = capture_run() do
            p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.scratch; force=true, recursive=true)
        end
        @test !occursin("resolving the test environment", disk_hit)
    end

    @testset "the environment is cached across runs in a session" begin
        pkg = fixture("Basic.jl")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        first_env = test_env(target)
        @test isfile(first_env)
        @test test_env(target) == first_env          # no rebuild, no re-resolve
        @test test_env(target) == first_env
    end

    @testset "the cache is rebuilt when the project changes" begin
        # A throwaway package rather than a copy of a fixture: two packages sharing
        # a UUID make Julia warn about a different version being loaded.
        work = mktempdir()
        pkg = joinpath(work, "Ephemeral")
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"Ephemeral\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\nversion = \"0.1.0\"\n")
        write(joinpath(pkg, "src", "Ephemeral.jl"), "module Ephemeral end\n")
        write(joinpath(pkg, "test", "a_test.jl"), """@testitem "x" begin\n @test true\n end\n""")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        before = test_env(target)
        @test test_env(target) == before
        # Bumping mtime without changing content (as a fresh CI checkout does) still
        # hits the content-hashed disk cache.
        bump_mtime!(joinpath(pkg, "Project.toml"))
        @test test_env(target) == before
        # Changing content invalidates both the session cache and the disk cache.
        open(io -> write(io, "\n[extras]\nRandom = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n[targets]\ntest = [\"Random\"]\n"),
             joinpath(pkg, "Project.toml"), "a")
        after = test_env(target)
        @test after != before
    end

    @testset "the cache follows the manifest Julia reads" begin
        # Julia reads `Manifest-v1.x.toml` before `Manifest.toml`: writing one makes it
        # the manifest the environment is built from, and changing it changes that.
        pkg = make_pkg("VersionedManifest", "test/a_test.jl" => """@testitem "x" begin\n @test true\nend\n""")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        before = test_env(target)
        @test test_env(target) == before
        versioned = joinpath(pkg, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
        write(versioned, "julia_version = \"$VERSION\"\nmanifest_format = \"2.0\"\n")
        created = test_env(target)
        @test created != before
        open(io -> write(io, "# edited\n"), versioned, "a")
        @test test_env(target) != created
    end

    @testset "the disk cache tracks path dependencies, depot presence, and sweep cleanup" begin
        with_runstate_dir() do rsdir
            work = mktempdir()
            dep_uuid = next_uuid()
            dep = joinpath(work, "LocalDep")
            mkpath(joinpath(dep, "src"))
            write(joinpath(dep, "Project.toml"),
                  "name = \"LocalDep\"\nuuid = \"$dep_uuid\"\nversion = \"0.1.0\"\n")
            write(joinpath(dep, "src", "LocalDep.jl"), "module LocalDep\nval() = 1\nend\n")

            pkg_uuid = next_uuid()
            pkg = joinpath(work, "UsesLocalDep")
            mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
            write(joinpath(pkg, "Project.toml"), """
            name = "UsesLocalDep"
            uuid = "$pkg_uuid"
            version = "0.1.0"

            [deps]
            LocalDep = "$dep_uuid"

            [sources]
            LocalDep = {path = "../LocalDep"}
            """)
            write(joinpath(pkg, "src", "UsesLocalDep.jl"), "module UsesLocalDep\nusing LocalDep\nend\n")
            write(joinpath(pkg, "test", "a_test.jl"), """@testitem "ok" begin\n @test true\n end\n""")
            target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))

            env1 = test_env(target)
            @test startswith(env1, joinpath(rsdir, ENV_CACHE_DIR))
            delete!(TEST_ENVS, abspath(target.project))
            @test load_disk_test_env(target) == env1
            @test test_env(target) == env1

            # Editing the developed path dependency's Project.toml invalidates BOTH the
            # in-memory session cache and the disk cache (even without clearing TEST_ENVS).
            open(io -> write(io, "\n[deps]\nRandom = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n"),
                 joinpath(dep, "Project.toml"), "a")
            @test load_disk_test_env(target) === nothing
            env2 = test_env(target)
            @test env2 != env1

            # Tampering with a cached Manifest.toml invalidates the disk entry via CRC check.
            cached_mf = joinpath(dirname(env2), "Manifest.toml")
            open(io -> write(io, "\n# corrupted\n"), cached_mf, "a")
            delete!(TEST_ENVS, abspath(target.project))
            @test load_disk_test_env(target) === nothing
            env3 = test_env(target)
            @test isfile(env3)

            # Updating a registry metadata file or removing a depot artifact invalidates the cache.
            fake_depot = mktempdir()
            reg_dir = joinpath(fake_depot, "registries", "FakeReg")
            mkpath(reg_dir)
            mkpath(joinpath(fake_depot, "artifacts", "deadbeef"))
            reg_file = joinpath(reg_dir, "Registry.toml")
            write(reg_file, "name = \"FakeReg\"\nuuid = \"$(next_uuid())\"\nrepo = \"\"\n[packages]\n")
            pushfirst!(DEPOT_PATH, fake_depot)
            try
                env_dep = test_env(target)
                delete!(TEST_ENVS, abspath(target.project))
                @test load_disk_test_env(target) == env_dep

                # Registry update -> cache miss
                open(io -> write(io, "# updated\n"), reg_file, "a")
                @test load_disk_test_env(target) === nothing
                env_dep2 = test_env(target)
                @test env_dep2 != env_dep

                # Artifact removal (e.g. Pkg.gc()) -> cache miss
                rm(joinpath(fake_depot, "artifacts", "deadbeef"); force = true, recursive = true)
                delete!(TEST_ENVS, abspath(target.project))
                @test load_disk_test_env(target) === nothing
            finally
                popfirst!(DEPOT_PATH)
                rm(fake_depot; force = true, recursive = true)
            end

            # A manifest entry whose package directory is absent from DEPOT_PATH misses.
            fake_mf = joinpath(work, "FakeManifest.toml")
            write(fake_mf, """
            manifest_format = "2.0"
            [[deps.MissingPkg]]
            git-tree-sha1 = "0123456789abcdef0123456789abcdef01234567"
            uuid = "11111111-2222-3333-4444-555555555555"
            version = "1.0.0"
            """)
            @test !manifest_packages_present(fake_mf, TOML.parsefile(fake_mf))
        end

        # `sweep_runstate_dirs` treats `envcache` as disposable alongside `project`.
        base = mktempdir()
        temp_root = mktempdir()
        gone_pkg = joinpath(temp_root, "GonePkg")
        entry = joinpath(base, "GonePkg-12345678")
        mkpath(joinpath(entry, ENV_CACHE_DIR))
        write(joinpath(entry, "project"), gone_pkg)
        write(joinpath(entry, ENV_CACHE_DIR, "stamp.toml"), "mode = \"testenv\"\n")
        swept = sweep_runstate_dirs(base; temp = temp_root, fix = true)
        @test length(swept) == 1 && swept[1].whole
        @test !ispath(entry)
    end

    @testset "a JULIA_PROJECT in the caller's environment does not reach the items" begin
        # A worker inherits this process's environment. If the variable came
        # through, every item would resolve against the caller's project instead of
        # the test environment the run built, and the package under test would be
        # the one thing it could not load.
        other = mktempdir()
        write(joinpath(other, "Project.toml"), "[deps]\n")
        pkg = fixture("TestDeps.jl")
        states, _, _ = withenv("JULIA_PROJECT" => other) do
            run_states(pkg; workers=1, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
    end

    @testset "the caller's environment is restored" begin
        pkg = fixture("Basic.jl")
        before = Base.active_project()
        p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.scratch; force=true, recursive=true)
        @test Base.active_project() == before
    end

    @testset "an already-active test/Project.toml is respected" begin
        work = mktempdir()
        pkg = joinpath(work, "WithTestProj")
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"WithTestProj\"\nuuid = \"1a2b3c4d-0000-4000-8000-000000000008\"\n")
        write(joinpath(pkg, "src", "WithTestProj.jl"), "module WithTestProj end\n")
        write(joinpath(pkg, "test", "Project.toml"), "[deps]\n")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        testproj = joinpath(pkg, "test", "Project.toml")
        original = Base.active_project()
        try
            Base.set_active_project(testproj)
            seen = with_test_env(target) do
                Base.active_project()
            end
            @test abspath(seen) == abspath(testproj)     # not rebuilt behind the user's back
        finally
            Base.set_active_project(original)
        end
    end

    @testset "a test project in the package's workspace is used as it is" begin
        # As under `Pkg.test`: it shares the package's manifest, so there is no
        # sandbox to build.
        item = """@testitem "loads" begin\n    using InWorkspace, Random\n    @test true\nend\n"""
        pkg = make_pkg("InWorkspace", "test/a_test.jl" => item)
        uuid = TOML.parsefile(joinpath(pkg, "Project.toml"))["uuid"]
        open(io -> write(io, "\n[workspace]\nprojects = [\"test\"]\n"), joinpath(pkg, "Project.toml"), "a")
        write(joinpath(pkg, "test", "Project.toml"),
              "[deps]\nInWorkspace = \"$uuid\"\nRandom = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        # Workspaces came with Julia 1.12. Before, the test project is sandboxed as any
        # other is, and the items run the same.
        @test samefile(test_env(target), joinpath(pkg, "test", "Project.toml")) == (VERSION >= v"1.12")
        states, _, _ = run_states(pkg; workers=1, logs=:issues, monitor=false)
        @test all(==(PASSED), values(states))

        # Outside a workspace, a test project has a manifest of its own, which need
        # not match the package's: that one is sandboxed, as `Pkg.test` does.
        pkg = make_pkg("OwnTestProject", "test/Project.toml" => "[deps]\n")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        @test !samefile(test_env(target), joinpath(pkg, "test", "Project.toml"))
    end

    @testset "a vendored package's test project in a monorepo's workspace is used as it is" begin
        # A flat workspace lists the package and its tests at the root; a nested one
        # lists the package, which lists its tests. Either way the test project shares
        # the root's manifest, though its workspace parents differ.
        for nested in (false, true)
            name = nested ? "NestedVendored" : "FlatVendored"
            root = mktempdir()
            uuid = next_uuid()
            a = joinpath(root, "lib", name)
            files = (
                "Project.toml" => "name = \"$(name)Root\"\nuuid = \"$(next_uuid())\"\nversion = \"0.1.0\"\n\n[workspace]\n" *
                    (nested ? "projects = [\"lib/$name\"]\n" : "projects = [\"lib/$name\", \"lib/$name/test\"]\n"),
                "src/$(name)Root.jl" => "module $(name)Root end\n",
                "lib/$name/Project.toml" => "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n" *
                    (nested ? "\n[workspace]\nprojects = [\"test\"]\n" : ""),
                "lib/$name/src/$name.jl" => "module $name\nanswer() = 42\nend\n",
                "lib/$name/test/Project.toml" => "[deps]\n$name = \"$uuid\"\nRandom = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n",
                "lib/$name/test/a_test.jl" => "@testitem \"answers\" begin\n    using Random\n    @test $name.answer() == 42\nend\n",
            )
            for (path, text) in files
                mkpath(dirname(joinpath(root, path)))
                write(joinpath(root, path), text)
            end
            testproj = joinpath(a, "test", "Project.toml")
            target = Target(a, joinpath(a, "Project.toml"), joinpath(a, "test"), String[], Int32(0))
            @test samefile(test_env(target), testproj) == (VERSION >= v"1.12")
            if VERSION >= v"1.12"
                parent = Base.base_project(testproj)
                @test samefile(parent, joinpath(nested ? a : root, "Project.toml"))
                @test isfile(joinpath(root, "Manifest.toml")) && !isfile(joinpath(a, "Manifest.toml"))
            end
            states, _, _ = run_states(a; workers=1, logs=:issues, monitor=false)
            @test states == Dict("answers" => PASSED)
        end
    end
end
