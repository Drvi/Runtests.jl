# [Files](@id files)

This page lists the files that Runtests reads and writes outside `test/`. [Syntax](@ref syntax) lists the files under `test/`.

## [Run state files](@id run-state-files)

Each run writes a run state file and a directory of logs, next to each other, in the run state directory:

```text
<run>.runstate
<run>.logs/
  item_7_1.log
  item_7_1.failure.txt
  item_7_1.artifacts/
    files/                  # Runtests.artifacts_dir()
    producer_1/             # the files of the first producer
    producer_2/
  item_7_1.artifacts.log    # what the producers printed, their errors, and their times
```

The name `<run>` is the start time of the run in microseconds and the ID of its process, for example `1790247276123456-96211`. The names in the logs directory are `item_<i>_<attempt>`, where `<i>` is the number of the item and `<attempt>` is the attempt.

| File | Contents |
|:-----|:---------|
| `<run>.runstate` | The binary record of the run. `Runtests.read_run_state` reads it. |
| `item_<i>_<a>.log` | Captured output of the attempt. `logs = :eager` streams this output without saving a per-item log. |
| `item_<i>_<a>.failure.txt` | The failure report of an attempt that did not pass. |
| `item_<i>_<a>.artifacts/files/` | The outputs that the item wrote to `Runtests.artifacts_dir()`. |
| `item_<i>_<a>.artifacts/producer_<k>/` | The files that the producer `k` wrote. |
| `item_<i>_<a>.artifacts.log` | What the producers printed, their errors and their times. |

Runtests deletes an empty log file at the end of the run, and the logs directory when it is empty. The logs directory is deleted with its run state. Starting another editor run or stopping the server does not remove these persistent logs; see [Run states and history](@ref history).

## The run state directory

By default, the run state directory is `runtests/runs/<project>-<hash>/` in the first Julia depot, for example `~/.julia/runtests/runs/MyPackage-8db4f545/`. `<project>` is the name of the project, and `<hash>` is a hash of the path of the project. Thus each checkout has its own directory. `RUNTESTS_RUNSTATE_DIR` names another directory, which several projects can share. [Run states and history](@ref history) explains which run states Runtests keeps.

## The artifact directory

When `RUNTESTS_ARTIFACT_DIR` is set, each run copies its run state and its logs directory into that directory when it ends. It also does this after a failure or an interrupt. The closing block names the directory on the `copied to` line.

## Files in the package

Runtests writes these files in the package:

- `lcov.info` at the root of the package, from a run with `coverage = true`. [Measure coverage](@ref coverage) describes the file.
- the expansion of each template, `test/<name>_tests.jl`, from `Runtests.chores()`,
- `test/testsetups/<Name>/Project.toml` and `test/testsetups/<Name>/src/<Name>.jl`, from `Runtests.chores()` when it converts a setup into a package.

Commit the files that `chores` writes.
