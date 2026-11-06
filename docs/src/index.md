# Runtests.jl

Runtests.jl runs the tests of a Julia package as independent test items on several worker processes. A test item is a named block of tests that runs in its own module. A worker is a Julia process that a run starts to run test items.

```julia
@testitem "adds numbers" tags=[:fast] begin
    @test 1 + 1 == 2
end
```

## What a run does

Each call to `Runtests.runtests()` does these steps:

1. It finds the test items by parsing the test files. It does not evaluate the files to find them.
2. It uses a suitable active test environment or prepares one. `Pkg.test()` supplies one, but you can also call `Runtests.runtests()` directly.
3. It chooses a number of workers from the CPUs and the memory of the machine.
4. It plans the order from earlier runs. Recent failures and long items start first. Other items run in file order, so that a worker can use code that it already compiled.
5. It records the run in a run state file. A run state file holds the items, the results, the configuration and the random seeds of one run.

With the run state, you can run the failures again with `Runtests.runtestsf()`, or [replay a recorded run](guide/failures.md) with the same seeds. A recorded run can come from your machine or from CI.

## Install

Runtests requires Julia 1.11 or later. Add it to the test dependencies of your package. If your package has a `test/Project.toml`, add Runtests to that environment:

```julia
using Pkg
Pkg.activate("test")
Pkg.add("Runtests")
```

If your package declares its test dependencies under `[extras]` and `[targets]` in `Project.toml`, add Runtests there. Keep the dependencies and the test targets that are already in the file:

```toml
[extras]
Runtests = "632efd68-cd41-4e05-bd25-b86dc2150078"
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test", "Runtests"]
```

In both cases, give Runtests a compat bound, for example `Runtests = "0.1"` under `[compat]`.

To use Runtests at the REPL for any package, also add it to your default environment, for example `@v1.12`. The [tutorial](tutorial.md) shows both uses.

## How this manual is organized

The manual has four parts. Each part answers a different kind of question.

| Part | Use it to |
|:-----|:----------|
| [Get started](tutorial.md) | Convert a small package to Runtests, step by step. |
| Guides | Do one task, for example [select the items to run](guide/running.md), [share code between items](guide/setups.md), [run a monorepo](guide/monorepos.md) or [run on CI](guide/ci.md). |
| Explanation | Learn [how a run works](explanation/run.md) and [how Runtests keeps history](explanation/history.md). |
| Reference | Look up [the syntax](reference/syntax.md), [every configuration key](reference/configuration.md), [the output](reference/output.md), [the files](reference/files.md), [the editor protocol](reference/editor-protocol.md) and [the API](reference/api.md). |

The [glossary](glossary.md) defines the terms that the manual uses.
