# [Share code with test setups](@id setups)

A test setup is a module in `test/testsetups/` that test items load with `using` or `import`. Put code there that several items share, for example helper functions, constants and fixture paths.

## Write a setup

Put the module in `test/testsetups/Name.jl`, or in `test/testsetups/Name/src/Name.jl`:

```julia
# test/testsetups/MySetups.jl
module MySetups
export ping
ping() = true
end
```

An item loads it as a package:

```julia
@testitem "server answers" begin
    using MySetups
    @test ping()
end
```

Runtests finds the `using` and `import` statements of the items. Before it starts the workers, it precompiles the setups that the selected items need. It precompiles each setup for each profile whose items load it, with the environment, the preferences and the Julia flags of that profile. It precompiles several setups at the same time. The limit is the same as for `Pkg.precompile`, and the environment variable `JULIA_NUM_PRECOMPILE_TASKS` sets it.

## Top-level code runs at precompilation

A setup is precompiled like any package. Its top-level code runs when Julia builds or rebuilds its precompile cache. Workers normally load that cache. Put work that must happen in each process in the `__init__` function of the module.

All items that a worker runs share the globals of the setup. Thus a mutable fixture in a setup carries changes from one item to the next. Build mutable fixtures inside the items.

## Convert setups into packages

`Runtests.setups_to_packages()` makes each setup a package of its own. `Runtests.chores()` does this conversion as one of its steps. The conversion does these changes:

1. It moves `Name.jl` to `Name/src/Name.jl`.
2. It writes `Name/Project.toml` with a UUID and with the packages that the setup imports, under `[deps]`.
3. It replaces `@__DIR__` with `pkgdir(MyPkg, "test", "testsetups")`, where `MyPkg` is the package under test. Thus a fixture path works also when you paste the code into the REPL.
4. When a path rewrite needs the package under test, it adds `import MyPkg` if the setup does not already bind that module.

Without a project and a UUID, all setups with the same name share one precompile cache in each depot. Each checkout, environment and set of Julia flags then writes over the cache of the others. Thus a run precompiles such a setup only for the first profile that loads it. Workers with other Julia flags or another environment compile it themselves. The run warns about each such setup that its items load. After the conversion, each checkout has its own cache, and a run precompiles the setup for each profile that loads it.

A package can import only what its `[deps]` lists. Thus you must convert again after a setup starts to import a new package. The conversion adds what is missing, changes nothing else and keeps the UUIDs. The conversion cannot see an import in code that the setup generates or evaluates at load time. Add such an import to `[deps]` yourself.

The conversion writes nothing unless it can convert every setup. These problems stop it, and it reports all of them at once:

- an import that neither the test environment nor the standard library provides,
- an `include` with a relative string literal, such as `include("helpers.jl")`,
- a use of `@__FILE__`.

## [Paths in a setup](@id setup-paths)

In a flat setup file, `test/testsetups/Name.jl`, `@__DIR__` is `test/testsetups/`. Converting that file rewrites the expression to `pkgdir(MyPkg, "test", "testsetups")`, preserving its original meaning. Thus `joinpath(@__DIR__, "..", "data")` becomes `pkgdir(MyPkg, "test", "data")`.

In a setup that you write directly as `test/testsetups/Name/src/Name.jl`, `@__DIR__` names that `src/` directory; conversion does not relocate or rewrite this file. For fixture paths that should be independent of the setup's layout, import the package under test and use `pkgdir(MyPkg, "test", "testfixtures", "filename")`.

In an item, `@__DIR__` and `include` are relative to the test file.

## Lists that templates share

A [test template](templates.md) can use a list from a setup, by a qualified name such as `MySetups.PERIODS`. The template must import the setup in its body. Put a list that several templates share in a setup.
