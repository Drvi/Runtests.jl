# Runtests.jl

[![CI](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/Drvi/Runtests.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://drvi.github.io/Runtests.jl/dev/)

Runtests.jl runs the tests of a Julia package as independent test items, on several worker processes. It plans each run from the runs before it -- failing, edited and new items go first, then long items, and the other items run in file order, so that a worker reuses the code that it compiled. Each run keeps a record. With it, you can run the failures again with the seeds that they failed with, or replay the whole run.

Runtests requires Julia 1.11 or later. Runtests is a vibe-coded package: its code was
written with an AI coding assistant. It is available under the MIT license.

The [documentation](https://drvi.github.io/Runtests.jl/dev/) has a tutorial, guides, explanations and a reference.

## Quick start

1. Add Runtests to the test dependencies of your package: `test/Project.toml`, or `[extras]` and `[targets]` in `Project.toml`.
2. Make `test/runtests.jl` call Runtests:

   ```julia
   using Runtests
   Runtests.runtests()
   ```

3. Write test items in files whose names end in `_test.jl` or `_tests.jl`:

   ```julia
   # test/arithmetic_tests.jl
   @testitem "adds numbers" begin
       @test 1 + 1 == 2
   end
   ```

4. Run the tests as for any package, with `Pkg.test()`.

Each item gets `Test` and the package under test in its scope. A test file holds `@testitem` declarations and nothing else. [Get started](https://drvi.github.io/Runtests.jl/dev/tutorial/) goes through these steps with a complete example.

At the REPL, load Runtests with the project of the package active. These calls are the most common:

```julia
Runtests.runtests()                          # the whole suite
Runtests.runtests("test/solver_test.jl:42")  # the item that contains line 42
Runtests.runtests(name = r"numbers$")        # the items whose names match
Runtests.runtests(tags = "fast && !slow")    # the items that a tag expression selects
Runtests.runtests(dry_run = true)            # the plan of a run, and nothing runs
Runtests.runtestsf()                         # the items whose latest verdict was not a pass
Runtests.chores()                            # maintenance of the suite
Runtests.runtests_mono()                     # the packages of a Julia workspace, in one run
```

## Features

The guides describe each of these features:

- [Test items](https://drvi.github.io/Runtests.jl/dev/guide/writing/) with keywords for tags, timeouts, retries, skips, chains, sandboxes and profiles.
- [Test setups](https://drvi.github.io/Runtests.jl/dev/guide/setups/): modules that items load with `using`, precompiled before the workers start.
- [Test templates](https://drvi.github.io/Runtests.jl/dev/guide/templates/): loops that `chores` expands into ordinary test items.
- [Profiles and environments](https://drvi.github.io/Runtests.jl/dev/guide/profiles/): the flags, threads, variables, `init` and `test_end` of the workers, and directories whose items run in a project of their own.
- [Run history](https://drvi.github.io/Runtests.jl/dev/explanation/history/): the record of each run, the failures with their seeds, replay, and retention that keeps what later runs need.
- [Evidence of failures](https://drvi.github.io/Runtests.jl/dev/guide/failures/): the logs of each item, and files that a failed attempt keeps.
- [CI](https://drvi.github.io/Runtests.jl/dev/guide/ci/): groups that split a suite over jobs, and a cache that keeps the history between jobs.
- [Coverage](https://drvi.github.io/Runtests.jl/dev/guide/coverage/), merged into one `lcov.info` file.
- [Monorepos](https://drvi.github.io/Runtests.jl/dev/guide/monorepos/): the suites of the packages of a Julia workspace in one run, with shared workers.
- [The REPL](https://drvi.github.io/Runtests.jl/dev/guide/repl/): a session that looks like a worker, pasted test items, and a debugger.
- [Editors](https://drvi.github.io/Runtests.jl/dev/guide/editors/): a VS Code extension, and a JSON protocol for other editors.

To port a `Test.jl` suite, read [Port a suite](https://drvi.github.io/Runtests.jl/dev/guide/porting/). Coding agents can follow [`skills/port-to-runtests/SKILL.md`](skills/port-to-runtests/SKILL.md).
