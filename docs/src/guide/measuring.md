# [Measure what each item costs](@id measuring)

A run can give you figures for each attempt at an item: its time, CPU time, compilation, garbage collection, allocations and memory. Give `runtests` or `runtests_mono` a function as `on_event`. The run calls the function in the process that started it.

## Collect the figures

The run calls the function when each attempt at an item starts, and again when the attempt ends. A retry is a new attempt, so it gets two calls of its own.

```julia
events = Runtests.TestItemEvent[]
Runtests.runtests(on_event = ev -> ev.kind === :finished && push!(events, ev))
sort!(events; by = ev -> ev.cpu, rev = true)   # the items with the most CPU time first
```

## The fields of a TestItemEvent

Each call gets a `Runtests.TestItemEvent` with these fields:

| Field | Meaning |
|:------|:--------|
| `kind` | `:started` or `:finished`. |
| `name`, `file`, `line` | The item. |
| `package`, `root` | The name and root directory of the item's package. Together with `name`, these distinguish items in a combined run. |
| `attempt` | 1 for the first attempt, 2 for the first retry, and so on. |
| `worker`, `pid` | The number of the worker that ran the attempt, as in `w1` in the lines of the run, and the ID of its process. |
| `time` | When the attempt started or ended, as `time()` gives it. |
| `state` | `:running` when the attempt starts. When it ends, the outcome: `:passed`, `:failed`, `:errored`, `:timedout`, `:skipped`, `:broken_chain` or `:cancelled`. |
| `measured` | `true` when the item measured the figures below itself. |
| `elapsed` | Seconds that the attempt took. |
| `cpu` | Seconds of CPU time that the process used, in its own code and in the kernel, over all its threads. |
| `compile`, `recompile` | Seconds of compilation, and the part of them that was recompilation. |
| `gc` | Seconds of garbage collection. |
| `allocated` | Bytes allocated. |
| `allocations` | The number of allocations. |
| `maxrss` | The most memory that the process held in RAM up to this point, in bytes. |
| `events_dir` | A directory for files that the function writes. See [Keep what the function writes](@ref events-dir). |

`pid` is 0 when no process ran the attempt. This happens when the run cannot start a worker, for example because the `init` of the profile fails. It also happens to an item of a chain whose worker stopped before the item ran. For that item, `worker` is 0 too.

## What the figures cover

Only the second call has the figures. Each figure except `elapsed` is for the whole process. CPU, compilation, garbage collection and allocation counts cover the interval measured around the item. `maxrss` is different: it is the process's lifetime high-water mark, which an earlier item may have set. With `workers = 0`, the process is the one that called `runtests`, so the interval can also include work that the run itself does in that process.

Measured item time excludes the profile's `test_end` and the deferred [artifact producers](@ref evidence). Their work still contributes to the run's total time. The `:finished` event is delivered after the verdict is recorded and before artifact collection begins; it does not signal that evidence files are complete.

Sometimes the run decides the outcome, and the item measures nothing. Examples are a timeout, a worker that stopped, an item of a chain that cannot run, and a stopped run. Then `measured` is `false`, the figures are 0, and `elapsed` is the time that the attempt held its worker.

## [Keep what the function writes](@id events-dir)

Write the files of the function to `ev.events_dir`. This directory is `events` in the directory of the run, next to the record and the logs of the run. Thus `RUNTESTS_ARTIFACT_DIR` copies the files with the run, and [retention](@ref retention) deletes them with the run. In a combined run, each package has its own directory. The run makes the directory only when you give a function.

```julia
Runtests.runtests(on_event = ev -> ev.kind === :finished &&
    open(io -> println(io, ev.name, ",", ev.cpu), joinpath(ev.events_dir, "cpu.csv"), "a"))
```

The calls do not overlap, so the function can add lines to one file without a lock.

## How the run calls the function

The run makes one call at a time, from its own tasks, and waits for each call to return. Thus a slow function makes the run slow. If the function throws an error, the run reports the error once and does not call the function again. The tests continue. An attempt that is in progress when you interrupt the run can end without its second call.
