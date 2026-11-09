# [How a run works](@id how-a-run-works)

This page explains what happens between a call to `runtests` and its result. A run reads the suite, plans the order, builds the test environment and runs the items on workers.

## The processes of a run

The process that calls `runtests` is the coordinator. The coordinator never runs test items, except with `workers = 0`. It starts the worker processes, gives each worker one item at a time, collects the results and prints the output. If a worker crashes, only that worker stops. The coordinator records the item as an error and continues.

## Reading the suite

The coordinator finds test items by parsing the test files. It does not evaluate the files. Thus it knows the name, the location, the keywords and the imports of each item before any worker starts. Each run parses the whole suite, also when the selection is one item. These problems stop the run: a file that does not parse, a name that two items use, and a Julia file in no category. The run then throws a `ScanFailure` that lists every problem.

From the imports of the selected items, the coordinator knows which [setups](@ref setups) they need. It precompiles these setups before it starts the workers, for each profile whose items load them.

## [The test environment](@id test-environment)

Under `Pkg.test`, Runtests uses the environment that Pkg already built. It also respects an already active `test/Project.toml`. Otherwise it builds the environment with TestEnv, except for the workspace case below. Thus the dependencies that your package declares only for tests can be imported in a test item. These are the dependencies in `[extras]` and `[targets]`, or in `test/Project.toml`. When the run ends, the environment that was active before is active again.

When a package and its `test/Project.toml` belong to the same outermost Julia workspace, Runtests activates the test project and instantiates it, as `Pkg.test` does. The workspace can list both projects directly, or the package can list its own `test` project. They share the workspace manifest, so TestEnv does not build a separate environment.

Runtests keeps resolved environments for the session and rebuilds them when their input files, such as `Project.toml` or a manifest, change. Reusing an environment does not guarantee that all compilation is reusable: changed source or worker flags can require new compiled code. The items in an [environment directory](@ref environments) run in that environment, stacked over the test environment.

## [The plan](@id plan)

Before it starts the items, the coordinator plans the order in which it gives them out. It uses the durations that earlier runs recorded. A run gives out the items in this order:

1. the items that `[order] first` names,
2. sandboxed items, while each process is still new,
3. items that need a new result:
   - items whose latest result is a failure,
   - items that the newest run that selected them stopped before,
   - items that are new, or changed since they last ran,
4. items that set the length of the run: at least 3 seconds, and more than a quarter of the share of work of one worker,
5. all other items, in file order,
6. the items that `[order] last` names.

Within step 3, new or edited items and failures from the newest run come first, then older failures from newest to oldest. Within each urgency level, the long items go first and the rest follow file order. A chain is scheduled together, at the position of its most urgent member.

In step 5, each worker goes through its own range of files. Thus neighboring items can use the code that the worker already compiled. A worker that finishes its range takes half of the longest range that is left. In the other steps, the next free worker takes the next item.

Each start configuration that the items use has a pool of workers. A start configuration is what a worker gets when it starts: its flags, threads, variables, `init`, preferences and environment. Pools start in order of their estimated completion, the latest first. The estimate starts with the time that a worker needs to be ready. It adds the larger of two times: the pool's work shared among its workers, and its longest item or chain. An item that no run timed counts as the typical duration of an item, also in a chain with timed items.

When a pool has no items left, a worker of that pool can restart for another pool. The restart must make that pool finish sooner. To find out, the run plays out the items that are left in the pool, in the order that the workers take them. Each item goes to the worker that is free first. The workers of the pool are free at once, and the new worker is free only after its cost: its start, and the compilation of what the other workers already compiled. An item or a chain goes to one worker whole. Thus a new worker that is ready after the other workers took the last items makes the pool finish no sooner. Of the pools that a restart makes finish sooner, the worker restarts for the pool that finishes last. During the run, an item that no run timed counts as the average item of its pool so far.

The dry run shows the plan. It plays out the dispatch of the run with the recorded durations, so it is as good as those durations are. The `why here` column says which rule placed an item, when the rule was not file order.

### Short names

When a name is much longer than the others, the plan shortens it to `r"^…"`, in the plan and in the `RUN` and `DONE` lines. The short form is a prefix that no other item name in the suite starts with. Thus you can give it as `name =` to select that item. `full_names = true` writes every name in full.

## Workers

A worker starts with the flags, threads, environment variables and preferences of its profile, in the environment of its pool. Then it runs the `init` of its profile, and after that one item at a time. After each item that returns a result other than skipped, it runs the `test_end` of its profile. A timed-out or crashed worker cannot run this hook.

Each item runs in a new module. A worker can reuse compiled code from earlier items, though new method specializations or invalidations can still require compilation. Items on one worker also share the state of the process. [Write test items](@ref writing) explains what this means for a test.

A worker that goes past the timeout of its item is stopped. The item is recorded as timed out, and the run starts a new worker in its place.

## [Memory](@id memory)

The coordinator watches the memory of the machine. When the memory in use goes over `memory_threshold`, the run does these steps:

1. It holds off on new items.
2. It collects garbage.
3. Only then, it restarts the largest worker, after the item that the worker runs is finished.

The run never stops a running item for memory, because the memory can belong to another program. The hold ends when the memory in use is two points below `memory_threshold`, and the run says when it ends. The hold has a limit. Thus memory pressure from another program slows a run down, but never stops it.

## Runs that hang

A run can go a long time without a finished item. The watchdog allows the larger of the largest item timeout plus the applicable `init` and `test_end` limits, or `artifacts_timeout`, then adds the longest memory hold and five minutes. Finishing [artifact collection](@ref evidence) also counts as progress. If nothing finishes within that budget, the run stops as hung: it kills the workers, records running items as timed out, and `runtests` throws. An attempt whose verdict was already recorded before collection keeps that verdict.

## The output

The coordinator writes all the output. A worker writes the output of its items to a log file, except under `logs = :eager`. When an item ends, the coordinator prints its block as one piece. Thus the output of another worker never lands inside it. [The output reference](@ref output) describes each line.

## The record

Each run writes a run state while it goes on, and prints its path at the end. The next run uses it to plan, and `runtestsf` uses it to find the failures. [Run states and history](@ref history) explains what a run state records and which run states Runtests keeps.
