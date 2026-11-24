# Sandboxes, throttles and forced order, in combination. Each of the three decides
# something different about where or when an item runs — alone in a process, beside
# at most so many of its throttle, at a fixed point in the queue — and a suite
# normally uses more than one of them at once.

using Runtests.Private: PASSED, nitems, nslots

# An item that takes long enough for an overlap to show, and records when it ended
# as well as when it started; `before` runs first.
timed_item(name; opts="", before="") = journal_item(name; opts, body=before * """
    sleep(0.2)
    open(joinpath(ENV["RUNTESTS_JOURNAL"], string(time_ns(), "-", getpid(), "-end")), "w") do io
        println(io, $(repr(name * " end")), "\\t", getpid(), "\\t", time())
    end
    @test true
    """)

@testset "sandboxes, throttles and order" begin
    @testset "a sandboxed item has its process to itself" begin
        dir = make_pkg("Alone", "test/t_test.jl" => string(
            journal_item("before"),
            journal_item("alone"; opts="sandbox=true"),
            journal_item("after"),
        ))
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 3
        alone = only(r for r in rows if r.name == "alone")
        # Nothing else ran in that process, before it or after it.
        @test count(r -> r.pid == alone.pid, rows) == 1
        # ...and the other two shared one, so this is about the sandbox and not
        # about every item getting a process.
        @test length(unique(r.pid for r in rows)) == 2
    end

    @testset "a sandbox worker says it is one, and is put down when it hangs" begin
        # A sandbox under the default profile is otherwise indistinguishable from a
        # pool worker in the log: same flags, same threads. The line has to say why
        # the process exists, because "one more worker came up" and "this item
        # demanded a process of its own" are different things to read past.
        dir = make_pkg("SandboxLog", "test/t_test.jl" => """
        @testitem "pooled one" begin
            @test true
        end
        @testitem "solo" sandbox=true begin
            @test true
        end
        @testitem "solo hangs" sandbox=true timeout=2 begin
            sleep(600)
        end
        @testitem "pooled two" begin
            @test true
        end
        """)
        _, out = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false)
        end
        lines = collect(eachsplit(out, '\n'))
        workers = worker_lines(out)
        ups = filter(l -> occursin("· UP ", l), workers)
        @test length(ups) == 3                      # one pool worker and two sandboxes
        @test count(l -> occursin("· sandbox", l), ups) == 2
        # The pool worker that ran the two ordinary items is not one of them.
        @test count(l -> !occursin("· sandbox", l), ups) == 1
        # A run of the default profile alone names no profile.
        @test !any(l -> occursin("· profile", l), ups)
        # The one that hung was killed; the one that passed was closed. Both words
        # appear, and neither stands in for the other.
        @test count(l -> occursin("· KILL", l), lines) == 1
        @test any(l -> occursin("· KILL", l) && occursin("solo hangs", l), lines)
        # A killed worker is already gone, so it is not also reported as exiting:
        # one UP per teardown line, three and three.
        @test count(l -> occursin("· EXIT", l), workers) == 2
    end

    @testset "a slot that has drained its sandboxes takes ordinary work" begin
        # A sandbox leads its profile's pool, in a process of its own that is torn
        # down after it. The slot that ran it has to go on to the pool's ordinary
        # work: going home with the rest of the suite still queued is a worker the
        # run paid for and did not use.
        ordinary_names = ["ordinary $i" for i in 1:6]
        dir = make_pkg(
            "SandboxThenSteal",
            "test/a_test.jl" => """
            @testitem "solo" sandbox=true begin
                @test true
            end
            """,
            # Each holds its worker until another process has started one of them,
            # so the ordinary pool's own slot cannot get through them alone.
            ("test/b_$(i)_test.jl" => journal_item(
                ordinary_names[i]; body=started_elsewhere(ordinary_names) * "@test true"
            ) for i in 1:6)...,
        )
        states, run, p = with_journal() do _
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
        idx(name) = findfirst(==(name), p.items.name)
        sandbox_slot = run.statuses.slot[idx("solo")]
        ordinary = [run.statuses.slot[idx(name)] for name in ordinary_names]
        @test count(==(sandbox_slot), ordinary) > 0
        # ...and the other slot did not sit idle either, so this is about sharing
        # the work and not about one slot taking all of it.
        @test length(unique(ordinary)) == 2
    end

    @testset "a sandbox reached with a used worker still gets a process of its own" begin
        # The reverse direction: a slot arrives at a sandbox holding a worker that
        # has already run another item. `[order] first` puts the ordinary item ahead
        # of the sandboxes at the head of the pool, so the slot that runs it takes a
        # sandbox next. A sandbox that inherits that process is not the test that
        # was declared, however green it comes out.
        dir = make_pkg(
            "SandboxAfterWork",
            "test/a_test.jl" => journal_item("ordinary"),
            ("test/b_$(i)_test.jl" => journal_item(
                "solo $i"; opts="sandbox=true", body="sleep(0.3)\n@test true"
            ) for i in 1:4)...,
            "test/TestItems.toml" => "[order]\nfirst = [\"ordinary\"]\n",
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 5
        for i in 1:4
            solo = only(r for r in rows if r.name == "solo $i")
            @test count(r -> r.pid == solo.pid, rows) == 1
        end
    end

    @testset "a sandboxed item is retried in a fresh process each time" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("AloneRetries", "test/t_test.jl" => journal_item(
                "flaky alone"; opts="sandbox=true retries=2", body="""
                k = let p = ENV["RUNTESTS_CRASH_MARKER"]
                    n = isfile(p) ? parse(Int, read(p, String)) : 0
                    write(p, string(n + 1))
                    n
                end
                k < 2 && ccall(:abort, Cvoid, ())
                @test k == 2
                """
            ))
            rows = withenv("RUNTESTS_CRASH_MARKER" => marker) do
                with_journal() do path
                    states, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                    @test states["flaky alone"] === PASSED
                    @test run.statuses.attempt[1] == 3
                    journal(path)
                end
            end
            @test length(rows) == 3
            @test length(unique(r.pid for r in rows)) == 3
        end
    end

    @testset "a throttle above 1 runs that many of its items at once, beside other items, and no more" begin
        gated = ["gated $k" for k in 1:4]
        plain = ["plain 1", "plain 2"]
        # Each body holds its worker until three items have started: the run's three
        # workers each start one, two of the throttle and one other, and a limit the
        # run did not keep would let a third of the throttle start instead.
        three_started = """
            let dir = ENV["RUNTESTS_JOURNAL"], deadline = time() + 30
                started() = count(readdir(dir; join=true)) do f
                    endswith(f, ".tmp") && return false
                    r = try
                        split(strip(read(f, String)), '\\t')
                    catch
                        return false
                    end
                    length(r) == 3 && !endswith(r[1], " end")
                end
                while started() < 3
                    time() > deadline && (touch(joinpath(dir, "gave-up")); break)
                    sleep(0.05)
                end
            end
            """
        dir = make_pkg(
            "Throttled",
            "test/t_test.jl" => join(timed_item(n; opts="throttle=:g", before=three_started) for n in gated) *
                                join(journal_item(n; body=three_started * "sleep(0.2)\n@test true") for n in plain),
            "test/TestItems.toml" => "[throttle]\ng = 2\n[order]\nfirst = $(repr(gated))\n",
        )
        spans, pids, gave_up, states, slots = with_journal() do path
            states, _, p = run_states(dir; workers=3, logs=:issues, monitor=false)
            # When each began and ended, by the clock all processes of the machine share.
            at = Dict{String, Float64}()
            pids = Set{Int}()
            for f in readdir(path; join=true)
                r = split(strip(read(f, String)), '\t')
                length(r) == 3 || continue
                at[r[1]] = parse(Float64, r[3])
                push!(pids, parse(Int, r[2]))
            end
            [(at[n], get(at, n * " end", Inf)) for n in gated], pids, isfile(joinpath(path, "gave-up")), states,
                nslots(p)
        end
        @test slots == 3
        @test all(==(PASSED), values(states))
        @test !gave_up
        @test length(pids) == 3
        # When any of them began, at most one other was under way; and two were at once.
        under_way(a) = count(((b, e),) -> b <= a < e, spans)
        @test all(((a, _),) -> under_way(a) <= 2, spans)
        @test any(((a, _),) -> under_way(a) == 2, spans)
    end

    @testset "a warmup throttle finishes one item alone while other items run, then overlaps up to limit" begin
        gated = ["warm $k" for k in 1:4]
        plain = ["plain 1", "plain 2"]
        # Wait until 1 gated item and both plain items have started, so the warmup item is
        # provably running alongside plain items while gated 2..4 are held back.
        warmup_wait = """
            let dir = ENV["RUNTESTS_JOURNAL"], deadline = time() + 30
                started() = count(readdir(dir; join=true)) do f
                    endswith(f, ".tmp") && return false
                    r = try
                        split(strip(read(f, String)), '\\t')
                    catch
                        return false
                    end
                    length(r) == 3 && !endswith(r[1], " end")
                end
                while started() < 3
                    time() > deadline && (touch(joinpath(dir, "gave-up")); break)
                    sleep(0.05)
                end
            end
            """
        # Once warmup ends, items 2..4 hold until 2 post-warmup gated items are active at once.
        post_warmup_wait = """
            let dir = ENV["RUNTESTS_JOURNAL"], deadline = time() + 30
                started_gated() = count(readdir(dir; join=true)) do f
                    endswith(f, ".tmp") && return false
                    r = try
                        split(strip(read(f, String)), '\\t')
                    catch
                        return false
                    end
                    length(r) == 3 && startswith(r[1], "warm ") && !endswith(r[1], " end")
                end
                while started_gated() < 3
                    time() > deadline && (touch(joinpath(dir, "gave-up-post")); break)
                    sleep(0.05)
                end
            end
            """
        dir = make_pkg(
            "ThrottledWarmup",
            "test/t_test.jl" =>
                timed_item("warm 1"; opts="throttle=:g", before=warmup_wait * "sleep(0.2)\n") *
                join(timed_item(n; opts="throttle=:g", before=post_warmup_wait * "sleep(0.1)\n") for n in gated[2:end]) *
                join(journal_item(n; body=warmup_wait * "sleep(0.1)\n@test true") for n in plain),
            "test/TestItems.toml" => "[throttle]\ng = { limit = 2, warmup = true }\n[order]\nfirst = $(repr(gated))\n",
        )
        at, gave_up, gave_up_post, states = with_journal() do path
            states, _, _ = run_states(dir; workers=3, logs=:issues, monitor=false)
            at = Dict{String, Float64}()
            for f in readdir(path; join=true)
                r = split(strip(read(f, String)), '\t')
                length(r) == 3 || continue
                at[r[1]] = parse(Float64, r[3])
            end
            at, isfile(joinpath(path, "gave-up")), isfile(joinpath(path, "gave-up-post")), states
        end
        @test all(==(PASSED), values(states))
        @test !gave_up && !gave_up_post
        # Both plain items started before warm 1 ended (non-gated work ran during warmup).
        @test at["plain 1"] < at["warm 1 end"] && at["plain 2"] < at["warm 1 end"]
        # No other gated item started before warm 1 ended.
        @test all(n -> at[n] >= at["warm 1 end"], gated[2:end])
        # After warmup, at most 2 ran concurrently, and 2 actually overlapped.
        spans = [(at[n], at[n * " end"]) for n in gated]
        under_way(a) = count(((b, e),) -> b <= a < e, spans)
        @test all(((a, _),) -> under_way(a) <= 2, spans)
        @test any(((a, _),) -> under_way(a) == 2, spans)
    end

    @testset "an idle slot never runs work belonging to another profile in its own process" begin
        # One quick item in the default pool and three slow ones in a pool with
        # different julia flags: the default slot drains first and goes looking for
        # work. What it must not do is run an item declared to run under flags its
        # own process was not started with — that item would be reported as a pass
        # without ever having been run the way it was written. It may go on with
        # them in a process started with their flags, which each item checks.
        dir = make_pkg(
            "NoCrossPoolSteal",
            "test/t_test.jl" => string(
                journal_item("quick"),
                journal_item("checked one"; opts="profile=:bounds",
                             body="sleep(0.5)\n@test Base.JLOptions().check_bounds == 1"),
                journal_item("checked two"; opts="profile=:bounds",
                             body="sleep(0.5)\n@test Base.JLOptions().check_bounds == 1"),
                journal_item("checked three"; opts="profile=:bounds",
                             body="sleep(0.5)\n@test Base.JLOptions().check_bounds == 1"),
            ),
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 4
        # The quick one's process ran none of the bounds items.
        checked = unique(r.pid for r in rows if startswith(r.name, "checked"))
        @test only(r.pid for r in rows if r.name == "quick") ∉ checked
    end

    @testset "a slot whose profile's items are done goes on with another profile's" begin
        # One quick item under a profile of its own, and enough default items for
        # `neediest_pool` to judge a second worker worth starting. `d1` holds its slot
        # until any other default item has started elsewhere, so the profile's slot
        # always finishes `tiny`, rebinds to the default profile, and takes a share
        # regardless of how long worker startup takes on a busy machine.
        others = ["d$i" for i in 2:20]
        dir = make_pkg(
            "Refilled",
            "test/tiny_test.jl" => journal_item("tiny"; opts = "profile=:tiny", body = "@test ENV[\"TINY\"] == \"1\""),
            "test/a_test.jl" => journal_item("d1"; body = started_elsewhere(others) * "@test !haskey(ENV, \"TINY\")"),
            "test/b_test.jl" => string((journal_item(n; body = "@test !haskey(ENV, \"TINY\")") for n in others)...),
            "test/TestItems.toml" => "[profiles.tiny]\nenv = { TINY = \"1\" }\n[order]\nfirst = [\"d1\"]\n",
        )
        rows = with_journal() do path
            states, run, p = run_states(dir; workers = 2, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
            ran = [run.statuses.slot[i] for i in 1:nitems(p) if p.items.name[i] != "tiny"]
            tiny_slot = run.statuses.slot[findfirst(==("tiny"), p.items.name)]
            # Default items ran on both slots, the profile's among them.
            @test sort(unique(ran)) == [1, 2]
            @test tiny_slot in ran
            journal(path)
        end
        # In a process of its own, not the one the profile's item ran in: each item
        # checked it ran under its own profile's environment.
        tiny_pid = only(r.pid for r in rows if r.name == "tiny")
        @test tiny_pid ∉ [r.pid for r in rows if r.name != "tiny"]
    end

    @testset "the last unit in a queue can still be stolen" begin
        # Two files are two affinity groups, so each slot gets one. One holds a
        # slow item followed by a quick one; the other holds a single quick item
        # and is done almost at once. The item left over must not sit behind the
        # slow one waiting for a worker that is busy, while a free worker goes home.
        #
        # "slow one" holds its worker until "left over" has started elsewhere, and
        # "quick" holds the other worker until "slow one" is running: the free slot
        # goes looking for work while the other is busy, whichever starts first.
        dir = make_pkg(
            "LastUnit",
            "test/a_test.jl" => string(
                journal_item("slow one"; body=started_elsewhere(["left over"]) * "@test true"),
                journal_item("left over"),
            ),
            "test/b_test.jl" => journal_item("quick"; body=started_elsewhere(["slow one"]) * "@test true"),
        )
        states, run, p = with_journal() do _
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
        # The slot the coordinator recorded: these two items now run at the same
        # time, which is the whole point, so a shared marker file would race.
        slot_of(name) = run.statuses.slot[findfirst(==(name), p.items.name)]
        @test slot_of("left over") != slot_of("slow one")
    end

    @testset "a sandbox alongside forced order still runs exactly once, alone" begin
        dir = make_pkg(
            "OrderedSandbox",
            "test/t_test.jl" => string(
                journal_item("plain one"),
                journal_item("solo"; opts="sandbox=true"),
                journal_item("plain two"),
            ),
            "test/TestItems.toml" => "[order]\nfirst = [\"plain two\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 3
        solo = only(r for r in rows if r.name == "solo")
        @test count(r -> r.pid == solo.pid, rows) == 1
        # The pinned item leads the pool it is in.
        plain = [r.name for r in rows if r.name != "solo"]
        @test plain == ["plain two", "plain one"]
    end
end
