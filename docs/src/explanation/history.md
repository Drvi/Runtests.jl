# [Run states and history](@id history)

This page explains how Runtests remembers runs. A standalone run writes one run state, a binary record of that run. A combined run writes one for each package that took part, so each package keeps its own history. Runtests uses a suite's history to plan its next run and to find its failing items.

## What a run state records

A run writes its run states while it goes on, and prints their directory paths at the end. Even an interrupted run leaves a record of the items it completed. Each run state records these facts for its package:

- How the run ended.
- The outcome, the duration and the compilation time of each item, and every attempt.
- Each start and exit of a worker, with whether the worker timed out, crashed, or got a signal from outside.
- The commit, the Julia version and build, and the machine. The record also says if the checkout had changes that the commit does not hold: a changed file that git tracks, or a Julia or TOML file under the project that git does not track or ignore.
- The configuration, the selection and the group that made it, the profiles, the preferences and the random seed.
- The seed of each item, and a hash of its source. The hash tells an edited item from an item that only moved.
- The Julia flags that change compiled code, such as `--check-bounds` and `-O`.
- The environment variables `JULIA_*`, `RUNTESTS_*` and those of CI jobs, without names that look like credentials.
- The `Project.toml` and `Manifest.toml` of the test environment, per-worker environment snapshots (`Project.toml`, `Manifest.toml`, and `LocalPreferences.toml` for each distinct worker environment), and each item's resolved policy (`timeout`, `retries`, `item_failfast`, `skip`).

Each package record lives as `run.runstate` in its own `<run>.rundata` directory. That directory also holds its logs: captured item output, failure reports, [artifact evidence](@ref evidence), and the reason why a run ended before its first item. On workers, even `logs = :eager` lazily saves nonempty item output to `item_<i>_<a>.log` (only `workers = 0` or an unwritable temporary directory omits per-item log files). Use [`Runtests.logs`](@ref logs) to read captured logs from any recorded run (including `logs = :quiet` runs). [The files reference](@ref run-state-files) shows the layout.

## How Runtests uses the history

Only the run states in the run state directory count for the plan and for the failures. A run state in another place counts only when you give it as `replay`, and only for that call. Runtests orders the runs by their recorded start time, not by the file name or by when you downloaded a file. As one exception, when a fresh checkout has no run states of its own (and `RUNTESTS_RUNSTATE_DIR` is unset and the package has a UUID), Runtests borrows item durations and worker cold-start costs — never failures or source hashes — from the newest sibling checkout with the same UUID.

For each item, the latest completed verdict decides whether the item is failing. The latest recorded duration of the item goes into the plan. A run that is still in progress gives durations at once. Its verdicts count for the failures and for the order only when it finishes, or when Runtests declares it dead.

A run state records how its run ended. The run finished, or one of these stopped it: a failure under `failfast`, an interrupt, a stall, the exit of its process, a failed `init` of a profile, a worker that could not start, its setup, or an error of the run itself. The run writes its ending as soon as it knows it, before it stops its workers. A run state without an ending is of a run in progress, or of a run whose coordinator died. The run writes its end time when it closes the file, after the last event of its workers. Until then the run counts as in progress, also after a failure under `failfast`, and pruning keeps it.

The ending tells what an item that did not finish means. Failed tests, errors and timeouts count as failures. An item left running counts as a failure when its run stopped as hung, or when its coordinator died. In a run that stopped in another way, an item left running has no verdict. A skip leaves the previous verdict unchanged without scheduling the item early. A cancellation or a run that never reached the item also leaves the previous verdict unchanged, and the next run starts such an item early. Any later passing verdict — whether a passing retry in the same run or a pass in a subsequent run (regardless of seed or selection) — resolves a recorded failure for `runtestsf`. The evidence of the earlier failed attempt still remains in the logs of its run.

## Where run states live

By default, run states live under `runtests/runs/` in the Julia depot, in a directory for each project. Set `RUNTESTS_RUNSTATE_DIR` to use another directory. Several projects can share it. Runtests matches run states to a project by the UUID of the project. If there is no UUID, it uses the name of the project, then the name of the directory.

## [Retention](@id retention)

A run prunes the run states of its project when it ends, and [`Runtests.chores()`](@ref chores) prunes them in the same way. Pruning keeps the newest 20 run states of this machine, and every run that is still in progress. It deletes an older run state of this machine only if these facts stay the same for each item that the suite has:

- the latest verdict of the item, and when it was recorded,
- the seed of a failure,
- the newest duration and source hash of the item,
- whether the newest run that selected the item stopped before the item.

Thus pruning never deletes a run state that holds the newest of these facts about an item of the suite. Each item holds back at most four run states. A project therefore keeps at most the newest 20 run states of this machine, plus four for each item of the suite, plus the runs in progress.

An item that the suite no longer has stays on record, for a branch that still has it. It holds back no run state beyond the newest 20. A run state keeps the whole directory of its run, with the logs and evidence of all its items. The directory is deleted with the run state, and only with it.

### [Deleted checkouts](@id deleted-checkouts)

A checkout is one copy of a project on disk, at one path. In the default location, each checkout has its own directory of run states, named for the project and a hash of its path. A checkout is deleted when its path no longer exists, for example after you remove a clone, or after a test suite removes a temporary package. No run reads its run states again.

[`Runtests.chores()`](@ref chores) deletes this machine's run states of deleted checkouts, and their directories, 30 days after the newest of these run states. A checkout in the system's temporary files has no 30-day wait. A checkout whose parent directory is missing or empty is left alone, as with a drive that is not mounted. A run does not look for deleted checkouts. When `RUNTESTS_RUNSTATE_DIR` is set, `chores` does not look for them either.

### Run states of other machines

The name of the machine is `RUNTESTS_HOST` when it is set. In other cases, it is the name that macOS gives the machine, or the hostname on other systems. The macOS name stays the same when the hostname changes with the network.

Retention never deletes a run state of another machine. `Runtests.chores()` reports how many of them the project has, from how many machines, and their size. A replay does not prune, and never deletes the run state that you give it.

### Formats

Runtests reads only run states in its own format. A run warns once when its run state directory holds run states of another version of Runtests. Runtests does not use those run states, and does not delete them.

## Concurrent runs

An editor, a REPL and CI jobs can share one run state directory. Each package record gets its own directory, and Runtests writes it to disk at least every 30 seconds. The run states of active runs are never pruned.

A run is dead when its run state did not change for 90 seconds, or when its local process is known to have exited. A dead run counts as cancelled, and an item that was running in it counts as failing. A run whose setup fails finishes its run state as a run that ended before its first item. Thus no other run waits for it.

Machines that share run states over a network must agree on the time to within a minute. Each `RUNTESTS_HOST` must name only one machine at a time.

## Read a run state

`Runtests.read_run_state(path)` reads a run state. `path` is the directory of a run or the `run.runstate` file in it. A truncated record or one left by a crashed run gives as much as can be read, or `nothing`; a record written by another format version returns `nothing`. Ordinary read and parse errors (including concurrent deletion by another process) are suppressed and return `nothing` so a broken old record does not stop a new run. An interrupt during parsing is rethrown. Use [`Runtests.logs`](@ref logs) to print the captured item logs stored alongside a run state.
