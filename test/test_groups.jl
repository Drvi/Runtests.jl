# Named selections. `[groups]` in TestItems.toml gives tag expressions names, which a
# run selects by with the `group` keyword or `RUNTESTS_GROUP`, and the `default` group
# when nothing else selects; and a selection that names a tag no item carries is a
# slip to report, not a selection of everything or of nothing.

using Runtests.Private: prepare, nitems, NoTestsError, ConfigError, read_config, read_run_state,
    runstate_files, failing_items, PASSED, FAILED

const GROUPED = """
@testitem "core one" tags=[:core] begin
    @test true
end

@testitem "core slow" tags=[:core, :slow] begin
    @test true
end

@testitem "gpu one" tags=[:gpu] begin
    @test true
end

@testitem "untagged" begin
    @test true
end
"""

const GROUPS = """
[groups]
default = "!gpu"
gpu = "gpu"
quick = "core && !slow"
"""

const EVERY_ITEM = ["core one", "core slow", "gpu one", "untagged"]

# What a selection resolves to, by name.
selected(path; kwargs...) =
    (p = first(prepare((path,); announce = false, kwargs...)); sort([p.items.name[i] for i in 1:nitems(p)]))

# The exception `f` throws, or `nothing`.
thrown(f) = try
    f()
    nothing
catch e
    e
end

# What `chores` returned, or the exception it threw, with what it printed.
groups_chores(args...; kw...) = capture_run(() -> try
    Runtests.chores(args...; kw...)
catch e
    e isa Runtests.ChoresError || rethrow()
    e
end)

@testset "groups" begin
    dir = make_pkg("Grouped", "test/a_test.jl" => GROUPED, "test/TestItems.toml" => GROUPS)
    # This process's own RUNTESTS_GROUP, if it has one, is not this file's to inherit.
    withenv("RUNTESTS_GROUP" => nothing) do

    @testset "a run that selects nothing else selects the default group" begin
        @test selected(dir) == ["core one", "core slow", "untagged"]
    end

    @testset "the group keyword selects a group, by string or by symbol" begin
        @test selected(dir; group = "gpu") == ["gpu one"]
        @test selected(dir; group = :quick) == ["core one"]
        @test selected(dir; group = "default") == ["core one", "core slow", "untagged"]
    end

    @testset "RUNTESTS_GROUP selects a group, and the keyword wins over it" begin
        withenv("RUNTESTS_GROUP" => "gpu") do
            @test selected(dir) == ["gpu one"]
            @test selected(dir; group = "quick") == ["core one"]
        end
        # Surrounding blanks are not part of a name.
        withenv("RUNTESTS_GROUP" => " quick\n") do
            @test selected(dir) == ["core one"]
        end
        # Empty is unset, as a CI matrix leaves it for a lane without a group.
        withenv("RUNTESTS_GROUP" => "") do
            @test selected(dir) == ["core one", "core slow", "untagged"]
        end
    end

    @testset "`all` is the whole suite, whatever the default" begin
        @test selected(dir; group = "all") == EVERY_ITEM
        withenv("RUNTESTS_GROUP" => "all") do
            @test selected(dir) == EVERY_ITEM
        end
        # And it means the same where nothing declares groups.
        plain = make_pkg("Ungrouped", "test/a_test.jl" => GROUPED)
        @test selected(plain; group = "all") == EVERY_ITEM
        @test selected(plain) == EVERY_ITEM
    end

    @testset "any other selection takes the place of the default group" begin
        @test selected(dir; tags = :gpu) == ["gpu one"]
        @test selected(dir; name = "gpu one") == ["gpu one"]
        @test selected(dir; name = r"one$") == ["core one", "gpu one"]
        # A path, and a line, select too.
        @test selected(joinpath(dir, "test", "a_test.jl")) == EVERY_ITEM
        @test selected(string(joinpath(dir, "test", "a_test.jl"), ":10")) == ["gpu one"]
    end

    @testset "a group narrows together with the other selections" begin
        @test selected(dir; group = "gpu", tags = :gpu) == ["gpu one"]
        @test selected(dir; group = "default", tags = :slow) == ["core slow"]
        @test selected(dir; group = "default", name = r"^core") == ["core one", "core slow"]
        @test_throws NoTestsError selected(dir; group = "quick", name = "gpu one")
        withenv("RUNTESTS_GROUP" => "default") do
            @test selected(dir; tags = :core) == ["core one", "core slow"]
            @test_throws NoTestsError selected(dir; name = "gpu one")
        end
    end

    @testset "a group that is not declared is an error, naming those that are" begin
        err = thrown(() -> selected(dir; group = "gpuu"))
        @test err isa ConfigError
        msg = sprint(showerror, err)
        @test occursin("the `group` keyword asks for group `gpuu`", msg)
        @test occursin("`default`, `gpu`, `quick`", msg)
        @test occursin("did you mean `gpu`", msg)
        withenv("RUNTESTS_GROUP" => "nightly") do
            err = thrown(() -> selected(dir))
            @test err isa ConfigError
            @test occursin("`RUNTESTS_GROUP` asks for group `nightly`", sprint(showerror, err))
            # Whatever else the call selects: a misspelled lane must not run something else.
            @test thrown(() -> selected(dir; tags = :core)) isa ConfigError
        end
        # Names are matched exactly, as a TOML key is written.
        @test thrown(() -> selected(dir; group = "GPU")) isa ConfigError
        plain = make_pkg("NoGroups", "test/a_test.jl" => GROUPED)
        err = thrown(() -> selected(plain; group = "gpu"))
        @test err isa ConfigError && occursin("declares no [groups]", sprint(showerror, err))
        withenv("RUNTESTS_GROUP" => "gpu") do
            @test thrown(() -> selected(plain)) isa ConfigError
        end
        @test thrown(() -> selected(dir; group = 1)) isa ArgumentError
        @test thrown(() -> selected(dir; group = "")) isa ArgumentError
    end

    @testset "the run says which group it selected, and what chose it" begin
        _, out = capture_run(() -> Runtests.runtests(dir; dry_run = true, group = "gpu"))
        @test occursin("group `gpu` = \"gpu\", from the `group` keyword", out)
        _, out = capture_run(() -> Runtests.runtests(dir; dry_run = true))
        @test occursin("group `default` = \"!gpu\", the default", out)
        _, out = withenv("RUNTESTS_GROUP" => "quick") do
            capture_run(() -> Runtests.runtests(dir; dry_run = true))
        end
        @test occursin("group `quick` = \"core && !slow\", from `RUNTESTS_GROUP`", out)
        # The whole suite is no group, and says nothing of one.
        _, out = capture_run(() -> Runtests.runtests(dir; dry_run = true, group = "all"))
        @test !occursin("group", out)
    end

    @testset "[groups] is read as strictly as the rest of the file" begin
        for (toml, what) in (
                "[groups]\nall = \"core\"\n" => "is the whole suite",
                "[groups]\nquick = [\"core\"]\n" => "must be a tag expression written as a string",
                "[groups]\nquick = true\n" => "must be a tag expression written as a string",
                "[groups]\nquick = \"core &&\"\n" => "a tag name is missing",
                "[groups]\nquick = \"core & slow\"\n" => "is not a tag name",
                "[groups]\nquick = \"\"\n" => "a tag name is missing",
                "groups = \"core\"\n" => "[groups] of",
                "[group]\nquick = \"core\"\n" => "unknown key `group`",
            )
            bad = make_pkg("BadGroups", "test/a_test.jl" => GROUPED, "test/TestItems.toml" => toml)
            err = thrown(() -> read_config(joinpath(bad, "test")))
            @test err isa ConfigError
            @test occursin(what, sprint(showerror, err))
            # A run stops on it whichever group it would select.
            @test thrown(() -> selected(bad; group = "all")) isa ConfigError
        end
        # A message names the group it is about, and the file.
        bad = make_pkg("BadGroupNamed", "test/a_test.jl" => GROUPED, "test/TestItems.toml" => "[groups]\nnightly = \"!\"\n")
        msg = sprint(showerror, thrown(() -> read_config(joinpath(bad, "test"))))
        @test occursin("group `nightly` of [groups] in", msg) && occursin("TestItems.toml", msg)
        # And the table is part of what a run's config holds.
        @test sort!(collect(keys(read_config(joinpath(dir, "test")).groups))) == ["default", "gpu", "quick"]
    end

    @testset "a config file named by the call brings its own groups" begin
        other = joinpath(mktempdir(), "ci.toml")
        write(other, "[groups]\nnightly = \"slow\"\n")
        @test selected(dir; config = other, group = "nightly") == ["core slow"]
        # It replaces test/TestItems.toml, so that file's default does not apply.
        @test selected(dir; config = other) == EVERY_ITEM
        @test thrown(() -> selected(dir; config = other, group = "gpu")) isa ConfigError
    end

    @testset "a run of a group is not a run of the whole suite" begin
        # A failure outside the default group stays failing through the default
        # group's runs: an item a whole-suite run does not find counts as renamed or
        # deleted, so a group's run must not be taken for one.
        failing = make_pkg(
            "GroupFailing",
            "test/a_test.jl" => replace(GROUPED, "@testitem \"gpu one\" tags=[:gpu] begin\n    @test true" =>
                                                  "@testitem \"gpu one\" tags=[:gpu] begin\n    @test false"),
            "test/TestItems.toml" => GROUPS
        )
        with_runstate_dir() do _
            states, _, _ = run_states(failing; group = "gpu", workers = 1, monitor = false, logs = :issues)
            @test states["gpu one"] === FAILED
            states, _, _ = run_states(failing; workers = 1, monitor = false, logs = :issues)
            @test !haskey(states, "gpu one")
            @test failing_items(failing) == ["gpu one"]
            newest = read_run_state(last(runstate_files(failing)))
            @test occursin("group `default`", newest.meta["selection"])
            # A run of the whole suite is one, and takes its verdicts from what it found.
            states, _, _ = run_states(failing; group = "all", workers = 1, monitor = false, logs = :issues)
            @test states["gpu one"] === FAILED
            @test read_run_state(last(runstate_files(failing))).meta["selection"] == ""
        end
    end

    @testset "[order] is strict on the whole suite only, as it is under any selection" begin
        ordered = make_pkg("GroupOrdered", "test/a_test.jl" => GROUPED,
                           "test/TestItems.toml" => GROUPS * "\n[order]\nfirst = [\"no such item\"]\n")
        @test selected(ordered) == ["core one", "core slow", "untagged"]
        @test thrown(() -> selected(ordered; group = "all")) isa ConfigError
        # A pin outside the group's items is no error and no item.
        pinned = make_pkg("GroupPinned", "test/a_test.jl" => GROUPED,
                          "test/TestItems.toml" => GROUPS * "\n[order]\nfirst = [\"gpu one\"]\n")
        @test selected(pinned) == ["core one", "core slow", "untagged"]
        @test selected(pinned; group = "gpu") == ["gpu one"]
    end

    @testset "a tag that no item carries is an error, not a selection of all or of nothing" begin
        for tags in ("!slw", "core && !slw", "slw || core", [:slw], :slw, ["slw"], Set([:core, :slw]))
            err = thrown(() -> selected(dir; group = "all", tags))
            @test err isa ArgumentError
            @test occursin("no test item has the tag `slw`", err.msg)
            @test occursin("did you mean `slow`", err.msg)
            @test occursin("the suite's tags are core, gpu, slow", err.msg)
        end
        # Several at once are named together.
        err = thrown(() -> selected(dir; group = "all", tags = "!slw && !gpuu"))
        @test err isa ArgumentError && occursin("no test item has the tags `slw`, `gpuu`", err.msg)
        # Tags that exist but select nothing together are nothing to run, as before.
        @test_throws NoTestsError selected(dir; group = "all", tags = "gpu && core")
        # A tag carried only by an item a path leaves out is a tag of the suite all the same.
        split = make_pkg("TagsElsewhere",
                         "test/a_test.jl" => "@testitem \"a\" tags=[:only_here] begin\nend\n",
                         "test/b_test.jl" => "@testitem \"b\" begin\nend\n")
        b_file = joinpath(split, "test", "b_test.jl")
        @test_throws NoTestsError selected(b_file; tags = :only_here)
        @test selected(b_file; tags = "!only_here") == ["b"]
        # A suite without tags says so rather than list none.
        bare = make_pkg("Untagged", "test/a_test.jl" => "@testitem \"a\" begin\nend\n")
        err = thrown(() -> selected(bare; tags = "!slow"))
        @test err isa ArgumentError && occursin("no item in the suite has a tag", err.msg)
    end

    @testset "a group naming a tag that no item carries stops a run selecting it, and only that" begin
        bad = make_pkg("GroupTypo", "test/a_test.jl" => GROUPED,
                       "test/TestItems.toml" => "[groups]\nnogpu = \"!gpuu\"\nquick = \"core\"\n")
        err = thrown(() -> selected(bad; group = "nogpu"))
        @test err isa ConfigError
        msg = sprint(showerror, err)
        # The fix is in [groups] whatever selected the group, so the message is about it.
        @test occursin("group `nogpu` of [groups] in $(joinpath("test", "TestItems.toml")), \"!gpuu\": " *
                       "no test item has the tag `gpuu`", msg)
        @test occursin("did you mean `gpu`", msg)
        # The other groups, and a run of no group, read the file as valid.
        @test selected(bad; group = "quick") == ["core one", "core slow"]
        @test selected(bad) == EVERY_ITEM
        # The default group is checked whenever it is the one selected.
        default_typo = make_pkg("DefaultTypo", "test/a_test.jl" => GROUPED,
                                "test/TestItems.toml" => "[groups]\ndefault = \"!gpuu\"\n")
        err = thrown(() -> selected(default_typo))
        @test err isa ConfigError && occursin("group `default` of [groups]", sprint(showerror, err))
        @test length(selected(default_typo; tags = :core)) == 2
    end

    @testset "chores reads the whole suite, and checks every group" begin
        with_runstate_dir() do _
            # Whatever group a run here would select.
            withenv("RUNTESTS_GROUP" => "gpu") do
                ok, out = groups_chores(dir; dry_run = true)
                @test ok === true
                @test occursin("test items: 4 in 1 file, all valid", out)
            end
            bad = make_pkg("ChoresGroupTypo", "test/a_test.jl" => GROUPED,
                           "test/TestItems.toml" => "[groups]\nnogpu = \"!gpuu\"\nquick = \"core\"\nempty = \"core && gpu\"\n")
            ok, out = groups_chores(bad; dry_run = true)
            @test ok === false
            @test occursin("groups: group `nogpu`", out) && occursin("gpuu", out)
            @test !occursin("keyword", out)   # chores checks every group; nothing asked for one
            @test occursin("groups: group `empty` selects no test item", out)
            @test !occursin("group `quick`", out)
            result, out = groups_chores(bad)
            @test result isa Runtests.ChoresError
            @test occursin("2 problems to fix by hand", sprint(showerror, result))
            # Each config file the call names has its groups checked too.
            other = joinpath(mktempdir(), "ci.toml")
            write(other, "[groups]\nlate = \"slw\"\n")
            ok, out = groups_chores(dir; dry_run = true, config = other)
            @test ok === false
            @test occursin("group `late`", out) && occursin("did you mean `slow`", out)
        end
    end

    end   # withenv
end
