using Runtests.Private: find_participants, import_problems, union_environment, prepare_mono, ConfigError, NoTestsError,
    ScanFailure, Filter, RawItem, Profile, History, Packages, scan, walk_test_dir, setup_modules, config_toml,
    read_profiles, read_config, with_package, item_cfg, start_configuration, auto_workers, plan, nitems,
    exclusively, execute, Target, read_run_state, PASSED, FAILED, ERRORED, TIMEDOUT, history, failing_items,
    failure_log, attempt_artifacts, rundata_dir, runstate_dir, idle_worker_seconds
using Pkg: Pkg
using TOML: TOML

one_item(name) = "@testitem $(repr(name)) begin\n    @test true\nend\n"

names_of(ps) = ps.name

item_text(name; opts = "") = "@testitem $(repr(name)) $opts begin\n    @test true\nend\n"
mono(ws; kwargs...) = prepare_mono((ws,); announce = false, kwargs...)
# Item `name` of package `pkg` in plan `p`, and the pool of its unit.
item_of(p, pkg, name) = only(i for i in 1:nitems(p) if p.packages.name[p.items.package[i]] == pkg && p.items.name[i] == name)
pool_of(p, i) = (u = p.items.unit[i]; findfirst(pl -> first(pl.head) <= u <= last(pl.tail), p.pools))

# What a combined run reads of each participant's suite: its items, the participant
# of each, and its profiles, setups and configuration file.
function scan_participants(ps)
    items, owner = RawItem[], Int[]
    profiles, setups, configs = Dict{Symbol, Profile}[], Dict{Symbol, String}[], String[]
    for k in eachindex(ps.root)
        testdir = joinpath(ps.root[k], "test")
        w = walk_test_dir(testdir)
        s = setup_modules(testdir)
        its = scan(w.tests, Filter(), s; environments = w.environments)
        append!(items, its); append!(owner, fill(k, length(its)))
        path, toml = config_toml(testdir, nothing)
        push!(profiles, read_profiles(path, toml)); push!(setups, s); push!(configs, path)
    end
    return items, owner, profiles, setups, configs
end
# A path or a message as it reads with `/` between directories, which Windows writes
# as `\`.
slashed(s::AbstractString) = replace(s, '\\' => '/')

root_rel(ps) = [slashed(relpath(r, ps.workspace)) for r in ps.root]

@testset "combined runs" begin
    @testset "a combined run needs Julia 1.12, which has workspaces" begin
        ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")])
        if VERSION < v"1.12"
            err = try find_participants(ws); nothing catch e; e end
            @test err isa ErrorException && occursin("Julia 1.12 or later", slashed(err.msg))
        else
            @test names_of(find_participants(ws)) == ["A"]
        end
    end

    @testset "`using Runtests` gives runtests_mono and chores_mono without the prefix" begin
        m = Module()
        Core.eval(m, :(using Runtests))
        @test Core.eval(m, :runtests_mono) === Runtests.runtests_mono
        @test Core.eval(m, :chores_mono) === Runtests.chores_mono
        # The rest of the combined-run API is public under the prefix.
        for name in (:activate_mono, :serve_mono)
            @test Base.ispublic(Runtests, name) && !Base.isexported(Runtests, name)
        end
    end

    if VERSION >= v"1.12"

        @testset "every package of the workspace with a suite takes part" begin
            for layout in (:flat, :nested)
                ws = make_workspace(
                    "A" => ["test/a_test.jl" => one_item("a")],
                    "B" => ["test/b_test.jl" => one_item("b")],
                    "NoSuite" => [],
                    "OnlyRunner" => ["test/runtests.jl" => "using Runtests\nRuntests.runtests()\n"],
                    "Stray" => ["test/helpers.jl" => "x = 1\n"];
                    root = ["test/root_test.jl" => one_item("root")], layout,
                )
                ps = find_participants(ws)
                @test ps.workspace == ws
                # The root is a package with a suite; a stray file fails the run later, as it
                # fails the package's own, rather than leave the package out.
                @test names_of(ps) == ["Root", "A", "B", "Stray"]
                @test ps.root == sort(ps.root)
                @test !any(ps.isolated)
                @test Dict(ps.skipped) == Dict(
                    "lib/NoSuite" => "its test/ has no test files",
                    "lib/OnlyRunner" => "its test/ has only runtests.jl, which a combined run does not run",
                )
            end
        end

        @testset "a workspace root that is not a package adds no participant" begin
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")]; root = nothing)
            ps = find_participants(ws)
            @test names_of(ps) == ["A"]
            @test isempty(ps.skipped)
        end

        @testset "the directory given is the workspace root" begin
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")])
            err = try find_participants(joinpath(ws, "lib", "A")); nothing catch e; e end
            @test err isa ArgumentError && occursin(slashed("is a member of the workspace at $ws"), slashed(err.msg))
            # Without one, the workspace of the active project, a test project's too.
            active = Base.active_project()
            try
                Base.set_active_project(joinpath(ws, "lib", "A", "test", "Project.toml"))
                @test find_participants().workspace == ws
            finally
                Base.set_active_project(active)
            end
            plain = make_pkg("NoWorkspace", "test/a_test.jl" => one_item("a"))
            err = try find_participants(plain); nothing catch e; e end
            @test err isa ConfigError && occursin("declares no workspace", slashed(err.msg)) && occursin("[workspace]", slashed(err.msg))
        end

        @testset "the members of a workspace are under its root, and the root takes part once" begin
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")]; root = ["test/root_test.jl" => one_item("root")],
                                members = ["."])
            ps = find_participants(ws)
            @test names_of(ps) == ["Root", "A"]
            # A package beside the workspace that it lists: Julia looks for a member's
            # workspace above the member, so that package is in none.
            beside = realpath(mktempdir())
            write_package(beside, "Beside", ["test/b_test.jl" => one_item("b")])
            rel = replace(relpath(beside, ws), '\\' => '/')
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")]; members = [rel, "$rel/test"])
            err = try find_participants(ws); nothing catch e; e end
            @test err isa ConfigError && occursin(slashed("lists $(repr(rel)), which is outside the workspace at $ws"), slashed(err.msg))
        end

        @testset "a package whose test project is not in the workspace stops the run, naming both fixes" begin
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")], "B" => ["test/b_test.jl" => one_item("b")];
                                outside = ["B"])
            err = try find_participants(ws); nothing catch e; e end
            @test err isa ConfigError
            @test occursin("lib/B", slashed(err.msg)) && !occursin("lib/A", slashed(err.msg))
            @test occursin("projects` of [workspace]", slashed(err.msg)) && occursin("`packages` of [monorepo]", slashed(err.msg))
            # Tests with [extras] and [targets] have no test project at all.
            rm(joinpath(ws, "lib", "B", "test", "Project.toml"))
            err = try find_participants(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("lib/B (it has none: its tests use [extras] and [targets])", slashed(err.msg))
            # Left out by [monorepo], it is no error.
            write(joinpath(ws, "test", "TestItems.toml"), "[monorepo]\npackages = [\"lib/A\"]\n")
            ps = find_participants(ws)
            @test names_of(ps) == ["A"]
            @test Dict(ps.skipped)["lib/B"] == "left out by `packages` of [monorepo]"
            @test Dict(ps.skipped)["."] == "its test/ has no test files"
        end

        @testset "[monorepo] lists the packages that take part, by directory or glob" begin
            ws = make_workspace(
                "A" => ["test/a_test.jl" => one_item("a")], "B" => ["test/b_test.jl" => one_item("b")],
                "NoSuite" => [];
                root = ["test/root_test.jl" => one_item("root")], members = ["tools/T", "tools/T/test"],
            )
            write_package(joinpath(ws, "tools", "T"), "T", ["test/t_test.jl" => one_item("t")])
            config = joinpath(ws, "test", "TestItems.toml")
            listing(entries...; isolated = String[]) = write(config,
                "[monorepo]\npackages = $(toml_list(entries))\nisolated = $(toml_list(isolated))\n")
            # A glob's packages without a suite are left out; one package matched twice
            # takes part once.
            listing("lib/*", "lib/A", "./lib/B")
            ps = find_participants(ws)
            @test root_rel(ps) == ["lib/A", "lib/B"]
            @test Dict(ps.skipped) == Dict("." => "left out by `packages` of [monorepo]",
                                           "lib/NoSuite" => "its test/ has no test files",
                                           "tools/T" => "left out by `packages` of [monorepo]")
            listing(".", "tools/?"; isolated = ["tools/T"])
            ps = find_participants(ws)
            @test names_of(ps) == ["Root", "T"]
            @test ps.isolated == [false, true]
            # What an entry may not be, each said before anything is read.
            mkpath(joinpath(ws, "lib", "plain"))
            symlink(joinpath(ws, "..") |> realpath, joinpath(ws, "lib", "away"))
            for (entries, isolated, says) in (
                    (["lib/X*"], String[], "matches no package of the workspace"),
                    (["../elsewhere"], String[], "leaves the workspace"),
                    (["lib/away"], String[], "leads outside the workspace"),
                    (["lib/plain"], String[], "is not a package of the workspace"),
                    (["lib/missing"], String[], "no such directory"),
                    (["lib/NoSuite"], String[], "names NoSuite, which has no suite to run: its test/ has no test files"),
                    ([""], String[], r"`packages` entry \"\" of \[monorepo\] in \S+ is empty"),
                    (["lib/A", " "], String[], r"`packages` entry \" \" of \[monorepo\] in \S+ is empty"),
                    (["lib/A"], [""], r"`isolated` entry \"\" of \[monorepo\] in \S+ is empty"),
                    (["lib/A"], ["lib/Z*"], "`isolated` entry \"lib/Z*\" of [monorepo]"),
                    (String[], String[], "leaves no package with a suite to run"),
                )
                listing(entries...; isolated)
                err = try find_participants(ws); nothing catch e; e end
                @test err isa ConfigError && occursin(says, slashed(err.msg))
            end
            write(config, "[monorepo]\npackages = \"lib/A\"\n")
            err = try find_participants(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("must be a list of strings", slashed(err.msg))
            write(config, "[monorepo]\npackage = [\"lib/A\"]\n")
            err = try find_participants(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("unknown key `package` in [monorepo]", slashed(err.msg))
        end

        @testset "the keyword `packages` narrows the participants, by name or directory" begin
            ws = make_workspace("Alpha" => ["test/a_test.jl" => one_item("a")], "Beta" => ["test/b_test.jl" => one_item("b")],
                                "NoSuite" => []; members = ["tools/Alpha", "tools/Alpha/test"])
            write_package(joinpath(ws, "tools", "Alpha"), "Alpha", ["test/a_test.jl" => one_item("a")])
            # A directory is relative to the workspace root, wherever the call is made.
            cd(mktempdir()) do
                ps = find_participants(ws; packages = ["Beta"])
                @test names_of(ps) == ["Beta"]
                @test Dict(ps.skipped)["lib/Alpha"] == "not among the `packages` given"
                @test names_of(find_participants(ws; packages = ["./lib/Alpha", :Beta])) == ["Alpha", "Beta"]
                for (packages, says) in (
                        (["Alpha"], "the workspace has 2 packages of that name, in lib/Alpha and tools/Alpha: give its directory"),
                        (["Betta"], "not a package of the workspace at $ws (did you mean \"Beta\"?)"),
                        (["lib/NoSuite"], "NoSuite, which does not take part: its test/ has no test files"),
                        (["lib/nothing"], "there is no such directory"),
                        (String[], "must be package names or directories"),
                        (1, "must be package names or directories"),
                    )
                    err = try find_participants(ws; packages); nothing catch e; e end
                    @test err isa ArgumentError && occursin(slashed(says), slashed(err.msg))
                end
            end
        end

        @testset "an import that only another participant's test project declares stops the run" begin
            forms = ["using OnlyB", "import OnlyB", "using OnlyB: f", "import OnlyB as Y", "using OnlyB.Sub",
                     "@eval using OnlyB"]
            ws = make_workspace(
                "A" => [
                    "test/forms_test.jl" => join("@testitem $(repr(f)) begin\n    $f\nend\n" for f in forms),
                    # Allowed: its test dependencies, itself, its setups, the standard
                    # library, relative and quoted imports, and a fixture that no
                    # package provides, which loads from a directory the item puts on
                    # `LOAD_PATH` in either run.
                    "test/allowed_test.jl" => """
                        @testitem "allowed" profile=:p begin
                            using Test, LinearAlgebra, A, OwnDep, ASetup, APkg
                            import Base.Threads
                            using .Inner
                            ex = quote using OnlyB end
                            import_ex = :(import OnlyB)
                            push!(LOAD_PATH, joinpath(@__DIR__, "testfixtures"))
                            using FixtureOnly
                        end
                        """,
                    "test/TestItems.toml" => "[profiles.p]\ninit = \"using OnlyB\"\ntest_end = \"using Test\"\n",
                    "test/testsetups/ASetup.jl" => "module ASetup\nusing ASibling\nusing OnlyB\nend\n",
                    "test/testsetups/ASibling.jl" => "module ASibling\nusing OwnDep, LinearAlgebra\nend\n",
                    "test/testsetups/APkg/Project.toml" => "name = \"APkg\"\n\n[deps]\nFoo = \"$(next_uuid())\"\n",
                    "test/testsetups/APkg/src/APkg.jl" => "module APkg\nusing Foo, Test\nusing OwnDep\nend\n",
                    # An environment directory runs in its own project.
                    "test/qa/Project.toml" => "[deps]\nOnlyB = \"$(next_uuid())\"\n",
                    "test/qa/qa_test.jl" => "@testitem \"qa\" begin\n    using OnlyB\nend\n",
                ],
                "B" => ["test/b_test.jl" => "@testitem \"b\" begin\n    using OnlyB\nend\n"],
                # An isolated participant runs in its own test environment.
                "C" => ["test/c_test.jl" => "@testitem \"c\" begin\n    using OnlyB\nend\n"];
                deps = Dict("A" => ["OwnDep"], "B" => ["OnlyB"]),
            )
            write(joinpath(ws, "test", "TestItems.toml"), "[monorepo]\nisolated = [\"lib/C\"]\n")
            ps = find_participants(ws)
            @test names_of(ps) == ["A", "B", "C"] && ps.isolated == [false, false, true]
            problems = import_problems(ps, scan_participants(ps)...)
            found = sort!([(slashed(relpath(e.file, ws)), Int(e.line), slashed(e.msg)) for e in problems])
            forms_at = [(f, findfirst(==("    $f"), split(read(joinpath(ws, "lib/A/test/forms_test.jl"), String), '\n')))
                        for f in forms]
            declared = "which is not in [deps] of A's test project, lib/A/test/Project.toml, so A's own run cannot load it"
            @test found == sort!([
                [("lib/A/test/forms_test.jl", line, "imports OnlyB, $declared") for (_, line) in forms_at];
                ("lib/A/test/TestItems.toml", 0, "`init` of [profiles.p] imports OnlyB, $declared");
                ("lib/A/test/testsetups/ASetup.jl", 3, "imports OnlyB, $declared");
                ("lib/A/test/testsetups/APkg/src/APkg.jl", 3,
                 "imports OwnDep, which is not in [deps] of the setup package APkg, lib/A/test/testsetups/APkg/Project.toml");
            ])
        end

        @testset "the union environment loads every test dependency from the workspace's manifest, without a resolve" begin
            # A's tests use a vendored package and Runtests by path, B's a standard
            # library; the root is no package.
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")], "B" => ["test/b_test.jl" => one_item("b")];
                                root = nothing, members = ["lib/Vendored"])
            write_package(joinpath(ws, "lib", "Vendored"), "Vendored", []; test_project = false)
            uuid(name) = TOML.parsefile(joinpath(ws, "lib", name, "Project.toml"))["uuid"]
            test = "Test = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n"
            write(joinpath(ws, "lib", "A", "test", "Project.toml"), """
                [deps]
                A = "$(uuid("A"))"
                Runtests = "632efd68-cd41-4e05-bd25-b86dc2150078"
                $(test)Vendored = "$(uuid("Vendored"))"

                [sources]
                A = {path = ".."}
                Runtests = {path = $(repr(pkgdir(Runtests)))}
                Vendored = {path = "../../Vendored"}
                """)
            write(joinpath(ws, "lib", "B", "test", "Project.toml"), """
                [deps]
                B = "$(uuid("B"))"
                Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
                $(test)
                [sources]
                B = {path = ".."}
                """)
            write(joinpath(ws, "lib", "A", "test", "LocalPreferences.toml"), "[Vendored]\nmode = \"fast\"\n")
            write(joinpath(ws, "lib", "B", "test", "LocalPreferences.toml"), "[Vendored]\nlevel = 2\nmode = \"fast\"\n")
            active = Base.active_project()
            try
                Pkg.activate(ws; io = devnull)
                Pkg.resolve(; io = devnull)
            finally
                Base.set_active_project(active)
            end
            dir = mktempdir()
            project = union_environment(find_participants(ws), dir)
            @test sort!(collect(keys(TOML.parsefile(project)["deps"]))) == ["A", "B", "Random", "Runtests", "Test", "Vendored"]
            # A relative path would point into `dir`.
            manifest = TOML.parsefile(joinpath(dir, "Manifest.toml"))
            paths = [e["path"] for (_, es) in manifest["deps"] for e in es if haskey(e, "path")]
            @test length(paths) == 4 && all(isabspath, paths)
            @test TOML.parsefile(joinpath(dir, "LocalPreferences.toml")) == Dict("Vendored" => Dict("mode" => "fast", "level" => 2))
            pkg_loaded = "haskey(Base.loaded_modules, Base.PkgId(Base.UUID(\"44cfe95a-1eb2-52ea-b672-e2afdf69b78f\"), \"Pkg\"))"
            code = "using A, B, Vendored, Runtests, Test, Random; print($pkg_loaded)"
            out = withenv("JULIA_LOAD_PATH" => "@$(Runtests.Private.PATHSEP)@stdlib", "JULIA_PROJECT" => nothing) do
                read(`$(Base.julia_cmd()) --startup-file=no --project=$dir -e $code`, String)
            end
            @test out == "false"
        end

        @testset "the union environment needs one package per name, agreeing preferences and Runtests" begin
            ws = make_workspace("A" => ["test/a_test.jl" => one_item("a")], "B" => ["test/b_test.jl" => one_item("b")];
                                root = nothing, deps = Dict("A" => ["Dup"], "B" => ["Dup"]))
            config = joinpath(ws, "test", "TestItems.toml")
            mkpath(dirname(config))
            fails(says) = (err = try union_environment(find_participants(ws), mktempdir()); nothing catch e; e end;
                           err isa ConfigError && occursin(says, slashed(err.msg)))
            # The same name for two packages, said with both declarations; an isolated
            # participant is not in the union, so its declaration is no conflict.
            @test fails(r"Dup is two packages in it: \S+ in lib/A/test/Project.toml, and \S+ in lib/B/test/Project.toml")
            write(config, "[monorepo]\nisolated = [\"lib/B\"]\n")
            @test fails("has no manifest")
            rm(config)
            write(joinpath(ws, "lib", "B", "test", "Project.toml"),
                  replace(read(joinpath(ws, "lib", "B", "test", "Project.toml"), String), r"Dup = .*\n" => ""))
            # A preference set two ways, said with both values and files.
            write(joinpath(ws, "lib", "A", "test", "LocalPreferences.toml"), "[Dup]\nlevel = 1\n")
            write(joinpath(ws, "lib", "B", "test", "LocalPreferences.toml"), "[Dup]\nlevel = 2\n")
            @test fails("they set preference \"level\" of Dup differently: 1 in lib/A/test/LocalPreferences.toml, " *
                        "and 2 in lib/B/test/LocalPreferences.toml")
            write(config, "[monorepo]\nisolated = [\"lib/B\"]\n")
            @test fails("has no manifest")
            # A manifest that does not hold Runtests.
            entries = join("[[deps.$n]]\nuuid = $(repr(u))\n\n" for (n, u) in
                           TOML.parsefile(joinpath(ws, "lib", "A", "test", "Project.toml"))["deps"])
            write(joinpath(ws, "Manifest.toml"), "julia_version = \"$VERSION\"\nmanifest_format = \"2.0\"\n\n$entries")
            @test fails("does not hold Runtests (the combined run itself). A combined run needs Runtests in the workspace")
        end

        @testset "a profile the workspace root marks monorepo_default is each package's whose code is the same" begin
            shared = "[profiles.default]\nmonorepo_default = true\ninit = \"global SHARED_INIT = pwd()\"\ntest_end = \"nothing\"\n"
            ws = make_workspace(
                "Inherits" => ["test/a_test.jl" => item_text("a")],
                # The same code, written another way.
                "Copies" => ["test/b_test.jl" => item_text("b"), "test/TestItems.toml" =>
                    "[profiles.default]\ninit = '''\nglobal SHARED_INIT  =  pwd()\n'''\ntest_end = '''\n# done\nnothing\n'''\n"],
                "OwnInit" => ["test/c_test.jl" => item_text("c"), "test/TestItems.toml" =>
                    "[profiles.default]\ninit = \"global OTHER = 1\"\ntest_end = \"nothing\"\n"],
                "OwnEnd" => ["test/d_test.jl" => item_text("d"), "test/TestItems.toml" =>
                    "[profiles.default]\ninit = \"global SHARED_INIT = pwd()\"\n"];
                root = ["test/r_test.jl" => item_text("r"), "test/TestItems.toml" => shared],
            )
            # In each package's own runs: the shared `init` runs in the workspace root.
            dir_of(rel) = read_config(joinpath(ws, rel, "test")).profiles[:default].dir
            @test dir_of(".") == dir_of("lib/Inherits") == dir_of("lib/Copies") == ws
            @test dir_of("lib/OwnInit") == dir_of("lib/OwnEnd") == ""
            # In a combined run: their workers are one pool, and each other package's are its own.
            p = mono(ws).plan
            pool(pkg, name) = pool_of(p, item_of(p, pkg, name))
            @test pool("Root", "r") == pool("Inherits", "a") == pool("Copies", "b")
            @test allunique([pool("Root", "r"), pool("OwnInit", "c"), pool("OwnEnd", "d")])
            # Only the file of the workspace root shares, and only with true or false.
            own = joinpath(ws, "lib", "OwnInit", "test", "TestItems.toml")
            write(own, "[profiles.default]\nmonorepo_default = true\n")
            for err in (try mono(ws); nothing catch e; e end, try read_config(dirname(own)); nothing catch e; e end)
                @test err isa ConfigError && occursin("only the test/TestItems.toml of a workspace's root shares", slashed(err.msg))
            end
            write(joinpath(ws, "test", "TestItems.toml"), replace(shared, "= true" => "= \"yes\""))
            err = try read_config(joinpath(ws, "test")); nothing catch e; e end
            @test err isa ConfigError && occursin("must be true or false, got \"yes\"", slashed(err.msg))
            lone = make_pkg("Lone", "test/TestItems.toml" => "[profiles.default]\nmonorepo_default = true\n")
            err = try read_config(joinpath(lone, "test")); nothing catch e; e end
            @test err isa ConfigError && occursin("this package is in no workspace", slashed(err.msg))
        end

        @testset "a package's own runs read only the profiles that the workspace root shares" begin
            ws = make_workspace("A" => ["test/a_test.jl" => item_text("a")]; root = nothing)
            config = joinpath(ws, "test", "TestItems.toml")
            mkpath(dirname(config))
            write(config, "[run]\nnot_a_setting = 1\n\n[profiles.unused]\nthreads = \"nonsense\"\n\n" *
                          "[profiles.default]\nmonorepo_default = true\ninit = \"global X = 1\"\n")
            @test read_config(joinpath(ws, "lib", "A", "test")).profiles[:default].dir == ws
            # One that it shares is checked as the root's own runs check it, and its file named.
            write(config, "[profiles.default]\nmonorepo_default = true\nthreads = \"nonsense\"\n")
            err = try read_config(joinpath(ws, "lib", "A", "test")); nothing catch e; e end
            @test err isa ConfigError && occursin(r"`threads` of \[profiles\.default\] in \S*TestItems\.toml must be", slashed(err.msg))
        end

        @testset "two packages of one name do not take part together" begin
            ws = make_workspace("Dup" => ["test/a_test.jl" => item_text("same")]; root = nothing,
                                members = ["tools/Dup", "tools/Dup/test"])
            write_package(joinpath(ws, "tools", "Dup"), "Dup", ["test/a_test.jl" => item_text("same")])
            says = "2 packages that take part are Dup: lib/Dup and tools/Dup"
            for err in (try find_participants(ws); nothing catch e; e end, try mono(ws; item_keys = [("Dup", "same")]); nothing catch e; e end,
                        try Runtests.Private.list_items_mono(ws); nothing catch e; e end)
                @test err isa ConfigError && occursin(says, slashed(err.msg))
            end
            # Taking part one at a time, each is itself.
            @test root_rel(find_participants(ws; packages = ["tools/Dup"])) == ["tools/Dup"]
        end

        @testset "a shared profile's imports are checked for each package that has it, at the root's file" begin
            ws = make_workspace("A" => ["test/a_test.jl" => item_text("a")], "B" => ["test/b_test.jl" => item_text("b")];
                                root = nothing, deps = Dict("B" => ["OnlyB"]))
            config = joinpath(ws, "test", "TestItems.toml")
            mkpath(dirname(config))
            write(config, "[profiles.default]\nmonorepo_default = true\ninit = \"using OnlyB\"\n")
            err = try mono(ws); nothing catch e; e end
            @test err isa ScanFailure
            problem = only(err.errors)
            @test problem.file == config
            @test occursin("`init` of [profiles.default] imports OnlyB, which is not in [deps] of A's test project", problem.msg)
        end

        @testset "items of several packages share workers that start the same way" begin
            ws = make_workspace(
                "A" => [
                    "test/a_test.jl" => item_text("same") * item_text("a1") * item_text("ends"; opts = "profile=:ends") *
                        item_text("fast"; opts = "profile=:fast") * item_text("init"; opts = "profile=:withinit") *
                        item_text("db1"; opts = "chain=:db") * item_text("db2"; opts = "chain=:db"),
                    "test/qa/Project.toml" => "[deps]\n",
                    "test/qa/qa_test.jl" => item_text("qa"),
                    "test/TestItems.toml" => "[profiles.ends]\ntest_end = \"nothing\"\n" *
                        "[profiles.fast]\njulia_args = [\"--check-bounds=yes\"]\n[profiles.withinit]\ninit = \"x = 1\"\n",
                ],
                "B" => [
                    "test/b_test.jl" => item_text("same") * item_text("fast"; opts = "profile=:fast") *
                        item_text("init"; opts = "profile=:withinit") * item_text("db1"; opts = "chain=:db"),
                    "test/TestItems.toml" => "[profiles.fast]\njulia_args = [\"--check-bounds=no\"]\n" *
                        "[profiles.withinit]\ninit = \"x = 1\"\n",
                ],
                "C" => ["test/c_test.jl" => item_text("c1")];
                root = nothing,
            )
            mkpath(joinpath(ws, "test"))
            write(joinpath(ws, "test", "TestItems.toml"), "[monorepo]\nisolated = [\"lib/C\"]\n")
            p = mono(ws).plan
            pool(pkg, name) = pool_of(p, item_of(p, pkg, name))
            # One pool for both default profiles and for a profile that differs only in
            # `test_end`; an item of the same name in each package is two items.
            @test pool("A", "same") == pool("B", "same") == pool("A", "a1") == pool("A", "ends")
            @test item_of(p, "A", "same") != item_of(p, "B", "same")
            # Other flags, an `init`, an environment directory and an isolated package
            # each keep pools of their own.
            @test pool("A", "fast") != pool("B", "fast") && pool("A", "fast") != pool("A", "a1")
            @test pool("A", "init") != pool("B", "init")
            @test length(unique([pool("A", "a1"), pool("A", "qa"), pool("C", "c1")])) == 3
            # A chain is one package's: two packages that name `:db` have one each.
            @test p.items.unit[item_of(p, "A", "db1")] == p.items.unit[item_of(p, "A", "db2")] !=
                  p.items.unit[item_of(p, "B", "db1")]
            # An item runs under its own package's profile.
            prof(pkg, name) = p.profiles[p.units.profile[p.items.unit[item_of(p, pkg, name)]]]
            @test prof("A", "fast").julia_args == ["--check-bounds=yes"] && prof("B", "fast").julia_args == ["--check-bounds=no"]
            @test p.profile_package[p.units.profile[p.items.unit[item_of(p, "B", "init")]]] == 2
            # The run's seed is every package's.
            p7 = mono(ws; seed = 7).plan
            @test all(==(7), p7.items.seed)
        end

        @testset "each package's [order] stays one block, the longest first" begin
            ws = make_workspace(
                "A" => ["test/a_test.jl" => join(item_text("a$i") for i in 1:4),
                        "test/TestItems.toml" => "[order]\nfirst = [\"a3\", \"a1\"]\nlast = [\"a4\"]\n"],
                "B" => ["test/b_test.jl" => join(item_text("b$i") for i in 1:4),
                        "test/TestItems.toml" => "[order]\nfirst = [\"b2\"]\nlast = [\"b1\", \"b4\"]\n"];
                root = nothing,
            )
            names_in_order(p) = [string(p.packages.name[p.items.package[i]], ":", p.items.name[i]) for i in 1:nitems(p)]
            # Nothing measured: in the order of the packages.
            order = names_in_order(mono(ws; workers = 1).plan)
            @test order[1:3] == ["A:a3", "A:a1", "B:b2"] && order[end-2:end] == ["A:a4", "B:b1", "B:b4"]
            # B's blocks took longer.
            ps = find_participants(ws)
            items, owner, _, _, _ = scan_participants(ps)
            raw = [with_package(it, k) for (it, k) in zip(items, owner)]
            cfgs = [read_config(joinpath(r, "test"); workers = 1) for r in ps.root]
            histories = [History(Dict("a3" => 1.0, "a1" => 1.0, "a4" => 1.0)), History(Dict("b2" => 5.0, "b1" => 2.0, "b4" => 2.0))]
            p = plan(raw, cfgs[1]; histories, root = ws,
                     packages = Packages(ps.name, ps.uuid, ps.root, ps.isolated, cfgs, [String[] for _ in ps.root]))
            order = names_in_order(p)
            @test order[1:3] == ["B:b2", "A:a3", "A:a1"] && order[end-2:end] == ["B:b1", "B:b4", "A:a4"]
        end

        @testset "settings: the run's from the root, each package's from its own file, under the call and the variables" begin
            ws = make_workspace(
                "A" => ["test/a_test.jl" => item_text("a"),
                        "test/TestItems.toml" => "[run]\ntimeout = 50\nthreads = \"3\"\nworkers = 7\nverbose = true\n"],
                "B" => ["test/b_test.jl" => item_text("b"), "test/TestItems.toml" => "[run]\nitem_failfast = false\n"];
                root = ["test/root_test.jl" => item_text("r"),
                        "test/TestItems.toml" => "[run]\ntimeout = 100\nworkers = 2\nfailfast = true\n"],
            )
            setting(r, pkg, name, key) = getfield(item_cfg(r.plan, item_of(r.plan, pkg, name)), key)
            r = mono(ws)
            @test r.plan.cfg.workers == 2 && r.plan.cfg.failfast && !r.plan.cfg.verbose
            @test [setting(r, "Root", "r", :timeout_s), setting(r, "A", "a", :timeout_s), setting(r, "B", "b", :timeout_s)] ==
                  [100, 50, 30 * 60]
            # A's own `workers` and `verbose` are the run's, so A's file has no effect on them.
            @test setting(r, "A", "a", :workers) == 2 && !setting(r, "A", "a", :verbose)
            @test [setting(r, "A", "a", :threads), setting(r, "B", "b", :threads)] == ["3", "2,1"]
            # An `item_failfast` that nothing sets is the run's `failfast`.
            @test setting(r, "A", "a", :item_failfast) && !setting(r, "B", "b", :item_failfast)
            # A variable gives every package its value, and a keyword wins over it.
            withenv("RUNTESTS_TIMEOUT" => "20") do
                @test all(i -> item_cfg(mono(ws).plan, i).timeout_s == 20, 1:3)
                @test all(i -> item_cfg(mono(ws; timeout = 10).plan, i).timeout_s == 10, 1:3)
            end
            err = try mono(ws; config = "x.toml"); nothing catch e; e end
            @test err isa ArgumentError && occursin("reads each package's own", slashed(err.msg))
            # `workers = "auto"` counts the most threads any package's workers start with.
            rm(joinpath(ws, "test", "TestItems.toml"))
            write(joinpath(ws, "lib", "B", "test", "TestItems.toml"), "[profiles.wide]\nthreads = \"8\"\n")
            @test mono(ws).plan.cfg.workers == auto_workers("8", 3)
        end

        @testset "a selection narrows each package" begin
            ws = make_workspace(
                "A" => ["test/a_test.jl" => item_text("a1"; opts = "tags=[:gpu]") * item_text("a2") *
                            item_text("a3"; opts = "tags=[:slow]"),
                        "test/TestItems.toml" => "[groups]\ngpu = \"gpu\"\ndefault = \"!slow\"\n"],
                "B" => ["test/b_test.jl" => item_text("b1"; opts = "tags=[:onlyb]") * item_text("b2")],
                "Skipped" => ["test/s_test.jl" => item_text("s")];
                root = nothing,
            )
            mkpath(joinpath(ws, "test"))
            write(joinpath(ws, "test", "TestItems.toml"), "[monorepo]\npackages = [\"lib/A\", \"lib/B\"]\n")
            selected(r) = sort!([string(r.plan.packages.name[r.plan.items.package[i]], ":", r.plan.items.name[i])
                                 for i in 1:nitems(r.plan)])
            # The default group is each package's own.
            @test selected(mono(ws)) == ["A:a1", "A:a2", "B:b1", "B:b2"]
            # A group that only A declares leaves B without items, and says so.
            r = mono(ws; group = "gpu")
            @test selected(r) == ["A:a1"]
            @test ("lib/B" => "it declares no group `gpu`") in r.skipped
            withenv("RUNTESTS_GROUP" => "gpu") do
                @test selected(mono(ws)) == ["A:a1"]
                # A name selects whatever group it is in.
                @test selected(mono(ws; name = "a3")) == ["A:a3"]
            end
            err = try mono(ws; group = "nope"); nothing catch e; e end
            @test err isa ArgumentError && occursin("no package of the combined run declares", slashed(err.msg))
            # A tag has to be in one of the suites.
            @test selected(mono(ws; tags = [:onlyb])) == ["B:b1"]
            err = try mono(ws; tags = [:nowhere]); nothing catch e; e end
            @test err isa ArgumentError && occursin("no test item has the tag `nowhere`", slashed(err.msg))
            # `packages` narrows the participants; paths select within the package they
            # are in, a line one item.
            @test selected(mono(ws; packages = ["B"])) == ["B:b1", "B:b2"]
            a, b = joinpath(ws, "lib/A/test/a_test.jl"), joinpath(ws, "lib/B/test")
            @test selected(prepare_mono((a, b); announce = false, group = "all")) == ["A:a1", "A:a2", "A:a3", "B:b1", "B:b2"]
            @test selected(prepare_mono(("$a:5",); announce = false)) == ["A:a2"]
            err = try prepare_mono((joinpath(ws, "lib/Skipped/test/s_test.jl"),); announce = false); nothing catch e; e end
            @test err isa ArgumentError && occursin("is in lib/Skipped, which does not take part", slashed(err.msg))
            err = try mono(ws; name = "zzz"); nothing catch e; e end
            @test err isa NoTestsError
            # Keys, as an editor asks: a package that no key names is not read, and a key
            # of nothing is said rather than refused.
            r = mono(ws; item_keys = [("A", "a2"), ("Z", "x"), ("B", "nope")])
            @test selected(r) == ["A:a2"] && r.unknown == [("B", "nope"), ("Z", "x")]
            @test ("lib/B" => "no item matches the selection") in r.skipped
        end

        @testset "what stops a combined plan before it is made" begin
            ws = make_workspace("A" => ["test/a_test.jl" => item_text("a"), "test/testsetups/Common.jl" => "module Common end\n"],
                                "B" => ["test/b_test.jl" => item_text("b"), "test/testsetups/Common.jl" => "module Common end\n"];
                                root = nothing)
            err = try mono(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("`Common` in lib/A/test/testsetups and in lib/B/test/testsetups", slashed(err.msg))
            # B selected away gives no item and shares no worker or load path with A,
            # whichever way the selection is made.
            write(joinpath(ws, "lib", "A", "test", "a_test.jl"), item_text("a"; opts = "tags=[:fast]"))
            write(joinpath(ws, "lib", "A", "test", "TestItems.toml"), "[groups]\ng = \"fast\"\n")
            only_a(r) = r.plan.packages.name == ["A"]
            @test only_a(mono(ws; name = "a"))
            @test only_a(mono(ws; group = "g"))
            @test only_a(mono(ws; item_keys = [("A", "a")]))
            @test only_a(prepare_mono((joinpath(ws, "lib", "A", "test", "a_test.jl"),); announce = false))
            rm(joinpath(ws, "lib", "B", "test", "testsetups"); recursive = true)
            write(joinpath(ws, "lib", "B", "test", "b_test.jl"), "@testitem \"b\" begin\n    using Common\nend\n")
            err = try mono(ws); nothing catch e; e end
            @test err isa ScanFailure && occursin("imports Common, which is not in [deps] of B's test project",
                                                  only(err.errors).msg)
            # A setup with the name of a test dependency of another package: a shared worker
            # would load that package for `using X`, where A's own run loads the setup.
            ws = make_workspace("A" => ["test/a_test.jl" => "@testitem \"a\" begin\n    using X\nend\n",
                                        "test/testsetups/X.jl" => "module X end\n"],
                                "B" => ["test/b_test.jl" => item_text("b")];
                                root = nothing, deps = Dict("B" => ["X"]))
            err = try mono(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("`X` in lib/A/test/testsetups, which lib/B/test/Project.toml declares", slashed(err.msg))
            # The same for another package itself, and none once either side is isolated.
            mv(joinpath(ws, "lib", "A", "test", "testsetups", "X.jl"), joinpath(ws, "lib", "A", "test", "testsetups", "B.jl"))
            write(joinpath(ws, "lib", "A", "test", "testsetups", "B.jl"), "module B end\n")
            write(joinpath(ws, "lib", "A", "test", "a_test.jl"), item_text("a"))
            err = try mono(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("`B` in lib/A/test/testsetups, which lib/B/Project.toml declares", slashed(err.msg))
            mkpath(joinpath(ws, "test"))
            for isolated in ("lib/A", "lib/B")
                write(joinpath(ws, "test", "TestItems.toml"), "[monorepo]\nisolated = [$(repr(isolated))]\n")
                @test length(mono(ws).plan.items.name) == 2
            end
            # Many profiles over several packages fit one plan.
            many = join("[profiles.p$i]\nthreads = \"1\"\n" for i in 1:60)
            ws = make_workspace(("P$k" => ["test/a_test.jl" => item_text("x"), "test/TestItems.toml" => many] for k in 1:3)...;
                                root = nothing)
            @test length(mono(ws).plan.profiles) == 3 * 61
        end

        @testset "a combined run: shared workers, each item in its own package, a run state for each package" begin
            ws = make_workspace(
                "A" => ["src/A.jl" => "module A\nf() = :a\nend\n",
                        "test/a_test.jl" => """
                            @testitem "same" begin
                                @test A.f() === :a
                                @test basename(pwd()) == "A"
                            end
                            @testitem "db1" chain=:db begin
                                @test true
                            end
                            @testitem "db2" chain=:db begin
                                @test true
                            end
                            """],
                "B" => ["src/B.jl" => "module B\nf() = :b\nend\n",
                        "test/b_test.jl" => """
                            @testitem "same" begin
                                @test B.f() === :b
                                @test basename(pwd()) == "B"
                                @test !isdefined(@__MODULE__, :A)
                            end
                            @testitem "db1" chain=:db begin
                                @test true
                            end
                            """];
                root = nothing,
            )
            with_runtests_dep!(ws, ["A", "B"])
            with_runstate_dir() do runstates
                events = Runtests.TestItemEvent[]
                states, run, p = run_mono(ws; workers = 1, logs = :issues, monitor = false,
                                          on_event = ev -> ev.kind === :finished && push!(events, ev))
                @test all(==(PASSED), values(states)) && length(states) == 5
                # One worker ran both packages' items, each in its own package.
                @test length(unique(ev.pid for ev in events)) == 1
                @test sort!([(ev.package, ev.name) for ev in events if ev.name == "same"]) == [("A", "same"), ("B", "same")]
                @test all(ev -> basename(ev.root) == ev.package, events)
                # Each package's events directory is in its own run's directory.
                for (k, f) in enumerate(run.runstate.files), ev in events
                    ev.package == p.packages.name[k] && @test ev.events_dir == joinpath(dirname(f.path), "events")
                end
                @test all(ev -> isdir(ev.events_dir), events)
                # A run state for each package, with its items alone, sharing the run's ID.
                records = [read_run_state(f.path) for f in run.runstate.files]
                @test [sort!([it.name for it in rs.items]) for rs in records] == [["db1", "db2", "same"], ["db1", "same"]]
                @test records[1].meta["combined_run"] == records[2].meta["combined_run"] == run.runid
                @test records[1].meta["isolated"] == "false"
                # The run's slots served both packages, and each record holds its own
                # attempts alone: no record says how long the slots stood idle.
                @test all(rs -> !haskey(rs.meta, "slots") && idle_worker_seconds(rs) === nothing, records)
                # The packages' own runs read them as theirs.
                @test sort!(collect(keys(history(joinpath(ws, "lib", "A")).seconds))) == ["db1", "db2", "same"]
                @test sort!(collect(keys(history(joinpath(ws, "lib", "B")).seconds))) == ["db1", "same"]
            end
            # What the call returns: a testset for each package.
            ts = with_runstate_dir() do _
                Runtests.Private.without_enclosing_testset() do
                    Runtests.runtests_mono(ws; workers = 1, logs = :issues, monitor = false)
                end
            end
            @test [r.description for r in ts.results] == ["A", "B"]
        end

        @testset "a shared profile's workers serve every package that has it, its init run in the workspace root" begin
            # Each item writes where the `init` of its worker ran, and the worker.
            log = tempname()
            records(name) = """
                @testitem $(repr(name)) begin
                    open(io -> println(io, Main.SHARED_INIT, '\t', getpid()), $(repr(log)), "a")
                end
                """
            shared = "[profiles.default]\nmonorepo_default = true\ninit = \"global SHARED_INIT = pwd()\"\n"
            ws = e2e_workspace("Inherits" => ["test/a_test.jl" => records("a")],
                               "Copies" => ["test/b_test.jl" => records("b"),
                                            "test/TestItems.toml" => "[profiles.default]\ninit = \"global SHARED_INIT = pwd()\"\n"];
                               root = ["test/r_test.jl" => records("r"), "test/TestItems.toml" => shared])
            lines() = [split(l, '\t') for l in readlines(log)]
            # The same directory, however a system spells it: Windows has short names too.
            in_ws(l) = samefile(l[1], ws) || (println("init ran in ", l[1], ", not ", ws); false)
            with_runstate_dir() do _
                states, run, p = run_mono(ws; workers = 2, logs = :issues, monitor = false)
                @test all(==(PASSED), values(states)) && length(states) == 3
                @test length(p.pools) == 1
                @test all(in_ws, lines())
                # Each package's run state says where the `init` ran, for a replay to run it there.
                records_ = [read_run_state(f.path) for f in run.runstate.files]
                @test [rs.meta["profile_dirs"] for rs in records_] == ["default\t.", "default\t../..", "default\t../.."]
                member = joinpath(ws, "lib", "Inherits")
                replayed = Runtests.Private.replayed_config(read_config(joinpath(member, "test")), records_[2], member)
                @test samefile(replayed.profiles[:default].dir, ws)
                # A package's own run runs the shared `init` where the combined run did.
                rm(log)
                states, _, _ = run_states(member; workers = 1, logs = :issues, monitor = false)
                @test states == Dict("a" => PASSED)
                @test in_ws(only(lines()))
            end
        end

        @testset "a worker's UP line names its profile unless it is the first package's default" begin
            # A's default has an `init`, so B's items get workers of their own.
            ws = e2e_workspace("A" => ["test/a_test.jl" => item_text("a"),
                                       "test/TestItems.toml" => "[profiles.default]\ninit = \"global INITED = true\"\n"],
                               "B" => ["test/b_test.jl" => item_text("b")])
            with_runstate_dir() do _
                (states, _, _), output = capture_run(() -> run_mono(ws; workers = 2, logs = :issues, monitor = false))
                @test states == Dict(("A", "a") => PASSED, ("B", "b") => PASSED)
                ups = filter(l -> occursin(r"\bUP\b", l), split(output, '\n'))
                @test length(ups) == 2
                @test count(l -> endswith(l, "· profile default of B"), ups) == 1
                @test count(l -> occursin("profile", l), ups) == 1
            end
        end

        @testset "profiles of one name in two packages keep their own preferences" begin
            # Each package's `tuned` sets a preference of its own package; an item that
            # gets the other's preferences, or neither's, reads "unset".
            tuned(pkg, mode) = ["test/$(lowercase(pkg))_test.jl" => """
                                    @testitem "$(lowercase(pkg))" profile=:tuned begin
                                        @test get(Base.get_preferences(Base.PkgId($pkg).uuid), "mode", "unset") == "$mode"
                                    end
                                    """,
                                "test/prefs.toml" => "[$pkg]\nmode = \"$mode\"\n",
                                "test/TestItems.toml" => "[profiles.tuned]\npreferences = \"prefs.toml\"\n"]
            ws = e2e_workspace("A" => tuned("A", "a"), "B" => tuned("B", "b"))
            with_runstate_dir() do _
                states, _, p = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                @test states == Dict(("A", "a") => PASSED, ("B", "b") => PASSED)
                @test pool_of(p, item_of(p, "A", "a")) != pool_of(p, item_of(p, "B", "b"))
            end
        end

        @testset "RUNTESTS_ARTIFACT_DIR receives each package's run state, and a failed copy leaves the verdict" begin
            ws = e2e_workspace("A" => ["test/a_test.jl" => item_text("a")], "B" => ["test/b_test.jl" => item_text("b")])
            artifacts = mktempdir()
            with_runstate_dir() do _
                states, run, _ = withenv(() -> run_mono(ws; workers = 1, logs = :issues, monitor = false),
                                         "RUNTESTS_ARTIFACT_DIR" => artifacts)
                @test states == Dict(("A", "a") => PASSED, ("B", "b") => PASSED)
                @test run.exported == artifacts
                # Each package's run directory, under the package's name.
                for (k, name) in enumerate(["A", "B"])
                    path = run.runstate.files[k].path
                    @test read(joinpath(artifacts, name, basename(rundata_dir(path)), basename(path))) == read(path)
                end
                # A file where the directory must go: a warning, and the items keep their verdicts.
                blocked = joinpath(mktempdir(), "file")
                write(blocked, "")
                (states, run, _), output = withenv("RUNTESTS_ARTIFACT_DIR" => joinpath(blocked, "sub")) do
                    capture_run(() -> run_mono(ws; workers = 1, logs = :issues, monitor = false))
                end
                @test occursin("could not copy the run state and logs to `RUNTESTS_ARTIFACT_DIR`", output)
                @test states == Dict(("A", "a") => PASSED, ("B", "b") => PASSED)
                @test isempty(run.exported)
            end
        end

        @testset "an isolated package and an environment directory run in environments of their own" begin
            # One worker goes from pool to pool: the union environment with the shared
            # setups, A's environment directory, and C's own test project with its own
            # setups, whose preferences need not agree with A's.
            ws = e2e_workspace(
                "A" => [
                    "test/a_test.jl" => """
                        @testitem "a" begin
                            using ASetup
                            @test ASetup.x == 1
                            @test Base.identify_package("CSetup") === nothing
                            @test occursin("runtests_union_", Base.active_project())
                        end
                        """,
                    "test/testsetups/ASetup.jl" => "module ASetup\nx = 1\nend\n",
                    "test/LocalPreferences.toml" => "[Foo]\nlevel = 1\n",
                    "test/qa/Project.toml" => "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n",
                    "test/qa/qa_test.jl" => """
                        @testitem "qa" begin
                            @test occursin("runtests_environment_", Base.active_project())
                            @test A isa Module
                        end
                        """,
                ],
                "C" => [
                    "test/c_test.jl" => """
                        @testitem "c" begin
                            using CSetup
                            @test CSetup.y == 2
                            @test Base.identify_package("ASetup") === nothing
                            @test basename(dirname(dirname(Base.active_project()))) == "C"
                        end
                        """,
                    "test/testsetups/CSetup.jl" => "module CSetup\ny = 2\nend\n",
                    "test/LocalPreferences.toml" => "[Foo]\nlevel = 2\n",
                ];
                isolated = ["lib/C"],
            )
            with_runstate_dir() do _
                states, _, _ = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                @test states == Dict(("A", "a") => PASSED, ("A", "qa") => PASSED, ("C", "c") => PASSED)
            end
        end

        @testset "the setups of an isolated package are precompiled for its own workers" begin
            # C's setup is on the load path of C's workers only. Its item asks, before it
            # loads the setup, whether its worker has a cache to load. A name no earlier
            # run compiled.
            setup = string("Own", string(time_ns(); base = 16))
            ws = e2e_workspace(
                "A" => ["test/a_test.jl" => "@testitem \"a\" begin\n    @test true\nend\n"],
                "C" => [
                    "test/c_test.jl" => """
                        @testitem "c" begin
                            @test Base.isprecompiled(Base.identify_package("$setup"))
                            using $setup
                            @test $setup.value() == 3
                        end
                        """,
                    "test/testsetups/$setup/Project.toml" => "name = \"$setup\"\nuuid = \"$(next_uuid())\"\n",
                    "test/testsetups/$setup/src/$setup.jl" => "module $setup\nvalue() = 3\nend\n",
                ];
                isolated = ["lib/C"],
            )
            with_runstate_dir() do _
                (states, _, _), out = capture_run(() -> run_mono(ws; workers = 1, logs = :issues, monitor = false))
                @test states == Dict(("A", "a") => PASSED, ("C", "c") => PASSED)
                @test occursin("precompiling $setup", out)
            end
        end

        @testset "each item runs in its package's root, under its package's settings" begin
            # A's `test_end` outlasts A's limit, and B's profile of the same name has a
            # limit of its own. On one worker, each item, skip expression, `test_end` and
            # failure producer reads its own package's file, and an item that leaves the
            # directory leaves it for none after it.
            ws = e2e_workspace(
                "A" => [
                    "data.txt" => "a",
                    "test/TestItems.toml" => """
                        [run]
                        test_end_timeout = 2
                        [profiles.slow_end]
                        test_end = "sleep(10)"
                        [order]
                        first = ["test_end too slow"]
                        """,
                    "test/a_test.jl" => """
                        @testitem "reads its own root" skip=!isfile("data.txt") begin
                            @test read("data.txt", String) == "a"
                        end
                        @testitem "test_end too slow" profile=:slow_end begin
                            @test true
                        end
                        @testitem "throws" begin
                            using Runtests
                            Runtests.on_failure(dir -> write(joinpath(dir, "seen.txt"), read("data.txt")))
                            cd(tempdir())
                            error("boom")
                        end
                        """,
                ],
                "B" => [
                    "data.txt" => "b",
                    "test/TestItems.toml" => """
                        [run]
                        test_end_timeout = 30
                        [profiles.slow_end]
                        test_end = '''sleep(3); @assert read("data.txt", String) == "b"'''
                        """,
                    "test/b_test.jl" => """
                        @testitem "reads its own root" skip=!isfile("data.txt") begin
                            @test read("data.txt", String) == "b"
                        end
                        @testitem "test_end within its own limit" profile=:slow_end begin
                            @test true
                        end
                        """,
                ];
                root = [
                    "test/TestItems.toml" => "[order]\nlast = [\"after an error\"]\n",
                    "test/root_test.jl" => """
                        @testitem "after an error" begin
                            @test realpath(pwd()) == realpath(dirname(dirname(@__FILE__)))
                        end
                        """,
                ],
            )
            with_runstate_dir() do _
                states, run, p = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                @test states[("A", "reads its own root")] === PASSED && states[("B", "reads its own root")] === PASSED
                @test states[("A", "test_end too slow")] === TIMEDOUT
                @test states[("B", "test_end within its own limit")] === PASSED
                @test states[("A", "throws")] in (FAILED, ERRORED)
                @test states[("Root", "after an error")] === PASSED
                seen = joinpath(attempt_artifacts(run, item_of(p, "A", "throws"), 1), "producer_1", "seen.txt")
                @test isfile(seen) && read(seen, String) == "a"
                # The watchdog allows the longest of the packages' limits.
                @test Runtests.Private.stall_limit(p) >= 30 * 60 + 30
            end
        end

        @testset "a failure stops the others with failfast, and each package's run state says what ran" begin
            # A nested workspace: each package lists its own test project.
            ws = e2e_workspace(
                "A" => ["test/TestItems.toml" => "[order]\nfirst = [\"same\"]\n",
                        "test/a_test.jl" => "@testitem \"same\" begin\n    @test 1 == 2\nend\n" * item_text("a2")],
                "B" => ["test/b_test.jl" => item_text("same")];
                layout = :nested,
            )
            with_runstate_dir() do _
                states, run, p = run_mono(ws; workers = 1, failfast = true, logs = :issues, monitor = false)
                @test states[("A", "same")] === FAILED
                @test states[("A", "a2")] !== PASSED && states[("B", "same")] !== PASSED
                records = [read_run_state(f.path) for f in run.runstate.files]
                @test all(rs -> rs.complete && rs.cancelled, records)
                @test !any(rs -> any(s -> s.state === PASSED, rs.statuses), records)
                # The failure report is with A's logs, by the item's index in A's run state.
                report = failure_log(run, item_of(p, "A", "same"), 1)
                @test isfile(report) && dirname(report) == rundata_dir(run.runstate.files[1].path)
                # A's runs find A's failure; B's, with an item of that name, none.
                @test failing_items(joinpath(ws, "lib", "A")) == ["same"]
                @test isempty(failing_items(joinpath(ws, "lib", "B")))
            end
        end

        @testset "a package whose run state cannot be written runs without one, the others with theirs" begin
            ws = e2e_workspace("A" => ["test/a_test.jl" => item_text("a")], "B" => ["test/b_test.jl" => item_text("b")])
            # The default directories, in a depot of the test's own rather than the one of
            # whoever runs the suite.
            pushfirst!(DEPOT_PATH, mktempdir())
            try
                withenv("RUNTESTS_RUNSTATE_DIR" => nothing) do
                    # B's is a file, so nothing can go in it.
                    b_dir = runstate_dir(joinpath(ws, "lib", "B"))
                    mkpath(dirname(b_dir)); write(b_dir, "")
                    states, run, _ = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                    @test all(==(PASSED), values(states))
                    @test run.runstate.files[1] !== nothing && run.runstate.files[2] === nothing
                    @test collect(keys(history(joinpath(ws, "lib", "A")).seconds)) == ["a"]
                    @test isempty(history(joinpath(ws, "lib", "B")).seconds)
                end
            finally
                popfirst!(DEPOT_PATH)
            end
        end

        @testset "one package in this process, a sandbox in the union environment, a dry run that makes nothing" begin
            ws = e2e_workspace(
                "A" => ["test/a_test.jl" => item_text("here") * """
                    @testitem "sandboxed" sandbox=true begin
                        @test occursin("runtests_union_", Base.active_project())
                    end
                    """],
                "B" => ["test/b_test.jl" => item_text("b")],
            )
            err = try Runtests.runtests_mono(ws; workers = 0, monitor = false); nothing catch e; e end
            @test err isa ArgumentError && occursin("give it one worker or more", slashed(err.msg))
            err = try mono(ws; coverage = true, workers = 0); nothing catch e; e end
            @test err isa ArgumentError && occursin("`coverage` is counted by worker processes", slashed(err.msg))
            with_runstate_dir() do dir
                value, out = capture_run(() -> Runtests.runtests_mono(ws; dry_run = true))
                @test value === nothing && occursin("dry run", out)
                @test isempty(readdir(dir)) && !isfile(joinpath(ws, "lcov.info"))
                events = Runtests.TestItemEvent[]
                states, _, _ = run_mono(ws; packages = ["A"], workers = 0, logs = :issues, monitor = false,
                                        on_event = ev -> ev.kind === :finished && push!(events, ev))
                @test states == Dict(("A", "here") => PASSED, ("A", "sandboxed") => PASSED)
                pid(name) = only(ev.pid for ev in events if ev.name == name)
                @test pid("sandboxed") != 0 && pid("sandboxed") != pid("here")
            end
        end

        @testset "coverage counts each package's src and ext, in lcov.info at the workspace root" begin
            ws = e2e_workspace(
                "A" => ["src/A.jl" => "module A\nf(x) = x + 1\nend\n", "test/a_test.jl" => "@testitem \"a\" begin\n    @test A.f(1) == 2\nend\n"],
                "B" => ["src/B.jl" => "module B\ng(x) = x * 2\nh(x) = x - 1\nend\n",
                        "test/b_test.jl" => "@testitem \"b\" begin\n    @test B.g(2) == 4\nend\n"],
            )
            with_runstate_dir() do _
                states, _, _ = run_mono(ws; workers = 1, coverage = true, logs = :issues, monitor = false)
                @test all(==(PASSED), values(states))
                lcov = read(joinpath(ws, "lcov.info"), String)
                @test sort!([l[4:end] for l in split(lcov, '\n') if startswith(l, "SF:")]) == ["lib/A/src/A.jl", "lib/B/src/B.jl"]
                # `h` never ran.
                @test occursin("DA:3,0", lcov)
            end
        end

        @testset "the import check reads what is written: an import built at run time reaches the union" begin
            # OnlyB is B's test dependency alone. A constructs an import of it and includes
            # a file with one: a shared worker loads it, A's own environment cannot.
            ws = e2e_workspace(
                "A" => ["test/a_test.jl" => """
                            @testitem "constructed" begin
                                Core.eval(Main, :(using OnlyB))
                                @test isdefined(Main, :OnlyB)
                            end
                            @testitem "included" begin
                                include(joinpath(@__DIR__, "testfixtures", "loads.jl"))
                                @test isdefined(Main, :OnlyB)
                            end
                            """,
                        "test/testfixtures/loads.jl" => "Core.eval(Main, :(using OnlyB))\n"],
                "B" => ["test/b_test.jl" => item_text("b")];
                members = ["lib/OnlyB"],
            )
            write_package(joinpath(ws, "lib", "OnlyB"), "OnlyB", []; test_project = false)
            only_b = TOML.parsefile(joinpath(ws, "lib", "OnlyB", "Project.toml"))["uuid"]
            path = joinpath(ws, "lib", "B", "test", "Project.toml")
            t = TOML.parsefile(path)
            t["deps"]["OnlyB"] = only_b
            t["sources"]["OnlyB"] = Dict("path" => "../../OnlyB")
            open(io -> TOML.print(io, t), path, "w")
            with_runstate_dir() do _
                states, _, _ = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                @test states[("A", "constructed")] === PASSED && states[("A", "included")] === PASSED
                # Isolated, A gets what its own run gets.
                write(joinpath(ws, "test", "TestItems.toml"), "[monorepo]\nisolated = [\"lib/A\"]\n")
                states, _, _ = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                @test states[("A", "constructed")] === ERRORED && states[("A", "included")] === ERRORED
            end
        end

        @testset "a combined run is replayed from any of its run states" begin
            ws = e2e_workspace(
                "A" => ["test/a_test.jl" => item_text("a1") * item_text("a2"),
                        "test/qa/Project.toml" => "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n",
                        "test/qa/qa_test.jl" => item_text("qa1")],
                "B" => ["test/b_test.jl" => item_text("b1") * item_text("b2")],
                "C" => ["test/c_test.jl" => item_text("c2")],
            )
            selected(p) = sort!([(p.packages.name[p.items.package[i]], p.items.name[i]) for i in 1:nitems(p)])
            with_runstate_dir() do _
                # The run: the items named `*1` of A and B, under a seed and a timeout of its own.
                _, run, _ = run_mono(ws; workers = 1, seed = 7, timeout = 123, name = r"1$", logs = :issues, monitor = false)
                a_record, b_record = (f.path for f in run.runstate.files)
                # Each run state has the run's packages, and the replay finds the others by the run's ID.
                write(joinpath(ws, "lib", "A", "test", "a_test.jl"), item_text("a1") * item_text("a2") * item_text("a31"))
                r = mono(ws; replay = b_record)
                @test selected(r.plan) == [("A", "a1"), ("A", "qa1"), ("B", "b1")]
                @test r.plan.cfg.seed == 7 && all(i -> item_cfg(r.plan, i).timeout_s == 123, 1:nitems(r.plan))
                @test r.plan.cfg.replayed_from == b_record
                # A deliberate narrowing replays less, and says nothing is missing.
                r = mono(ws; replay = a_record, packages = ["B"])
                @test selected(r.plan) == [("B", "b1")] && !any(startswith("partial replay"), r.plan.notes)
                # A moved environment directory: the item runs in this checkout's, and the
                # replay says where it ran before.
                mv(joinpath(ws, "lib", "A", "test", "qa"), joinpath(ws, "lib", "A", "test", "qa2"))
                @test_logs (:warn, r"\"qa1\" ran in test/qa in the replayed run, and runs in test/qa2") match_mode = :any mono(ws; replay = a_record)
                # A run state that is gone makes a partial replay, said as one; with none left, there is nothing to replay.
                rm(b_record)
                r = mono(ws; replay = a_record)
                @test selected(r.plan) == [("A", "a1"), ("A", "qa1")]
                @test any(==("partial replay: no run state of B is left from the replayed run"), r.plan.notes)
                err = try mono(ws; replay = a_record, packages = ["B"]); nothing catch e; e end
                @test err isa ConfigError && occursin("has a run state of the run", slashed(err.msg))
                # A run state of one package is replayed by its own `runtests`.
                single = read_run_state(a_record)
                err = try Runtests.Private.replay_records(a_record, find_participants(ws)); nothing catch e; e end
                @test err === nothing
                # A run state whose environment directories do not pair with its items is refused.
                broken = Runtests.Private.RunStateRecord((f === :meta ? merge(single.meta, Dict("environments" => "")) :
                                                          getfield(single, f) for f in fieldnames(Runtests.Private.RunStateRecord))...)
                err = try Runtests.Private.check_replayed_environments(RawItem[], [broken], [joinpath(ws, "lib", "A")]); nothing catch e; e end
                @test err isa ConfigError && occursin("records 1 environment directory for 2 test items", slashed(err.msg))
            end
        end

        @testset "a worker that cannot start leaves every run state finished, and passes nothing it did not run" begin
            ws = e2e_workspace(
                "A" => ["test/a_test.jl" => item_text("a"), "test/TestItems.toml" => "[profiles.default]\ninit = \"error(\\\"no\\\")\"\n"],
                "B" => ["test/b_test.jl" => item_text("b")],
            )
            with_runstate_dir() do _
                # The item that asked for the worker is told why it got none, and the run stops.
                states, run, _ = run_mono(ws; workers = 1, logs = :issues, monitor = false)
                @test states[("A", "a")] === ERRORED && states[("B", "b")] !== PASSED
                records = [read_run_state(f.path) for f in run.runstate.files]
                @test all(rs -> rs.complete && rs.cancelled, records)
                @test !any(rs -> any(s -> s.state === PASSED, rs.statuses), records)
            end
        end

        @testset "a root package's Pkg.test runs the combined suites" begin
            # The root's `test/runtests.jl` launches the combined run, and has no items of its own.
            ws = e2e_workspace("A" => ["test/a_test.jl" => item_text("a")], "B" => ["test/b_test.jl" => item_text("b")];
                               root = ["test/runtests.jl" => "using Runtests\nRuntests.runtests_mono()\n"])
            with_runstate_dir() do dir
                log = joinpath(dir, "pkgtest.log")
                script = "using Pkg; Pkg.activate($(repr(ws)); io = devnull); Pkg.test(\"Root\")"
                ok = success(pipeline(ignorestatus(addenv(`$(Base.julia_cmd()) --startup-file=no -e $script`,
                                                          "JULIA_LOAD_PATH" => nothing)); stdout = log, stderr = log))
                out = read(log, String)
                echo_captured(out)
                @test ok
                @test occursin("packages: A (1 item), B (1 item)", out)
                @test occursin("skipped: . (its test/ has only runtests.jl", out)
                @test occursin("tests passed", out)
            end
        end

        @testset "activate_mono: the union environment and the shared setups, which deactivate takes back" begin
            ws = e2e_workspace("A" => ["test/a_test.jl" => item_text("a"), "test/testsetups/ASetup.jl" => "module ASetup end\n"],
                               "C" => ["test/c_test.jl" => item_text("c"), "test/testsetups/CSetup.jl" => "module CSetup end\n"];
                               isolated = ["lib/C"])
            project, load_path = Base.active_project(), copy(LOAD_PATH)
            try
                active = redirect_stdout(devnull) do
                    Runtests.activate_mono(ws)
                end
                @test occursin("runtests_union_", active) && Base.active_project() == active
                @test joinpath(ws, "lib", "A", "test", "testsetups") in LOAD_PATH
                @test !(joinpath(ws, "lib", "C", "test", "testsetups") in LOAD_PATH)
                @test Base.identify_package("ASetup") !== nothing && Base.identify_package("CSetup") === nothing
                # An item runs as on a shared worker, as an item of the package whose
                # directory holds its file, or the REPL's directory for a pasted one: in
                # the union environment, with its package and setups, in its root.
                body = quote
                    using ASetup
                    @test pwd() == $(joinpath(ws, "lib", "A"))
                    @test A isa Module
                    @test occursin("runtests_union_", Base.active_project())
                end
                state(ts) = Runtests.RuntestsWorkers.state_of(ts)
                pasted(dir) = cd(dir) do
                    redirect_stdout(devnull) do
                        Core.eval(Main, Expr(:macrocall, Symbol("@testitem"), LineNumberNode(1, Symbol("REPL[1]")), "pasted", body))
                    end
                end
                @test state(pasted(joinpath(ws, "lib", "A", "test"))) === PASSED
                file = joinpath(ws, "lib", "A", "test", "more.jl")
                write(file, "@testitem \"included\" begin\n$(join(string.(body.args), "\n"))\nend\n")
                @test state(cd(() -> redirect_stdout(() -> include(file), devnull), ws)) === PASSED
                # In no package, and in an isolated one, it says what to do instead.
                for (dir, says) in ((ws, "is in none of A, C: `cd` into the package's directory"),
                                    (joinpath(ws, "lib", "C"), "C is isolated"))
                    err = try pasted(dir); nothing catch e; e end
                    @test err isa ConfigError && occursin(says, slashed(err.msg))
                end
                redirect_stdout(Runtests.deactivate, devnull)
                @test Base.active_project() == project && LOAD_PATH == load_path && !isdir(dirname(active))
            finally
                Runtests.is_activated() && redirect_stdout(Runtests.deactivate, devnull)
                Base.set_active_project(project)
            end
            # Two setups of one name stop it before anything changes.
            ws = make_workspace("A" => ["test/a_test.jl" => item_text("a"), "test/testsetups/Common.jl" => "module Common end\n"],
                                "B" => ["test/b_test.jl" => item_text("b"), "test/testsetups/Common.jl" => "module Common end\n"])
            err = try Runtests.activate_mono(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("`Common` in lib/A/test/testsetups and in lib/B/test/testsetups", slashed(err.msg))
            @test Base.active_project() == project && LOAD_PATH == load_path && !Runtests.is_activated()
            # So does a setup that a package of the union environment would shadow.
            ws = make_workspace("A" => ["test/a_test.jl" => item_text("a"), "test/testsetups/X.jl" => "module X end\n"],
                                "B" => ["test/b_test.jl" => item_text("b")]; deps = Dict("B" => ["X"]))
            err = try Runtests.activate_mono(ws); nothing catch e; e end
            @test err isa ConfigError && occursin("`X` in lib/A/test/testsetups, which lib/B/test/Project.toml declares", slashed(err.msg))
            @test Base.active_project() == project && LOAD_PATH == load_path && !Runtests.is_activated()
        end

        @testset "chores_mono says which items can share a worker: the groups of profiles, and where each comes from" begin
            shared = "[profiles.default]\nmonorepo_default = true\ninit = \"global SHARED_INIT = pwd()\"\n"
            ws = make_workspace(
                "Takes" => ["test/a_test.jl" => item_text("a")],
                "Copies" => ["test/b_test.jl" => item_text("b"), "test/TestItems.toml" =>
                    "[profiles.default]\ninit = \"global SHARED_INIT = pwd()\"\n"],
                "Differs" => ["test/c_test.jl" => item_text("c"), "test/TestItems.toml" =>
                    "[profiles.default]\ninit = \"global OTHER = 1\"\nthreads = \"3\"\n\n[profiles.fast]\nenv = { FAST = \"1\" }\n"];
                root = ["test/r_test.jl" => item_text("r"), "test/TestItems.toml" => shared],
            )
            groups(ws) = split(chomp(sprint(io -> Runtests.Private.print_worker_groups(io, find_participants(ws)))), '\n')
            config = joinpath("test", "TestItems.toml")
            @test groups(ws) == [
                "workers: 3 groups, and an item shares a worker only with the items of its group",
                "  `default` of Root, Copies and Takes: init expression",
                "    shared by $config",
                "    the same in the test/TestItems.toml of Copies, which can leave it out",
                "  `default` of Differs: threads 3 · init expression",
                "  `fast` of Differs: FAST=1",
            ]
            # Without `monorepo_default`, the same profile in two packages is two groups, and said to be the same.
            write(joinpath(ws, "test", "TestItems.toml"), replace(shared, "monorepo_default = true\n" => ""))
            @test groups(ws)[1:5] == [
                "workers: 5 groups, and an item shares a worker only with the items of its group",
                "  `default` of Root: init expression",
                "  `default` of Copies: init expression",
                "    the same as the root's `default`: `monorepo_default = true` in $config makes them one group",
                "  `default` of Differs: threads 3 · init expression",
            ]
            # Profiles that start their workers alike are one group, whichever packages declare them.
            plain = make_workspace("A" => ["test/a_test.jl" => item_text("a")], "B" => ["test/b_test.jl" => item_text("b")];
                                   root = nothing)
            @test groups(plain) == ["workers: one group, so the items of every package can share a worker",
                                    "  `default` of A and B: sets nothing"]
            # All of it in one report, its paths from the workspace root.
            (value, out) = with_runstate_dir(_ -> capture_run(() -> Runtests.chores_mono(ws; dry_run = true)))
            @test value === true
            @test count("[TEST]", out) == 1 && occursin("[TEST] chores of 4 packages, checking only", out)
            @test occursin("│ Copies\n│   setups: none", out)
            @test occursin("config: $(joinpath("lib", "Copies", "test", "TestItems.toml")), valid", out)
            @test occursin("│ workers: 5 groups", out) && occursin("│ imports: each loads", out)
        end

        @testset "chores_mono: what no chore fixes stops it first, and the imports are checked after the chores" begin
            ws = e2e_workspace(
                "A" => ["test/a_test.jl" => item_text("a"),
                        "test/testsetups/ASetup.jl" => "module ASetup\nusing OnlyB\nend\n",
                        "test/runtests.jl" => "using Runtests\nRuntests.runtests(; workers = 2)\n"],
                "B" => ["test/b_test.jl" => item_text("b"), "test/runtests.jl" => "using B\nusing Runtests\n\nRuntests.runtests()\n"],
                "C" => ["test/c_test.jl" => item_text("c"), "test/testsetups/Common.jl" => "module Common end\n"],
                "D" => ["test/d_test.jl" => item_text("d"), "test/testsetups/Common.jl" => "module Common end\n"];
                deps = Dict("B" => ["OnlyB"]),
            )
            # The clash is in the last packages, and no package's chores ran: A's setup is still a module.
            err = with_runstate_dir(_ -> try Runtests.chores_mono(ws); nothing catch e; e end)
            @test err isa ConfigError && occursin("`Common` in lib/C/test/testsetups and in lib/D/test/testsetups", slashed(err.msg))
            @test isfile(joinpath(ws, "lib", "A", "test", "testsetups", "ASetup.jl"))
            rm(joinpath(ws, "lib", "D", "test", "testsetups"); recursive = true)
            # A setup that imports another package's test dependency, and a launcher that
            # does more than run the suite: said, and nothing changed.
            value, out = with_runstate_dir(_ -> capture_run(() -> Runtests.chores_mono(ws; dry_run = true)))
            @test value === false
            @test occursin("imports OnlyB, which is not in [deps] of A's test project", out)
            @test occursin("$(joinpath("lib", "A", "test", "runtests.jl")) does more than call", out)
            @test !occursin(joinpath("lib", "B", "test", "runtests.jl"), out)
            @test isfile(joinpath(ws, "lib", "A", "test", "testsetups", "ASetup.jl"))
        end
    end
end
