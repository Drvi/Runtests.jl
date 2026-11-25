# Subsetting a run. Name, tags, path and line each narrow what runs; they combine;
# and none of them may quietly change what the items that do run mean — forced order
# still holds over whatever survived.

using Runtests.Private: PASSED, prepare, nitems, NoTestsError

const SUITE = string(
    """
    @testitem "adds numbers" tags=[:fast, :math] begin
        @test 1 + 1 == 2
    end

    @testitem "multiplies numbers" tags=[:fast] begin
        @test 2 * 3 == 6
    end

    @testitem "solves slowly" tags=[:slow, :math] begin
        @test true
    end
    """
)

const THROTTLED = """
@testitem "step one" tags=[:seq] throttle=:c begin
    @test true
end

@testitem "step two" throttle=:c begin
    @test true
end

@testitem "unrelated" begin
    @test true
end
"""

# What a selection actually resolves to, by name.
filtered(paths...; kwargs...) =
    (p = first(prepare(paths; kwargs...)); sort([p.items.name[i] for i in 1:nitems(p)]))

@testset "filters" begin
    dir = make_pkg("Filtered", "test/a_test.jl" => SUITE, "test/sub/b_test.jl" => THROTTLED)

    @testset "by name, exactly or by pattern" begin
        @test filtered(dir; name="adds numbers") == ["adds numbers"]
        @test filtered(dir; name=r"numbers$") == ["adds numbers", "multiplies numbers"]
        @test_throws NoTestsError filtered(dir; name="no such item")
    end

    @testset "by tag, and an item must carry all of them" begin
        @test filtered(dir; tags=:fast) == ["adds numbers", "multiplies numbers"]
        @test filtered(dir; tags=[:fast, :math]) == ["adds numbers"]
        @test filtered(dir; tags=[:slow, :math]) == ["solves slowly"]
        @test_throws NoTestsError filtered(dir; tags=[:fast, :slow])
    end

    @testset "by tag expression: `!`, `&&` and `||`" begin
        @test filtered(dir; tags="!slow") ==
            ["adds numbers", "multiplies numbers", "step one", "step two", "unrelated"]
        @test filtered(dir; tags="fast && !math") == ["multiplies numbers"]
        @test filtered(dir; tags="slow || fast") == ["adds numbers", "multiplies numbers", "solves slowly"]
        @test filtered(dir; tags="math && !fast || fast && !math") == ["multiplies numbers", "solves slowly"]
        @test_throws NoTestsError filtered(dir; tags="fast && slow")
        @test_throws ArgumentError filtered(dir; tags=":fast")
        @test_throws ArgumentError filtered(dir; tags="fast &&")
        @test_throws ArgumentError filtered(dir; tags="fast & slow")
        @test_throws ArgumentError filtered(dir; tags="")
    end

    @testset "a tag written as a string is a tag, and a bad one says so" begin
        # Strings are what a caller reaches for first, and the element types line
        # up badly: a `Vector{String}` handed to a `Vector{Symbol}` field fails
        # somewhere inside `convert`, naming neither the keyword nor the value.
        @test filtered(dir; tags=["fast"]) == filtered(dir; tags=[:fast])
        @test filtered(dir; tags=("fast", "math")) == filtered(dir; tags=[:fast, :math])
        @test filtered(dir; tags=Set([:fast])) == filtered(dir; tags=[:fast])
        # An expression split across elements would read as a tag named `!slow`,
        # which matches nothing and reports nothing.
        e = try
            filtered(dir; tags=["!slow"])
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("!slow", e.msg) && occursin("one string", e.msg)
        for bad in (["fast || slow"], [1, 2], 42)
            @test_throws ArgumentError filtered(dir; tags=bad)
        end
    end

    @testset "by path: a file, a directory, or a line inside one" begin
        @test filtered(joinpath(dir, "test", "a_test.jl")) ==
            ["adds numbers", "multiplies numbers", "solves slowly"]
        @test filtered(joinpath(dir, "test", "sub")) == ["step one", "step two", "unrelated"]
        # `file.jl:line` is the item that line is inside.
        @test filtered(string(joinpath(dir, "test", "a_test.jl"), ":6")) == ["multiplies numbers"]
        # Beside another file or directory, the line could pick an item there instead.
        for other in (joinpath(dir, "test", "sub", "b_test.jl"), joinpath(dir, "test", "sub"),
                      string(joinpath(dir, "test", "sub", "b_test.jl"), ":6"))
            e = try
                filtered(string(joinpath(dir, "test", "a_test.jl"), ":6"), other)
            catch err
                err
            end
            @test e isa ArgumentError && occursin("without other files or directories", e.msg)
        end
    end

    @testset "a line picks the item it is in; other selections keep it or leave nothing" begin
        at(line) = string(joinpath(dir, "test", "a_test.jl"), ":", line)
        # Line 10 is inside "solves slowly", which is not :fast. The :fast item above
        # it is not what the line names, so nothing runs.
        @test_throws NoTestsError filtered(at(10); tags = :fast)
        @test filtered(at(10); tags = :math) == ["solves slowly"]
        @test_throws NoTestsError filtered(at(6); name = "adds numbers")
        @test filtered(at(6); name = r"numbers") == ["multiplies numbers"]
    end

    # What `f` throws, or `nothing`.
    caught(f) = try
        f()
        nothing
    catch err
        err
    end

    @testset "several paths select what any of them does; the package or test/ among them, all of it" begin
        file = joinpath(dir, "test", "a_test.jl")
        everything = filtered(dir)
        @test filtered(dir, file) == everything
        @test filtered(joinpath(dir, "test"), file) == everything
        @test filtered(file, joinpath(dir, "test")) == everything
        # A path given twice is one path, and said once.
        p, _ = prepare((file, file); announce = false)
        @test p.selection == "paths $(joinpath("test", "a_test.jl"))"
        # A line picks one item, so the whole suite beside it is a contradiction.
        e = caught(() -> filtered(dir, "$file:6"))
        @test e isa ArgumentError && occursin("without other files or directories", e.msg)
    end

    @testset "a line is one the file has" begin
        file = joinpath(dir, "test", "a_test.jl")
        n = countlines(file)
        for (arg, says) in ("$file:0" => "lines are numbered from 1",
                            "$file:$(n + 1)" => "has $n lines, so there is no line $(n + 1)",
                            "$file:99999999999" => "lines, so there is no line")
            e = caught(() -> filtered(arg))
            @test e isa ArgumentError && occursin(says, e.msg)
        end
        @test filtered("$file:$n") == ["solves slowly"]
        # Above the file's first item there is no item, and the error says where it is.
        headed = make_pkg("Headed", "test/h_test.jl" => "# a header\n\n@testitem \"first\" begin\nend\n")
        e = caught(() -> filtered(joinpath(headed, "test", "h_test.jl") * ":1"))
        @test e isa NoTestsError
        @test occursin("line 1 of $(joinpath("test", "h_test.jl")) is above its first test item, at line 3", sprint(showerror, e))
    end

    @testset "an empty or blank selection is a mistake, not a selection of all or of none" begin
        for kw in ((; name = ""), (; name = "  "), (; name = String[]), (; name = Set{String}()),
                   (; tags = Symbol[]), (; tags = String[]))
            @test caught(() -> filtered(dir; kw...)) isa ArgumentError
        end
    end

    @testset "a name the suite does not have is answered with the nearest it does" begin
        said(f) = (e = caught(f); e isa NoTestsError ? sprint(showerror, e) : repr(e))
        @test occursin("the suite has no item called \"Adds numbers\" (did you mean \"adds numbers\"?)",
                       said(() -> filtered(dir; name = "Adds numbers")))
        msg = said(() -> filtered(dir; name = ["multiplys numbers", "nothing like it"]))
        @test occursin("\"multiplys numbers\" (did you mean \"multiplies numbers\"?)", msg)
        @test occursin("\"nothing like it\"", msg)
        # Beside a name the suite has, one it does not would be left out without a word.
        msg = said(() -> filtered(dir; name = ["adds numbers", "multiplys numbers"]))
        @test occursin("\"multiplys numbers\" (did you mean \"multiplies numbers\"?)", msg)
        @test !occursin("\"adds numbers\"", msg)
        # A name the suite has, that another selection leaves out, needs no hint.
        @test !occursin("has no item called", said(() -> filtered(dir; name = "adds numbers", tags = :slow)))
    end

    @testset "a module stands for the whole suite, and is given on its own" begin
        e = caught(() -> filtered(Runtests, dir))
        @test e isa ArgumentError && occursin("a module stands for its package's whole suite", e.msg)
    end

    @testset "a misspelled keyword is answered with the one meant" begin
        for (kw, meant) in (:tag => "(did you mean `tags`?)", :worker => "(did you mean `workers`?)",
                            :dryrun => "(did you mean `dry_run`?)", :timout => "(did you mean `timeout`?)")
            e = caught(() -> prepare((dir,); announce = false, NamedTuple{(kw,)}((1,))...))
            @test e isa ArgumentError
            @test occursin("unknown keyword `$kw` $meant", e.msg)
            # Every keyword it could have been is listed, selections and settings alike.
            @test all(k -> occursin("`$k`", e.msg), (:name, :tags, :group, :dry_run, :replay, :config, :workers, :seed))
        end
        # Internal `nunits` is never accepted as a user keyword.
        e = caught(() -> Runtests.runtests(dir; dry_run = true, nunits = 5))
        @test e isa ArgumentError && occursin("unknown keyword `nunits`", e.msg)
    end

    @testset "bad keywords and values fail before scanning or announcing" begin
        # Unknown keyword and invalid setting values must fail before printing
        # "reading test files" or resolving/scanning any files.
        missing_path = joinpath(dir, "does_not_exist_at_all")
        for call in (
            () -> Runtests.runtests(missing_path; workres = 2),
            () -> Runtests.runtests(dir; workers = -1),
            () -> Runtests.runtests(dir; logs = :bogus),
            () -> Runtests.runtests(dir; timeout = -5),
            () -> Runtests.runtests(dir; worker_init = 123),
            () -> Runtests.runtests(dir; test_end = "not an expr"),
            () -> Runtests.runtests(dir; config = 123),
            () -> Runtests.runtests(dir; replay = 123),
            () -> Runtests.runtests(dir; coverage = true, workers = 0),
        )
            err, out = capture_run() do
                caught(call)
            end
            @test err isa ArgumentError
            @test isempty(out)
        end

        # `runtestsf` validates all keywords even when nothing is failing / no run state exists.
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            for call in (
                () -> Runtests.runtestsf(dir; workres = 2),
                () -> Runtests.runtestsf(dir; nunits = 5),
                () -> Runtests.runtestsf(dir; workers = -1),
                () -> Runtests.runtestsf(dir; on_event = 123),
                () -> Runtests.runtestsf(dir; dry_run = "yes"),
            )
                err, out = capture_run() do
                    caught(call)
                end
                @test err isa ArgumentError
                @test isempty(out)
            end
        end
    end

    @testset "a path beside test/ is not under it" begin
        # `test2/` starts with the same letters as `test/` and is somewhere else.
        mkpath(joinpath(dir, "test2"))
        write(joinpath(dir, "test2", "c_test.jl"), "@testitem \"elsewhere\" begin\nend\n")
        e = try
            filtered(joinpath(dir, "test2", "c_test.jl"))
        catch err
            err
        end
        @test e isa ArgumentError && occursin("is not under", e.msg)
        rm(joinpath(dir, "test2"); recursive = true)
    end

    @testset "a path of another package's tests is that package's, and a call runs one package" begin
        # A monorepo's layout: a package below the one being run, with tests of its own.
        sub = joinpath(dir, "lib", "Sub")
        mkpath(joinpath(sub, "test"))
        write(joinpath(sub, "Project.toml"), "name = \"Sub\"\nuuid = \"$(next_uuid())\"\n")
        write(joinpath(sub, "test", "s_test.jl"), "@testitem \"sub\" begin\nend\n")
        thrown_by(paths...) = try
            filtered(paths...)
            nothing
        catch err
            err
        end
        for (paths, owner) in (((dir, joinpath(sub, "test", "s_test.jl")), sub),
                               ((joinpath(sub, "test"), joinpath(dir, "test", "a_test.jl")), dir))
            e = thrown_by(paths...)
            @test e isa ArgumentError
            @test occursin("$(last(paths)) belongs to the package at $owner", e.msg)
            @test occursin("a call runs one package's tests, so give each package a call of its own", e.msg)
        end
        # On its own, the other package's path runs that package.
        @test filtered(joinpath(sub, "test", "s_test.jl")) == ["sub"]
        rm(joinpath(dir, "lib"); recursive = true)
    end

    @testset "a module stands for its package's directory" begin
        @test Runtests.Private.resolve_target((Runtests,)).root == pkgdir(Runtests)
        @test_throws r"could not find a directory for module" Runtests.Private.resolve_target((Module(:Loose),))
    end

    @testset "name, tags and path narrow together" begin
        @test filtered(joinpath(dir, "test", "a_test.jl"); tags=:math) ==
            ["adds numbers", "solves slowly"]
        @test filtered(joinpath(dir, "test", "a_test.jl"); tags=:math, name=r"^adds") ==
            ["adds numbers"]
        # A path that holds none of the tagged items is no items, not all of them.
        @test_throws NoTestsError filtered(joinpath(dir, "test", "sub"); tags=:math)
    end

    @testset "selecting one item of a throttle selects that item and no other" begin
        # A throttle says these items may not run at the same time as each other. It
        # says nothing about any of them needing the others to have run, so a
        # selection that reaches one of them does not drag the rest in.
        @test filtered(dir; name="step two") == ["step two"]
        @test filtered(dir; tags=:seq) == ["step one"]
        @test filtered(string(joinpath(dir, "test", "sub", "b_test.jl"), ":6")) == ["step two"]
    end

    @testset "the run says what it selected" begin
        _, out = capture_run() do
            prepare((dir,); name="step two")
        end
        @test occursin("reading test files under $(joinpath("test", "")) matching name = \"step two\"", out)
        @test occursin("found 1 test item", out)
        _, plain = capture_run() do
            prepare((dir,); tags=:fast)
        end
        @test occursin("matching tags = [:fast]", plain)
        _, expr = capture_run() do
            prepare((dir,); tags="!slow")
        end
        @test occursin("matching tags = \"!slow\"", expr)
    end

    @testset "a filtered run still honours forced order" begin
        ordered = make_pkg(
            "FilteredOrder",
            "test/a_test.jl" => string(
                journal_item("one"; opts="tags=[:pick]"),
                journal_item("two"; opts="tags=[:pick]"),
                journal_item("three"),
            ),
            "test/TestItems.toml" => "[order]\nfirst = [\"two\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(ordered; workers=1, tags=:pick, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test [r.name for r in rows] == ["two", "one"]
    end

    @testset "[order] naming an item the filter removed is not an error" begin
        # Only a full run can tell a typo from an item the filter took out.
        ordered = make_pkg(
            "FilteredMissing",
            "test/a_test.jl" => SUITE,
            "test/TestItems.toml" => "[order]\nfirst = [\"solves slowly\"]\n"
        )
        @test filtered(ordered; tags=:fast) == ["adds numbers", "multiplies numbers"]
    end
end

@testset "an item's name given as a path says how to give it" begin
    err = try
        Runtests.Private.resolve_target(("adds numbers",))
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("no such file or directory", err.msg) && occursin("give `name = \"adds numbers\"`", err.msg)
    # What looks like a path is a path that is not there, and nothing else.
    err = try
        Runtests.Private.resolve_target((joinpath("test", "missing_test.jl"),))
    catch e
        e
    end
    @test err isa ArgumentError && !occursin("name =", err.msg)
end

@testset "no-test-files error names the real directory and hints when pwd() has a test/ project" begin
    # Simulates starting `julia` without `--project` (active project is an empty global env)
    # while `pwd()` is a package checkout that has `test/`.
    empty_env = mktempdir()
    write(joinpath(empty_env, "Project.toml"), "[deps]\n")
    pkg = make_pkg("HerePkg", "test/a_test.jl" => "@testitem \"ok\" begin\n    @test true\nend\n")
    orig_proj = Base.active_project()
    try
        Base.set_active_project(joinpath(empty_env, "Project.toml"))
        err, out = cd(pkg) do
            err_ref = Ref{Any}(nothing)
            _, printed = capture_run() do
                try
                    prepare(())
                catch e
                    err_ref[] = e
                end
            end
            err_ref[], printed
        end
        @test err isa NoTestsError
        msg = sprint(showerror, err)
        @test occursin(Base.contractuser(joinpath(empty_env, "test")), out)
        @test occursin(Base.contractuser(joinpath(empty_env, "test")), msg)
        @test occursin("from the active project", msg)
        @test occursin("has a project with a `test/` directory", msg)
        @test occursin("runtests(\".\")", msg)
    finally
        Base.set_active_project(orig_proj)
    end
end
