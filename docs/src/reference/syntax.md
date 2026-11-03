# [Syntax](@id syntax)

This page gives the exact syntax of test files, test items, test templates and tag expressions. [Write test items](@ref writing) and [Generate test items from a template](@ref templates) explain how to use them.

## File names

Runtests reads the files under `test/`. Each Julia file there must match one of these rules:

| Path | Meaning |
|:-----|:--------|
| `test/runtests.jl` | The entry point that `Pkg.test` runs. |
| `test/**/*_test.jl`, `test/**/*_tests.jl` | A test file. It holds `@testitem` declarations only. |
| `test/testsetups/Name.jl`, `test/testsetups/Name/src/Name.jl` | A test setup: the module `Name`. |
| `test/testtemplates/*_test_template.jl`, `test/testtemplates/*_tests_template.jl` | A test template. It holds `@testtemplate` declarations only. |
| `test/testfixtures/**` | Input for the tests. Runtests never reads it as part of the suite. |
| `test/**/` with a `Project.toml` or `JuliaProject.toml` | An environment directory. Its test files run in that environment. |

A hidden file or directory, whose name starts with `.`, is not part of the suite. A Julia file that matches no rule stops the run.

Every nested `Project.toml` or `JuliaProject.toml` that discovery encounters makes its directory an [environment directory](@ref environments). The innermost one that holds a test file is the environment of its items. The root `test/` project is the test environment. Setup packages under `test/testsetups/`, projects under `test/testtemplates/` and fixture projects under `test/testfixtures/` are not environment directories. Only the suite-root `test/testfixtures/` is reserved: a deeper directory with that name is an ordinary directory.

The expansion of `test/testtemplates/x_tests_template.jl` is `test/x_tests.jl`.

## @testitem

```julia
@testitem "name" keyword=value ... begin
    body
end
```

The name is a string literal that is not blank. It must be unique across the suite. The keywords come between the name and `begin`, in any order.

### [Keywords](@id testitem-keywords)

| Keyword | Value | Default | Meaning |
|:--------|:------|:--------|:--------|
| `tags` | A vector of symbols, for example `[:fast, :math]`. | none | The tags that a run can select by. |
| `timeout` | A positive number of seconds. | The `timeout` of the run. | The time that each attempt can take. |
| `retries` | An integer from 0 to 126. | The `retries` of the run. | The number of more attempts after a failure. A chain retries from its first item. |
| `skip` | `true`, `false`, or an expression that gives a `Bool`. | `false` | Skip the item. The worker evaluates the expression before the body. |
| `failfast` | `true` or `false`. | The `item_failfast` of the run. | Stop the item at its first failed test. |
| `chain` | A symbol, for example `:db`. | none | The items of a chain run in sequence, on one worker. |
| `sandbox` | `true` or `false`. | `false` | `true` runs the item alone in a new process. |
| `profile` | The name of a profile as a symbol, for example `:bounds`. | `:default` | The profile of the workers that run the item. |

Each value except the value of `skip` must be a literal. Arithmetic on numeric literals is a literal too, for example `timeout = 5*60`. `sandbox = true` and `chain` cannot go together. `sandbox = true` and `profile` combine. All items of one chain must use the same profile and be in the same environment. `sandbox = :name` is an error that tells you to write `profile = :name`.

The `skip` expression runs on the worker, with `Test` and the package in scope, before the imports of the body. An exception in it, or a value that is not a `Bool`, is an error of the item.

### The body

The body runs at the top level of a new module, with the soft scope of the REPL. `Test` and the package under test are in scope. The variables of the body are untyped globals.

## @testtemplate

```julia
@testtemplate "name with $x" keyword=value ... for x in xs, y in ys
    body with $x
end
```

A template makes one test item for each iteration of the loop. With several loop variables, the first one changes slowest. The loop runs in a module that holds `Test`, the package under test, and each package that the body imports, by its module name only.

### Interpolation

| Location | Form | Meaning |
|:---------|:-----|:--------|
| Name | `"case $n"` | The value of the iteration goes into the literal name. |
| Body or keywords | `$n` | The value of the loop variable goes in as Julia code. |
| Keywords | `$(expression)` | The expansion evaluates the expression once for each iteration, in the scope of the loop, and writes its value. |
| Body | `$` before anything else than a loop variable | The expansion leaves it as it is, for a macro of the body. |
| Quoted expressions | any `$` | The expansion leaves it as it is. |

An inserted value is written with `repr`, as the module of the item sees it with the imports of the body. It must evaluate back to an equal value there. A loop variable without `$` in the body is an error, unless the body binds it, as `x = $x` does. Inside a string in the body, write `"$($x)"` to insert the value.

`@testtemplate` evaluated anywhere else than in a template that `chores` expands throws an error.

## [Tag expressions](@id tag-expressions)

The `tags` keyword of `runtests` and the values of `[groups]` take a tag expression as a string:

```text
expression  = alternative { "||" alternative }
alternative = term { "&&" term }
term        = [ "!" ] tag
tag         = one or more characters that are not white space, "!", "&", "|", ":", "(" or ")"
```

`!` negates one tag. `&&` binds tighter than `||`. Parentheses are not part of the syntax. White space around the operators has no effect. Examples:

| Expression | Selects |
|:-----------|:--------|
| `"fast"` | The items with the tag `fast`. |
| `"!slow"` | The items without the tag `slow`. |
| `"fast && !slow"` | The items with `fast` and without `slow`. |
| `"juliac \|\| serializer"` | The items with `juliac`, or with `serializer`, or with both. |
| `"a && b \|\| c"` | The items with `a` and `b`, or with `c`. |

The `tags` keyword also takes a symbol, which selects the items with that tag. A vector of symbols selects the items with all of its tags. An expression that names a tag that no item of the suite carries is an error.
