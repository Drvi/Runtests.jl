"""
    @testitem "name" [kwargs...] begin
        # tests
    end

Declare an independently runnable group of tests.

`Runtests.runtests()` finds test items by parsing test files and runs each body in a
fresh module on a worker process. Evaluating the macro itself — pasting an item
into the REPL, or `include`ing its file — runs that one item the same way in this
session, or on a worker of its own when it is sandboxed.

The body runs at the top level of its module with the REPL's soft scope, as in
ReTestItems, so its variables are untyped globals. That matters to a test that
measures allocations. Julia measures a plain call such as `@allocated f(x, y)`,
whose function and arguments are names or literals, from inside `f`. Anything
else, such as `Mod.f(x)`, a keyword argument or a `begin` block, it measures where
it stands, which then includes reaching the globals. Put such a measurement in a
`let` block, where the variables are local:

```julia
@testitem "summing allocates nothing" begin
    let
        x = rand(10)
        @test @allocated(sum(x; init = 0.0)) == 0
    end
end
```

Keyword arguments must be literals, except `skip`, which may be any expression and
is evaluated on the worker before the body, with `Test` and the package in scope. It
must give a `Bool`, and an error in it is the item's error.

| Keyword | Meaning |
|:--------|:--------|
| `tags=[:a, :b]` | tags used for filtering |
| `timeout=N` | seconds before the item is killed; overrides the run default |
| `retries=N` | overrides the run default; a chain retries from its first item |
| `skip=expr` | `Bool`, or an expression evaluated on the worker before the body |
| `failfast=true` | stop this item at its first failure |
| `chain=:sym` | items sharing a chain run in sequence on one worker |
| `sandbox=true` | run alone in a process that is torn down afterwards |
| `sandbox=:profile` | run in the pool for `[profiles.profile]` of `TestItems.toml` |
"""
macro testitem(args...)
    # The call goes to `run_interactive` whole, to be read by the scanner's own
    # parser: a pasted item means exactly what the same item means in a file.
    call = Expr(:macrocall, Symbol("@testitem"), __source__, args...)
    return :($(run_interactive)($(QuoteNode(call)), $(QuoteNode(__source__))))
end

"""
    @testtemplate "name \$x" [kwargs...] for x in xs
        # tests, with `\$x` where the value of `x` goes
    end

Declare a test item per iteration of the loop, in a test template: a file
`test/testtemplates/*_tests_template.jl`, which [`chores`](@ref) runs in a process with
the test environment and the setups, and expands into the test file of its name
without `_template`, in `test/`.

```julia
# test/testtemplates/periods_tests_template.jl, expanded into test/periods_tests.jl
@testtemplate "doubling a \$P of \$n" for P in (Day, Month), n in 1:2
    using Dates
    @test \$P(\$n) + \$P(\$n) == \$P(2 * \$n)
end
```

The loop runs as Julia's does, among the names the item will have: the package and
the body's `using` and `import` statements. The name interpolates each iteration's
values. A template holds `@testtemplate`s and nothing else: an ordinary `@testitem`
goes in a test file, and a list several templates share in a setup module. In the
keywords and the body, `\$x` puts the value of the loop variable `x` there, written as
code, as `Threads.@spawn` takes `\$x`: `repr(x)` as the item's module sees it with the
body's `using` and `import` statements, which has to evaluate back to an equal value
there. Nothing binds `x` in the item, so `x` written without its `\$` is refused unless
the body binds it itself, as `x = \$x` does.

In the keywords, a `\$(...)` is computed as the template expands, once per iteration
among the same names, and its value written the same way: `skip = \$(x in KNOWN_BAD)`
is `skip = true` or `skip = false` in each item. Outside a `\$(...)` a keyword is the
item's, evaluated as it runs. In the body, a `\$` before anything but a loop variable
is left as it is, for a macro of the body's own, and so is every `\$` inside a quoted
expression.

Evaluated anywhere but in a template expanded by `chores`, it throws.
"""
macro testtemplate(args...)
    throw(ArgumentError(
        "`@testtemplate` declares test items in a test template, `test/testtemplates/*_tests_template.jl`, " *
        "which `Runtests.chores()` expands into a test file under `test/`; it does not run where it is evaluated"))
end
