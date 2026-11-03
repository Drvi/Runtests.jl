# [Measure what each item costs](@id measuring)

A run can give you figures for each attempt at an item: its time, CPU time, compilation, garbage collection, allocations and memory. Give `runtests` a function as `on_item`. The run calls the function in the process that called `runtests`.

## Collect the figures

The run calls the function when each attempt at an item starts, and again when the attempt ends. A retry is a new attempt, so it gets two calls of its own.

```julia
events = Runtests.ItemEvent[]
Runtests.runtests(on_item = ev -> ev.kind === :finished && push!(events, ev))
sort!(events; by = ev -> ev.cpu, rev = true)   # the items with the most CPU time first
```

## The fields of an ItemEvent

Each call gets a `Runtests.ItemEvent` with these fields:

| Field | Meaning |
|:------|:--------|
| `kind` | `:started` or `:finished`. |
| `name`, `file`, `line` | The item. |
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

`pid` is 0 when no process ran the attempt. This happens when the run cannot start a worker, for example because the `init` of the profile fails. It also happens to an item of a chain whose worker stopped before the item ran. For that item, `worker` is 0 too.

## What the figures cover

Only the second call has the figures. Each figure except `elapsed` is for the whole process. CPU, compilation, garbage collection and allocation counts cover the interval measured around the item. `maxrss` is different: it is the process's lifetime high-water mark, which an earlier item may have set. With `workers = 0`, the process is the one that called `runtests`, so the interval can also include work that the run itself does in that process.

Measured item time excludes the profile's `test_end` and the deferred [artifact producers](@ref evidence). Their work still contributes to the run's total time. The `:finished` event is delivered after the verdict is recorded and before artifact collection begins; it does not signal that evidence files are complete.

Sometimes the run decides the outcome, and the item measures nothing. Examples are a timeout, a worker that stopped, an item of a chain that cannot run, and a stopped run. Then `measured` is `false`, the figures are 0, and `elapsed` is the time that the attempt held its worker.

## How the run calls the function

The run makes one call at a time, from its own tasks, and waits for each call to return. Thus a slow function makes the run slow. If the function throws an error, the run reports the error once and does not call the function again. The tests continue. An attempt that is in progress when you interrupt the run can end without its second call.
