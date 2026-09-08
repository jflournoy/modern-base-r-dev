<!-- Shared core of the R guide. Canonical copy:
     https://github.com/jflournoy/modern-base-r-dev/blob/main/CLAUDE_r-devel.md
     claude-config vendors it verbatim between r-core markers via sync-r-guide.js. -->
# R Development

data.table and base R, not the tidyverse. The rules below are defaults for new work; a
project that has already committed to something else says so in its own `CLAUDE.md`. For
the reasons behind the rules, the patterns, and runnable examples, see
[the long guide](https://github.com/jflournoy/modern-base-r-dev/blob/main/R-dev-guide.md).

## Non-negotiable

- **`data.table` for all data manipulation** — not dplyr, not base data frames
- **Never `%>%`.** Use `|>`, and only for two steps; past that, name the intermediate
- **Never load tidyverse** or any meta-package
- **Base R** for anything data.table and the approved list do not cover
- **`lapply()` + `rbindlist()`** as the default pattern for building tabular results
- **Modify in place with `:=`** inside a function that owns its object; `copy()` at the
  boundary when the caller's object must survive the call
- **Write functions.** Name your transformations; do not chain anonymous steps

## Approved packages

| Package | Purpose |
|---|---|
| `data.table` | All data manipulation |
| `ggplot2` | All visualization |
| `stringr` / `stringi` | String operations |
| `arrow` | Parquet I/O, lazy datasets |
| `duckdb` | Out-of-core SQL |
| `lubridate` | Heavy date/time work only |
| `here` | Project-relative paths in scripts and tests |
| `S7` | OOP only with a written reason; S3 is the default. S7 is experimental |
| `testthat` | Unit testing |
| `targets` | Pipeline management |
| `parallel` | Multicore, base R |
| `crew` / `crew.cluster` | Parallel backends for targets |

No tidyverse packages (dplyr, purrr, tidyr, readr, tibble, forcats). No fst. Justify anything
not on this list before using it.

## Style

- `snake_case` throughout — variables are nouns, functions are verbs
- Intermediate variables over chains; the name is free documentation
- Assumes R ≥ 4.1: `|>` is native, and `\(x)` is `function(x)`. Either spelling is fine for a
  one-liner
- Validate inputs at user-facing boundaries; skip internal validation
- `fcase()` / `fifelse()`, not `case_when()` / `if_else()` — and not `ifelse()`, which is not
  type-stable
- `rbindlist()`, not `bind_rows()`
- `melt()` / `dcast()`, not `pivot_longer()` / `pivot_wider()`
- `merge()`, not `left_join()`
- `fread()` / `fwrite()`, not `read_csv()` / `write_csv()`

### tidyverse → here

| Instead of | Write |
|---|---|
| `mutate(dt, z = x + y)` | `dt[, z := x + y]` |
| `filter(dt, x > 0)` | `dt[x > 0]` |
| `group_by() \|> summarise()` | `dt[, .(m = mean(x)), by = g]` |
| `map(x, f) \|> list_rbind()` | `rbindlist(lapply(x, f))` |
| `left_join(a, b)` | `merge(a, b, by = "id", all.x = TRUE)` |

## Testing

- `testthat`, written before the implementation: RED → GREEN → REFACTOR
- Test contracts — inputs, outputs, error conditions — not implementation details
- **For data.table functions, test reference semantics explicitly.** `:=` modifies in place,
  so a test that passes `dt` and then reuses it is testing a mutated object. Pass `copy(dt)`
  where that matters, and assert the mutation where it is the contract
- Tests in `tests/test-*.R`; run with `testthat::test_dir("tests/")`
- Source the code under test with `here::here()`: `test_dir()` runs with the working
  directory set to `tests/`, so a path relative to the project root does not resolve

## Pipelines

- `targets` for any multi-step analysis with slow or expensive steps
- Keep `_targets.R` thin: one function call per `tar_target()`
- All logic in functions under `R/`, tested with testthat
- Track input files with `format = "file"` so targets notices changes on disk
- Branching over a list needs `iteration = "list"` on both the list target and the
  branched target; a downstream target receives every branch by naming the upstream
  target, never via `tar_read()` inside a command

## Data I/O

- Read a CSV once with `fread()`, then write parquet
- Never re-read a CSV in an iterative workflow
- `write_parquet()` / `read_parquet()` for everything — working, persistent, and shared
- Wrap in `as.data.table()` after reading back from arrow

One format, not two. Parquet is the best-supported intermediate format there is, and a
"working" file has a way of becoming the shared one.

## Large data and parallelism

- `fread(select = ...)` to read only the columns you need
- `setkey()` before repeated subsetting or joining; `setindex()` when sorting is unwanted
- With a secondary index, `on =` is **required** — `dt[.("x")]` with no key and no `on=`
  raises an error, it does not fall back to a scan
- `mclapply()` forks, which is **unstable inside RStudio and Positron on macOS** — run from
  a terminal, or use `parLapply()` with a socket cluster. `parLapply()` is also the only
  option on Windows
- **`mc.set.seed = TRUE` is already the default and is not reproducible** — under the default
  RNG it seeds children from time and PID. For reproducible `mclapply()`, either
  `set.seed(i)` inside the worker keyed on the item, or `RNGkind("L'Ecuyer-CMRG")` before
  `set.seed()`. Use `clusterSetRNGStream()` for a socket cluster whose workers do not seed
  themselves; it switches them to L'Ecuyer-CMRG, so it does not combine with `set.seed(i)`
  in the worker
- Time one item with `system.time()` before parallelising anything
- **Never chunk a CSV with `readLines()`.** Embedded newlines inside quoted fields are legal
  (RFC 4180) and split the record. Use `arrow::open_dataset()` and collect in batches
- `duckdb` for out-of-core work, queried with SQL — no dplyr verbs

## Reference semantics: know whose object you are modifying

`dt2 <- dt` does not copy. `:=` inside a function modifies the caller's data.table, and
assignment to a new name does nothing to prevent it.

- Call `copy()` at a function boundary when the caller's object must survive the call
- Where in-place mutation *is* the contract, say so in the function name and its tests
- `setDT()` converts in place, so the original name is also converted
