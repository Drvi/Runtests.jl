# [Glossary](@id glossary)

This page defines the terms of this manual, in alphabetical order.

| Term | Definition |
|:-----|:-----------|
| attempt | One execution of a test item. A retry is a new attempt. |
| chain | A set of test items with the same `chain` keyword. They run in sequence, on one worker. |
| combined run | One call to `runtests_mono`. It runs the suites of several packages of one workspace in one run. |
| coordinator | The process that calls `runtests`. It plans the run, starts the workers and prints the output. |
| dry run | A run with `dry_run = true`. It prints the plan and runs nothing. |
| environment directory | A directory under `test/` with a `Project.toml` of its own. The test files in it run in that environment. |
| evidence | The files that a failed attempt keeps: the outputs in `artifacts_dir()` and the files of its producers. |
| expansion | The test file that `chores` writes from a test template. |
| group | A named tag expression in `[groups]` of `test/TestItems.toml`. |
| plan | The order in which a run gives out its items, and the worker that is expected to run each item. |
| producer | A function that an item registers with `on_failure`. It writes evidence after a failed attempt. |
| profile | A named worker configuration in `[profiles]`: flags, threads, variables, expressions and preferences. An item chooses it with `profile = :name`. |
| replay | A run of the items of a recorded run state, with its configuration and seeds. |
| retention | The rules that decide which run states Runtests keeps. |
| run | One call to `runtests` or `runtestsf`. |
| run state | A binary file that records one run: its items, results, configuration and seeds. |
| sandbox | An item with `sandbox = true` runs alone in a new process, under its profile. |
| seed | The number from which a run derives the random numbers of each item. |
| tag | A symbol in the `tags` keyword of an item. A run can select items by tag. |
| tag expression | A string such as `"fast && !slow"` that selects items by their tags. |
| test environment | The Julia environment in which the items run. It holds the package and its test dependencies. |
| test file | A file under `test/` whose name ends in `_test.jl` or `_tests.jl`. It holds `@testitem` declarations. |
| test fixture | Input for tests in `test/testfixtures/`. Runtests never reads it as part of the suite. |
| test item | A named block of tests, declared with `@testitem`. It runs alone, in a module of its own. |
| test setup | A module in `test/testsetups/` that test items load with `using`. |
| union environment | The environment of the shared workers of a combined run. It holds the test dependencies of all its packages that are not isolated. |
| test template | A file in `test/testtemplates/` of `@testtemplate` loops. `chores` expands it into a test file. |
| verdict | The latest recorded pass or failure of an item. Failures include errors, timeouts and lost-worker outcomes. A skip or explicit cancellation leaves the previous verdict unchanged. See [Run states and history](@ref history). |
| worker | A Julia process that a run starts to run test items. |
