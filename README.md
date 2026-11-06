# Runtests.jl

[![CI](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://drvi.github.io/Runtests.jl/dev/)

Runtests.jl runs a Julia package's tests as independent **test items** across
worker processes. Call `Runtests.runtests()` to run the suite and
`Runtests.runtestsf()` to rerun failures.

Runtests chooses a worker count from the available CPUs and memory, builds the
test environment, and uses previous runs to plan the next one. Recent failures
and long items get priority; other items run in file order to reuse compiled
code. Each run records its results, settings, profiles, and random seed for
[inspection and replay](#run-state).

**Requires Julia 1.11 or later.** Runtests is a vibe-coded package: its code was
written with an AI coding assistant.

- [Quick start](#quick-start) · [Running tests](#running-tests)
- [Test files](#test-files) · [Writing test items](#writing-test-items)
- [Test setups](#test-setups) · [Test templates](#test-templates) · [Suite maintenance](#suite-maintenance)
- [Configuration](#testtestitemstoml) · [Coverage](#coverage)
- [The plan](#the-plan) · [While it runs](#while-it-runs)
- [At the REPL](#at-the-repl) · [Monorepos](#monorepos) · [Run state](#run-state) · [Editors](#editors)

## Quick start

1. Add Runtests to the package's test dependencies: `test/Project.toml`, or
   `[extras]` and `[targets]` in `Project.toml`.
2. Create the test entry point:

   ```julia
   # test/runtests.jl
   using Runtests
   Runtests.runtests()
   ```

3. Write test items in files named `*_test.jl` or `*_tests.jl`:

   ```julia
   # test/arithmetic_tests.jl
   @testitem "adds numbers" begin
       @test 1 + 1 == 2
   end
   ```

4. Run the package's tests from its active project:

   ```julia
   using Pkg
   Pkg.test()
   ```

Each item gets `Test` and the package under test automatically. Test files contain
only `@testitem` declarations; put imports and other executable code inside an
item, or shared helpers in a [test setup](#test-setups).

Porting an existing suite? Agents can follow
[`skills/port-to-runtests/SKILL.md`](skills/port-to-runtests/SKILL.md).

For an interactive session where Runtests is available, `using Runtests` followed
by `Runtests.runtests()` runs the active project's suite and builds its test
environment. See [At the REPL](#at-the-repl) for activating that environment
yourself or debugging an item.

## Running tests

With the package's project active and Runtests loaded:

```julia
Runtests.runtests()                         # entire suite
Runtests.runtests("test/solver_test.jl")    # one file
Runtests.runtests("test/solver_test.jl:42") # item containing this line
Runtests.runtests(name="adds numbers")      # exact name
Runtests.runtests(name=r"numbers$")         # names matching a Regex
Runtests.runtests(tags=:fast)               # one tag
Runtests.runtests(tags=[:fast, :math])      # must have both tags
Runtests.runtests(tags="fast && !slow")     # tag expression
Runtests.runtests("test/db"; tags=:fast)    # combine path and tag filters
Runtests.runtests(group="gpu")              # a named selection from TestItems.toml
Runtests.runtests(dry_run=true)             # inspect the plan without running
Runtests.runtestsf()                        # items whose latest verdict did not pass
```

Paths, names, tags and a group narrow the selection together. Several paths select
what any of them does, so the package or its `test/` among them is the whole suite.
`name` also accepts a vector or set of exact names. A `file.jl:line` target picks the
item that line is inside, whatever the other selections, which then keep it or leave
nothing; it is the only positional target, and names a line the file has. Tag
expressions support `!`, `&&`, and `||`; `&&` binds tighter than `||`, and
parentheses are not supported.

A selection that cannot mean what was intended is an error rather than a selection
of everything or of nothing: an empty `name` or `tags`, a tag no item in the suite
carries, a name it does not have, a group `[groups]` does not declare, a misspelled
keyword. Each error names the nearest thing that does exist.

`group` picks a named selection from [`[groups]`](#groups). A call that selects
nothing else runs the group `RUNTESTS_GROUP` names, for a CI matrix, and otherwise
`default`: the group of that name when `[groups]` declares one, and the whole suite
when it does not. `group="all"` is always the whole suite.

`runtestsf()` remembers each item's latest verdict across runs. Rerunning one
failure does not forget other failures, and renamed or deleted items are left
out. A skip is not a verdict, so a skipped item that failed before stays failing.
Every other selection narrows the failing items, `name` included, so nothing that
is not failing runs. Each failing item runs with the seed it failed with, so a
failure that depends on its random numbers comes back until it is fixed. Give
`seed` to choose another. When nothing is failing, `runtestsf()` says so and returns
`nothing`. To reproduce a recorded run's settings and seed, use
[`replay`](#run-state).

A normal run returns a `RunTestSet`; a dry run returns `nothing`. Outside an
existing `@testset`, an item that did not pass makes the call throw, so
`Pkg.test()` fails. Inside an existing `@testset`, the result is recorded there.

Problems discovered before execution also throw:

| Error | Cause |
|:------|:------|
| `Runtests.ScanFailure` | Invalid test files, duplicate names, or missing or stale template expansions. |
| `Runtests.NoTestsError` | No test files, or no matching items. |
| `Runtests.ConfigError` | A mistake in `test/TestItems.toml`, another config file or an environment variable: an invalid setting, profile or group, an undeclared group in `RUNTESTS_GROUP`, or an environment directory that does not resolve. |
| `ArgumentError` | A mistake in the call: a misspelled keyword, a value out of range, an empty selection, a malformed tag expression, a tag no item carries, an undeclared group, or a path outside `test/`, in another package, or at a line the file does not have. |

See [Configuration](#testtestitemstoml) for worker counts, timeouts, output,
coverage, and other run options.

## Test files

```text
test/
  runtests.jl                      # test entry point
  solver_test.jl                   # @testitem declarations
  sub/parser_tests.jl
  periods_tests.jl                 # generated by Runtests.chores(); commit this
  testsetups/
    MySetups.jl                    # shared helpers, loaded with using MySetups
  testtemplates/
    periods_tests_template.jl      # @testtemplate declarations
  qa/
    Project.toml                   # an environment of its own, for the test files in qa/
    aqua_tests.jl
  testfixtures/                    # input for the tests, never read as part of the suite
    Example/Project.toml
    reference.png
  TestItems.toml                   # optional settings, ordering, groups, and profiles
```

Runtests discovers items by parsing test files, without evaluating them in the
coordinator process. Item names must be nonblank string literals and unique
across the suite.

Every Julia file under `test/` must belong to one of the categories above.
Unrecognized files stop the run with an error, so a misnamed test file cannot
silently go untested. Hidden files and directories are excluded from discovery.

`test/testfixtures/` holds input for the tests: packages, projects and source that
may be broken on purpose, reference images, data. A run, a dry run, `chores` and an
editor never read it, count its tests or add it to `LOAD_PATH`. Only the directory
of that name at the top of `test/` is reserved. A package kept there runs as a suite
of its own when you give a path inside it alone, as in
`runtests("test/testfixtures/Example")`. A path into it given with the suite's own
paths is an error.

Every other directory under `test/` with its own `Project.toml` or
`JuliaProject.toml` is an [environment](#environments): the test files in it run
there. `test/Project.toml` itself is the test environment, and the setup packages
in `test/testsetups/` are setups. A run warns about a directory there whose project
declares a package: a package that the tests take as input belongs in
`test/testfixtures/`, and one that is a setup in `test/testsetups/`.

**Filters select what runs, not what is validated.** Every run parses the entire
suite and checks for duplicate names, even when you select a single item.

## Writing test items

```julia
@testitem "adds numbers" tags=[:fast] begin
    @test 1 + 1 == 2
end

@testitem "against a database" chain=:db timeout=600 retries=1 begin
    using MySetups          # test/testsetups/MySetups.jl
    @test MySetups.ping()
end
```

`Test` and the package under test are in scope already, so `@test` and `@testset`
work without the test environment having to declare `Test` itself.

| Keyword | Meaning |
|:--------|:--------|
| `tags=[:a, :b]` | tags to filter by |
| `timeout=N` | positive number of seconds allowed for an attempt; overrides the run default |
| `retries=N` | additional attempts after failure, from 0 to 126; overrides the run default |
| `skip=expr` | `true`, or an expression evaluated on the worker before the body |
| `failfast=true` | stop this item at its first failure |
| `chain=:sym` | items sharing a chain run in sequence, on one worker |
| `sandbox=true` | run alone in a process that is torn down afterwards (not with `chain`) |
| `profile=:name` | run on the workers of `[profiles.name]` of `TestItems.toml` |

Every keyword except `skip` must be a literal; arithmetic on numeric literals,
such as `timeout=5*60`, is also accepted. Invalid values are rejected:
`timeout=true` is not one second. `skip` runs before the body's imports, with
`Test` and the package in scope. It must return a `Bool`; an exception or any other
result is reported as an item error.

A retry uses the same worker unless the worker timed out or crashed, or the item
uses `sandbox=true`. A chain retries from its first item. The items of a profile
share its workers; add `sandbox=true` when an item needs a fresh process of its
own, of its profile or of the default one. Neither keyword chooses the item's
packages: its [environment](#environments) is where its file is.

An item's body runs at the top level of a fresh module, with the REPL's soft scope:
`x = 1` followed by a loop that updates `x` works as it does at the prompt. As in a
script, its variables are untyped globals, so code whose speed or allocations a
test measures belongs inside a function or a `let`. When the item ends, what its
globals refer to is let go, so a large fixture does not stay in the worker; a
`const` keeps its value for as long as the worker lives.

### Test setups

Code that items share goes in a module under `test/testsetups/`, as `Name.jl` or
`Name/src/Name.jl`:

```julia
# test/testsetups/MySetups.jl
module MySetups
export ping
ping() = true
end
```

An item loads a setup with `using MySetups` or `import MySetups`. Runtests discovers
these imports and precompiles the required setups before starting workers. As
with any package, top-level setup code runs during precompilation; put work that
must happen in each process in `__init__`.

`Runtests.setups_to_packages()` converts setups into packages:

- Moves `Name.jl` to `Name/src/Name.jl`.
- Creates `Name/Project.toml` with a UUID and the setup's imported dependencies.
- Rewrites `@__DIR__` to `pkgdir(MyPkg, "test", "testsetups")`, using the package
  under test's name, so fixture paths also work when pasted into the REPL.

Without a project and UUID, setups of the same name share a precompile cache per
depot. Conversion gives each checkout its own cache identity; runs precompile
setups for each profile's Julia flags. Rerun the conversion when a setup imports
new dependencies. [`Runtests.chores()`](#suite-maintenance) includes this step.

### Test templates

Use a template when a list of values should produce independently runnable test
items. Templates live in `test/testtemplates/`, contain only `@testtemplate`
declarations, and have names ending in `_test_template.jl` or
`_tests_template.jl`. Add `Dates` to your test dependencies for this example:

```julia
# test/testtemplates/periods_tests_template.jl
@testtemplate "doubling a $P of $n" tags=[:gen] for P in (Dates.Day, Dates.Month), n in 1:2
    using Dates
    @test $P($n) + $P($n) == $P(2 * $n)
end
```

Run `Runtests.chores()` to generate `test/periods_tests.jl`. It contains four
ordinary `@testitem` declarations, with the first loop variable varying slowest:
`Day` at 1 and 2, then `Month` at 1 and 2. The first item is:

```julia
@testitem "doubling a Day of 1" tags=[:gen] begin
    using Dates
    @test Day(1) + Day(1) == Day(2 * 1)
end
```

**Commit the generated file.** Installed packages need it to run `Pkg.test()`.
Edit the template and rerun `Runtests.chores()` when the cases change.

#### Scope and interpolation

Expansion runs in a separate process with the test environment and setups
available. The loop sees `Test`, the package under test, and packages imported by
the body **by module name only**. In this example, the loop uses `Dates.Day`;
the item can use `Day` after `using Dates`. Shared lists belong in a setup module,
referenced by a qualified name such as `MySetups.PERIODS`.

| Location | Meaning |
|:---------|:--------|
| Name: `"case $n"` | Interpolate the iteration's value into the item's literal name. |
| Body or keywords: `$n` | Insert the loop variable's value as Julia code. |
| Keywords: `$(expression)` | Evaluate during expansion, once per iteration, in the loop's scope. |
| Body: other `$` expressions | Leave them for the body's own macros, such as `@btime`. |
| Quoted expressions | Leave all `$` expressions unchanged. |

Inserted values use `repr` in the item's scope, including its imports, and must
evaluate back to equal values there. Values that cannot round-trip, such as
closures, are rejected. Parentheses are added where needed to preserve how the
surrounding code parses.

Loop variables are not bound in the generated item. Use `$P` to insert a value,
or `P = $P` to give the item a variable named `P`; an unbound `P` is rejected.
Inside a body string, use `"$($P)"` to insert the template value.

For example, compute a keyword during expansion:

```julia
# test/testtemplates/cases_tests_template.jl
@testtemplate "case $n" skip=$(n == 2) for n in 1:3
    @test $n != 2
end
```

This writes `skip=true` for case 2 and `skip=false` for the others. Code outside
`$(...)` remains part of the item's keyword: `skip=Sys.iswindows() || $(n == 2)`
checks the operating system when the item runs. A shared exclusion list works
as `skip=$(n in MySetups.KNOWN_BAD)` when the body imports `MySetups`.

#### Keeping expansions current

Only `Runtests.chores()` expands templates. A test run and
`Runtests.chores(dry_run=true)` check the generated file's stamp without running
the template. A test run refuses to start if an expansion is missing, its template
changed, the generated file was edited by hand, or its template was deleted.
Line endings, a byte-order mark, and trailing whitespace at the end of the file
do not affect the stamp.

`Runtests.chores()` evaluates every template each time, because its input data can
change without its source changing, and writes only changed expansions. It
reports manually edited expansions for you to resolve. On CI, run
`Runtests.chores()` followed by `git diff --exit-code` to check committed
expansions against the current data.

## Suite maintenance

```julia
Runtests.chores(dry_run=true)  # report needed changes without making them
Runtests.chores()              # apply automatic fixes and report remaining problems
```

`chores()` performs these tasks:

- Converts setups to packages and adds newly imported dependencies.
- Expands templates and deletes generated files whose templates were removed.
- Checks test items and `test/TestItems.toml`, reporting problems that need manual
  changes, including manually edited expansions. A package without test files, such
  as a fixture package in another package's `test/testfixtures/`, has nothing to check.
- Deletes the run states that a run's own pruning deletes, by the same
  [retention rules](#storage-and-retention), with their runs' directories. Records
  from other machines, and those this version does not read, are preserved.

After applying automatic fixes, it returns `true` or throws
`Runtests.ChoresError` if manual work remains. This lets you check the suite before
starting a run:

```julia
Runtests.chores(); Runtests.runtests()
```

`chores(dry_run=true)` changes nothing and returns `true` only when nothing needs
doing; reported problems do not throw `ChoresError`. To check additional config
files alongside `test/TestItems.toml`, pass `config="ci.toml"` or a vector of paths.

## `test/TestItems.toml`

Use this optional file for suite defaults, dispatch order, named selections, and
worker profiles. Explicit `runtests` keywords override `[run]` settings.

```toml
[run]
workers = "auto"       # or an integer
timeout = 600          # per test item
init_timeout = 120     # per `init` expression; defaults to `timeout`
test_end_timeout = 60  # per `test_end` expression; defaults to `timeout`

[order]
first = ["smoke test"]         # use exact item names from your suite
last  = ["large simulation"]

[groups]
default = "!gpu"               # what a run selects when nothing else does
gpu = "gpu"
quick = "fast && !slow"

[profiles.bounds]
julia_args = ["--check-bounds=yes"]
threads = "4"
env = { JULIA_DEBUG = "Main" }
init = "using MyPkg"
test_end = "GC.gc(true)"
preferences = "prefs/bounds.toml"  # optional; this file must exist
```

Select the example profile with `profile=:bounds` on an item. Replace `MyPkg`
with your package's name. `[profiles.default]` configures the workers of every item
without a `profile`, sandboxed or not.

`config="path/to/file.toml"` selects a file instead of `test/TestItems.toml`.
The path is relative to the current directory and must exist. No environment
variable or neighbouring file selects a config implicitly. Unknown keys and
invalid values are errors. On a full run, `[order]` must name existing items;
filtered runs allow names of items outside the selection.

**Ordering across profiles, environments or sandbox boundaries is not
sequential.** Those items can run concurrently. Use a `chain` for items that must
run in sequence on one worker; all items in a chain must use the same profile and
be in the same environment.

A profile's `init` runs once per worker before its items; `test_end` runs after
each attempt at an item that was not skipped. Each has its own timeout, separate
from the item's budget. Failures in `test_end` count toward the item's result.
Profiles whose workers start the same way, the same flags, threads, variables,
`init`, preferences and environment, share workers: profiles that differ only in
`test_end` share them, and each item runs the `test_end` of its own profile.

The `preferences` path is relative to the config file. Its contents overlay
`LocalPreferences.toml` in a temporary copy of the item's environment, with separate
precompilation for the profile's preferences.

### Groups

`[groups]` names tag expressions, written as `tags` takes them. `runtests(group="gpu")`
or `RUNTESTS_GROUP=gpu` runs the items an expression selects, and the run's header
says which group it was and what picked it: the keyword, the variable, or nothing
else selecting, for `default`. `RUNTESTS_GROUP` and `default` apply only to a call
that selects nothing else: a path, a line, `name`, `tags` or `group` takes their
place, so an item asked for runs whatever group it is in. The `group` keyword is a
selection like the others, and narrows together with them.

Two names are reserved. `all` is the whole suite and is not declared. `default` is
what a run selects by default: the group declared under that name, and the whole
suite when none is. A name that differs from either only in case is an error, and a
misspelled group is answered with the one meant (`ALL` with `all`). A name
`[groups]` does not declare is an error that lists the ones it does, and so is an
expression that names a tag no item carries. `Runtests.chores()` checks every
group.

A run of a group, `default` included, is a selection like any other: `[order]` may
name items outside it, and it is not a run of the whole suite, which `group="all"`
is (see [retention](#storage-and-retention)).

### Environments

A directory under `test/` with a `Project.toml` of its own is an environment: the
test files in it run in that environment instead of the test environment. This is
how a suite keeps tests whose dependencies the test environment should not carry,
such as Aqua or JET checks, or a group that needs other versions:

```text
test/
  qa/
    Project.toml                   # Aqua, JET, ...
    aqua_tests.jl                  # its items run in the qa environment
```

Every test item under the directory runs there, in the innermost such directory
that holds its file, whatever its `profile` and `sandbox` say: a profile chooses
the workers' flags and preferences, and the environment chooses their packages. An
item elsewhere cannot borrow it. The workers run in a copy of the environment, in
the system's temporary files, with the package under test added by path, which
brings the packages its `[sources]` name, such as its siblings in a monorepo; and
with the directory's `LocalPreferences.toml` under the profile's `preferences`.
Nothing is written into the directory. The copy is stacked over the test
environment, as `Pkg.test` stacks its sandbox over the active project: an item
loads the environment's packages first, and can still load the test environment's.
The copy is resolved once a session, and again when a file it was built from
changes; one that does not resolve stops the run before anything runs.

The directories in `test/testsetups/`, `test/testtemplates/` and `test/testfixtures/`
are never environments, nor are hidden ones. A profile has no `environment` key:
one is an error that says to give the items `profile = :name` instead. A replay
finds each item's environment where its file is, in the checkout it runs in.

### Run options

| Keyword | Default | Meaning |
|:--------|:--------|:--------|
| `workers` | `"auto"` | Worker count. Auto uses CPU count, threads per worker, and an assumed 4 GiB per worker, capped at 8. A worker with `threads = "auto"` takes every CPU. |
| `threads` | `"2,1"` | Each worker's Julia `--threads` value. |
| `timeout` | `1800` | Seconds allowed per item attempt. |
| `init_timeout`, `test_end_timeout` | `timeout` | Separate limits for profile hooks. |
| `artifacts_timeout` | `timeout` | Seconds allowed for all the [producers](#evidence-from-a-failed-attempt) of one failed attempt together. |
| `retries` | `0` | Additional attempts after failure, from 0 to 126. |
| `failfast` | `false` | Stop the run after an item fails. |
| `item_failfast` | `failfast` | Stop each item at its first failure. |
| `logs` | `:issues` | Print output for nonpassing items. Use `:batched` for every item's output when it ends, `:eager` to stream it, or `:quiet` to keep it in the run's logs only. |
| `verbose` | `false` | Print results and output for passing items too. |
| `memory_threshold` | `0.9` | Fraction of machine memory in use at which new items wait; must be in `(0, 1]`. |
| `monitor` | `true` | Monitor memory and display progress. |
| `monitor_interval` | `30` | Seconds between progress lines outside a terminal, which also print every 10 finished items; `0` prints at each sample, five times a second. |
| `full_stacktraces` | `false` | Include Runtests' internal frames in failure backtraces. |
| `full_names` | `false` | Print long names in full instead of [unique prefixes](#the-plan). |
| `testset_name` | `"Runtests"` | Summary testset name; useful for several runs inside one `@testset`. |
| `coverage` | `false` | Write merged line coverage to `lcov.info`; see [Coverage](#coverage). |
| `seed` | random | Seed combined with each item's name. Without one, the run chooses a random seed and prints it. |
| `dry_run` | `false` | Print the plan without executing tests. |
| `replay` | `nothing` | Path to a recorded [run state](#run-state). |
| `config` | `test/TestItems.toml` | Config file to read; an explicit path is relative to the current directory. |
| `group` | `RUNTESTS_GROUP`, else `default`, when nothing else selects | A [group](#groups) to run; `"all"` for the whole suite. |
| `on_item` | `nothing` | A function that the run calls when each attempt at an item starts and ends. See [What each item costs](#what-each-item-costs). |

An interactive run with at most one worker defaults to `logs=:eager`. All options
above except `dry_run`, `replay`, `config`, `group`, and `on_item` can also go under `[run]`. Use
TOML strings for symbols, such as `logs = "issues"`. Explicit keywords override the file.

Each of those settings can also come from a variable named `RUNTESTS_` and the
setting in capitals, such as `RUNTESTS_WORKERS=4`, `RUNTESTS_RETRIES=1` or
`RUNTESTS_SEED=0x1234`. CI sets a job's settings this way without an edit to the
project. A keyword wins over the variable, and the variable wins over the file. The
run's header names each variable that set something.

Timeouts must be positive and at most 2,147,483,647 seconds; fractional values
round up to whole seconds. Invalid settings are rejected before execution.

With `workers = 0` the items run in this process, one after another. An item that
needs a process of its own (`sandbox=true`, a profile, or an
[environment](#environments) directory) still gets one, started and stopped around
it, and the run lists which items did.

## Coverage

`coverage = true`, as a keyword, as `RUNTESTS_COVERAGE=true` in the environment, or
under `[run]` in `TestItems.toml`, has every worker count which lines of the
package's `src/` and `ext/` run. A keyword wins over the variable, and the variable
over the file; the run's opening block says which of them decided. At the end the
workers' counts are merged into `lcov.info` at the package's root, ready for Codecov
or Coveralls. Its paths are relative to the root of the git checkout the package is
in, which is what those services resolve them against, so a package in a
subdirectory, as in a monorepo, has its directory in front of them
(`lib/Foo/src/Foo.jl`); outside a checkout they are relative to the package.
Every line of a function that never ran counts as not covered, in a file that was
never loaded too, and the closing block gives the share that ran:

<pre>
<b>│ </b>coverage: 33.3% of 6 lines in 2 files · lcov.info
</pre>

Coverage is counted by the workers, so it needs one (`workers = 0` is an error).
A worker writes what it counted as it exits, a timed-out one included, so a worker
that dies without exiting, one killed outright or one that crashed, takes its
counts with it; the closing block says how many did. On Windows a timed-out worker
is terminated outright too. A report that cannot be written is said there as well,
and the run's result stands.

Under `Pkg.test(coverage = true)`, which is what `julia-actions/julia-runtest` does,
the workers take Julia's coverage flags from the test process and write `.cov`
files beside the sources, as the test process does, for `julia-processcoverage` to
merge; nothing needs setting. To upload the merged file instead:

```yaml
- uses: julia-actions/julia-runtest@v1
  env:
    RUNTESTS_COVERAGE: true
- uses: codecov/codecov-action@v5
  with:
    files: lcov.info
```

## The plan

`Runtests.runtests(dry_run=true)` prints what a run would do and runs nothing:

The output below and in [While it runs](#while-it-runs) illustrates a small suite;
timings and resource usage depend on the suite and machine.

<pre>
<b>┌ [TEST]</b> dry run · v0.1.0 · julia 1.13.3 · 6 test items in 2 files · 2 workers · threads 2,1
<b>│ </b>startup: files 0.0s
<b>│ </b>setups: `BasicSetup`
<b>│ </b>timeout: 1800s · retries: 0 · failfast: false · logs: issues · memory_threshold: 0.9
<b>│ </b>estimated work: w1 0.049s · w2 0.058s
<b>└ </b>order and workers: predicted from the recorded durations, an item without one counting as a typical one

  <b>#</b> · <b>worker</b> · <b>test item   </b> · <b>at                  </b> · <b> est</b> · <b>tags      </b> · <b>why here     </b> · <b>details</b>
  1 ·     w1 · "slow thing" · test/sub/b_test.jl:9 · 0.0s · slow       · [order] first · timeout 120s
  2 ·     w2 · "chain one"  · test/sub/b_test.jl:1 · 0.0s ·            ·               · chain `seq` 1/2
  3 ·     w2 · "chain two"  · test/sub/b_test.jl:5 · 0.0s ·            ·               · chain `seq` 2/2
  4 ·     w1 · "add works"  · test/a_test.jl:1     · 0.0s · fast
  5 ·     w2 · "uses setup" · test/a_test.jl:11    · 0.0s ·            ·               · setup `BasicSetup`
  6 ·     w1 · "mul works"  · test/a_test.jl:6     · 0.0s · fast, math
</pre>

The table lists the items in the order the run is expected to start them, each
with the worker expected to run it. The prediction plays out the run's own
dispatch with the durations earlier runs recorded, so it is as good as they are.
When earlier runs recorded durations, the `est` column gives each item's newest
one, in seconds with one decimal, and `estimated work` gives the time each worker
is expected to be busy. The column is blank for an item that has none yet.

A run hands out, in this order:

1. the items `[order] first` names;
2. sandboxed items, while every process is still fresh;
3. items whose latest result is a failure, however long ago; items that the newest
   run to select them stopped before; and items edited since they last ran, or new.
   The long ones among them go first;
4. items long enough to set the length of the run: at least 3 s, and over a quarter
   of a worker's share of the work;
5. everything else, in file order, each worker walking its own stretch of files so
   that neighbouring items reuse what it has compiled;
6. the items `[order] last` names.

The first four and the last go to whichever worker is free, and a worker that
finishes its own stretch takes over half of the longest one left. When a pool runs
dry, its worker may restart for another pool. The scheduler considers a pool when
its estimated work per serving worker exceeds both its longest unclaimed item or
chain and the cost of starting and compiling a fresh worker. It chooses the
qualifying pool with the largest estimated share. `why here` says which rule placed
an item, when it was not file order.

A name much longer than the rest is shortened to `r"^…"`, here and in a run's
`RUN` and `DONE` lines: a prefix that no other item's name in the suite starts
with, which picks that item out when passed as `name=`. `full_names = true` writes
every name whole.

## While it runs

Workers, test items and the run itself each get lines of one shape:

<pre>
<b>┌ [TEST]</b> v0.1.0 · julia 1.13.3 · 6 test items in 2 files · seed 0x522fb3b30334cd75 · 2 workers · threads 2,1
<b>│ </b>env: /var/folders/…/jl_7AEUWb/Project.toml
<b>└ </b>startup: files 0.0s · plan 0.1s · setup 1.2s
⚪ w0 · 14:52:16 · <b>INFO</b> · 0/6 · 0 failed · 0/2 workers · tree mem 920M (max 920M) · child max 449M · mem 82% · cpu  5.5/18 · testing 0s
⚫ w1 · 14:52:16 · <b>UP  </b> · pid 35898 · threads 2,1
⚫ w2 · 14:52:16 · <b>UP  </b> · pid 35899 · threads 2,1
🔵 w2 · 14:52:16 · <b>RUN </b> · 5/6 · "chain one"  · at <b>test/sub/b_test.jl:1</b>
🔵 w1 · 14:52:16 · <b>RUN </b> · 1/6 · "slow thing" · at <b>test/sub/b_test.jl:9</b>
🟢 w1 · 14:52:16 · <b>DONE</b> · 1/6 · "slow thing" · PASS ·  0.0s (94% compile) · maxrss 0.3 GiB
</pre>

⚫ is a worker starting or ending, 🔵 an item starting, 🟢 an item that passed, 🔴
one that failed, errored or timed out, and 🟡 one skipped or never reached. ⚪ is
the run's progress line: on a terminal it stays at the bottom and is redrawn as the
run goes; otherwise it is printed every `monitor_interval` seconds, every 10 finished
items but no sooner than 5 seconds after the previous one, when the run moves from
setup to testing, and when the machine's memory crosses 90%.

The header names the Julia flags of the workers that a plain `julia` does not have,
such as `--check-bounds=yes -O1`, and the variables that set run settings.

An item that did not pass gets its results and captured output right after its
`DONE` line:

<pre>
🔴 w1 · 12:55:14 · <b>DONE</b> · 1/1 · "fails" · FAIL ·  0.0s (92% compile) · maxrss 0.3 GiB
<b>┌ [1/1] FAIL</b> "fails"
<b>│ </b><b>Test Failed</b> at <b>test/faults_test.jl:6</b>
<b>│ </b>  Expression: 1 == 2
<b>│ </b><b>[ No captured logs</b>
<b>└ </b>@ test/faults_test.jl:5 on worker 1
</pre>

The run ends with what it cost, stage by stage, followed by `Test`'s usual summary:

<pre>
<b>┌ [TEST]</b> ran 6 test items in 2.1s on 2 workers, all passed
<b>│ </b>setup   · 1.1s · tree max  445M · child max  445M · coordinator
<b>│ </b>testing · 0.9s · tree max  1.0G · child max  460M · coordinator + 2 workers · 85% compile
<b>│ </b>(summed resident sizes over-count pages the processes share)
<b>│ </b>machine · 52.9G of 64.0G in use at peak
<b>│ </b>cpu · 8% of 18 threads for this run's processes, 24% for the whole machine (averages over the run)
<b>└ </b>run state: ~/.julia/runtests/runs/MyPackage-8db4f545/1790247276123456-96211.rundata
</pre>

The `run state` line names the run's directory, which also holds what the items
printed (see [Run state](#run-state)). When items failed, the block says how to run
them again: `Runtests.runtestsf()`, or `Runtests.runtestsf(replay = "<run>.rundata")`
where the run's directory was copied for CI.

The memory figures cover every process the run owns: the coordinator, the workers,
and whatever they spawn, such as `Pkg` precompiling or a process a test starts.
`tree max` is the peak of their sum, `child max` the largest single process, and
the list after it says what the peak was summed over (`coordinator + 8 workers + 3
spawned`, say).

`cpu` gives two averages over the whole run, each a share of the machine's CPU
threads: how much of them the run's processes used — the coordinator, the workers
and every process they started and waited for — and how busy the machine was with
everything counted. Compare these figures to see how much CPU time other work on
the machine is using. On Windows, which keeps no total for a
process's children, only the machine's share is given.

If memory gets tight the run holds off on new items, collects garbage, and only
then restarts the largest worker, once the item it is running has finished: a
running item is never stopped for memory, which may be someone else's. The hold
ends once memory is two points below `memory_threshold`, and the run says when it
does. It is also bounded, so pressure caused by something else on the machine slows
a run down but never stalls it.

A run that goes longer without any item finishing than one attempt at any of them
may take (the largest `timeout`, the profiles' `init` and `test_end` limits, a
memory hold, and five minutes to spare) is stopped as hung: the workers are killed,
the items that were running are recorded as timed out, and `runtests` throws. An
item past its own timeout is killed long before that, so this catches only what
should have stopped and did not.

### What each item costs

To collect figures for each item, give `runtests` a function as `on_item`. The run
calls the function in the process that called `runtests`. It calls it when each
attempt at an item starts, and again when the attempt ends. A retry is a new
attempt, so it gets two calls of its own.

```julia
events = Runtests.ItemEvent[]
Runtests.runtests(on_item = ev -> ev.kind === :finished && push!(events, ev))
sort!(events; by = ev -> ev.cpu, rev = true)   # the items that used the most CPU time first
```

Each call gets a `Runtests.ItemEvent` with these fields:

| Field | Meaning |
|:------|:--------|
| `kind` | `:started` or `:finished`. |
| `name`, `file`, `line` | The item. |
| `attempt` | 1 for the first attempt, 2 for the first retry, and so on. |
| `worker`, `pid` | The number of the worker that ran the attempt, as in `w1` in the lines of the run, and the ID of its process. `pid` is 0 when no process ran the attempt. This happens when the run cannot start a worker, for example because the `init` of the profile fails. It also happens to an item of a chain whose worker died before the item ran. For that item, `worker` is 0 too. |
| `time` | When the attempt started or ended, as `time()` gives it. |
| `state` | `:running` when the attempt starts. When it ends, the outcome: `:passed`, `:failed`, `:errored`, `:timedout`, `:skipped`, `:broken_chain`, or `:cancelled`. |
| `measured` | `true` when the item measured the figures below itself. |
| `elapsed` | Seconds that the attempt took. |
| `cpu` | Seconds of CPU time that the process used, in its own code and in the kernel, over all its threads. |
| `compile`, `recompile` | Seconds of compilation, and the part of them that was recompilation. |
| `gc` | Seconds of garbage collection. |
| `allocated` | Bytes allocated. |
| `allocations` | The number of allocations. |
| `maxrss` | The most memory that the process held in RAM so far, in bytes. |

The figures come with the second call only. Each figure except `elapsed` is for the
whole process. A worker runs one item at a time, so its figures belong to that item.
With `workers = 0`, the process is the one that called `runtests`, and the figures
also include the work that the run itself does in that process.

Sometimes the run decides the outcome, and the item measures nothing. This is the
case for a timeout, a worker that died, an item of a chain that cannot run, and a
stopped run. Then `measured` is `false`, the figures are 0, and `elapsed` is the time
that the attempt held its worker.

The run makes one call at a time, from its own tasks, and waits for each call to
return. A slow function thus makes the run slow. If the function throws an error, the
run reports the error once and does not call the function again. The tests continue.
An attempt that is in progress when the run is interrupted can end without its second
call.

## At the REPL

```julia
Runtests.activate()        # or Runtests.activate("path/to/Package")
Runtests.deactivate()
```

`activate` puts the session where a test item's worker is: the package's test
environment active, and `test/testsetups/` on `LOAD_PATH`. `using MySetups` and the
package's test-only dependencies then work the way they do inside an item.
`deactivate` puts both back.

A `@testitem` pasted into the REPL runs there and then:

```julia
julia> @testitem "adds numbers" begin
           @test 1 + 1 == 2
       end
🔵 16:30:28 · RUN  · "adds numbers" · at REPL[2]:1
Test Summary: | Pass  Total  Time
adds numbers  |    1      1  0.0s
🟢 16:30:28 · DONE · "adds numbers" · PASS ·  0.0s (96% compile) · maxrss 0.6 GiB
```

It is read by the same parser as a test file, so a keyword that would be an error
in a file is an error here, and it runs the same way: fresh module, soft scope,
`Test` and the package in scope. `skip` and `failfast` are honoured, and so is
`sandbox` and `profile`, by starting a worker for the item under the profile and
in the environment a run would give it (`[profiles.default]` without a `profile`):
its flags, environment variables, preferences, `init`, and `test_end`, whose
failures count. An item from a file in an [environment](#environments) directory
gets a worker of its own in that environment too. `timeout`, `retries` and `chain` need
a run around the item, so they are ignored with a warning, except that an item
with a worker of its own keeps its `timeout` and `retries`. `tags` are ignored.

With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, `Runtests.debug`
steps into one test item, here in this process:

```julia
julia> using Debugger

julia> Runtests.debug()                 # the most recent failure

julia> Runtests.debug("adds numbers")   # seed = … to draw the random numbers a run drew

julia> Runtests.debug(r"^adds")         # the one item whose name matches

julia> Runtests.debug("test/math_test.jl:12")   # the item line 12 is inside
```

`debug` steps into exactly one item: one an exact name, a `Regex` or a path picks. A
path is read as `runtests` reads one, relative to the current directory: a
`file.jl:line`, or a file or directory that holds one item. What picks no item, or
several, is an error that lists what it found.

Without a name it steps into the most recent failure among the items that are
failing, with the seed it failed with, and names the other failing items. When
nothing is failing, there is nothing to step into, and it says so. A failing item
named in the call runs with the seed it failed with too. The item gets what a run gives it: its
module and imports, its environment and the setups, and its profile's `env`,
`init` and `test_end`. Its body is a function the debugger enters at the first
call, in the test file. What cannot be part of a function (`using`, `struct`,
`const`, a method on `Base.show` and the like) has run by then. Only that item
runs, not the items before it in a chain. What one process cannot give the item,
such as a profile's `julia_args` or `sandbox=true`, is listed before it starts. An
item you leave the debugger in before it has finished is recorded as an error, not
a pass.

## Inside a test item

```julia
import Runtests               # in the item's body
Runtests.current_testitem()   # a TestItemInfo: name, file, line, attempt, profile; or nothing
```

These are for test infrastructure: temporary directories, fixture paths, switching
off telemetry. Library code that changes what it does because it detects that it
is under test stops testing the library. Loading Runtests in an item costs each worker
a moment the first time.

### Evidence from a failed attempt

An item can keep files that explain a failure: outputs it writes while it runs, and
files that producers (functions the item registers) write after the attempt has
failed.

```julia
@testitem "image matches reference" begin
    import Runtests
    actual = render_scene()
    reference = load_reference()

    Runtests.on_failure() do dir
        save(joinpath(dir, "actual.png"), actual)
        save(joinpath(dir, "difference.png"), difference(actual, reference))
    end

    @test actual ≈ reference
end

@testitem "compiled program runs" begin
    import Runtests
    dir = Runtests.artifacts_dir()
    executable = compile_program(dir)
    @test success(run(ignorestatus(`$executable`)))
end
```

`Runtests.artifacts_dir()` makes and returns the attempt's `files/` directory, the
same one each time within an attempt. Write outputs there directly. Nothing is
copied. `Runtests.on_failure(f)` registers a producer and returns `nothing`. It does
not call `f`. If the attempt fails, Runtests calls each producer once, in the order
of registration, with a directory of its own, `producer_<k>/`. The test owns the
file names in both directories.

An attempt fails when an assertion fails or the item throws, in its body or in its
profile's `test_end`. A skipped item, an expected-broken assertion, and an attempt
that passes do not run producers. An attempt that passes deletes what it wrote.

Each attempt keeps its evidence beside its log, in the run's directory:

```text
<run>.rundata/
  run.runstate              # the run's record
  item_7_1.log
  item_7_1.failure.txt
  item_7_1.artifacts/
    files/                  # Runtests.artifacts_dir()
    producer_1/             # the first producer's files
    producer_2/
  item_7_1.artifacts.log    # what the producers printed, their errors, and timings
```

The failure's report and the run's closing block print the path. A retry gets a
directory of its own, so a failed attempt keeps its evidence when a later attempt
passes. The evidence is deleted with the run state, and `RUNTESTS_ARTIFACT_DIR`
copies it with the logs. In the CI example below, `if: failure()` uploads nothing
when a retry passes. Use `if: always()` to keep that evidence too.

Producers run after the verdict is recorded. They see their values as they are
when they run, not as they were when registered. A file that a `mktempdir() do`
block deletes is gone by then: write such files to `artifacts_dir()` instead. A
producer that throws, or a `@test` in it that fails, is reported in the
`.artifacts.log` and does not change the verdict. The next producer still runs.
All the producers of an attempt together have `artifacts_timeout` seconds. If they
take longer, or the worker dies, the worker is replaced and the files written so
far are kept. If the item itself times out or its worker dies, its producers do not
run, and the `.artifacts.log` says why. With `workers = 0`, nothing can stop a
producer that hangs, as nothing can stop an item that hangs.

Both functions work only in the item's body, and in the tasks it starts and waits
for. They throw an `ArgumentError` in `init`, `skip`, `test_end`, a producer, or
outside an item. They also throw for a task that the item did not wait for and that
calls them after the body returned. Evidence is not passed between the items of a
chain, because a passing item's directory is deleted.

A registered producer keeps what it refers to, and the item's globals, until the
verdict is known. A `test_end` such as `GC.gc(true)` does not free that memory. A
passed attempt releases it before its worker runs the next item. A pasted item,
and an item stepped into with `Runtests.debug`, keep their evidence in a new
directory in the system's temporary files. The REPL prints its path, and you delete
it when you no longer need it.

## The environment tests run in

Under `Pkg.test`, Runtests uses the environment Pkg already built. Otherwise it
keeps an already active `test/Project.toml`, activates a test project that shares
the package's workspace, or builds a separate environment with `TestEnv`. Thus
dependencies your package declares only for testing (`[extras]`/`[targets]`, or
`test/Project.toml`) are importable from a test item. Whatever environment you had
active is restored when the run ends.

When a package and its `test/Project.toml` belong to the same workspace, Runtests
activates the test project and instantiates it, as `Pkg.test` does. They share a
manifest, so TestEnv does not build a separate environment.

Environments are cached for the session, so calling `runtests()` again
at the REPL does not re-resolve and re-precompile. The cache notices when you
change `Project.toml` or a manifest, and rebuilds.

The items in an [environment](#environments) directory run in that one instead,
stacked over this one.

## Monorepos

`Runtests.runtests_mono()` runs the test suites of the packages of a Julia workspace
in one run, with one plan, one set of workers and one report. It needs Julia 1.12 or
later. The root `Project.toml` lists the packages under `[workspace]`. Each
participating package has a `test/Project.toml` in that workspace, listed either by
the root or the package's own `[workspace]`. A flat layout lists both in the root:

```toml
[workspace]
projects = ["lib/A", "lib/A/test", "lib/B", "lib/B/test"]
```

Start Julia in a project that declares Runtests directly in `[deps]`, such as the
root project or a member's test project. The workspace manifest alone does not
make `using Runtests` available. If the root package calls `runtests_mono` from its
`test/runtests.jl`, its test environment must declare Runtests.

Items of different packages share workers when their profiles start workers the same
way. Each item runs in the root of its own package, under its own package's profiles,
setups and settings. A `[monorepo]` table in the root's `test/TestItems.toml` lists
the packages that take part (`packages`, directories or globs) and those that run
apart (`isolated`). Before any worker starts, the run stops for an import that a
package's own test environment cannot load, and for two setups of one name. Each
package gets its own run state, so `runtestsf()` in a package runs its failures from
the combined run. To run the combined suites with `Pkg.test` of the root package, its
`test/runtests.jl` calls `Runtests.runtests_mono()`. See the
[monorepo guide](docs/src/guide/monorepos.md) for setup, package selection and
shared profiles.

## Run state

Every run writes a binary record as it progresses, `run.runstate` in a directory of
its own, `<run>.rundata`, and prints the directory's path at the end. Even an
interrupted run leaves a record of completed items. The same directory keeps what
each item printed and the failure report of each item that did not pass. Give a
run's directory from a local run or a downloaded CI artifact to inspect or replay
it. The record file in it works as well:

```julia
Runtests.read_run_state("path/to/the.rundata")
Runtests.runtests(replay="path/to/the.rundata")
Runtests.runtestsf(replay="path/to/the.rundata")
```

`runtests(replay=...)` uses the recorded items, settings, profiles, `[order]`, and
seeds. It gives the workers the Julia flags of the recorded run when this process
has others. Explicit keywords override recorded settings. Replay reports package versions
that differ from the recorded environment; it does not restore those versions.
It also names each recorded item that the suite no longer has, because a renamed
or deleted item cannot run again.
`runtestsf(replay=...)` selects failures using that run's verdicts and those of
runs started after it. Earlier runs contribute durations only.

### What is recorded

- Item outcomes, durations, compilation time, and every attempt.
- Worker starts and exits, including whether a worker timed out, crashed, or
  received an external signal.
- The commit, Julia version and build, machine, settings, the selection and the
  group that made it, profiles, preferences, and random seed. A replay finds each
  item's environment where its file is, in the checkout it runs in.
- Each item's seed, and a hash of its source, which tells an edited item from one
  that only moved.
- The Julia flags that change compiled code, such as `--check-bounds` and `-O`.
- In the run's directory, beside the record: what each item printed, the failure
  report of each attempt that did not pass, and why a run ended before its first
  item.
- `JULIA_*`, `RUNTESTS_*`, and CI job environment variables, excluding names that
  look like credentials.
- The test environment's `Project.toml` and `Manifest.toml`.

### Storage and retention

By default, records live under the Julia depot's `runtests/runs/`, in a directory
per project. Set `RUNTESTS_RUNSTATE_DIR` to use another directory; several projects
can share it. Records are matched by project UUID, falling back to project name,
then directory name.

Only records in that directory contribute to scheduling and failure history.
A record elsewhere is used only when explicitly passed as `replay`, for that call.
Runs are ordered by their recorded start time, regardless of filename or when a
record was downloaded. Each item's latest completed verdict determines whether
it is failing, and its latest recorded duration informs scheduling.

Runtests keeps this machine's newest 20 records. It keeps an older record while
its deletion would change what the records say about an item the suite has: its
latest verdict and when it was recorded, the seed of a failure, its newest duration
and source hash, or whether the newest run that selected it stopped before it. An
item the suite no longer has stays on record, for a branch that still has it, and
keeps no record beyond the newest 20. A record's directory, with its logs, is
deleted with it, and only with it. Records of a deleted project are removed 30 days after its newest run,
unless its parent directory is missing or empty, as with an unmounted drive. A
project in the system's temporary files has no such wait. A run looks for deleted
projects at most once a day.

The machine identity is `RUNTESTS_HOST` when it is set. Otherwise it is the name
macOS gives the machine, which stays the same when the hostname follows the
network, and the hostname elsewhere. Records from other machines are never changed
or deleted. Replay performs no pruning and never deletes the supplied record.

Runtests reads only records in its own format. A run warns once about records of
another version of Runtests, and leaves them alone.

### Keeping history on CI

Cache run states between jobs to preserve scheduling history, and upload each
job's own records and logs as an artifact. `RUNTESTS_ARTIFACT_DIR` names a
directory into which each run copies its own directory, with its record and its
logs, when it ends, also after a failure or an interrupt. For a GitHub Actions matrix with `os`, `version`,
and a [`group`](#groups) per job:

```yaml
# Restore the run states that the last job with this os, version and group saved.
- uses: actions/cache/restore@v4
  with:
    # The run states only, without their logs. The save step must name the same path.
    path: ${{ runner.temp }}/runtests/*.rundata/run.runstate
    # No entry has this key yet. The restore takes the newest entry whose key starts with restore-keys.
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}
    restore-keys: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-
- uses: julia-actions/julia-runtest@v1
  env:
    # The group of test items that this job runs.
    RUNTESTS_GROUP: ${{ matrix.group }}
    # Where the run reads the restored run states and writes its own.
    RUNTESTS_RUNSTATE_DIR: ${{ runner.temp }}/runtests
    # A stable machine name, so that the run also prunes the restored run states.
    RUNTESTS_HOST: ci-${{ matrix.os }}-${{ matrix.version }}
    # Where the run copies its own directory when it ends, for the upload step.
    RUNTESTS_ARTIFACT_DIR: ${{ runner.temp }}/runtests-artifact
# Save the run states for the next job, also when the tests fail.
- uses: actions/cache/save@v4
  if: always()
  with:
    path: ${{ runner.temp }}/runtests/*.rundata/run.runstate
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}
# When the job fails, upload this run's directory: its run state, logs and failure evidence.
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}
    path: ${{ runner.temp }}/runtests-artifact
```

The cache holds the records and leaves the logs out, because the next job plans
from the records alone. Name the records with `*.rundata/run.runstate`. Do not
name the runs' directories, `*.rundata`, with an exclusion such as `!**/*.log`: the
cache archives a directory whole, and the exclusion has no effect. The restore step and the save step must
list the same `path`. The cache finds an entry by its key and by its paths, so a
restore that lists other paths does not find it.
The artifact holds this job's run directory, with its record and logs, and none of
the history. On your machine, run the failures of a downloaded run with
`Runtests.runtestsf(replay = "<run>.rundata")`.

Use a unique cache key per run and `restore-keys` to retrieve the previous cache.
Save it even when tests fail, so the next run sees those failures. A stable
`RUNTESTS_HOST` makes restored records eligible for normal retention instead of
accumulating under a new hostname each run. On CI without it, a run warns when its
directory holds other machines' records.

Every dimension of the matrix belongs in the key: two jobs of one workflow run
with the same key race to save it, and the cache keeps only one of them. A
monorepo whose jobs each test one package (`julia-runtest`'s `project` input) adds
that package to the key, and to the artifact's name, as the group is added here.
An empty `RUNTESTS_GROUP` is unset, so a job whose `matrix.group` is empty runs
what a run selects by default.

### Concurrent runs

An editor, a REPL, or CI jobs can share a run-state directory. Each run claims its
own directory and flushes its record at least every 30 seconds. Completed items supply timing
data immediately; verdicts affect failure history and scheduling priority only
when the run finishes or is declared dead. Active records are never pruned.

A run is considered dead if its record has not been updated for 90 seconds, or
its local process is known to have exited. It then counts as cancelled, with any
item that was running counted as failing. A run whose setup fails finishes its
record as one that ended before its first item, so no other run waits for it. Machines sharing records over a network
must agree on time to within a minute, and each `RUNTESTS_HOST` must identify only
one machine at a time.

## Editors

The [VS Code extension](editors/vscode/README.md) provides a Test Explorer,
per-item results, and a **Run Failed Tests** command. Its README covers local
installation and settings.

`Runtests.serve(path)` lets an editor drive a package's suite. It lists items with
their locations and keywords, runs selected items (or a group or replay), reports
each start and outcome as it happens, and cancels on request. It speaks one JSON
object per line: commands on stdin, events on stdout, and output for people on
stderr.

For a package with a `test/Project.toml` that declares Runtests:

```sh
cd MyPackage && julia --project=test -e 'using Runtests; Runtests.serve()'
```

`Runtests.serve_mono(root)` serves a workspace; its item keys contain both the
package name and the item name. See the
[editor protocol](docs/src/reference/editor-protocol.md) for commands and events.
