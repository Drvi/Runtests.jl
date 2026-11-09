# [Configure runs](@id configuration)

This page tells you how to configure the runs of a suite: the number of workers, the timeouts, the output, the order and the groups. [The configuration reference](@ref configuration-keys) lists every key with its default.

## Where the configuration comes from

A run takes each configuration value from the first of these sources that sets it:

1. a keyword of `runtests`, for example `runtests(workers = 4)`,
2. an environment variable `RUNTESTS_<KEY>`, for example `RUNTESTS_WORKERS=4`,
3. the `[run]` table of `test/TestItems.toml`,
4. the default.

The header of the run names each environment variable that set a value. CI can thus set the configuration of a job without a change to the project.

In a [combined workspace run](@ref monorepos), run-wide values come from the workspace root's file. Each package's other settings come from its own file, with any [shared profile defaults](@ref shared-profiles) from the workspace root. A keyword or environment variable still takes precedence for every package.

```julia
Runtests.runtests(workers = 4, timeout = 600, retries = 1)
```

```toml
# test/TestItems.toml
[run]
workers = 4
timeout = 600
retries = 1
logs = "issues"
```

In the file, write a symbol value as a TOML string, for example `logs = "issues"`. An unknown key or an incorrect value is an error, and Runtests reports it before any item runs.

## The configuration file

`test/TestItems.toml` is optional. It has four tables:

```toml
[run]
workers = "auto"       # or an integer
timeout = 600          # seconds for each attempt at an item
init_timeout = 120     # seconds for each `init` expression; the default is `timeout`
test_end_timeout = 60  # seconds for each `test_end` expression; the default is `timeout`

[order]
first = ["smoke test"]         # exact names of items in the suite
last  = ["large simulation"]

[groups]
default = "!gpu"               # what a run selects when nothing else selects
gpu = "gpu"
quick = "fast && !slow"

[profiles.bounds]
julia_args = ["--check-bounds=yes"]   # for items with `profile = :bounds`
```

`[profiles]` declares worker profiles. [Profiles and environments](profiles.md) tells you how to use them.

To read another file in place of `test/TestItems.toml`, give the `config` keyword: `runtests(config = "ci.toml")`. The path is relative to the current directory, and the file must exist. Only the `config` keyword selects another file. No environment variable and no file next to it do that.

## Workers and threads

`workers = "auto"` is the default. It chooses the number of workers from the number of CPUs, the threads of each worker and an assumed 4 GiB for each worker. The maximum is 8. Give an integer to set the number yourself. `workers = 0` runs ordinary items in the process that calls `runtests`; sandboxed items and items of a named profile still use workers. [Run tests](@ref running) explains this mode.

`threads` is the `--threads` value of each worker. The default is `"2,1"`: two threads in the default pool and one interactive thread. A worker with `threads = "auto"` takes every CPU.

## Timeouts and retries

`timeout` is the number of seconds that each attempt at an item can take. The default is 1800. A worker that goes past the timeout is stopped, and the item is recorded as timed out. `init_timeout` and `test_end_timeout` limit the `init` and `test_end` expressions of a profile, and `artifacts_timeout` limits the [producers](@ref evidence) of a failed attempt. Each of them is `timeout` by default.

A timeout must be positive and at most 2,147,483,647 seconds. Runtests rounds a fraction up to whole seconds. Work in the calling process with `workers = 0` cannot be forcibly timed out.

`retries` gives each item more attempts after a failure, from 0 to 126. The `timeout` and `retries` keywords of an item replace the values of the run for that item.

`failfast = true` stops the run when an item or chain still fails after its allowed retries. `item_failfast = true` stops each attempt at its first failed test. Its default is the run's `failfast` value; set it separately when you want a failing attempt to finish its remaining assertions before the run stops.

## Output

`logs` controls what the run prints of the output of the items:

| Value | What the run prints |
|:------|:--------------------|
| `:issues` | The output of each item that did not pass, after its `DONE` line. This is the default. |
| `:batched` | The output of every item, when the item ends. |
| `:eager` | The output of every item, while it runs. This mode does not save the output to per-item log files. |
| `:quiet` | No output of any item. The output stays in the log files of the run. |

An interactive session with one worker or less uses `:eager` by default. When many workers print at the same time, their output mixes. Thus other runs use `:issues` by default.

These keys also control the output:

- `verbose = true` includes passing testsets in the result summary. Use `logs = :batched` to print passing-item output too.
- `monitor = false` switches off the memory monitor and the progress line.
- `monitor_interval` is the number of seconds between progress lines when the output is not a terminal. The default is 30.
- `full_stacktraces = true` keeps the frames of Runtests in the stack traces of failures.
- `full_names = true` prints long item names in full, in place of [a unique prefix](@ref plan).
- `testset_name` is the name of the testset that the run returns. The default is `"Runtests"`.

## Memory

`memory_threshold` is the fraction of the memory of the machine at which the run waits before it starts new items. The default is 0.9. The value must be greater than 0 and at most 1. [How a run works](@ref memory) explains what the run does when memory is low.

## [Random numbers](@id random-numbers)

`seed` sets the seed of the run. Each item draws its random numbers from this seed combined with the name of its package and its own name. Thus an item draws the same numbers in the run of its package as in a [combined run](@ref monorepos), and two items with one name in different packages draw different numbers. Without `seed`, the run chooses a random seed and prints it in its header. A run with the same seed draws the same numbers in each item, whatever ran before the item. Environment variables take a seed as text, for example `RUNTESTS_SEED=0x1234`.

A retry draws the same numbers as the first attempt. Thus a failure that the numbers cause fails again, and does not pass on a lucky draw. To draw new numbers on a retry, reseed from the attempt number that `Runtests.current_testitem()` gives:

```julia
@testitem "random inputs" retries=2 begin
    import Random, Runtests
    attempt = Runtests.current_testitem().attempt
    attempt > 1 && Random.seed!(rand(UInt64) + attempt)
    @test all(x -> 0 <= x < 1, rand(100))
end
```

For this, `Random` must be a test dependency of the package.

## [Order](@id order)

`[order]` names items that start before or after all others:

```toml
[order]
first = ["smoke test"]
last  = ["large simulation"]
```

On a run of the whole suite, `[order]` must name items that exist. A run of a part of the suite accepts names of items outside the selection.

!!! warning
    Do not use `[order]` for items that must run one after the other. Items of different profiles or environments, and sandboxed items, can run at the same time. Use a `chain` for items that must run in sequence, on one worker.

## [Groups](@id groups)

`[groups]` gives names to tag expressions, written as the `tags` keyword takes them:

```toml
[groups]
default = "!gpu"
gpu = "gpu"
quick = "fast && !slow"
```

`runtests(group = "gpu")`, or `RUNTESTS_GROUP=gpu`, runs the items that the expression selects. The header of the run says which group ran and what selected it: the keyword, the variable, or the `default` when nothing else selected. `RUNTESTS_GROUP` and `default` apply only to a call that selects nothing else. A path, a line, `name`, `tags` or `group` in the call replaces them.

Two names are reserved:

- `all` is the whole suite. You cannot declare it.
- `default` is what a run selects when nothing else selects. It is the group with this name, or the whole suite when no group has this name.

A name that differs from `all` or `default` only in case is an error. A group that `[groups]` does not declare is an error that lists the declared groups. An expression with a tag that no item carries is also an error. `Runtests.chores()` makes sure that every group is valid.

A declared group, including a declared `default`, makes the run a selection of the suite. Thus `[order]` can name items outside it. With no other filters, `group = "all"` runs the whole suite, as does `default` when no group of that name is declared. Adding a path, name or tag filter still narrows the run. This distinction also matters for the [retention of run states](@ref retention).

## Values that only a keyword sets

Some keywords of `runtests` are not configuration keys, so they cannot go in `[run]` or in an environment variable. These keywords are `name`, `tags`, `group`, `dry_run`, `replay`, `config` and `on_event`. `RUNTESTS_GROUP` is the exception: it selects a group when the call selects nothing else.
