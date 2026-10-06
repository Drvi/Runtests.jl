# Loops whose cases become items: test templates

A loop over cases inside one item is fine when the cases are quick. Give each case an
item of its own when a case is slow enough to matter for the run's length (speed.md),
or when a failure has to say which case failed.

Item names are literals, so a loop that generates items lives in a template: a file
in `test/testtemplates/` named `*_tests_template.jl`. `Runtests.chores()` runs its
loops and writes the items to `test/<name>_tests.jl`. Commit both files. The README's
"Test templates" section has the full rules.

A top-level `@testset "round trip $T" for T in (Int8, Int16, Float32) … end` becomes:

```julia
# test/testtemplates/roundtrip_tests_template.jl
@testtemplate "round trip $T" for T in (Int8, Int16, Float32)
    T = $T                      # binds T in the item, so the body below stays as it was
    x = rand(T)
    @test parse(T, string(x)) == x
end
```

`chores` writes `@testitem "round trip Int8" begin T = Int8 … end`, and so on for
each type.

- A template holds `@testtemplate` declarations and nothing else.
- The loop runs in a separate process with the test environment and the setups. It
  sees `Test`, the package, and the packages the body imports, by module name only:
  write `Dates.Day` and `MyPkgTestHelpers.CASES`, not `Day` or `CASES`.
- `$x`, where `x` is a loop variable, inserts its value as code in the keywords and
  the body. A value has to survive `repr` and evaluate back to an equal value in the
  item, so closures are refused. Loop variables are not bound in the item; `x = $x`
  at the top of the body binds one.
- In the keywords, `$(expr)` is evaluated during expansion, as in
  `skip = $(T in MyPkgTestHelpers.BROKEN)`. In the body, a `$` before anything but a
  loop variable is left for the body's own macros, such as `@btime f($y)`. Quoted
  expressions are left alone.
- Loop over values that are the same on every machine, such as names, numbers and
  types. A path computed in a setup is absolute, and would be written into the
  committed file. Loop over relative names and build each path in the body.

Run `Runtests.chores()` after every change to a template, or to the data its loops
read. A run refuses to start when an expansion is missing, older than its template,
or edited by hand. Never edit a generated file: change the template and run `chores`
again.
