# [Profiles and environments](@id profiles)

Three things decide where a test item runs, and each has its own control:

- The profile decides the configuration of the worker: Julia flags, threads, environment variables, Julia expressions to run and preferences. An item chooses it with `profile = :name`.
- `sandbox = true` decides that the item runs alone, in a new process.
- The location of the test file decides the environment: the packages that the item can load.

A profile is a named worker configuration in `test/TestItems.toml`. An environment directory is a directory under `test/` with a `Project.toml` of its own. The three controls combine freely.

## Declare a profile

Profiles go under `[profiles]` in `test/TestItems.toml`:

```toml
[profiles.bounds]
julia_args = ["--check-bounds=yes"]
threads = "4"
env = { JULIA_DEBUG = "Main" }
init = "using MyPkg"
test_end = "GC.gc(true)"
preferences = "prefs/bounds.toml"
```

An item runs under this profile with `profile = :bounds`:

```julia
@testitem "indexes stay in bounds" profile=:bounds begin
    @test sum(MyPkg.window([1, 2, 3], 2)) == 5
end
```

The items of one profile share the workers of that profile. To run an item of the profile alone in a new process, add `sandbox = true`:

```julia
@testitem "indexes stay in bounds, alone" profile=:bounds sandbox=true begin
    @test sum(MyPkg.window([1, 2, 3], 2)) == 5
end
```

[The configuration reference](@ref profile-keys) lists each key of a profile. A profile has no `environment` key. A configuration file that gives one is an error, and the message tells you to give the items `profile = :name` instead.

## The default profile

`[profiles.default]` configures the workers of every item without a `profile`, sandboxed or not. Without this table, the default profile has no flags, no environment variables and no expressions. A profile without `threads` uses the `threads` of the run.

## init and test_end

`init` runs once in each worker of the profile, before the first item. `test_end` runs after each attempt at an item that was not skipped, a failed attempt before its retry too. Each item runs the `test_end` of its own profile. Each has its own timeout, `init_timeout` and `test_end_timeout`, and this time does not count toward the timeout of the item. A failure in `test_end` counts toward the result of the item.

## Preferences

`preferences` names a TOML file, relative to the configuration file. The file must exist. Its contents go over the `LocalPreferences.toml` of a temporary copy of the environment of the item. Runtests precompiles separately for the preferences of each profile.

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

### Directories that are not environments

These directories are never environment directories, even with a project of their own:

- `test/` itself, which holds the test environment,
- the directories in `test/testsetups/`, which are setup packages,
- the directories in `test/testtemplates/` and `test/testfixtures/`,
- hidden directories, whose names start with `.`.

Discovery does not follow directory symlinks. A replay finds the environment of each item where its file is, in the checkout that the replay runs in.

## Pools of workers

A run keeps a pool of workers for each start configuration that its items use. The start configuration of a worker is what it gets when it starts: Julia flags, threads, environment variables, `init`, preferences and environment. Thus an item with `profile = :bounds` in `test/qa/` runs on a worker with the flags of `bounds` and the packages of `test/qa`. Two profiles that differ only in `test_end` share a pool. The run says the profile and the environment of each worker on its `UP` line.

Items of different pools run on different workers, and can run at the same time. `[order]` does not make them run one after the other. A `chain` runs its items in sequence on one worker. Thus all items of a chain must use the same profile and be in the same environment.

When a pool has no items left, its workers can restart for another pool. A worker restarts only for a pool that the restart makes finish sooner. Of those pools, it restarts for the pool that finishes last. [How a run works](@ref plan) explains this.
