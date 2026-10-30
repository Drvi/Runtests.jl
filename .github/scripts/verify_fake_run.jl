# Checks what a CI run of the fake suite, `test/testfixtures/FakeCI.jl`, left for a person
# to download, and that it works the way the README says it does:
#
# - the artifact `RUNTESTS_ARTIFACT_DIR` filled: one run state and its logs, nothing else;
# - the run state: every item, its verdict and its attempts;
# - the logs: what failing items printed, and the failure report of each failed attempt;
# - the evidence of each failed attempt, `Runtests.artifacts_dir()` and `Runtests.on_failure`,
#   a retry's failed attempt among them, with collection errors and timeouts reported beside
#   it in paths that hold wherever the bundle is unpacked;
# - the run-state cache for the next job, which leaves the logs out;
# - the failing items run again from the downloaded run state, `Runtests.runtestsf(replay =
#   ...)`, with the same verdicts and the random numbers they drew on CI.
#
#     julia --project=test/testfixtures/FakeCI.jl/test .github/scripts/verify_fake_run.jl <artifact> <run states>
#
# The two directories can also come from `FAKECI_ARTIFACT` and `FAKECI_RUNSTATES`.

using Runtests

const FAKECI = normpath(joinpath(@__DIR__, "..", "..", "test", "testfixtures", "FakeCI.jl"))

# Each item's verdict and the attempt that gave it, as `test/ci_tests.jl` makes them.
const VERDICTS = Dict(
    "passes" => ("PASSED", 1),
    "fails an assertion" => ("FAILED", 1),
    "throws" => ("ERRORED", 1),
    "producers that misbehave" => ("FAILED", 1),
    "passes on a retry" => ("PASSED", 2),
    "times out" => ("TIMEDOUT", 1),
    "kills its worker" => ("ERRORED", 1),
    "hangs in a producer" => ("FAILED", 1),
    "skipped" => ("SKIPPED", 1),
    "broken" => ("PASSED", 1),
)

# The evidence each failed attempt keeps: files in its directory, with their contents
# where they are known, and what the log beside it says.
const EVIDENCE = Dict(
    ("fails an assertion", 1) => (files = ["files/drawn.txt" => nothing, "producer_1/report.txt" => "expected 42, got 40"],
                                  log = ["collected: 1 producer, 0 failed"]),
    ("throws", 1) => (files = ["producer_1/state.txt" => "collected after an error"],
                      log = ["collected: 1 producer, 0 failed"]),
    ("producers that misbehave", 1) => (files = ["producer_2/ok.txt" => "the next producer still runs"],
                                        log = ["producer 1 (producer_1/) threw", "a producer that throws",
                                               "collected: 2 producers, 1 failed"]),
    ("passes on a retry", 1) => (files = ["files/attempt.txt" => "1", "producer_1/attempt.txt" => "1"],
                                 log = ["collected: 1 producer, 0 failed"]),
    ("times out", 1) => (files = ["files/before.txt" => "written before the hang"],
                         log = ["not collected: test item \"times out\" timed out after 10s", "the producers did not run"]),
    ("kills its worker", 1) => (files = ["files/before.txt" => "written before the exit"],
                                log = ["not collected: the worker running this item died", "the producers did not run"]),
    ("hangs in a producer", 1) => (files = ["producer_1/partial.txt" => "written before the hang"],
                                   log = ["timed out after 10s (artifacts_timeout)"]),
)

# What each failed attempt's failure report says.
const FAILURES = Dict(
    ("fails an assertion", 1) => "FakeCI.double(20) == expected",
    ("throws", 1) => "thrown on purpose",
    ("producers that misbehave", 1) => "Test Failed",
    ("passes on a retry", 1) => "attempt == 2",
    ("times out", 1) => "timed out after 10s",
    ("kills its worker", 1) => "died",
    ("hangs in a producer", 1) => "Test Failed",
)

arg(k, var) = length(ARGS) >= k ? ARGS[k] : get(ENV, var, "")
const ARTIFACT = abspath(arg(1, "FAKECI_ARTIFACT"))
const RUNSTATES = abspath(arg(2, "FAKECI_RUNSTATES"))
isdir(ARTIFACT) || error("no artifact directory at $(repr(ARTIFACT)); give it as the first argument or FAKECI_ARTIFACT")
# A missing run-state directory is what a cache that was not restored leaves, which the
# checks of the cache report; the rest is checked all the same.

logs_of(runstate) = string(chopsuffix(runstate, ".runstate"), ".logs")
read_or_empty(path) = isfile(path) ? read(path, String) : ""
# Files compared as text, whatever line endings the runner wrote them with.
text(path) = replace(read_or_empty(path), "\r\n" => "\n")

# Everything a record says of each item, by name.
items_of(rs) = Dict(it.name => (k, string(st.state), Int(st.attempt)) for (k, (it, st)) in enumerate(zip(rs.items, rs.statuses)))

const RUNSTATE = let found = filter(endswith(".runstate"), readdir(ARTIFACT; join = true))
    length(found) == 1 || error("the artifact holds $(length(found)) run states, where it should hold one: $(readdir(ARTIFACT))")
    only(found)
end
const LOGS = logs_of(RUNSTATE)
const RECORD = Runtests.read_run_state(RUNSTATE)
RECORD === nothing && error("$(RUNSTATE) does not read as a run state")
const ITEMS = items_of(RECORD)

# The failing items run again from the downloaded record, here, before any testset: a
# run inside one would add its failures to it. Their verdicts are checked below.
const REPLAYED = mktempdir()
const REPLAY_ERROR = withenv("RUNTESTS_RUNSTATE_DIR" => REPLAYED, "RUNTESTS_ARTIFACT_DIR" => nothing) do
    try
        Runtests.runtestsf(FAKECI; replay = RUNSTATE)
        nothing
    catch e
        e
    end
end

# On GitHub, what the run recorded, for whoever opens the job: written first, since a
# testset that fails ends the script.
summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
isempty(summary) || open(summary, "a") do io
    println(io, "### FakeCI run on ", get(RECORD.meta, "host", "?"), "\n")
    println(io, "| item | verdict | attempt | evidence |\n|:--|:--|:--|:--|")
    for (name, (k, state, attempt)) in sort!(collect(ITEMS); by = x -> first(last(x)))
        kept = [a for a in 1:attempt if isdir(joinpath(LOGS, "item_$(k)_$(a).artifacts"))]
        println(io, "| ", name, " | ", state, " | ", attempt, " | ",
                isempty(kept) ? "" : join(("item_$(k)_$(a).artifacts" for a in kept), ", "), " |")
    end
end

@testset "a CI run of FakeCI" begin
    @testset "the artifact holds the run state and its logs, and nothing else" begin
        @test sort(readdir(ARTIFACT)) == sort([basename(RUNSTATE), basename(LOGS)])
        @test isdir(LOGS)
    end

    @testset "the run state records every item, its verdict and its attempt" begin
        @test RECORD.complete && !RECORD.cancelled
        @test Dict(n => (s, a) for (n, (_, s, a)) in ITEMS) == VERDICTS
        @test startswith(get(RECORD.meta, "host", ""), "ci-")
        @test get(RECORD.meta, "artifacts_timeout", "") == "10"
    end

    @testset "the logs hold what failed and what failing items printed" begin
        for ((name, attempt), says) in FAILURES
            k = first(ITEMS[name])
            @test occursin(says, text(joinpath(LOGS, "item_$(k)_$(attempt).failure.txt")))
        end
        k = first(ITEMS["fails an assertion"])
        @test occursin("printed by the failing item", text(joinpath(LOGS, "item_$(k)_1.log")))
        # An attempt that passed reports no failure.
        k = first(ITEMS["passes on a retry"])
        @test !isfile(joinpath(LOGS, "item_$(k)_2.failure.txt"))
    end

    @testset "each failed attempt keeps its evidence, and only those do" begin
        kept = Set(n for n in readdir(LOGS) if endswith(n, ".artifacts"))
        expected = Set(string("item_", first(ITEMS[name]), "_", attempt, ".artifacts") for (name, attempt) in keys(EVIDENCE))
        @test kept == expected
        for ((name, attempt), (; files, log)) in EVIDENCE
            dir = joinpath(LOGS, string("item_", first(ITEMS[name]), "_", attempt, ".artifacts"))
            for (file, content) in files
                @test isfile(joinpath(dir, file))
                content === nothing || @test text(joinpath(dir, file)) == content
            end
            said = text(string(dir, ".log"))
            for line in log
                @test occursin(line, said)
            end
            # Paths there are the bundle's own, so the log reads the same wherever it is
            # unpacked.
            @test !occursin(".logs", said)
        end
        # A producer's error is shown down to the producer, without Runtests' own frames.
        k = first(ITEMS["producers that misbehave"])
        @test !occursin("run_producer", text(joinpath(LOGS, "item_$(k)_1.artifacts.log")))
        # A producer runs for a failed attempt that finished, and for nothing else.
        @test !any(f -> f == "never.txt", (f for (_, _, fs) in walkdir(LOGS) for f in fs))
        @test !isfile(joinpath(LOGS, string("item_", first(ITEMS["passes on a retry"]), "_2.artifacts.log")))
    end

    @testset "the record, read where it was downloaded, says where the evidence is" begin
        shown = sprint(show, MIME("text/plain"), RECORD)
        k = first(ITEMS["fails an assertion"])
        @test occursin(joinpath(LOGS, "item_$(k)_1.artifacts"), shown)
        @test occursin("Runtests.runtestsf(replay = ", shown)
    end

    @testset "the cache for the next job holds the run state and leaves the logs out" begin
        @test isdir(RUNSTATES)
        if isdir(RUNSTATES)
            @test basename(RUNSTATE) in readdir(RUNSTATES)
            @test !any(endswith(".logs"), (d for (_, ds, _) in walkdir(RUNSTATES) for d in ds))
            @test Runtests.read_run_state(joinpath(RUNSTATES, basename(RUNSTATE))) !== nothing
        end
    end

    @testset "the failing items run again from the record, as they ran on CI" begin
        @test REPLAY_ERROR !== nothing   # they fail again
        found = filter(endswith(".runstate"), readdir(REPLAYED; join = true))
        @test length(found) == 1
        replay = Runtests.read_run_state(only(found))
        again = items_of(replay)
        failing = Set(n for (n, (s, _)) in VERDICTS if s in ("FAILED", "ERRORED", "TIMEDOUT"))
        @test Set(keys(again)) == failing
        for name in failing
            @test again[name][2] == ITEMS[name][2]
        end
        # With the seed it failed with: the number it drew is the one it drew on CI.
        drawn(logs, k) = text(joinpath(logs, "item_$(k)_1.artifacts", "files", "drawn.txt"))
        @test drawn(logs_of(only(found)), first(again["fails an assertion"])) ==
              drawn(LOGS, first(ITEMS["fails an assertion"]))
    end
end
