using Runtests.Private: read_config, ConfigError, Profile, DEFAULT_PROFILE, auto_workers

function with_toml(f, contents::AbstractString)
    dir = mktempdir()
    write(joinpath(dir, "TestItems.toml"), contents)
    return f(dir)
end

@testset "config" begin
    @testset "defaults without a TestItems.toml" begin
        cfg = read_config(mktempdir())
        @test cfg.workers >= 1
        @test cfg.timeout_s == 30 * 60
        @test cfg.retries == 0
        @test cfg.memory_threshold == 0.9
        @test !cfg.full_names   # a name too long for its column is shortened
        @test cfg.testset_name == "Runtests"
        @test haskey(cfg.profiles, DEFAULT_PROFILE)
        @test isempty(cfg.order_first) && isempty(cfg.order_last)
    end

    @testset "TestItems.toml is read" begin
        with_toml("""
        [run]
        workers = 3
        timeout = 120
        retries = 2
        logs = "eager"
        full_names = true
        testset_name = "unit"

        [order]
        first = ["a"]
        last = ["z"]

        [profiles.bounds]
        julia_args = ["--check-bounds=yes"]
        threads = "4"
        env = { FOO = "1" }
        init = "using Test"
        test_end = "GC.gc(true)"
        """) do dir
            cfg = read_config(dir)
            @test cfg.workers == 3
            @test cfg.timeout_s == 120
            @test cfg.retries == 2
            @test cfg.logs === :eager
            @test cfg.full_names
            @test cfg.testset_name == "unit"
            @test cfg.order_first == ["a"] && cfg.order_last == ["z"]
            p = cfg.profiles[:bounds]
            @test p.julia_args == ["--check-bounds=yes"]
            @test p.threads == "4"
            @test p.env == ["FOO" => "1"]
            @test p.init.head === :block && !isempty(p.init.args)
            @test p.test_end.head === :block
        end
    end

    @testset "an explicit keyword beats the file" begin
        with_toml("[run]\nworkers = 3\n") do dir
            @test read_config(dir; workers=7).workers == 7
            @test read_config(dir).workers == 3
        end
    end

    @testset "coverage comes from the keyword, then RUNTESTS_COVERAGE, then the file, and says which" begin
        withenv("RUNTESTS_COVERAGE" => nothing) do
            cfg = read_config(mktempdir())
            @test !cfg.coverage && cfg.coverage_source == ""          # the default says nothing
            with_toml("[run]\ncoverage = true\n") do dir
                cfg = read_config(dir)
                @test cfg.coverage && endswith(cfg.coverage_source, "TestItems.toml")
                # `nothing` is no choice: the file's stands.
                @test read_config(dir; coverage = nothing).coverage
                withenv("RUNTESTS_COVERAGE" => "false") do
                    cfg = read_config(dir)
                    @test !cfg.coverage && cfg.coverage_source == "`RUNTESTS_COVERAGE`"
                    @test !read_config(dir; coverage = nothing).coverage
                    cfg = read_config(dir; coverage = true)
                    @test cfg.coverage && cfg.coverage_source == "the `coverage` keyword"
                end
            end
            withenv("RUNTESTS_COVERAGE" => "yes") do
                @test read_config(mktempdir()).coverage
                @test !read_config(mktempdir(); coverage = false).coverage
            end
            withenv("RUNTESTS_COVERAGE" => "maybe") do
                err = try; read_config(mktempdir()); catch e; e; end
                @test err isa ConfigError
                @test occursin("`RUNTESTS_COVERAGE` must be true or false", sprint(showerror, err))
                # The keyword decides, so the variable is not read, and cannot fail.
                @test !read_config(mktempdir(); coverage = false).coverage
            end
            # A process's coverage is set when it starts, so it takes a worker. Asked
            # for in the call, either half of it, it is the call's mistake.
            err = try; read_config(mktempdir(); coverage = true, workers = 0); catch e; e; end
            @test err isa ArgumentError
            @test occursin("`workers = 0` runs the items in this one", sprint(showerror, err))
            with_toml("[run]\ncoverage = true\n") do dir
                @test (try; read_config(dir; workers = 0); catch e; e; end) isa ArgumentError
            end
            with_toml("[run]\ncoverage = true\nworkers = 0\n") do dir
                @test (try; read_config(dir); catch e; e; end) isa ConfigError
            end
        end
    end

    @testset "a testset name is a non-empty string" begin
        @test read_config(mktempdir(); testset_name = "integration").testset_name == "integration"
        for bad in ("", 3)
            err = try; read_config(mktempdir(); testset_name = bad); catch e; e; end
            @test err isa ArgumentError
            @test occursin("`testset_name` must be a non-empty string", sprint(showerror, err))
        end
    end

    @testset "unknown keys are errors, not no-ops" begin
        for (toml, needle) in (
            ("[run]\nworkerz = 2\n", "unknown key `workerz`"),
            ("[orderr]\nfirst = []\n", "unknown key `orderr`"),
            ("[order]\nfirstt = []\n", "unknown key `firstt`"),
            ("[profiles.p]\njulia_argz = []\n", "unknown key `julia_argz`"),
        )
            with_toml(toml) do dir
                err = try; read_config(dir); catch e; e; end
                @test err isa ConfigError
                @test occursin(needle, sprint(showerror, err))
            end
        end
    end

    @testset "init expressions are parsed here, not on a worker" begin
        with_toml("[profiles.p]\ninit = \"using \"\n") do dir
            err = try; read_config(dir); catch e; e; end
            @test err isa ConfigError
            @test occursin("could not parse `init`", sprint(showerror, err))
        end
        with_toml("[profiles.p]\ntest_end = \"1 +\"\n") do dir
            @test_throws ConfigError read_config(dir)
        end
    end

    @testset "values are validated" begin
        for toml in ("[run]\nworkers = -1\n", "[run]\ntimeout = 0\n", "[run]\nretries = -1\n",
                     "[run]\nmemory_threshold = 1.5\n", "[run]\nlogs = \"loud\"\n",
                     "[run]\nworkers = \"most\"\n", "[run]\nmonitor_interval = -5\n",
                     "[run]\nmonitor_interval = nan\n", "[run]\ntimeout = inf\n",
                     "[run]\ntimeout = 1e12\n", "[run]\nretries = 1000\n", "[run]\nretries = 1.5\n",
                     "[run]\ninit_timeout = nan\n", "[run]\nworkers = 2.5\n", "[run]\nworkers = 40000\n",
                     "[run]\nfailfast = 1\n", "[run]\nverbose = \"yes\"\n", "[run]\nseed = -1\n",
                     "[run]\nmemory_threshold = \"high\"\n", "[run]\nthreads = \"x\"\n",
                     "[run]\nthreads = \"0\"\n", "[profiles.p]\nthreads = \"4,1,1\"\n")
            with_toml(toml) do dir
                @test_throws ConfigError read_config(dir)
            end
        end
        # The same from a keyword is the call's mistake, and the message says what is allowed.
        with_toml("") do dir
            for kw in ((; workers = -1), (; timeout = 0), (; retries = -1), (; memory_threshold = 1.5),
                       (; logs = :loud), (; workers = "most"), (; monitor_interval = -5), (; failfast = 1),
                       (; verbose = "yes"), (; seed = -1), (; threads = "x"), (; testset_name = ""), (; coverage = "yes"))
                @test_throws ArgumentError read_config(dir; kw...)
            end
            @test_throws r"`monitor_interval` must be a number of seconds from 0" read_config(dir; monitor_interval = -1)
            @test read_config(dir; monitor_interval = 0).monitor_interval == 0
            @test_throws r"`retries` must be an integer from 0 to 126, got 127" read_config(dir; retries = 127)
            @test read_config(dir; retries = 126).retries == 126
            @test read_config(dir; timeout = 1.5).timeout_s == 2
            @test_throws r"`seed` must be an integer from 0 to" read_config(dir; seed = big(2)^70)
            @test_throws r"`threads` must be what `--threads` takes" read_config(dir; threads = "2, 1")
            # Every form `--threads` takes, and a number for one.
            for t in ("4", "4,1", "4,0", "auto", "auto,1", "4,auto")
                @test read_config(dir; threads = t).threads == t
            end
            @test read_config(dir; threads = 4).threads == "4"
        end
    end

    @testset "a value of the wrong shape is refused, not taken apart" begin
        # A string where a list goes would be read as its characters, and a table's
        # entries as pairs of them; `true` would be the integer 1.
        for (toml, said) in (
                "[profiles.p]\njulia_args = \"-O0\"\n" => r"`julia_args` of \[profiles\.p\] in \S*TestItems.toml must be a list of strings",
                "[profiles.p]\njulia_args = [\"-O0\", 1]\n" => "`julia_args` of [profiles.p]",
                "[profiles.p]\nenv = [\"A=1\"]\n" => r"`env` of \[profiles\.p\] in \S*TestItems.toml must be a table of variables",
                "[profiles.p]\nenv = { A = [1] }\n" => "`env` of [profiles.p]",
                "[profiles.p]\ninit = 1\n" => r"`init` of \[profiles\.p\] in \S*TestItems.toml must be a string",
                "[profiles.p]\ntest_end = [\"x\"]\n" => "`test_end` of [profiles.p]",
                "[order]\nfirst = \"one\"\n" => r"`first` of \[order\] in \S*TestItems.toml must be a list of strings",
                "[order]\nlast = [1]\n" => "`last` of [order]",
                "[run]\ntimeout = true\n" => "`timeout` must be a positive number of seconds",
                "[run]\nworkers = true\n" => "`workers` must be",
                "[run]\nretries = true\n" => "`retries` must be an integer",
                "[run]\nseed = true\n" => "`seed` must be an integer",
                "[run]\nmemory_threshold = true\n" => "`memory_threshold` must be",
                "[run]\nmonitor_interval = false\n" => "`monitor_interval` must be",
            )
            with_toml(toml) do dir
                @test_throws ConfigError read_config(dir)
                e = try read_config(dir) catch err; err end
                @test occursin(said, e.msg)
            end
        end
        # From a keyword too.
        with_toml("") do dir
            @test_throws r"`timeout` must be a positive number" read_config(dir; timeout = true)
            @test_throws r"`retries` must be an integer" read_config(dir; retries = false)
        end
        # What they are for still reads: numbers and flags for variables among them.
        with_toml("[profiles.p]\njulia_args = []\nenv = { A = \"x\", N = 1, F = true }\n[order]\nfirst = []\n") do dir
            cfg = read_config(dir)
            @test isempty(cfg.profiles[:p].julia_args)
            @test cfg.profiles[:p].env == ["A" => "x", "F" => "true", "N" => "1"]
        end
    end

    @testset "malformed TOML is an error with the file named" begin
        with_toml("[run\n") do dir
            err = try; read_config(dir); catch e; e; end
            @test err isa ConfigError
            @test occursin("TestItems.toml", sprint(showerror, err))
        end
    end

    @testset "a config file the call names is read in place of TestItems.toml" begin
        # The suite's own file is broken, so reading it at all would throw.
        with_toml("[run]\nworkers = 3\nnot_a_key = 1\n") do testdir
            other = mktempdir()
            prefs = joinpath(other, "prefs", "Fast.toml")
            mkpath(dirname(prefs)); write(prefs, "[Foo]\nx = 1\n")
            custom = joinpath(other, "custom.toml")
            write(custom, """
            [run]
            workers = 2
            timeout = 90
            [order]
            first = ["a"]
            [profiles.fast]
            julia_args = ["-O0"]
            preferences = "prefs/Fast.toml"
            """)
            cfg = read_config(testdir; config = custom)
            @test (cfg.workers, cfg.timeout_s, cfg.order_first) == (2, 90, ["a"])
            @test cfg.profiles[:fast].julia_args == ["-O0"]
            # A path in it is relative to its own directory, not to `test/`.
            @test cfg.profiles[:fast].preferences == prefs
            @test cfg.config_file == custom
            # A keyword still wins over it.
            @test read_config(testdir; config = custom, workers = 1).workers == 1
            # Relative to the current directory.
            @test cd(() -> read_config(testdir; config = "custom.toml").timeout_s, other) == 90
            # Without the keyword the suite's own file is read, and refused.
            @test_throws ConfigError read_config(testdir)
            # Without it, the suite's own is read, and no file is named.
            @test read_config(mktempdir()).config_file == ""
        end
    end

    @testset "a config file the call names has to exist, and what is wrong with it names it" begin
        dir = mktempdir()
        message(f) = (err = try; f(); nothing; catch e; e; end; err isa ConfigError ? sprint(showerror, err) : "")
        missing_file = joinpath(dir, "missing.toml")
        @test occursin("missing.toml", message(() -> read_config(dir; config = missing_file)))
        @test occursin("does not exist", message(() -> read_config(dir; config = missing_file)))
        # A directory is not a file to read.
        @test occursin("does not exist", message(() -> read_config(dir; config = dir)))
        bad = joinpath(dir, "bad.toml")
        write(bad, "[run]\nworkerz = 2\n")
        @test occursin("bad.toml", message(() -> read_config(dir; config = bad)))
        write(bad, "[run\n")
        @test occursin("bad.toml", message(() -> read_config(dir; config = bad)))
        write(bad, "[profiles.p]\npreferences = \"nowhere.toml\"\n")
        @test occursin(joinpath(dir, "nowhere.toml"), message(() -> read_config(dir; config = bad)))
    end

    @testset "a run reads the config file it is given, and runtestsf passes it on" begin
        dir = make_pkg("CustomConfig", "test/t_test.jl" => """
        @testitem "fast" sandbox=:fast begin
            @test true
        end
        @testitem "fails" begin
            @test false
        end
        """)
        profile = joinpath(mktempdir(), "ci.toml")
        write(profile, "[run]\ntimeout = 77\n[profiles.fast]\nthreads = \"1\"\n")
        no_profile = joinpath(dirname(profile), "bare.toml")
        write(no_profile, "[run]\ntimeout = 78\n")
        message(f) = (err = try; f(); nothing; catch e; e; end; err isa ConfigError ? sprint(showerror, err) : "")
        prep(; kw...) = Runtests.Private.prepare((dir,); announce = false, kw...)
        # The suite has no TestItems.toml: the profile is unknown, and the message
        # names where it was looked for.
        @test occursin("TestItems.toml", message(() -> prep()))
        p, _ = prep(; config = profile)
        @test p.cfg.timeout_s == 77 && p.cfg.profiles[:fast].threads == "1"
        @test occursin("bare.toml", message(() -> prep(; config = no_profile)))
        # `runtestsf` hands it to the run: a missing one stops it.
        with_runstate_dir() do _
            capture_run(() -> run_states(dir; workers = 1, logs = :issues, monitor = false, config = profile))
            err = try
                Runtests.runtestsf(dir; config = joinpath(dirname(profile), "gone.toml"), dry_run = true)
            catch e
                e
            end
            @test err isa ConfigError && occursin("gone.toml", sprint(showerror, err))
        end
    end

    @testset "auto worker count" begin
        @test auto_workers("2", 0) >= 1
        @test auto_workers("2", 1) == 1          # never more workers than there is work
        @test auto_workers("2", 100) <= 8
    end
end

@testset "the default logging style" begin
    # One worker prints as it goes; several would interleave more than a reader can
    # follow, so only the items with something wrong say anything. `:batched` is
    # never chosen for you.
    @test Runtests.Private.default_logs(1, true) === :eager
    @test Runtests.Private.default_logs(0, true) === :eager
    @test Runtests.Private.default_logs(2, true) === :issues
    @test Runtests.Private.default_logs(8, true) === :issues
    # Nothing is watching a non-interactive run as it goes.
    @test Runtests.Private.default_logs(1, false) === :issues
    @test Runtests.Private.default_logs(8, false) === :issues
end
