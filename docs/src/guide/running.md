# [Run tests](@id running)

This page covers runs of one package: how to start one, select its items, and read its result. For one run across several packages in a Julia workspace, see [Run the suites of a monorepo](@ref monorepos).

## Start a run

There are two ways to start a run:

1. Call `Pkg.test()` with the project of the package active. `Pkg.test` runs `test/runtests.jl`, which calls `Runtests.runtests()`.
2. Call `Runtests.runtests()` at the REPL with the project of the package active. Runtests must be in an environment that Julia can load from, for example your default environment.

Under `Pkg.test()`, Runtests uses the package whose `test/runtests.jl` is running. At the REPL, it uses the package of the active project. To run the suite of another package, give its directory as the first argument: `Runtests.runtests("path/to/Package")`.

At the REPL, Runtests reuses an active test project or prepares a test environment. It caches an environment it prepares for the session, reusing it while its input files remain unchanged. [The test environment](@ref test-environment) explains when it is rebuilt.

## Select items

With no arguments, a run selects the whole suite, or the `default` group when the configuration declares one. These calls select a part of the suite:

```julia
Runtests.runtests("test/solver_test.jl")     # one file
Runtests.runtests("test/db")                 # the files in a directory
Runtests.runtests("test/solver_test.jl:42")  # the item that contains line 42
Runtests.runtests(name = "adds numbers")     # one name, exactly
Runtests.runtests(name = r"numbers$")        # the names that match a Regex
Runtests.runtests(tags = :fast)              # the items with this tag
Runtests.runtests(tags = [:fast, :math])     # the items with both tags
Runtests.runtests(tags = "fast && !slow")    # a tag expression
Runtests.runtests(group = "gpu")             # a group from TestItems.toml
Runtests.runtests("test/db"; tags = :fast)   # a path and a tag together
```

Each selection narrows the run. When you give several selections, an item runs only if all of them select it. Several paths are the exception: an item runs if any of the paths selects it. Thus a list of paths that includes the package or its `test/` directory selects the whole suite.

The `name` keyword also takes a vector or a set of exact names. A tag expression uses `!`, `&&` and `||`, and `&&` binds tighter than `||`. Parentheses are not part of the syntax. [The syntax reference](@ref tag-expressions) gives the full grammar.

### Select one item by its line

A target of the form `file.jl:line` selects the item that contains that line. The line must be in the file. A `file.jl:line` target is the only positional target of its call, so you cannot give other paths with it. The other selections still apply. If they do not select that item, the run selects nothing.

### Select a group

A group is a named tag expression that `test/TestItems.toml` declares under `[groups]`. [Configure runs](@ref groups) tells you how to declare groups. When a call selects nothing else, the run selects a group in this order:

1. The group that the environment variable `RUNTESTS_GROUP` names, if it is set. CI jobs use this variable to split a suite.
2. The group named `default`, if `[groups]` declares it.
3. The whole suite.

`group = "all"` removes the group restriction; other selections still narrow the run. A path, a line, `name`, `tags` or `group` in the call replaces `RUNTESTS_GROUP` and `default`. Thus an item that you ask for by name runs, whatever its group.

### Selections that are errors

A selection that cannot mean what you intended is an error. The run does not select everything or nothing in its place. These selections are errors:

- an empty `name` or an empty `tags`,
- a tag that no item of the suite carries,
- a name that the suite does not have,
- a group that `[groups]` does not declare,
- a misspelled keyword.

When a nearby spelling exists, the error message suggests it. For example, a misspelled group name can get the name of the group that you probably meant.

The selection narrows what runs, but not what Runtests reads. Each run parses the whole suite and makes sure that no two items have the same name, also when you select one item.

## Run the failing items

`Runtests.runtestsf()` runs the items whose latest verdict was not a pass. Failures include failed tests, errors, timeouts, a chain cut short by a lost worker, and an item left running when its coordinator died. Runtests keeps the latest verdict of each item across runs. Thus a run of one failure does not forget the other failures. [Run states and history](@ref history) explains which records count.

These rules apply to `runtestsf`:

- A skip is not a verdict. A skipped item that failed before stays failing.
- A run that explicitly cancels an item, or stops before reaching it, leaves its previous verdict unchanged.
- An item that the suite no longer has, for example because you renamed it, does not run.
- Each other selection narrows the failing items, so an item that is not failing never runs. If no failing item matches `name`, the call is an error.
- Each item starts from the seed that it failed with. Give `seed` to use another seed. Reproducing the seed does not reproduce external state or task scheduling; [Investigate failures](@ref failures) explains the limits.

When no item is failing, `runtestsf()` says so and returns `nothing`. Thus you can call it again until the suite passes.

The `retries` setting controls additional attempts within one run. [Configure runs](@ref configuration) explains this setting; [Keep evidence from a failed attempt](@ref evidence) explains what survives when a retry passes.

## Inspect the plan

`Runtests.runtests(dry_run = true)` prints the plan of a run and runs nothing. The plan shows each item in the order that the run is expected to start it, with the worker that is expected to run it. A dry run returns `nothing`. [How a run works](@ref plan) explains the order.

## Run in this process

`workers = 0` runs the items in the process that calls `runtests`, one after the other. An item that needs a process of its own still gets one. These are items with `sandbox = true`, items that run under a profile other than `default`, and items in an environment directory. The run starts a process for each such item or chain, stops it afterwards, and lists these items. A chain shares that process through its members and retries unless the process is lost.

The items in this process run in its current directory, which is `test/` under `Pkg.test`. The `init` of the default profile runs once in `Main` of this process, before the first item, and the run warns about it. The items that get a process of their own run in the root of the package. [Where code runs](@ref where-code-runs) gives the details.

Items that run in the caller's process, their profile hooks and their artifact producers have no enforceable timeout: there is no separate process to stop. Items that get a worker keep their timeouts. Coverage needs workers, so `workers = 0` with `coverage = true` is an error.

## What a run returns

A normal run returns a `Runtests.RunTestSet`. A `RunTestSet` is a testset that holds one testset for each test file. A dry run returns `nothing`.

The result of a failure depends on where you call `runtests`:

- Outside a `@testset`, an item that did not pass makes the call throw. This is how `Pkg.test` knows that the tests failed.
- Inside a `@testset`, the run records its results in that testset. Several runs inside one `@testset` add up there. Give each run a different `testset_name` to tell them apart.

A process runs one run at a time. A call to `runtests` while another run is in progress, for example from another task, throws an error. The first run continues.

## Errors before a run starts

Some problems stop the run before any item runs. These problems throw an exception:

| Exception | Cause |
|:----------|:------|
| `Runtests.ScanFailure` | A test file that does not parse, a name that two items use, a Julia file under `test/` that is not a test file, or a template expansion that is missing or not current. |
| `Runtests.NoTestsError` | No test files, no item that the selection matches, or existing failing items of which none matches the selection. With no failing items, `runtestsf()` returns `nothing`. |
| `Runtests.ConfigError` | A mistake in `test/TestItems.toml`, in another configuration file or in an environment variable. Examples are an incorrect value, an unknown profile, an undeclared group in `RUNTESTS_GROUP`, or a profile environment that does not resolve. |
| `ArgumentError` | A mistake in the call. Examples are a misspelled keyword, a value out of range, an empty selection, a malformed tag expression, or a path outside `test/`. |

A `ScanFailure` lists every problem that Runtests found, so you can correct them all before the next run.
