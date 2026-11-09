# Get started

In this tutorial, you give a small package a test suite that Runtests runs. You write test items, run them with `Pkg.test`, run them at the REPL, repair a failure, and share code between items.

## Make a package

You need Julia 1.11 or later. Start Julia in an empty directory and make a package named `Geometry`:

```julia
using Pkg
Pkg.generate("Geometry")
```

Replace the contents of `Geometry/src/Geometry.jl` with this module:

```julia
module Geometry

export circle_area, square_area

circle_area(r) = π * r^2
square_area(s) = s^2

end
```

## Add Runtests to the test dependencies

The tests of `Geometry` get their own environment in `Geometry/test/`. Add Runtests to it:

```julia
cd("Geometry")
Pkg.activate("test")
Pkg.add("Runtests")
Pkg.activate(".")
```

Pkg writes `test/Project.toml` with Runtests under `[deps]`. Commit this file with the suite.

## Write the entry point and the first test items

`Pkg.test` runs the file `test/runtests.jl`. Make that file call Runtests:

```julia
# test/runtests.jl
using Runtests
Runtests.runtests()
```

Test items go in test files. The name of a test file ends in `_test.jl` or `_tests.jl`. Make `test/area_tests.jl`:

```julia
# test/area_tests.jl
@testitem "circle area" begin
    @test circle_area(1) ≈ π
    @test circle_area(2) ≈ 4π
end

@testitem "square area" tags=[:fast] begin
    @test square_area(3) == 9
end
```

Each item gets `Test` and the package under test in its scope. Thus `@test` and `circle_area` work without `using` statements. A test file holds `@testitem` declarations and nothing else.

## Run the suite with Pkg.test

Run the tests as for any package:

```julia
Pkg.test()
```

The output starts with a header block, then one line for each event of the run. The abbreviated output below illustrates the format; worker counts, assignments, paths, seeds and timings depend on your run.

```text
┌ [TEST] v0.1.0 · julia 1.13.3 · 2 test items in 1 file · seed 0xdd9c0263775e72e7 · 2 workers · threads 2,1
│ env: /tmp/jl_4JWcNy/Project.toml
└ startup: scan 0.0s · plan 0.1s · setup 1.1s
⚫ w1 · 14:54:35 · UP   · pid 45413 · threads 2,1
🔵 w1 · 14:54:35 · RUN  · 1/2 · "circle area" · at test/area_tests.jl:1
🟢 w1 · 14:54:36 · DONE · 1/2 · "circle area" · PASS ·  0.5s (11% compile) · maxrss 0.3 GiB
┌ [TEST] ran 2 test items in 2.4s on 2 workers, all passed
└ run state: ~/.julia/runtests/runs/Geometry-…/1793973275182436-45262.rundata
Test Summary:        | Pass  Total  Time
Runtests             |    3      3  2.4s
  test/area_tests.jl |    3      3  0.5s
```

This example uses two workers. The last line of the closing block names the directory of the run. The directory holds the run state and the logs of the run. [The output reference](reference/output.md) explains each part of the lines.

## Run the suite at the REPL

At the REPL, you can run the suite without `Pkg.test`. For this, Runtests must be in an environment that Julia can load from, for example your default environment:

```julia
Pkg.activate()   # the default environment, for example @v1.12
Pkg.add("Runtests")
Pkg.activate(".")
```

With the `Geometry` project active, load Runtests and run the suite:

```julia
using Runtests
Runtests.runtests()
```

Runtests prepares the test dependencies of `Geometry` itself. It keeps the resolved environment for the session and rebuilds it when its input files change.

## Repair a failure

Change the second test of `"circle area"` so that it fails:

```julia
    @test circle_area(2) ≈ 2π
```

Run the suite again with `Runtests.runtests()`. The failed item gets a block with its failure, directly after its `DONE` line. For example:

```text
🔴 w1 · 12:29:30 · DONE · 1/2 · "circle area" · FAIL ·  0.0s (94% compile) · maxrss 0.3 GiB
┌ [1/2] FAIL "circle area"
│ Test Failed at test/area_tests.jl:3
│   Expression: circle_area(2) ≈ 2π
│    Evaluated: 12.566370614359172 ≈ 6.283185307179586
│ [ No captured logs
└ @ test/area_tests.jl:1 on worker 1
```

The closing block tells you what to do next:

```text
└ run the failing items again: Runtests.runtestsf()
```

Outside a `@testset`, a run with a failure throws an exception. `Pkg.test` then reports that the tests failed.

Change the test back to `4π`. Then run only the failed items:

```julia
Runtests.runtestsf()
```

Runtests reads the earlier run states to find the failing items, and runs `"circle area"` alone. It uses the same random seed that the item failed with. When no item is failing, `runtestsf()` says so and returns `nothing`:

```text
  [TEST] no test item is failing in the recorded runs
```

## Select items

You can run a part of the suite. These calls select by tag, by name and by file:

```julia
Runtests.runtests(tags = :fast)
Runtests.runtests(name = "circle area")
Runtests.runtests("test/area_tests.jl")
```

To see the plan of a run without running it, give `dry_run = true`:

```julia
Runtests.runtests(dry_run = true)
```

```text
  # · worker · test item     · at                   ·  est · tags
  1 ·     w1 · "circle area" · test/area_tests.jl:1 · 0.5s
  2 ·     w2 · "square area" · test/area_tests.jl:6 · 0.4s · fast
```

The `est` column shows each item's most recent recorded duration. The most recent
run may not have selected every item. [Run tests](guide/running.md) tells you all
the ways to select items.

## Share code between items

Code that several items use goes in a test setup. A test setup is a module in `test/testsetups/`. Make `test/testsetups/ShapeData.jl`:

```julia
# test/testsetups/ShapeData.jl
module ShapeData
export RADII
const RADII = (0.5, 1, 2)
end
```

Add an item to `test/area_tests.jl` that loads the setup with `using`:

```julia
@testitem "areas are positive" begin
    using ShapeData
    for r in RADII
        @test circle_area(r) > 0
    end
end
```

Run the suite. Runtests finds the `using ShapeData` statement, and precompiles the setup before it starts the workers.

## Let chores maintain the suite

`Runtests.chores()` does the maintenance work that a suite needs. Run it now:

```julia
Runtests.chores()
```

```text
┌ [TEST] chores
│ setups: 1 of 1 changed:
│   `ShapeData`: moved to ShapeData/src/ShapeData.jl · deps: none
│ templates: none
│ test items: 3 in 1 file, all valid
│ config: none
│ run states: 5 in ~/.julia/runtests/runs/Geometry-…, none to delete
│ checkouts that are gone: none with run states to delete
└ done: 1
```

`chores` converted `ShapeData` into a package with its own `Project.toml`. A setup that is a package gets its own precompile cache for each checkout. Commit the files that `chores` writes.

## Next steps

You now have a suite that Runtests runs. These pages continue from here:

- [Write test items](guide/writing.md) explains the keywords of `@testitem`, for example `timeout`, `retries` and `skip`.
- [Configure runs](guide/configuration.md) explains `test/TestItems.toml`.
- [Run on CI](guide/ci.md) explains how to keep the history of runs between CI jobs.
- [Generate test items from a template](guide/templates.md) explains how one loop makes many items.
- [Run a monorepo](guide/monorepos.md) explains how packages in one Julia workspace share a run and workers.
