using Runtests.Private: canonical_text, text_crc, render_expansion, read_stamp, expansion_of,
                    expansion_state, prepare, scan, setup_modules, Filter, PASSED, SKIPPED

instance(name, values...; computed = []) = Dict{String, Any}("name" => name,
    "values" => [[String(v), c] for (v, c) in values], "computed" => [[k, c] for (k, c) in computed])
looped(line, instances...) = Dict{String, Any}("line" => line, "instances" => collect(instances))

# Where a template named `name` goes, and where its expansion does.
template_in(pkg, name) = joinpath(pkg, "test", "testtemplates", "$(name)_tests_template.jl")
shown_template(name) = joinpath("test", "testtemplates", "$(name)_tests_template.jl")

# A template and its expansion as `chores` writes them, from the answer the expanding
# process would give.
function write_expanded(template, text, items)
    mkpath(dirname(template))
    write(template, text)
    write(expansion_of(template), render_expansion(template, text, items))
    return expansion_of(template)
end

# What `chores` returned, or the exception it threw, with what it printed.
template_chores(args...; kw...) = capture_run(() -> try
    Runtests.chores(args...; kw...)
catch e
    e isa Runtests.ChoresError || rethrow()
    e
end)

# What a run would refuse to start on, as it says it; empty when it would start.
function refusal(pkg)
    try
        prepare((pkg,); announce = false)
        return ""
    catch e
        e isa Runtests.ScanFailure || rethrow()
        return sprint(showerror, e)
    end
end

with_test_dep(pkg) = open(joinpath(pkg, "Project.toml"), "a") do io
    print(io, "\n[extras]\nDates = \"ade2ca70-3891-5945-98fb-dc099432e06a\"\n\n[targets]\ntest = [\"Dates\"]\n")
end

const PLAIN_ITEM = "@testitem \"plain\" begin\n    @test true\nend\n"

@testset "templates" begin
    @testset "a stamp hashes the text as its author wrote it" begin
        text = "@testtemplate \"a \$n\" for n in 1:2\n    @test \$n > 0\nend\n"
        crc = text_crc(text)
        @test text_crc("\ufeff" * text) == crc
        @test text_crc(replace(text, "\n" => "\r\n")) == crc
        @test text_crc(replace(text, "\n" => "\r")) == crc
        @test text_crc(text * "\n\n \t") == crc && text_crc(chomp(text)) == crc
        @test canonical_text("a\r\nb\n\n") == "a\nb"
        # Whitespace anywhere but the end may be inside a string.
        @test text_crc(replace(text, "> 0" => "> 0 ")) != crc
        @test text_crc(replace(text, "1:2" => "1:3")) != crc
    end

    @testset "an instance has each `\$x` replaced by the code of its value, and nothing bound" begin
        template = joinpath(mkpath(joinpath(mktempdir(), "test", "testtemplates")), "a_tests_template.jl")
        text = """
            # Only the declarations reach the expansion.

            @testtemplate "with \$x" tags=[:t, \$tag] timeout=60 for x in (1, 2), tag in (:a,), r in (1:3,)
                using Dates
                y = 7
                @test \$x > 0  # stays on its line
                @test -\$x < 0
                @test "\$(\$x)" == string(\$x)
                @test \$r == 1:3
                @test :(\$x + 1) isa Expr
                @btime f(\$y)
            end
            """
        r = instance("with 1", :x => "1", :tag => ":a", :r => "1:3")
        out = render_expansion(template, text, [looped(3, r)])
        @test startswith(out, "# Expanded from testtemplates/a_tests_template.jl by `Runtests.chores()`.")
        @test occursin("""
            @testitem "with 1" tags=[:t, :a] timeout=60 begin
                using Dates
                y = 7
                @test 1 > 0  # stays on its line
                @test -(1) < 0
                @test "\$(1)" == string(1)
                @test (1:3) == 1:3
                @test :(\$x + 1) isa Expr
                @btime f(\$y)
            end""", out)
        @test !occursin("Only the declarations", out)
        write(template, text)
        write(expansion_of(template), out)
        stamp = read_stamp(expansion_of(template))
        @test stamp.template == text_crc(text) && stamp.actual == stamp.expansion
        @test expansion_state(template) === :current
        items = scan([expansion_of(template)], Filter(), Dict{Symbol, String}())
        @test [it.name for it in items] == ["with 1"]
        @test items[1].tags == [:t, :a]
        # A `$x` where no value reads as one is refused rather than written. One where it
        # reads, and fails only when the item runs, as `$x = 2` would, is the template's.
        @test_throws "a `\$x` or a `\$(...)` has to stand where a value can" render_expansion(template,
            "@testtemplate \"z \$x\" for x in (1,)\n    function \$x()\n    end\nend\n", [looped(1, instance("z 1", :x => "1"))])
    end

    @testset "a keyword's `\$(...)` is replaced by the code of what it computed" begin
        template = joinpath(mkpath(joinpath(mktempdir(), "test", "testtemplates")), "k_tests_template.jl")
        text = """
            @testtemplate "k \$n" skip = (1 + 1 == 3) || \$(n in BAD) timeout = \$(60n) tags = [:k, \$(n > 1 ? :big : :small)] for n in 1:2
                @test \$n > 0
            end
            """
        key = Runtests.Private.Expander.interpolation_key
        computed = [key(:(n in BAD)) => "true", key(:(60n)) => "120", key(:(n > 1 ? :big : :small)) => ":big"]
        out = render_expansion(template, text, [looped(1, instance("k 2", :n => "2"; computed))])
        # What is not in a `$(...)` is the item's, decided as it runs.
        @test occursin("""
            @testitem "k 2" skip = (1 + 1 == 3) || true timeout = 120 tags = [:k, :big] begin
                @test 2 > 0
            end""", out)
        # Every `$` in the keywords is the template's, so one with nothing computed for it is
        # not written as it stands.
        @test_throws "computed nothing for `\$(60n)`" render_expansion(template, text,
            [looped(1, instance("k 2", :n => "2"; computed = computed[[1, 3]]))])
    end

    @testset "a run refuses an expansion that is not the template's as it is now" begin
        pkg = make_pkg("Stamped", "test/other_test.jl" => PLAIN_ITEM)
        t = template_in(pkg, "c")
        o = expansion_of(t)
        source(n) = "@testtemplate \"n=\$n\" for n in 1:$n\n    @test \$n > 0\nend\n"
        expanded(n) = [looped(1, (instance("n=$k", :n => string(k)) for k in 1:n)...)]
        write_expanded(t, source(2), expanded(2))
        @test refusal(pkg) == ""
        # As Git on Windows checks them out.
        foreach(f -> write(f, replace(read(f, String), "\n" => "\r\n")), (t, o))
        @test refusal(pkg) == ""
        write(t, source(3))
        @test occursin("$(joinpath("test", "c_tests.jl")):0: expanded from an older $(shown_template("c")): " *
                       "run `Runtests.chores()` to expand it again", refusal(pkg))
        write_expanded(t, source(3), expanded(3))
        write(o, replace(read(o, String), "> 0" => ">= 0"))
        @test occursin("edited since `Runtests.chores()` expanded it from $(shown_template("c"))", refusal(pkg))
        rm(t)
        @test occursin("which is gone: delete this file, or run `Runtests.chores()`, which does", refusal(pkg))
        rm(o)
        write(t, source(1))
        @test occursin("$(shown_template("c")):0: not expanded yet", refusal(pkg))
        write(o, PLAIN_ITEM)
        @test occursin("in the way of $(shown_template("c"))'s expansion", refusal(pkg))
        # A suite of nothing else says what it lacks, not that it has no test files.
        alone = make_pkg("Unexpanded", "test/testtemplates/d_tests_template.jl" => source(1))
        @test occursin("not expanded yet", refusal(alone))
    end

    @testset "a template is a `*_tests_template.jl` in `test/testtemplates/`, and nothing else is" begin
        pkg = make_pkg("Placed", "test/other_test.jl" => PLAIN_ITEM,
            "test/testtemplates/placed_tests_template.jl" => "@testtemplate \"p \$n\" for n in 1:2\n    @test \$n > 0\nend\n",
            # Beside its expansion, in a directory of its own there, or in a directory of tests.
            "test/beside_tests_template.jl" => "",
            "test/testtemplates/io/deep_tests_template.jl" => "",
            "test/io/nested_tests_template.jl" => "",
            # Neither templates nor test files: what `test/testtemplates/` holds is read as neither.
            "test/testtemplates/helpers.jl" => "",
            "test/testtemplates/written_tests.jl" => PLAIN_ITEM,
            "test/testtemplates/README.md" => "how the templates go\n")
        files, strays, templates = Runtests.Private.walk_test_dir(joinpath(pkg, "test"))
        @test templates == [template_in(pkg, "placed")]
        @test files == [joinpath(pkg, "test", "other_test.jl")]
        said = Dict(relpath(e.file, pkg) => e.msg for e in strays)
        @test sort!(collect(keys(said))) == sort!([joinpath("test", "beside_tests_template.jl"),
            joinpath("test", "testtemplates", "io", "deep_tests_template.jl"), joinpath("test", "io", "nested_tests_template.jl"),
            joinpath("test", "testtemplates", "helpers.jl"), joinpath("test", "testtemplates", "written_tests.jl")])
        @test said[joinpath("test", "beside_tests_template.jl")] == "a test template belongs in `test/testtemplates/` itself, " *
            "from where `Runtests.chores()` expands it into `test/beside_tests.jl`: move it there"
        @test occursin("expands it into `test/deep_tests.jl`", said[joinpath("test", "testtemplates", "io", "deep_tests_template.jl")])
        @test occursin("expands it into `test/nested_tests.jl`", said[joinpath("test", "io", "nested_tests_template.jl")])
        for f in ("helpers.jl", "written_tests.jl")
            @test startswith(said[joinpath("test", "testtemplates", f)], "not a test template. `test/testtemplates/` holds test templates")
        end
        # Each stops the run, and `chores` leaves them to a person.
        msg = refusal(pkg)
        @test all(f -> occursin(f, msg), keys(said))
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            err, out = template_chores(pkg)
            @test err isa Runtests.ChoresError
            @test occursin("templates: 1, 1 expanded:", out) && occursin("move it there", out)
            @test isfile(joinpath(pkg, "test", "placed_tests.jl"))
            @test !isfile(joinpath(pkg, "test", "beside_tests.jl")) && !isfile(joinpath(pkg, "test", "deep_tests.jl"))
        end
    end

    @testset "a test file points a loop at `@testtemplate`" begin
        pkg = make_pkg("Loops", "test/loops_test.jl" => """
            @testitem "x \$T" for T in (Int8,)
                @test true
            end

            for T in (Int8,)
                @testitem "y \$T" begin
                    @test true
                end
            end

            @testtemplate "z \$T" for T in (Int8,)
                @test true
            end
            """)
        msg = refusal(pkg)
        @test occursin("`@testitem` declares one item; to declare one per element, write `@testtemplate`", msg)
        @test occursin("found a `for` loop; to declare an item per element, write a `@testtemplate`", msg)
        @test occursin("a `@testtemplate` belongs in a test template", msg)
    end

    @testset "chores expands a template with the test environment and the setups" begin
        pkg = make_pkg("Expands", "test/other_test.jl" => PLAIN_ITEM,
            "test/testsetups/ExpandsSetup.jl" => "module ExpandsSetup\nexport twice, COUNTS\ntwice(x) = 2x\nconst COUNTS = 1:2\nend\n",
            "test/testtemplates/periods_tests_template.jl" => """
                # The loop sees the packages the item imports, by name: Dates, and the setup.
                @testtemplate "doubling a \$P of \$n" tags=[:gen] for P in filter(T -> T <: Dates.DatePeriod, [Dates.Day, Dates.Hour, Dates.Month]), n in ExpandsSetup.COUNTS
                    using Dates
                    using ExpandsSetup
                    P = \$P
                    @test twice(P(\$n)) == P(2 * \$n)
                end
                """)
        with_test_dep(pkg)
        t = template_in(pkg, "periods")
        o = expansion_of(t)
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            ok, out = template_chores(pkg; dry_run = true)
            @test ok === false && !isfile(o)
            @test occursin("$(joinpath("test", "periods_tests.jl")): to expand from $(shown_template("periods")), not expanded yet", out)
            ok, out = template_chores(pkg)
            @test ok === true
            @test occursin("$(joinpath("test", "periods_tests.jl")): expanded from $(shown_template("periods")), 4 test items", out)
            text = read(o, String)
            # Written as the item's module sees the values: `Day`, not `Dates.Day`.
            @test occursin("@testitem \"doubling a Day of 1\" tags=[:gen] begin\n    using Dates\n    using ExpandsSetup\n    P = Day\n    @test twice(P(1)) == P(2 * 1)\n", text)
            @test occursin("doubling a Month of 2", text) && !occursin("Hour", text)
            # Expanded again, to the same text, which is not written again.
            ok, out = template_chores(pkg)
            @test ok === true && occursin("templates: 1, every expansion current", out) && read(o, String) == text
            states, _, _ = run_states(pkg; workers = 1, monitor = false)
            @test length(states) == 5 && all(==(PASSED), values(states))

            write(t, replace(read(t, String), "[Dates.Day, Dates.Hour, Dates.Month]" => "[Dates.Day, Dates.Hour, Dates.Month, Dates.Year]"))
            @test occursin("expanded from an older", refusal(pkg))
            ok, out = template_chores(pkg; dry_run = true)
            @test ok === false && read(o, String) == text && occursin("which changed since it was expanded", out)
            ok, out = template_chores(pkg)
            @test ok === true && occursin("doubling a Year of 2", read(o, String)) && refusal(pkg) == ""

            edited = replace(read(o, String), "P(2 * 1)" => "P(1 + 1)")
            write(o, edited)
            err, out = template_chores(pkg)
            @test err isa Runtests.ChoresError && read(o, String) == edited
            @test occursin("edited since `Runtests.chores()` expanded it", out)

            rm(o)
            ok, _ = template_chores(pkg)
            @test ok === true && isfile(o)
            rm(t)
            ok, out = template_chores(pkg)
            @test ok === true && !isfile(o) && occursin("deleted, as its template", out)
        end
    end

    @testset "a loop sees each package the body imports by its name, and nothing it exports" begin
        body = quote
            using Dates: Day
            import Random as R
            using .Local
            @test true
        end
        m = Runtests.Private.Expander.loop_module(body, "", 1)
        @test isdefined(m, :Dates) && isdefined(m, :R) && isdefined(m, :Test)
        @test !isdefined(m, :Day) && !isdefined(m, :Random) && !isdefined(m, :Local)
        @test !isdefined(m, Symbol("@test"))
        @test_throws "the loop's `import Missing_Package_X` failed" Runtests.Private.Expander.loop_module(
            quote using Missing_Package_X end, "", 3)
    end

    @testset "a keyword's `\$(...)` is computed as the template expands, among the names the loop sees" begin
        pkg = make_pkg("Computed", "test/other_test.jl" => PLAIN_ITEM,
            "test/testsetups/ComputedSetup.jl" => "module ComputedSetup\nexport KNOWN_BAD\nconst KNOWN_BAD = (2,)\nend\n",
            "test/testtemplates/cases_tests_template.jl" => """
                @testtemplate "case \$n" skip = \$(n in ComputedSetup.KNOWN_BAD) timeout = \$(60n) tags = [:gen, \$(n > 1 ? :big : :small)] for n in 1:3
                    using ComputedSetup
                    @test \$n != 2
                end
                """)
        o = joinpath(pkg, "test", "cases_tests.jl")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            ok, out = template_chores(pkg)
            @test ok === true
            text = read(o, String)
            @test occursin("@testitem \"case 1\" skip = false timeout = 60 tags = [:gen, :small] begin\n", text)
            @test occursin("@testitem \"case 2\" skip = true timeout = 120 tags = [:gen, :big] begin\n", text)
            # Literals, as the scanner takes every keyword but `skip`.
            items = scan([o], Filter(), setup_modules(joinpath(pkg, "test")))
            @test [(it.skip, it.timeout_s, it.tags) for it in items] ==
                [(false, 60, [:gen, :small]), (true, 120, [:gen, :big]), (false, 180, [:gen, :big])]
            states, _, _ = run_states(pkg; workers = 1, monitor = false)
            @test states["case 2"] === SKIPPED && states["case 1"] === PASSED && states["case 3"] === PASSED
        end
    end

    @testset "chores leaves a template it cannot expand to a person and writes nothing for it" begin
        templates = [
            "throws" => "@testtemplate \"x \$T\" for T in error(\"no list today\")\n    @test true\nend\n",
            "closure" => "@testtemplate \"f \$k\" for (k, f) in ((1, x -> x),)\n    @test \$f(1) == 1\nend\n",
            "needs_import" => "@testtemplate \"p \$p\" for p in (Day(1),)\n    @test \$p isa Any\nend\n",
            "exported_name" => "@testtemplate \"x \$p\" for p in (Day(1),)\n    using Dates\n    @test \$p isa Any\nend\n",
            "top_level_code" => "const XS = (1, 2)\n@testtemplate \"t \$x\" for x in XS\n    @test \$x > 0\nend\n",
            "duplicate" => "@testtemplate \"same\" for T in (Int8, Int16)\n    @test true\nend\n",
            "nested" => "for T in (Int8,)\n    @testitem \"n \$T\" begin\n    end\nend\n",
            "testitem" => PLAIN_ITEM,
            "looped_testitem" => "@testitem \"l \$T\" for T in (Int8,)\n    @test true\nend\n",
            "bare_keyword" => "@testtemplate \"k \$T\" skip=(T === Int8) for T in (Int8,)\n    @test true\nend\n",
            "bare_in_body" => "@testtemplate \"b \$n\" for n in 1:2\n    @test string(\$n) == \"\$n\"\nend\n",
            "computed" => "@testtemplate \"c \$T\" for T in (Int8,)\n    @test \$(sizeof(T)) == 1\nend\n",
            "keyword_throws" => "@testtemplate \"kt \$n\" skip = \$(error(\"no skip list today\")) for n in 1:1\n    @test true\nend\n",
            "keyword_not_given_back" => "@testtemplate \"kg \$n\" skip = \$(Ref(n)) for n in 1:1\n    @test true\nend\n",
            "empty" => "@testtemplate \"e \$T\" for T in ()\n    @test true\nend\n",
            "syntax" => "@testtemplate \"s \$T\" for T in (Int8,\n    @test true\nend\n",
        ]
        pkg = make_pkg("Unexpandable", "test/other_test.jl" => PLAIN_ITEM,
            ("test/testtemplates/$(name)_tests_template.jl" => text for (name, text) in templates)...)
        with_test_dep(pkg)
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            err, out = template_chores(pkg)
            @test err isa Runtests.ChoresError
            @test occursin("templates: $(length(templates)), $(length(templates)) to fix by hand:", out)
            for msg in ["no list today",
                        "`\$f` would be written `Main.Template.var",
                        "UndefVarError: `Day` not defined",
                        "a template holds `@testtemplate`s and nothing else: a `@testtemplate`'s loop sees the package and each package the body imports, by name",
                        # What `using Dates` brings into the item's scope is not the loop's.
                        "exported_name_tests_template.jl: line 1: UndefVarError: `Day` not defined",
                        "declares the test item name \"same\" a second time",
                        "a `@testtemplate` belongs at the top level of a template, its loop in its header",
                        "a template holds `@testtemplate`s and nothing else: a `@testitem` belongs in a test file",
                        "a `@testitem` declares one item; to declare one per iteration, write `@testtemplate`",
                        "`skip` names the loop variable `T`, which nothing binds in the item: write `\$T` where its value " *
                            "goes, or `\$(...)` around what is computed from it as the template expands",
                        "`n` in the body names a loop variable, which nothing binds in the item: write `\$n` where its value goes, `\"\$(\$n)\"` in a string",
                        "the body interpolates only a loop variable, as `\$x`, since a `\$(...)` there may be a macro's",
                        "no skip list today",
                        "`\$(Ref(n))` would be written `Base.RefValue{Int64}(1)`, which does not give its value back",
                        "ran no iteration, so it declares no test item",
                        "ParseError"]
                @test occursin(msg, out)
            end
            @test !any(((name, _),) -> isfile(joinpath(pkg, "test", "$(name)_tests.jl")), templates)
        end
    end

    @testset "an expanding process that ends without answering, or hangs, is reported" begin
        pkg = make_pkg("Unanswered", "test/other_test.jl" => PLAIN_ITEM,
            "test/testtemplates/gone_tests_template.jl" => "@testtemplate \"g \$x\" for x in (exit(3); (1,))\nend\n")
        t = template_in(pkg, "gone")
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            err, out = template_chores(pkg)
            @test err isa Runtests.ChoresError
            @test occursin("the process expanding the templates failed, exiting with 3\n", out)
            # An error the process itself dies of is said, as Julia printed it.
            write(t, "@testtemplate \"g \$x\" for x in (throw(InterruptException()); (1,))\nend\n")
            err, out = template_chores(pkg)
            @test occursin("the process expanding the templates failed, exiting with 1:\n│     ERROR: InterruptException", out)
            write(t, "@testtemplate \"g \$x\" for x in (sleep(60); (1,))\nend\n")
            write(joinpath(pkg, "test", "TestItems.toml"), "[run]\ninit_timeout = 2\n")
            elapsed = @elapsed err, out = template_chores(pkg)
            @test err isa Runtests.ChoresError && elapsed < 50
            @test occursin("took longer than 2.0s, the `init_timeout` setting, and was stopped", out)
            # Where it was stopped, as Julia says on SIGTERM: the template's line once
            # the process has got that far, which under load it may not have. Windows
            # has no signals, and the process ends without a word.
            Sys.iswindows() || @test occursin("was stopped:\n│     in expression starting at ", out)
            @test !isfile(expansion_of(t))
        end
    end

    @testset "a load path without the standard libraries, as `Pkg.test` gives, still expands" begin
        pkg = make_pkg("Sandboxed", "test/other_test.jl" => PLAIN_ITEM,
            "test/testtemplates/s_tests_template.jl" => "@testtemplate \"s \$n\" for n in 1:2\n    @test \$n > 0\nend\n")
        load_path = copy(LOAD_PATH)
        withenv("RUNTESTS_RUNSTATE_DIR" => mktempdir()) do
            try
                copy!(LOAD_PATH, ["@"])
                ok, out = template_chores(pkg)
                @test ok === true || (println(out); false)
            finally
                copy!(LOAD_PATH, load_path)
            end
            @test isfile(joinpath(pkg, "test", "s_tests.jl"))
        end
    end

    @testset "`@testtemplate` does not run where it is evaluated" begin
        @test_throws "declares test items in a test template" @eval @testtemplate "x \$T" for T in (1,)
        end
    end
end
