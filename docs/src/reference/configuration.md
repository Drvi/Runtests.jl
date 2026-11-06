# [Configuration](@id configuration-keys)

This page lists every configuration key of a run, every key of `test/TestItems.toml`, and the public environment variables for configuring Runtests. [Configure runs](@ref configuration) explains how to use them.

## Precedence

A run takes each value from the first source that sets it, in this order:

1. the keyword of `runtests`,
2. the environment variable `RUNTESTS_<KEY>`,
3. the `[run]` table of `test/TestItems.toml`, or of the file that `config` names,
4. the default.

An unknown key, an unknown keyword or an incorrect value is an error before any item runs. A mistake in the call is an `ArgumentError`. A mistake in a file or in an environment variable is a `Runtests.ConfigError`.

## [Run keys](@id run-keys)

Each of these keys is a keyword of `runtests`, a key of `[run]`, and an environment variable `RUNTESTS_<KEY>`.

| Key | Default | Value |
|:----|:--------|:------|
| `workers` | `"auto"` | The number of workers, or `"auto"`. Auto uses the number of CPUs, the threads of each worker and an assumed 4 GiB for each worker, at most 8. `0` runs ordinary items in the calling process; sandboxed items and items of a named profile still use workers. See [Run tests](@ref running). |
| `threads` | `"2,1"` | The `--threads` value of each worker, for example `"4"`, `"4,1"` or `"auto"`. |
| `timeout` | `1800` | Seconds for each attempt at an item. |
| `init_timeout` | `timeout` | Seconds for each `init` expression of a profile. |
| `test_end_timeout` | `timeout` | Seconds for each `test_end` expression of a profile. |
| `artifacts_timeout` | `timeout` | Seconds for all [producers](@ref evidence) of one failed attempt together. |
| `retries` | `0` | More attempts after a failure, from 0 to 126. |
| `failfast` | `false` | Stop the run when an item or chain still fails after its allowed retries. |
| `item_failfast` | `failfast` | Stop each item at its first failed test. |
| `logs` | `:issues` | Which item output the run prints: `:issues`, `:batched`, `:eager` or `:quiet`. See below. |
| `verbose` | `false` | Include passing testsets in the result summary. Item output is controlled by `logs`. |
| `memory_threshold` | `0.9` | The fraction of machine memory in use at which new items wait. Greater than 0, at most 1. |
| `monitor` | `true` | Monitor the memory and print progress. |
| `monitor_interval` | `30` | Seconds between progress lines when the output is not a terminal. `0` prints at each sample, five times a second. |
| `full_stacktraces` | `false` | Keep the frames of Runtests in the stack traces of failures. |
| `full_names` | `false` | Print long names in full, in place of a unique prefix. |
| `testset_name` | `"Runtests"` | The name of the testset that the run returns. |
| `coverage` | `false` | Merge line coverage into `lcov.info`. See [Measure coverage](@ref coverage). |
| `seed` | random | The seed that each item combines with its name. A run without a seed chooses one and prints it. |

A timeout must be positive and at most 2,147,483,647 seconds. A fraction rounds up to whole seconds. Work in the calling process with `workers = 0` cannot be forcibly timed out. In a TOML file or an environment variable, write a symbol as a string, for example `logs = "issues"`.

### logs

| Value | Effect |
|:------|:-------|
| `:issues` | Print the output of each item that did not pass, after its `DONE` line. |
| `:batched` | Print the output of every item when it ends. |
| `:eager` | Print the output of every item while it runs, without saving it to per-item log files. |
| `:quiet` | Print no item output. The output stays in the log files of the run. |

An interactive session with one worker or less uses `:eager` by default. All other runs use `:issues` by default.

## Call keywords

These keywords of `runtests` are not configuration keys and cannot go in `[run]`. They have no environment-variable equivalent except `group`, as described below.

| Keyword | Value |
|:--------|:------|
| `name` | A `String` for an exact name, a `Regex` for a partial match, or a vector or set of exact names. |
| `tags` | A symbol, a vector of symbols that an item must carry all of, or a [tag expression](@ref tag-expressions). |
| `group` | The name of a group of `[groups]`, `"all"` or `"default"`. `RUNTESTS_GROUP` also selects a group when the call selects nothing else; see [Groups](@ref groups). |
| `dry_run` | `true` prints the plan and runs nothing. |
| `replay` | The path of a run state to run again. |
| `config` | The path of a file to read in place of `test/TestItems.toml`, relative to the current directory. The file must exist. |
| `on_item` | A function that the run calls with a [`Runtests.ItemEvent`](@ref) when each attempt starts and ends. |

## TestItems.toml

`test/TestItems.toml` is optional. It has these tables, and no others. A file that `config` names has the same form. Only a combined run reads `[monorepo]`, from the file of the workspace root.

### [run]

The `[run]` table takes the [run keys](@ref run-keys) above. Write each key as the keyword, for example `timeout = 600`. Write a symbol as a string, for example `logs = "quiet"`.

### [order]

| Key | Value |
|:----|:------|
| `first` | A vector of exact item names. These items start first. |
| `last` | A vector of exact item names. These items start last. |

On a run of the whole suite, each name must be an item of the suite. A run of a part of the suite accepts names of items outside the selection.

### [groups]

Each key is the name of a group, and each value is a [tag expression](@ref tag-expressions). `all` is reserved and cannot be declared. `default` is what a run selects when nothing else selects. A name that differs from `all` or `default` only in case is an error.

### [monorepo]

The workspace root's file can have this table. It selects the packages of a [combined run](@ref monorepos).

| Key | Default | Value |
|:----|:--------|:------|
| `packages` | every package of the workspace with a suite | A vector of directories or globs, relative to the workspace root, for example `["lib/*", "."]`. The packages that take part. |
| `isolated` | `[]` | A vector of directories or globs. These packages run in their own test environment, on workers of their own. |

An entry that matches no package, or names a directory outside the workspace, is an error.

### [Profiles](@id profile-keys)

Each profile is a table `[profiles.<name>]`. An item uses it with `profile = :<name>`. `[profiles.default]` configures the workers of every item without a `profile`, sandboxed or not.

| Key | Default | Value |
|:----|:--------|:------|
| `julia_args` | `[]` | A vector of command-line flags for `julia`, for example `["--check-bounds=yes"]`. |
| `threads` | the `threads` of the run | The `--threads` value of the workers of the profile. |
| `env` | `{}` | A table of environment variables for the workers, for example `{ JULIA_DEBUG = "Main" }`. |
| `init` | none | Julia code, as a string, that runs once in each worker before its first item. It runs in the root of the package, or in the workspace root for a [shared profile](@ref shared-profiles). |
| `test_end` | none | Julia code, as a string, that runs after each item. A failure counts toward the item. |
| `preferences` | none | A TOML file, relative to the configuration file, whose contents go over the `LocalPreferences.toml` of the environment. The file must exist. |
| `monorepo_default` | `false` | Only in the `test/TestItems.toml` of a workspace root. `true` shares the profile with the packages of the workspace, in their own runs and in combined runs. See [Share a profile](@ref shared-profiles). |

## [Environment variables](@id environment-variables)

These environment variables configure Runtests:

| Variable | Meaning |
|:---------|:--------|
| `RUNTESTS_<KEY>` | A [run key](@ref run-keys), for example `RUNTESTS_WORKERS=4`, `RUNTESTS_RETRIES=1` or `RUNTESTS_SEED=0x1234`. A true-or-false key takes `true`, `false`, `1`, `0`, `yes` or `no`. A keyword replaces it, and it replaces `[run]`. |
| `RUNTESTS_GROUP` | The group to run when a call selects nothing else. An empty value counts as unset. |
| `RUNTESTS_RUNSTATE_DIR` | The directory of the run states. The default is `runtests/runs/` in the Julia depot, with a directory for each project. |
| `RUNTESTS_HOST` | The name of this machine in the run states. The default is the macOS machine name, or the hostname on other systems. |
| `RUNTESTS_ARTIFACT_DIR` | A directory into which each run copies its run state and its logs when it ends. |

Runtests sets these variables in each worker. Do not set them yourself:

| Variable | Meaning |
|:---------|:--------|
| `RUNTESTS_RUN_ID` | The ID of the run. `Runtests.in_test_run()` is `true` when it is set. Subprocesses of a worker inherit it. |
| `RUNTESTS_WORKER` | The number of the worker, as in `w1`. |
