# [Write test items](@id writing)

This page tells you where test files go, how to write a test item, and what its keywords do. A test item is a named block of tests that runs alone, in a module of its own, on a worker process.

## Lay out the test directory

Runtests reads the files under the `test/` directory of the package. Each Julia file there must belong to one of these categories:

```text
test/
  runtests.jl                      # the entry point that Pkg.test runs
  solver_test.jl                   # a test file: @testitem declarations
  sub/parser_tests.jl              # a test file in a subdirectory
  periods_tests.jl                 # an expansion that Runtests.chores() wrote
  testsetups/
    MySetups.jl                    # a test setup, loaded with `using MySetups`
  testtemplates/
    periods_tests_template.jl      # a test template: @testtemplate declarations
  qa/
    Project.toml                   # the environment of the test files in qa/
    aqua_tests.jl
  testfixtures/                    # input for the tests, never read as tests
    Example/Project.toml
    reference.png
  TestItems.toml                   # the configuration of the suite (optional)
```

The name of a test file ends in `_test.jl` or `_tests.jl`. A Julia file under `test/` that is in no category stops the run with an error. Thus a misnamed test file cannot go untested without a message. Runtests ignores hidden files and hidden directories.

Runtests finds items by parsing the test files. It does not evaluate them in the process that calls `runtests`. A test file holds `@testitem` declarations and nothing else. Put imports and other code inside an item, or put shared code in a [test setup](setups.md).

### Test fixtures

`test/testfixtures/` holds input for the tests. Examples are packages, projects, source files that are broken on purpose, reference images and data. A run, a dry run, `chores` and an editor never read this directory, never count its tests and never add it to `LOAD_PATH`. Only the directory with this name at the top of `test/` has this meaning.

A package in `test/testfixtures/` runs as a suite of its own when you give a path inside it alone, for example `Runtests.runtests("test/testfixtures/Example")`. A path into `test/testfixtures/` together with paths of the suite is an error.

### Directories with a project of their own

Each other directory under `test/` that has its own `Project.toml` or `JuliaProject.toml` is an environment directory. The test files in it run in that environment, not in the test environment. [Profiles and environments](@ref environments) tells you more. `test/Project.toml` is the test environment, and the packages in `test/testsetups/` are setups, not environment directories. A project that is input for the tests goes in `test/testfixtures/`. If the project of an environment directory declares a package, the run warns. A package there is usually a fixture or a setup in the wrong place.

## Write a test item

```julia
@testitem "adds numbers" tags=[:fast] begin
    @test 1 + 1 == 2
end

@testitem "against a database" chain=:db timeout=600 retries=1 begin
    using MySetups          # test/testsetups/MySetups.jl
    @test MySetups.ping()
end
```

The name of an item is a string literal that is not blank. It must be unique across the suite. `Test` and the package under test are in the scope of the item, so `@test` and `@testset` work. The test environment does not have to declare `Test`.

### Keywords

Keywords come between the name and `begin`. The [syntax reference](@ref testitem-keywords) lists them all. This list summarizes what they do:

- `tags = [:a, :b]` gives the item tags that a run can select by.
- `timeout = N` gives each attempt `N` seconds. It replaces the run's `timeout` for this item.
- `retries = N` gives the item `N` more attempts after a failure, from 0 to 126.
- `skip = expr` skips the item when `expr` gives `true`.
- `failfast = true` stops the item at its first failed test.
- `chain = :name` runs the items of one chain in sequence, on one worker.
- `sandbox = true` runs the item alone in a new process, which stops after the item.
- `profile = :name` runs the item on workers with the configuration of the profile `name`.

Each keyword except `skip` must be a literal. Arithmetic on numeric literals is also a literal, for example `timeout = 5*60`. An incorrect value is an error. For example, `timeout = true` is not one second.

`skip` can be any expression. The worker evaluates it before the body, with `Test` and the package in scope, but before the imports of the body. It must give a `Bool`. An exception or a value of another type is an error of the item.

### Retries, chains and sandboxes

A retry runs on the same worker, except in three cases: the worker timed out, the worker crashed, or the item has `sandbox = true`. A chain retries from its first item. All items in a chain must use the same profile and be in the same environment. `sandbox = true` and `chain` do not go together.

The items of a profile share the workers of that profile. If an item needs a new process of its own, add `sandbox = true`. The two keywords combine: `profile = :bounds sandbox = true` runs the item alone, in a new process of the `bounds` profile. Neither keyword chooses the packages of the item. The location of its file does.

## How the body runs

The body of an item runs at the top level of a new module, with the soft scope of the REPL. Thus `x = 1` followed by a loop that changes `x` works as it does at the prompt. As in a script, the variables of the body are untyped globals.

!!! warning
    Put code whose speed or allocations a test measures inside a function or a `let` block. In the body, the measurement includes the access to the untyped globals.

Julia measures a plain call such as `@allocated f(x, y)` from inside `f`, when the function and the arguments are names or literals. Julia measures any other expression where it stands, with the global access. These examples include a qualified name, a keyword argument and a `begin` block. Use a `let` block for them:

```julia
@testitem "summing allocates nothing" begin
    let
        x = rand(10)
        @test @allocated(sum(x; init = 0.0)) == 0
    end
end
```

When the item ends, the run releases what its nonconstant globals refer to. An item that registers [failure-artifact producers](@ref evidence) retains the values they need through `test_end` and artifact collection. A `const` keeps its value for as long as the worker runs.

## Items on one worker

A worker runs one item at a time, and runs many items one after the other. Each item sees the changes that earlier items made to the process. Examples are changes to `ENV`, to the global logger, to the working directory and to the loaded packages. Restore what an item changes, with `withenv` or `try` and `finally`. If an item cannot restore a change, give it `sandbox = true`.

Items on different workers run at the same time. If two items can write to the same path, make each of them use its own `mktempdir()`.

Each item draws its random numbers from the seed of the run, combined with the name of the item. The run prints its seed. If the expected values of an item come from a fixed seed, call `Random.seed!` in the item.

## Use Runtests inside an item

Test infrastructure can ask Runtests about the item that runs. Examples are code that makes temporary directories, finds fixture paths or switches off telemetry:

```julia
import Runtests               # in the body of the item
Runtests.current_testitem()   # a TestItemInfo, or nothing
Runtests.in_testitem()        # true in this task and in the tasks that it starts
Runtests.in_test_run()        # true in the process, and in its subprocesses
```

`current_testitem()` gives the `name`, `file`, `line`, `attempt` and `profile` of the item. A task that started before the item, for example a service that a profile's `init` started, does not see the item. For that case, and for subprocesses, use `in_test_run()`.

!!! warning
    Do not make library code change what it does because it is under test. Then the tests no longer test the library.

To keep files that explain a failure, use `Runtests.on_failure` and `Runtests.artifacts_dir`. [Investigate failures](@ref evidence) tells you how.
