# [Profiles and environments](@id profiles)

Three things decide where a test item runs, and each has its own control:

- The profile decides the configuration of the worker: Julia flags, threads, environment variables, Julia expressions to run and preferences. An item chooses it with `profile = :name`.
- `sandbox = true` decides that the item runs alone, in a new process.
- The location of the test file decides the environment: the packages that the item can load.

A profile is a named worker configuration in `test/TestItems.toml`, with its code in `test/testconfigs/`. An environment directory is a directory under `test/` with a `Project.toml` of its own. The three controls combine freely.

## Declare a profile

Profiles go under `[profiles]` in `test/TestItems.toml`:

```toml
[profiles.bounds]
julia_args = ["--check-bounds=yes", "--threads=4"]
env = { JULIA_DEBUG = "Main" }
preferences = "prefs/bounds.toml"
```

The Julia code of the profile goes in files of a directory with its name, `test/testconfigs/bounds/`. [init and test_end](@ref profile-code) tells you how.

An item runs under this profile with `profile = :bounds`:

```julia
@testitem "indexes stay in bounds" profile=:bounds begin
    @test sum(MyPkg.window([1, 2, 3], 2)) == 5
end
```

Items of this profile reuse its workers. Another profile can use the same pool when its workers start the same way. To run an item alone in a new process, add `sandbox = true`:

```julia
@testitem "indexes stay in bounds, alone" profile=:bounds sandbox=true begin
    @test sum(MyPkg.window([1, 2, 3], 2)) == 5
end
```

[The configuration reference](@ref profile-keys) lists each key of a profile. A profile has no `environment` key. A configuration file that gives one is an error, and the message tells you to give the items `profile = :name` instead.

The name of a profile is also the name of a directory. Thus a name must be a valid file name on Linux, macOS and Windows: no `/`, `\`, `:`, `*`, `?`, `"`, `<`, `>` or `|`, no space or dot at the end, and not a name that Windows keeps for a device, such as `CON`. macOS and Windows do not tell names apart by case. Thus two profiles must not differ only in case, and `Default` is an error.

## The default profile

`[profiles.default]` configures the workers of every item without a `profile`, sandboxed or not. Without this table and without code, the default profile has no flags, no environment variables and no expressions. A profile whose `julia_args` give no `--threads` (or `-t`) uses the `threads` of the run. The number of threads does not change the compiled code, so Runtests does not precompile again for it.

## [init and test_end](@id profile-code)

The `init` of a profile is Julia code that runs once in each worker of the profile, before the first item. Its `test_end` is code that runs after each attempt at an item that was not skipped, a failed attempt before its retry too. Each is a file of `test/testconfigs/`:

```text
test/
  testconfigs/
    worker_init.jl      # the init of the default profile
    test_end.jl         # the test_end of the default profile
    bounds/
      worker_init.jl    # the init of the profile bounds
      test_end.jl       # the test_end of the profile bounds
```

Each file is optional. The default profile needs no table for its files. Another profile must have a table in `[profiles]`. `test/testconfigs/` holds nothing else. A file with another name, or a directory that is no profile of `[profiles]`, is an error in each run and in `chores`. Hidden files, such as `.DS_Store`, are not errors. An error in the code names its file and its line.

The keywords `worker_init` and `test_end` of `runtests` give the code of the default profile in place of its files, as expressions:

```julia
runtests(worker_init = :(using Plots), test_end = quote GC.gc(true) end)
```

Each item runs the `test_end` of its own profile. Each has its own timeout, `init_timeout` and `test_end_timeout`, and this time does not count toward the timeout of the item. The result of the item is the result of its body. A failure, an error or a timeout in `test_end` does not change it, and does not start a retry. The run prints a `HOOK` line for the problem and writes the details in the log of the attempt. After a timeout, the run ends the worker and starts a new one for the next item.

`init` runs at the top level of `Main` of the worker. Under `workers = 0`, the `init` of the default profile runs in `Main` of the process that calls `runtests`, and the run warns about it. Items run in modules of their own, and do not see what `init` defines or imports. Thus a `worker_init.jl` that holds `using Plots` loads Plots before the first item, and an item that uses Plots must still import it. `test_end` runs in a new module of its own, with `Test` and the package in scope. It does not see the variables of the item. [Where code runs](@ref where-code-runs) gives the details.

## Preferences

`preferences` names a TOML file, relative to the configuration file. The file must exist. Its contents go over the `LocalPreferences.toml` of a temporary copy of the environment of the item. Runtests precompiles separately for the preferences of each profile.

Only the Julia flags and the preferences of a profile change the compiled code. Its environment variables do not go to precompilation. A package that reads an environment variable at its top level gets the value of the process that precompiles it, not the value of the profile. If a value must change the compiled code, give it as a preference.

## [Precompilation](@id profile-precompile)

Before the workers start, Runtests precompiles the environment of each profile for the Julia flags of that profile, as [Precompilation](@ref precompilation) tells. A flag that changes how Julia compiles code, for example `--check-bounds=yes`, makes Runtests compile each package of the environment again. For a large environment, this can take longer than the items of the profile.

`precompile` names the packages that Runtests precompiles for the profile instead, each with its dependencies:

```toml
[profiles.bounds]
julia_args = ["--check-bounds=yes"]
precompile = ["MyPackage", "Test"]
```

With `precompile = []`, Runtests precompiles no package of the environment for the profile. Without the key, it precompiles the whole environment.

Each name must be a package of the environment of the items of the profile, a dependency of a dependency included. A name that no such environment holds is an error, and the run stops before the workers start.

Runtests always compiles Runtests itself for the flags of the profile, because each worker loads Runtests before it connects. A worker compiles each other package when an item loads it for the first time. This time counts toward the timeout of the item. With the key, Runtests also does not compile the [setups](@ref setups) of these items before the workers start.

Each worker compiles in parallel, with its own limit. Two workers do not compile the same package, but together they can start more compile processes than `JULIA_NUM_PRECOMPILE_TASKS` allows. To lower the limit of each worker, set the variable in `env` of the profile, for example `env = { JULIA_NUM_PRECOMPILE_TASKS = "4" }`.

When items of another profile without the key run on the same workers, as [Pools of workers](@ref worker-pools) describes, Runtests still precompiles the whole environment for that profile.

## [Run items in an environment of their own](@id environments)

A directory under `test/` with a `Project.toml` or `JuliaProject.toml` of its own is an environment directory. The test files in it run in that environment, not in the test environment. With this, a suite can keep tests whose dependencies the test environment must not carry. Examples are Aqua or JET tests, and a group that needs other versions of packages:

```text
test/
  qa/
    Project.toml                   # Aqua, JET, ...
    aqua_tests.jl                  # its items run in the qa environment
```

Every test item under the directory runs in that environment, under the profile that it asks for. When environment directories are nested, the innermost directory that holds the file decides. An item in another place cannot use the environment.

An environment for tests declares no package. If its `Project.toml` has a `name`, the run warns and names the directory. Move a package that the tests take as input to `test/testfixtures/`. Move a test setup to `test/testsetups/`.

The workers run in a copy of the environment, in the temporary files of the system. The copy has these changes:

- The package under test is added by its path. This also brings the packages that its `[sources]` names, for example its siblings in a monorepo.
- The `LocalPreferences.toml` of the directory is used, with the `preferences` of the profile over it.

Runtests writes nothing into the directory. The copy is stacked over the test environment, as `Pkg.test` stacks its sandbox over the active project. Thus an item loads the packages of the environment first, and can still load the packages of the test environment.

Runtests resolves the copy once in each session, and again when a file that it was built from changes. A copy that does not resolve stops the run before any item runs.

### [Skip an environment](@id skip-environment)

Some environments do not work on every version of Julia. JET, for example, often does not resolve or compile on a prerelease. `skip_environment` names the environment directories that a run must not build, by their path from the root of the repository:

```julia
# test/runtests.jl
using Runtests
runtests(skip_environment = isempty(VERSION.prerelease) ? nothing : "test/qa")
```

The run does not resolve or precompile a skipped environment, and it starts no worker in it. It records each selected item of the directory as skipped, so the summary counts the items. The header of the run marks the directory: `env dir: test/qa (skipped)`.

Without the keyword, the run reads the environment variable `RUNTESTS_SKIP_ENVIRONMENT`. Thus a CI job can skip an environment with no change to the suite:

```yaml
env:
  RUNTESTS_SKIP_ENVIRONMENT: test/qa
```

A keyword in the call has precedence over the variable. The value `nothing` is the same as no keyword. Thus the call above decides on a prerelease, and the variable decides on a release. `[run]` does not take `skip_environment`, because one list in the file holds on every version of Julia.

The root of the repository is the directory that holds `.git`. Outside a git checkout, it is the root of the outermost workspace that holds the package, or else the root of the package. In a monorepo, a name is thus `lib/A/test/qa`. It skips that environment of `A` in the run of `A` and in each combined run that includes `A`. A run that does not include `A` accepts the name without an error, so one variable can serve the CI job of each package. A name that is no environment directory is an error.

`skip` on an item does not have this effect. The worker evaluates `skip` in the environment of the item, so the run builds the environment first. A run that selects no item of the directory, by name, tag or path, also does not build the environment.

A dependency that fails on some versions of Julia must be in an environment directory, not in the test environment. The run always builds the test environment.

### Directories that are not environments

These directories are never environment directories, even with a project of their own:

- `test/` itself, which holds the test environment,
- the directories in `test/testsetups/`, which are setup packages,
- the directories in `test/testtemplates/`, `test/testfixtures/` and `test/testconfigs/`,
- hidden directories, whose names start with `.`.

Discovery does not follow directory symlinks. A replay finds the environment of each item where its file is, in the checkout that the replay runs in.

## [Pools of workers](@id worker-pools)

A run keeps a pool of workers for each start configuration that its items use. The start configuration of a worker is what it gets when it starts: Julia flags, threads, environment variables, `init`, preferences and environment. Thus an item with `profile = :bounds` in `test/qa/` runs on a worker with the flags of `bounds` and the packages of `test/qa`. Two profiles that differ only in `test_end` share a pool, and each item still runs its own profile's `test_end`. Across packages of a workspace, an `init` must also run in the same directory for workers to be shared. [Share a profile](@ref shared-profiles) explains how the workspace root supplies one `init` to its packages.

The `UP` line of a worker names its profile when an item of the run uses a profile other than `default`. It names the environment of the worker when an item uses an environment directory. [Output](@ref output) gives the details.

Items of different pools run on different workers, and can run at the same time. `[order]` does not make them run one after the other. A chain, a throttle with the limit 1, runs its items in sequence on one worker. Thus all items of a chain must use the same profile and be in the same environment.

When a pool has no items left, its workers can restart for another pool. A worker restarts only for a pool that the restart makes finish sooner. Of those pools, it restarts for the pool that finishes last. [How a run works](@ref plan) explains this.
