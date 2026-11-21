# [Files](@id files)

This page describes run-state bundles and files that Runtests writes. [Syntax](@ref syntax) describes the files it discovers under `test/`.

## [Run state files](@id run-state-files)

A standalone run keeps its run state and logs in a directory of its own, `<run>.rundata`, in the run state directory. A combined run writes one such directory for each participating package; each contains only that package's items:

```text
<run>.rundata/
  run.runstate              # the record of the run
  item_7_1.log
  item_7_1.failure.txt
  item_7_1.artifacts/
    files/                  # Runtests.artifacts_dir()
    producer_1/             # the files of the first producer
    producer_2/
  item_7_1.artifacts.log    # what the producers printed, their errors, and their times
  events/                   # created only when `on_event` is passed
```

The name `<run>` is the start time of the run in microseconds and the ID of its process, for example `1790247276123456-96211`. If a directory with that name exists, the run adds `_2`, `_3` and so on to the name. The names of the logs are `item_<i>_<attempt>`, where `<i>` is the number of the item and `<attempt>` is the attempt.

| File | Contents |
|:-----|:---------|
| `run.runstate` | The binary record of the run. `Runtests.read_run_state` reads it, or the directory of the run. |
| `item_<i>_<a>.log` | Captured output of the attempt. Worker runs under `logs = :eager` also lazily save nonempty item output here (omitted under `workers = 0` or when a temporary log directory cannot be created). Use [`Runtests.logs`](@ref logs) to read captured item logs (including from `logs = :quiet` runs). |
| `item_<i>_<a>.failure.txt` | The failure report of an attempt that did not pass. |
| `item_<i>_<a>.artifacts/files/` | The outputs that the item wrote to `Runtests.artifacts_dir()`. |
| `item_<i>_<a>.artifacts/producer_<k>/` | The files that the producer `k` wrote. |
| `item_<i>_<a>.artifacts.log` | What the producers printed, their errors and their times. |
| `events/` | Directory passed to `on_event` callbacks via `event.events_dir` (created only when `on_event` is supplied). |
| `setup.log` | The error that stopped a run before its first item. |

Runtests deletes an empty log file at the end of the run. When Runtests deletes a run state, it deletes the directory of the run with it. Another editor run does not remove the logs, and neither does stopping the server. If the system temporary directory is not writable, Runtests warns once, falls back to `logs = :eager`, disables `coverage`, and skips scratch directories. [Run states and history](@ref history) tells which run states Runtests keeps.

## The run state directory

By default, the run state directory is `runtests/runs/<project>-<hash>/` in the first Julia depot, for example `~/.julia/runtests/runs/MyPackage-8db4f545/`. `<project>` is the name of the project, and `<hash>` is a hash of the path of the project. Thus each checkout has its own directory. `RUNTESTS_RUNSTATE_DIR` names another directory, which several projects can share. Several processes can use one run state directory at the same time. Each run makes a new directory for itself, and no two runs get the same directory. Beside the `<run>.rundata` directories, Runtests keeps an `envcache/` directory caching the resolved test environment across processes (keyed by file content hashes of project/test/workspace files, path-dependency hashes, installed registry metadata, Julia version, depot artifact state, cached file CRCs, and manifest package presence, and removed automatically when `chores` sweeps a gone checkout). [Run states and history](@ref history) explains which run states Runtests keeps.

## The artifact directory

When `RUNTESTS_ARTIFACT_DIR` is set, each run copies its directory, `<run>.rundata`, into that directory when it ends. It also does this after a failure or an interrupt. If a run fails before opening its run state, it writes `setup-<runid>.log` directly into `RUNTESTS_ARTIFACT_DIR`. A run of several packages copies the directory of each package into a directory with the name of the package. The closing block names the artifact directory on the `copied to` line.

## Files in the package

Runtests also writes these files in a package or workspace:

- `lcov.info` at the package root for a standalone run, or at the workspace root for a combined run, when `coverage = true`. [Measure coverage](@ref coverage) describes the file.
- the expansion of each template, `test/<name>_tests.jl`, from `Runtests.chores()`,
- `test/testsetups/<Name>/Project.toml` and `test/testsetups/<Name>/src/<Name>.jl`, from `Runtests.chores()` when it converts a setup into a package.

`Runtests.chores_mono()` performs the same file-writing chores for each participating package. Commit the files that either chores command writes.
