# Suite shapes and how each ports

Most suites are plain Test.jl. Either `runtests.jl` includes files of top-level
testsets, or it holds the testsets itself. Some wrap each file in `@safetestset`.
Some switch on `GROUP` or `ARGS`, and many also run Aqua or JET. Hardly any are
already made of items. Very few files are already named `*_test.jl`, so expect to
rename every file.

## Testsets in files that runtests.jl includes

```julia
# test/runtests.jl
using Test, MyPkg, Random
include("helpers.jl")
@testset "MyPkg" begin
    include("parsing.jl")
    include("writing.jl")
end
```

The converter (SKILL.md, step 4) reads this as written. The outer `@testset "MyPkg"`
only grouped the files, so it goes. `using Random` reaches the items and setups of
both files. `helpers.jl` becomes `testsetups/HelpersSetup.jl`, which their items
load.

## Testsets in runtests.jl itself

The converter ports them into a file named for the package and lists the move as
`moved runtests.jl -> my_pkg_tests.jl`. Make that move with `git mv` first, so that
the tests' history follows them, then copy in the ported file and the new
`runtests.jl`. Code that ran but held no tests, such as a loop calling `Pkg.test`, is
dropped and listed; port it by hand (see "Downstream tests" below).

## SafeTestsets

```julia
using SafeTestsets
@safetestset "Quadrature" include("quadrature.jl")
@safetestset "Interpolation" begin include("interpolation.jl") end
```

Each `@safetestset` ran its file at the top level of a module of its own, which is
what an item's body is. The converter (SKILL.md, step 4) makes an item of each of the
file's testsets. A file of tests outside testsets becomes one item, named after its
`@safetestset`.

A file whose testsets depend on each other can instead be wrapped whole in one item
named after its `@safetestset`. This keeps the file's order and its state from one
test to the next:

  ```julia
  # test/quadrature_tests.jl
  @testitem "Quadrature" begin
      using MyPkg, Test
      # … the rest of quadrature.jl, as it was
  end
  ```

Wrap whole any file whose testsets depend on each other. If it turns out to be slow,
split it afterwards (speed.md).

## GROUP and ARGS switches

```julia
const GROUP = get(ENV, "GROUP", "All")
if GROUP == "All" || GROUP == "Core"
    @safetestset "Interface" include("interface.jl")
end
if GROUP == "GPU"
    @safetestset "CUDA" include("gpu/cuda.jl")
end
```

The converter gives each group's items a tag (`tags = [:core]`, `tags = [:gpu]`) and
writes a `runtests.jl` that selects the group. Unset or `All`, it leaves out the GPU
group, as the original did:

```julia
using Runtests
# GROUP picks the items tagged with it; unset, the items runtests.jl ran by default.
group = lowercase(get(ENV, "GROUP", ""))
Runtests.runtests(; tags = isempty(group) || group == "all" ? "!gpu" : Symbol(group))
```

The selection can live in `test/TestItems.toml` instead, where `Runtests.chores()`
checks it and the run's header names it. `default` is what a run selects when
nothing else does, so `All` maps to it rather than to Runtests' `all`, the whole
suite:

```toml
[groups]
default = "!gpu"
core = "core"
gpu = "gpu"
```

```julia
using Runtests
group = lowercase(get(ENV, "GROUP", ""))
Runtests.runtests(; group = isempty(group) || group == "all" ? "default" : group)
```

On CI, `RUNTESTS_GROUP` selects a group without any of this in `runtests.jl`.

Some groups build an environment of their own: `Pkg.activate` and `Pkg.develop` in
`runtests.jl`, often for downstream or QA tests. The converter leaves the files of a
directory with a `Project.toml` of its own where they are, and lists them. To run
them in that environment, port them in place and add a profile naming the
directory:

```toml
[profiles.qa]
environment = "qa"        # test/qa/Project.toml: Aqua, JET, ...
```

Every item under `test/qa/` then runs under that profile, in a copy of that
environment with the package added by path; nothing needs `Pkg.activate` or
`Pkg.develop` any more. Give the items a tag as well if CI runs them as a group of
their own. If the environment was for something other than tests, such as
downstream packages' suites, ask the user.

`Pkg.test(test_args = …)` arrives as `ARGS`. A run selects items by path, name and
tag, so map what `ARGS` selected onto those. If `ARGS` named files, pass the ported
files' paths:
`Runtests.runtests(map(f -> joinpath(@__DIR__, f), ARGS)...)`. If the mapping is not
one to one, ask the user.

## Downstream tests

A loop such as `for pkg in ["CodecZlib", "CodecXz"]; Pkg.test(pkg); end` runs other
packages' suites against this one. Ask the user whether these stay. If they do, they
become one item tagged `:downstream`, with the loop as it was:

```julia
# test/downstream_tests.jl
@testitem "third-party codec packages" tags = [:downstream] begin
    using Pkg
    for pkg in ["CodecZlib", "CodecXz"]
        Pkg.test(pkg)
    end
end
```

## Aqua, JET, doctests

Each becomes an item of its own, with the same arguments, and `skip` for any
condition `runtests.jl` put around it:

```julia
# test/quality_tests.jl
@testitem "Aqua" tags = [:quality] begin
    using Aqua
    Aqua.test_all(MyPkg)          # with the arguments the old runtests.jl passed
end
```

Do the same for JET, ExplicitImports and doctests (`Documenter.doctest`): one item
each, with the checking package imported in the body. These packages are already
test dependencies.

## ReTestItems

The items carry over. What changes around them:

| ReTestItems | Runtests |
|:--|:--|
| `using ReTestItems; runtests(MyPkg; …)` | `using Runtests; Runtests.runtests()`, with the keywords moved to `[run]` in `test/TestItems.toml` |
| `nworkers`, `nworker_threads`, `testitem_timeout` | `workers`, `threads`, `timeout` |
| `retries`, `memory_threshold`, `failfast` | the same names |
| `testitem_failfast` | `item_failfast` |
| `worker_init_expr`, `test_end_expr` | `init` and `test_end` of `[profiles.default]`, as strings of code |
| `report = true` (JUnit XML) | no equivalent: tell the user |
| `@testsetup module S … end` | `module S … end` in `test/testsetups/S.jl` |
| `setup = [S]` on an item | `using S` at the top of its body |
| `skip = :(expr)` | `skip = expr`, unquoted: a quoted expression evaluates to an `Expr`, not a `Bool` |
| `default_imports = false`, `_id = …` | remove: `Test` and the package are always imported |
| items in `src/`; files named `*-test.jl` | move them into test files under `test/`, named `*_test.jl` or `*_tests.jl` |

A `@testsetup` ran once in each worker. A setup module is precompiled, so its
top-level code runs once per machine, at precompilation: SKILL.md, step 4, item 3 applies. Test
files hold only `@testitem`s, so move every `@testsetup` out of them.

`scripts/port_retestitems.jl` makes the changes in this table that are the same in
every suite: the setups, `setup = [...]`, a quoted `skip`, `default_imports` and `_id`.
A setup moves from the directory of its old file to `testsetups/`, so the script also
rewrites each `@__DIR__` in it to name the old directory.

What a `runtests.jl` does around the call is the person's to port:

- A filter that selects by tag from an environment variable, such as
  `TEST_SLICE=juliac`, becomes `[groups]` in `test/TestItems.toml`, one group per
  value. The new `runtests.jl` passes the variable's value as `group`. Keep the
  variable's own check if it has one: its error message names the variable, where an
  unknown group names the `group` keyword.
- A hack that dispatches slow items first, such as one through ReTestItems'
  `failures_first`, becomes `first = [...]` under `[order]`, listing those items.
  Runtests also puts long items first once it has their durations from a run.
- Code that runs once before the items, such as cleaning a scratch directory or
  setting an environment variable the workers inherit, stays in `runtests.jl`
  before the call.
- A `Pkg.test` of another package in the same repository, after the call, stays too.
  That package's suite is ported on its own, in its own test directory: one
  `Runtests.runtests` call runs one package.

## TestItemRunner

| TestItemRunner | Runtests |
|:--|:--|
| `using TestItemRunner; @run_package_tests` | `using Runtests; Runtests.runtests()` |
| `@run_package_tests filter = ti -> …` | `tags = …` or `name = …` in that call |
| `setup = [S]` on an item | `using S` at the top of its body |
| `@testmodule M begin … end` | `module M … end` in `test/testsetups/M.jl`, and `import M` in the items, which name it as `M.x` |
| `@testsnippet S begin … end` | the snippet's code pasted into each item that named it, or a setup module that exports what it defines, loaded with `using S` |
| `default_imports = false` | remove |
| items anywhere in the package, `src/` included | move them into test files under `test/` |

A snippet ran its code inside each item. Code that has to run in each item, rather
than once per machine, stays in the items.
