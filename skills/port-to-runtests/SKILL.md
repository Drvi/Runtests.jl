---
name: port-to-runtests
description: Port a Julia package's test suite to Runtests.jl and show that no test changed. Covers Test.jl suites (testsets in runtests.jl or in the files it includes), SafeTestsets, GROUP or ARGS switches, Aqua/JET/doctest checks, downstream tests, and ReTestItems or TestItemRunner items. Use when asked to port, migrate or convert a package's tests to Runtests, to adopt Runtests in a package, or to replace ReTestItems or TestItemRunner with it.
---

# Port a test suite to Runtests

Runtests runs a package's tests as independent **test items** on several worker
processes. A port rewrites the suite as items without changing what any test checks.
Then it proves that: the ported suite makes the same checks, with the same outcomes,
as the original. Runtests' README is the reference for everything below:
`pkgdir(Runtests, "README.md")`, or <https://github.com/Drvi/Runtests.jl>.

Do the steps in order. Each ends with a check that has to pass before the next step.
Where a step says to ask the user, ask: those decisions are theirs.

## The target layout

```text
test/
  runtests.jl               using Runtests; Runtests.runtests()
  solver_tests.jl           @testitem declarations and nothing else
  sub/parser_tests.jl
  testsetups/MySetup.jl     code that items share: a module, loaded with `using MySetup`
  testtemplates/            loops that generate items (reference/templates.md)
  TestItems.toml            optional: workers, threads, timeouts, groups, profiles
  .scripts/                 Julia files that tests run or read, out of Runtests' way
```

- Test files are named `*_test.jl` or `*_tests.jl` and hold only `@testitem`
  declarations. Any other `.jl` file under `test/` stops the run. The exceptions are
  `test/runtests.jl`, `testsetups/`, `testtemplates/`, hidden directories, and
  directories with a `Project.toml` of their own, which are read only when a profile
  names them as its `environment`.
- An item's name is a nonblank string literal, unique across the whole suite. Its
  keywords (`tags`, `timeout`, `retries`, `skip`, `failfast`, `chain`, `sandbox`)
  are literals, except `skip`, an expression evaluated before the body.
- Each item runs in a fresh module, with `Test` and the package already imported.
  Anything else it uses, it imports in its own body.

## 1. Make an environment to run Runtests from

The package's own project cannot load a test-only dependency, so make a separate
environment outside the repository. If Runtests is in the General registry, add it
there with `Pkg.add("Runtests")`; to find out, run
`julia -e 'using Pkg; Pkg.activate(; temp = true); Pkg.add("Runtests")'`. If it isn't,
add it by URL, together with its worker package from the same repository:

```sh
RT=$(mktemp -d)/runner
julia --project=$RT -e 'using Pkg; u = "https://github.com/Drvi/Runtests.jl"
    Pkg.add([PackageSpec(url = u, subdir = "lib/RuntestsWorkers"), PackageSpec(url = u)])'
```

With the package directory as the working directory,
`julia --project=$RT -e 'using Runtests; Runtests.runtests("test/a_tests.jl")'` runs one
file of the suite in the package's test environment.

Before running Runtests on a copy of the package, set `RUNTESTS_RUNSTATE_DIR` to a
scratch directory. A copy has the package's identity, so without that its runs, and
the pruning `chores` does, go into the package's own run history.

Check: `julia --project=$RT -e 'using Runtests; print(pkgdir(Runtests))'` prints a path.

## 2. Record what the suite does now

1. Read `test/runtests.jl` and everything it includes. Find the suite's shape in
   reference/source-shapes.md.
2. Runtests needs Julia 1.12 or later. Read `[compat] julia` in `Project.toml` and the
   CI matrix in `.github/workflows/`. If the tests must keep running on an older
   Julia, stop and ask the user: a package whose tests use Runtests cannot run them
   there.
3. Run the original suite as CI does, from the package directory, with the
   environment variables CI sets (once for each `GROUP` value CI uses), and keep the
   output:

   ```sh
   julia --project=. -e 'using Pkg; Pkg.test()'
   ```

4. Count every check. That run's summary can't do it: it covers only checks inside
   testsets, and the first failing top-level testset ends the script. Run the suite
   once more inside one outer testset, in its test environment, with the flags
   `Pkg.test` passes. Without `--depwarn=yes`, `@test_deprecated` records no check:

   ```sh
   julia --project=$RT --depwarn=yes --warn-overwrite=yes -e 'using Runtests, Test
       Runtests.activate("."); @testset "baseline" begin include("test/runtests.jl") end'
   ```

   From this summary, record how many checks passed, failed, errored and were broken,
   and which checks did not pass. Those stay as they are: a port fixes nothing.

Check: you have the baseline totals and the list of checks that did not pass.

## 3. Add Runtests to the test dependencies

Add it next to the package's other test dependencies: `[extras]` and `[targets]` in
`Project.toml`, or `test/Project.toml` if the package has one. While Runtests is not
registered, both packages come by URL. Leaving `RuntestsWorkers` out fails resolution
with "RuntestsWorkers has no known versions":

```toml
[extras]            # [deps] in test/Project.toml
Runtests = "632efd68-cd41-4e05-bd25-b86dc2150078"
RuntestsWorkers = "acf69a68-059a-4663-b032-8b5ead8afe67"

[sources]
Runtests = {url = "https://github.com/Drvi/Runtests.jl"}
RuntestsWorkers = {url = "https://github.com/Drvi/Runtests.jl", subdir = "lib/RuntestsWorkers"}

[targets]           # Project.toml only
test = ["Test", "Runtests", "RuntestsWorkers"]   # the existing entries, plus these two
```

If the tests run Aqua's `test_all` or `test_deps_compat`, also add
`Runtests = "0.1"` and `RuntestsWorkers = "0.1"` under `[compat]`. Aqua asks every
test dependency for a compat bound.

Check: `julia --project=. -e 'using Pkg; Pkg.test()'` resolves the new test
environment and runs the original suite as before.

## 4. Convert the suite

The converter `scripts/port_testsets.jl`, next to this file, ports Test.jl suites. In
an installed Runtests it is at
`pkgdir(Runtests, "skills", "port-to-runtests", "scripts", "port_testsets.jl")`.
Treat it as a first pass, and read everything it writes.

Run it on a scratch copy of the test directory, with the package's `Project.toml`
next to it:

```sh
PORT=…/port_testsets.jl
W=$(mktemp -d); cp -R test $W/test; cp Project.toml $W/
julia $PORT $W/test
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
  items by `GROUP` (reference/source-shapes.md). Groups that did not run by default
  stay out of a default run. Any other condition around files becomes
  `skip = <condition>` on their items.
- Files under a directory with a `Project.toml` of its own ran in that environment.
  They stay where they are, unported, and the list names them. To keep running them
  there, port them in place and add a profile naming the directory,
  `[profiles.qa] environment = "qa"` (reference/source-shapes.md).

Then go through its output:

1. Handle every entry in its "for a person to look at" list.
2. Rename the items it named after their file, such as `"a 2"`. Those come from tests
   without a literal name, like `@testset "case $T" for T in Ts`, which it keeps whole
   as one item. Name each after what it tests. If the cases of a loop should be items
   of their own, make it a template (reference/templates.md). Do that when each case is
   slow, or when failures need telling apart.
3. Read every setup it wrote. A setup's top-level code runs once, when the setup is
   precompiled, not when the tests run.
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

Then copy its output into the repository. For each `moved a.jl -> a_tests.jl`, run
`git mv test/a.jl test/a_tests.jl` before copying in the new content, so that the
file's history follows it; a helper moves the same way, as in
`git mv test/helpers.jl test/testsetups/HelpersSetup.jl`. For `replaced a_tests.jl`,
copy the file. Then copy `runtests.jl` and the rest of `testsetups/`.

A suite already made of ReTestItems or TestItemRunner items needs no converter: see
reference/source-shapes.md.

Check: every file in the converter's list of moves is in place, and every entry of
its "for a person to look at" list has been handled.

## 5. Check test/runtests.jl

The converter wrote it: `using Runtests` and `Runtests.runtests()`, or a selection by
`GROUP`. Everything else the old file did has to be accounted for:

- Each check such as Aqua, JET or doctests is an item of its own. If `runtests.jl`
  ran them, the converter put them in the file named for the package
  (reference/source-shapes.md).
- A `Random.seed!(…)` before the includes moves into each item whose expected values
  depend on that seed (see "Randomness" below).
- Thread warnings, timing and commented-out coverage code can go.
- A suite the converter could not read, such as a custom runner or files named at run
  time, shows up in its list as files it could not name or did not reach. Port those
  files with the file-list form, `julia $PORT $W/test - a.jl b.jl`, in the order they
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
`julia --project=$RT -e 'using Runtests; Runtests.runtests("."; dry_run = true)'` lists
every item and reports no scan errors. It reports any `.jl` file under `test/` that
fits none of the places in "The target layout".

## 7. Run chores, then the suite

From the package directory:

```sh
julia --project=$RT -e 'using Runtests; Runtests.chores(".")'
julia --project=. -e 'using Pkg; Pkg.test()'
```

`chores` turns each setup into a package: `testsetups/A/src/A.jl`, plus a
`Project.toml` listing what it imports, taken from the test environment. It also
expands templates and checks the suite. When something has to be fixed by hand it
throws `ChoresError`: fix it and run `chores` again. Run it again whenever a setup
starts importing something new.

Iterate one file at a time with `Runtests.runtests("test/a_tests.jl")` from `$RT`;
`Runtests.runtestsf(".")` reruns what failed. For each failure, look in "What changes
when a testset becomes an item" below.

Check: the suite runs to the end.

## 8. Show that nothing changed

Compare the ported run's summary with the baseline count from step 2: the totals of
checks that passed, failed, errored and were broken, and which ones did not pass.
Runtests prints a row for each test file, which helps to locate a difference. Compare
failures by what they check, not by line number: the converter adds lines at the top
of each file.

Every difference needs a cause you can name. These are not the port's doing:

- The environment differs: a variable such as `CI`, the thread count (workers start
  with `--threads=2,1`), the OS, or a network service. Rerun both sides in the same
  environment.
- A count that follows random draws the original did not seed, such as a test that
  skips some draws. Run the original twice; if its count moves, the port's can too.
- A check that `runtests.jl` skipped under a condition you turned into `skip` or tags.

Any other difference is a test the port lost or changed. Find it.

Check: the totals match, or each difference has its cause written down.

## 9. Report

Tell the user, in this order:

- the baseline and ported totals, and the cause of each difference;
- the wall time before and after, measured from the second run on. The first run has
  no recorded durations, so its schedule is a guess: one ported suite took 60 s on its
  first run and 33 s on later ones;
- each change you made by hand beyond the converter, with its reason;
- what is theirs to decide: Julia versions; CI changes (`GROUP` values, checking
  template expansions, caching run state as the README describes); tags for slow,
  networked or downstream tests; whether to split long items for speed
  (reference/speed.md).

Leave the changes uncommitted unless the user asks you to commit.

## What changes when a testset becomes an item

- **Scope.** A testset's body is a local scope, where variables are typed locals. An
  item's body runs at the top level of a module, with the REPL's soft scope, so its
  variables are untyped globals. Put code whose speed or allocations a test measures
  (`@allocated`, `@allocations`, timing) inside `let … end` or a function. In a
  testset, `counter += 1` inside a function the body defines updated the body's
  `counter`; at the top level the function gets a `counter` of its own, so such a
  body keeps its `let` too.
- **One shared `Main`.** In a Test.jl suite every file ran in `Main`, in one process,
  in include order, so a file could use what `runtests.jl` or an earlier file defined
  or imported. Each item has its own module, runs on one of several workers, in any
  order. Import into each item and setup what it uses. Load the setup of every file
  whose definitions an item uses (`using ASetup, BSetup`), or move shared definitions
  into one setup.
- **State between testsets.** A variable, file or setting that one testset left
  behind reached the testsets after it. Items share only setups and their worker's
  process. Make each item build what it needs, or give the items that depend on each
  other the same `chain = :name`: a chain runs in order, on one worker.
- **Process state.** Changes to `ENV`, the global logger, the working directory,
  preferences, or which packages and extensions are loaded used to last until the
  suite ended. Now the items on a worker run one after another, and each sees what
  earlier ones changed. Restore what an item changes (`withenv`, `try … finally`). If
  an item can't restore it, or needs a package not to be loaded, give it
  `sandbox = true`, which runs it in a process of its own.
- **Printed types.** Where `Main` imported a type's module, types printed
  unqualified. Now `Main` imports nothing, so the package's messages print types
  qualified, as in `FixedPointDecimals.FixedDecimal{Int64, 100}`. Build expected text
  the way the message builds it, with `"… $(FixedDecimal{Int64, 100}) …"`, or print
  with `sprint(show, x; context = :module => @__MODULE__)`.
- **Randomness.** A `Random.seed!` in `runtests.jl` used to decide every draw. Each
  item now draws from the run's seed combined with its own name, and the run prints
  that seed. An item whose expected values come from a fixed seed calls
  `Random.seed!` itself.
- **Threads.** The original process had whatever threads `julia` was started with,
  usually 1. Workers start with `--threads=2,1`. For tests that need a particular
  count, set `threads` under `[run]` in `test/TestItems.toml`, or use a profile.
- **Setup code.** Helper code at the top of a file used to run when the file was
  included. In a setup it runs once per machine, at precompilation (step 4, item 3).
  Every item a worker runs shares the setup's globals, so build mutable fixtures
  inside the items.
- **Paths.** In a helper, `@__DIR__` was `test/`. In a setup it is `test/testsetups/`,
  and after `chores` it is `pkgdir(MyPkg, "test", "testsetups")`, so add `".."` to
  paths built from it. In an item, `@__DIR__` and `include` are relative to the test
  file, as before.
- **Parallelism.** Testsets used to run one at a time; items run at the same time. Any
  path two items could both write to becomes a `mktempdir()`.
- **Crashes.** An `exit()` or a crash used to end the suite. Now it ends only that
  worker: the item counts as an error and the run goes on.

## Rules

- Never change what a test checks to make it pass, and never delete a test. If a test
  can't pass under Runtests for a reason not covered here, leave it as it is and
  report it.
- Don't change `src/`.
- Never edit a file that `chores` generated from a template. Edit the template and run
  `chores` again.
- Runs of a copy of the package get their own `RUNTESTS_RUNSTATE_DIR` (step 1).
