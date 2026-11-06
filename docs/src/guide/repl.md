# [Work at the REPL](@id repl)

This page tells you how to work with a suite at the REPL. You can make the session look like a worker, run a pasted test item, and step into an item with a debugger.

## Make the session look like a worker

```julia
Runtests.activate()        # or Runtests.activate("path/to/Package")
Runtests.deactivate()
```

`activate` makes the session look like the worker of a test item. It activates the test environment of the package and puts `test/testsetups/` on `LOAD_PATH`. Then `using MySetups` and the test-only dependencies of the package work as they do inside an item. `activate` returns the path of the environment. `deactivate` restores the environment that was active and the `LOAD_PATH`. `Runtests.is_activated()` tells you whether `activate` is in force.

For the shared packages of a [workspace](@ref monorepos), use `Runtests.activate_mono()` after loading Runtests from a project in that workspace. It activates the combined test environment and the shared setups. A pasted item belongs to the package that holds the REPL's current directory; an item brought in with `include` belongs to the package that holds its file. In either case its body runs in that package's root:

```julia
Runtests.activate_mono()
cd("lib/A")                 # from the workspace root, before pasting an A item
# paste an @testitem from A here
Runtests.deactivate()
```

`deactivate` restores the project and `LOAD_PATH`, but leaves the directory changed by `cd` alone. From the workspace root, use `Runtests.activate("lib/Legacy")` for an isolated package instead; `activate_mono` reports an error if an item belongs to one.

## Run a pasted test item

A `@testitem` that you paste into the REPL runs at once:

```julia
julia> @testitem "adds numbers" begin
           @test 1 + 1 == 2
       end
🔵 16:30:28 · RUN  · "adds numbers" · at REPL[2]:1
Test Summary: | Pass  Total  Time
adds numbers  |    1      1  0.0s
🟢 16:30:28 · DONE · "adds numbers" · PASS ·  0.0s (96% compile) · maxrss 0.6 GiB
```

The same parser reads it as reads a test file. Thus a keyword that is an error in a file is an error at the REPL too. The item runs in the same way as in a run. It runs in a new module, with soft scope, and with `Test` and the package in scope. An `include` of a test file runs its items in the same way.

The keywords behave as follows at the REPL:

- `skip` and `failfast` apply.
- `sandbox` and `profile` apply. Runtests starts a worker for the item, with the profile and the environment that a run gives it. Without `profile`, the worker uses `[profiles.default]`. The worker gets the flags, the environment variables, the preferences, the `init` and the `test_end` of the profile. A failure in `test_end` counts.
- An item from a file in an [environment directory](@ref environments) also gets a worker, in that environment.
- `timeout`, `retries` and `chain` need a run around the item. Runtests ignores them with a warning. An item with a worker of its own is the exception: it keeps its `timeout` and `retries`.
- `tags` have no effect.

An item running in this process, and its artifact producers, have no enforceable timeout. A sandboxed item keeps its explicitly declared `timeout` and `retries`; it does not inherit those two limits from `[run]`. Its profile hooks and artifact producers use their configured limits. [Investigate failures](@ref evidence) explains where a pasted item's evidence is kept.

## [Step into an item with a debugger](@id debug)

With [Debugger.jl](https://github.com/JuliaDebug/Debugger.jl) loaded, `Runtests.debug` steps into one test item in the current process:

```julia
julia> using Debugger

julia> Runtests.debug()                        # the most recent failure

julia> Runtests.debug("adds numbers")          # an exact name

julia> Runtests.debug(r"^adds")                # the one item whose name matches

julia> Runtests.debug("test/math_test.jl:12")  # the item that contains line 12
```

`debug` steps into exactly one item. An exact name, a `Regex` or a path selects it. Runtests reads a path as `runtests` reads one, relative to the current directory. The path is a `file.jl:line`, or a file or directory that holds one item. A selection that gives no item, or several items, is an error that lists what it found.

### Without a name

Without a name, `debug` steps into the most recent recorded failure, error or timeout among the failing items, with the seed that it failed with. It also names the other failures it can step into. If no such failure is recorded, `debug()` throws `NoTestsError`; name an item to inspect it anyway. A failing item that you name also runs with the seed that it failed with. Give `seed` to use another seed. As with a rerun, the seed does not restore external state or task scheduling.

### What the item gets

The item gets what a run gives it. It gets its module and imports, its environment, the setups, and the `env`, `init` and `test_end` of its profile. The body of the item becomes a function, and the debugger enters it at the first call, in the test file. Code that cannot be part of a function ran before then. Examples are `using`, `struct`, `const` and a method of `Base.show`.

Only that item runs, not the items before it in a chain. Before the item starts, `debug` lists what this process cannot give it. Examples are the `julia_args` of a profile and `sandbox = true`. The item, its hooks and its artifact producers run in the current process without enforceable timeouts. An item that you leave in the debugger before it ends is recorded as an error, not as a pass.

`debug` returns the testset of the item.
