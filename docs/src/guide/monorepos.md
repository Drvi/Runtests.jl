# [Run the suites of a monorepo](@id monorepos)

A monorepo is a repository that holds several Julia packages, for example a root package and packages under `lib/`. `Runtests.runtests_mono` runs the test suites of these packages in one run: one plan, one set of workers and one report. Items of different packages share workers when their workers start the same way. A combined run needs Julia 1.12 or later.

## Set up the workspace

A combined run runs the packages of a Julia workspace. All members of a workspace share one manifest. The root `Project.toml` lists each package and the test project of each package under `[workspace]`:

```toml
[workspace]
projects = ["lib/A", "lib/A/test", "lib/B", "lib/B/test"]
```

A package can also list its own `test` under a `[workspace]` of its own. The root then lists only the package.

Each package that takes part must have a `test/Project.toml` (or `test/JuliaProject.toml`), and that project must be a member of the workspace. Tests that use only `[extras]` and `[targets]` cannot take part. The workspace manifest must hold Runtests: add Runtests to `[deps]` of a test project or of the root project, and resolve the workspace.

## Run the tests

At the REPL, activate a project of the workspace that has Runtests in its `[deps]`, then call `Runtests.runtests_mono()`. It finds the workspace root from the active project. For example, from the workspace root when `lib/A/test/Project.toml` declares Runtests:

```julia
using Pkg
Pkg.activate("lib/A/test")
Pkg.instantiate()
using Runtests
Runtests.runtests_mono()
```

To run the combined suites with `Pkg.test` of a root package, that package's own test environment must also contain Runtests. Put this in its `test/runtests.jl`:

```julia
using Runtests
Runtests.runtests_mono()
```

Runtests instantiates the workspace once. Then it writes one environment for the shared workers. This environment holds the test dependencies of all packages, in the versions of the workspace manifest, and Julia loads it without a resolve.

`runtests_mono` takes the selections of `runtests`. `name`, `tags` and `group` select within each package. A group or a tag that only some packages have is no error. A path selects within the package that holds it. The keyword `packages` takes package names, or directories relative to the workspace root, and runs only those packages:

```julia
Runtests.runtests_mono(; packages = ["A", "lib/B"], group = "fast")
```

## Choose the packages

By default, every package of the workspace that has a suite takes part. A table `[monorepo]` in `test/TestItems.toml` of the workspace root changes this:

```toml
[monorepo]
packages = ["lib/*", "."]
isolated = ["lib/Legacy"]
```

`packages` lists the packages that take part, as directories or globs relative to the root. `isolated` lists packages that run in their own test environment, on workers of their own. If two workspace members have the same package name, use `packages` to leave one out; a combined run cannot identify both by name. The header of the run lists the packages, names the isolated ones, and says why each other package of the workspace does not take part.

## [What the packages share](@id combined-settings)

Two profiles share workers when their workers start the same way: the same flags, threads, environment variables, preferences and environment. This is true for profiles of one package and for profiles of two packages. A profile with an `init` keeps workers of its own package, because `init` runs in the root of its package. A [shared profile](@ref shared-profiles) is the exception. An environment directory and an isolated package also keep workers of their own.

Each item runs in the root of its own package and imports its own package. It runs under the profiles, setups and settings of its own package. `test_end` runs under the `test_end_timeout` of the package of the item.

The settings of the run itself come from the call, the `RUNTESTS_` variables and `[run]` of the workspace root, in that order. These settings are `workers`, `memory_threshold`, `logs`, `verbose`, `monitor`, `monitor_interval`, `full_stacktraces`, `full_names`, `testset_name`, `coverage`, `seed` and `failfast`. Such a setting in the `[run]` of another package has no effect. The other settings belong to each package. A keyword or a variable gives every package its value. Otherwise each package keeps the value of its own file.

## [Share a profile](@id shared-profiles)

To give the packages of a workspace one profile, `init` included, declare it in the `test/TestItems.toml` of the workspace root with `monorepo_default = true`:

```toml
[profiles.default]
monorepo_default = true
init = "global WORKER_STARTED = time()"
```

A package of the workspace that does not declare a profile of this name uses the shared profile. A package that declares it with the same `init` and `test_end` uses the shared profile too. The code must be the same, but the layout and the comments can be different. A package whose `init` or `test_end` differs keeps its own profile. Profiles with different `test_end` expressions can still share workers when their start configuration and `init` directory are the same; `test_end` runs after each item.

The `init` of a shared profile runs in the workspace root, in the runs of each package and in combined runs. Thus the packages that use the profile share its workers. Shared profiles need Julia 1.12 or later, which has workspaces.

`Runtests.chores_mono()` shows the groups of workers. The items of one group can share a worker, and the items of two groups cannot. Each group names its profiles and their packages. The report also names the copies of a shared profile that a package can delete. It also names a profile that the root declares the same way as a package, and that `monorepo_default = true` would share.

## What stops a combined run

These problems stop a combined run before a worker starts:

1. A `using` or an `import` that a shared worker can load and the test environment of its own package cannot. Such an import names a package, a test dependency or a setup of another package. Items, setups, `init` and `test_end` are read. The error names the file, the import and the project that must declare it.
2. Two selected packages with a setup of the same name. A shared worker finds a setup by its name, so it would load only one of them.
3. A setup with the name of a package in the environment of the shared workers, for example a test dependency of another package. A shared worker loads that package for the name, but the run of its own package loads the setup. Rename the setup, or put one of the two packages in `isolated`.
4. Two packages that declare one dependency name with two different UUIDs.
5. Two packages whose `test/LocalPreferences.toml` set one preference to two different values.
6. Two participating packages with the same package name. An editor and a combined run identify an item by its package name and item name.

To fix 4 or 5 for a package that cannot change, put the package in `isolated`.

The import check reads the code as it is written. It does not see an import that code builds at run time, for example with `Core.eval`, or an import in a file that `include` reads. Such an import can load a test dependency of another package in a combined run, and fail in the run of its own package.

## Run states and replay

A combined run writes one run state for each package, in the run state directory of that package. Each run state holds only the items of its package. Thus `runtestsf()` in a package runs the failures of that package from the combined run, and the next run of the package plans with the durations of the combined run.

The closing block gives one line for each package: its items, those that did not pass, and the directory of its run. To replay a combined run, give the directory of the run of any of its packages:

```julia
Runtests.runtests_mono(; replay = "/path/to/the.rundata")
```

The replay finds the run states of the other packages of the run. It runs their items again with their configuration and seeds. When the run state of a package is gone, the replay runs the other packages and says that it is a partial replay.

## Maintain the suites and work at the REPL

`Runtests.chores_mono()` does the [chores](@ref chores) of every package that takes part. Before the chores of any package change a file, it stops for the problems that no chore fixes: two setups of one name, a dependency name with two UUIDs, and preferences that disagree. It writes one report for all packages, with paths from the workspace root. After the chores, the report shows the [groups of workers](@ref shared-profiles) and checks the imports of every package that shares workers, as a combined run does. It also names each `test/runtests.jl` that does more than call `Runtests.runtests()`, because a combined run does not run that file. Move what that file sets to `test/TestItems.toml` of its package. Run settings go to `[run]`, the group that a run selects goes to `default` of `[groups]`, and variables go to `env` of a profile. A variable whose value the file computes goes to `init` of the profile.

`Runtests.activate_mono()` makes the REPL look like a shared worker. It activates the environment of the shared workers and puts the setups of every package that shares workers on `LOAD_PATH`. An included test item runs as an item of the package that holds its file, with that package loaded and its root as the working directory. A test item pasted at the REPL uses the package that holds the REPL's current directory, so `cd` into a package first. `Runtests.deactivate()` restores the environment and `LOAD_PATH`; it does not undo `cd`. To work with an isolated package, use `Runtests.activate` with that package. [Work at the REPL](@ref repl) has an example.

## Limits

With `workers = 0`, a combined run runs one package only, because this process holds one test environment.

A shared worker keeps the packages that it loaded for earlier items, from any package. An item that needs a clean process must use `sandbox = true`. Put a package whose tests react to the code of other packages in `isolated`.

With `coverage = true`, the run writes one `lcov.info` at the workspace root. It counts the `src/` and `ext/` directories of every package.
