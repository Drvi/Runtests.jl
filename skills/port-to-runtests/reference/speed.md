# Making a ported suite faster

Only after parity holds (SKILL.md, step 8), and only when the user wants it.

A run takes about as long as the larger of two figures: its longest item, and its
total item time divided by the number of workers. Startup comes on top: the test
environment, precompiling setups, and starting workers. Runtests already starts the
longest items first. Splitting pays only when one item is longer than a worker's
share of the total.

Measure from the second run on. The first run has no recorded durations, so it
schedules blind: two ported suites took 54 s and 60 s on their first runs, and 33 s
on later ones.

Each item's time is on its `DONE` line (`PASS · 12.4s (98% compile)`), and in the run
state whose path the run prints at the end:

```julia
using Runtests
rs = Runtests.read_run_state("…")        # the path the run printed
rows = sort!(collect(zip(rs.items, rs.statuses)); by = ((_, st),) -> -st.elapsed)
for (item, st) in first(rows, 10)
    println(round(st.elapsed; digits = 1), " s, ", round(st.compile; digits = 1), " s of it compiling: ", item.name)
end
```

In many Julia suites most of an item's time is compilation. That decides where a
split pays:

- Split along what compiles separately: element types, input types, configurations
  that take different code paths. Each part then compiles only its own code.
- Do not split along what shares compiled code, such as values of one type, or the
  same functions called with other inputs. Every part would compile the same code,
  and the run gets slower.
- A worker keeps what it compiled for the items it runs later. That is why Runtests
  runs neighbouring items of a file on the same worker.

Measured on ported suites:

- ChunkedCSV: 15 items each looped over 3 input types × 2 parsing algorithms. A
  template item for each case took the run from 33 s to 17–19 s. One test also
  looped over 10 integer types for decimal columns. Split by input and algorithm, it
  took 4.1 times the CPU, because every part compiled the parsers for all 10 types.
  Split by type instead, it paid off.
- ProtoBuf: one item translated and loaded 9 sets of proto files, under 2 sets of
  options, in loops. An item for each set and option took the run from 28.5 s to
  16.3 s.
- CSV: splitting a 25 s writer check into 5 column families left the run at 32 s.
  Every worker was already busy for 24–29 s of it.
- Parsers: one 30 s item sets the run's length. Its slow part loops over three index
  values that run the same kernels, so splitting it there would compile them three
  times.

Ways to split:

- A loop over cases becomes a template (templates.md).
- A long item with sections becomes an item per section. Code the sections share
  moves into a setup, or is repeated in each section if it is cheap.

After splitting, check parity again, and compare at least two runs on each side,
from the second run on. Keep a split only if the run got faster, or if the user wants
failures to name their case.
