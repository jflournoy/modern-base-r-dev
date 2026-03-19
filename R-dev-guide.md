# Modern R Development Guide (data.table Edition)

*An opinionated guide for R development that prioritizes data.table, base R, and ggplot2.
The tidyverse trades dependencies and a proprietary dialect for ergonomics — a reasonable trade for many workflows. This guide prefers base R and tools that earn their inclusion. Last updated: March 2026.*

---

## Package Installation

Run this once to install all packages recommended in this guide:

```r
pkgs <- c(
  "data.table",  # core data manipulation
  "ggplot2",     # visualization
  "stringr",     # string operations (consistent API)
  "stringi",     # ICU-backed Unicode/locale string ops
  "arrow",       # feather + parquet I/O, lazy datasets
  "duckdb",      # in-process SQL, out-of-core analytics
  "profvis",     # profiling
  "bench",       # benchmarking
  "parallel",    # multicore parallelism (base R, ships with R)
  "lubridate",   # date/time (optional, for heavy date work)
  "S7",          # modern OOP for new package development
  "broom",       # tidy model output (used in lapply+rbindlist examples)
  "testthat",    # unit testing
  "targets"      # make-like pipeline framework
)

install.packages(pkgs[!pkgs %in% installed.packages()[, "Package"]])
```

---

## Core Principles

1. **data.table for data manipulation** — fast, memory-efficient, expressive, and stable
2. **Base R for everything else** — it's already there, it's fast, and it composes cleanly
3. **ggplot2 for visualization** — it is genuinely excellent and stands alone
4. **stringr/stringi for strings** — consistent API, backed by ICU; fine to depend on
5. **feather for iteration, parquet for storage** — never re-read a CSV in an iterative workflow
6. **Intermediate variables, not chains** — name your transformations; pipes are for 2 steps max
7. **Profile before optimizing** — use `profvis` and `bench` to find real bottlenecks
8. **Functional, not fluent** — write functions, not sentences

---

## On Pipes: Prefer Intermediate Variables

The native pipe `|>` exists. It is fine for a maximum of two steps where the
transformation is so obvious it needs no name. That's it.

**Do not use `%>%`**. The magrittr pipe has different semantics in edge cases, carries
`rlang`/tidyverse baggage, and adds a dependency for no reason.

**Avoid chains**. Pipe chains are a writing style masquerading as a programming paradigm.
They're hard to debug (you can't inspect intermediate values without restructuring the
whole expression), they collapse meaningful transformations into anonymous steps, and they
make profiling harder. The name you give an intermediate variable is free documentation.

```r
# Prefer plain function calls
result <- round(log(x), 3)

# Two-step pipe is acceptable, but the above is preferred
result <- log(x) |> round(3)

# More than two — use intermediate variables
# Don't do this:
result <- dt |> some_filter() |> some_agg() |> some_reshape() |> some_join(ref)

# Do this:
filtered   <- dt[condition & !is.na(score)]
aggregated <- filtered[, .(mean_score = mean(score), n = .N), by = .(group, year)]
reshaped   <- dcast(aggregated, group ~ year, value.var = "mean_score")
result     <- merge(reshaped, ref, by = "group", all.x = TRUE)
```

Intermediate variables have costs only when they're large — in that case, use `:=`
in-place operations on data.table instead of creating new objects. The solution to
large intermediates is data.table's reference semantics, not collapsing everything
into a chain.

```r
# When intermediate objects would be large, modify in place
dt[, score_z := (score - mean(score)) / sd(score)]
dt[, flag    := score_z > 2]
dt[, label   := fcase(flag & group == "A", "outlier_A",
                      flag & group == "B", "outlier_B",
                      default = "normal")]
# dt is modified in place at each step — no copies, no chain needed
```

---

## data.table: The Core Workhorse

data.table is a strong choice for data manipulation in R. It is:

- Significantly faster than dplyr for most operations
- Far more memory-efficient (modify by reference)
- Dependency-light
- Expressive once you know the `[i, j, by]` grammar

> **Version note**: All patterns in this guide require data.table ≥ 1.13.0 (July 2020),
> which introduced `fcase()` and `fifelse()`. `setindex()` and `patterns()` for `.SDcols`
> have been available since v1.9.4–v1.9.6 (2014–2015). Current CRAN release: v1.18.x.
> If you're on an older install, `update.packages()` before using this guide.

### Setup

```r
library(data.table)

# Convert on read
dt <- fread("data.csv")

# Convert existing data frame
dt <- as.data.table(df)

# Convert in place (no copy)
setDT(df)
```

### The `[i, j, by]` Grammar

`dt[i, j, by]` maps cleanly to SQL: `WHERE`, `SELECT/MUTATE`, `GROUP BY`.
Learn this and you rarely need anything else.

```r
# i: row filtering
dt[age > 30]
dt[group == "A" & !is.na(score)]

# j: column operations
dt[, .(mean_score = mean(score), n = .N)]
dt[, score_z := (score - mean(score)) / sd(score)]  # modify in place

# by: grouping
dt[, .(mean_score = mean(score)), by = group]
dt[, .(mean_score = mean(score)), by = .(group, year)]

# All three together
dt[age > 18, .(mean_score = mean(score), n = .N), by = group]
```

### Column Operations

```r
# Add/modify columns in place (no copy made)
dt[, new_col := value]
dt[, c("a", "b") := .(val_a, val_b)]

# Conditional assignment
dt[condition, flag := TRUE]
dt[, label := ifelse(score > 0.5, "high", "low")]

# Delete column
dt[, col_to_drop := NULL]

# Multiple columns from a character vector
cols <- c("x", "y", "z")
dt[, (cols) := lapply(.SD, scale), .SDcols = cols]
```

### Grouping and Aggregation

```r
# Basic aggregation
summary_dt <- dt[, .(
  mean_val  = mean(value, na.rm = TRUE),
  sd_val    = sd(value, na.rm = TRUE),
  n         = .N
), by = .(group, year)]

# Running operations by group (no ungroup() needed — data.table doesn't group permanently)
dt[, group_mean := mean(value), by = group]

# Grouped operations on multiple columns
dt[, lapply(.SD, mean, na.rm = TRUE), by = group, .SDcols = c("x", "y", "z")]

# .SD is the subset of data for each group — use .SDcols to limit it
dt[, lapply(.SD, function(x) x - mean(x)), .SDcols = patterns("^score")]
```

### Joins

```r
# Merge (left join by default when all.x = TRUE)
result <- merge(dt_a, dt_b, by = "id")
result <- merge(dt_a, dt_b, by = "id", all.x = TRUE)   # left join
result <- merge(dt_a, dt_b, by = c("id", "year"))       # compound key
result <- merge(dt_a, dt_b, by.x = "id_a", by.y = "id_b")  # different names

# data.table keyed join (fast, especially for large tables)
setkey(dt_a, id)
setkey(dt_b, id)
result <- dt_b[dt_a]   # right join of dt_a into dt_b

# Rolling joins (very powerful for time series)
setkey(transactions, id, date)
setkey(prices, id, date)
result <- prices[transactions, roll = TRUE]  # last price on or before transaction date
```

### Reshaping

```r
# Wide to long
long_dt <- melt(
  wide_dt,
  id.vars       = c("id", "year"),
  measure.vars  = c("score_1", "score_2", "score_3"),
  variable.name = "wave",
  value.name    = "score"
)

# Long to wide
wide_dt <- dcast(
  long_dt,
  id + year ~ wave,
  value.var = "score"
)

# Multiple value columns at once
wide_dt <- dcast(
  long_dt,
  id ~ wave,
  value.var = c("score", "weight")
)
```

### Reference Semantics: Understand What You're Doing

data.table modifies by reference. This is a feature, not a bug — but it means you need
to think about copies.

```r
# This modifies dt IN PLACE — dt_copy points to the same object
dt_copy <- dt
dt[, new_col := 1]  # Also modifies dt_copy!

# To get an actual copy
dt_copy <- copy(dt)
dt[, new_col := 1]  # dt_copy is unaffected

# Functions that modify their input should document this expectation
add_flag <- function(dt) {
  dt[, flag := TRUE]  # modifies in place — caller's object changes
  invisible(dt)
}
```

---

## Base R: Use It More

Base R is underused. It's fast, stable, has zero dependencies, and is already loaded.
The ergonomics argument for tidyverse comes with a dependency cost and a dialect to learn.

### Functional Programming with Base R

```r
# lapply returns a list — reliable and explicit
results <- lapply(files, read.csv)

# sapply is convenient but type-unstable — use it only when you know the output type
means <- sapply(dt_list, function(d) mean(d$score))  # fine, will be numeric

# Use vapply when you need type safety
means <- vapply(dt_list, function(d) mean(d$score), numeric(1))  # guarantees numeric(1)

# Map over multiple inputs
results <- Map(function(x, y) x + y, list_a, list_b)

# Reduce for accumulation
total <- Reduce("+", list_of_vectors)
cumulative <- Reduce("+", list_of_vectors, accumulate = TRUE)
```

### Apply Over Data Frames / data.tables

```r
# Column-wise operations on a data.table
col_means <- dt[, lapply(.SD, mean, na.rm = TRUE), .SDcols = is.numeric]

# On a plain matrix
col_means <- colMeans(mat, na.rm = TRUE)
row_sums   <- rowSums(mat, na.rm = TRUE)

# apply on a matrix (careful: apply coerces to common type)
row_results <- apply(mat, 1, my_func)  # 1 = rows
col_results <- apply(mat, 2, my_func)  # 2 = columns
```

### String Manipulation: stringr and stringi

`stringr` and `stringi` are good packages that stand alone from the rest of tidyverse
and are worth using. `stringr` provides a clean, consistent API (string first, pattern
second, `str_` prefix). `stringi` is the underlying engine and exposes more power when
you need it — ICU-backed Unicode handling, locale-aware collation, transliteration.

Use `stringr` by default. Drop down to `stringi` for heavy Unicode work, locale-specific
operations, or anything where you need performance on large character vectors.

```r
library(stringr)

# Detection
str_detect(x, "pattern")          # logical vector — grepl() equivalent
str_starts(x, "prefix")
str_ends(x, "suffix")
str_count(x, "pattern")           # count occurrences per element

# Extraction
str_extract(x, "\\d+")            # first match
str_extract_all(x, "\\d+")        # all matches (returns list)
str_match(x, "(\\w+)-(\\d+)")     # capture groups → matrix

# Substitution
str_replace(x, "old", "new")      # first match
str_replace_all(x, "old", "new")  # all matches

# Splitting and combining
str_split(x, ",")                 # returns list
str_split_fixed(x, ",", n = 3)    # returns matrix, fixed n columns
str_c(a, b, sep = "-")            # paste() equivalent, NA-safe
str_glue("Hello {name}!")         # glue-style interpolation

# Basic operations
str_length(x)
str_to_lower(x); str_to_upper(x); str_to_title(x)
str_trim(x)                        # strip whitespace
str_pad(x, width = 10, side = "left")
str_sub(x, 1, 5)
str_trunc(x, width = 80)

# Pattern helpers
str_detect(x, fixed("$"))         # literal, no regex interpretation
str_detect(x, regex("\\d+", ignore_case = TRUE))
str_detect(x, coll("é", locale = "fr"))  # locale-aware collation
```

```r
library(stringi)

# When you need more than stringr offers:
stri_trans_general(x, "Latin-ASCII")    # transliterate, e.g. "é" → "e"
stri_conv(x, from = "UTF-8", to = "UTF-8")  # re-encode between charsets (rarely needed in R)
stri_sort(x, locale = "pl_PL")          # locale-aware sort
stri_pad_left(x, width = 10)            # faster than str_pad on large vectors
stri_count_regex(x, pattern)            # ICU regex, handles Unicode categories
stri_extract_all_words(x)               # sensible word tokenization
```

### Date/Time

```r
# Base R handles dates well for most purposes
Sys.Date()
as.Date("2024-01-15")
format(Sys.Date(), "%Y-%m")

# Arithmetic
end_date - start_date             # difftime object
as.numeric(end_date - start_date) # days as number

# Sequences
seq(as.Date("2020-01-01"), as.Date("2024-12-31"), by = "month")
```

`lubridate` is fine and reasonable for heavy date manipulation. It's a thin,
focused package — not the rest of tidyverse.

---

## ggplot2: It's Great, Use It

ggplot2 is exquisite, and it composes with any tabular data source
(data.table, base R data frames, matrices via `reshape2`/`melt`).

```r
library(ggplot2)

# ggplot2 works directly with data.tables
ggplot(dt, aes(x = group, y = score, fill = condition)) +
  geom_boxplot() +
  theme_bw()

# Compute summaries in data.table, then plot — don't pipe into ggplot
summary_dt <- dt[, .(
  mean  = mean(score, na.rm = TRUE),
  se    = sd(score, na.rm = TRUE) / sqrt(.N)
), by = .(group, wave)]

ggplot(summary_dt, aes(x = wave, y = mean, color = group)) +
  geom_line() +
  geom_errorbar(aes(ymin = mean - se, ymax = mean + se), width = 0.2) +
  theme_bw()
```

### Theme Preferences

```r
# Set a default theme rather than repeating it
theme_set(theme_bw(base_size = 12))

# Custom reusable theme layer
my_theme <- theme_bw(base_size = 12) +
  theme(
    panel.grid.minor  = element_blank(),
    strip.background  = element_rect(fill = "grey92"),
    legend.position   = "bottom"
  )

# Apply it
p + my_theme
```

### Computed Variables

Compute in data.table, plot in ggplot2. Avoid `dplyr::mutate()` inside a ggplot
pipeline. The boundary is clean and each tool does what it's good at.

```r
# Good: prepare, then plot
plot_dt <- dt[, .(
  n          = .N,
  pct_pass   = mean(passed),
  ci_lo      = mean(passed) - 1.96 * sqrt(mean(passed) * (1 - mean(passed)) / .N),  # normal approx
  ci_hi      = mean(passed) + 1.96 * sqrt(mean(passed) * (1 - mean(passed)) / .N)   # adequate for large n
), by = cohort]

ggplot(plot_dt, aes(x = cohort, y = pct_pass, ymin = ci_lo, ymax = ci_hi)) +
  geom_pointrange()

# Bad: tangled dplyr + ggplot pipeline — hard to debug, hard to reuse data
```

---

## Functions: Write Them, Don't Chain Them

### Structure and Style

```r
# Good: explicit, testable, debuggable
compute_effect_size <- function(x, y, type = c("cohen_d", "glass_delta")) {
  type  <- match.arg(type)
  # weighted pooled SD — correct for unequal n; simplifies to sqrt((var(x)+var(y))/2) when n_x==n_y
  pooled_sd <- sqrt(((length(x) - 1) * var(x) + (length(y) - 1) * var(y)) /
                    (length(x) + length(y) - 2))

  if (type == "cohen_d") {
    (mean(x) - mean(y)) / pooled_sd
  } else {
    (mean(x) - mean(y)) / sd(y)
  }
}

# Intermediate variables are your friend — not a sign of bad code
fit_group_models <- function(dt, formula, group_col) {
  dt_list <- split(dt, by = group_col)
  fits    <- lapply(dt_list, function(d) lm(formula, data = d))
  coefs   <- lapply(fits, function(f) {
    co <- coef(f)
    data.table(term = names(co), estimate = unname(co))
  })
  result  <- rbindlist(coefs, idcol = group_col)
  result
}
```

### Avoid Growing Objects

Pre-allocate results instead of growing them iteratively:

```r
# Bad: copies at every iteration — O(n²) memory
result <- c()
for (i in seq_len(n)) result <- c(result, compute(i))

# Good: pre-allocate a vector when results are atomic
result <- vector("numeric", n)
for (i in seq_len(n)) result[i] <- compute(i)

# Best for tabular results: lapply + rbindlist
results <- lapply(seq_len(n), compute)
result  <- rbindlist(results)
```

### lapply + rbindlist: The Core Pattern

`lapply` over a list or index, each call returning a `data.table`, combined with
`rbindlist` — this is the idiomatic way to build up tabular results in R. It is
faster than any loop-and-grow approach, cleaner than pre-allocating a list and
manually tracking indices, and composes naturally with parallelism (swap `lapply`
for `mclapply` and nothing else changes — with caveats on macOS IDEs, see the
Parallelism section).

The key insight: **write a function that returns a `data.table` for one unit of
work, then map it**. The function is testable in isolation; the mapping is trivial.

```r
# ── Core pattern ──────────────────────────────────────────────────────────

# Each call returns a data.table for one item
process_file <- function(path) {
  dt <- fread(path)
  dt[, .(
    file    = basename(path),
    n       = .N,
    mean_x  = mean(x, na.rm = TRUE),
    missing = sum(is.na(x))
  )]
}

file_paths <- list.files("data/", pattern = "\\.csv$", full.names = TRUE)
results    <- lapply(file_paths, process_file)
summary_dt <- rbindlist(results)

# ── idcol: track which item produced each row ──────────────────────────────

# When your function returns multiple rows, idcol labels them
fit_group <- function(group_dt) {
  fit    <- lm(outcome ~ age + treatment, data = group_dt)
  result <- as.data.table(broom::tidy(fit))
  result
}

dt_list    <- split(dt, by = "cohort")
fits       <- lapply(dt_list, fit_group)
coef_dt    <- rbindlist(fits, idcol = "cohort")
# coef_dt has a "cohort" column identifying which split each row came from

# ── use.names: stack columns by name, not position ────────────────────────

# Safe when data.tables from different sources may have columns in different order
rbindlist(results, use.names = TRUE, fill = TRUE)
# fill = TRUE: missing columns in some data.tables get NA rather than erroring

# ── Index-based: when you need the index inside the function ───────────────

run_simulation <- function(sim_id) {
  set.seed(sim_id)
  dt <- simulate_data()
  dt[, sim_id := sim_id]
  dt[, .(sim_id, estimate = mean(outcome), se = sd(outcome) / sqrt(.N))]
}

sim_results <- rbindlist(lapply(seq_len(1000), run_simulation))

# ── Composing with parallelism: swap lapply for mclapply ──────────────────
# The function is identical — only the mapping changes.
# Caveat: mclapply uses fork() and is unstable in RStudio/Positron on macOS.
# See the Parallelism section for details and the parLapply alternative.

sim_results <- rbindlist(mclapply(seq_len(1000), run_simulation, mc.cores = n_cores))

# ── Reading many files ─────────────────────────────────────────────────────

# Pattern: read + light transform per file, combine once
load_wave <- function(path) {
  dt        <- fread(path)
  dt[, wave := as.integer(str_extract(basename(path), "\\d+"))]
  dt
}

all_waves <- rbindlist(lapply(wave_files, load_wave), use.names = TRUE)

# ── Nested: lapply inside lapply, flatten with rbindlist ──────────────────

# Outer loop: cohorts; inner loop: outcomes
results <- lapply(cohorts, function(cohort) {
  cohort_dt <- dt[group == cohort]
  lapply(outcome_vars, function(var) {
    cohort_dt[, .(
      cohort   = cohort,
      outcome  = var,
      estimate = mean(.SD[[var]], na.rm = TRUE)
    )]
  })
})
flat_dt <- rbindlist(unlist(results, recursive = FALSE))
```

### Naming

```r
# Variables: nouns, snake_case
pupil_scores     <- ...
model_coefs      <- ...
group_summary_dt <- ...

# Functions: verbs, snake_case
compute_icc       <- function(...) { ... }
fit_mixed_model   <- function(...) { ... }
load_wave_data    <- function(...) { ... }

# Constants: all caps (optional but useful)
MAX_ITER <- 1000
DEFAULT_ALPHA <- 0.05
```

---

## Large Data: Memory-Efficient Patterns

When data is large (hundreds of MB to GB+), several concerns become critical:
unnecessary copies, column-wise reads, and compute-before-load filtering.

### Read Only What You Need

```r
# fread is the right tool — it's fast and flexible
dt <- fread("big.csv")

# Read only specific columns
dt <- fread("big.csv", select = c("id", "date", "outcome"))

# Read only rows matching a condition using shell preprocessing
dt <- fread(cmd = "grep 'treatment' big.csv")
dt <- fread(cmd = "awk -F, '$3 == \"A\"' big.csv")  # column filter

# For very large files, read in chunks
# WARNING: readLines-based chunking breaks on CSV fields that contain embedded newlines
# (valid per RFC 4180). Safe only if you control the data and know it has none.
# For untrusted or complex CSVs, prefer Arrow open_dataset() + collect() in batches.
chunk_size <- 1e6
con <- file("big.csv", "r")
header <- readLines(con, n = 1)
results <- list()
i <- 1
repeat {
  chunk_lines <- readLines(con, n = chunk_size)
  if (length(chunk_lines) == 0) break
  chunk <- fread(paste(c(header, chunk_lines), collapse = "\n"))
  results[[i]] <- process_chunk(chunk)
  i <- i + 1
}
close(con)
result <- rbindlist(results)
```

### Modify In Place (data.table)

Every `dplyr::mutate()` call returns a copy of the data frame. For large data,
this adds up quickly. data.table's `:=` modifies in place — no copy.

```r
# This creates a new copy of dt every time (dplyr style)
dt2 <- dplyr::mutate(dt, log_val = log(value))

# This modifies in place — no copy
dt[, log_val := log(value)]

# Chain multiple in-place assignments
dt[, `:=`(
  log_val   = log(value),
  scaled    = (value - min(value)) / (max(value) - min(value)),
  flag      = value > threshold
)]
```

### Avoid Unnecessary Copies

```r
# Bad: copy, filter, copy again
sub_dt  <- dt[group == "A"]             # copy
result  <- sub_dt[score > 0, .(n = .N)] # another copy

# Better: filter once in i
result <- dt[group == "A" & score > 0, .(n = .N)]

# When you need a subset you'll reuse, copy deliberately
group_a <- copy(dt[group == "A"])  # explicit, documented

# Be careful with R's copy-on-modify for base R data frames
# Every time you do df$new_col <- ..., R may copy the whole frame
# setDT() + := avoids this
```

### Column Types Matter

```r
# After reading, check types — fread infers but sometimes gets it wrong
dt[, lapply(.SD, class)]

# Coerce in place
dt[, id := as.character(id)]
dt[, date := as.IDate(date)]  # IDate is data.table's memory-efficient date class
dt[, group := as.factor(group)]

# Use integer instead of double where possible
dt[, count := as.integer(count)]  # 4 bytes vs 8 bytes per value

# IDate vs Date: IDate is stored as integer, much smaller
dt[, date_idt := as.IDate(date_str, format = "%Y-%m-%d")]
```

### Keys and Indices for Repeated Lookups

If you'll be subsetting or joining on a column repeatedly, set a key. This sorts
the data in place (memory-efficient radix sort) and enables binary search lookups.

```r
# Set key for repeated i-subsetting
setkey(dt, id)
dt["ABC123"]  # binary search, fast

# Set key for joins
setkey(dt_a, id, date)
setkey(dt_b, id, date)
merged <- dt_b[dt_a]  # keyed join, much faster than merge() on large tables

# Secondary indices (don't sort, but enable fast lookup)
setindex(dt, group)
dt[.("treatment"), on = "group"]  # on = is required; without it, falls back to full scan
```

### Parallelism: Multicore vs Multiprocess

The right parallelism strategy depends on your bottleneck. Get this wrong and you'll
spend more time on overhead than you save.

**Multicore (forking)** — fast to start, shares memory, Unix/Mac only. Workers are
copies of the parent process at fork time. Best for CPU-bound tasks with large shared
data that doesn't need to be copied (data.table is particularly good here — workers can
read the shared object without copying it).

**Multiprocess (socket clusters)** — works on Windows, isolated workers, higher
startup cost. Workers start fresh and need explicit export of objects and packages.
Required when: you're on Windows, you need workers to be fully isolated (e.g., they
load conflicting libraries), or you're distributing across machines.

```r
library(parallel)

# detectCores() returns logical (hyperthreaded) cores — overcounts for CPU-bound work.
# Use logical = FALSE to get physical cores, which is what you want for R tasks.
# detectCores() can return NA on some systems; guard against that.
n_cores <- max(1L, parallel::detectCores(logical = FALSE) - 1L)
# Alternatively: parallelly::availableCores() is more robust in cluster/container envs

# ── Multicore (fork): mclapply ─────────────────────────────────────────────
# Use when: Unix/Mac, CPU-bound, workers share a large read-only object
# Workers inherit the parent environment at fork — no export needed
# data.table objects are especially efficient here (copy-on-write at OS level)
#
# WARNING: fork-based parallelism is unstable inside RStudio and Positron on macOS.
# Symptoms: hangs, silent NULLs in results, or crashes with data.table + OpenMP.
# If this happens: run from the terminal instead of the IDE console, or switch to
# parLapply (socket cluster). If crashes persist with data.table loaded, call
# data.table::setDTthreads(1) before forking.

results <- mclapply(
  seq_len(n_sims),
  function(i) run_simulation(shared_params, i),
  mc.cores    = n_cores,
  mc.set.seed = TRUE   # reproducible RNG across workers
)

# Pattern: parallel model fitting over groups
dt_list <- split(dt, by = "group")            # list of data.tables
fits    <- mclapply(dt_list, function(d) {
  lm(outcome ~ predictor_1 + predictor_2, data = d)
}, mc.cores = n_cores)
coef_dt <- rbindlist(lapply(fits, broom::tidy), idcol = "group")

# ── Multiprocess (socket): parLapply ──────────────────────────────────────
# Use when: Windows, isolated workers needed, or distributing across nodes
# Must explicitly export objects and load packages on each worker

cl <- makeCluster(n_cores)

# Export everything workers need
clusterExport(cl, varlist = c("my_function", "lookup_table", "threshold"))

# Load packages on workers
clusterEvalQ(cl, {
  library(data.table)
  library(stringr)
})

# Optionally seed each worker for reproducibility
clusterSetRNGStream(cl, iseed = 42)

results <- parLapply(cl, items, my_function)
stopCluster(cl)  # always clean up

# ── When NOT to parallelize ────────────────────────────────────────────────
# Parallelism has real overhead. It hurts more than it helps when:
#   - The task takes < ~100ms per item (overhead dominates)
#   - Workers need to communicate or share mutable state
#   - Memory is constrained (forking copies pages on write; socket workers duplicate)
#   - The bottleneck is I/O (disk/network), not CPU — parallel I/O can make it worse

# Quick check: time one item first
system.time(my_function(items[[1]]))
# If < 0.1s and you have 1000 items, parallelize. If < 0.01s, probably don't bother.
```

### Binary Formats: Feather and Parquet

Never re-read a CSV in an iterative workflow. After the first read, write to a binary
format. Two formats cover all cases:

**Feather** (Arrow IPC format) is the default for iterative analytical work — loading,
exploring, reloading the same dataset across sessions. Read speed is comparable to or
faster than fst, compression via LZ4 is fast and lossless, and the format is
cross-language: the same file loads in Python (pandas, Polars), Julia, and DuckDB
without any conversion. Use the `.arrow` extension (recommended); `.feather` also works
for V2 files. Note: `write_feather()` and `write_ipc_file()` share the same parameters
but are not strict aliases — `write_feather()` supports a `version` argument for legacy
V1 files; `write_ipc_file()` is V2 only.

**Parquet** is the format for anything that persists or gets shared. Best compression
(4–5× smaller than feather on typical mixed-type data due to dictionary and run-length
encoding before general compression), predicate pushdown and partition pruning for
selective queries on large datasets, and the industry standard for data lakes, Spark,
BigQuery, and DuckDB. The tradeoff is slower writes (typically 2–3× vs feather) — acceptable for
data you write once and query many times.

```r
library(arrow)

# ── Feather: default for iterative R work ────────────────────────────────
# Write once after reading from CSV
dt_raw <- fread("data.csv")
write_feather(dt_raw, "data.arrow")              # LZ4 compression by default
write_feather(dt_raw, "data.arrow",
              compression = "zstd")              # smaller files, slightly slower reads

# Read back — fast, and works with data.table directly
dt <- as.data.table(read_feather("data.arrow"))

# Column selection on read
dt_sub <- as.data.table(read_feather(
  "data.arrow",
  col_select = c("id", "date", "outcome")
))

# ── Parquet: storage, sharing, large data ─────────────────────────────────
write_parquet(dt, "data.parquet")                # Snappy compression by default
write_parquet(dt, "data.parquet",
              compression = "zstd")              # better ratio, still fast to read

dt <- as.data.table(read_parquet("data.parquet"))

# Column selection on read (parquet is columnar — unread columns cost nothing)
dt_sub <- as.data.table(read_parquet(
  "data.parquet",
  col_select = c("id", "outcome", "weight")
))

# ── Format reference ───────────────────────────────────────────────────────
# feather:  fastest reads, cross-language, LZ4/ZSTD, good for iterative work
# parquet:  best compression, predicate pushdown, industry standard for storage
# RDS:      arbitrary R objects (models, lists) — not for data frames
# CSV:      only for handoff to tools that can't read binary formats
```

### Large Data: Arrow Datasets and DuckDB

For data that doesn't fit comfortably in memory, or large partitioned data on disk
where you only ever need a slice, Arrow datasets with DuckDB as the query engine
are the right architecture.

**Arrow `open_dataset()`** provides lazy evaluation over a directory of parquet or
feather files. Filters, column selection, and group aggregations are pushed down to
the file layer — only the result enters R memory. Writing with `partitioning`
creates a Hive-style directory structure (`year=2021/group=treatment/`) that Arrow
exploits for partition pruning: `filter(year == 2021)` never touches files from other years.

**DuckDB** is an in-process analytical database that queries parquet and feather
files directly, with the Arrow zero-copy integration meaning no data moves between
R and DuckDB memory during queries. It also handles out-of-core sorting, joining,
and windowing for data that exceeds RAM.

```r
library(arrow)
library(duckdb)

# ── Partition on write ────────────────────────────────────────────────────

# Pay the cost once, benefit on every subsequent query
write_dataset(
  dt,
  path         = "data/partitioned/",
  format       = "parquet",
  partitioning = c("year", "group")
)
# Creates: data/partitioned/year=2021/group=treatment/part-0.parquet, etc.

# ── DuckDB ────────────────────────────────────────────────────────────────

# SQL is the query language at this layer. The Arrow dplyr verbs (filter,
# select, collect) require loading dplyr, which conflicts with data.table.
# DuckDB handles all of this cleanly without extra dependencies.

con <- dbConnect(duckdb())

# Register a data.table as a virtual table — zero copy
duckdb_register(con, "dt", dt)

# WHERE = filter rows, SELECT = columns, GROUP BY = aggregate
result_dt <- as.data.table(dbGetQuery(con, "
  SELECT   cohort, AVG(outcome) AS mean_outcome, COUNT(*) AS n
  FROM     dt
  WHERE    year = 2021
    AND    \"group\" = 'treatment'
  GROUP BY cohort
"))

# Window functions — no equivalent outside SQL here
result_ranked <- as.data.table(dbGetQuery(con, "
  SELECT   id, cohort, outcome,
           ROW_NUMBER() OVER (PARTITION BY cohort ORDER BY outcome DESC) AS rnk
  FROM     dt
  WHERE    year >= 2021
"))

# Query partitioned parquet files directly — nothing loaded into R first
result_parquet <- as.data.table(dbGetQuery(con, "
  SELECT   cohort, AVG(outcome) AS mean_outcome, COUNT(*) AS n
  FROM     read_parquet('data/partitioned/**/*.parquet')
  WHERE    year = 2021
  GROUP BY cohort
"))

dbDisconnect(con, shutdown = TRUE)
```

### Memory Monitoring

```r
# Check object sizes
# Note: object.size() undercounts for data.tables — it misses key/index overhead
# and shared ALTREP columns. Use data.table's tables() for accurate in-session accounting.
object.size(dt)
format(object.size(dt), units = "MB")

# All data.tables in session with accurate sizes, keys, and row/col counts
tables()

# Check all objects in environment, sorted by size (base R objects)
sizes <- vapply(ls(), function(x) object.size(get(x)), numeric(1))
head(sort(sizes, decreasing = TRUE), 10)

# Free memory explicitly when done with large intermediates
rm(big_intermediate)
gc()
```

### A Note on fst

fst was the correct choice for fast R-only binary I/O until around 2022. It is not
a good choice for new projects today. The package has not had a CRAN release since
February 2022, has 130+ open unanswered GitHub issues including known crash bugs,
and is R-only with no cross-language support. Existing fst files remain readable
and the format is stable — if you have a codebase using fst and migration isn't
worth the cost, it's fine to leave it. For new work, use feather or parquet.

---

## Vectorization

R is a vectorized language — lean into it. Loop over elements only when you
genuinely need element-wise control flow.

```r
# Bad: looping over elements when vectorized ops exist
result <- numeric(nrow(dt))
for (i in seq_len(nrow(dt))) {
  result[i] <- dt$x[i] * 2 + dt$y[i]
}

# Good: vectorized
dt[, result := x * 2 + y]

# Complex case: use ifelse or fcase (data.table's fast case_when)
dt[, category := fcase(
  score > 0.8, "high",
  score > 0.5, "medium",
  default = "low"
)]

# fifelse: data.table's fast type-stable ifelse
dt[, flag := fifelse(score > threshold, TRUE, FALSE)]
```

---

## Object-Oriented Programming

### S3: Default for Most Work

S3 is the right choice for most purposes. It's simple, fast, and requires
no dependencies.

```r
# Constructor
new_model_result <- function(coefs, vcov, df, call) {
  obj <- list(
    coefs = coefs,
    vcov  = vcov,
    df    = df,
    call  = call
  )
  class(obj) <- "model_result"
  obj
}

# Methods
print.model_result <- function(x, ...) {
  cat("Model Result\n")
  cat("Call:", deparse(x$call), "\n\n")
  print(x$coefs)
  invisible(x)
}

summary.model_result <- function(object, ...) {
  # ...
}

coef.model_result <- function(object, ...) object$coefs
```

### S4: For Bioconductor or Complex Dispatch

```r
setClass("Participant", representation(
  id    = "character",
  waves = "data.table",
  meta  = "list"
))

setGeneric("n_waves", function(x) standardGeneric("n_waves"))
setMethod("n_waves", "Participant", function(x) nrow(x@waves))
```

### S7: Good Choice for New Packages

S7 (available in the `S7` package) offers S4-like structure with S3-like simplicity.
Worth it for new package development that needs validation and clear class hierarchies.

```r
library(S7)

Interval <- new_class("Interval",
  properties = list(
    lo = class_double,
    hi = class_double
  ),
  validator = function(self) {
    if (self@hi < self@lo) "@hi must be >= @lo"
  }
)

x <- Interval(lo = 0, hi = 1)
x@lo  # 0
```

---

## Performance Workflow

### 1. Profile First

```r
library(profvis)
profvis({
  your_slow_function(real_data)
})

# system.time() for quick checks
system.time({
  your_function(data)
})
```

### 2. Benchmark Alternatives

```r
library(bench)

bench::mark(
  data_table   = dt[, .(mean_val = mean(x)), by = group],
  base_tapply  = tapply(dt$x, dt$group, mean),
  min_iterations = 20
)
```

### 3. Common Bottlenecks and Fixes

```r
# Bottleneck: string operations in a loop
# Fix: vectorize with str_detect/str_replace_all (stringr) or base gsub/grep

# Bottleneck: row-by-row data frame modification
# Fix: data.table := assignment

# Bottleneck: repeated subsetting without index
# Fix: setkey() + keyed joins

# Bottleneck: reading same large file multiple times
# Fix: read once, write to feather (iterative) or parquet (storage); see Large Data section
```

---

## Package Development

### Dependency Philosophy

Every dependency you add is a dependency your users carry. Be deliberate.

```r
# Worth adding:
# - data.table: for data manipulation (faster, lighter than dplyr)
# - ggplot2:    for visualization
# - stringr:    clean string API, fine in isolation (backed by stringi)
# - stringi:    ICU-backed Unicode/locale-aware string ops, heavy lifting
# - arrow:      feather + parquet I/O, lazy datasets, zero-copy Arrow↔DuckDB
# - duckdb:     in-process SQL, out-of-core analytics, queries parquet/feather
# - Rcpp:       for C++ extensions
# - Matrix:     for sparse matrices
# - lme4/brms:  for modeling
# - lubridate:  for heavy date work (isolated, focused)

# Not worth adding to avoid writing 3 lines of base R:
# - dplyr   (use data.table)
# - purrr   (use lapply/vapply/Map)
# - tidyr   (use melt/dcast from data.table)
# - forcats (use factor() / levels())
# - readr   (use fread)
# - tibble  (use data.table or data.frame)
# - fst     (unmaintained since 2022 — use feather for new work)
# - tidyverse (meta-package — pulls in everything; prefer individual tools)
```

### Input Validation

```r
# User-facing: validate fully
fit_model <- function(dt, outcome, predictors, max_iter = 100) {
  if (!is.data.table(dt)) stop("`dt` must be a data.table")
  if (!is.character(outcome) || length(outcome) != 1)
    stop("`outcome` must be a single string")
  missing_cols <- setdiff(c(outcome, predictors), names(dt))
  if (length(missing_cols) > 0)
    stop("Columns not found in `dt`: ", paste(missing_cols, collapse = ", "))
  if (!is.numeric(max_iter) || max_iter < 1)
    stop("`max_iter` must be a positive integer")

  # ... body
}

# Internal: minimal or none
.compute_gradient <- function(y, yhat) {
  # assumes y and yhat are numeric vectors of the same length
  2 * (yhat - y)
}
```

### Error Messages

```r
# Be specific. Tell people what was wrong AND what to do.
if (nrow(dt) == 0) {
  stop(
    "`dt` has 0 rows after filtering. ",
    "Check your filter conditions or the input data."
  )
}

# Use warning() for recoverable issues
if (any(is.na(dt$score))) {
  warning(
    sum(is.na(dt$score)), " NA values in `score` will be removed. ",
    "Set na.rm = FALSE to error instead."
  )
}
```

---

## Test-Driven Development with testthat

TDD clarifies requirements before you write code. It forces you to define what
"correct" means before you have a stake in any implementation, and gives you a safety
net for refactoring. Use it for any non-trivial function.

### The TDD Cycle

1. **RED** — write a failing test that specifies the behaviour you need
2. **GREEN** — write the minimal code to make it pass; resist the urge to do more
3. **REFACTOR** — clean up with the safety net of a passing test
4. **COMMIT** — ship tested, working code

### Setup

```r
install.packages("testthat")
```

For a standalone script workflow (no package), put tests in a `tests/` directory
and run them with `testthat::test_dir("tests/")`. For package development,
`usethis::use_testthat()` wires everything up.

```
project/
├── R/
│   └── analysis.R
└── tests/
    └── test-analysis.R
```

### Writing Tests

```r
# tests/test-analysis.R
library(testthat)
source("R/analysis.R")

# ── RED: write these before the function exists ───────────────────────────

test_that("compute_effect_size returns correct Cohen's d", {
  x <- c(2, 3, 5, 7, 8)
  y <- c(1, 2, 3, 4, 5)
  d <- compute_effect_size(x, y, type = "cohen_d")
  expect_type(d, "double")
  expect_length(d, 1)
  expect_gt(d, 0)                  # x has higher mean, so d should be positive
})

test_that("compute_effect_size errors on non-numeric input", {
  expect_error(compute_effect_size("a", 1:5), class = "simpleError")
})

test_that("compute_effect_size handles equal vectors", {
  x <- c(1, 2, 3)
  expect_equal(compute_effect_size(x, x, type = "cohen_d"), 0)
})
```

### Core Expectations

```r
# Equality
expect_equal(result, expected)           # numeric: uses tolerance (~1e-7)
expect_identical(result, expected)       # exact: type + value + attributes

# Type and structure
expect_type(x, "double")
expect_s3_class(dt, "data.table")
expect_length(x, 3)
expect_named(dt, c("id", "score"))       # check column names

# Conditions
expect_error(f(bad_input))               # any error
expect_error(f(x), "must be numeric")   # error message matches regex
expect_warning(f(x), "NA values")       # warning message matches regex
expect_no_error(f(good_input))          # assert no error is thrown
expect_message(f(x), "Processing")      # message() output matches

# Logical
expect_true(all(dt$score > 0))
expect_false(anyNA(dt$id))
expect_gt(n, 0); expect_gte(n, 1)
expect_lt(err, 0.01); expect_lte(err, 0.05)

# Snapshots — useful for complex output (plots, print methods)
expect_snapshot(print(my_object))        # writes/compares a .snap file
```

### Testing data.table Functions

```r
# ── Test that := does not affect the caller's object ──────────────────────
test_that("add_z_score does not modify input by reference", {
  dt <- data.table(score = c(1, 2, 3, 4, 5))
  original <- copy(dt)
  result <- add_z_score(copy(dt))       # pass a copy if function modifies in place
  expect_equal(dt, original)            # caller's dt unchanged
  expect_true("score_z" %in% names(result))
})

# ── Test groupwise correctness ─────────────────────────────────────────────
test_that("summarise_by_group returns correct means per group", {
  dt <- data.table(
    group = c("A", "A", "B", "B"),
    value = c(1, 3, 2, 4)
  )
  result <- summarise_by_group(dt)
  expect_equal(result[group == "A", mean_val], 2)
  expect_equal(result[group == "B", mean_val], 3)
})
```

### Running Tests

```r
# Run all tests in a directory
testthat::test_dir("tests/")

# Run a single file
testthat::test_file("tests/test-analysis.R")

# In a package
devtools::test()

# Run a specific test by name (grepl match on description)
testthat::test_dir("tests/", filter = "effect_size")
```

### What to Test

Test the contract of a function — its inputs, outputs, and error conditions —
not its implementation. If the body changes but the contract holds, your tests
should still pass.

```r
# Good: tests the contract
test_that("fit_group_models returns one row per group per term", {
  dt <- data.table(
    group   = rep(c("A", "B"), each = 20),
    outcome = rnorm(40),
    age     = sample(18:65, 40, replace = TRUE)
  )
  result <- fit_group_models(dt, outcome ~ age, group_col = "group")
  expect_s3_class(result, "data.table")
  expect_true(all(c("term", "estimate") %in% names(result)))
  expect_equal(nrow(result), 2 * 2)   # 2 groups * 2 terms (intercept + age)
})

# Avoid: tests an implementation detail (the internal formula string)
```

---

## targets: Make-like Pipelines

`targets` is the correct tool for any multi-step analysis where:

- steps are slow and you don't want to rerun them unnecessarily
- you want a clear record of what depends on what
- you need reproducibility across sessions and machines

It replaces ad-hoc `if (file.exists(...)) { skip } else { run }` patterns with
a principled dependency graph. Re-run the pipeline: only outdated targets execute.

### Setup

```r
install.packages("targets")
```

A targets pipeline lives in `_targets.R` at the project root. That file defines
the pipeline; everything else is just R functions.

```
project/
├── _targets.R          # pipeline definition
├── R/
│   └── functions.R     # the actual work lives here
└── data/
    └── raw.csv
```

### A Minimal Pipeline

```r
# _targets.R
library(targets)

# Load your functions — keep them in R/ and source them here
tar_source("R/functions.R")

# Set options (packages available to all targets, common format, etc.)
tar_option_set(packages = c("data.table", "ggplot2"))

# Define the pipeline as a list of tar_target() calls
list(
  tar_target(raw_data,    load_raw("data/raw.csv")),   # reads file
  tar_target(clean_data,  clean(raw_data)),             # depends on raw_data
  tar_target(model,       fit_model(clean_data)),        # depends on clean_data
  tar_target(figure,      plot_results(model, clean_data))
)
```

```r
# R/functions.R
load_raw <- function(path) {
  as.data.table(fread(path))
}

clean <- function(dt) {
  dt <- copy(dt)
  dt <- dt[!is.na(outcome)]
  dt[, score_z := (score - mean(score)) / sd(score)]
  dt
}

fit_model <- function(dt) {
  lm(outcome ~ score_z + age + group, data = dt)
}

plot_results <- function(model, dt) {
  # returns a ggplot object
  ...
}
```

```r
# Run the pipeline — only outdated targets execute
tar_make()

# Inspect results
tar_read(clean_data)    # load a target's value into session
tar_load(model)         # load into environment by name

# Check pipeline status
tar_visnetwork()        # dependency graph in the Viewer
tar_outdated()          # which targets need to rerun
tar_manifest()          # table of all targets and their commands
```

### File Targets: Track Input and Output Files

When a target reads or writes a file, declare it with `format = "file"` so
targets tracks the file's hash, not just whether the code changed.

```r
list(
  # Input file: rerun if the CSV changes on disk
  tar_target(
    raw_path,
    "data/raw.csv",
    format = "file"
  ),

  # raw_path is now the file path string — pass it to your reader
  tar_target(raw_data, load_raw(raw_path)),

  # Output file: target returns the path; targets hashes the file
  tar_target(
    report_path,
    {
      path <- "output/report.html"
      rmarkdown::render("report.Rmd", output_file = path)
      path
    },
    format = "file"
  )
)
```

### Branching: Map Over Many Inputs

Static branching generates targets at pipeline-definition time — you know the
inputs upfront. Dynamic branching generates targets at runtime, useful when the
number of items isn't known until a prior target runs.

```r
# ── Static branching: known inputs ────────────────────────────────────────
list(
  tar_target(
    model_A,
    fit_subgroup(clean_data, group = "A")
  ),
  tar_target(
    model_B,
    fit_subgroup(clean_data, group = "B")
  )
)

# ── Dynamic branching: inputs determined at runtime ────────────────────────
list(
  tar_target(clean_data, clean(raw_data)),

  # Split into a list of data.tables — one per group
  tar_target(
    group_data,
    split(clean_data, by = "group"),
    pattern = NULL  # this target itself isn't branched
  ),

  # Fit a model for each element — creates one sub-target per group
  tar_target(
    group_model,
    fit_model(group_data),
    pattern = map(group_data)   # branches over group_data
  ),

  # Aggregate all branches back into one object
  tar_target(
    all_coefs,
    rbindlist(lapply(tar_read(group_model), broom::tidy), idcol = "group")
  )
)
```

### TDD and targets Together

Write and test your functions in isolation with testthat. The pipeline wires
them together — it is not a substitute for function-level tests.

```r
# R/functions.R — pure functions, easy to test
clean <- function(dt) {
  dt <- copy(dt)
  dt <- dt[!is.na(outcome)]
  dt[, score_z := (score - mean(score)) / sd(score)]
  dt
}

# tests/test-functions.R — test the function, not the pipeline
test_that("clean removes NA rows and adds score_z", {
  dt <- data.table(outcome = c(1, NA, 3), score = c(10, 20, 30))
  result <- clean(dt)
  expect_equal(nrow(result), 2)
  expect_true("score_z" %in% names(result))
  expect_equal(result$score_z, scale(c(10, 30))[, 1])
})
```

The key discipline: **keep the work in functions, keep the pipeline thin**. A
`tar_target()` command should be a single function call. If it's more than that,
extract the logic into a named function and test it.

### Common Operations

```r
# Add targets and testthat to your package list
tar_option_set(packages = c("data.table", "ggplot2", "stringr"))

# Invalidate a specific target (force rerun)
tar_invalidate(model)

# Delete all cached targets and start fresh
tar_destroy()

# Run in parallel — requires the `crew` package (by the targets author)
# crew provides a unified controller API over multiple backends:
#   crew_controller_local()  — local processes
#   crew.cluster package adds crew_controller_slurm(), _sge(), etc. for HPC
library(crew)
tar_option_set(controller = crew_controller_local(workers = 4))
tar_make()

# Store targets in a non-default location (useful for large outputs)
tar_option_set(store = "cache/_targets")
```

---

## Naming and Style

```r
# snake_case everywhere
# Variables: nouns
pupil_scores   <- ...
model_fit      <- ...
group_summary  <- ...

# Functions: verbs
compute_icc         <- function(...) { ... }
load_wave_data      <- function(...) { ... }
validate_cohort_ids <- function(...) { ... }

# Internal (package) functions: prefix with dot
.prepare_design_matrix <- function(...) { ... }

# Spacing
x[, 1]
mean(x, na.rm = TRUE)
dt[group == "A" & score > 0]

# Logical conditions: explicit
if (isTRUE(flag)) { ... }       # use isTRUE() when flag might be NA or length > 1
                                 # plain if (flag) is fine for a known scalar logical
if (identical(x, "abc")) { ... } # not: if (x == "abc") for scalars
```

---

## Migration Reference: tidyverse → data.table + Base R

| tidyverse | data.table / base R |
|---|---|
| `filter(dt, x > 0)` | `dt[x > 0]` |
| `select(dt, a, b)` | `dt[, .(a, b)]` or `dt[, c("a","b"), with=FALSE]` |
| `mutate(dt, z = x + y)` | `dt[, z := x + y]` |
| `group_by(dt, g) |> summarise(m = mean(x))` | `dt[, .(m = mean(x)), by = g]` |
| `arrange(dt, x)` | `dt[order(x)]` or `setorder(dt, x)` |
| `rename(dt, new = old)` | `setnames(dt, "old", "new")` |
| `left_join(a, b, by = "id")` | `merge(a, b, by = "id", all.x = TRUE)` |
| `bind_rows(a, b)` | `rbindlist(list(a, b))` |
| `bind_cols(a, b)` | `cbind(a, b)` |
| `pivot_longer(...)` | `melt(dt, id.vars = ...)` |
| `pivot_wider(...)` | `dcast(dt, formula, value.var = ...)` |
| `case_when(...)` | `fcase(...)` (data.table) |
| `if_else(...)` | `fifelse(...)` (data.table) |
| `count(dt, g)` | `dt[, .N, by = g]` |
| `distinct(dt, col)` | `unique(dt, by = "col")` |
| `pull(dt, col)` | `dt$col` or `dt[["col"]]` |
| `map(x, f)` | `lapply(x, f)` |
| `map_dbl(x, f)` | `vapply(x, f, numeric(1))` |
| `map_chr(x, f)` | `vapply(x, f, character(1))` |
| `walk(x, f)` | `invisible(lapply(x, f))` |
| `map2(x, y, f)` | `Map(f, x, y)` |
| `reduce(x, f)` | `Reduce(f, x)` |
| `str_detect(x, p)` | `str_detect(x, p)` ✓ (keep it) |
| `str_replace(x, p, r)` | `str_replace(x, p, r)` ✓ (keep it) |
| `str_replace_all(x, p, r)` | `str_replace_all(x, p, r)` ✓ (keep it) |
| `str_split(x, p)` | `str_split(x, p)` ✓ (keep it) |
| `str_c(a, b)` | `paste0(a, b)` or `str_c(a, b)` ✓ |
| `str_length(x)` | `str_length(x)` ✓ or `nchar(x)` |
| `str_to_lower(x)` | `str_to_lower(x)` ✓ or `tolower(x)` |
| `str_glue("{x}")` | `str_glue("{x}")` ✓ or `sprintf(...)` |
| `read_csv(f)` | `fread(f)` |
| `write_csv(dt, f)` | `fwrite(dt, f)` |

---

*This guide is intentionally opinionated. The tools here are fast, stable, and
earn their place — that's the standard everything in this guide is held to.*