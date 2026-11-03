# [Run states and history](@id history)

This page explains how Runtests remembers runs. Each run writes a run state: a binary file that records the run. The history of a suite is its set of run states. Runtests uses the history to plan the order of a run and to find the failing items.

## What a run state records

Every run writes its run state while it goes on, and prints the path at the end. Even an interrupted run leaves a record of the items that it completed. A run state records these facts:

- The outcome, the duration and the compilation time of each item, and every attempt.
- Each start and exit of a worker, with whether the worker timed out, crashed, or got a signal from outside.
- The commit, the Julia version and build, and the machine.
- The configuration, the selection and the group that made it, the profiles, the preferences and the random seed.
- The seed of each item, and a hash of its source. The hash tells an edited item from an item that only moved.
- The Julia flags that change compiled code, such as `--check-bounds` and `-O`.
- The environment variables `JULIA_*`, `RUNTESTS_*` and those of CI jobs, without names that look like credentials.
- The `Project.toml` and the `Manifest.toml` of the test environment.

Next to the run state, a directory with the same name and `.logs` in place of `.runstate` holds the logs. They hold captured item output, failure reports, [artifact evidence](@ref evidence), and the reason why a run ended before its first item. Under `logs = :eager`, ordinary item output is streamed and is not retained there; artifact producers still have their own captured output. [The files reference](@ref run-state-files) shows the layout.

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

An item that the suite no longer has stays on record, for a branch that still has it. It keeps no run state beyond the newest 20. The logs of a run state are deleted with it, and only with it.

[`Runtests.chores()`](@ref chores) also looks for deleted projects in the default run-state location. It removes this machine's run states after the newest file is at least 30 days old. A project in the system's temporary files has no 30-day wait. A project whose parent directory is missing or empty is left alone, as with a drive that is not mounted. Ordinary runs prune their own project's history; they do not sweep deleted projects. The sweep is disabled when `RUNTESTS_RUNSTATE_DIR` is set.

### Run states of other machines

The name of the machine is `RUNTESTS_HOST` when it is set. In other cases, it is the name that macOS gives the machine, or the hostname on other systems. The macOS name stays the same when the hostname changes with the network.

Normal retention leaves readable run states of other machines alone. The old-format cleanup below is an exception: files too old to read have no readable machine identity and can be deleted from the default location. A replay does not prune, and never deletes the run state that you give it.

### Formats

Runtests reads the current run state format and the preceding format. A run warns once about formats that it does not read. `Runtests.chores()` deletes formats older than those it can read in the default location. It does not delete old-format files from a custom `RUNTESTS_RUNSTATE_DIR`, which may hold other projects' records.

## Concurrent runs

An editor, a REPL and CI jobs can share one run state directory. Each run makes its own file, and writes it to disk at least every 30 seconds. The run states of active runs are never pruned.

A run is dead when its run state did not change for 90 seconds, or when its local process is known to have exited. A dead run counts as cancelled, and an item that was running in it counts as failing. A run whose setup fails finishes its run state as a run that ended before its first item. Thus no other run waits for it.

Machines that share run states over a network must agree on the time to within a minute. Each `RUNTESTS_HOST` must name only one machine at a time.

## Read a run state

`Runtests.read_run_state(path)` reads a run state file. It never throws. A file that is truncated, that a crashed run left, or that another version wrote gives as much as it can, or `nothing`. A broken record of an old run must not stop a new run.
