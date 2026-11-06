# [Generate test items from a template](@id templates)

A test template is a file of loops, each of which makes one test item for each iteration. Use a template when a list of values must give test items that run independently. `Runtests.chores()` runs the loops and writes ordinary test items into a test file. This file is the expansion of the template.

## Write a template

Templates go in `test/testtemplates/`. The name of a template ends in `_test_template.jl` or `_tests_template.jl`. A template holds `@testtemplate` declarations and nothing else.

This example uses `Dates`, so add `Dates` to the test dependencies first:

```julia
# test/testtemplates/periods_tests_template.jl
@testtemplate "doubling a $P of $n" tags=[:gen] for P in (Dates.Day, Dates.Month), n in 1:2
    using Dates
    @test $P($n) + $P($n) == $P(2 * $n)
end
```

## Expand the template

Run `Runtests.chores()`. It writes `test/periods_tests.jl`, the name of the template without `_template`. The file holds four ordinary `@testitem` declarations. The first loop variable changes slowest: `Day` with 1 and 2, then `Month` with 1 and 2. The first item is:

```julia
@testitem "doubling a Day of 1" tags=[:gen] begin
    using Dates
    @test Day(1) + Day(1) == Day(2 * 1)
end
```

Commit the expansion. An installed package needs it to run `Pkg.test()`. When the cases change, edit the template and run `Runtests.chores()` again. Do not edit the expansion yourself.

## What the loop can see

`chores` runs the loops in a separate process, with the test environment and the setups available. The loop sees `Test`, the package under test, and the packages that the body imports, by the name of the module only. In the example, the loop writes `Dates.Day`. The item writes `Day`, because its body has `using Dates`.

The loop runs in a module named `Template`, in the current directory of the process that calls `chores`. To read a file in the loop, build its path from `@__DIR__`, the directory of the template.

The loop does not see the names that `using Dates` exports. Put a list that several templates share in a [setup](setups.md), and refer to it by a qualified name, such as `MySetups.PERIODS`. The body must import that setup.

## Interpolation

A `$` in a template puts a value of the loop into the item. The meaning depends on where the `$` is:

| Location | Meaning |
|:---------|:--------|
| Name: `"case $n"` | The value of the iteration goes into the literal name of the item. |
| Body or keywords: `$n` | The value of the loop variable goes in as Julia code. |
| Keywords: `$(expression)` | The expansion evaluates the expression once for each iteration, in the scope of the loop. |
| Body: other `$` expressions | The expansion leaves them for the macros of the body, for example `@btime`. |
| Quoted expressions | The expansion leaves every `$` as it is. |

Runtests writes an inserted value with `repr`, as the module of the item sees it with the imports of the body. The text must evaluate back to an equal value there. A value that cannot do this, for example a closure, is an error. Runtests adds parentheses where they are necessary to keep the meaning of the code around the value.

The loop variables are not bound in the item. Write `$P` to insert the value, or `P = $P` to give the item a variable named `P`. A `P` without `$` is an error, unless the body binds `P` itself. Inside a string in the body, write `"$($P)"` to insert the value.

## Compute a keyword during expansion

A `$(...)` in a keyword is computed during the expansion:

```julia
# test/testtemplates/cases_tests_template.jl
@testtemplate "case $n" skip=$(n == 2) for n in 1:3
    @test $n != 2
end
```

The expansion writes `skip=true` for case 2 and `skip=false` for the other cases. The code outside `$(...)` stays part of the keyword, and the worker evaluates it when the item runs. For example, `skip=Sys.iswindows() || $(n == 2)` asks the operating system when the item runs. A list of known failures works as `skip=$(n in MySetups.KNOWN_BAD)`, if the body imports `MySetups`.

## Keep expansions current

Only `Runtests.chores()` expands templates. A test run and `Runtests.chores(dry_run = true)` read the stamp of each expansion, and do not run the template. A test run refuses to start if one of these conditions is true:

- an expansion is missing,
- a template changed after its expansion,
- an expansion was edited by hand,
- the template of an expansion was deleted.

Line endings, a byte-order mark and trailing white space at the end of the file do not change the stamp.

`chores` evaluates every template each time, because the data of a template can change while its text stays the same. It writes only the expansions that changed. It reports an expansion that was edited by hand, for you to resolve.

On CI, run `Runtests.chores()` and check for changed, deleted, and newly generated files. The [CI example](@ref ci-templates) catches untracked expansions as well as changes to committed ones.

## Templates that cannot expand

`chores` reports a template that it cannot expand, and writes nothing for that template. A person must correct it. These are examples:

- a loop or a keyword that throws,
- a name that two iterations give,
- a `@testitem` in a template,
- a loop that uses a name that only a `using` in the body brings in.

`@testtemplate` evaluated anywhere else than in a template that `chores` expands throws an error.
