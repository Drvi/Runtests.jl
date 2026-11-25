# Everything a run prints goes through one writer. These tests run a real suite in
# a subprocess, with the monitor printing as fast as it can and several workers
# relaying output at once, and check that no two writers ever landed on the same
# line.

using Runtests: RuntestsWorkers

@testset "run output" begin
    work = mktempdir()
    out = joinpath(work, "run.log")
    script = joinpath(work, "run.jl")
    write(script, """
    push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
    using Runtests
    Runtests.runtests($(repr(fixture("Basic.jl"))); workers=3, logs=:eager,
                  monitor=true, monitor_interval=0)
    """)
    ok = success(pipeline(ignorestatus(addenv(plain_julia(script),
                                              "RUNTESTS_RUNSTATE_DIR" => joinpath(work, "runs")));
                          stdout=out, stderr=out))
    log = read(out, String)
    ok || @info "the output fixture failed; its output was:\n$log"
    @test ok
    lines = split(log, '\n')

    @testset "the opening block says what the machine has, and puts items and seed on their own lines" begin
        head = only(filter(l -> startswith(l, "┌ [TEST] v"), lines))
        @test !occursin("test items in", head)
        @test !occursin("seed ", head)
        @test any(l -> startswith(l, "│ items: 6 test items in 2 files"), lines)
        @test any(l -> occursin(r"^│ seed: 0x[0-9a-f]{16}", l), lines)
        machine = only(filter(l -> occursin("machine: ", l), lines))
        @test occursin("│ machine: $(Sys.CPU_THREADS) CPU threads", machine)
        @test occursin(r" · \d+\.\dG memory, \d+\.\dG available$", machine)
    end

    @testset "every item announces its start and its end" begin
        starts = filter(l -> occursin("· RUN", l), lines)
        dones  = filter(l -> occursin("· DONE", l), lines)
        @test length(starts) == 6
        @test length(dones) == 6
        # Blue while it runs, then the colour of how it went — every item in this
        # fixture passes.
        run_num_by_name = Dict{String, Int}()
        run_nums = Int[]
        for l in starts
            m = match(
                Regex("^$(Runtests.Private.MARK_RUNNING) w\\d+ · " *
                      "\\d\\d:\\d\\d:\\d\\d · RUN  · (\\d+)/6 · \"(.+?)\"\\s+· at \\S+:\\d+\$"), l)
            @test m !== nothing
            if m !== nothing
                k = parse(Int, m.captures[1])
                push!(run_nums, k)
                run_num_by_name[String(m.captures[2])] = k
            end
        end
        # First-attempt RUN lines are numbered strictly in start order (1..N).
        @test run_nums == collect(1:6)
        for l in dones
            m = match(
                Regex("^$(Runtests.Private.MARK_PASSED) w\\d+ · " *
                      "\\d\\d:\\d\\d:\\d\\d · DONE · (\\d+)/6 · \"(.+?)\"\\s+· PASS · "), l)
            @test m !== nothing
            if m !== nothing
                @test parse(Int, m.captures[1]) == run_num_by_name[String(m.captures[2])]
            end
            # The worker with what it started, or its own `maxrss` before a sample saw it.
            @test occursin(r" · (tree max|maxrss) \d", l)
        end
    end

    @testset "every line a worker or the run writes lines up" begin
        # One shape for the lot: glyph, who, when, what. The glyphs are all two
        # columns wide, so `w1 |` lands in the same place whichever kind of line
        # it is — which is the only reason a log of them is readable.
        heads = filter(l -> occursin(r" w\d+ · \d\d:\d\d:\d\d · ", l), lines)
        @test !isempty(heads)
        @test all(l -> !isspace(first(l)), heads)   # from the first column
        marks = unique(first(split(strip(l))) for l in heads)
        known = Set([Runtests.Private.MARK_INFO, (Runtests.Private.MARK_RUNNING, Runtests.Private.MARK_PASSED, Runtests.Private.MARK_FAILED, Runtests.Private.MARK_SET_ASIDE, Runtests.Private.MARK_ITEM, Runtests.Private.MARK_WORKER)...])
        # The fixture's setup has lines of its own when its cache has to be compiled.
        union!(known, (Runtests.Private.PRECOMPILE_MARK_RUNNING, Runtests.Private.PRECOMPILE_MARK_PASSED,
                       Runtests.Private.PRECOMPILE_MARK_FAILED, Runtests.Private.PRECOMPILE_MARK_UNPRECOMPILABLE,
                       Runtests.Private.PRECOMPILE_MARK_WORKER, Runtests.Private.PRECOMPILE_MARK_INFO))
        @test issubset(marks, known)
        # This fixture starts workers, runs items that pass, and reports.
        @test Runtests.Private.MARK_WORKER in marks
        @test Runtests.Private.MARK_RUNNING in marks
        @test Runtests.Private.MARK_PASSED in marks
        # ...and the column `w<n>` starts in is the same on all of them.
        cols = unique(length(SubString(l, 1, prevind(l, first(findfirst(r" w\d+ · ", l))))) for l in heads)
        @test length(cols) == 1
    end

    @testset "the run reports on itself when there is no terminal" begin
        status = filter(l -> occursin("· INFO ", l), lines)
        @test !isempty(status)
        # Marked as the precompile lines are while there is something to compile.
        info_marks = (Runtests.Private.MARK_INFO, Runtests.Private.PRECOMPILE_MARK_INFO)
        @test all(l -> any(m -> startswith(l, m * " w0" * Runtests.Private.FIELD), info_marks), status)
        @test any(l -> occursin("mem ", l), status)
        # The load average as well as memory, where there is one: Windows reports none.
        Sys.iswindows() || @test any(l -> occursin(r" · cpu +\d+\.\d/\d+ · ", l), status)
        @test any(l -> occursin("workers", l), status)
        @test any(l -> occursin("tree mem", l), status)
        @test any(l -> occursin("(max ", l), status)
    end

    @testset "a run with no workers concludes without claiming one" begin
        _, solo = capture_run() do
            run_states(fixture("Basic.jl"); workers=0, logs=:issues, monitor=false)
        end
        @test occursin("in this process", solo)
        @test !occursin("on 1 worker", solo)
    end

    @testset "a path is shortened on the way out, not on the way in" begin
        root = "/some/where/MyPkg"
        text = "Error During Test at $root/test/a_test.jl:7\n  @ $root/test/b_test.jl:2\n"
        short = Runtests.Private.strip_root(text, root)
        @test occursin("at test/a_test.jl:7", short)
        @test occursin("@ test/b_test.jl:2", short)
        @test !occursin(root, short)
        # The stacktrace printer writes the home directory as `~`, so the same
        # path arrives spelled two ways and both come off. Not on Windows, where
        # the home directory is never contracted, but where a path can arrive
        # with either separator instead.
        home = homedir()
        under = joinpath(home, "proj", "MyPkg")
        if Sys.iswindows()
            @test Runtests.Private.strip_root("a $(under)\\test\\x.jl:1 and $(under)/test/y.jl:2", under) ==
                "a test\\x.jl:1 and test/y.jl:2"
        else
            both = "a $(under)/test/x.jl:1 and ~/proj/MyPkg/test/y.jl:2"
            @test Runtests.Private.strip_root(both, under) == "a test/x.jl:1 and test/y.jl:2"
        end
        # Nothing to strip, nothing changed.
        @test Runtests.Private.strip_root(text, "") == text
        @test Runtests.Private.strip_root("no paths here", root) == "no paths here"
    end

    @testset "a worker's last line says what it did, not what the slot did" begin
        # One worker, three items: the count belongs to the process that ran them.
        _, out = capture_run() do
            run_states(fixture("Basic.jl"); workers=1, logs=:issues, monitor=false)
        end
        exits = filter(l -> occursin("· EXIT", l), worker_lines(out))
        @test length(exits) == 1
        @test occursin("6 items", only(exits))
        # A graceful shutdown is not a kill: that word is reserved for a worker
        # the run put down, and the two must stay distinguishable. It is also not
        # "DONE", which is an item finishing, nor "LOST", which is a worker that
        # died on its own — four words, none of them a glance away from another.
        @test !occursin("KILL", out)
        @test !occursin("LOST", out)
        @test count(l -> occursin("· UP ", l), worker_lines(out)) == 1
    end

    @testset "the name column is chosen from the names the run will print" begin
        nw(names; columns=0) = Runtests.Private.name_width(names; columns)
        qw = Runtests.Private.quoted_width
        widest(names) = maximum(qw, names)

        short = ["item $i" for i in 1:100]
        # They all fit, so they all line up and nothing overflows.
        @test nw(short) == widest(short)
        @test count(n -> qw(n) > nw(short), short) == 0

        # Two long names among a hundred short ones do not buy forty columns of
        # blanks on every line.
        outliers = vcat(short, ["a much longer outlier name $i" for i in 1:2])
        @test nw(outliers) < widest(outliers)
        @test count(n -> qw(n) > nw(outliers), outliers) <= 3

        # A tail that is only a little longer than the rest is covered instead.
        tight = ["name of length about $i" for i in 1:50]
        @test nw(tight) == widest(tight)

        # Whatever the distribution, the overflow stays a tail.
        for names in (short, outliers, tight, vcat(short, ["x"^150]),
                      vcat(short[1:90], ["slightly longer name $i" for i in 1:10]))
            over = count(n -> qw(n) > nw(names), names)
            @test over <= max(Runtests.Private.NAME_OUTLIER_ALLOWANCE,
                              length(names) ÷ Runtests.Private.NAME_OUTLIER_SHARE)
        end

        # A terminal narrows the column; a narrow one does not squeeze it away.
        long = ["a considerably longer test item name $i" for i in 1:100]
        @test nw(long; columns=200) > nw(long; columns=120) > nw(long; columns=80)
        @test nw(long; columns=40) >= Runtests.Private.MIN_NAME_WIDTH
        @test nw(long) <= Runtests.Private.MAX_NAME_WIDTH
        @test nw(String[]) >= Runtests.Private.MIN_NAME_WIDTH
        @test nw(["just the one"]) == qw("just the one")

        # The width it counts on is the width the line actually takes.
        for n in ["plain", "with \"quotes\"", "back\\slash", "emoji 🎉", "unicode é", "tab\there",
                  "newline\nhere", "dollar \$x", "", "\e[1mnot an escape sequence"]
            @test qw(n) == textwidth(repr(n))
        end
    end

    @testset "a name too long for the column is written as a prefix of its own" begin
        # As the plan writes it: `r"^…"`, which passed to `name=` picks out that item.
        names = ["one", "two", "three", "an item whose name runs on and on, far past the others",
                 "another item whose name runs on and on, far past the others"]
        dir = make_pkg("ShortNames", "test/s_test.jl" => join(
            (string("@testitem ", repr(n), " begin\n    @test true\nend\n") for n in names), "\n"))
        dones(; kw...) = filter(l -> occursin("DONE", l), split(last(capture_run(() ->
            run_states(dir; workers=0, logs=:issues, monitor=false, kw...))), '\n'))
        short = dones()
        @test length(short) == 5
        @test count(l -> occursin("r\"^an", l), short) == 2
        # The quotes line up, and so does everything after the names.
        column(l, text) = length(l[1:prevind(l, findfirst(text, l).start)])
        @test length(unique(column.(short, "\""))) == 1
        @test length(unique(column.(short, "PASS"))) == 1
        # Asked for, every name is written whole.
        whole = dones(full_names = true)
        @test all(n -> any(l -> occursin(repr(n), l), whole), names)
        @test !any(l -> occursin("r\"^", l), whole)
    end

    @testset "a log path is built exactly as `string` would build it" begin
        # The digits go into the string's bytes by hand, which is only worth doing
        # if it cannot disagree with the obvious way of writing it.
        prefix = "/tmp/runtests_abcdef/item_"
        for index in (1, 9, 10, 99, 100, 2000, 12345), attempt in (1, 2, 9, 10, 127)
            @test Runtests.Private.item_log_path(prefix, index, attempt) ==
                string(prefix, index, "_", attempt, ".log")
        end
    end

    @testset "every [TEST] line starts in the same column" begin
        # The things Runtests says that run to more than one line are bracketed, and
        # the gutter takes the two columns the one-line ones leave blank — so the
        # prefix is in one column down the whole log, bracketed or not.
        # Counted in characters: a bracket's corner is more than one byte wide.
        column(l) = length(SubString(l, 1, prevind(l, first(findfirst("[TEST]", l))))) + 1
        cols = unique(column(l) for l in lines if occursin("[TEST]", l))
        @test length(cols) == 1
        @test only(cols) == length(Runtests.Private.GUTTER) + 1
        # ...and the multi-line ones really are drawn as blocks.
        @test any(l -> startswith(l, "┌ [TEST] "), lines)
        @test count(l -> startswith(l, "└"), lines) >= 1
    end

    @testset "no two writers share a line" begin
        # A marker that starts a line must never appear in the middle of one:
        # that is what interleaved writes look like.
        for marker in ("[TEST]", "· RUN", "· DONE", "Captured logs:")
            for l in lines
                occursin(marker, l) || continue
                @test count(marker, l) == 1
                if marker == "[TEST]"
                    # At the start of its line, after the gutter or after a
                    # bracket's corner. Anywhere else is two writers on one line.
                    @test startswith(l, Runtests.Private.GUTTER * "[TEST]") ||
                        occursin(r"^[┌│└] \[TEST\]", l)
                end
            end
        end
        # Nothing may be printed after a worker's relayed line on the same line.
        for l in lines
            occursin(r" w\d+ · \d\d:\d\d:\d\d · ", l) || continue
            @test count(r"\sw\d+ · ", l) == 1
        end
    end

    @testset "an item's failures and logs arrive as one bracketed block" begin
        work2 = mktempdir()
        out2 = joinpath(work2, "run.log")
        script2 = joinpath(work2, "run.jl")
        write(script2, """
        push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
        using Runtests
        try
            Runtests.runtests($(repr(fixture("Faulty.jl"))); workers=1, logs=:issues, monitor=false,
                          name="fails after logging")
        catch
        end
        """)
        run(pipeline(ignorestatus(addenv(plain_julia(script2),
                                         "RUNTESTS_RUNSTATE_DIR" => joinpath(work2, "runs"),
                                         "RUNTESTS_FAULTY_DIR" => work2));
                     stdout=out2, stderr=out2))
        # The item's own block, not the run header's or the conclusion's: those are
        # bracketed too, and what this is about is that one item's output is one
        # block.
        all_lines = split(read(out2, String), '\n')
        first_line = findfirst(l -> startswith(l, "┌ [1/1] FAIL "), all_lines)
        @test first_line !== nothing
        last_line = findnext(l -> startswith(l, "└"), all_lines, first_line)
        block = all_lines[first_line:last_line]
        @test all(l -> startswith(l, "┌") || startswith(l, "│") || startswith(l, "└"), block)
        @test startswith(last(block), "└ @ " * joinpath("test", "faults_test.jl") * ":")
        # the item's failure, its captured output and its own log records, nested
        @test any(l -> occursin("Expression: 1 == 2", l), block)
        @test any(l -> occursin("┌ Captured logs", l), block)
        @test any(l -> occursin("some output before the failure", l), block)
        @test any(l -> occursin("Warning: something looked wrong", l), block)
        # nothing about this item is printed outside the block
        others = filter(l -> !isempty(l) && !startswith(l, "┌") && !startswith(l, "│") &&
                             !startswith(l, "└"), split(read(out2, String), '\n'))
        @test !any(l -> occursin("Expression: 1 == 2", l), others)
    end

    @testset "logs=:quiet prints a failure without its output, which stays in the logs" begin
        work3 = mktempdir()
        out3 = joinpath(work3, "run.log")
        script3 = joinpath(work3, "run.jl")
        write(script3, """
        push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
        using Runtests
        try
            Runtests.runtests($(repr(fixture("Faulty.jl"))); workers=1, logs=:quiet, monitor=false,
                          name="fails after logging")
        catch
        end
        """)
        runs = joinpath(work3, "runs")
        run(pipeline(ignorestatus(addenv(plain_julia(script3),
                                         "RUNTESTS_RUNSTATE_DIR" => runs,
                                         "RUNTESTS_FAULTY_DIR" => work3));
                     stdout=out3, stderr=out3))
        text = read(out3, String)
        @test occursin("FAIL", text)
        @test occursin("Expression: 1 == 2", text)
        @test !occursin("Captured logs", text)
        @test !occursin("some output before the failure", text)
        @test !occursin("something looked wrong", text)
        logs = [joinpath(d, f) for (d, _, fs) in walkdir(runs) for f in fs if endswith(d, ".rundata") && endswith(f, ".log")]
        @test any(f -> occursin("some output before the failure", read(f, String)), logs)
    end

    @testset "no terminal control sequences when there is no terminal" begin
        @test !occursin("\e[2K", log)
        @test !occursin("\e[", log)
    end

    @testset "an outcome is drawn in a colour given as a number" begin
        # `JULIA_ERROR_COLOR=196` makes `Base.error_color()` a number rather than a name.
        P = Runtests.Private
        withenv("JULIA_ERROR_COLOR" => "196", "JULIA_WARN_COLOR" => "208") do
            for (state, code) in ((P.FAILED, 196), (P.SKIPPED, 208))
                text = sprint(io -> P.print_colored(io, P.short_state(state), 4, P.state_color(state)); context = :color => true)
                @test startswith(text, Base.text_colors[code]) && occursin(P.short_state(state), text)
            end
            how = (; state = P.FAILED, elapsed_ns = UInt64(1), compile_ns = UInt64(0), maxrss = UInt64(1))
            @test occursin("FAIL", P.item_line(1, 1, 2, "\"x\"", 12, 1, 1, how))
        end
    end

    @testset "a worker's label is as wide as the run's widest, so lines line up past the ninth" begin
        P = Runtests.Private
        how = (; state = P.PASSED, elapsed_ns = UInt64(1), compile_ns = UInt64(0), maxrss = UInt64(1))
        at = (line, word) -> findfirst(word, line)
        width = P.SLOT_LABEL_WIDTH[]
        try
            P.SLOT_LABEL_WIDTH[] = P.slot_label_width(12)
            lines = [P.item_line(s, 1, 12, "\"x\"", 3, 1, 1, how) for s in (1, 9, 10, 12)]
            @test allequal(at(l, "DONE") for l in lines)
            @test startswith(lines[1], "🟢 w1  · ") && startswith(lines[3], "🟢 w10 · ")
            P.SLOT_LABEL_WIDTH[] = P.slot_label_width(9)
            @test startswith(P.item_line(9, 1, 12, "\"x\"", 3, 1, 1, how), "🟢 w9 · ")
        finally
            P.SLOT_LABEL_WIDTH[] = width
        end
    end

    @testset "the child that wrote that log was never asked for colour" begin
        # Every assertion above reads the log as plain text, so the child that
        # writes it must not colour it — and whether it does is decided by the
        # suite, not by this file: `Base.julia_cmd()` carries the `--color` of
        # whoever ran the tests. `plain_julia` appends `--color=no`, which holds
        # because julia takes the last `--color` on the line.
        ask = "print(get(stdout, :color, false))"
        @test read(`$(Base.julia_cmd()) --startup-file=no --color=yes -e $ask`, String) == "true"
        @test read(`$(Base.julia_cmd()) --startup-file=no --color=yes --color=no -e $ask`,
                   String) == "false"
        @test read(plain_julia("-e", ask), String) == "false"
    end

    @testset "what a worker says while it dies is filed once it is gone" begin
        # The worker still has the item's log open while it is being taken down,
        # and `open(path, "a")` seeks to the end when it opens rather than on every
        # write — so two processes appending to one file keep separate offsets and
        # write over each other. These lines wait for the process to go.
        dir = mktempdir()
        path = joinpath(dir, "item_1_1.log")
        write(path, "what the item printed\n")     # the worker's own capture
        slot = Runtests.Private.Slot(
            Runtests.Private.SlotIdx(1),
            Runtests.Private.ProfileIdx(1), nothing, 0.0, 0, Runtests.Private.ItemIdx(0),
            Int8(0), path, String[], false, Runtests.Private.ItemIdx(0)
        )
        for i in 1:3
            Runtests.Private.keep_dying_line!(slot, "signal $i")
        end
        @test read(path, String) == "what the item printed\n"     # nothing yet
        Runtests.Private.flush_dying_log!(slot)
        @test readlines(path) == ["what the item printed", "signal 1", "signal 2", "signal 3"]
        # ...and the slot is ready for the process that replaces this one.
        @test isempty(slot.dying_lines)
        @test isempty(slot.dying_log)

        # A process can print without limit on its way down.
        @atomic slot.dying_log = path
        for i in 1:(Runtests.Private.MAX_DYING_LINES + 50)
            Runtests.Private.keep_dying_line!(slot, "line $i")
        end
        @test length(slot.dying_lines) == Runtests.Private.MAX_DYING_LINES
        Runtests.Private.flush_dying_log!(slot)
        @test length(readlines(path)) == 4 + Runtests.Private.MAX_DYING_LINES

        # A log that cannot be written is a lost backtrace, never a failed run.
        @atomic slot.dying_log = joinpath(dir, "no", "such", "dir", "x.log")
        Runtests.Private.keep_dying_line!(slot, "x")
        @test Runtests.Private.flush_dying_log!(slot) === nothing
        @test isempty(slot.dying_lines)
    end

    @testset "what an exit hook writes is written before it returns, to a pipe or not" begin
        # The exit hook writes the closing block this way: on Unix straight to the
        # pipe's descriptor, without libuv, and every byte of it.
        p = Pipe()
        Base.link_pipe!(p; reader_supports_async = true, writer_supports_async = true)
        # Less than any pipe holds: a full pipe makes it wait on the reader, which
        # cannot run while it does.
        text = repeat("a line of the closing block\n", 50)
        reader = @async read(p.out, String)
        Runtests.Private.write_now(p.in, text)
        close(p.in)
        @test fetch(reader) == text
        io = IOBuffer()
        Runtests.Private.write_now(io, "anywhere else\n")
        @test String(take!(io)) == "anywhere else\n"
    end

    @testset "items are numbered in start order across RUN, DONE, retries and failure blocks" begin
        P = Runtests.Private
        p, _ = P.prepare((fixture("Basic.jl"),); workers = 2, logs = :issues, monitor = false)
        n = P.nitems(p)
        @test n >= 3
        names, column = P.item_names(p, P.run_name_width(p))
        scratch = mktempdir()
        run = P.Run(
            p, P.Queues(p), P.Statuses(n), P.Slot[], "Basic", "testrun", scratch, scratch, "",
            String[scratch], String[joinpath(scratch, "item_")], String[joinpath(scratch, "art_")],
            P.ItemIdx[P.ItemIdx(i) for i in 1:n], String[], falses(length(p.profiles)), Int32(0), column, names,
            ReentrantLock(), time(), nothing, nothing, Dict{P.ProfileIdx, String}(), zeros(Int32, n), 0, 0, 0,
            0.0, false, Task[], RuntestsWorkers.Worker[],
            Vector{Union{Nothing, RuntestsWorkers.WorkerProcess}}(nothing, P.nslots(p)), ReentrantLock(),
            Set{Int32}(), Tuple{P.ItemIdx, Int8}[], nothing, nothing, nothing, ReentrantLock(), Threads.threadid(),
        )
        # Start items out of plan order: plan item n starts first, then 1, then 2.
        fail_how = (; state = P.FAILED, elapsed_ns = UInt64(1), compile_ns = UInt64(0), maxrss = UInt64(1))
        pass_how = (; state = P.PASSED, elapsed_ns = UInt64(1), compile_ns = UInt64(0), maxrss = UInt64(1))
        captured = mktemp() do path, io
            redirect_stdout(io) do
                P.print_item_line(run, 1, n, 1, nothing)       # start #1 (plan index n)
                P.print_item_line(run, 2, 1, 1, nothing)       # start #2 (plan index 1)
                P.print_item_line(run, 1, n, 1, fail_how)      # DONE #1
                P.print_item_line(run, 1, n, 2, nothing)       # retry of #1 keeps #1
                P.print_item_line(run, 2, 1, 1, pass_how)      # DONE #2 finishes before retry of #1
                P.print_item_line(run, 1, n, 2, fail_how)      # DONE #1 after #2 finished
                # Failure block for plan item n must carry [1/N], matching its RUN/DONE lines,
                # even though it is the second finished item (`ndone == 2`).
                ts = Test.DefaultTestSet(p.items.name[n])
                Test.record(ts, Test.Fail(:test, "1 == 2", 1, 2, nothing, LineNumberNode(1, :test), false))
                P.count_done!(run, P.ItemIdx(1))
                P.count_done!(run, P.ItemIdx(n))
                o = P.AttemptOutcome(
                    P.ItemIdx(n), P.SlotIdx(1), Int8(2), P.FAILED, P.FAILED, Int32(1), 0.1,
                    RuntestsWorkers.PerfStats(), ts, false, 0x00, "", time()
                )
                P.report_item!(run, o)
                # An item that fails before any RUN line prints still gets the next start number (3).
                ts2 = Test.DefaultTestSet(p.items.name[2])
                Test.record(ts2, Test.Fail(:test, "false", false, true, nothing, LineNumberNode(1, :test), false))
                o2 = P.AttemptOutcome(
                    P.ItemIdx(2), P.SlotIdx(2), Int8(1), P.ERRORED, P.ERRORED, Int32(0), 0.0,
                    RuntestsWorkers.PerfStats(), ts2, false, 0x00, "", time()
                )
                P.report_item!(run, o2)
            end
            flush(io)
            read(path, String)
        end
        out_lines = split(captured, '\n')
        @test occursin("· RUN  · 1/$n · $(names[n])", out_lines[1])
        @test occursin("· RUN  · 2/$n · $(names[1])", out_lines[2])
        @test occursin("· DONE · 1/$n · $(names[n])", out_lines[3])
        @test occursin("· RUN  · 1/$n · $(names[n])", out_lines[4]) && occursin("retry 1 of", out_lines[4])
        @test occursin("· DONE · 2/$n · $(names[1])", out_lines[5])
        @test occursin("· DONE · 1/$n · $(names[n])", out_lines[6])
        @test any(l -> startswith(l, "┌ [1/$n] FAIL $(repr(p.items.name[n]))"), out_lines)
        @test any(l -> startswith(l, "┌ [3/$n] ERR $(repr(p.items.name[2]))"), out_lines)
        @test (@atomic run.ndone) == 2
        @test run.nstarted == 3
        rm(scratch; force = true, recursive = true)
    end

    @testset "display-width helpers and wrapped lists" begin
        P = Runtests.Private
        # Short lists stay on one line with no trailing space.
        short = sprint(io -> P.print_wrapped_list(io, "setups: ", ["`Alpha`", "`Beta`"]; width = 80))
        @test short == "setups: `Alpha`, `Beta`\n"

        # Long comma lists wrap cleanly with aligned continuation indent and no trailing spaces.
        setups = ["`SetupModuleNumber$i`" for i in 1:8]
        wrapped = sprint(io -> P.print_wrapped_list(io, "setups: ", setups; width = 60))
        wlines = split(chomp(wrapped), '\n')
        @test length(wlines) >= 3
        @test all(l -> textwidth(l) <= 60, wlines)
        @test all(l -> l == rstrip(l), wlines)
        @test all(l -> startswith(l, "        "), wlines[2:end])
        @test all(l -> endswith(l, ","), wlines[1:(end - 1)])
        @test !endswith(wlines[end], ",")

        # ` · `-separated lists break cleanly between items without dangling separators.
        est = ["w$i 12.3s" for i in 1:10]
        dot_wrapped = sprint(io -> P.print_wrapped_list(io, "estimated work: ", est; sep = " · ", width = 50))
        dlines = split(chomp(dot_wrapped), '\n')
        @test length(dlines) >= 2
        @test all(l -> textwidth(l) <= 50, dlines)
        @test all(l -> l == rstrip(l) && !endswith(l, "·"), dlines)

        # Inside a bracket, every continuation line and any blank line carries the `│` / `└` gutter.
        blk = P.bracket(wrapped * "\nnext: ok\n", "[TEST]", "head", "", :default)
        blines = split(chomp(blk), '\n')
        @test startswith(blines[1], "┌ [TEST] head")
        @test all(l -> startswith(l, "│"), blines[2:(end - 1)])
        @test startswith(blines[end], "└ ")
        @test all(l -> l == rstrip(l), blines)

        # `explicit_columns` and `wrap_columns` respect `IOContext(:displaysize)` and `COLUMNS`,
        # and off-TTY defaults to `DEFAULT_WRAP_COLUMNS` for lists while staying `0` for `explicit_columns`.
        withenv("COLUMNS" => nothing) do
            buf = IOBuffer()
            @test P.explicit_columns(buf) == 0
            @test P.wrap_columns(buf; gutter = 2) == P.DEFAULT_WRAP_COLUMNS - 2
            ctx = IOContext(buf, :displaysize => (24, 72))
            @test P.explicit_columns(ctx) == 72
            @test P.wrap_columns(ctx; gutter = 2) == 70
            fwd = P.io_context_like(IOBuffer(), ctx)
            @test displaysize(fwd) == (24, 72)
        end
        withenv("COLUMNS" => "90") do
            buf = IOBuffer()
            @test P.explicit_columns(buf) == 90
            @test P.wrap_columns(buf; gutter = 2) == 88
            fwd = P.io_context_like(IOBuffer(), buf)
            @test displaysize(fwd)[2] == 90
        end

        # `print_plan` forwards `io`'s `:displaysize` to both wrapped header lists and the plan table.
        dir = make_pkg("WidePlan")
        mkpath(joinpath(dir, "test", "testsetups"))
        snames = ["WideSetupModuleNumber$i" for i in 1:6]
        for s in snames
            write(joinpath(dir, "test", "testsetups", "$s.jl"), "module $s end\n")
        end
        write(joinpath(dir, "test", "w_test.jl"),
              string("@testitem \"a considerably longer item name for width budgeting\" begin\n",
                     join(("    using $s\n" for s in snames)),
                     "    @test true\nend\n"))
        p, _ = Runtests.Private.prepare((dir,); workers = 1, monitor = false)
        narrow = sprint(io -> P.print_plan(IOContext(io, :displaysize => (24, 64)), p))
        nlines = split(chomp(narrow), '\n')
        setup_idx = findfirst(l -> occursin("setups: ", l), nlines)
        @test setup_idx !== nothing
        @test startswith(nlines[setup_idx + 1], "│         ")
        @test all(l -> textwidth(l) <= 64, nlines[setup_idx:(setup_idx + 2)])
        @test any(l -> startswith(l, "│ items: 1 test item in 1 file"), nlines)

        # `comp_line_reserved` accounts for package, kind, and version columns.
        @test P.comp_line_reserved(2, 10, 12, 9, 6) > P.comp_line_reserved(0, 10, 0, 6, 0)
    end
end
