# [Configuration](@id configuration-keys)

This page lists every configuration key of a run, every key of `test/TestItems.toml`, and the public environment variables for configuring Runtests. [Configure runs](@ref configuration) explains how to use them.

## Precedence

With `runtests`, each value comes from the first source that sets it, in this order:

1. the keyword of `runtests`,
2. the environment variable `RUNTESTS_<KEY>`,
3. the `[run]` table of `test/TestItems.toml`, or of the file that `config` names,
4. the default.

An unknown key, an unknown keyword or an incorrect value is an error before any item runs. A mistake in the call is an `ArgumentError`. A mistake in a file or in an environment variable is a `Runtests.ConfigError`.

For `runtests_mono`, the call and environment variables still take precedence. Run-wide keys then come from `[run]` at the workspace root; each package's own `[run]` supplies its other keys. A run-wide key in the `[run]` of another package has no effect. [What the packages share](@ref combined-settings) lists the run-wide keys.

## [Run keys](@id run-keys)

Each of these keys is a keyword of `runtests` and `runtests_mono`, a key of `[run]`, and an environment variable `RUNTESTS_<KEY>`.

| Key | Default | Value |
|:----|:--------|:------|
| `workers` | `"auto"` | The number of workers, or `"auto"`. Auto uses the number of CPUs, the threads of each worker, and either the recorded worker memory for the selected items (with 25% headroom against `memory_threshold`, asymmetrically regularized toward 4 GiB when only part of the selection has worker history, up to 16 workers once at least 80% of selected items are measured) or an assumed 4 GiB per worker (at most 8) when no worker history exists. `0` runs ordinary items in the calling process; sandboxed items, items of a named profile, and items in an environment directory still use workers. See [Run tests](@ref running). |
| `threads` | `"2,1"` | The `--threads` value of each worker, for example `"4"`, `"4,1"` or `"auto"`. |
| `timeout` | `1800` | Seconds for each attempt at an item. |
| `init_timeout` | `timeout` | Seconds for each `init` expression of a profile. |
| `test_end_timeout` | `timeout` | Seconds for each `test_end` expression of a profile. |
| `artifacts_timeout` | `timeout` | Seconds for all [producers](@ref evidence) of one failed attempt together. |
| `retries` | `0` | More attempts after a failure, from 0 to 126. |
| `failfast` | `false` | Stop the run when an item still fails after its allowed retries. |
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
| `seed` | random | The seed that each item combines with the name of its package and its own name. A run without a seed chooses one and prints it. |

A timeout must be positive and at most 2,147,483,647 seconds. A fraction rounds up to whole seconds. Work in the calling process with `workers = 0` cannot be forcibly timed out. In a TOML file or an environment variable, write a symbol as a string, for example `logs = "issues"`.

### logs

| Value | Effect |
|:------|:-------|
| `:issues` | Print the output of each item that did not pass, after its `DONE` line. |
| `:batched` | Print the output of every item when it ends. |
| `:eager` | Print the output of every item while it runs. On workers, non-empty item output is also lazily saved to per-item log files (omitted under `workers = 0` or when a temporary log directory cannot be created). |
| `:quiet` | Print no item output. Non-empty output stays in the log files of the run and can be read afterwards with [`Runtests.logs`](@ref logs). |

An interactive session with one worker or less uses `:eager` by default. All other runs use `:issues` by default. If Runtests cannot create a temporary directory for logs, it warns once, falls back to `logs = :eager` (without temporary log files), and disables `coverage`.

## Call keywords

These keywords of `runtests` are not configuration keys and cannot go in `[run]`. They have no environment-variable equivalent except `group` and `skip_environment`, as described below.

| Keyword | Value |
|:--------|:------|
| `name` | A `String` for an exact name, a `Regex` for a partial match, or a vector or set of exact names. |
| `tags` | A symbol, a vector of symbols that an item must carry all of, or a [tag expression](@ref tag-expressions). |
| `group` | The name of a group of `[groups]`, `"all"` or `"default"`. `RUNTESTS_GROUP` also selects a group when the call selects nothing else; see [Groups](@ref groups). |
| `dry_run` | `true` prints the plan and runs nothing. |
| `replay` | The path of a run state to run again. Reproduces the recorded items, settings, profiles, `[throttle]` limits, seeds, per-item policies (`timeout`, `retries`, `item_failfast`, `skip`, unless overridden), and exact per-worker slot order (no work-stealing or reordering). Combined with `dry_run = true`, prints a full diff against the current checkout. |
| `config` | The path of a file to read in place of `test/TestItems.toml`, relative to the current directory. The file must exist. |
| `skip_environment` | An [environment directory](@ref environments) that the run does not build, or a vector of them. Each name is the path of the directory from the root of the repository, for example `"test/qa"`, or `"lib/A/test/qa"` in a monorepo. The run records the selected items of the directory as skipped. A run that does not include the package of a named directory accepts the name without an error. A name that is no environment directory is an error. `RUNTESTS_SKIP_ENVIRONMENT` gives the names when the call gives none. See [Skip an environment](@ref skip-environment). |
| `on_event` | A function that the run calls with a [`Runtests.TestItemEvent`](@ref) when each attempt starts and ends. |
| `worker_init` | An expression, for example `:(using Plots)`, that is the `init` of the default profile in place of `test/testconfigs/worker_init.jl`. |
| `test_end` | An expression that is the `test_end` of the default profile in place of `test/testconfigs/test_end.jl`. |

`runtests_mono` also accepts `packages`, a list of package names or directories to include. It rejects `config`, because a combined run reads each package's own configuration file.

## TestItems.toml

`test/TestItems.toml` is optional. It has these tables, and no others. A file that `config` names has the same form. Only a combined run reads `[monorepo]`, from the file of the workspace root.

### [run]

The `[run]` table takes the [run keys](@ref run-keys) above. Write each key as the keyword, for example `timeout = 600`. Write a symbol as a string, for example `logs = "quiet"`.

### [order]

| Key | Value |
|:----|:------|
| `first` | A vector of exact item names. These items start first. |
| `last` | A vector of exact item names. These items start last. |

Every name in `[order]` must exist in the suite (even on a filtered run, which accepts existing items outside the current selection). Replays ignore recorded `[order]` names that have since been renamed or deleted.

### [groups]

Each key is the name of a group, and each value is a [tag expression](@ref tag-expressions). `all` is reserved and cannot be declared. `default` is the group that `runtestsd` and `runtestsd_mono` select. A name that differs from `all` or `default` only in case is an error.

### [throttle]

Each key is the name of a throttle, as the `throttle` keyword gives it. Each value is the limit of the throttle: the most items of the throttle that run at the same time, an integer from 1 to 2147483647. A throttle that the table does not name has the limit 1. A key must be a Julia identifier. Julia reads the key as it reads `:name`, so `"µ"` (the micro sign) and `"μ"` are the same key. In a combined run, the packages that use a throttle share it, and must give it the same limit. [Throttles](@ref throttles) explains the limits.

For example, three packages each have one item with `throttle = :db`, and the run has three workers. With `db = 2` in each package, two of the items start together, and the third starts when one of these ends. With `db = 1` in each package, or with no `[throttle]` in any of them, the items run one at a time. With `db = 2` in one package and no `[throttle]` in the others, the run stops with an error that names the different limits.

### [monorepo]

The workspace root's file can have this table. It selects the packages of a [combined run](@ref monorepos).

| Key | Default | Value |
|:----|:--------|:------|
| `packages` | every package of the workspace with a suite | A vector of directories or globs, relative to the workspace root, for example `["lib/*", "."]`. The packages that take part. |
| `isolated` | `[]` | A vector of directories or globs. These packages run in their own test environment, on workers of their own. |

An entry that matches no package, or names a directory outside the workspace, is an error.

### [Profiles](@id profile-keys)

Each profile is a table `[profiles.<name>]`. An item uses it with `profile = :<name>`. `[profiles.default]` configures the workers of every item without a `profile`, sandboxed or not. The name of a profile is a valid file name on Linux, macOS and Windows, and two names must not differ only in case. The code of a profile is not a key. It is in files of `test/testconfigs/`, as [The code of a profile](@ref profile-code-files) describes.

| Key | Default | Value |
|:----|:--------|:------|
| `julia_args` | `[]` | A vector of command-line flags for `julia`, for example `["--check-bounds=yes"]`. `--threads` or `-t` gives the threads of the workers of the profile, for example `["--threads=4"]`. Without it, the workers get the `threads` of the run. |
| `env` | `{}` | A table of environment variables for the workers, for example `{ JULIA_DEBUG = "Main" }`. |
| `preferences` | none | A TOML file, relative to the configuration file, whose contents go over the `LocalPreferences.toml` of the environment. The file must exist. |
| `precompile` | the whole environment | The packages that Runtests precompiles for the workers of the profile before they start, each with its dependencies, for example `["MyPackage", "Test"]`. `[]` precompiles none. A worker compiles each other package when an item loads it. A name that is not a package of the environment of the items is an error. See [Precompilation](@ref profile-precompile). |
| `monorepo_default` | `false` | Only in the `test/TestItems.toml` of a workspace root. `true` shares the profile with the packages of the workspace, in their own runs and in combined runs. See [Share a profile](@ref shared-profiles). |

### [The code of a profile](@id profile-code-files)

| File | Value |
|:-----|:------|
| `test/testconfigs/worker_init.jl` | The `init` of the default profile: Julia code that runs once in each worker before its first item, at the top level of `Main`. Items do not see what it defines or imports. It runs in the root of the package, or in the workspace root for a [shared profile](@ref shared-profiles). Under `workers = 0`, it runs in the process that calls `runtests`, in the same directory. |
| `test/testconfigs/test_end.jl` | The `test_end` of the default profile: Julia code that runs after each item, in a new module with `Test` and the package in scope. It does not see the variables of the item. A failure does not change the result of the item: the run prints a `HOOK` line for it. |
| `test/testconfigs/<name>/worker_init.jl`, `test/testconfigs/<name>/test_end.jl` | The `init` and the `test_end` of the profile `<name>`, which `[profiles]` must declare. |

Each file is optional. Any other entry of `test/testconfigs/` is an error, except a hidden one. The keywords `worker_init` and `test_end` of `runtests` and `runtests_mono` give the code of the default profile in place of its files. A profile that the workspace shares takes its code from the `test/testconfigs/` of the workspace root.

## [Environment variables](@id environment-variables)

These environment variables configure Runtests:

| Variable | Meaning |
|:---------|:--------|
| `RUNTESTS_<KEY>` | A [run key](@ref run-keys), for example `RUNTESTS_WORKERS=4`, `RUNTESTS_RETRIES=1` or `RUNTESTS_SEED=0x1234`. A true-or-false key takes `true`, `false`, `1`, `0`, `yes` or `no`. A keyword replaces it, and it replaces `[run]`. |
| `RUNTESTS_GROUP` | The group to run when a call selects nothing else. An empty value counts as unset. |
| `RUNTESTS_SKIP_ENVIRONMENT` | The environment directories that the run does not build when the call gives no `skip_environment`, with commas between the names. An empty value counts as unset. |
| `RUNTESTS_RUNSTATE_DIR` | The directory of the run states, which holds a directory `<run>.rundata` for each run. The default is `runtests/runs/` in the Julia depot, with a directory for each project. |
| `RUNTESTS_HOST` | The name of this machine in the run states. The default is the macOS machine name, or the hostname on other systems. |
| `RUNTESTS_ARTIFACT_DIR` | A directory into which a run copies its `<run>.rundata` directory, with its run state and logs, when it ends. A combined run puts each package's directory under a subdirectory named for the package. If a run fails before opening its run state, it writes `setup-<runid>.log` there instead. |

Runtests sets these variables in each worker. Do not set them yourself:

| Variable | Meaning |
|:---------|:--------|
| `RUNTESTS_RUN_ID` | The ID of the run, set for each worker. Subprocesses of a worker inherit it. |
| `RUNTESTS_WORKER` | The number of the worker, as in `w1`. |
