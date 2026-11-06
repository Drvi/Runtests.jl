# [Run on CI](@id ci)

This page tells you how to run a suite on CI and how to split it over jobs. It also tells you how to keep the history of runs between jobs. The examples use GitHub Actions.

## Run the tests

On CI, run the tests with `Pkg.test`, as for any package. `julia-actions/julia-runtest` does this:

```yaml
- uses: julia-actions/setup-julia@v2
- uses: julia-actions/cache@v2
- uses: julia-actions/julia-buildpkg@v1
- uses: julia-actions/julia-runtest@v1
```

Outside a terminal, the run prints a progress line every `monitor_interval` seconds, 30 by default. It also prints one after every 10 finished items, but no sooner than 5 seconds after the last one.

## Configure a job with environment variables

Each run setting can come from an environment variable named `RUNTESTS_` and the key in capitals. A job sets its configuration in this way, without a change to the project:

```yaml
- uses: julia-actions/julia-runtest@v1
  env:
    RUNTESTS_WORKERS: 4
    RUNTESTS_RETRIES: 1
```

A keyword of `runtests` replaces the variable, and the variable replaces `test/TestItems.toml`. The header of the run names each variable that set a value. [The configuration reference](@ref environment-variables) lists all variables.

## Split the suite over jobs

Declare [groups](@ref groups) in `test/TestItems.toml`, and give each job of the matrix a group in `RUNTESTS_GROUP`:

```yaml
strategy:
  matrix:
    group: [default, gpu]
steps:
  - uses: julia-actions/julia-runtest@v1
    env:
      RUNTESTS_GROUP: ${{ matrix.group }}
```

`RUNTESTS_GROUP` applies only when `runtests` selects nothing else. An empty `RUNTESTS_GROUP` counts as unset. Thus a job whose `matrix.group` is empty runs what a run selects by default.

## [Keep the history of runs](@id ci-history)

Runtests plans each run from the run states of earlier runs. On CI, each job starts on a new machine, so the job must restore the run states of earlier jobs. Cache the run states between jobs. Upload the run states and logs of each job as an artifact.

Each run keeps its run state and its logs in a directory of its own, `<run>.rundata`. The run state is the file `run.runstate` in that directory.

This example is for a matrix with `os`, `version` and `group`:

```yaml
- uses: actions/cache/restore@v4
  with:
    path: ${{ runner.temp }}/runtests/*.rundata/run.runstate
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}
    restore-keys: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-
- uses: julia-actions/julia-runtest@v1
  env:
    RUNTESTS_GROUP: ${{ matrix.group }}
    RUNTESTS_RUNSTATE_DIR: ${{ runner.temp }}/runtests
    RUNTESTS_HOST: ci-${{ matrix.os }}-${{ matrix.version }}
    RUNTESTS_ARTIFACT_DIR: ${{ runner.temp }}/runtests-artifact
- uses: actions/cache/save@v4
  if: always()
  with:
    path: ${{ runner.temp }}/runtests/*.rundata/run.runstate
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}
    path: ${{ runner.temp }}/runtests-artifact
```

The example uses these variables:

- `RUNTESTS_RUNSTATE_DIR` is the directory that holds the directories of the runs.
- `RUNTESTS_HOST` is the name of the machine in the run states.
- `RUNTESTS_ARTIFACT_DIR` is a directory into which each run copies its own directory when it ends. The run also copies it after a failure or an interrupt.

### The cache

The cache holds the run states and not the logs, because the next job plans from the run states only. Use these rules for the cache:

- Name the run states with `*.rundata/run.runstate` in `path`. The cache then holds each run's directory with the run state only.
- Give the restore step and the save step the same `path`. The cache finds an entry by its key and by its paths. A restore with other paths does not find the entry.
- Use a unique key for each run, and `restore-keys` to get the most recent cache.
- Save the cache also when the tests fail, with `if: always()`. Then the next job sees those failures.
- Put each dimension of the matrix in the key. Two jobs of one workflow run with the same key both save, and the cache keeps only one of them.

!!! warning
    Do not name the directories, `*.rundata`, in `path` with a pattern such as `!**/*.log` to exclude the logs. The cache archives a directory as a whole, and the exclusion has no effect.

In a monorepo, each job can test one package with the `project` input of `julia-runtest`. Then add the package to the key and to the name of the artifact, as the example adds the group.

### The machine name

A stable `RUNTESTS_HOST` makes the restored run states part of the normal [retention](@ref retention). Without it, each job has a new hostname, and run states of other machines collect. On CI without `RUNTESTS_HOST`, a run warns when its directory holds run states of other machines.

### [The artifact](@id ci-artifact)

The artifact holds the directory of this job's run: its run state, its logs and its [failure evidence](@ref evidence). It holds none of the history. On your machine, run the failures of a downloaded run again:

```julia
Runtests.runtestsf(replay = "path/to/the.rundata")
```

When items fail, the closing block of the run prints this command with the name of the copied directory.

`if: failure()` uploads nothing when a retry passes. To also keep the evidence of a failed attempt that a later attempt repaired, use `if: always()`.

## Coverage on CI

`Pkg.test(coverage = true)` works with Runtests, and `julia-runtest` uses it by default. Runtests can also merge the counts of the workers into one `lcov.info` file. [Measure coverage](@ref coverage) tells you about both ways.

## [Template expansions on CI](@id ci-templates)

To make sure that the committed [expansions](@ref templates) agree with the current data, run `chores` and check for changes under `test/`. The Julia environment used by this step must already be instantiated and contain Runtests. This example uses `test/Project.toml`; use the environment where your project makes Runtests available if it has no test project:

```yaml
- run: julia --project=test -e 'using Runtests; Runtests.chores()'
- name: Check generated test files
  shell: bash
  run: |
    changes=$(git status --porcelain --untracked-files=all -- test/)
    if [ -n "$changes" ]; then
      printf '%s\n' "$changes"
      exit 1
    fi
```

The second step fails for modified, deleted or new untracked files under `test/`. Unlike `git diff`, it also catches a newly generated expansion that was never committed. Generated test files must not be ignored by git. `chores` can also update setup packages, so commit those changes together with the expansions.
