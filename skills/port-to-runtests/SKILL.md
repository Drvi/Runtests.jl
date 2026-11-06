---
name: port-to-runtests
description: Port a Julia package's Test.jl, SafeTestsets, ReTestItems or TestItemRunner suite to Runtests.jl, preserving its checks and verifying their outcomes. Use when asked to migrate or adopt Runtests in a package.
---

# Port a test suite to Runtests

Runtests runs a package's tests as independent **test items** on worker processes.
Preserve what each test checks, then compare the ported suite's checks and outcomes
with a baseline run under comparable conditions. The [README](../../README.md) is
the reference for Runtests behavior.

Follow the applicable steps in order. Record pre-existing failures rather than
requiring a green baseline. Ask the user when a change to supported Julia versions,
test selection or test behavior cannot be inferred from the existing suite or CI.

## The target layout

```text
test/
  runtests.jl               using Runtests; Runtests.runtests()
  solver_tests.jl           @testitem declarations and nothing else
  sub/parser_tests.jl
  testsetups/MySetup.jl     code that items share: a module, loaded with `using MySetup`
  testtemplates/            loops that generate items
  TestItems.toml            optional: workers, threads, timeouts, groups, profiles
  testfixtures/             input for the tests (packages, projects, data), never read as tests
  .scripts/                 Julia files that tests run or read, out of Runtests' way
```

- Test files are named `*_test.jl` or `*_tests.jl` and hold only `@testitem`
  declarations. Any other `.jl` file under `test/` stops the run. The exceptions are
  `test/runtests.jl`, `testsetups/`, `testtemplates/`, `testfixtures/`, and hidden
  directories. Any other directory with a `Project.toml` or `JuliaProject.toml`
  of its own is an environment: the test files in it run there.
- An item's name is a nonblank string literal, unique across the whole suite. Its
  keywords (`tags`, `timeout`, `retries`, `skip`, `failfast`, `chain`, `sandbox`,
  `profile`)
  are literals, except `skip`, an expression evaluated before the body.
- A profile's `init` runs in the worker's `Main`, which items do not see: an import
  in `init` loads a package early, but does not reach the items.
- Each item runs in a fresh module, with `Test` and the package already imported.
  Anything else it uses, it imports in its own body.

## 1. Make an environment to run Runtests from

The package's own project may not load its test-only dependencies. Make a separate
environment outside the repository and add Runtests to it:

```sh
RT="$(mktemp -d)/runner"
julia --project="$RT" -e 'using Pkg; Pkg.add("Runtests")'
```

Check: `julia --project="$RT" -e 'using Runtests; print(pkgdir(Runtests))'` prints a path.

## 2. Record what the suite does now

1. Read `test/runtests.jl` and everything it includes. Find the suite's shape in
   [suite shapes](reference/source-shapes.md).
2. Runtests needs Julia 1.11 or later; combined workspace runs need 1.12 or later.
   Read `[compat] julia` in `Project.toml` and the CI matrix in
   `.github/workflows/`. If the tests must keep running on an older Julia, record
   the incompatibility and ask before changing supported versions.
3. Run the original suite as CI does, from the package directory, with the
   environment variables CI sets (once for each `GROUP`, `ARGS` or other selection
   CI uses), and keep the output:

   ```sh
   julia --project=. -e 'using Pkg; Pkg.test()'
   ```

4. Count every check. In a plain Test.jl suite, the `Pkg.test` summary covers only
   checks inside testsets, and the first failing top-level testset ends the script.
   Run that suite once more inside one outer testset, in its test environment.
   Match the CI test process's relevant flags, startup mode and environment.
   `--depwarn=yes` lets `@test_deprecated` record a check:

   ```sh
   julia --startup-file=no --project="$RT" --depwarn=yes --warn-overwrite=yes -e 'using Runtests, Test
       Runtests.activate("."); @testset "baseline" begin include("test/runtests.jl") end'
   ```

   From this summary, record how many checks passed, failed, errored and were broken,
   and which checks did not pass. Those stay as they are: a port fixes nothing.
   A ReTestItems suite prints these totals itself, per file, so its `Pkg.test` run is
   the baseline.

The baseline reads test files until it ends. A `runtests.jl` that runs another
package's tests after its own, with `Pkg.test`, reads that suite last. So do not edit
the checkout while the baseline runs: port in a scratch copy, as step 4 does, and
move the result in after the baseline is done.

Check: you have the baseline totals and the list of checks that did not pass.

## 3. Add Runtests to the test dependencies

Add it next to the package's other test dependencies: `[extras]` and `[targets]` in
`Project.toml`, or `test/Project.toml` if the package has one:

```toml
[extras]            # [deps] in test/Project.toml
Runtests = "632efd68-cd41-4e05-bd25-b86dc2150078"

[targets]           # Project.toml only
test = ["Test", "Runtests"]   # the existing entries, plus this one
```

If the tests run Aqua's `test_all` or `test_deps_compat`, also add
`Runtests = "0.1"` under `[compat]`. Aqua asks every test dependency for a compat
bound.

For a trial against a local checkout of Runtests, a path under `[sources]` works:
`Runtests = {path = "../../Runtests"}`, relative to the project file. But a path names
that local checkout only. CI, and every script that checks the package out somewhere else, such
as a git worktree in a temporary directory, need the registered package. Tell the user which one
the port uses. Develop the same checkout into `$RT` with
`julia --project="$RT" -e 'using Pkg; Pkg.develop(path = "/absolute/path/to/Runtests")'`
so the converter and trial runs use the same Runtests code.

Check: `julia --project=. -e 'using Pkg; Pkg.test()'` runs the original suite
with the recorded outcomes. If resolution reports a stale manifest, inspect it
before changing the baseline. Resolve only when needed, preferably in an isolated
copy, and record the changed dependency graph.

## 4. Convert the suite

The converter [port_testsets.jl](scripts/port_testsets.jl) ports Test.jl suites. In
an installed Runtests it is at
`pkgdir(Runtests, "skills", "port-to-runtests", "scripts", "port_testsets.jl")`.
Treat it as a first pass, and read everything it writes.

Run it on a scratch copy of the test directory, with the package's `Project.toml`
next to it:

```sh
PORT="$(julia --project="$RT" -e 'using Runtests; print(pkgdir(Runtests, "skills", "port-to-runtests", "scripts", "port_testsets.jl"))')"
W="$(mktemp -d)"
cp -R test "$W/test"
cp Project.toml "$W/"
julia "$PORT" "$W/test"
```

It reads the suite the way `runtests.jl` runs it. That covers the files it includes,
directly or in a `@safetestset`. It follows them inside testsets, `if` blocks,
functions and loops over lists it can name, and finds the files SciMLTesting's
`run_tests` or ParallelTestRunner's `find_tests` would run. It also reads the files
those include, and the tests `runtests.jl` holds itself. A file that only runs other
files is read the same way, and then moves to `.scripts/`. In the copy it writes:

- for each test file `a.jl`, the items in `a_tests.jl` (`test_a.jl` also becomes
  `a_tests.jl`), and the file's top-level definitions in `testsetups/ASetup.jl`;
- for each file of definitions the tests include, a setup such as
  `testsetups/HelpersSetup.jl`, loaded where the file was included;
- for the tests in `runtests.jl`, a file named for the package, `my_pkg_tests.jl`;
- a new `runtests.jl`.

It prints each file it moved, as `moved a.jl -> a_tests.jl`, then a list headed "for a
person to look at".

What it does to each file:

- `@testset "name" begin … end` at the top level becomes `@testitem "name" begin … end`.
  The body is kept as written, after `using ASetup` and the file's imports. A body
  that measures `@allocated` of anything but a plain call, calls `include`, declares
  `local x` for a block to assign, or defines a function that assigns one of its
  variables, is wrapped in `let` (see "Scope" below).
- A testset or module that holds only testsets and imports is taken apart into those
  testsets. A testset that also defines something stays whole as one item, so that
  its variables stay its own. A `for` loop around testsets becomes one item per
  testset, with the loop inside it.
- Tests outside any testset, together with the code between them, become one item.
  When that is all the file has besides definitions, or the file has several such
  stretches, the whole file becomes one item that runs as the file did.
- A name that two files share gets the file's name in front: `"a: basics"`.
- Any other top-level statement goes into the setup. A call given `@__MODULE__`,
  such as `RuntimeGeneratedFunctions.init(@__MODULE__)`, also goes into each item: it
  was about the module the tests ran in, and each item is a module of its own.
- An `include` of a file of definitions becomes `using` its setup, plus that file's
  own imports, which the `include` brought into reach. An `include` of a file of tests
  is dropped, and that file is ported on its own.
- Every setup imports `Test`: each file ran where Test was imported, whether in
  `Main` or by `@safetestset`.
- A Julia file that nothing runs moves to `test/.scripts/`, where a run doesn't read
  it. Where it was, it would stop the run.

What it does with `runtests.jl`:

- Its imports reach the items and setups of the files that ran in `Main` after them.
  Its definitions those files use go into a setup of their own, which they load.
- Code that only ran the suite is dropped, and the list names it: printing, `Pkg`
  calls, a definition no test uses such as `const GROUP = …`, and code in a branch
  that is not a test, such as `activate_qa_env()`.
- Files under a `GROUP` branch get the group's tag, and the new `runtests.jl` selects
  items by `GROUP` (see [suite shapes](reference/source-shapes.md)). Groups that
  did not run by default stay out of a default run. Any other condition around
  files becomes `skip = <condition>` on their items.
- Files under a directory with a `Project.toml` or `JuliaProject.toml` of its own
  stay where they are, unported, and the list names them. Port their tests in place:
  Runtests then runs them in that directory's environment. Check whether the old
  runner activated that environment too; if it did not, account for the change.
  A run stops on unported Julia files there.
  A directory that is input for the tests rather than tests, such as a package a
  test loads, moves under `test/testfixtures/` instead (see
  [suite shapes](reference/source-shapes.md)).

Then go through its output:

1. Handle every entry in its "for a person to look at" list.
2. Rename the items it named after their file, such as `"a 2"`. Those come from tests
   without a literal name, like `@testset "case $T" for T in Ts`, which it keeps whole
   as one item. Name each after what it tests. If the cases of a loop should be items
   of their own, make it a [template](reference/templates.md). Do that when each case is
   slow, or when failures need telling apart.
3. Read every setup it wrote. A setup's top-level code runs when its precompile
   cache is built or rebuilt, not once per item.
   - Definitions, imports and constant data belong there. Move anything with a side
     effect, or whose value has to be fresh, into `__init__` or into the items that
     use it: temporary directories, open files, `ENV` changes, random draws, the time,
     a server, data read from a file that can change.
   - `__init__` also runs while another setup that loads this one precompiles. Guard
     what changes another module or the process, such as `Mocking.activate()`:
     `__init__() = ccall(:jl_generating_output, Cint, ()) == 1 || Mocking.activate()`.
   - The converter flags statements that are not definitions, but it counts
     `x = compute()` as a definition and moves it without a word.
   - A setup made from a file that every test file `include`d gives each item that
     loads it the same globals, where each file used to make its own. Look for tests
     that change those globals.
4. Restore any testset options it dropped. `@testset verbose = true "x"`, or a custom
   testset type, survives only as a `@testset` inside the item.

Apply the reviewed output to the repository, including file moves, replacements,
the new `runtests.jl` and the setups. Check `git status` and the diff for missing
files. Git detects renames by content similarity; `git mv` is not required and
would stage a move before the port is reviewed.

A suite of ReTestItems items needs no converter, but the changes around its items are
many and mechanical. Run [port_retestitems.jl](scripts/port_retestitems.jl) on a
scratch copy of the test directory:

```sh
RETEST_PORT="$(julia --project="$RT" -e 'using Runtests; print(pkgdir(Runtests, "skills", "port-to-runtests", "scripts", "port_retestitems.jl"))')"
W="$(mktemp -d)"
cp -R test "$W/test"
cp Project.toml "$W/"
julia "$RETEST_PORT" "$W/test"
```

It moves setups in the files it scans to `testsetups/`, turns `setup = [...]` into
`using`, unquotes `skip`, and lists what is left for a person, such as keywords of
the old `runtests` call. Nested environment directories need a separate pass. A
TestItemRunner suite is ported by hand using [suite shapes](reference/source-shapes.md).

Check: every file in the converter's list of moves is in place, and every entry of
its "for a person to look at" list has been handled.

## 5. Check test/runtests.jl

The converter wrote it: `using Runtests` and `Runtests.runtests()`, or a selection by
`GROUP`. Everything else the old file did has to be accounted for:

- Preserve each check such as Aqua, JET or doctests. The converter may put several
  adjacent checks into one item in the file named for the package; split them if
  separate outcomes matter. See [suite shapes](reference/source-shapes.md).
- A `Random.seed!(…)` before the includes moves into each item whose expected values
  depend on that seed (see "Randomness" below).
- Thread warnings, timing and commented-out coverage code can go.
- A suite the converter could not read, such as a custom runner or files named at run
  time, shows up in its list as files it could not name or did not reach. Port those
  files with the file-list form, `julia "$PORT" "$W/test" - a.jl b.jl`, in the order they
  ran, and add the rest of `runtests.jl` by hand.

Check: nothing the old `runtests.jl` did is lost.

## 6. Move what is not a test file

- Helper files become setup modules (step 4 makes them).
- Julia files that `runtests.jl` did not run are in `test/.scripts/` already (step 4).
  Some of them tests run or read, such as a script started in a subprocess or a `.jl`
  file read as data: update every path that names them. Scripts that no test uses,
  such as data generators or benchmarks, can stay there, or go wherever the user
  wants them.
- Data files that are not `.jl` stay where they are.

Check: from the package directory,
`julia --project="$RT" -e 'using Runtests; Runtests.runtests("."; group = "all", dry_run = true)'` lists
every item and reports no scan errors. It reports any `.jl` file under `test/` that
fits none of the places in "The target layout".

## 7. Run chores, then the suite

From the package directory:

```sh
julia --project="$RT" -e 'using Runtests; Runtests.chores(".")'
julia --project=. -e 'using Pkg; Pkg.test()'
```

`chores` turns each setup into a package: `testsetups/A/src/A.jl`, plus a
`Project.toml` listing what it imports, taken from the test environment. It also
expands templates and checks the suite. Inspect the files it generated and the
resulting diff. When something has to be fixed by hand it throws `ChoresError`:
fix it and run `chores` again. Run it again whenever a setup starts importing
something new.

After conversion, iterate one file at a time with
`Runtests.runtests("test/a_tests.jl")` from `$RT`; even a selected-file run scans
the whole suite for errors. `Runtests.runtestsf(".")` reruns what failed. For each
failure, look in "What changes when a testset becomes an item" below.

Check: the suite runs to the end.

## 8. Show that nothing changed

For every selection CI used (`GROUP`, `ARGS` or another switch), compare the ported
run with the corresponding baseline: which checks ran, their passed, failed,
errored and broken totals, and which checks did not pass. Runtests prints a row per
test file to help locate a difference. Compare checks by their assertion, not their
line number: the converter adds lines to files.

Investigate every difference. Match the environment variables, thread count, OS
and external services before attributing it to the environment. If the original
suite has unseeded random behavior, rerun it to establish what varies. A check
omitted by a new `skip` or tag is lost coverage unless the original selection also
omitted it.

Check: the same checks run for every selection, with matching outcomes under
comparable conditions, or every remaining difference has evidence and is reported.

## 9. Report

Tell the user, in this order:

- the baseline and ported selections, totals and outcomes, with evidence for each
  difference;
- before/after wall times only when measured under comparable conditions; distinguish
  cold and warm runs and make no speed claim without a measurement;
- each change you made by hand beyond the converter, with its reason;
- any decision that would change supported Julia versions, test selection or test
  behavior. Make mechanical CI updates needed for the port, and report them. Split
  long items for speed only when requested, using [speed guidance](reference/speed.md).

Leave the changes uncommitted unless the user asks you to commit.

## What changes when a testset becomes an item

- **Scope.** A testset's body is a local scope, where variables are typed locals. An
  item's body runs at the top level of a module, with the REPL's soft scope, so its
  variables are untyped globals. Put code whose speed or allocations a test measures
  (`@allocated`, `@allocations`, timing) inside `let … end` or a function. In a
  testset, `counter += 1` inside a function the body defines updated the body's
  `counter`; at the top level the function gets a `counter` of its own, so such a
  body keeps its `let` too.
- **One shared `Main`.** In a plain include-based Test.jl suite, files ran in
  `Main` in include order, so a file could use what `runtests.jl` or an earlier file
  defined or imported. SafeTestsets and other runners may already isolate files.
  Each Runtests item has its own module. Import what it uses in the item or a setup.
  Load the setup of every file whose definitions an item uses
  (`using ASetup, BSetup`), or move shared definitions into one setup.
- **State between testsets.** An include-based suite may pass variables, files or
  settings from one testset to the next. Each item has a fresh module, so it must
  build its own values or get them from a setup. A `chain = :name` keeps items in
  order on one worker when intentional process or file state requires that; it does
  not share item variables.
- **Process state.** Changes to `ENV`, the global logger, the working directory,
  preferences, or which packages and extensions are loaded used to last until the
  suite ended. Now the items on a worker run one after another, and each sees what
  earlier ones changed. Restore what an item changes (`withenv`, `try … finally`). If
  an item can't restore it, or needs a package not to be loaded, give it
  `sandbox = true`, which runs it in a process of its own.
- **Printed types.** Where `Main` imported a type's module, types printed
  unqualified. Now `Main` imports nothing, unless a profile's `init` imports a
  package there, so the package's messages print types qualified, as in `FixedPointDecimals.FixedDecimal{Int64, 100}`. Build expected text
  the way the message builds it, with `"… $(FixedDecimal{Int64, 100}) …"`, or print
  with `sprint(show, x; context = :module => @__MODULE__)`.
- **Randomness.** A `Random.seed!` in `runtests.jl` used to decide every draw. Each
  item now draws from the run's seed combined with its own name, and the run prints
  that seed. An item whose expected values come from a fixed seed calls
  `Random.seed!` itself.
- **Threads.** Record the original process's thread count. Workers use
  `--threads=2,1` by default; set `threads` under `[run]` in `test/TestItems.toml`
  or use a profile when tests require another count.
- **Setup code.** Helper code at the top of a file used to run when the file was
  included. In a setup it runs when the precompile cache is built or rebuilt, and
  `__init__` runs when it loads. Items on a worker share the setup's globals, so
  build mutable fixtures inside items.
- **Paths.** Compare each moved helper's original directory with its setup
  location and check paths built from `@__DIR__` or `include`. `chores` rewrites
  `@__DIR__` in a flat setup to preserve that setup location; it does not restore a
  helper's original directory. In an item, `@__DIR__` and `include` are relative to
  the test file, as before.
- **Parallelism.** Plain include-based Test.jl testsets ran one at a time; Runtests items
  can overlap. Give independent items separate temporary paths when shared writes
  were accidental. Preserve intentional shared paths with explicit ordering and
  verify their behavior.
- **Crashes.** An `exit()` or a crash used to end the suite. Now it ends only that
  worker: the item counts as an error and the run goes on.

## Rules

- Never change what a test checks to make it pass, and never delete a test. If a test
  can't pass under Runtests for a reason not covered here, leave it as it is and
  report it.
- Source changes are outside a test-suite port unless the user requests them;
  report source defects that block parity.
- Never edit a file that `chores` generated from a template. Edit the template and run
  `chores` again.
