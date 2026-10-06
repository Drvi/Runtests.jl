# Runtests.jl

[![CI](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml)

Runtests.jl runs a Julia package's tests as independent **test items** across
worker processes. Call `Runtests.runtests()` to run the suite and
`Runtests.runtestsf()` to rerun failures.

Runtests chooses a worker count from the available CPUs and memory, builds the
test environment, and uses previous runs to plan the next one. Recent failures
and long items get priority; other items run in file order to reuse compiled
code. Each run records its results, settings, profiles, and random seed for
[inspection and replay](#run-state).

**Requires Julia 1.12 or later.** Runtests is a vibe-coded package: its code was
written with an AI coding assistant.

- [Quick start](#quick-start) · [Running tests](#running-tests)
- [Test files](#test-files) · [Writing test items](#writing-test-items)
- [Test setups](#test-setups) · [Test templates](#test-templates) · [Suite maintenance](#suite-maintenance)
- [Configuration](#testtestitemstoml) · [Coverage](#coverage)
- [The plan](#the-plan) · [While it runs](#while-it-runs)
- [At the REPL](#at-the-repl) · [Run state](#run-state) · [Editors](#editors)

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
out. Every other selection narrows the failing items, `name` included, so nothing
that is not failing runs. To reproduce a recorded run's settings and seed, use
[`replay`](#run-state).

A normal run returns a `RunTestSet`; a dry run returns `nothing`. Outside an
existing `@testset`, an item that did not pass makes the call throw, so
`Pkg.test()` fails. Inside an existing `@testset`, the result is recorded there.

Problems discovered before execution also throw:

| Error | Cause |
|:------|:------|
| `Runtests.ScanFailure` | Invalid test files, duplicate names, or missing or stale template expansions. |
| `Runtests.NoTestsError` | No test files, no matching items, or no recorded failures for `runtestsf()`. |
| `Runtests.ConfigError` | A mistake in `test/TestItems.toml`, another config file or an environment variable: an invalid setting, profile or group, an undeclared group in `RUNTESTS_GROUP`, or a profile's environment that does not resolve. |
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
    Project.toml                   # an environment of its own, which a profile names
    aqua_tests.jl
  TestItems.toml                   # optional settings, ordering, groups, and profiles
```

Runtests discovers items by parsing test files, without evaluating them in the
coordinator process. Item names must be nonblank string literals and unique
across the suite.

Every Julia file under `test/` must belong to one of the categories above.
Unrecognized files stop the run with an error, so a misnamed test file cannot
silently go untested. Hidden files and directories are excluded from discovery.
A directory with its own `Project.toml` or `JuliaProject.toml` is read only when a
profile names it as its [`environment`](#environments); a run lists the test files
in any other such directory as not run.

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
| `sandbox=:name` | run in the worker pool for `[profiles.name]` of `TestItems.toml` |

Every keyword except `skip` must be a literal; arithmetic on numeric literals,
such as `timeout=5*60`, is also accepted. Invalid values are rejected:
`timeout=true` is not one second. `skip` runs before the body's imports, with
`Test` and the package in scope. It must return a `Bool`; an exception or any other
result is reported as an item error.

A retry uses the same worker unless the worker timed out or crashed, or the item
uses `sandbox=true`. A chain retries from its first item. Named profiles share
workers; use `sandbox=true` when an item needs a fresh process of its own.

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
  changes, including manually edited expansions.
- Removes this machine's obsolete run states, respecting the
  [retention rules](#run-state). Among retained states, it removes only those with
  no information about any current item, such as empty dry runs. Records from
  other machines are preserved.

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

[profiles.qa]
environment = "qa"             # test/qa, with a Project.toml of its own

[profiles.bounds]
julia_args = ["--check-bounds=yes"]
threads = "4"
env = { JULIA_DEBUG = "Main" }
init = "using MyPkg"
test_end = "GC.gc(true)"
preferences = "prefs/bounds.toml"  # optional; this file must exist
```

Select the example profile with `sandbox=:bounds` on an item. Replace `MyPkg`
with your package's name. `[profiles.default]` configures ordinary workers and
the fresh workers used by `sandbox=true`.

`config="path/to/file.toml"` selects a file instead of `test/TestItems.toml`.
The path is relative to the current directory and must exist. No environment
variable or neighbouring file selects a config implicitly. Unknown keys and
invalid values are errors. On a full run, `[order]` must name existing items;
filtered runs allow names of items outside the selection.

**Ordering across profiles or sandbox boundaries is not sequential.** Those
items can run concurrently. Use a `chain` for items that must run in sequence
on one worker; all items in a chain must use the same profile.

A profile's `init` runs once per worker before its items; `test_end` runs after
each item. Each has its own timeout, separate from the item's budget. Failures
in `test_end` count toward the item's result.

The `preferences` path is relative to the config file. Its contents overlay
`LocalPreferences.toml` in a temporary copy of the test environment, with separate
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

A profile with `environment` runs in that directory's environment instead of the
test environment. This is how a suite keeps tests whose dependencies the test
environment should not carry, such as Aqua or JET checks, or a group that needs
other versions:

```text
test/
  TestItems.toml                   # [profiles.qa] environment = "qa"
  qa/
    Project.toml                   # Aqua, JET, ...
    aqua_tests.jl                  # its items run under the qa profile
```

Every test item under the directory runs under that profile, and an item
elsewhere can ask for it with `sandbox=:qa`. The workers run in a copy of the
environment, in the system's temporary files, with the package under test added by
path, which brings the packages its `[sources]` name, such as its siblings in a
monorepo; and with the directory's `LocalPreferences.toml` under the profile's
`preferences`. Nothing is written into the directory. The copy is stacked over the
test environment, as `Pkg.test` stacks its sandbox over the active project: an
item loads the environment's packages first, and can still load the test
environment's. The copy is resolved once a session, and again when a file it was
built from changes; one that does not resolve stops the run before anything runs.

The path is relative to the config file. A directory is one profile's
environment, and never the `default` profile's. A directory with its own project
that no profile names is not read; the dry run, the run's header and its closing
block each say how many test files it holds.

### Run options

| Keyword | Default | Meaning |
|:--------|:--------|:--------|
| `workers` | `"auto"` | Worker count. Auto uses CPU count, threads per worker, and an assumed 4 GiB per worker, capped at 8. |
| `threads` | `"2,1"` | Each worker's Julia `--threads` value. |
| `timeout` | `1800` | Seconds allowed per item attempt. |
| `init_timeout`, `test_end_timeout` | `timeout` | Separate limits for profile hooks. |
| `retries` | `0` | Additional attempts after failure, from 0 to 126. |
| `failfast` | `false` | Stop the run after an item fails. |
| `item_failfast` | `failfast` | Stop each item at its first failure. |
| `logs` | `:issues` | Print output for nonpassing items. Use `:batched` for every item's output when it ends, or `:eager` to stream it. |
| `verbose` | `false` | Print results and output for passing items too. |
| `memory_threshold` | `0.9` | Fraction of machine memory in use at which new items wait; must be in `(0, 1]`. |
| `monitor` | `true` | Monitor memory and display progress. |
| `monitor_interval` | `30` | Seconds between progress lines outside a terminal, which also print every 10 finished items; `0` prints at each sample, five times a second. |
| `full_stacktraces` | `false` | Include Runtests' internal frames in failure backtraces. |
| `full_names` | `false` | Print long names in full instead of [unique prefixes](#the-plan). |
| `testset_name` | `"Runtests"` | Summary testset name; useful for several runs inside one `@testset`. |
| `coverage` | `false` | Write merged line coverage to `lcov.info`; see [Coverage](#coverage). |
| `seed` | random | Seed combined with each item's name. `0` chooses a random seed; the run prints the chosen value. |
| `dry_run` | `false` | Print the plan without executing tests. |
| `replay` | `nothing` | Path to a recorded [run state](#run-state). |
| `config` | `test/TestItems.toml` | Config file to read; an explicit path is relative to the current directory. |
| `group` | `RUNTESTS_GROUP`, else `default`, when nothing else selects | A [group](#groups) to run; `"all"` for the whole suite. |

An interactive run with at most one worker defaults to `logs=:eager`. All options
above except `dry_run`, `replay`, `config`, and `group` can also go under `[run]`; use TOML
strings for symbols, such as `logs = "issues"`. Explicit keywords override the file.

Timeouts must be positive and at most 2,147,483,647 seconds; fractional values
round up to whole seconds. Invalid settings are rejected before execution.

With `workers = 0` the items run in this process, one after another. An item that
needs a process of its own (`sandbox=true`, or a profile) still gets one, started
and stopped around it, and the run lists which items did.

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
<b>┌ [TEST]</b> dry run · v0.1.0 · julia 1.13.0 · 6 test items in 2 files · 2 workers · threads 2,1
<b>│ </b>startup: files 0.0s · plan 0.0s
<b>│ </b>setups: `BasicSetup`
<b>│ </b>timeout: 1800s · retries: 0 · failfast: false · logs: issues · memory_threshold: 0.9
<b>└ </b>order and workers: predicted as if every item took as long, since no durations are recorded yet

  <b>#</b> · <b>worker</b> · <b>test item   </b> · <b>at                  </b> · <b>tags      </b> · <b>why here     </b> · <b>details</b>
  1 ·     w1 · "slow thing" · test/sub/b_test.jl:9 · slow       · [order] first · timeout 120s
  2 ·     w2 · "chain one"  · test/sub/b_test.jl:1 ·            ·               · chain `seq` 1/2
  3 ·     w2 · "chain two"  · test/sub/b_test.jl:5 ·            ·               · chain `seq` 2/2
  4 ·     w1 · "add works"  · test/a_test.jl:1     · fast
  5 ·     w2 · "uses setup" · test/a_test.jl:11    ·            ·               · setup `BasicSetup`
  6 ·     w1 · "mul works"  · test/a_test.jl:6     · fast, math
</pre>

The table lists the items in the order the run is expected to start them, each
with the worker expected to run it. The prediction plays out the run's own
dispatch with the durations earlier runs recorded, so it is as good as they are.

A run hands out, in this order:

1. the items `[order] first` names;
2. sandboxed items, while every process is still fresh;
3. items that failed recently, or whose file changed since the last run;
4. items long enough to set the length of the run: at least 3 s, and over a quarter
   of a worker's share of the work;
5. everything else, in file order, each worker walking its own stretch of files so
   that neighbouring items reuse what it has compiled;
6. the items `[order] last` names.

The first four and the last go to whichever worker is free, and a worker that
finishes its own stretch takes over half of the longest one left. A worker whose
profile has nothing left restarts under the profile whose workers have the most
left each, when that saves more than a fresh worker costs: starting, and compiling
what the others already have. `why here` says which rule placed an item, when it
was not file order.

A name much longer than the rest is shortened to `r"^…"`, here and in a run's
`RUN` and `DONE` lines: a prefix that no other item's name in the suite starts
with, which picks that item out when passed as `name=`. `full_names = true` writes
every name whole.

## While it runs

Workers, test items and the run itself each get lines of one shape:

<pre>
<b>┌ [TEST]</b> v0.1.0 · julia 1.13.0 · 6 test items in 2 files · seed 0x0c15831ed3676a15 · 2 workers · threads 2,1
<b>│ </b>env: /var/folders/…/jl_vWMrc1/Project.toml
<b>└ </b>startup: files 0.0s · plan 0.1s · setup 1.4s
⚪ w0 · 12:54:36 · <b>INFO</b> · 0/6 · 0 failed · 0/2 workers · tree mem 845M (max 845M) · child max 448M · mem 89% · cpu 10.6/18 · testing 1s
⚫ w1 · 12:54:37 · <b>UP  </b> · pid 96279 · threads 2,1
⚫ w2 · 12:54:37 · <b>UP  </b> · pid 96280 · threads 2,1
🔵 w1 · 12:54:37 · <b>RUN </b> · 1/6 · "slow thing" · at <b>test/sub/b_test.jl:9</b>
🔵 w2 · 12:54:37 · <b>RUN </b> · 5/6 · "chain one"  · at <b>test/sub/b_test.jl:1</b>
🟢 w1 · 12:54:37 · <b>DONE</b> · 1/6 · "slow thing" · PASS ·  0.0s (93% compile) · maxrss 0.3 GiB
</pre>

⚫ is a worker starting or ending, 🔵 an item starting, 🟢 an item that passed, 🔴
one that failed, errored or timed out, and 🟡 one skipped or never reached. ⚪ is
the run's progress line: on a terminal it stays at the bottom and is redrawn as the
run goes; otherwise it is printed every `monitor_interval` seconds, every 10 finished
items but no sooner than 5 seconds after the previous one, when the run moves from
setup to testing, and when the machine's memory crosses 90%.

An item that did not pass gets its results and captured output right after its
`DONE` line:

<pre>
🔴 w1 · 12:55:14 · <b>DONE</b> · 1/1 · "fails" · FAIL ·  0.0s (92% compile) · maxrss 0.3 GiB
<b>┌ [1/1] FAIL</b> "fails"
<b>│ </b><b>Test Failed</b> at <b>test/faults_test.jl:6</b>
<b>│ </b>  Expression: 1 == 2
<b>│ </b><b>No captured logs</b>
<b>└ </b>@ test/faults_test.jl:5 on worker 1
</pre>

The run ends with what it cost, stage by stage, followed by `Test`'s usual summary:

<pre>
<b>┌ [TEST]</b> ran 6 test items in 3.3s on 2 workers, all passed
<b>│ </b>setup   · 1.3s · tree max  422M · child max  422M · coordinator
<b>│ </b>testing · 1.8s · tree max  1.0G · child max  452M · coordinator + 2 workers · 87% compile
<b>│ </b>(summed resident sizes over-count pages the processes share)
<b>│ </b>machine · 57.7G of 64.0G in use at peak
<b>│ </b>cpu · 9% of 18 threads for this run's processes, 14% for the whole machine (averages over the run)
<b>└ </b>run state: ~/.julia/runtests/runs/MyPackage-8db4f545/1790247276123456-96211.runstate
</pre>

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
`sandbox`, by starting a worker for the item under the profile a run would give it
(`[profiles.default]` for `sandbox=true`): its flags, environment, preferences,
`init`, and `test_end`, whose failures count. `timeout`, `retries` and `chain` need
a run around the item, so they are ignored with a warning, except that an item
with a worker of its own keeps its `timeout` and `retries`. `tags` are ignored.

With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, `Runtests.debug`
steps into one test item, here in this process:

```julia
julia> using Debugger

julia> Runtests.debug()                 # the last run's most recent failure

julia> Runtests.debug("adds numbers")   # seed = … to draw the random numbers a run drew

julia> Runtests.debug(r"^adds")         # the one item whose name matches

julia> Runtests.debug("test/math_test.jl:12")   # the item line 12 is inside
```

`debug` steps into exactly one item: one an exact name, a `Regex` or a path picks. A
path is read as `runtests` reads one, relative to the current directory: a
`file.jl:line`, or a file or directory that holds one item. What picks no item, or
several, is an error that lists what it found.

Without a name it steps into the failure the last run recorded most recently, with
that run's seed, and names the run's other failures; if the last run passed, there
is nothing to step into and it says so. The item gets what a run gives it: its
module and imports, the test environment and setups, and its profile's `env`,
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
Runtests.in_testitem()        # Bool, for this task and the tasks it spawns
Runtests.in_test_run()        # Bool, process-level, inherited by subprocesses
```

These are for test infrastructure: temporary directories, fixture paths, switching
off telemetry. Library code that changes what it does because it detects that it
is under test stops testing the library. Loading Runtests in an item costs each worker
a moment the first time.

## The environment tests run in

Under `Pkg.test`, Runtests uses the environment Pkg already built. Otherwise it builds
one with `TestEnv`, so dependencies your package declares only for testing
(`[extras]`/`[targets]`, or `test/Project.toml`) are importable from a test item.
Whatever environment you had active is restored when the run ends.

Generated environments are cached for the session, so calling `runtests()` again
at the REPL does not re-resolve and re-precompile. The cache notices when you
change `Project.toml` or a manifest, and rebuilds.

The items of a profile that names an [environment](#environments) run in that one
instead, stacked over this one.

## Run state

Every run writes a binary record as it progresses and prints its path at the end.
Even an interrupted run leaves a record of completed items. Use a record from a
local run or a downloaded CI artifact to inspect or replay it:

```julia
Runtests.read_run_state("run.runstate")
Runtests.runtests(replay="run.runstate")
Runtests.runtestsf(replay="run.runstate")
```

`runtests(replay=...)` uses the recorded items, settings, profiles, and seed.
Explicit keywords override recorded settings. Replay reports package versions
that differ from the recorded environment; it does not restore those versions.
`runtestsf(replay=...)` selects failures using that run's verdicts and those of
runs started after it. Earlier runs contribute durations only.

### What is recorded

- Item outcomes, durations, compilation time, and every attempt.
- Worker starts and exits, including whether a worker timed out, crashed, or
  received an external signal.
- The commit, Julia version and build, machine, settings, the selection and the
  group that made it, profiles and the environment each names, preferences, and
  random seed. A replay finds a profile's environment in the checkout it runs in.
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

Runtests keeps this machine's newest 20 records, plus any older record containing
a failing item's latest verdict. A full run retires failures for items that have
been renamed or deleted; with a `default` group, that is a run with `group="all"`. Records for a deleted project are also removed, unless
its parent directory is missing or empty, as with an unmounted drive.

The machine identity is its hostname, overridden by `RUNTESTS_HOST`. Records from
other machines are never changed or deleted. Replay performs no pruning and
never deletes the supplied record.

### Keeping history on CI

Cache run states between jobs to preserve scheduling history, and upload them
as artifacts after failures. For a GitHub Actions matrix with `os`, `version`, and
a [`group`](#groups) per job:

```yaml
- uses: actions/cache/restore@v4
  with:
    path: ${{ runner.temp }}/runtests
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}
    restore-keys: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-
- uses: julia-actions/julia-runtest@v1
  env:
    RUNTESTS_GROUP: ${{ matrix.group }}
    RUNTESTS_RUNSTATE_DIR: ${{ runner.temp }}/runtests
    RUNTESTS_HOST: ci-${{ matrix.os }}-${{ matrix.version }}
- uses: actions/cache/save@v4
  if: always()
  with:
    path: ${{ runner.temp }}/runtests
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}-${{ github.run_id }}-${{ github.run_attempt }}
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: runtests-run-state-${{ matrix.os }}-${{ matrix.version }}-${{ matrix.group }}
    path: ${{ runner.temp }}/runtests
```

Use a unique cache key per run and `restore-keys` to retrieve the previous cache.
Save it even when tests fail, so the next run sees those failures. A stable
`RUNTESTS_HOST` makes restored records eligible for normal retention instead of
accumulating under a new hostname each run.

Every dimension of the matrix belongs in the key: two jobs of one workflow run
with the same key race to save it, and the cache keeps only one of them. A
monorepo whose jobs each test one package (`julia-runtest`'s `project` input) adds
that package to the key, and to the artifact's name, as the group is added here.
An empty `RUNTESTS_GROUP` is unset, so a job whose `matrix.group` is empty runs
what a run selects by default.

### Concurrent runs

An editor, a REPL, or CI jobs can share a run-state directory. Each run claims its
own file and flushes it at least every 30 seconds. Completed items supply timing
data immediately; verdicts affect failure history and scheduling priority only
when the run finishes or is declared dead. Active records are never pruned.

A run is considered dead if its record has not been updated for 90 seconds, or
its local process is known to have exited. It then counts as cancelled, with any
item that was running counted as failing. Machines sharing records over a network
must agree on time to within a minute, and each `RUNTESTS_HOST` must identify only
one machine at a time.

## Editors

The [VS Code extension](editors/vscode/README.md) provides a Test Explorer,
per-item results, and a **Run Failed Tests** command. Its README covers local
installation and settings.

`Runtests.serve(path)` lets an editor drive a package's suite: it lists the test items
with where they are and what they declare, runs the ones asked for, reports each
item's start and outcome as it happens — failures with their file and line — and
cancels a run on request. It speaks one JSON object per line: commands on stdin,
events on stdout, and everything written for people on stderr.

```sh
cd MyPackage && julia --project=test -e 'using Runtests; Runtests.serve()'
```
