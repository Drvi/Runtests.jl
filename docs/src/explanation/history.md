# [Run states and history](@id history)

This page explains how Runtests remembers runs. A standalone run writes one run state, a binary record of that run. A combined run writes one for each package that took part, so each package keeps its own history. Runtests uses a suite's history to plan its next run and to find its failing items.

## What a run state records

A run writes its run states while it goes on, and prints their directory paths at the end. Even an interrupted run leaves a record of the items it completed. Each run state records these facts for its package:

- The outcome, the duration and the compilation time of each item, and every attempt.
- Each start and exit of a worker, with whether the worker timed out, crashed, or got a signal from outside.
- The commit, the Julia version and build, and the machine.
- The configuration, the selection and the group that made it, the profiles, the preferences and the random seed.
- The seed of each item, and a hash of its source. The hash tells an edited item from an item that only moved.
- The Julia flags that change compiled code, such as `--check-bounds` and `-O`.
- The environment variables `JULIA_*`, `RUNTESTS_*` and those of CI jobs, without names that look like credentials.
- The `Project.toml` and the `Manifest.toml` of the test environment.

Each package record lives as `run.runstate` in its own `<run>.rundata` directory. That directory also holds its logs: captured item output, failure reports, [artifact evidence](@ref evidence), and the reason why a run ended before its first item. Under `logs = :eager`, ordinary item output is streamed and is not kept there. Artifact producers still have their own captured output. [The files reference](@ref run-state-files) shows the layout.

## How Runtests uses the history

Only the run states in the run state directory count for the plan and for the failures. A run state in another place counts only when you give it as `replay`, and only for that call. Runtests orders the runs by their recorded start time, not by the file name or by when you downloaded a file.

For each item, the latest completed verdict decides whether the item is failing. The latest recorded duration of the item goes into the plan. A run that is still in progress gives durations at once. Its verdicts count for the failures and for the order only when it finishes, or when Runtests declares it dead.

Failed tests, errors, timeouts, a chain cut short by a lost worker, and an item left running when its coordinator died count as failures. A skip, an explicit cancellation, or a run that never reached the item leaves the previous verdict unchanged. A later passing retry replaces the failure for `runtestsf`; the earlier attempt's evidence still remains in that run's logs.

## Where run states live

By default, run states live under `runtests/runs/` in the Julia depot, in a directory for each project. Set `RUNTESTS_RUNSTATE_DIR` to use another directory. Several projects can share it. Runtests matches run states to a project by the UUID of the project. If there is no UUID, it uses the name of the project, then the name of the directory.

## [Retention](@id retention)

Runtests keeps the newest 20 run states of this machine. It deletes an older run state, except when the deletion changes what the run states say about an item of the suite. These facts of an item keep a run state:

- the latest verdict of the item, and when it was recorded,
- the seed of a failure,
- the newest duration and source hash of the item,
- whether the newest run that selected the item stopped before the item.

An item that the suite no longer has stays on record, for a branch that still has it. It keeps no run state beyond the newest 20. The directory of a run, with its logs, is deleted with its run state, and only with it.

[`Runtests.chores()`](@ref chores) also looks for deleted projects in the default run-state location. It removes this machine's run states after the newest file is at least 30 days old. A project in the system's temporary files has no 30-day wait. A project whose parent directory is missing or empty is left alone, as with a drive that is not mounted. Ordinary runs prune their own project's history; they do not sweep deleted projects. The sweep is disabled when `RUNTESTS_RUNSTATE_DIR` is set.

### Run states of other machines

The name of the machine is `RUNTESTS_HOST` when it is set. In other cases, it is the name that macOS gives the machine, or the hostname on other systems. The macOS name stays the same when the hostname changes with the network.

Retention leaves run states of other machines alone. A replay does not prune, and never deletes the run state that you give it.

### Formats

Runtests reads only run states in its own format. A run warns once when its run state directory holds run states of another version of Runtests. Runtests does not use those run states, and does not delete them.

## Concurrent runs

An editor, a REPL and CI jobs can share one run state directory. Each package record gets its own directory, and Runtests writes it to disk at least every 30 seconds. The run states of active runs are never pruned.

A run is dead when its run state did not change for 90 seconds, or when its local process is known to have exited. A dead run counts as cancelled, and an item that was running in it counts as failing. A run whose setup fails finishes its run state as a run that ended before its first item. Thus no other run waits for it.

Machines that share run states over a network must agree on the time to within a minute. Each `RUNTESTS_HOST` must name only one machine at a time.

## Read a run state

`Runtests.read_run_state(path)` reads a run state. `path` is the directory of a run or the `run.runstate` file in it. A truncated record, one left by a crashed run, or one written by another version gives as much as can be read, or `nothing`. Ordinary read and parse errors are suppressed so a broken old record does not stop a new run. An interrupt during parsing is rethrown; a file removed between reading and checking its modification time can cause a file-system error.
