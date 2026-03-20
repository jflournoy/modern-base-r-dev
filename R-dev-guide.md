# Modern R Development Guide (data.table Edition)

*An opinionated guide for R development that prioritizes data.table, base R, and ggplot2.
The tidyverse trades dependencies and a proprietary dialect for ergonomics — a reasonable 
trade for many workflows. This guide prefers base R and tools that earn their inclusion. 
Each guideline contains a minimal reproducible example (MRE). As long as you have the package
installed you should be able to run the MRE. Last updated: March 2026.*

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
  "broom"        # tidy model output (used in lapply+rbindlist examples)
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
library(data.table)

set.seed(1)
dt <- data.table(
  id    = 1:200,
  group = rep(c("A", "B"), 100),
  year  = rep(2021:2022, each = 100),
  score = c(rnorm(100, mean = 5), rnorm(100, mean = 6))
)
ref <- data.table(group = c("A", "B"), label = c("control", "treatment"))

# Prefer plain function calls over pipes
x      <- exp(pi)
result <- round(log(x), 3)

# Two-step pipe is acceptable, but the above is preferred
result <- log(x) |> round(3)

# More than two — use intermediate variables, not a chain
# Don't do this:
# result <- dt |> some_filter() |> some_agg() |> some_reshape() |> some_join(ref)

# Do this:
filtered   <- dt[!is.na(score)]
aggregated <- filtered[, .(mean_score = mean(score), n = .N), by = .(group, year)]
reshaped   <- dcast(aggregated, group ~ year, value.var = "mean_score")
result     <- merge(reshaped, ref, by = "group", all.x = TRUE)
result
```

Intermediate variables have costs only when they're large — in that case, use `:=`
in-place operations on data.table instead of creating new objects. The solution to
large intermediates is data.table's reference semantics, not collapsing everything
into a chain.

```r
library(data.table)

set.seed(1)
dt <- data.table(
  id    = 1:200,
  group = rep(c("A", "B"), 100),
  score = c(rnorm(100, mean = 5), rnorm(100, mean = 6))
)

# When intermediate objects would be large, modify in place
dt[, score_z := (score - mean(score)) / sd(score)]
dt[, flag    := score_z > 2]
dt[, label   := fcase(flag & group == "A", "outlier_A",
                      flag & group == "B", "outlier_B",
                      default = "normal")]
dt
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
library(data.table)

set.seed(1)
dt <- data.table(
  id    = 1:100,
  age   = sample(15:45, 100, replace = TRUE),
  group = sample(c("A", "B"), 100, replace = TRUE),
  year  = sample(2020:2022, 100, replace = TRUE),
  score = rnorm(100, mean = 50, sd = 10)
)

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
library(data.table)

dt <- data.table(
  id    = 1:6,
  x     = c(1.2, 2.4, 3.1, 4.5, 5.0, 6.7),
  y     = c(10, 20, 30, 40, 50, 60),
  z     = c(0.1, 0.2, 0.3, 0.4, 0.5, 0.6),
  score = c(0.3, 0.7, 0.5, 0.9, 0.1, 0.8),
  group = c("A", "A", "B", "B", "A", "B")
)

# Add/modify columns in place
dt[, new_col := x * 2]
dt[, c("a", "b") := .(x + y, y - z)]

# Conditional assignment
dt[group == "A", flag := TRUE]
dt[, label := ifelse(score > 0.5, "high", "low")]

# Delete a column
dt[, new_col := NULL]

# Apply a function to multiple columns by name
cols <- c("x", "y", "z")
dt[, (cols) := lapply(.SD, scale), .SDcols = cols]
dt
```

### Grouping and Aggregation

```r
library(data.table)

set.seed(42)
dt <- data.table(
  group      = rep(c("A", "B", "C"), each = 30),
  year       = rep(rep(2021:2023, each = 10), 3),
  value      = rnorm(90, mean = 100, sd = 15),
  score_math = rnorm(90, 70, 10),
  score_read = rnorm(90, 75, 8)
)

# Basic aggregation
summary_dt <- dt[, .(
  mean_val = mean(value, na.rm = TRUE),
  sd_val   = sd(value, na.rm = TRUE),
  n        = .N
), by = .(group, year)]
summary_dt

# Add group mean back to original table (no ungroup() needed)
dt[, group_mean := mean(value), by = group]

# Grouped operations on multiple columns
dt[, lapply(.SD, mean, na.rm = TRUE), by = group, .SDcols = c("score_math", "score_read")]

# .SD with column name patterns
dt[, lapply(.SD, function(x) x - mean(x)), .SDcols = patterns("^score")]
```

### Joins

```r
library(data.table)

dt_a <- data.table(
  id    = c("s01", "s02", "s03", "s04"),
  year  = c(2021, 2021, 2022, 2022),
  score = c(82, 74, 91, 68)
)
dt_b <- data.table(
  id    = c("s01", "s02", "s03", "s05"),
  group = c("ctrl", "treat", "ctrl", "treat")
)

# merge: inner, left, explicit names
merge(dt_a, dt_b, by = "id")                        # inner
merge(dt_a, dt_b, by = "id", all.x = TRUE)          # left join
merge(dt_a, dt_b, by.x = "id", by.y = "id")         # explicit names

# Keyed join (fast for large tables)
setkey(dt_a, id)
setkey(dt_b, id)
dt_b[dt_a]  # right join: all dt_a rows, matching dt_b

# Rolling join: last known price on or before each transaction
prices <- data.table(
  id    = c("X", "X", "X", "Y", "Y"),
  date  = as.IDate(c("2024-01-01", "2024-03-01", "2024-06-01",
                     "2024-01-01", "2024-04-01")),
  price = c(100, 105, 110, 200, 210)
)
transactions <- data.table(
  id   = c("X", "X", "Y"),
  date = as.IDate(c("2024-02-15", "2024-07-01", "2024-05-01"))
)
setkey(prices, id, date)
setkey(transactions, id, date)
prices[transactions, roll = TRUE]
```

### Reshaping

```r
library(data.table)

# Wide to long
wide_dt <- data.table(
  id      = 1:4,
  year    = c(2021, 2021, 2022, 2022),
  score_1 = c(80, 75, 90, 85),
  score_2 = c(70, 65, 88, 82),
  score_3 = c(60, 72, 78, 91)
)

long_dt <- melt(
  wide_dt,
  id.vars       = c("id", "year"),
  measure.vars  = c("score_1", "score_2", "score_3"),
  variable.name = "wave",
  value.name    = "score"
)
long_dt

# Long back to wide
dcast(long_dt, id + year ~ wave, value.var = "score")

# Multiple value columns at once (add a weight column first)
long_dt[, weight := runif(.N, 0.5, 1.5)]
dcast(long_dt, id ~ wave, value.var = c("score", "weight"))
```

### Reference Semantics: Understand What You're Doing

data.table modifies by reference. This is a feature, not a bug — but it means you need
to think about copies.

```r
library(data.table)

dt <- data.table(x = 1:3, y = c("a", "b", "c"))

# dt_shallow and dt point to the same object — modifying one changes both
dt_shallow <- dt
dt[, z := 99]
dt_shallow  # z column appears here too!

# copy() creates an independent object
dt2      <- data.table(x = 1:3, y = c("a", "b", "c"))
dt2_copy <- copy(dt2)
dt2[, z := 99]
dt2_copy  # z column does NOT appear

# Function that modifies in place — caller's object changes
add_flag <- function(d) {
  d[, flag := TRUE]
  invisible(d)
}
dt3 <- data.table(x = 1:3)
add_flag(dt3)
print(dt3)  # flag column is present
```

---

## Base R: Use It More

Base R is underused. It's fast, stable, has zero dependencies, and is already loaded.
The ergonomics argument for tidyverse comes with a dependency cost and a dialect to learn.

### Functional Programming with Base R

```r
dt_list <- list(
  A = data.frame(score = c(80, 90, 70)),
  B = data.frame(score = c(60, 85, 75)),
  C = data.frame(score = c(95, 55, 88))
)

# lapply returns a list — reliable and explicit
means_list <- lapply(dt_list, function(d) mean(d$score))
means_list

# vapply: type-safe, returns named numeric vector
means_vec <- vapply(dt_list, function(d) mean(d$score), numeric(1))
means_vec

# Map over multiple inputs
list_a <- list(1:3, 4:6, 7:9)
list_b <- list(10, 20, 30)
Map(function(x, y) x + y, list_a, list_b)

# Reduce for accumulation
Reduce("+", list(1:4, 5:8, 9:12))
Reduce("+", list(1:4, 5:8, 9:12), accumulate = TRUE)
```

### Apply Over Data Frames / data.tables

```r
library(data.table)

mat <- matrix(c(1, 2, NA, 4, 5, 6, 7, NA, 9), nrow = 3)

colMeans(mat, na.rm = TRUE)
rowSums(mat, na.rm = TRUE)
apply(mat, 1, function(x) sum(x^2, na.rm = TRUE))  # row-wise
apply(mat, 2, max, na.rm = TRUE)                    # col-wise

# On a data.table
dt <- data.table(a = c(1, 2, 3), b = c(4, NA, 6), c = c(7, 8, 9))
dt[, lapply(.SD, mean, na.rm = TRUE), .SDcols = is.numeric]
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

x    <- c("apple-42", "banana-7", "cherry-100", "NA-value", "café")
name <- "world"

# Detection
str_detect(x, "\\d+")
str_starts(x, "ban")
str_ends(x, "\\d")
str_count(x, "[aeiou]")

# Extraction
str_extract(x, "\\d+")            # first match
str_extract_all(x, "[a-z]+")      # all matches (returns list)
str_match(x, "(\\w+)-(\\d+)")     # capture groups → matrix

# Substitution
str_replace(x, "-", "_")          # first match
str_replace_all(x, "[aeiou]", "*") # all matches

# Splitting and combining
str_split(x, "-")
str_split_fixed(x, "-", n = 2)
str_c("item", 1:3, sep = "_")
str_glue("Hello {name}!")

# Basic operations
str_length(x)
str_to_lower(x)
str_trim("  spaces  ")
str_pad("42", width = 6, side = "left")
str_sub(x, 1, 5)
str_trunc(x, width = 8)

# Pattern helpers
str_detect(c("$100", "100"), fixed("$"))
str_detect(c("Abc123", "abc"), regex("ABC", ignore_case = TRUE))
str_detect(c("café", "cafe"), coll("é", locale = "fr"))
```

```r
library(stringi)

x <- c("café", "naïve", "résumé", "hello")

stri_trans_general(x, "Latin-ASCII")       # strip accents: "cafe", "naive", ...
stri_sort(x, locale = "fr_FR")             # French locale sort
stri_pad_left(c("a", "bb", "ccc"), width = 5)
stri_count_regex(x, "[aeiou]")
stri_extract_all_words("the quick brown fox")
```

### Date/Time

```r
Sys.Date()
as.Date("2024-01-15")
format(Sys.Date(), "%Y-%m")

start_date <- as.Date("2024-01-01")
end_date   <- as.Date("2024-06-30")
end_date - start_date
as.numeric(end_date - start_date)

seq(as.Date("2024-01-01"), as.Date("2024-06-01"), by = "month")
```

`lubridate` is fine and reasonable for heavy date manipulation. It's a thin,
focused package — not the rest of tidyverse.

---

## ggplot2: It's Great, Use It

ggplot2 is exquisite, and it composes with any tabular data source
(data.table, base R data frames, matrices via `reshape2`/`melt`).

```r
library(data.table)
library(ggplot2)

set.seed(7)
dt <- data.table(
  id        = 1:120,
  group     = rep(c("ctrl", "treat"), 60),
  condition = rep(c("low", "high", "low", "high"), 30),
  wave      = rep(1:3, each = 40),
  score     = rnorm(120, mean = 50, sd = 12),
  passed    = rbinom(120, 1, 0.65)
)
dt[, cohort := paste0("C", sample(1:3, 120, replace = TRUE))]

# ggplot2 works directly with data.tables
ggplot(dt, aes(x = group, y = score, fill = condition)) +
  geom_boxplot() +
  theme_bw()

# Compute summaries in data.table, then plot — don't pipe into ggplot
summary_dt <- dt[, .(
  mean = mean(score, na.rm = TRUE),
  se   = sd(score, na.rm = TRUE) / sqrt(.N)
), by = .(group, wave)]

ggplot(summary_dt, aes(x = wave, y = mean, color = group)) +
  geom_line() +
  geom_errorbar(aes(ymin = mean - se, ymax = mean + se), width = 0.2) +
  theme_bw()
```

### Theme Preferences

```r
library(ggplot2)

# Custom reusable theme layer
my_theme <- theme_bw(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    strip.background = element_rect(fill = "grey92"),
    legend.position  = "bottom"
  )
```

### Computed Variables

Compute in data.table, plot in ggplot2. Avoid `dplyr::mutate()` inside a ggplot
pipeline. The boundary is clean and each tool does what it's good at.

```r
library(data.table)
library(ggplot2)

set.seed(7)
dt <- data.table(
  passed = rbinom(120, 1, 0.65),
  cohort = paste0("C", sample(1:3, 120, replace = TRUE))
)

my_theme <- theme_bw(base_size = 12) +
  theme(panel.grid.minor = element_blank(), legend.position = "bottom")

# Good: prepare, then plot
plot_dt <- dt[, .(
  n        = .N,
  pct_pass = mean(passed),
  ci_lo    = mean(passed) - 1.96 * sqrt(mean(passed) * (1 - mean(passed)) / .N),
  ci_hi    = mean(passed) + 1.96 * sqrt(mean(passed) * (1 - mean(passed)) / .N)
), by = cohort]

ggplot(plot_dt, aes(x = cohort, y = pct_pass, ymin = ci_lo, ymax = ci_hi)) +
  geom_pointrange() +
  my_theme
```

---

## Functions: Write Them, Don't Chain Them

### Structure and Style

```r
library(data.table)

compute_effect_size <- function(x, y, type = c("cohen_d", "glass_delta")) {
  type      <- match.arg(type)
  pooled_sd <- sqrt(((length(x) - 1) * var(x) + (length(y) - 1) * var(y)) /
                    (length(x) + length(y) - 2))
  if (type == "cohen_d") {
    (mean(x) - mean(y)) / pooled_sd
  } else {
    (mean(x) - mean(y)) / sd(y)
  }
}

set.seed(1)
compute_effect_size(rnorm(50, 5), rnorm(50, 4))
compute_effect_size(rnorm(50, 5), rnorm(50, 4), type = "glass_delta")

fit_group_models <- function(dt, formula, group_col) {
  dt_list <- split(dt, by = group_col)
  fits    <- lapply(dt_list, function(d) lm(formula, data = d))
  coefs   <- lapply(fits, function(f) {
    co <- coef(f)
    data.table(term = names(co), estimate = unname(co))
  })
  rbindlist(coefs, idcol = group_col)
}

set.seed(2)
dt <- data.table(
  group     = rep(c("A", "B"), each = 50),
  outcome   = rnorm(100, 10, 2),
  predictor = rnorm(100, 5, 1)
)
fit_group_models(dt, outcome ~ predictor, "group")
```

### Avoid Growing Objects

Pre-allocate results instead of growing them iteratively:

```r
library(data.table)

n       <- 200
compute <- function(i) i^2 + rnorm(1)

# Bad: O(n²) copies
result_bad <- c()
for (i in seq_len(n)) result_bad <- c(result_bad, compute(i))

# Good: pre-allocate
result_good <- vector("numeric", n)
for (i in seq_len(n)) result_good[i] <- compute(i)

# Best for tabular results
results <- lapply(seq_len(n), function(i) data.table(i = i, val = compute(i)))
result  <- rbindlist(results)
result
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

<details>
<summary>Full lapply + rbindlist patterns</summary>

```r
library(data.table)
library(stringr)

# ── Core pattern ──────────────────────────────────────────────────────────

# Function returns one data.table per item; combine with rbindlist
summarise_group <- function(grp, dt) {
  d <- dt[group == grp]
  d[, .(group = grp, n = .N, mean_score = mean(score), sd_score = sd(score))]
}

set.seed(3)
dt     <- data.table(group = rep(c("A", "B", "C"), each = 40),
                     score = rnorm(120, 70, 10))
groups <- unique(dt$group)
rbindlist(lapply(groups, summarise_group, dt = dt))

# ── idcol: track which item produced each row ──────────────────────────────

fit_group <- function(group_dt) {
  as.data.table(coef(lm(score ~ 1, data = group_dt)), keep.rownames = "term")
}
dt_list <- split(dt, by = "group")
rbindlist(lapply(dt_list, fit_group), idcol = "group")

# ── use.names: stack columns by name, not position ────────────────────────

r1 <- data.table(a = 1, b = 2)
r2 <- data.table(a = 3,      c = 5)
rbindlist(list(r1, r2), use.names = TRUE, fill = TRUE)

# ── Index-based: seed per simulation ──────────────────────────────────────

run_simulation <- function(sim_id) {
  set.seed(sim_id)
  x <- rnorm(30)
  data.table(sim_id = sim_id, estimate = mean(x), se = sd(x) / sqrt(length(x)))
}
sim_results <- rbindlist(lapply(seq_len(50), run_simulation))
sim_results

# ── Composing with parallelism: swap lapply for mclapply ──────────────────
# The function is identical — only the mapping changes.
# Caveat: mclapply uses fork() and is unstable in RStudio/Positron on macOS.
# See the Parallelism section for details and the parLapply alternative.

# sim_results <- rbindlist(mclapply(seq_len(50), run_simulation, mc.cores = n_cores))

# ── Nested: lapply inside lapply, flatten with rbindlist ──────────────────

cohorts      <- c("C1", "C2")
outcome_vars <- c("score_a", "score_b")
set.seed(4)
dt2 <- data.table(
  cohort  = rep(cohorts, each = 20),
  score_a = rnorm(40),
  score_b = rnorm(40, mean = 1)
)
nested <- lapply(cohorts, function(coh) {
  sub <- dt2[cohort == coh]
  lapply(outcome_vars, function(v) {
    sub[, .(cohort = coh, outcome = v, estimate = mean(.SD[[v]], na.rm = TRUE))]
  })
})
rbindlist(unlist(nested, recursive = FALSE))
```

</details>

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
```

<details>
<summary>Chunked file reading</summary>

```r
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

</details>

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

<details>
<summary>mclapply, parLapply, and when not to parallelize</summary>

```r
library(data.table)
library(parallel)

n_cores <- max(1L, parallel::detectCores(logical = FALSE) - 1L)

run_simulation <- function(sim_id) {
  set.seed(sim_id)
  x <- rnorm(100)
  data.table(sim_id = sim_id, estimate = mean(x), se = sd(x) / sqrt(length(x)))
}

# ── Multicore (fork): mclapply ─────────────────────────────────────────────
# Use when: Unix/Mac, CPU-bound, workers share a large read-only object
# WARNING: unstable inside RStudio/Positron on macOS — run from terminal if hangs occur
sim_results <- rbindlist(mclapply(seq_len(50), run_simulation, mc.cores = n_cores,
                                  mc.set.seed = TRUE))
sim_results

# ── Multiprocess (socket): parLapply ──────────────────────────────────────
# Use when: Windows, isolated workers needed, or distributing across nodes
cl <- makeCluster(n_cores)
clusterExport(cl, varlist = "run_simulation")
invisible(clusterEvalQ(cl, library(data.table)))
clusterSetRNGStream(cl, iseed = 42)

sim_results2 <- rbindlist(parLapply(cl, seq_len(50), run_simulation))
stopCluster(cl)
sim_results2

# Quick check before parallelising — is one item worth the overhead?
system.time(run_simulation(1))
```

</details>

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
library(data.table)
library(arrow)

set.seed(7)
dt_raw <- data.table(
  id      = 1:1000,
  outcome = rnorm(1000),
  group   = sample(c("A", "B", "C"), 1000, replace = TRUE),
  date    = seq.Date(as.Date("2022-01-01"), by = "day", length.out = 1000)
)

# ── Feather: fast reads, good for iterative work ──────────────────────────
feather_path <- tempfile(fileext = ".arrow")
write_feather(dt_raw, feather_path)
dt <- as.data.table(read_feather(feather_path))

# Column selection on read
dt_sub <- as.data.table(read_feather(feather_path, col_select = c("id", "outcome")))

# ── Parquet: best compression, good for storage and sharing ──────────────
parquet_path <- tempfile(fileext = ".parquet")
write_parquet(dt_raw, parquet_path)
dt2     <- as.data.table(read_parquet(parquet_path))
dt2_sub <- as.data.table(read_parquet(parquet_path, col_select = c("id", "group")))

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

<details>
<summary>Partitioned parquet + DuckDB queries</summary>

```r
library(data.table)
library(arrow)
library(duckdb)

set.seed(8)
dt <- data.table(
  id      = 1:400,
  year    = rep(2020:2023, each = 100),
  group   = sample(c("control", "treatment"), 400, replace = TRUE),
  cohort  = sample(c("C1", "C2"), 400, replace = TRUE),
  outcome = rnorm(400, 10, 2),
  weight  = runif(400)
)

# ── Partition on write ────────────────────────────────────────────────────
part_dir <- file.path(tempdir(), "partitioned")
write_dataset(dt, path = part_dir, format = "parquet",
              partitioning = c("year", "group"))

# ── DuckDB ────────────────────────────────────────────────────────────────
# SQL is the query language here — no dplyr verbs needed or loaded
con <- dbConnect(duckdb())
duckdb_register(con, "dt", dt)

# WHERE = filter rows, SELECT = columns, GROUP BY = aggregate
result_dt <- as.data.table(dbGetQuery(con, "
  SELECT   cohort,
           AVG(outcome)  AS mean_outcome,
           COUNT(*)      AS n
  FROM     dt
  WHERE    year = 2021
    AND    \"group\" = 'treatment'
  GROUP BY cohort
"))
result_dt

# Window functions
result_ranked <- as.data.table(dbGetQuery(con, "
  SELECT   id, cohort, outcome,
           ROW_NUMBER() OVER (PARTITION BY cohort ORDER BY outcome DESC) AS rnk
  FROM     dt
  WHERE    year >= 2021
"))
result_ranked

# Query partitioned parquet files directly — nothing loaded into R first
result_parquet <- as.data.table(dbGetQuery(con, sprintf("
  SELECT   cohort, AVG(outcome) AS mean_outcome, COUNT(*) AS n
  FROM     read_parquet('%s/**/*.parquet')
  WHERE    year = 2021
  GROUP BY cohort
", part_dir)))
result_parquet

dbDisconnect(con, shutdown = TRUE)
```

</details>

### Memory Monitoring

```r
library(data.table)

dt    <- data.table(x = rnorm(1e5), y = rnorm(1e5))
small <- data.table(a = 1:10)

format(object.size(dt), units = "MB")

tables()  # accurate sizes for all data.tables in session

sizes <- vapply(ls(), function(nm) object.size(get(nm)), numeric(1))
head(sort(sizes, decreasing = TRUE), 5)

rm(small)
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
library(data.table)

set.seed(9)
dt <- data.table(
  x         = rnorm(1000),
  y         = rnorm(1000, 5),
  score     = runif(1000),
  threshold = 0.5
)

# Bad: element-wise loop
result_loop <- numeric(nrow(dt))
for (i in seq_len(nrow(dt))) result_loop[i] <- dt$x[i] * 2 + dt$y[i]

# Good: vectorized
dt[, result := x * 2 + y]

# fcase: fast multi-condition assignment (data.table's case_when)
dt[, category := fcase(
  score > 0.8, "high",
  score > 0.5, "medium",
  default = "low"
)]

# fifelse: fast type-stable ifelse
dt[, flag := fifelse(score > threshold, TRUE, FALSE)]
dt
```

---

## Object-Oriented Programming

### S3: Default for Most Work

S3 is the right choice for most purposes. It's simple, fast, and requires
no dependencies.

```r
new_model_result <- function(coefs, vcov_mat, df, call) {
  obj <- list(coefs = coefs, vcov = vcov_mat, df = df, call = call)
  class(obj) <- "model_result"
  obj
}

print.model_result <- function(x, ...) {
  cat("Model Result\n")
  cat("Call:", deparse(x$call), "\n\n")
  print(x$coefs)
  invisible(x)
}

coef.model_result <- function(object, ...) object$coefs

# Demonstrate
set.seed(10)
fit <- lm(dist ~ speed, data = cars)
res <- new_model_result(
  coefs    = coef(fit),
  vcov_mat = vcov(fit),
  df       = df.residual(fit),
  call     = fit$call
)
print(res)
coef(res)
```

### S4: For Bioconductor or Complex Dispatch

```r
library(data.table)

setClass("Participant", representation(
  id    = "character",
  waves = "data.table",
  meta  = "list"
))

setGeneric("n_waves", function(x) standardGeneric("n_waves"))
setMethod("n_waves", "Participant", function(x) nrow(x@waves))

p <- new("Participant",
         id    = "s001",
         waves = data.table(wave = 1:3, score = c(80, 85, 90)),
         meta  = list(site = "Lab A"))
n_waves(p)
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
x@lo
x@hi

# Validator fires on invalid input
tryCatch(Interval(lo = 5, hi = 1), error = function(e) conditionMessage(e))
```

---

## Performance Workflow

### 1. Profile First

```r
library(data.table)

set.seed(11)
dt <- data.table(
  x     = rnorm(1e5),
  group = sample(letters[1:5], 1e5, replace = TRUE)
)

# system.time for a quick check
system.time(dt[, .(mean_x = mean(x)), by = group])

# library(profvis)
# profvis(dt[, .(mean_x = mean(x)), by = group])
```

### 2. Benchmark Alternatives

```r
library(data.table)
library(bench)

set.seed(11)
dt <- data.table(
  x     = rnorm(1e5),
  group = sample(letters[1:5], 1e5, replace = TRUE)
)

bench::mark(
  data_table  = dt[, .(mean_x = mean(x)), by = group],
  base_tapply = tapply(dt$x, dt$group, mean),
  min_iterations = 20,
  check = FALSE
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
library(data.table)

fit_model <- function(dt, outcome, predictors, max_iter = 100) {
  if (!is.data.table(dt))
    stop("`dt` must be a data.table")
  if (!is.character(outcome) || length(outcome) != 1)
    stop("`outcome` must be a single string")
  missing_cols <- setdiff(c(outcome, predictors), names(dt))
  if (length(missing_cols) > 0)
    stop("Columns not found in `dt`: ", paste(missing_cols, collapse = ", "))
  if (!is.numeric(max_iter) || max_iter < 1)
    stop("`max_iter` must be a positive integer")
  lm(as.formula(paste(outcome, "~", paste(predictors, collapse = "+"))), data = dt)
}

dt <- data.table(y = rnorm(50), x1 = rnorm(50), x2 = rnorm(50))
fit_model(dt, "y", c("x1", "x2"))

# Validation fires correctly
tryCatch(fit_model(dt, "y", c("x1", "missing_col")), error = conditionMessage)
tryCatch(fit_model(as.data.frame(dt), "y", "x1"),    error = conditionMessage)

# warning() for recoverable issues
dt_with_na <- copy(dt)
dt_with_na[c(3, 7, 12), y := NA]

if (any(is.na(dt_with_na$y))) {
  warning(sum(is.na(dt_with_na$y)),
          " NA values in `y` will be removed.")
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

<details>
<summary>Example test file</summary>

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

</details>

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

<details>
<summary>Reference semantics and groupwise correctness tests</summary>

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

</details>

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

<details>
<summary>_targets.R, R/functions.R, and common commands</summary>

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

</details>

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

<details>
<summary>Static and dynamic branching examples</summary>

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

</details>

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