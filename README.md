# Runtests.jl

[![CI](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml)

Runtests.jl runs a package's tests as independent *test items* spread over worker processes,
and plans each run from what the runs before it recorded: what failed last time runs first,
the longest items start early, and the rest go in file order, so that a worker reuses the code
it has already compiled. Every run leaves a record that is enough to run it again elsewhere.

The aim is a workflow with next to nothing to decide. Most of the time you call
`Runtests.runtests()` to run the suite and `Runtests.runtestsf()` to run again what
failed, and Runtests picks the rest: how many workers the machine has room for, what
order the items run in, whose output is worth printing, and the environment the tests
need. Every one of those choices has a keyword for when the default is wrong for you
(see [Running tests](#running-tests)).

Runtests is a vibe-coded package: its code was written with an AI coding assistant.

Julia 1.12+. Beyond the standard library it needs three packages: `TestEnv` to
build the environment tests run in, `PrecompileTools` to keep the wait before the
first test item short, and `RuntestsWorkers`, the part of Runtests a worker process loads.
With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, it can step
into a test item.

## Quick start

Add Runtests to the package's test dependencies (`test/Project.toml`, or `[extras]`
and `[targets]` in `Project.toml`), and make `test/runtests.jl`:

```julia
using Runtests
Runtests.runtests()
```

Then write test items in files named `*_test.jl` or `*_tests.jl`:

```julia
# test/arithmetic_tests.jl
@testitem "adds numbers" begin
    @test 1 + 1 == 2
end
```

`Pkg.test()` runs them as usual. At the REPL, `Runtests.runtests()` runs the suite of
the active project, building its test environment itself.

## Test files

```
test/
  runtests.jl          using Runtests; Runtests.runtests()
  solver_test.jl       @testitem declarations, and nothing else
  sub/parser_tests.jl
  periods_tests.jl     the items its template declares, which Runtests.chores() writes
  testsetups/
    MySetups.jl        ordinary modules that test items load with `using`
  testtemplates/
    periods_tests_template.jl   @testtemplate declarations, each a loop
  TestItems.toml       optional: run settings, forced ordering, sandbox profiles
```

A test file contains only `@testitem` declarations. Runtests reads test files by
parsing them, never by evaluating them, so a test file cannot run anything in the
process that is coordinating the run.

Every Julia file under `test/` has to be a test file, a test template in
`testtemplates/` (see [Test templates](#test-templates)), a module in `testsetups/`,
or `runtests.jl`. Files inside a directory with its own `Project.toml` or
`JuliaProject.toml`, such as a package of test helpers, are left alone, and so are
hidden (dot-prefixed) files and directories. Anything else stops the run until it
is named, moved or removed: a file of tests that nobody named `*_test.jl` would
otherwise sit there for months, never read, while the suite reported a clean pass
without it.

A run reads every test file whatever it was asked to run: a suite that does not
parse, or that declares one name twice, is a broken suite rather than a smaller
one. What a filter decides is which items *run*.

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
| `timeout=N` | seconds before the item is killed |
| `retries=N` | attempts after a failed one; the item's value wins over the run's |
| `skip=expr` | `true`, or an expression evaluated on the worker before the body |
| `failfast=true` | stop this item at its first failure |
| `chain=:sym` | items sharing a chain run in sequence, on one worker |
| `sandbox=true` | run alone in a process that is torn down afterwards (not with `chain`) |
| `sandbox=:name` | run under `[profiles.name]` of `TestItems.toml` |

Every keyword except `skip` must be a literal of the kind the table says:
`timeout=true` is refused rather than read as one second. `skip` sees `Test` and
the package, as the body does before its own imports, and must give a `Bool`; an
error in it is the item's error, reported as one in the body would be. A retry runs on the same
worker, unless the failure took the worker with it (a timeout, a crash) or the item
is sandboxed; the failed attempt's report says which.

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

An item loads it with `using MySetups` or `import MySetups`, which is also how
Runtests knows which setups an item needs. Before any worker starts, it precompiles
each of them once, so that the workers do not all compile the same module at the
same moment. A setup is precompiled like any package: its top-level code runs when
it is compiled, and what has to happen in every process goes in its `__init__`.

A setup without a project of its own has no UUID, and Julia keeps a single cache
file for it per depot: another checkout with a setup of the same name, or a profile
with other Julia flags, compiles over it. `Runtests.setups_to_packages()` makes every
setup a package, after which each checkout and each set of flags keeps its own
cache. `Name.jl` moves to `Name/src/Name.jl`, beside a `Name/Project.toml` with a
UUID and the packages the setup imports, and a run precompiles it for the Julia
flags of every profile before any worker needs it. In a moved setup, `@__DIR__`
becomes `pkgdir(MyPkg, "test", "testsetups")`, which still names that directory
when the code is pasted at the REPL. A package can import only what its project
lists, so run it again after a setup starts importing something new.

### Test templates

A test item per element of a list that code computes, such as the subtypes of an
abstract type or the files of a data directory, comes from a template in
`test/testtemplates/`: `periods_tests_template.jl` there expands into the test file
`test/periods_tests.jl`.

```julia
# test/testtemplates/periods_tests_template.jl
@testtemplate "doubling a $P of $n" tags=[:gen] for P in filter(T -> T <: DatePeriod, [Day, Hour, Month]), n in 1:2
    using Dates
    @test $P($n) + $P($n) == $P(2 * $n)
end
```

A template holds `@testtemplate` declarations and nothing else; an ordinary
`@testitem` goes in a test file. A `@testtemplate` declares an item per iteration of
the `for` in its header, the first variable varying slowest, each written out as a
`@testitem` with a literal name. `Runtests.chores()` runs the loops in a process of
its own, with the test environment active and the setups loadable as in a worker,
and each loop sees what its item will: the package and the body's `using` and
`import` statements, here `Dates`. A list several templates share goes in a setup
module, as other shared code does.

```julia
# Expanded from testtemplates/periods_tests_template.jl by `Runtests.chores()`.
# Change the template and run `Runtests.chores()` again, rather than editing this file.
# runtests-expansion 1 433820ad 8fb456c8

@testitem "doubling a Day of 1" tags=[:gen] begin
    using Dates
    @test Day(1) + Day(1) == Day(2 * 1)
end
```

and so on, for `Day` at 2 and `Month` at 1 and 2.

In the name, `$P` interpolates as in any string, with the values printed as the
item's module shows them. In the keywords and the body, `$P` puts the value of
the loop variable `P` there, written as code, as `Threads.@spawn` takes `$x`: `repr`
of it as the item's module sees it with the body's `using` and `import` statements,
in parentheses where the code beside it would bind to it otherwise. It has to
evaluate back to an equal value there, or the template is refused, so a closure or a
type the template defines cannot be looped over. Nothing binds `P` in the item, so
a `P` without its `$` is refused unless the body binds `P` itself: `P = $P` gives it a
variable of that name, wherever the template puts it and with what it shadows there.

In the keywords, a `$(...)` is computed as the template expands, once per iteration
and among the names the loop sees, and its value is written the same way:

```julia
@testtemplate "case $n" skip = $(n in KNOWN_BAD) for n in 1:1000
    using MySetups          # KNOWN_BAD = (42, 666)
    @test check($n)
end
```

gives `@testitem "case 42" skip = true begin`, and `skip = false` to the items not
in `KNOWN_BAD`. What is outside a `$(...)` is the item's, evaluated as it runs:
`skip = Sys.iswindows() || $(n in KNOWN_BAD)` decides its first half on the machine
that runs the item. In the body only a loop variable's `$` is the template's, since a
`$(...)` there may be a macro's: any other `$` is left as it is, for a macro of the
body's own such as BenchmarkTools' `@btime`, and so is every `$` inside a quoted
expression; in a string, `"$($P)"` puts the value in.

The expansion is an ordinary test file: commit it, as `Pkg.test` of an installed
package needs it. Nothing expands a template but `Runtests.chores()`. A run, and
`Runtests.chores(dry_run = true)`, only compare the two files, by the stamp on the
expansion's third line, and a run refuses to start when the expansion is not the
template's: the template changed since it was expanded, the expansion was edited by
hand, or the template is gone. The stamp hashes the text as its author wrote it:
line endings, a byte-order mark and whitespace at the end of the file do not count.

`Runtests.chores()` expands every template each time, since what a template's code
computes can change while its text does not, and writes only the files that change.
On CI, `Runtests.chores()` followed by `git diff --exit-code` fails a commit whose
expansions are out of date.

## Running tests

```julia
Runtests.runtests()                          # everything under test/
Runtests.runtests("test/solver_test.jl")     # one file
Runtests.runtests("test/solver_test.jl:42")  # the item that line is inside
Runtests.runtests(name="adds numbers")       # one item; a Regex matches part of a name
Runtests.runtests(tags=:fast)                # by tag
Runtests.runtests(tags="fast && !slow")      # by tag expression: `!`, `&&`, `||`
Runtests.runtests("test/db"; tags=:fast)     # they narrow together
Runtests.runtests(dry_run=true)              # print the plan, run nothing
Runtests.runtestsf()                         # run what is failing, each item as it last ran
Runtests.chores()                            # tidy the suite; dry_run=true only says what it would do
```

A tag expression is names joined with `&&` and `||`, each optionally negated with
`!`; `&&` binds tighter, and there are no parentheses. `name` also takes several
names, as a vector or a set. A `file.jl:line` target picks one item, so it is given
without other files or directories.

`Runtests.chores()` looks after a suite: it makes packages of the setups that are
not yet, and adds to their `[deps]` what they have come to import; it expands the
test templates (see [Test templates](#test-templates)), and deletes the expansion of
one that is gone; it deletes this machine's run states that nothing reads; and it
reports anything a run would refuse to start on, in the test items or in
`TestItems.toml`, which needs a person, as is an expansion edited by hand. Run
states are kept as a run keeps them, the newest 20 and any older one a failing item's
last verdict is in, and of those only one with nothing about an item the suite has
now goes: a dry run, a run stopped before any item finished, or one whose items have
all been renamed or deleted since. Another machine's run state, a downloaded CI
artifact say, is never deleted. Once it has done what it can, it throws
`Runtests.ChoresError` if anything is left for a person, and otherwise returns
`true`, so `Runtests.chores(); Runtests.runtests()` stops before a long run on a
suite that needs fixing first. `Runtests.chores(dry_run = true)` changes nothing,
never throws, says what it would do, and returns `true` when nothing is left to do.
`Runtests.chores(config = "ci.toml")`, or with several files, checks those too, each
as a run given it would, beside `test/TestItems.toml`.

A run that cannot start throws before any item runs: `Runtests.ScanFailure` when test
files cannot be read as a suite, an expansion out of date with its template among them, `Runtests.NoTestsError` when there is nothing to run,
and `Runtests.ConfigError` when a setting, profile or test setup cannot be used as
given.

| Keyword | Meaning |
|:--------|:--------|
| `workers` | how many worker processes: a number, or `"auto"` (the default: as many as the CPUs allow at `threads` each and memory allows at 4 GiB each, at most 8) |
| `threads` | each worker's `--threads`; `"2,1"` by default |
| `timeout` | seconds an item may run; 1800 by default |
| `init_timeout`, `test_end_timeout` | the same for a profile's `init` and `test_end`; `timeout` by default |
| `retries` | attempts after a failed one; 0 by default |
| `failfast` | stop the run once an item fails |
| `item_failfast` | stop an item at its first failure; `failfast` by default |
| `logs` | whose output to print: `:issues`, only items that did not pass (the default); `:batched`, every item's once it ends; `:eager`, as it is written (the default for an interactive run with one worker) |
| `verbose` | print every item's results and output, passing ones included |
| `memory_threshold` | the share of the machine's memory in use at which the run holds off on new items; 0.9 by default |
| `monitor` | watch memory and show the progress line; on by default |
| `monitor_interval` | how often the progress line is printed when there is no terminal to redraw it on; 30 seconds by default, and 0 prints it five times a second |
| `full_stacktraces` | keep Runtests' own frames in a failing item's backtrace |
| `full_names` | write every item's name whole, where by default one much longer than the rest is shortened to a prefix of its own (see [The plan](#the-plan)) |
| `testset_name` | what the run's testset is called in the summary; `"Runtests"` by default. Runs of several calls under one `@testset` are told apart by it |
| `coverage` | count which lines of `src/` and `ext/` the items run, into `lcov.info` at the package's root; also `RUNTESTS_COVERAGE` (see [Coverage](#coverage)) |
| `seed` | where every item's random numbers start, with its name; random unless given, and printed at the start of the run |
| `dry_run` | print the plan and run nothing |
| `replay` | run a recorded run again (see [Run state](#run-state)) |
| `config` | a file to read in place of `test/TestItems.toml`, relative to the current directory (see [`test/TestItems.toml`](#testtestitemstoml)) |

All but `dry_run`, `replay` and `config` can also go under `[run]` in `test/TestItems.toml`;
a keyword given to `runtests` wins over the file.

With `workers = 0` the items run in this process, one after another. An item that
needs a process of its own (`sandbox=true`, or a profile) still gets one, started
and stopped around it, and the run lists which items did.

### Coverage

`coverage = true`, as a keyword, as `RUNTESTS_COVERAGE=true` in the environment, or
under `[run]` in `TestItems.toml`, has every worker count which lines of the
package's `src/` and `ext/` run. A keyword wins over the variable, and the variable
over the file; the run's opening block says which of them decided. At the end the
workers' counts are merged into `lcov.info` at the package's root, with paths
relative to it, ready for Codecov or Coveralls. Every line of a function that never
ran counts as not covered, in a file that was never loaded too, and the closing
block gives the share that ran:

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
run goes; otherwise it is printed every `monitor_interval` seconds, when the run
moves from setup to testing, and when the machine's memory crosses 90%.

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
everything counted. A run far below the machine is sharing it; a run near the top
of it will not go faster with more workers. On Windows, which keeps no total for a
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

## `test/TestItems.toml`

```toml
[run]
workers = "auto"       # or an integer
timeout = 600          # per test item
init_timeout = 120     # per `init` expression; defaults to `timeout`
test_end_timeout = 60  # per `test_end` expression; defaults to `timeout`

[order]
first = ["build the artifacts"]   # handed out first, in this order
last  = ["tear down the cluster"]

[profiles.bounds]
julia_args = ["--check-bounds=yes"]
threads = "4"
env = { JULIA_DEBUG = "Main" }
init = "using MyPkg"
test_end = "GC.gc(true)"
preferences = "prefs/bounds.toml"
```

The file is read from the package's `test/` directory, unless a call names another
with `config = "path/to/file.toml"`, relative to the current directory, which then
has to exist. Nothing but that keyword makes a run read another file: not an
environment variable, and not a file lying next to the suite.

An unknown key, a value of the wrong kind (a string where a list goes, `true` where
a number does), or a name in `[order]` that is not a test item, is an error: a
misspelled option that silently does nothing is how a suite ends up not running the
way its author believes it does.

An `[order]` pin is relative to the items that run alongside it. Items under
different profiles run concurrently, and a sandboxed item runs concurrently with
the ordinary ones, so pinning across either boundary does not sequence them.

A profile's `init` runs once per worker before any item, and `test_end` runs after
every item, on the same worker but timed against limits of their own. They are
the suite's own code, so what they cost is not charged to the item, and an item's
timeout stays a budget for the item. What `test_end` finds is reported as the
item's result, because that is what it was checking.

A profile's `preferences` file, relative to the directory of the file that declares
the profile (`test/` for `test/TestItems.toml`), is laid over the test
environment's `LocalPreferences.toml` in a copy of the environment that its workers
use, kept among the system's temporary files. Packages see different preferences
there, so they are precompiled separately.

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
```

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

## Run state

Every run writes a binary record as it goes, so a run that is killed still leaves
a readable account of what had finished. It holds what it takes to run the same
run again somewhere else:

- which items ran, how each ended, how long it took and how much of that was
  compilation, and every attempt and every worker's start and end in order: which
  items a worker had run before it died, and whether it exited, was killed for a
  timeout, or was killed by a signal nobody in the run sent;
- the commit, the Julia version and build, the machine, the settings, the
  profiles with their preferences, and the seed every item's random numbers came
  from;
- the environment variables a run's behaviour can depend on (`JULIA_*` and
  `RUNTESTS_*`) and the ones naming the CI job it ran in, leaving out any whose name
  looks like a credential;
- the test environment's `Project.toml` and `Manifest.toml`.

The path is printed at the end of every run. Run states live in the depot, in a
directory per project under `runtests/runs/` named for the project, or in the
directory `RUNTESTS_RUNSTATE_DIR` names, which several projects can share: each reads
only its own, known by the project's UUID, else its name, else the name of its
directory. A run writes its run state there, under a name of its choosing; a call
cannot give it another path. Only the run states in that directory are read, to plan
a run, to find what `runtestsf` runs and to decide what pruning keeps. One anywhere
else, such as a run state downloaded from CI or copied next to the project, counts
only when a call names it with `replay`, and for that call alone. Run states count in
the order they started, as each records it, so a downloaded one counts from when it
ran, whatever it is named.

The 20 most recent that this machine recorded are kept, and so is any older one that
a failing item's last verdict is in, however many runs back: running one item again
and again does not make `runtestsf` forget the others. An item that a run of the
whole suite no longer finds was renamed or deleted: it is not failing from then on,
and keeps no run state. Once a project's directory is gone, the run states this
machine recorded for it are deleted too, unless the directory above it is missing or
empty, as a drive that is not mounted leaves it. The machine is the hostname, or the
name `RUNTESTS_HOST` gives it. One recorded elsewhere, such as a run state downloaded
from CI, is never changed or deleted, wherever it is, and a replay deletes nothing.

On CI, cache them from one run to the next, so each run is ordered by the ones
before it, and keep a failed run's as an artifact:

```yaml
- uses: actions/cache/restore@v4
  with:
    path: ${{ runner.temp }}/runtests
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ github.run_id }}-${{ github.run_attempt }}
    restore-keys: runtests-${{ matrix.os }}-${{ matrix.version }}-
- uses: julia-actions/julia-runtest@v1
  env:
    RUNTESTS_RUNSTATE_DIR: ${{ runner.temp }}/runtests
    RUNTESTS_HOST: ci-${{ matrix.os }}-${{ matrix.version }}
- uses: actions/cache/save@v4
  if: always()
  with:
    path: ${{ runner.temp }}/runtests
    key: runtests-${{ matrix.os }}-${{ matrix.version }}-${{ github.run_id }}-${{ github.run_attempt }}
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: runtests-run-state-${{ matrix.os }}-${{ matrix.version }}
    path: ${{ runner.temp }}/runtests
```

A cache is written once per key, so every run saves under a key of its own, and
`restore-keys` brings back the newest one saved before it. It is saved whether or
not the tests passed: which items failed is what orders the next run most. A
runner has a new hostname every run, so `RUNTESTS_HOST` names the machine: the run
states the cache brings back are then this machine's, and pruned to the newest 20
like a local directory's, where otherwise they would pile up.

Then, locally, `Runtests.read_run_state("run.runstate")` shows what happened, and
`Runtests.runtests(replay="run.runstate")` runs the same items with the same settings,
profiles and seed, naming every package whose version differs from the one CI had.
`Runtests.runtestsf(replay="run.runstate")` runs what is failing counted from that run:
its verdicts and those of the runs after it, the runs before it giving only how long
items take. A run pointed at a run state never deletes it.

Later runs read the run states to plan (see [The plan](#the-plan)), taking each item's
duration from the newest run that ran it, and `runtestsf` runs every item the suite
has whose last verdict in them was not a pass. A replay happens only when
asked: a run state lying next to the project is not a request to run differently,
and an explicit keyword always wins.

Runs can share a directory as they go: CI jobs on one machine, or an editor and a
REPL. Each writes a file of its own, under a name it claims by creating it, and the
others read it part way through. A run still going writes its file at least every 30
seconds, and one whose file has not been written for 90 seconds, or whose process
this machine knows to be gone, is taken to have died. Until a run has finished or
died, its verdicts are not in: it changes nothing about what is failing or what the
next run takes first, though the items it has finished give their durations, and
its file is not pruned, however many runs started since. A run that died counts as a
cancelled one does, and an item it was running when it did is failing. Machines that
share a directory over a network have to agree on the time to within a minute, and a
`RUNTESTS_HOST` names one machine at a time.

## Editors

`Runtests.serve(path)` lets an editor drive a package's suite: it lists the test items
with where they are and what they declare, runs the ones asked for, reports each
item's start and outcome as it happens — failures with their file and line — and
cancels a run on request. It speaks one JSON object per line: commands on stdin,
events on stdout, and everything written for people on stderr.

```sh
cd MyPackage && julia --project=test -e 'using Runtests; Runtests.serve()'
```
