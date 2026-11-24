using Runtests.Private: plan, scan, discover, setup_modules, read_config, Filter, History, ConfigError,
            ScanFailure, nslots, nitems, NO_THROTTLE, print_plan, RawItem, USE_RUN_DEFAULT,
            DEFAULT_PROFILE, ItemIdx
using Random: Xoshiro

const PKG = fixture("Basic.jl")
const TESTDIR = joinpath(PKG, "test")

read_items(; filter=Filter()) = scan(discover(TESTDIR), filter, setup_modules(TESTDIR))

function make_plan(; filter=Filter(), history=History(), kwargs...)
    items = read_items(; filter)
    cfg = read_config(TESTDIR; nunits=length(items), kwargs...)
    return plan(items, cfg; history, root=PKG)
end

# The order items would run in if the workers' queues were concatenated.
dispatch_order(p) = [p.items.name[i] for i in 1:nitems(p)]
slot_names(p, s) = [p.items.name[i] for i in p.slot_items[s]]
# Every item in the order the plan hands them out: each pool's head, its slots' stretches
# (the whole body for a pool still waiting for a slot), then its tail.
planned(p) = [p.items.name[i] for (k, pool) in enumerate(p.pools)
              for r in [[pool.head]; [p.slot_items[s] for s in 1:nslots(p) if p.slot_pool[s] == k];
                        k in p.pending ? [pool.body] : UnitRange{Int32}[]; [pool.tail]]
              for i in r]

@testset "plan" begin
    @testset "every item lands in the plan, handed out exactly once" begin
        p = make_plan()
        @test nitems(p) == 6
        @test sort(dispatch_order(p)) == sort([i.name for i in read_items()])
        assigned = planned(p)
        @test sort(assigned) == sort(dispatch_order(p))
        @test length(unique(assigned)) == length(assigned)
    end

    @testset "[order] first is honoured" begin
        p = make_plan()
        @test first(dispatch_order(p)) == "slow thing"
    end

    @testset "[order] naming an item both first and last is an error" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "a_test.jl"), """@testitem "one" begin\n end\n@testitem "two" begin\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"), "[order]\nfirst = [\"one\"]\nlast = [\"two\", \"one\"]\n")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        err = try; plan(items, read_config(joinpath(dir, "test")); root=dir); catch e; e; end
        @test err isa ConfigError
        @test occursin("puts these both first and last:\n  \"one\" is named by both", err.msg)
    end

    @testset "[order] naming an item the suite does not have is an error, whatever the selection" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "a_test.jl"), """@testitem "real" begin\n @test true\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"), "[order]\nfirst = [\"raal\"]\n")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        cfg = read_config(joinpath(dir, "test"))
        err = try; plan(items, cfg; root=dir); catch e; e; end
        @test err isa ConfigError
        @test occursin("do not exist", sprint(showerror, err))
        @test occursin("did you mean", sprint(showerror, err))   # near-match suggestion
        # A selection of other items does not hide the mistake.
        err = try; plan(items, cfg; root=dir, suite_names=["real"]); catch e; e; end
        @test err isa ConfigError
        # A pinned item the selection leaves out is no mistake: the rest run, in order.
        write(joinpath(dir, "test", "a_test.jl"), """@testitem "real" begin\n end\n@testitem "other" begin\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"), "[order]\nfirst = [\"real\"]\n")
        all_items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        others = filter(it -> it.name == "other", all_items)
        p = plan(others, read_config(joinpath(dir, "test")); root=dir, suite_names=["real", "other"])
        @test dispatch_order(p) == ["other"]
    end

    @testset "an unknown profile is an error naming the items" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "a_test.jl"),
              """@testitem "x" profile=:nope begin\n @test true\n end\n""")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        err = try; plan(items, read_config(joinpath(dir, "test")); root=dir); catch e; e; end
        @test err isa ConfigError
        @test occursin("`profile = :nope` has no [profiles.nope]", sprint(showerror, err))
        @test occursin("\"x\"", sprint(showerror, err))
    end

    @testset "workers are capped by the work available" begin
        p = make_plan(; workers=64)
        @test nslots(p) <= nitems(p)
        # and no pool has more slots than it has units to hand out
        for (k, pool) in enumerate(p.pools)
            @test count(==(k), p.slot_pool) <= length(pool.head) + length(pool.body) + length(pool.tail)
        end
    end

    @testset "affinity keeps items that share a file or a setup together" begin
        p = make_plan(; workers=2)
        for s in 1:nslots(p)
            names = slot_names(p, s)
            # "add works" and "mul works" share a file and no setup; they should not
            # be split while a whole-group assignment is possible
            if "add works" in names || "mul works" in names
                @test ("add works" in names) == ("mul works" in names)
            end
        end
    end

    @testset "history drives ordering" begin
        h = History(Dict("uses setup" => 100.0, "add works" => 0.1, "mul works" => 0.1),
                    Dict("mul works" => 0))
        p = make_plan(; history=h, workers=2)
        # the failure from last time is dispatched before the rest of its pool's work
        order = dispatch_order(p)
        @test findfirst(==("mul works"), order) < findfirst(==("uses setup"), order)
    end

    items(names...) = join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in names))
    function plan_dir(dir; history=History(), workers=2)
        testdir = joinpath(dir, "test")
        raw = scan(discover(testdir), Filter(), setup_modules(testdir))
        return plan(raw, read_config(testdir; nunits=length(raw), workers); history, root=dir)
    end

    @testset "recent failures and changed files lead, then long units, then file order" begin
        dir = make_pkg("Urgent", "test/a_test.jl" => items("a1", "a2", "a3"),
                       "test/b_test.jl" => items("b1", "b2"), "test/c_test.jl" => items("c1", "c2"))
        # a3 failed in the last run and b2 two runs ago; c2 takes more than a quarter
        # of a slot's share of the work.
        h = History(Dict("c2" => 60.0, "a1" => 1.0), Dict("b2" => 2, "a3" => 0))
        p = plan_dir(dir; history=h)
        @test length(only(p.pools).head) == 3
        @test dispatch_order(p) == ["a3", "b2", "c2", "a1", "a2", "b1", "c1"]
        # Among those as recent, a long one goes first, as long units do.
        h = History(Dict("c2" => 60.0, "a1" => 1.0), Dict("b2" => 2, "a3" => 0, "c2" => 0))
        @test dispatch_order(plan_dir(dir; history=h)) == ["c2", "a3", "b2", "a1", "a2", "b1", "c1"]
        # An item edited since its last run leads, and so does one that never ran; an
        # item that moved, or whose neighbour changed, has not changed.
        ran = plan_dir(dir)
        recorded = History(; hashes = Dict(ran.items.name[i] => ran.items.hash[i] for i in eachindex(ran.items.name)),
                           known = Set(ran.items.name))
        write(joinpath(dir, "test", "b_test.jl"), items("b1") * "@testitem \"b2\" begin\n    @test 1 == 1\nend\n")
        @test dispatch_order(plan_dir(dir; history = recorded))[1] == "b2"
        write(joinpath(dir, "test", "b_test.jl"), "\n# moved down\n" * items("b1", "b2", "b3"))
        moved = plan_dir(dir; history = recorded)
        @test dispatch_order(moved)[1] == "b3" && length(only(moved.pools).head) == 1
        # Over a quarter of a slot's share, but a matter of seconds: not long.
        p = plan_dir(dir; history=History(Dict("a1" => 2.0), Dict{String,Int}()))
        @test isempty(only(p.pools).head)
        @test p.items.why[findfirst(==("a1"), p.items.name)] === Runtests.Private.IN_FILE_ORDER
        # A sandboxed unit goes before any of them: its process is fresh anyway.
        write(joinpath(dir, "test", "c_test.jl"), items("c1") * "@testitem \"alone\" sandbox=true begin\n    @test true\nend\n")
        @test first(dispatch_order(plan_dir(dir; history=h))) == "alone"
    end

    @testset "the body is cut at a file boundary rather than through a file" begin
        p = plan_dir(make_pkg("Cut", "test/a_test.jl" => items("a1", "a2", "a3"), "test/b_test.jl" => items("b1")))
        @test [slot_names(p, s) for s in 1:2] == [["a1", "a2", "a3"], ["b1"]]
        p = plan_dir(make_pkg("OneFile", "test/a_test.jl" => items("a1", "a2", "a3", "a4")))
        @test [slot_names(p, s) for s in 1:2] == [["a1", "a2"], ["a3", "a4"]]
    end

    @testset "a slot takes the head, walks its stretch, halves the largest one left, then the tail" begin
        p = plan_dir(make_pkg("Claims", "test/a_test.jl" => items("a1", "a2", "a3", "a4", "a5", "a6"),
                              "test/b_test.jl" => items("b1", "b2"),
                              "test/TestItems.toml" => "[order]\nfirst = [\"b2\"]\nlast = [\"a1\"]\n"))
        q = Runtests.Private.Queues(p)
        next(s) = (c = Runtests.Private.claim!(q, s); c.kind === :item ? p.items.name[c.item] : c.kind)
        @test [next(2), next(2), next(1)] == ["b2", "b1", "a2"]
        @test next(2) == "a5"                                   # the second half of a3–a6
        @test [next(1), next(1), next(1)] == ["a3", "a4", "a6"] # then the one unit slot 2 had left
        @test [next(2), next(2)] == ["a1", :done]
        # A cursor pointing at a unit already handed out is a scheduling bug, stopped
        # rather than run twice.
        q2 = Runtests.Private.Queues(p)
        q2.claimed[q2.head[1]] = true
        @test_throws ErrorException Runtests.Private.claim!(q2, 1)
    end

    declared(names...; opts = "") = join(("@testitem \"$n\" $opts begin\n    @test true\nend\n" for n in names))

    @testset "however the slots take turns, a unit goes out once, whole, to a slot started as its profile starts" begin
        # Two pools. The default profile shares its pool with `ends`, which differs
        # from it only in `test_end`. Slot counts go from fewer than the pools to more
        # than one per pool, so a slot rebinds to a pool no slot serves, or steals from
        # another slot of its own pool.
        dir = make_pkg(
            "Claiming",
            "test/a_test.jl" => declared("a1", "a2", "a3", "c1", "c2", "c3"),
            "test/b_test.jl" => declared("b1", "b2", "b3", "b4", "d1", "d2"),
            "test/p_test.jl" => declared("p1", "p2", "p3", "e1", "e2"; opts = "profile=:bounds"),
            "test/t_test.jl" => declared("t1", "t2", "f1", "f2"; opts = "profile=:ends"),
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n[profiles.ends]\n",
            profile_files("ends"; test_end = "nothing")...,
        )
        starts(p, prof) = Runtests.Private.start_configuration(p.profiles[prof])
        for workers in (1, 2, 3, 5)
            p = plan_dir(dir; workers)
            @test length(p.pools) == 2
            # Every interleaving the slots could claim in, sampled.
            wrong = String[]
            for seed in 1:200
                rng = Xoshiro(seed)
                q = Runtests.Private.Queues(p)
                serves = copy(p.slot_pool)      # the pool each slot's process was started for
                handed = zeros(Int, nitems(p))
                live = collect(1:nslots(p))
                while !isempty(live)
                    s = rand(rng, live)
                    c = Runtests.Private.claim!(q, s)
                    if c.kind === :done
                        filter!(!=(s), live)
                    elseif c.kind === :rebind
                        # Only to a pool that still has something to hand out.
                        pool = p.pools[c.pool]
                        any(u -> !q.claimed[u], first(pool.head):last(pool.tail)) ||
                            push!(wrong, "seed $seed: slot $s rebound to pool $(c.pool), which had nothing left")
                        serves[s] = c.pool
                    else
                        handed[c.item] += 1
                        starts(p, p.items.profile[c.item]) == starts(p, p.pools[serves[s]].profile) ||
                            push!(wrong, "seed $seed: slot $s, serving pool $(serves[s]), took item $(c.item)")
                    end
                end
                all(==(1), handed) || push!(wrong, "seed $seed: items handed out $(handed)")
            end
            @test isempty(wrong)
        end
    end

    @testset "an item of a throttle belongs to its gate" begin
        dir = make_pkg("Gated",
            "test/a_test.jl" => declared("g1", "g2", "g3"; opts = "throttle=:g") * declared("c1", "c2"; opts = "throttle=:c") *
                                declared("a1"),
            "test/TestItems.toml" => "[throttle]\ng = 2\nunused = 3\n")
        p = plan_dir(dir; workers = 3)
        item(n) = findfirst(==(n), p.items.name)
        gate(n) = p.items.gate[item(n)]
        @test all(n -> p.items.throttle[item(n)] === :g, ("g1", "g2", "g3")) && allequal(gate.(["g1", "g2", "g3"]))
        # `c` has no limit in [throttle], so 1: one of its items at a time.
        @test gate("c1") == gate("c2") != gate("g1") && p.items.throttle[item("c1")] === :c
        @test p.gate_limit[gate("g1")] == 2 && p.gate_limit[gate("c1")] == 1
        @test p.items.throttle[item("a1")] === NO_THROTTLE && gate("a1") == 0
        # The dry run says which, on each item's row.
        out = sprint(print_plan, p)
        row(n) = only(l for l in split(out, '\n') if occursin(repr(n), l))
        @test occursin("throttle `g`, 2 at a time", row("g1"))
        @test occursin("throttle `c`, 1 at a time", row("c2"))
    end

    @testset "the items of a throttle may be sandboxed, and differ in profile and environment" begin
        dir = make_pkg("ThrottleMixes",
            "test/a_test.jl" => declared("s1"; opts = "throttle=:g sandbox=true") *
                                declared("m1"; opts = "throttle=:g profile=:bounds"),
            "test/qa/Project.toml" => "[deps]\n",
            "test/qa/q_test.jl" => declared("q1"; opts = "throttle=:g"),
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n")
        testdir = joinpath(dir, "test")
        walked = Runtests.Private.walk_test_dir(testdir)
        raw = scan(walked.tests, Filter(), setup_modules(testdir); environments = walked.environments)
        p = plan(raw, read_config(testdir; nunits = length(raw)); root = dir)
        item(n) = findfirst(==(n), p.items.name)
        @test p.items.exclusive[item("s1")]
        @test allequal(p.items.gate[item(n)] for n in ("s1", "m1", "q1")) && p.gate_limit == [1]
        @test length(unique(p.items.profile[item(n)] for n in ("s1", "m1", "q1"))) == 3
    end

    @testset "a gate's items start early and together, and bound how soon their pool can finish" begin
        # Eight items of ten seconds that one at a time take eighty: longer than the
        # pool's share among four workers, so they go first, in file order.
        dir = make_pkg("GateFirst",
            "test/a_test.jl" => declared(("a$i" for i in 1:8)...),
            "test/g_test.jl" => declared(("g$i" for i in 1:8)...; opts = "throttle=:g"),
            "test/TestItems.toml" => "[throttle]\ng = 1\n")
        h = History(Dict(n => 10.0 for n in [["a$i" for i in 1:8]; ["g$i" for i in 1:8]]), Dict{String, Int}())
        # At 1 the throttle is eighty seconds of gated work, long by itself.
        p = plan_dir(dir; history = h, workers = 4)
        @test p.items.why[findfirst(==("g1"), p.items.name)] === Runtests.Private.LONG
        write(joinpath(dir, "test", "TestItems.toml"), "[throttle]\ng = 2\n")
        p = plan_dir(dir; history = h, workers = 4)
        gated = [findfirst(==("g$i"), p.items.name) for i in 1:8]
        @test all(i -> p.items.why[i] === Runtests.Private.LONG, gated)
        @test gated == collect(first(p.pools[1].head):(first(p.pools[1].head) + 7))
        @test occursin("throttle `g` est 40.0s, 2 at a time", Runtests.Private.why_text(p, gated[1]))
        # Unthrottled, each is a ten-second item and none is long.
        write(joinpath(dir, "test", "TestItems.toml"), "[throttle]\ng = 8\n")
        p = plan_dir(dir; history = h, workers = 4)
        @test all(i -> p.items.why[findfirst(==("g$i"), p.items.name)] === Runtests.Private.IN_FILE_ORDER, 1:8)
    end

    @testset "however the slots take turns, a gate never runs more than its limit, and every item runs once" begin
        # A gate of two in two pools, beside a gate of one and plain items, with slots
        # fewer than the pools to more than one per pool. A slot runs one item at a time and
        # claims again only once it ended, as `run_slot` does.
        dir = make_pkg("GateTurns",
            "test/a_test.jl" => declared("a1", "a2", "a3") * declared(("g$i" for i in 1:5)...; opts = "throttle=:g"),
            "test/b_test.jl" => declared("c1", "c2"; opts = "throttle=:c") * declared("b1", "b2"),
            "test/p_test.jl" => declared("p1", "p2") * declared("h1", "h2", "h3"; opts = "throttle=:g profile=:bounds"),
            "test/TestItems.toml" => "[throttle]\ng = 2\n[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n")
        P = Runtests.Private
        for workers in (1, 2, 3, 6)
            p = plan_dir(dir; workers)
            wrong = String[]
            for seed in 1:200
                rng = Xoshiro(seed)
                q = P.Queues(p)
                current = zeros(Int32, nslots(p))   # the item each slot runs, 0 for none
                handed = zeros(Int, nitems(p))
                live = collect(1:nslots(p))
                steps = 0
                while !isempty(live) && (steps += 1) < 100_000
                    s = rand(rng, live)
                    if current[s] != 0
                        P.item_ended!(q, current[s])
                        current[s] = 0
                        continue
                    end
                    c = @lock q.lock P.claim_now!(q, s)
                    if c.kind === :done
                        filter!(!=(s), live)
                    elseif c.kind === :wait
                        # Only while an item of a gate runs: its end lets the slot go on.
                        any(i -> i != 0 && p.items.gate[i] != 0, current) ||
                            push!(wrong, "seed $seed: slot $s waits, and no gate runs anything")
                    elseif c.kind === :item
                        current[s] = c.item
                        handed[c.item] += 1
                        g = p.items.gate[c.item]
                        running = count(i -> i != 0 && p.items.gate[i] == g, current)
                        g == 0 || running <= p.gate_limit[g] ||
                            push!(wrong, "seed $seed: $running items of gate $g run at once")
                    end
                end
                steps < 100_000 || push!(wrong, "seed $seed: the slots stopped making progress")
                all(==(1), handed) || push!(wrong, "seed $seed: items handed out $(handed)")
            end
            @test isempty(wrong)
        end
    end

    @testset "a slot whose pool holds only items their gate holds back waits, and takes nothing as it wakes" begin
        dir = make_pkg("GateWait", "test/a_test.jl" => declared("g1", "g2", "g3", "g4"; opts = "throttle=:g"),
                       "test/TestItems.toml" => "[throttle]\ng = 2\n")
        # A third worker would only wait: the gate's work over its limit bounds the run.
        p = plan_dir(dir; workers = 3)
        @test nslots(p) == 2
        P = Runtests.Private
        q = P.Queues(p)
        first_ = P.claim!(q, 1); second = P.claim!(q, 2)
        @test first_.kind === :item && second.kind === :item
        @test (@lock q.lock P.claim_now!(q, 1)).kind === :wait
        waiting(s) = (t = Threads.@spawn P.claim!(q, s); sleep(0.2); @test !istaskdone(t); t)
        # An item of the gate that ends wakes it, and it goes back to its loop, which
        # looks at the memory guard before it claims: the place stays free meanwhile.
        t = waiting(1)
        P.set_paused!(q, true)
        P.item_ended!(q, first_.item)
        @test fetch(t).kind === :wait && q.gate_running == [1]
        P.set_paused!(q, false)
        third = P.claim!(q, 1)
        @test third.kind === :item && allunique([first_.item, second.item, third.item]) && q.gate_running == [2]
        # The memory guard asking for its worker wakes it as well.
        t = waiting(1)
        P.wake_waiting!(q)
        @test fetch(t).kind === :wait && q.gate_running == [2]
        # So does a stopped run, after which there is nothing to do.
        t = waiting(2)
        P.cancel!(q)
        @test fetch(t).kind === :wait
        @test P.claim!(q, 2).kind === :done
    end

    @testset "a slot that would wait for a gate starts a pool that has work, and the pool it left is taken up" begin
        # A, B and C are profiles of their own that share a gate of two; D has no
        # throttle. Three workers: A, B and C get one each, and D none at first.
        dir = make_pkg("GateMoves",
            "test/a_test.jl" => declared("a1"; opts = "throttle=:g profile=:a"),
            "test/b_test.jl" => declared("b1"; opts = "throttle=:g profile=:b"),
            "test/c_test.jl" => declared("c1", "c2", "c3"; opts = "throttle=:g profile=:c"),
            "test/d_test.jl" => declared("d1"; opts = "profile=:d"),
            "test/TestItems.toml" => "[throttle]\ng = 2\n" * join(("[profiles.$x]\njulia_args = [\"--threads=$k\"]\n"
                                                                    for (k, x) in enumerate("abcd"))))
        h = History(Dict("a1" => 120.0, "b1" => 110.0, "c1" => 30.0, "c2" => 30.0, "c3" => 30.0, "d1" => 80.0),
                    Dict{String, Int}())
        p = plan_dir(dir; history = h, workers = 3)
        @test [p.profiles[p.pools[k].profile].name for k in p.pending] == [:d]
        order = Runtests.Private.run_order(p)
        start(n) = only(t for (t, _, i) in order.items if p.items.name[i] == n)
        # C's worker finds its gate full and starts D rather than wait; C's units start
        # as A's and B's end: the run takes 170 seconds where waiting took 190.
        @test start("d1") == 0.0
        @test sort([start("c1"), start("c2"), start("c3")]) == [110.0, 120.0, 140.0]
        @test maximum(t + p.items.est_s[i] for (t, _, i) in order.items) == 170.0
        # Each worker's work is what its items take, without what it waited.
        for w in 1:nslots(p)
            @test order.work[w] ≈ sum((p.items.est_s[i] for (_, s, i) in order.items if s == w); init = 0.0)
        end
    end

    @testset "a worker does not move to a pool whose gates its workers already fill" begin
        # Seven units of a gate of two, which two workers fill, and one other unit.
        dir = make_pkg("GateFull",
            "test/t_test.jl" => declared(("t$i" for i in 1:7)...; opts = "throttle=:g profile=:t"),
            "test/s_test.jl" => declared("s1"),
            "test/TestItems.toml" => "[throttle]\ng = 2\n[profiles.t]\njulia_args = [\"--threads=1\"]\n")
        h = History(Dict(vcat(["t$i" => 4.0 for i in 1:7], ["s1" => 1.0])), Dict{String, Int}())
        p = plan_dir(dir; history = h, workers = 3)
        P = Runtests.Private
        q = P.Queues(p)
        pool_of(name) = (i = findfirst(==(name), p.items.name);
                         findfirst(k -> i in first(p.pools[k].head):last(p.pools[k].tail), eachindex(p.pools)))
        t_slots = [s for s in 1:nslots(p) if p.slot_pool[s] == pool_of("t1")]
        s_slot = only(s for s in 1:nslots(p) if p.slot_pool[s] == pool_of("s1"))
        @test length(t_slots) == 2
        @test all(s -> P.claim!(q, s).kind === :item, t_slots)
        @test P.claim!(q, s_slot).kind === :item
        # Its own pool done, it would only wait for the gate there.
        @test P.claim!(q, s_slot).kind === :done
    end

    @testset "a gate's long items go longest first" begin
        dir = make_pkg("GateLongest", "test/a_test.jl" => declared("g1", "g2", "g3", "g4"; opts = "throttle=:g"),
                       "test/TestItems.toml" => "[throttle]\ng = 2\n")
        h = History(Dict("g1" => 10.0, "g2" => 10.0, "g3" => 10.0, "g4" => 30.0), Dict{String, Int}())
        p = plan_dir(dir; history = h, workers = 2)
        @test [p.items.name[i] for i in p.pools[1].head] == ["g4", "g1", "g2", "g3"]
        order = Runtests.Private.run_order(p)
        @test maximum(t + p.items.est_s[i] for (t, _, i) in order.items) == 30.0
    end

    @testset "a warmup throttle runs one item to completion alone, then opens to its limit" begin
        P = Runtests.Private
        dir = make_pkg("GateWarmup",
            "test/a_test.jl" => declared("g1", "g2", "g3", "g4"; opts = "throttle=:g") *
                                declared("p1", "p2"),
            "test/TestItems.toml" => "[throttle]\ng = { limit = 2, warmup = true }\n")
        h = History(Dict("g1" => 10.0, "g2" => 10.0, "g3" => 10.0, "g4" => 10.0, "p1" => 10.0, "p2" => 10.0),
                    Dict{String, Int}())
        p = plan_dir(dir; history = h, workers = 3)
        @test p.gate_limit == [2] && p.gate_warmup == [true] && nslots(p) == 3
        g1 = findfirst(==("g1"), p.items.name)
        # Floor is 10 + (40 - 10) / 2 = 25.0s.
        @test occursin("throttle `g` est 25.0s, 2 at a time (warmup)", P.why_text(p, g1))
        @test occursin("throttle `g`, 2 at a time (warmup)", P.details_text(p, g1))
        # Dry-run schedule: at t=0 only 1 gated item starts while workers 2 & 3 take plain items;
        # after g1 ends at t=10, two gated items start concurrently at t=10, and the 4th at t=20.
        order = P.run_order(p)
        start(n) = only(t for (t, _, i) in order.items if p.items.name[i] == n)
        @test start("g1") == 0.0
        @test start("p1") == 0.0 && start("p2") == 0.0
        @test sort([start("g2"), start("g3"), start("g4")]) == [10.0, 10.0, 20.0]

        # A skipped first item does not satisfy warmup: the next gated item still runs alone.
        q = P.Queues(p)
        c1 = @lock q.lock P.claim_now!(q, 1)
        @test c1.kind === :item && p.items.gate[c1.item] == 1 && q.gate_warming == [true]
        # Second slot cannot start another gated item while warming, so it takes a plain item.
        c2 = @lock q.lock P.claim_now!(q, 2)
        @test c2.kind === :item && p.items.gate[c2.item] == 0
        # c1 ends as skipped (`warmed = false`): gate stays warming!
        P.item_ended!(q, c1.item; warmed = false)
        @test q.gate_warming == [true] && q.gate_running == [0]
        c3 = @lock q.lock P.claim_now!(q, 1)
        @test c3.kind === :item && p.items.gate[c3.item] == 1 && q.gate_running == [1]
        # Still capped at 1 while c3 runs.
        c4 = @lock q.lock P.claim_now!(q, 3)
        @test c4.kind === :item && p.items.gate[c4.item] == 0
        # c3 ends normally (`warmed = true`): gate opens to limit 2.
        P.item_ended!(q, c3.item; warmed = true)
        @test q.gate_warming == [false]
        c5 = @lock q.lock P.claim_now!(q, 1)
        c6 = @lock q.lock P.claim_now!(q, 2)
        @test c5.kind === :item && c6.kind === :item
        @test p.items.gate[c5.item] == 1 && p.items.gate[c6.item] == 1 && q.gate_running == [2]

        # Randomized turn-order invariant check: at most 1 before the first gated item ends,
        # at most `limit` thereafter, and every item handed out once without deadlock.
        for workers in (1, 2, 3, 5)
            pw = plan_dir(dir; history = h, workers)
            wrong = String[]
            for seed in 1:100
                rng = Xoshiro(seed)
                qw = P.Queues(pw)
                current = zeros(Int32, nslots(pw))
                handed = zeros(Int, nitems(pw))
                live = collect(1:nslots(pw))
                warmed_done = false
                steps = 0
                while !isempty(live) && (steps += 1) < 100_000
                    s = rand(rng, live)
                    if current[s] != 0
                        pw.items.gate[current[s]] == 1 && (warmed_done = true)
                        P.item_ended!(qw, current[s])
                        current[s] = 0
                        continue
                    end
                    c = @lock qw.lock P.claim_now!(qw, s)
                    if c.kind === :done
                        filter!(!=(s), live)
                    elseif c.kind === :wait
                        any(i -> i != 0 && pw.items.gate[i] != 0, current) ||
                            push!(wrong, "seed $seed: slot $s waits with nothing running in a gate")
                    elseif c.kind === :item
                        current[s] = c.item
                        handed[c.item] += 1
                        if pw.items.gate[c.item] == 1
                            running = count(i -> i != 0 && pw.items.gate[i] == 1, current)
                            cap = warmed_done ? 2 : 1
                            running <= cap || push!(wrong, "seed $seed: $running gated items ran at once (cap $cap)")
                        end
                    end
                end
                steps < 100_000 || push!(wrong, "seed $seed: stalled")
                all(==(1), handed) || push!(wrong, "seed $seed: handed $(handed)")
            end
            @test isempty(wrong)
        end

        # `limit = 1, warmup = true` stays serialized cleanly.
        write(joinpath(dir, "test", "TestItems.toml"), "[throttle]\ng = { limit = 1, warmup = true }\n")
        p1 = plan_dir(dir; history = h, workers = 3)
        @test p1.gate_limit == [1] && p1.gate_warmup == [true]
        order1 = P.run_order(p1)
        gstarts = sort([t for (t, _, i) in order1.items if p1.items.gate[i] == 1])
        @test gstarts == [0.0, 10.0, 20.0, 30.0]
    end

    @testset "pools start in order of estimated completion, an item no run timed at the typical duration" begin
        # `slow` has three items of five seconds; `many` has ten that no run has timed,
        # which count as the typical duration, five seconds, rather than one.
        dir = make_pkg("Completion",
            "test/s_test.jl" => declared("s1", "s2", "s3"; opts = "profile=:slow"),
            "test/m_test.jl" => declared(("m$i" for i in 1:10)...; opts = "profile=:many"),
            "test/q_test.jl" => declared("q1"; opts = "profile=:quick"),
            "test/TestItems.toml" => "[profiles.slow]\njulia_args = [\"--threads=1\"]\n[profiles.many]\njulia_args = [\"--threads=2\"]\n" *
                                     "[profiles.quick]\njulia_args = [\"--threads=3\"]\n")
        h = History(Dict("s1" => 5.0, "s2" => 5.0, "s3" => 5.0, "q1" => 1.0), Dict{String, Int}())
        names_of(p) = [p.profiles[pool.profile].name for pool in p.pools]
        p = plan_dir(dir; history = h, workers = 1)
        @test names_of(p) == [:many, :slow, :quick]
        # One worker: the latest pool gets it, and the others wait in the same order.
        @test p.slot_pool == [1]
        @test p.pending == [2, 3]
        # Every pool gets a worker first; the rest go where they shorten the latest
        # completion: `many` has fifty seconds of work and `slow` fifteen.
        p = plan_dir(dir; history = h, workers = 5)
        @test [count(==(k), p.slot_pool) for k in 1:3] == [3, 1, 1]
        @test isempty(p.pending)
        # A worker that cannot shorten a pool's completion is not planned: one long
        # item outlasts the others shared among any number of workers.
        long = make_pkg("CompletionLong", "test/a_test.jl" => declared("long", "a1", "a2", "a3"))
        p = plan_dir(long; history = History(Dict("long" => 30.0, "a1" => 1.0, "a2" => 1.0, "a3" => 1.0), Dict{String, Int}()),
                     workers = 4)
        @test p.slot_pool == [1, 1]
    end

    @testset "an item no run timed counts as the typical item" begin
        # Pool `a` has one item timed at ten seconds and one that no run timed, which
        # counts as the typical item, ten seconds. `b` has one item of fifteen. By its
        # timed item alone, `a` would finish first.
        dir = make_pkg("Untimed",
            "test/a_test.jl" => declared("c1", "c2"; opts = "profile=:a"),
            "test/b_test.jl" => declared("b1"; opts = "profile=:b"),
            "test/TestItems.toml" => "[profiles.a]\njulia_args = [\"--threads=1\"]\n[profiles.b]\njulia_args = [\"--threads=2\"]\n")
        p = plan_dir(dir; history = History(Dict("c1" => 10.0, "b1" => 15.0), Dict{String, Int}()), workers = 1)
        @test [p.profiles[pool.profile].name for pool in p.pools] == [:a, :b]
        # The run counts the items as the plan does, until the pool has timed items.
        q = Runtests.Private.Queues(p)
        @test Runtests.Private.unclaimed_work(q, 1) == [10.0, 10.0]
        # Then it scales a recorded duration by how the pool's items took against
        # theirs, and counts an item without one as the pool's average item.
        q.stats[1].estimated_s, q.stats[1].estimated_took_s = 10.0, 5.0
        q.stats[1].items, q.stats[1].took_s = 2, 8.0
        @test Runtests.Private.unclaimed_work(q, 1) == [5.0, 4.0]
    end

    @testset "a slot whose pool runs dry moves only where one more worker makes a pool finish sooner" begin
        # `long` has one unit of thirty seconds and one slot: a second worker cannot
        # finish it sooner. `many` has twenty units of a second and two slots, ten
        # seconds each. `dry`'s slot goes to `many`, although `long` has more work
        # for each slot.
        dir = make_pkg("Replacement",
            "test/d_test.jl" => declared("d1"; opts = "profile=:dry"),
            "test/l_test.jl" => declared("l1"; opts = "profile=:long"),
            "test/m_test.jl" => declared(("m$i" for i in 1:20)...; opts = "profile=:many"),
            "test/TestItems.toml" => "[profiles.dry]\njulia_args = [\"--threads=1\"]\n[profiles.long]\njulia_args = [\"--threads=2\"]\n" *
                                     "[profiles.many]\njulia_args = [\"--threads=3\"]\n")
        seconds = Dict("d1" => 1.0, "l1" => 30.0, ("m$i" => 1.0 for i in 1:20)...)
        p = plan_dir(dir; history = History(seconds, Dict{String, Int}()), workers = 4)
        pool_named(name) = findfirst(k -> p.profiles[k.profile].name === name, p.pools)
        @test [count(==(pool_named(n)), p.slot_pool) for n in (:dry, :long, :many)] == [1, 1, 2]
        s = findfirst(==(pool_named(:dry)), p.slot_pool)
        claim!, Q = Runtests.Private.claim!, Runtests.Private.Queues
        q = Q(p)
        @test claim!(q, s).kind === :item
        c = claim!(q, s)
        @test c.kind === :rebind && c.pool == pool_named(:many)
        # With `many` all handed out, no move makes a pool finish sooner: the slot is
        # done.
        q = Q(p)
        claim!(q, s)
        many = p.pools[pool_named(:many)]
        q.claimed[first(many.head):last(many.tail)] .= true
        @test claim!(q, s).kind === :done
    end

    @testset "a slot whose pool runs dry does not start a worker that would be ready after the work is claimed" begin
        # `target` has five units of four seconds and two slots, which claim them at 0,
        # 0, 4, 4 and 8 seconds and are done at 12. A third worker ready at 9 finds
        # nothing left to claim; one ready at 3 takes the third unit and they are done at 8.
        dir = make_pkg("LateWorker",
            "test/d_test.jl" => declared("d1"; opts = "profile=:dry"),
            "test/t_test.jl" => declared(("t$i" for i in 1:5)...; opts = "profile=:target"),
            "test/TestItems.toml" => "[profiles.dry]\njulia_args = [\"--threads=1\"]\n[profiles.target]\njulia_args = [\"--threads=2\"]\n")
        seconds = Dict("d1" => 1.0, ("t$i" => 4.0 for i in 1:5)...)
        p = plan_dir(dir; history = History(seconds, Dict{String, Int}()), workers = 3)
        target = findfirst(k -> p.profiles[k.profile].name === :target, p.pools)
        @test count(==(target), p.slot_pool) == 2
        s = findfirst(k -> p.profiles[p.pools[k].profile].name === :dry, p.slot_pool)
        finish_time = Runtests.Private.finish_time
        @test finish_time(fill(4.0, 5), [0.0, 0.0]) == 12.0
        @test finish_time(fill(4.0, 5), [0.0, 0.0, 9.0]) == 12.0
        @test finish_time(fill(4.0, 5), [0.0, 0.0, 3.0]) == 8.0
        for (start_s, kind) in ((9.0, :done), (3.0, :rebind))
            q = Runtests.Private.Queues(p)
            Runtests.Private.claim!(q, s)
            q.stats[target].starts, q.stats[target].start_s = 1, start_s
            @test Runtests.Private.claim!(q, s).kind === kind
        end
    end

    @testset "a slot whose pool runs dry moves to where it takes the most work off the others" begin
        # Twelve default units of a second, and single units under two profiles of
        # their own; `big` has eight.
        dir = make_pkg(
            "Refill",
            "test/a_test.jl" => declared(("a$i" for i in 1:12)...),
            "test/p_test.jl" => declared("p1"; opts = "profile=:tiny"),
            "test/b_test.jl" => declared(("b$i" for i in 1:8)...; opts = "profile=:big"),
            "test/TestItems.toml" => "[profiles.tiny]\njulia_args = [\"--threads=1\"]\n[profiles.big]\njulia_args = [\"--threads=2\"]\n",
        )
        second = Dict(n => 1.0 for n in [["a$i" for i in 1:12]; ["b$i" for i in 1:8]; "p1"])
        known = History(second, Dict{String, Int}())
        Q, claim!, cold_cost, ColdCost = Runtests.Private.Queues, Runtests.Private.claim!, Runtests.Private.cold_cost,
            Runtests.Private.ColdCost
        profile_of(p, c) = p.profiles[p.items.profile[c.item]].name
        pool_named(p, name) = findfirst(k -> p.profiles[k.profile].name === name, p.pools)
        tiny_slot(p) = findfirst(==(pool_named(p, :tiny)), p.slot_pool)

        # Without `big`: default has two slots, `tiny` one.
        solo = make_pkg("RefillTwo", "test/a_test.jl" => declared(("a$i" for i in 1:12)...),
                        "test/p_test.jl" => declared("p1"; opts = "profile=:tiny"),
                        "test/TestItems.toml" => "[profiles.tiny]\njulia_args = [\"--threads=1\"]\n")
        p = plan_dir(solo; workers = 3, history = known)
        s = tiny_slot(p)
        default = pool_named(p, :default)
        @test count(==(default), p.slot_pool) == 2
        q = Q(p)
        @test profile_of(p, claim!(q, s)) === :tiny
        c = claim!(q, s)
        @test c.kind === :rebind && c.pool == default
        # From there it takes default items, as one of the pool's own slots would.
        c = claim!(q, s)
        @test c.kind === :item && profile_of(p, c) === :default
        @test q.serving[default] == 3

        # A fresh default worker that takes longer to be ready than the six seconds
        # each default slot has left is not started: the slot is done.
        q = Q(p)
        claim!(q, s)
        q.stats[default].starts, q.stats[default].start_s = 1, 20.0
        @test claim!(q, s).kind === :done
        @test q.serving[pool_named(p, :tiny)] == 0

        # An item without a recorded duration counts as the pool's own average so
        # far: twelve of a hundredth of a second each leave a default slot nothing a
        # worker that takes half a second to start would save it.
        p0 = plan_dir(solo; workers = 3)
        q = Q(p0)
        claim!(q, s)
        q.stats[default].starts, q.stats[default].start_s = 1, 0.5
        q.stats[default].items, q.stats[default].took_s = 4, 0.04
        @test claim!(q, s).kind === :done
        q = Q(p0)                      # before any has run, an item counts as a second
        claim!(q, s)
        q.stats[default].starts, q.stats[default].start_s = 1, 0.5
        @test claim!(q, s).kind === :rebind
        # A recorded duration is scaled by how the run's items took against theirs.
        q = Q(p)
        claim!(q, s)
        q.stats[default].starts, q.stats[default].start_s = 1, 1.0
        q.stats[default].estimated_s, q.stats[default].estimated_took_s = 4.0, 0.4
        @test claim!(q, s).kind === :done

        # A pool no slot serves is taken however much a fresh worker costs: nothing
        # else will run it.
        p1 = plan_dir(solo; workers = 1, history = known)
        @test p1.pending == [pool_named(p1, :tiny)]
        q = Q(p1)
        q.stats[pool_named(p1, :tiny)].starts, q.stats[pool_named(p1, :tiny)].start_s = 1, 1000.0
        kinds = Symbol[]
        while (c = claim!(q, 1)).kind !== :done
            c.kind === :rebind && push!(kinds, c.kind)
        end
        @test kinds == [:rebind]

        # With `big` as well, four slots: two default, one each for `big` and `tiny`.
        # Default has six seconds left per slot and `big` eight, so `tiny`'s slot goes
        # to `big`.
        p = plan_dir(dir; workers = 4, history = known)
        @test count(==(pool_named(p, :default)), p.slot_pool) == 2
        q = Q(p)
        s = tiny_slot(p)
        claim!(q, s)
        c = claim!(q, s)
        @test c.kind === :rebind && c.pool == pool_named(p, :big)

        # What a fresh worker costs: measured in its pool once the run has seen it
        # there, across the run's pools before that, and from earlier runs before either.
        p = plan_dir(solo; workers = 3, history = History(second, Dict{String, Int}(); cold = ColdCost(2.0, 0.5)))
        q = Q(p)
        tiny = pool_named(p, :tiny)
        @test cold_cost(q, default) == 2.5
        q.stats[tiny].starts, q.stats[tiny].start_s = 2, 1.0
        @test cold_cost(q, default) == 0.5 + 0.5
        q.stats[tiny].cold, q.stats[tiny].cold_compile_s = 2, 10.0
        q.stats[tiny].warm, q.stats[tiny].warm_compile_s = 2, 0.0
        @test cold_cost(q, default) == 0.5 + 5.0
        q.stats[default].starts, q.stats[default].start_s = 1, 0.3
        q.stats[default].cold, q.stats[default].cold_compile_s = 2, 1.0
        q.stats[default].warm, q.stats[default].warm_compile_s = 4, 0.4
        @test cold_cost(q, default) ≈ 0.3 + (0.5 - 0.1)
        # A first item that compiled less than the later ones is no extra cost.
        q.stats[default].cold_compile_s = 0.0
        @test cold_cost(q, default) ≈ 0.3

        # The dry run predicts the same: `tiny`'s slot goes on with default units, and
        # does not when earlier runs say a fresh worker costs more than it would save.
        p = plan_dir(solo; workers = 3, history = known)
        on_tiny(p) = [p.items.name[i] for (_, w, i) in Runtests.Private.run_order(p).items if w == tiny_slot(p)]
        @test first(on_tiny(p)) == "p1"
        @test length(on_tiny(p)) > 1 && all(startswith("a"), on_tiny(p)[2:end])
        costly = plan_dir(solo; workers = 3, history = History(second, Dict{String, Int}(); cold = ColdCost(20.0, 0.0)))
        @test on_tiny(costly) == ["p1"]
        # A slot that moves is charged the fresh worker before its first unit there:
        # `p1`'s second, then a second and a half.
        p = plan_dir(solo; workers = 3, history = History(second, Dict{String, Int}(); cold = ColdCost(1.0, 0.5)))
        starts = [t for (t, w, i) in Runtests.Private.run_order(p).items if w == tiny_slot(p)]
        @test starts[1:2] ≈ [0.0, 2.5]
    end

    @testset "planning is deterministic" begin
        a = make_plan()
        for _ in 1:3
            b = make_plan()
            @test dispatch_order(a) == dispatch_order(b)
            @test [slot_names(a, s) for s in 1:nslots(a)] == [slot_names(b, s) for s in 1:nslots(b)]
        end
    end

    @testset "in-process runs use a single slot" begin
        p = make_plan(; workers=0)
        @test nslots(p) == 1
        @test sort(planned(p)) == sort(dispatch_order(p))
    end

    @testset "the plan prints as one block and one table" begin
        out = sprint(print_plan, make_plan())
        @test occursin("dry run · ", out)
        @test occursin("6 test items in 2 files", out)
        @test occursin("setups: `BasicSetup`", out)
        rows = filter(l -> occursin("_test.jl:", l), split(out, '\n'))
        @test length(rows) == 6
        row(name) = only(filter(l -> occursin(repr(name), l), rows))
        @test occursin("[order] first", row("slow thing"))
        @test occursin("throttle `seq`, 1 at a time", row("chain one"))
        @test occursin("throttle `seq`, 1 at a time", row("chain two"))
        @test occursin("setup `BasicSetup`", row("uses setup"))
        # Units are the scheduler's, and the output has no use for the word.
        @test !occursin(r"\bunits?\b", out)
    end

    @testset "the table's columns line up, each as wide as its widest entry" begin
        out = sprint(print_plan, make_plan())
        lines = split(out, '\n')
        header = only(filter(l -> occursin("test item", l) && occursin("tags", l), lines))
        rows = filter(l -> occursin("_test.jl:", l), lines)
        # Positions in characters, not bytes: the separator is not ASCII.
        column(l, text) = length(l[1:prevind(l, findfirst(text, l).start)]) + 1
        # The tags start in one column, just after the longest location and the
        # separator.
        tags_at = column(header, "tags")
        longest = maximum(l -> length(match(r"test[/\\]\S+:\d+", l).match), rows)   # `\` on Windows
        @test tags_at == column(header, "at ") + longest + length(Runtests.Private.FIELD)
        # Every row's separators fall where the header's do, up to where the row ends.
        dots = findall(==('·'), collect(header))
        @test all(l -> all(d -> d > length(l) || collect(l)[d] == '·', dots), rows)
        tagged = filter(l -> occursin("fast", l), rows)
        @test length(tagged) == 2
        @test all(l -> column(l, "fast") == tags_at, tagged)
        # A row ends at its last character.
        @test all(l -> l == rstrip(l), lines)
    end

    @testset "the worker column is right-aligned under its title" begin
        lines = split(sprint(print_plan, make_plan(; workers=2)), '\n')
        column(l, text) = length(l[1:prevind(l, findfirst(text, l).start)]) + 1
        header = only(filter(l -> occursin("· worker ·", l), lines))
        ends = column(header, "worker") + length("worker")
        rows = filter(l -> occursin("_test.jl:", l), lines)
        @test all(rows) do l
            m = match(r"(w\d+) ·", l)
            column(l, m.match) + length(m.captures[1]) == ends
        end
    end

    @testset "a name too long for its column is shortened to a prefix only it has" begin
        names = ["short one", "short two",
                 "a long name about parsing dates carefully", "a long name about parsing times carefully",
                 "zebra crossings are long and winding roads", "long name (with parens) and more words"]
        cells = Runtests.Private.shown_names(names, 20)
        shown = Dict(zip(names, cells))
        # One that fits is as it is, after the column the shortened ones have an `r` in.
        @test shown["short one"] == " \"short one\""
        # Shortened as far as fits, which is further than it needs to be unique.
        @test shown["zebra crossings are long and winding roads"] == "r\"^zebra crossings a\""
        @test textwidth(shown["zebra crossings are long and winding roads"]) == 1 + 20
        # What makes it the only one does not fit: the column is overrun, not the name cut.
        @test shown["a long name about parsing dates carefully"] == "r\"^a long name about parsing d\""
        # A regex character is quoted, so the prefix is matched as written.
        @test shown["long name (with parens) and more words"] == "r\"^\\Qlong name (with\""
        # Every shortened name, passed to `name=`, picks out its item and no other.
        for (n, c) in zip(names, cells)
            startswith(c, 'r') || continue
            rx = eval(Meta.parse(c))
            @test occursin(rx, n) && count(m -> occursin(rx, m), names) == 1
        end
        # All the names fit: nothing changes, and there is no column for an `r`.
        @test Runtests.Private.shown_names(["short one", "short two"], 20) == ["\"short one\"", "\"short two\""]
        # No prefix is a name's own when another name begins with all of it: it stays
        # whole, and the other is picked out by the character after it.
        @test Runtests.Private.shown_names(["a name that is long", "a name that is long, and longer"], 12) ==
            [" \"a name that is long\"", "r\"^a name that is long,\""]
    end

    @testset "a shortened name is told apart from every name in the suite" begin
        shown = "a long name about parsing dates carefully"
        other = "a long name about parsing dates carelessly"
        # Among the names shown, a short prefix would do; the suite has another name
        # that shares most of it, so the prefix runs to where the two part.
        @test Runtests.Private.shown_names([shown, "short"], 20) == ["r\"^a long name about\"", " \"short\""]
        @test Runtests.Private.shown_names([shown, "short"], 20; among = [shown, "short", other]) ==
            ["r\"^a long name about parsing dates caref\"", " \"short\""]
        # A dry run of part of the suite: the item left out still has a name.
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n")
                      for n in ["one", "two", "three", shown, other]), "\n")
        dir = make_pkg("Apart", "test/a_test.jl" => items)
        p, _ = Runtests.Private.prepare((dir,); name=Set(["one", "two", "three", shown]), workers=1,
                            logs=:issues, announce=false)
        row = only(filter(l -> occursin("r\"^", l), split(sprint(print_plan, p), '\n')))
        rx = eval(Meta.parse(match(r"r\"\^.*?[^\\]\"", row).match))
        @test occursin(rx, shown) && !occursin(rx, other)
    end

    @testset "a shortened name's regex matches its own prefix, whatever characters the name has" begin
        regex_prefix = Runtests.Private.regex_prefix
        special = Runtests.Private.REGEX_SPECIAL
        # Every character a regex or a raw string reads as other than itself: alone,
        # doubled, first, between, last and three together.
        names = String[]
        for c in string(special, '"'), form in ("$c", "$c$c", "a$(c)b", "ab$c", "$(c)ab", "a$c$c$c")
            push!(names, form)
        end
        append!(names, [
            # What ends quoting, what starts it, and both together.
            "\\E", "\\Q", "\\E\\E", "\\Q\\E", "a\\Eb\\Qc", "\\\\E", "\\\\\\E", "E\\", "Q\\",
            # Backslashes before the closing quote, however many.
            "\\", "\\\\", "\\\\\\", "\\\\\\\\", "a\\", "a\\\\", "a\\\\\\",
            # Backslashes before a quote in the name, and quotes around them.
            "\\\"", "\\\\\"", "\"\\", "\"\\\"", "\"\"\\\\\"\"", "a\\\"b\\\\\"c",
            # What a string would interpolate, and escapes written as text.
            "\$(x)", "\$x \$\$", "#{x}", "\\d\\w\\s\\1\\x41\\u0041\\n\\t",
            # Spaces, and what prints beyond ASCII.
            "a b  c", " leading", "trailing ", "∑ α → 🙂 漢字", "é combining", "(∑|α)+", "∑.∑",
        ])
        for n in names, k in 1:length(n)
            s = regex_prefix(n, k)
            @test s !== nothing
            s === nothing && continue
            rx = eval(Meta.parse(s))
            m = match(rx, n)
            @test m !== nothing && m.offset == 1 && m.match == first(n, k)
            # Anchored: the same text anywhere else does not match.
            @test !occursin(rx, "\0" * n)
            # Quoted only when a character needs it.
            @test startswith(s, "r\"^\\Q") == any(in(special), first(n, k))
        end
    end

    @testset "random names of those characters: every prefix matches as it is written" begin
        regex_prefix = Runtests.Private.regex_prefix
        # Seeded, so a name that breaks it breaks every run.
        rng = Xoshiro(20260929)
        alphabet = collect(string(Runtests.Private.REGEX_SPECIAL, "\"EQab ∑"))
        for _ in 1:300
            n = String(rand(rng, alphabet, rand(rng, 1:12)))
            for k in 1:length(n)
                m = match(eval(Meta.parse(regex_prefix(n, k))), n)
                @test m !== nothing && m.offset == 1 && m.match == first(n, k)
            end
        end
    end

    @testset "escaping costs a shortened name characters of its prefix, never the column" begin
        regex_prefix = Runtests.Private.regex_prefix
        # `\E` is written as five more characters, a backslash before the closing
        # quote as one more, `\Q` as two: a longer prefix is never narrower, which is
        # what lets the prefix grow until the next character would not fit.
        for n in ["a\\E\\E\\Eb", "x\\", "x\\\\\"y", "\\E\\\\E\\Q\\E", "plain then \\E then (x)", "q\\\"b\\", "(a)\\E\\"]
            ws = [textwidth(regex_prefix(n, k)) for k in 1:length(n)]
            @test issorted(ws)
        end
        # Over a column only when the shortest prefix that tells it apart is.
        names = ["runs \\E on and on for a long while", "runs \\E on and on for ever and ever",
                 "\\E\\E\\E at the start of a long name", "a name with \\E\\Q\\E and more after",
                 "a name with \\E\\Q\\E and other words", "short", "tiny"]
        common(a, b) = (k = 0; for (x, y) in zip(a, b); x == y || break; k += 1; end; k)
        need(n) = 1 + maximum(m -> m == n ? 0 : common(n, m), names)
        for width in 8:40, (n, cell) in zip(names, Runtests.Private.shown_names(names, width))
            startswith(cell, 'r') || continue
            if textwidth(cell) - 1 > width
                @test cell == regex_prefix(n, need(n)) && textwidth(cell) - 1 > width
            end
            @test occursin(eval(Meta.parse(cell)), n) && count(m -> occursin(eval(Meta.parse(cell)), m), names) == 1
        end
    end

    @testset "a prefix that its escaped `\\E` makes too wide overruns the column rather than stop matching one item" begin
        regex_prefix = Runtests.Private.regex_prefix
        picks(cell, names) = filter(m -> occursin(eval(Meta.parse(cell)), m), names)
        # The two part only after a `\E`, which the prefix must then hold, written as
        # five characters more. A shorter prefix would fit the column, and match both.
        names = ["long name \\E and a then more words", "long name \\E and b then more words", "short"]
        width = 20
        fits = regex_prefix(names[1], 10)
        @test textwidth(fits) - 1 <= width && length(picks(fits, names)) == 2
        cells = Runtests.Private.shown_names(names, width)
        for (n, cell) in zip(names[1:2], cells[1:2])
            @test cell == regex_prefix(n, 18)             # the shortest prefix that is its own
            @test textwidth(cell) - 1 > width             # over the column, as it must be
            @test picks(cell, names) == [n]
        end
        # The character that tells them apart is the one that makes the `\E`.
        names = ["path\\Ea long name", "path\\Fb long name", "short"]
        cells = Runtests.Private.shown_names(names, 8)
        @test cells[1] == regex_prefix(names[1], 6) == "r\"^\\Qpath\\E\\\\E\\Q\""
        @test cells[2] == regex_prefix(names[2], 6)
        @test picks(cells[1], names) == [names[1]] && picks(cells[2], names) == [names[2]]
    end

    @testset "a character that does not print ends a prefix; a name that needs one past it stays whole" begin
        regex_prefix = Runtests.Private.regex_prefix
        shown_names = Runtests.Private.shown_names
        for c in ('\n', '\t', '\r', '\0', '\x01', '\x7f', '\u0085', '​', '﻿', '\U0e0001')
            n = string("a long name ", c, " that goes on for a while")
            @test regex_prefix(n, 12) !== nothing   # up to it
            @test regex_prefix(n, 13) === nothing   # with it
        end
        @test regex_prefix("a long name \xff that goes on", 13) === nothing   # not UTF-8 at all
        # Told apart from the other before the character: shortened, and the prefix
        # stops short of it.
        cells = shown_names(["a long name \n that goes on and on", "b short"], 20)
        @test cells[1] == "r\"^a long name \""
        @test occursin(eval(Meta.parse(cells[1])), "a long name \n that goes on and on")
        # Told apart only after it: whole, as `repr` writes it, which is its name exactly.
        names = ["a long\tname that goes on and on", "a long\tname that goes elsewhere"]
        cells = shown_names(names, 12)
        @test all(!startswith(c, 'r') for c in cells)
        @test [eval(Meta.parse(c)) for c in cells] == names
    end

    @testset "names that differ only in characters a regex reads are each picked out by their own" begin
        names = [
            "a.b (1) of a long name", "a.b (2) of a long name", "axb (1) of a long name", "a.b [1] of a long name",
            "path\\to\\file one is long", "path\\to\\file two is long", "path/to/file one is long",
            "ends with a backslash \\", "ends with a backslash \\\\", "ends with a backslash \\\\\\",
            "quote \" then more text", "quote \\\" then more text", "quote \\\\\" then more text",
            "\\E inside, then more text", "\\Q inside, then more text", "\\E\\Q inside, then more",
            "\$(interp) is not run here", "\$interp is not run here", "(a|b)+ is a lot of text", "(a|b)* is a lot of text",
        ]
        cells = Runtests.Private.shown_names(names, 14)
        @test count(c -> startswith(c, 'r'), cells) >= 10
        for (n, c) in zip(names, cells)
            x = eval(Meta.parse(lstrip(c)))
            if x isa Regex
                @test occursin(x, n) && count(m -> occursin(x, m), names) == 1
            else
                @test x == n   # whole, as `repr` writes it
            end
        end
        # And as a run takes it: `name=` with the regex shown selects that item alone.
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n") for n in names), "\n")
        dir = make_pkg("RegexNames", "test/r_test.jl" => items)
        for (n, c) in zip(names, cells)
            startswith(c, 'r') || continue
            p, _ = Runtests.Private.prepare((dir,); name = eval(Meta.parse(c)), workers = 1, announce = false)
            @test p.items.name == [n]
        end
    end

    @testset "the names line up on their opening quotes" begin
        long = "an item whose name runs on and on, far past any other in the suite"
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n")
                      for n in ["one", "two", "three", long, long * " too"]), "\n")
        dir = make_pkg("Quoted", "test/q_test.jl" => items)
        p, _ = Runtests.Private.prepare((dir,); workers=2, logs=:issues, announce=false)
        rows = filter(l -> occursin("_test.jl:", l), split(sprint(print_plan, p), '\n'))
        quote_at(l) = length(l[1:prevind(l, findfirst('"', l))]) + 1
        @test length(unique(quote_at.(rows))) == 1
        @test any(l -> occursin("r\"^an item whose name", l), rows)
    end

    @testset "full_names writes every name whole" begin
        long = "an item whose name runs on and on, far past any other in the suite"
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n")
                      for n in ["one", "two", "three", long]), "\n")
        dir = make_pkg("Whole", "test/w_test.jl" => items)
        rows(; kw...) = filter(l -> occursin("_test.jl:", l), split(sprint(print_plan,
            first(Runtests.Private.prepare((dir,); workers=1, logs=:issues, announce=false, kw...))), '\n'))
        @test any(l -> occursin("r\"^an i", l), rows())
        @test any(l -> occursin(repr(long), l), rows(full_names=true))
        @test !any(l -> occursin("r\"^", l), rows(full_names=true))
    end

    @testset "the dry run says why an item goes where it does" begin
        whys(p) = Dict(p.items.name[i] => Runtests.Private.why_text(p, i) for i in 1:nitems(p))
        # From the recorded runs: one item failed in the newest, one three runs back,
        # and one took far longer than the rest.
        h = History(Dict("uses setup" => 100.0, "add works" => 0.1, "mul works" => 0.1),
                    Dict("add works" => 0, "mul works" => 2))
        w = whys(make_plan(; history = h))
        @test w["slow thing"] == "[order] first"
        @test w["add works"] == "failed in the last run"
        @test w["mul works"] == "failed 3 runs ago"
        @test w["uses setup"] == "long: est 1m40.0s"
        # What a cancelled run did not finish goes early too, and is not called a failure.
        h = History(Dict{String, Float64}(), Dict("add works" => 0, "mul works" => 2);
                    cancelled = Set(["add works", "mul works"]))
        w = whys(make_plan(; history = h))
        @test w["add works"] == "cancelled in the last run"
        @test w["mul works"] == "cancelled 3 runs ago"
        # An item edited since its last run, and one no run recorded, come early too.
        all_names = Set(make_plan().items.name)
        w = whys(make_plan(; history = History(; hashes = Dict("add works" => UInt32(1)),
                                               known = setdiff(all_names, ["mul works"]))))
        @test w["add works"] == "edited since its last run"
        @test w["mul works"] == "new"

        dir = make_pkg("Placed",
            "test/p_test.jl" => """
            @testitem "in its own process" sandbox=true begin
                @test true
            end
            @testitem "last of all" begin
                @test true
            end
            @testitem "in file order" begin
                @test true
            end
            """,
            "test/TestItems.toml" => "[order]\nlast = [\"last of all\"]\n")
        p, _ = Runtests.Private.prepare((dir,); workers=2, logs=:issues, announce=false)
        w = whys(p)
        @test w["in its own process"] == "sandbox"
        @test w["last of all"] == "[order] last"
        @test w["in file order"] == ""
    end

    @testset "the dry run shows each item's expected time in seconds, with one decimal, when one is recorded" begin
        lines(p) = split(sprint(print_plan, p), '\n')
        header(p) = only(filter(l -> occursin("test item", l) && occursin(" at ", l), lines(p)))
        @test !occursin(r"\best\b", header(make_plan()))
        h = History(Dict("uses setup" => 100.0, "add works" => 0.26, "chain one" => 2.0), Dict{String, Int}())
        p = make_plan(; workers = 2, history = h)
        row(name) = collect(only(filter(l -> occursin(repr(name), l) && occursin("_test.jl:", l), lines(p))))
        # Right-aligned, ending under the title's last letter, so that the points line
        # up; an item nothing was recorded for has none.
        hdr = header(p)
        stop = length(hdr[1:prevind(hdr, findfirst("est ·", hdr).start)]) + 3
        cell(name) = strip(String(row(name)[(stop - length("100.0s") + 1):stop]))
        @test cell("uses setup") == "100.0s"
        @test cell("add works") == "0.3s" && row("add works")[stop] == 's'
        @test cell("chain one") == "2.0s"
        @test cell("chain two") == ""
        @test cell("mul works") == ""
        # Never in minutes, and a tenth at any size.
        tenths = Runtests.Private.tenths_text
        @test tenths(3725.0) == "3725.0s"
        @test tenths(0.04) == "0.0s"
        @test tenths(Inf) == "Infs"
    end

    @testset "the table is in the order the run would start the items, and says where" begin
        rows(p) = filter(l -> occursin("_test.jl:", l), split(sprint(print_plan, p), '\n'))
        worker(l) = match(r"·\s+(w\d+) ·", l).captures[1]
        # Nothing recorded, so every item counts the same: the pinned item goes to
        # the first worker to ask, and the second starts its own stretch meanwhile,
        # rather than waiting for the first worker's whole stretch to be listed.
        r = rows(make_plan(; workers=2))
        @test length(r) == 6
        @test [parse(Int, match(r"^\s*(\d+) ·", l).captures[1]) for l in r] == 1:6
        @test occursin("\"slow thing\"", r[1]) && worker(r[1]) == "w1"
        @test worker(r[2]) == "w2"
        @test sort(unique(worker.(r))) == ["w1", "w2"]
        # Each item once, and the items of a throttle of one never at the same time:
        # each takes a typical second, nothing being recorded.
        @test sort([match(r"\"(.*?)\"", l).captures[1] for l in r]) == sort([i.name for i in read_items()])
        p = make_plan(; workers=2)
        order = Runtests.Private.run_order(p)
        at(n) = only(t for (t, _, i) in order.items if p.items.name[i] == n)
        @test abs(at("chain one") - at("chain two")) >= 1.0
        # In a run without workers the items run in plan order, and there is no
        # worker to name.
        p = make_plan(; workers=0)
        r = rows(p)
        @test [match(r"\"(.*?)\"", l).captures[1] for l in r] == [p.items.name[i] for i in 1:nitems(p)]
        @test !any(l -> occursin(r"· w\d+", l), r)
    end

    @testset "slot allocation accounts for worker start and per-worker compile cost" begin
        ColdCost = Runtests.Private.ColdCost
        raw = read_items()
        names = [it.name for it in raw]
        # 6 items of 1.0s each (6s total, with a 2-item throttle gate of limit 1 -> floor 2.0s):
        # without compile/start cost, budget 6 uses 3 slots (6/3 == 2.0s).
        secs = Dict(n => 1.0 for n in names)
        p_free = plan(raw, Runtests.Private.read_config(joinpath(fixture("Basic.jl"), "test"); workers = 6);
                      history = History(secs, Dict{String, Int}()))
        @test nslots(p_free) == 3

        # With heavy cold-start compile (20s -> 20% = 4s per extra worker), adding a 2nd
        # worker saves 3s < 4s, so the planner keeps a single worker.
        p_cold = plan(raw, Runtests.Private.read_config(joinpath(fixture("Basic.jl"), "test"); workers = 6);
                      history = History(secs, Dict{String, Int}(); cold = ColdCost(0.5, 20.0, 20.0)))
        @test nslots(p_cold) == 1

        # With moderate per-worker compile (10s across items -> 20% = 2s + 0.5s start = 2.5s),
        # 1->2 saves 3.0s > 2.5s (worth it), 2->3 saves 1.0s < 2.5s (stops at 2 workers).
        comps = Dict(n => 2.0 for n in names)
        p_mod = plan(raw, Runtests.Private.read_config(joinpath(fixture("Basic.jl"), "test"); workers = 6);
                     history = History(secs, Dict{String, Int}(); cold = ColdCost(0.5, 0.0, 10.0), compile_s = comps))
        @test nslots(p_mod) == 2
    end
end
