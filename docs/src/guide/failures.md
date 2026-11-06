# [Investigate failures](@id failures)

This page tells you how to find out why an item failed. You can read its report and its log, and run it again with the same seed. You can also keep files that explain the failure, and step into the item with a debugger.

## Read the report of the item

An item that did not pass gets a block with its results right after its `DONE` line:

```text
🔴 w1 · 12:55:14 · DONE · 1/1 · "fails" · FAIL ·  0.0s (92% compile) · maxrss 0.3 GiB
┌ [1/1] FAIL "fails"
│ Test Failed at test/faults_test.jl:6
│   Expression: 1 == 2
│ [ No captured logs
└ @ test/faults_test.jl:5 on worker 1
```

The block holds the failed tests, the captured output of the item, and the path of the files that the item kept. Under `logs = :issues`, the default, only items that did not pass print their output. Under `logs = :quiet`, no item prints its output. Then read the output in the log of the item. Under `logs = :eager`, the output streams as the item runs and is not repeated in the block.

## Read the logs

Except under `logs = :eager`, each run keeps what each item printed in the directory of the run, `<run>.rundata`, next to its run state. The closing block names the directory on its `run state` line. The directory also holds the failure report of each attempt that did not pass. [The files reference](@ref run-state-files) shows the names of the files.

With `logs = :eager`, use the terminal or CI job log to read the item's output; Runtests does not retain an item log of that output. Failure reports and [artifact evidence](@ref evidence) are still kept. Producers' output is captured in their `.artifacts.log` even in this mode. [The configuration reference](@ref run-keys) lists all logging modes.

## Run the failures again

`Runtests.runtestsf()` runs the items that are failing, each starting from the seed that it failed with. This helps reproduce random inputs when the code and its sequence of random draws are unchanged. It does not restore external state, task scheduling, or a random generator that the test seeds separately, so it does not guarantee the failure will recur. [Run tests](@ref running) explains selection, and [Run states and history](@ref history) explains which failures remain on record.

## Replay a recorded run

A run state records a run: its items, configuration, profiles, `[order]` and seeds. To run the same items again, give the directory of the run as `replay`. The `run.runstate` file in it also works.

```julia
Runtests.read_run_state("path/to/the.rundata")     # read the record
Runtests.runtests(replay = "path/to/the.rundata")  # run its items again
Runtests.runtestsf(replay = "path/to/the.rundata") # run its failures again
```

A replay does these things:

- It uses the items, the configuration, the profiles, the `[order]` and the seeds of the record. A keyword that you give replaces the recorded value.
- It gives the workers the Julia flags of the recorded run, when these differ from the flags of this process.
- It names each package whose version differs from the recorded environment. It does not install the recorded versions.
- It names each recorded item that the suite no longer has. A renamed or deleted item cannot run again.

`runtestsf(replay = ...)` selects the failures from the verdicts of that run and of the runs that started after it. Earlier runs give only durations.

For a combined workspace run, call `Runtests.runtests_mono(replay = "path/to/a.runstate")` with the run state of any participating package. [The monorepo guide](@ref monorepos) explains how it finds the other packages' records.

A run state from CI works the same way. Download the artifact of the job, and give the path of the run state as `replay`. [Run on CI](@ref ci-history) tells you how to keep run states on CI.

## [Keep evidence from a failed attempt](@id evidence)

An item can keep files that explain a failure. There are two kinds of files: outputs that the item writes while it runs, and files that producers write after the attempt fails. A producer is a function that the item registers with `Runtests.on_failure`.

This example needs no packages beyond Runtests and Julia's standard library. Put it in `test/evidence_test.jl` and run `Runtests.runtests("test/evidence_test.jl")`. It fails deliberately and prints the path of its evidence:

```julia
@testitem "keep a failed comparison" begin
    import Runtests
    expected = [1, 2, 3]
    actual = [1, 2, 4]

    write(joinpath(Runtests.artifacts_dir(), "input.txt"), "1,2,3\n")
    Runtests.on_failure() do dir
        open(joinpath(dir, "comparison.txt"), "w") do io
            println(io, "expected = ", expected)
            println(io, "actual = ", actual)
        end
    end

    @test actual == expected
end
```

The attempt keeps `files/input.txt` and `producer_1/comparison.txt`. Change `actual` to `[1, 2, 3]` and run again: the producer does not run, and the passing attempt's files are deleted. The earlier failure's evidence remains with its own run state.

The same pattern applies to images and compiled programs. These illustrations use application-specific functions such as `render_scene`, `save` and `compile_program`:

```julia
@testitem "image matches reference" begin
    import Runtests
    actual = render_scene()
    reference = load_reference()

    Runtests.on_failure() do dir
        save(joinpath(dir, "actual.png"), actual)
        save(joinpath(dir, "difference.png"), difference(actual, reference))
    end

    @test actual ≈ reference
end

@testitem "compiled program runs" begin
    import Runtests
    dir = Runtests.artifacts_dir()
    executable = compile_program(dir)
    @test success(run(ignorestatus(`$executable`)))
end
```

### artifacts_dir

`Runtests.artifacts_dir()` makes the `files/` directory of the attempt and returns its path. It returns the same directory each time within one attempt. Write outputs there directly. Runtests copies nothing.

### on_failure

`Runtests.on_failure(f)` registers a producer and returns `nothing`. It does not call `f`. If the attempt fails, Runtests calls each producer once, in the order of registration. Each producer gets a directory of its own, `producer_<k>/`. The test chooses the names of the files in both directories.

### When an attempt fails

An attempt fails when a test fails or the item throws, in its body or in the `test_end` of its profile. Producers can run only if the worker survives to return the result. A skipped item, a test marked as broken and an attempt that passes do not run producers. An attempt that passes deletes what it wrote.

Producers run after the body and its profile's `test_end` finish and the run records the verdict. They see their values as they are when they run, not as they were at registration. A file that a `mktempdir() do` block deletes is gone by then. Write such a file to `artifacts_dir()` instead.

Collection has its own time budget and does not count toward the item's measured time or timeout. It does take time in the run and occupies the worker until it ends. The [`on_item` callback](@ref measuring) receives `:finished` before collection begins; that event does not mean the evidence is ready.

A producer that throws, or a `@test` in a producer that fails, goes into the `.artifacts.log` file. It does not change the verdict, and the next producer still runs. All producers of an attempt together have `artifacts_timeout` seconds; this [run setting](@ref run-keys) defaults to `timeout`. If they take longer, or the worker stops, the run replaces the worker and keeps the files written so far. If the body or `test_end` times out or loses its worker, producers do not run. When producers were registered, the `.artifacts.log` file says why.

A worker lost during collection also loses a chain's process state. The remaining members cannot continue on that process; the usual chain retry rules apply.

!!! warning
    A producer running in the caller's process, under `workers = 0` or while debugging, has no enforceable timeout. Sandboxed items that still get a worker under `workers = 0` keep the collection timeout.

### Where the evidence goes

Each attempt keeps its evidence next to its log, in the directory of the run. A retry gets a directory of its own. Thus a failed attempt keeps its evidence when a later attempt passes. The report of the failure and the closing block of the run print the path. [The files reference](@ref run-state-files) shows the layout.

The evidence is deleted with the run state. `RUNTESTS_ARTIFACT_DIR` copies it with the logs; [Run on CI](@ref ci-artifact) explains how to upload it, including evidence from failed attempts whose retries passed. A pasted item keeps its evidence in a new directory in the temporary files of the system. So does an item that you step into with `Runtests.debug`. The REPL prints its path. Delete the directory when you no longer need it.

### Limits

Both functions work only in the body of an item, and in the tasks that the body starts and waits for. They throw an `ArgumentError` in `init`, in `skip`, in `test_end`, in a producer and outside an item. They also throw in a task that the item did not wait for, if the task calls them after the body returned. The items of a chain do not share evidence, because the directory of a passing item is deleted.

A registered producer keeps what it refers to, and the globals of the item, until collection ends or the producers are discarded after a pass. A `test_end` such as `GC.gc(true)` does not release that memory. A passed attempt releases it before its worker runs the next item. The producer's serialization or other expensive work happens only after a failure; registration still retains the references and writes a small note that producers are waiting.

## Step into an item with a debugger

With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, `Runtests.debug` steps into one test item in the current process. Without a name, it steps into the most recent failure, with the seed that it failed with. [Work at the REPL](@ref debug) tells you how.
