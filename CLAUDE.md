# R Development Instructions

For full rationale, patterns, and examples, see [R-dev-guide.md](R-dev-guide.md).

---

## Non-negotiable rules

- **Use `data.table`** for all data manipulation — not dplyr, not base R data frames
- **Never use `%>%`** — use `|>` only, and only for two steps max; prefer intermediate variables
- **Never load tidyverse** or any tidyverse meta-package
- **Use base R** for everything not covered by data.table or an approved package (see below)
- **Use `lapply` + `rbindlist`** as the default pattern for building tabular results
- **Modify in place with `:=`** — never copy a data.table when `dt[, col := ...]` will do
- **Write functions** — name your transformations; don't chain anonymous steps

---

## Approved packages

| Package | Purpose |
|---|---|
| `data.table` | All data manipulation |
| `ggplot2` | All visualization |
| `stringr` / `stringi` | String operations |
| `arrow` | Feather + parquet I/O, lazy datasets |
| `duckdb` | Out-of-core SQL queries |
| `lubridate` | Heavy date/time work only |
| `S7` | OOP in new packages |
| `testthat` | Unit testing |
| `targets` | Pipeline management |
| `parallel` | Multicore parallelism (base R) |
| `crew` / `crew.cluster` | Parallel backends for targets |

Do not add tidyverse packages (dplyr, purrr, tidyr, readr, tibble, forcats, etc.).
Do not add fst. Justify any package not on this list before using it.

---

## Code style

- `snake_case` everywhere — variables are nouns, functions are verbs
- Intermediate variables over chains — the name is free documentation
- Validate inputs at user-facing function boundaries; skip internal validation
- Use `fcase()` / `fifelse()` not `case_when()` / `if_else()`
- Use `rbindlist()` not `bind_rows()`
- Use `melt()` / `dcast()` not `pivot_longer()` / `pivot_wider()`
- Use `merge()` not `left_join()` etc.
- Use `fread()` / `fwrite()` not `read_csv()` / `write_csv()`

---

## Testing

- Write tests with `testthat` before writing implementation (TDD: RED → GREEN → REFACTOR)
- Test function contracts — inputs, outputs, error conditions — not implementation details
- For data.table functions: test reference semantics explicitly (pass `copy(dt)` when needed)
- Put tests in `tests/test-*.R`; run with `testthat::test_dir("tests/")`

---

## Pipelines

- Use `targets` for any multi-step analysis with slow or expensive steps
- Keep `_targets.R` thin — one function call per `tar_target()`
- Put all logic in functions in `R/`; test those functions with testthat
- Track input files with `format = "file"` so targets detects changes on disk

---

## Data I/O

- Read CSV once with `fread()`, then write to feather (iterative work) or parquet (storage)
- Never re-read a CSV in an iterative workflow
- Use `write_feather()` / `read_feather()` for working data
- Use `write_parquet()` / `read_parquet()` for data that persists or gets shared
- Wrap results in `as.data.table()` after reading from arrow/parquet

---

## Quick reference: tidyverse → this guide

See the full table in [R-dev-guide.md](R-dev-guide.md#migration-reference-tidyverse--datatable--base-r).

Key substitutions:
- `mutate(dt, z = x+y)` → `dt[, z := x+y]`
- `filter(dt, x > 0)` → `dt[x > 0]`
- `group_by() |> summarise()` → `dt[, .(m = mean(x)), by = g]`
- `map(x, f) |> list_rbind()` → `rbindlist(lapply(x, f))`
- `left_join(a, b)` → `merge(a, b, by = "id", all.x = TRUE)`
