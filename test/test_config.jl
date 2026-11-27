using Runtests.Private: read_config, ConfigError, Profile, DEFAULT_PROFILE, auto_workers

function with_toml(f, contents::AbstractString)
    dir = mktempdir()
    write(joinpath(dir, "TestItems.toml"), contents)
    return f(dir)
end

function with_clean_runtests_env(f)
    cleared = [k => nothing for k in keys(ENV) if startswith(k, "RUNTESTS_")]
    return withenv(f, cleared...)
end

@testset "config" begin
    @testset "defaults without a TestItems.toml" begin
        with_clean_runtests_env() do
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
    end

    @testset "TestItems.toml is read" begin
        with_clean_runtests_env() do
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
            julia_args = ["--check-bounds=yes", "--threads=4"]
            env = { FOO = "1" }
            precompile = ["Test"]
            """) do dir
                code = mkpath(joinpath(dir, "testconfigs", "bounds"))
                write(joinpath(code, "worker_init.jl"), "using Test\n")
                write(joinpath(code, "test_end.jl"), "GC.gc(true)\n")
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
                @test p.test_end.head === :block && !isempty(p.test_end.args)
                # Parsed with the path of its file, so an error in it names the file and the line.
                @test first(p.init.args) == LineNumberNode(1, Symbol(joinpath(code, "worker_init.jl")))
                @test p.precompile == ["Test"]
                # Without the key, the whole environment.
                @test cfg.profiles[:default].precompile === nothing
            end
        end
    end

    @testset "an explicit keyword beats the file" begin
        with_clean_runtests_env() do
            with_toml("[run]\nworkers = 3\n") do dir
                @test read_config(dir; workers=7).workers == 7
                @test read_config(dir).workers == 3
            end
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

    @testset "every run setting reads RUNTESTS_<KEY>, under a keyword and over the file" begin
        mktempdir() do dir
            write(joinpath(dir, "TestItems.toml"), "[run]\nworkers = 3\nretries = 1\n")
            vars = ("RUNTESTS_WORKERS" => "5", "RUNTESTS_TIMEOUT" => "90", "RUNTESTS_FAILFAST" => "yes",
                    "RUNTESTS_SEED" => "0x10", "RUNTESTS_LOGS" => "batched", "RUNTESTS_THREADS" => "3,1")
            withenv(vars...) do
                cfg = read_config(dir)
                @test (cfg.workers, cfg.timeout_s, cfg.failfast, cfg.seed, cfg.logs, cfg.threads) == (5, 90, true, 0x10, :batched, "3,1")
                @test cfg.retries == 1                            # the file's, with no variable
                @test read_config(dir; workers = 2).workers == 2  # a keyword wins
                @test issetequal(cfg.env_settings, collect(vars))
                @test !any(v -> first(v) == "RUNTESTS_WORKERS", read_config(dir; workers = 2).env_settings)
            end
            # A bad value names its variable, which nothing else in the project shows.
            withenv("RUNTESTS_WORKERS" => "many") do
                err = try read_config(dir) catch e e end
                @test err isa ConfigError && occursin("`workers` must be", err.msg) && occursin("RUNTESTS_WORKERS", err.msg)
            end
            withenv("RUNTESTS_VERBOSE" => "maybe") do
                @test_throws ConfigError read_config(dir)
            end
        end
    end

    @testset "a seed given is the seed, 0 among them, and none given is a random one" begin
        mktempdir() do dir
            @test read_config(dir; seed = 0).seed == 0
            @test read_config(dir; seed = 0x1234).seed == 0x1234
            @test read_config(dir).seed != read_config(dir).seed
            write(joinpath(dir, "TestItems.toml"), "[run]\nseed = 0\n")
            @test read_config(dir).seed == 0
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

    @testset "the code of a profile is parsed here, not on a worker" begin
        with_toml("[profiles.p]\n") do dir
            code = mkpath(joinpath(dir, "testconfigs", "p"))
            write(joinpath(code, "worker_init.jl"), "using ")
            err = try; read_config(dir); catch e; e; end
            @test err isa ConfigError
            @test occursin(r"could not parse \S*worker_init.jl", sprint(showerror, err))
            write(joinpath(code, "worker_init.jl"), "")
            write(joinpath(code, "test_end.jl"), "1 +")
            @test_throws ConfigError read_config(dir)
        end
    end

    @testset "the code of a profile is in files, not in TestItems.toml" begin
        with_toml("[profiles.p]\ninit = \"using Test\"\n") do dir
            msg = sprint(showerror, try; read_config(dir); catch e; e; end)
            @test occursin("the code of a profile is in a file of its own", msg)
            @test occursin(joinpath("testconfigs", "p", "worker_init.jl"), msg)
        end
        with_toml("[profiles.default]\ntest_end = \"nothing\"\n") do dir
            @test occursin(joinpath("testconfigs", "test_end.jl"),
                           sprint(showerror, try; read_config(dir); catch e; e; end))
        end
        # The default profile's code needs no table.
        with_toml("") do dir
            mkpath(joinpath(dir, "testconfigs"))
            write(joinpath(dir, "testconfigs", "worker_init.jl"), "const FROM_FILE = 1\n")
            @test !isempty(read_config(dir).profiles[DEFAULT_PROFILE].init.args)
        end
    end

    @testset "the threads of a profile are a flag of julia_args, taken out of them" begin
        for (args, threads, rest) in (("[\"-t\", \"4\"]", "4", String[]), ("[\"-t4\", \"-O1\"]", "4", ["-O1"]),
                                      ("[\"--threads\", \"2,1\"]", "2,1", String[]),
                                      ("[\"--threads=auto\", \"--check-bounds=yes\"]", "auto", ["--check-bounds=yes"]))
            with_toml("[profiles.p]\njulia_args = $args\n") do dir
                p = read_config(dir).profiles[:p]
                @test p.threads == threads && p.julia_args == rest
            end
        end
        for (toml, said) in (
                "[profiles.p]\nthreads = \"4\"\n" =>
                    "the threads of a profile are a flag of `julia_args`, as in `julia_args = [\"--threads=4\"]`",
                "[profiles.p]\njulia_args = [\"-t\"]\n" => "`-t` in `julia_args` of [profiles.p]",
                "[profiles.p]\njulia_args = [\"-t2\", \"--threads=3\"]\n" => "is given twice",
                "[profiles.p]\njulia_args = [\"-t0\"]\n" => "must be what `--threads` takes",
            )
            with_toml(toml) do dir
                err = try; read_config(dir); catch e; e; end
                @test err isa ConfigError && occursin(said, sprint(showerror, err))
            end
        end
        # Without `--threads`, the workers get the run's.
        with_toml("[profiles.p]\njulia_args = [\"-O1\"]\n") do dir
            @test read_config(dir).profiles[:p].threads == ""
        end
    end

    @testset "the name of a profile is a directory name on every system" begin
        for (toml, said) in (
                "[profiles.\"a/b\"]\n" => "it holds '/'",
                "[profiles.\"x:y\"]\n" => "it holds ':'",
                "[profiles.CON]\n" => "Windows takes it for a device",
                "[profiles.\"end.\"]\n" => "Windows drops a space or a dot at its end",
                "[profiles.Default]\n" => "differs from `default` only in case",
                "[profiles.\"Worker_Init.jl\"]\n" => "it is the name of a file there",
                "[profiles.Bounds]\n[profiles.bounds]\n" => "`Bounds` and `bounds`, which differ only in case",
            )
            with_toml(toml) do dir
                err = try; read_config(dir); catch e; e; end
                @test err isa ConfigError
                @test occursin(said, sprint(showerror, err))
            end
        end
    end

    @testset "test/testconfigs holds the code of the profiles and nothing else" begin
        with_toml("[profiles.bounds]\n") do dir
            code = joinpath(dir, "testconfigs")
            mkpath(joinpath(code, "bounds"))
            write(joinpath(code, "worker_init.jl"), "")
            write(joinpath(code, "bounds", "test_end.jl"), "")
            write(joinpath(code, ".DS_Store"), "")              # hidden: passed over
            @test read_config(dir).profiles[:bounds].test_end == Expr(:block)
            for (extra, said) in (
                    joinpath("notes.md") => "`notes.md`",
                    joinpath("bounds", "helpers.jl") => "`bounds/helpers.jl`",
                    joinpath("default", "worker_init.jl") => "`default/`",
                    joinpath("fast", "worker_init.jl") => "`fast/`",
                )
                path = joinpath(code, extra)
                mkpath(dirname(path)); write(path, "")
                msg = sprint(showerror, try; read_config(dir); catch e; e; end)
                @test occursin(said, msg)
                @test occursin("The other profiles are `bounds`", msg)
                rm(dirname(path) == code ? path : (dirname(path) == joinpath(code, "bounds") ? path : dirname(path));
                   recursive = true)
            end
            @test read_config(dir).profiles[:bounds].test_end == Expr(:block)
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
                     "[run]\nthreads = \"0\"\n", "[profiles.p]\njulia_args = [\"--threads=4,1,1\"]\n")
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

    @testset "[throttle] gives a throttle the number of its items that may run at once" begin
        T = Runtests.Private.Throttle
        with_toml("[throttle]\ngpu = 2\ndb = 1\n") do dir
            @test read_config(dir).throttle == Dict(:gpu => T(2, false), :db => T(1, false))
        end
        @test isempty(read_config(mktempdir()).throttle)
        # Table form (inline and subtable) configures `limit` and optional `warmup`.
        with_toml("[throttle]\npc = { limit = 2, warmup = true }\ngpu = { limit = 3 }\none = { limit = 1, warmup = true }\n[throttle.db]\nlimit = 4\nwarmup = false\n") do dir
            @test read_config(dir).throttle == Dict(
                :pc => T(2, true),
                :gpu => T(3, false),
                :one => T(1, true),
                :db => T(4, false),
            )
        end
        # A key is the name Julia reads from `:name`: the micro sign is Greek mu, an
        # accent written apart is composed with its letter.
        with_toml("[throttle]\n\"\u00b5\" = 2\n\"e\u0301x\" = 3\n") do dir
            @test read_config(dir).throttle == Dict(Symbol("\u03bc") => T(2, false), Symbol("\u00e9x") => T(3, false))
        end
        with_toml("[throttle]\n\"\u00b5\" = 2\n\"\u03bc\" = 3\n") do dir
            err = try; read_config(dir); nothing; catch e; e; end
            @test err isa ConfigError && occursin("as it reads another key of [throttle]", sprint(showerror, err))
        end
        for (toml, said) in (("[throttle]\ngpu = 0\n", "an integer from 1"), ("[throttle]\ngpu = 1.5\n", "an integer from 1"),
                             ("[throttle]\ngpu = \"2\"\n", "an integer from 1"),
                             ("[throttle]\n\"two words\" = 2\n", "a Julia identifier"), ("throttle = 2\n", "must be a table"),
                             ("[throttle]\npc = { warmup = true }\n", "must set `limit`"),
                             ("[throttle]\npc = { limit = 0, warmup = true }\n", "an integer from 1"),
                             ("[throttle]\npc = { limit = 2, warmup = \"yes\" }\n", "must be true or false"),
                             ("[throttle]\npc = { limit = 2, bogus = 1 }\n", "unknown key"))
            with_toml(toml) do dir
                err = try; read_config(dir); nothing; catch e; e; end
                @test err isa ConfigError && occursin(said, sprint(showerror, err))
            end
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
                "[profiles.p]\ninit = 1\n" => r"`init` of \[profiles\.p\] in \S*TestItems.toml: the code of a profile is in a file",
                "[profiles.p]\ntest_end = [\"x\"]\n" => "`test_end` of [profiles.p]",
                "[profiles.p]\nprecompile = false\n" => r"`precompile` of \[profiles\.p\] in \S*TestItems.toml must be a list of strings",
                "[profiles.p]\nprecompile = [\"A\", 1]\n" => "`precompile` of [profiles.p]",
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
        with_toml("[profiles.p]\njulia_args = []\nenv = { A = \"x\", N = 1, F = true }\nprecompile = []\n[order]\nfirst = []\n") do dir
            cfg = read_config(dir)
            @test isempty(cfg.profiles[:p].julia_args)
            # No package, which is not the whole environment.
            @test cfg.profiles[:p].precompile == String[]
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
        @testitem "fast" profile=:fast begin
            @test true
        end
        @testitem "fails" begin
            @test false
        end
        """)
        profile = joinpath(mktempdir(), "ci.toml")
        write(profile, "[run]\ntimeout = 77\n[profiles.fast]\njulia_args = [\"--threads=1\"]\n")
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
        # A worker with a thread per CPU fills the machine on its own.
        @test auto_workers("auto", 100) == 1 && auto_workers("auto,1", 100) == 1

        # Recorded peak worker RSS scales down heavy suites and lets light suites use
        # more workers than the unmeasured 4G guess on memory-constrained machines.
        mem_16g = Int64(16) * 1_000_000_000
        @test auto_workers("1", 100; peak_worker_mb = 4000.0, coverage = 1.0, memory_threshold = 0.9, total_memory = mem_16g) <= 2
        if Runtests.Private.effective_cpu_threads() >= 8
            @test auto_workers("1", 100; peak_worker_mb = 350.0, coverage = 1.0, memory_threshold = 0.9, total_memory = mem_16g) >= 8
        end
        # Incomplete coverage regularizes low RSS readings back toward the 4G prior
        # (so a tiny partial run cannot oversubscribe a full run), while never shrinking
        # high readings (> 4G) downward.
        @test auto_workers("1", 100; peak_worker_mb = 350.0, coverage = 0.05, memory_threshold = 0.9, total_memory = mem_16g) <= 4
        @test auto_workers("1", 100; peak_worker_mb = 5000.0, coverage = 0.05, memory_threshold = 0.9, total_memory = mem_16g) <= 2
        # Low coverage keeps the unmeasured cap of 8 even on large-memory machines.
        mem_128g = Int64(128) * 1_000_000_000
        @test auto_workers("1", 100; peak_worker_mb = 350.0, coverage = 0.5, memory_threshold = 0.9, total_memory = mem_128g) <= 8
        # Non-finite or non-positive readings fall back to the unmeasured default.
        @test auto_workers("2", 100; peak_worker_mb = NaN, total_memory = mem_16g) ==
              auto_workers("2", 100; total_memory = mem_16g)
        @test auto_workers("2", 100; peak_worker_mb = -50.0, total_memory = mem_16g) ==
              auto_workers("2", 100; total_memory = mem_16g)
    end

    @testset "LocalTestItems.toml overlays [run] and [throttle]" begin
        with_clean_runtests_env() do
            # LocalTestItems.toml overrides [run] and merges [throttle] over TestItems.toml.
            with_toml("""
            [run]
            workers = 2
            timeout = 300
            retries = 1
            failfast = false

            [throttle]
            db = 1
            gpu = 1

            [groups]
            fast = "fast"
            """) do dir
                write(joinpath(dir, "LocalTestItems.toml"), """
                [run]
                workers = 6
                failfast = true
                verbose = true

                [throttle]
                gpu = { limit = 4, warmup = true }
                """)
                cfg = read_config(dir)
                @test cfg.workers == 6
                @test cfg.timeout_s == 300        # kept from TestItems.toml
                @test cfg.retries == 1            # kept from TestItems.toml
                @test cfg.failfast && cfg.verbose
                @test haskey(cfg.groups, "fast")  # kept from TestItems.toml
                @test cfg.throttle[:db] == Runtests.Private.Throttle(1, false)
                @test cfg.throttle[:gpu] == Runtests.Private.Throttle(4, true)
                @test endswith(cfg.local_config_file, "LocalTestItems.toml")
                @test ("workers" => "6") in cfg.local_settings
                @test ("failfast" => "true") in cfg.local_settings
                @test ("verbose" => "true") in cfg.local_settings
                @test ("throttle.gpu" => "{limit=4, warmup=true}") in cfg.local_settings
                @test !any(((k, _),) -> k == "timeout", cfg.local_settings)

                # Precedence: keyword > RUNTESTS_<KEY> > LocalTestItems.toml > TestItems.toml.
                withenv("RUNTESTS_WORKERS" => "3") do
                    c_env = read_config(dir)
                    @test c_env.workers == 3
                    @test !any(((k, _),) -> k == "workers", c_env.local_settings)
                    @test ("failfast" => "true") in c_env.local_settings
                    c_kw = read_config(dir; workers = 5, failfast = false)
                    @test c_kw.workers == 5 && !c_kw.failfast
                    @test !any(((k, _),) -> k in ("workers", "failfast"), c_kw.local_settings)
                end

                # Explicit `config = ...` replaces TestItems.toml and ignores LocalTestItems.toml.
                other = joinpath(mktempdir(), "ci.toml")
                write(other, "[run]\nworkers = 2\n")
                c_other = read_config(dir; config = other)
                @test c_other.workers == 2 && !c_other.failfast && isempty(c_other.local_config_file)
            end

            # Works without a committed TestItems.toml, and attributes coverage to LocalTestItems.toml.
            solo = mktempdir()
            write(joinpath(solo, "LocalTestItems.toml"), "[run]\nworkers = 4\ncoverage = true\n")
            cfg = read_config(solo)
            @test cfg.workers == 4 && cfg.coverage
            @test endswith(cfg.coverage_source, "LocalTestItems.toml")
            @test endswith(cfg.local_config_file, "LocalTestItems.toml")

            # Suite-only sections and bad keys/values in LocalTestItems.toml fail loudly naming it.
            for (bad, needle) in (
                "[profiles.fast]\njulia_args = [\"--threads=1\"]\n" => "allow only [run] and [throttle]",
                "[groups]\nfast = \"fast\"\n" => "allow only [run] and [throttle]",
                "[order]\nfirst = [\"a\"]\n" => "allow only [run] and [throttle]",
                "[monorepo]\npackages = [\".\"]\n" => "allow only [run] and [throttle]",
                "[bogus]\nx = 1\n" => "unknown key `bogus`",
                "[run]\nskip_environment = [\"test/qa\"]\n" => "LocalTestItems.toml",
                "[run]\nworkers = -1\n" => "LocalTestItems.toml",
                "[throttle]\ndb = 0\n" => "LocalTestItems.toml",
            )
                d = mktempdir()
                write(joinpath(d, "LocalTestItems.toml"), bad)
                err = try; read_config(d); nothing; catch e; e; end
                @test err isa ConfigError
                msg = sprint(showerror, err)
                @test occursin("LocalTestItems.toml", msg) && occursin(needle, msg)
            end

            # Dry-run plan block and `chores` announce effective LocalTestItems.toml overrides.
            pkg = make_pkg(
                "LocalPkg",
                "test/a_test.jl" => "@testitem \"ok\" begin\n    @test true\nend\n",
                "test/TestItems.toml" => "[run]\nworkers = 2\n",
                "test/LocalTestItems.toml" => "[run]\nworkers = 4\nfailfast = true\n",
            )
            _, out = capture_run(() -> Runtests.runtests(pkg; dry_run = true))
            @test occursin("set by", out) && occursin("LocalTestItems.toml", out)
            @test occursin("workers=4", out) && occursin("failfast=true", out)
            # A keyword overriding all local keys leaves no `set by ... LocalTestItems.toml` line.
            _, out_kw = capture_run(() -> Runtests.runtests(pkg; dry_run = true, workers = 1, failfast = false))
            @test !occursin("LocalTestItems.toml", out_kw)
            # `chores` validates LocalTestItems.toml (with and without TestItems.toml).
            _, chores_out = capture_run(() -> Runtests.chores(pkg; dry_run = true))
            @test occursin("LocalTestItems.toml", chores_out) && occursin("valid", chores_out)
            rm(joinpath(pkg, "test", "TestItems.toml"))
            _, chores_solo = capture_run(() -> Runtests.chores(pkg; dry_run = true))
            @test occursin("LocalTestItems.toml", chores_solo) && occursin("valid", chores_solo)

            # Monorepo: root LocalTestItems.toml supplies run-wide keys; member supplies package keys and [throttle].
            if VERSION >= v"1.12"
                ws = realpath(mktempdir())
                a = joinpath(ws, "lib", "A")
                uuid = next_uuid()
                mkpath(joinpath(a, "src")); mkpath(joinpath(a, "test")); mkpath(joinpath(ws, "test"))
                write(joinpath(ws, "Project.toml"), "[workspace]\nprojects = [\"lib/A\", \"lib/A/test\"]\n")
                write(joinpath(a, "Project.toml"), "name = \"A\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n")
                write(joinpath(a, "src", "A.jl"), "module A\nend\n")
                write(joinpath(a, "test", "Project.toml"), """
                    [deps]
                    A = "$uuid"
                    Runtests = "632efd68-cd41-4e05-bd25-b86dc2150078"
                    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

                    [sources]
                    A = {path = ".."}
                    Runtests = {path = $(repr(pkgdir(Runtests)))}
                    """)
                write(joinpath(a, "test", "a_test.jl"), "@testitem \"one\" throttle=:db begin\n    @test true\nend\n")
                write(joinpath(ws, "test", "TestItems.toml"), "[run]\nworkers = 2\n")
                write(joinpath(ws, "test", "LocalTestItems.toml"), "[run]\nworkers = 4\nfailfast = true\n")
                write(joinpath(a, "test", "LocalTestItems.toml"), "[run]\ntimeout = 123\nworkers = 9\n[throttle]\ndb = 2\n")
                r = Runtests.Private.prepare_mono((ws,); announce = false)
                @test r.plan.cfg.workers == 4 && r.plan.cfg.failfast
                @test r.plan.packages.cfg[1].timeout_s == 123
                @test r.plan.packages.cfg[1].throttle[:db] == Runtests.Private.Throttle(2, false)
                # Non-root member's run-wide `workers = 9` was dropped and not reported as active.
                @test !any(((k, _),) -> k == "workers", r.plan.packages.cfg[1].local_settings)
                @test ("timeout" => "123") in r.plan.packages.cfg[1].local_settings
                @test ("throttle.db" => "2") in r.plan.packages.cfg[1].local_settings
                _, mono_out = capture_run(() -> Runtests.runtests_mono(ws; dry_run = true))
                mono_slashed = replace(mono_out, '\\' => '/')
                @test occursin("test/LocalTestItems.toml", mono_slashed) && occursin("workers=4", mono_slashed)
                @test occursin("lib/A/test/LocalTestItems.toml", mono_slashed) && occursin("timeout=123", mono_slashed)
            end
        end
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
