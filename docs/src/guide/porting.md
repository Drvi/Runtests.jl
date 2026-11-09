# [Port an existing suite](@id porting)

This page tells you how to convert a suite that uses `Test.jl` testsets, ReTestItems or TestItemRunner to Runtests. It also tells you what changes for a test when a testset becomes a test item.

## The port, step by step

A port rewrites the suite as test items while preserving what each test checks. It then compares the ported suite's checks and outcomes with the original under comparable conditions. The Runtests repository has a [guide for coding agents](https://github.com/Drvi/Runtests.jl/blob/main/skills/port-to-runtests/SKILL.md) that does a port in this way. A person can follow it too. Its steps are:

1. Make an environment outside the repository that has Runtests.
2. Record what the suite does now: run it as CI does, and count each test and each outcome.
3. Add Runtests to the test dependencies of the package.
4. Convert the suite, with the scripts below.
5. Make `test/runtests.jl` call `Runtests.runtests()`.
6. Put shared helpers in `test/testsetups/` and source or package fixtures in `test/testfixtures/`. Port the tests of a nested environment in place: they run in that environment. Check each remaining Julia file against the [test-directory rules](writing.md); do not hide tests to make discovery pass.
7. Run `Runtests.chores()`, then the suite.
8. Show that the numbers of passed, failed, errored and broken tests did not change.

## The conversion scripts

The guide has two scripts in `skills/port-to-runtests/scripts/`. Each script edits the test directory that you give it, in place. Give it a copy. The commands below run from a checkout of the Runtests repository; replace `/path/to/copied-package/test` with the copy's test directory.

[`port_testsets.jl`](https://github.com/Drvi/Runtests.jl/blob/main/skills/port-to-runtests/scripts/port_testsets.jl) converts a `Test.jl` suite. Each top-level `@testset "name" begin ... end` becomes `@testitem "name" begin ... end`, adding a `let` block where the script detects a need to preserve local scope. It reads the suite as `runtests.jl` runs it, with the files that it includes. Definitions at the top of a file go into a setup module that the items of the file load.

```sh
julia skills/port-to-runtests/scripts/port_testsets.jl /path/to/copied-package/test
```

[`port_retestitems.jl`](https://github.com/Drvi/Runtests.jl/blob/main/skills/port-to-runtests/scripts/port_retestitems.jl) converts a ReTestItems suite. The items stay as they are. These parts change around them:

- Each `@testsetup module S ... end` becomes `testsetups/S.jl`.
- `setup = [S, T]` on an item becomes `using S, T` at the top of its body.
- `skip = :(expr)` becomes `skip = expr`, because Runtests evaluates the expression itself.
- `default_imports` and `_id` go away, because Runtests always imports `Test` and the package.
- A file of items with another name becomes `<stem>_tests.jl`.

```sh
julia skills/port-to-runtests/scripts/port_retestitems.jl /path/to/copied-package/test
```

Each script prints what it moved, and a list of what a person must look at.

## What changes when a testset becomes an item

A test item runs in a different way from a testset. These differences can change what a test does:

| Topic | In a testset | In a test item |
|:------|:-------------|:---------------|
| Scope | The body is a local scope, with typed local variables. | The body runs at the top level of a module, with soft scope, and its variables are untyped globals. Put code that measures speed or allocations in a `let` block or a function. |
| Main | In a plain include-based suite, files ran in `Main` in order and could see earlier definitions. SafeTestsets may already isolate them. | Each item has its own module, on one of several workers, in any order. Import what each item uses, in the item or in a setup. |
| State | A variable, file or value that one testset left could reach the next. | Each item has a fresh module, so build its own values or use a setup. A `chain` keeps items in order on one worker for intentional process or file state; it does not share item variables. |
| Process | In a plain include-based suite, changes to `ENV`, the logger, the working directory or the loaded packages lasted until the suite ended. | Items on a worker run one after the other, and see what earlier items changed, except the working directory: each item starts in the root of its package. Restore changes, or use `sandbox = true`. |
| Printed types | Types printed without their module, where `Main` imported it. | `Main` imports nothing, unless the `init` of a profile imports a package there. Thus messages print types with their module, for example `FixedPointDecimals.FixedDecimal{Int64, 100}`. |
| Random numbers | A `Random.seed!` in `runtests.jl` decided every draw. | Each item draws from the seed of the run combined with the name of its package and its own name. An item that expects values from a fixed seed calls `Random.seed!` itself. |
| Threads | The process had the threads that `julia` started with; record the count. | Workers use `--threads=2,1` by default. Set `threads` under `[run]`, or use a profile. |
| Setup code | Helper code at the top of a file ran when the file was included. | Top-level setup code runs when its precompile cache is built or rebuilt. Per-process initialization belongs in `__init__`. All items on a worker share the globals of the setup. See [test setups](setups.md). |
| Paths | `@__DIR__` named the helper's directory. | Moving a helper into a setup changes its directory. Check its paths against the [setup path rules](@ref setup-paths). In an item, `@__DIR__` and `include` are relative to the test file. |
| Parallel runs | Plain include-based Test.jl testsets ran one at a time. | Items can overlap. Give independent items separate temporary paths; preserve intentional shared paths with explicit ordering. |
| Crashes | An `exit()` or a crash ended the suite. | It ends only that worker. The item counts as an error, and the run continues. |

## Rules for a port

Follow these rules during a port:

- Do not change what a test does to make it pass, and do not delete a test. If a test cannot pass under Runtests, leave it as it is and report it.
- Do not change `src/`.
- Do not edit an expansion that `chores` wrote. Edit the template and run `chores` again.
