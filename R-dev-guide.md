# Modern R Development Guide (data.table Edition)

*An opinionated guide for R development that prioritizes data.table, base R, and ggplot2.
The tidyverse trades dependencies and a proprietary dialect for ergonomics, a reasonable
trade for many workflows. The objection this guide makes is to the dialect (a second grammar
for operations base R and data.table already express) and to the dependency graph that
arrives with it; it is not an objection to dependencies as such, and the approved list
carries arrow, duckdb, and testthat without apology. Each guideline contains a minimal
reproducible example (MRE). Every MRE is run by `check-examples.R`, which also generates
`R-dev-examples.R` from this file. Last updated: September 2026.*

---

## Package Installation

Run this once to install all packages recommended in this guide:

<!-- example: skip -->
```r
pkgs <- c(
  "data.table",  # core data manipulation
  "ggplot2",     # visualization
  "stringr",     # string operations (consistent API)
  "stringi",     # ICU-backed Unicode/locale string ops
  "arrow",       # parquet I/O, lazy datasets
  "duckdb",      # in-process SQL, out-of-core analytics
  "profvis",     # profiling
  "bench",       # benchmarking
  "parallel",    # multicore parallelism (base R, ships with R)
  "lubridate",   # date/time (optional, for heavy date work)
  "S7",          # OOP; experimental, so S3 stays the default (see OOP section)
  "here",        # project-relative paths, so tests find R/ (see Testing section)
  "crew",        # where targets run: local workers here, a scheduler or cloud elsewhere
  "tarchetypes", # tar_quarto(): the report as a target
  "quarto",      # renders the report; needs the Quarto CLI on the PATH
  "posterior",   # draws from any Bayesian fit, as data
  "lme4"         # used in the model-output examples only
)
# cmdstanr is not on CRAN, and it needs CmdStan itself:
# install.packages("cmdstanr", repos = c("https://stan-dev.r-universe.dev", getOption("repos")))
# cmdstanr::install_cmdstan()

install.packages(pkgs[!pkgs %in% installed.packages()[, "Package"]])
```

---

## Core Principles

1. **data.table for data manipulation** — fast, memory-efficient, expressive, and stable
2. **Base R for everything else** — it's already there, it's fast, and it composes cleanly
3. **ggplot2 for visualization** — it is genuinely excellent and stands alone
4. **stringr/stringi for strings** — consistent API, backed by ICU; fine to depend on
5. **Parquet for everything on disk** — never re-read a CSV in an iterative workflow
6. **Intermediate variables, not chains** — name your transformations; pipes are for 2 steps max
7. **Profile before optimizing** — use `profvis` and `bench` to find real bottlenecks
8. **Functional, not fluent** — write functions, not sentences

---

## On Pipes: Prefer Intermediate Variables

The native pipe `|>` exists. It is fine for a maximum of two steps where the
transformation is so obvious it needs no name. That's it. The two-step limit is a house
rule, not a measurement; the argument against longer chains follows.

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
stopifnot(nrow(result) == 2L)
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

> **Version note**: This guide assumes R ≥ 4.1, which introduced the native pipe `|>`
> and the lambda shorthand `\(x)`. Patterns here require data.table ≥ 1.13.0 (July 2020),
> which introduced `fcase()` and `fifelse()`. `setindex()` and `patterns()` for `.SDcols`
> have been available since v1.9.4–v1.9.6 (2014–2015). If you're on an older install,
> `update.packages()` before using this guide.

### Setup

<!-- example: skip -->
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
dt[, label := fifelse(score > 0.5, "high", "low")]  # fifelse is type-stable

# Delete a column
dt[, new_col := NULL]

# Apply a function to multiple columns by name
cols <- c("x", "y", "z")
dt[, (cols) := lapply(.SD, function(x) as.numeric(scale(x))), .SDcols = cols]
# as.numeric() drops the scaled:center / scaled:scale attributes scale() attaches
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
stopifnot(nrow(summary_dt) == 9L)

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

stopifnot(nrow(merge(dt_a, dt_b, by = "id", all.x = TRUE)) == 4L,
          nrow(prices[transactions, roll = TRUE]) == 3L)
```

### Joins That Lose Rows

A join has three ways to go wrong without an error. Rows drop when a key is missing on the
other side; rows multiply when a key is duplicated on the other side; and keys that should
match do not, because one file padded its identifiers and the other did not (see
Identifiers Are Character, under Large Data). None of these shows in the joined table,
which prints fine. So state what the join is supposed to do before running it, and assert
it after. The one failure data.table refuses outright is a key with two types, and that
error is the good outcome.

```r
library(data.table)

dt_a <- data.table(id = c("s01", "s02", "s03", "s04"), score = c(82, 74, 91, 68))
dt_b <- data.table(id = c("s01", "s02", "s03", "s05"), group = c("ctrl", "treat", "ctrl", "treat"))

# Say what the join must preserve, then check it
n_before <- nrow(dt_a)
joined   <- merge(dt_a, dt_b, by = "id", all.x = TRUE)
stopifnot(nrow(joined) == n_before)       # a left join keeps every left row...
stopifnot(!anyDuplicated(dt_b$id))        # ...only if the right side's key is unique

# What fell out, on each side: anti-joins
dt_a[!dt_b, on = "id"]   # in a, not in b: s04
dt_b[!dt_a, on = "id"]   # in b, not in a: s05

# A duplicated key multiplies rows silently. Check the key before, not the count after
dt_dup <- rbindlist(list(dt_b, dt_b[1]))
nrow(merge(dt_a, dt_dup, by = "id"))      # 4, not 3: s01 appears twice
stopifnot(nrow(merge(dt_a, dt_dup, by = "id")) == 4L)

# A key with two types does not join at all. data.table refuses, loudly
dt_int <- data.table(id = 1:3, x = 1:3)
dt_chr <- data.table(id = c("1", "2", "3"), y = 4:6)
msg <- tryCatch(merge(dt_int, dt_chr, by = "id"), error = conditionMessage)
msg
stopifnot(grepl("Incompatible join types", msg, fixed = TRUE))
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
stopifnot(nrow(long_dt) == 12L, ncol(dcast(long_dt, id + year ~ wave, value.var = "score")) == 5L)
```

### Reference Semantics: Understand What You're Doing

data.table modifies by reference. This is a feature, not a bug, but it means you need to
think about copies. The rule: modify in place inside a function that owns its object, and
`copy()` at a function boundary when the caller's object must survive the call. Where
in-place mutation is the contract, say so in the function's name and in its tests.

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

stopifnot("z" %in% names(dt_shallow), !"z" %in% names(dt2_copy), "flag" %in% names(dt3))
```

---

## Base R: Use It More

Base R is underused. It's fast, stable, has zero dependencies, and is already loaded.
The ergonomics argument for tidyverse comes with a dependency cost and a dialect to learn.

### Functional Programming with Base R

R ≥ 4.1 has a lambda shorthand: `\(x)` is exactly `function(x)`. The examples below spell
out `function`; either form is fine for a one-liner.

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

ggplot2 is exquisite, and it composes with any tabular data source (data.table, base R
data frames, or a matrix reshaped with data.table's `melt()`).

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

The functions below are the ones the Testing section writes tests against, so they live
in a file the tests can source.

<!-- example: file=R/analysis.R -->
```r
# R/analysis.R
library(data.table)

compute_effect_size <- function(x, y, type = c("cohen_d", "glass_delta")) {
  if (!is.numeric(x) || !is.numeric(y)) stop("`x` and `y` must be numeric")
  type      <- match.arg(type)
  pooled_sd <- sqrt(((length(x) - 1) * var(x) + (length(y) - 1) * var(y)) /
                    (length(x) + length(y) - 2))
  if (type == "cohen_d") {
    (mean(x) - mean(y)) / pooled_sd
  } else {
    (mean(x) - mean(y)) / sd(y)
  }
}

fit_group_models <- function(dt, formula, group_col) {
  dt_list <- split(dt, by = group_col)
  fits    <- lapply(dt_list, function(d) lm(formula, data = d))
  coefs   <- lapply(fits, function(f) {
    co <- coef(f)
    data.table(term = names(co), estimate = unname(co))
  })
  rbindlist(coefs, idcol = group_col)
}

# Modifies in place: the caller's table gains score_z. The name and the tests say so.
add_z_score <- function(dt) {
  dt[, score_z := (score - mean(score)) / sd(score)]
  dt
}

summarise_by_group <- function(dt) {
  dt[, .(mean_val = mean(value)), by = group]
}
```

```r
library(data.table)
source(here::here("R", "analysis.R"))

set.seed(1)
d <- compute_effect_size(rnorm(50, 5), rnorm(50, 4))
d
compute_effect_size(rnorm(50, 5), rnorm(50, 4), type = "glass_delta")

set.seed(2)
dt <- data.table(
  group     = rep(c("A", "B"), each = 50),
  outcome   = rnorm(100, 10, 2),
  predictor = rnorm(100, 5, 1)
)
coefs <- fit_group_models(dt, outcome ~ predictor, "group")
coefs
stopifnot(d > 0, nrow(coefs) == 4L, identical(names(coefs), c("group", "term", "estimate")))
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
  co <- coef(lm(score ~ 1, data = group_dt))
  data.table(term = names(co), estimate = unname(co))
}
# Not as.data.table(co, keep.rownames = "term"): on a named vector that silently
# yields columns V1 and V2, and the "term" name is ignored.
dt_list <- split(dt, by = "group")
coefs   <- rbindlist(lapply(dt_list, fit_group), idcol = "group")
coefs
stopifnot(identical(names(coefs), c("group", "term", "estimate")))

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
stopifnot(nrow(sim_results) == 50L)

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

## Model Output as data.tables

A fitted model is an object with its own accessor vocabulary, and every package has a
different one: `coef(summary(fit))` for `lm()` and `lmer()`, `summary(fit)$s.table` for an
mgcv smooth, `posterior::as_draws_df()` for anything sampled. Reports, figures, and tests
should not know any of that. Put the extraction in one layer of small functions that return
plain data.tables, one row per term, and have everything downstream consume those. When a
model changes class, from `lm()` to a mixed model, or from maximum likelihood to a
Bayesian fit, one file changes and the report does not.

<!-- example: file=R/tidy.R -->
```r
# R/tidy.R
library(data.table)

# One row per term, for any fit whose summary() carries a coefficient matrix: lm, glm, lmer
tidy_coef <- function(fit) {
  co <- coef(summary(fit))
  data.table(term = rownames(co), estimate = co[, 1], se = co[, 2])
}

# One row per smooth term, from mgcv's summary()
tidy_smooth <- function(fit) {
  st <- summary(fit)$s.table
  data.table(term = rownames(st), edf = st[, "edf"], p = st[, "p-value"])
}

# One row per draw per variable, from anything posterior can read: a CmdStanMCMC's
# $draws(), a brmsfit's $fit, or a draws object. Never the fitting package's accessors
tidy_draws <- function(draws, variables) {
  d <- posterior::subset_draws(posterior::as_draws(draws), variable = variables)
  melt(as.data.table(posterior::as_draws_df(d)),
       id.vars = c(".chain", ".iteration", ".draw"), variable.name = "variable")
}
```

The payoff is that fits of different classes stack, and a table comparing them is one
`rbindlist()`:

```r
library(data.table)
library(mgcv)
library(lme4)
source(here::here("R", "tidy.R"))

set.seed(5)
n  <- 200
dt <- data.table(group = rep(sprintf("g%02d", 1:10), each = 20), age = runif(n, 10, 20))
dt[, score   := 50 + 3 * sin(age / 3) + rnorm(n, sd = 2)]
dt[, outcome := 10 + 0.4 * score + rnorm(10)[as.integer(factor(group))] + rnorm(n)]

fits <- list(
  linear = lm(outcome ~ score, data = dt),
  mixed  = lmer(outcome ~ score + (1 | group), data = dt),
  smooth = gam(score ~ s(age), data = dt)
)
coefs <- rbindlist(lapply(fits[c("linear", "mixed")], tidy_coef), idcol = "model")
coefs
smooths <- tidy_smooth(fits$smooth)
smooths
stopifnot(identical(names(coefs), c("model", "term", "estimate", "se")), nrow(coefs) == 4L,
          smooths$term == "s(age)", smooths$edf > 1)
```

A Bayesian fit goes through the same layer. The draws come out of `posterior`, never out of
the fitting package's own accessors, and the function returns a data.table of draws, one
row per draw per variable, that `melt()` and `by =` already know how to summarise. It is
in `R/tidy.R` above, and it takes anything `posterior` can read: a CmdStanMCMC's
`$draws()`, a brmsfit's `$fit`, or a draws object already in hand. The demonstration
fits a two-parameter model through cmdstanr, so it needs CmdStan installed:

<!-- example: file=stan/normal.stan -->
```stan
data {
  int<lower=0> N;
  vector[N] y;
}
parameters {
  real mu;
  real<lower=0> sigma;
}
model {
  mu ~ normal(0, 5);
  sigma ~ normal(0, 2);
  y ~ normal(mu, sigma);
}
```

```r
library(data.table)
library(cmdstanr)
source(here::here("R", "tidy.R"))

set.seed(6)
y   <- rnorm(50, mean = 3, sd = 1.5)
mod <- cmdstan_model("stan/normal.stan")
fit <- mod$sample(data = list(N = length(y), y = y), chains = 2, iter_warmup = 300,
                  iter_sampling = 300, refresh = 0, seed = 6)

draws <- tidy_draws(fit$draws(), c("mu", "sigma"))
draws[, .(mean = mean(value), lo = quantile(value, 0.05), hi = quantile(value, 0.95)),
      by = variable]
stopifnot(identical(names(draws), c(".chain", ".iteration", ".draw", "variable", "value")),
          nrow(draws) == 2L * 600L,
          abs(draws[variable == "mu", mean(value)] - 3) < 0.6)
```

<!-- example: file=tests/test-tidy.R -->
```r
# tests/test-tidy.R
library(testthat)
library(data.table)
source(here::here("R", "tidy.R"))

test_that("tidy_coef returns one row per term with estimate and se", {
  fit <- lm(dist ~ speed, data = cars)
  out <- tidy_coef(fit)
  expect_s3_class(out, "data.table")
  expect_named(out, c("term", "estimate", "se"))
  expect_equal(out$term, c("(Intercept)", "speed"))
  expect_equal(out$estimate, unname(coef(fit)))
})

test_that("tidy_smooth reports the smooth's edf", {
  set.seed(1)
  d   <- data.frame(x = seq(0, 10, length.out = 100))
  d$y <- sin(d$x) + rnorm(100, sd = 0.2)
  out <- tidy_smooth(mgcv::gam(y ~ s(x), data = d))
  expect_equal(out$term, "s(x)")
  expect_gt(out$edf, 1)
})

test_that("tidy_draws gives one row per draw per variable", {
  ex  <- posterior::example_draws()     # eight schools: mu, tau, theta[1:8]
  out <- tidy_draws(ex, c("mu", "tau"))
  expect_named(out, c(".chain", ".iteration", ".draw", "variable", "value"))
  expect_equal(nrow(out), 2 * posterior::ndraws(ex))
  expect_equal(sort(unique(as.character(out$variable))), c("mu", "tau"))
})
```

---

## Large Data: Memory-Efficient Patterns

When data is large (hundreds of MB to GB+), several concerns become critical:
unnecessary copies, column-wise reads, and compute-before-load filtering.

### Read Only What You Need

<!-- example: skip -->
```r
# fread is the right tool — it's fast and flexible
dt <- fread("big.csv")

# Read only specific columns
dt <- fread("big.csv", select = c("id", "date", "outcome"))

# Read only rows matching a condition using shell preprocessing
dt <- fread(cmd = "grep 'treatment' big.csv")
dt <- fread(cmd = "awk -F, '$3 == \"A\"' big.csv")  # column filter
```

Do not chunk a CSV with `readLines()`. A quoted field may contain a newline (RFC 4180
allows it), and a line-based split cuts that record in two with no error. For a file that
does not fit in memory, convert it to parquet once and query it lazily; see
[Arrow Datasets and DuckDB](#large-data-arrow-datasets-and-duckdb) below.

### Modify In Place (data.table)

Adding a column does not copy a data frame: the unchanged columns are shared and only the
new one is allocated. The copies come from assigning *into* an
existing column. `df[i, "col"] <- v` duplicates the whole column before writing, and
`tracemem()` will show it. data.table's `:=` writes into the existing column — no copy.

<!-- example: skip -->
```r
# Base R: a subassignment copies the whole column first
df[df$value < 0, "value"] <- 0

# data.table: writes into the existing column in place
dt[value < 0, value := 0]

# Adding a column allocates only the new column, in either idiom
dt[, log_val := log(value)]

# Chain multiple in-place assignments
dt[, `:=`(
  log_val   = log(value),
  scaled    = (value - min(value)) / (max(value) - min(value)),
  flag      = value > threshold
)]
```

### Avoid Unnecessary Copies

<!-- example: skip -->
```r
# Bad: copy, filter, copy again
sub_dt  <- dt[group == "A"]             # copy
result  <- sub_dt[score > 0, .(n = .N)] # another copy

# Better: filter once in i
result <- dt[group == "A" & score > 0, .(n = .N)]

# When you need a subset you'll reuse, copy deliberately
group_a <- copy(dt[group == "A"])  # explicit, documented

# Base R copy-on-modify: df$new_col <- ... shares the existing columns, but
# df[i, "col"] <- ... copies that whole column before writing
# setDT() + := writes in place instead
```

### Column Types Matter

<!-- example: skip -->
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

### Identifiers Are Character

An identifier is a label, not a quantity. `fread()` cannot know that, so a column of `007`,
`042`, `100` comes back as the integers 7, 42, 100 and the zeros are gone. Nothing fails at
the read. The failure arrives two steps later, when the id has to match a file name, a
second table, or a participant list that kept its zeros. Declare the type at the read,
once, with `colClasses`, and let parquet carry it from there. A test that a padded id
survives a round trip is cheap, and it catches the regression the day someone re-exports
the CSV.

```r
library(data.table)
library(arrow)

csv <- tempfile(fileext = ".csv")
writeLines(c("id,score", "007,52", "042,61", "100,48"), csv)

fread(csv)$id                                     # 7 42 100: the zeros are gone
ids <- fread(csv, colClasses = c(id = "character"))
ids$id                                            # "007" "042" "100"

# The damage shows up two steps later, when the id has to match something else
paste0("sub-", fread(csv)$id)[1]                  # "sub-7": no such file, no such row
paste0("sub-", ids$id)[1]                         # "sub-007"

# Parquet keeps the type, so the decision made at the read survives every later read
pq <- tempfile(fileext = ".parquet")
write_parquet(ids, pq)
back <- as.data.table(read_parquet(pq))
stopifnot(is.character(back$id), identical(back$id, c("007", "042", "100")))
```

### Keys and Indices for Repeated Lookups

If you'll be subsetting or joining on a column repeatedly, set a key. This sorts
the data in place (memory-efficient radix sort) and enables binary search lookups.

<!-- example: skip -->
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
dt[.("treatment"), on = "group"]  # on = is required — without a key or on=, this errors
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
# Reproducible because run_simulation() seeds itself from sim_id. mc.set.seed is TRUE by
# default and does not get you this — it seeds children from time and PID. Seed inside the
# worker, or set RNGkind("L'Ecuyer-CMRG") before set.seed().
sim_results <- rbindlist(mclapply(seq_len(50), run_simulation, mc.cores = n_cores))
sim_results

# ── Multiprocess (socket): parLapply ──────────────────────────────────────
# Use when: Windows, isolated workers needed, or distributing across nodes
cl <- makeCluster(n_cores)
# envir defaults to the global environment, which is not where run_simulation lives
# when this code runs inside a function or a sourced block
clusterExport(cl, varlist = "run_simulation", envir = environment())
invisible(clusterEvalQ(cl, library(data.table)))
# Not clusterSetRNGStream(cl, iseed = 42) here: it switches the workers to the
# L'Ecuyer-CMRG generator, and set.seed(sim_id) inside the worker then draws different
# numbers than the same call under the default generator. Use it when the worker does
# not seed itself; seeding in the worker and streams on the cluster do not combine.

sim_results2 <- rbindlist(parLapply(cl, seq_len(50), run_simulation))
stopCluster(cl)
sim_results2

# Both routes seed inside the worker from sim_id, so they agree exactly
stopifnot(identical(sim_results, sim_results2))

# Quick check before parallelising — is one item worth the overhead?
system.time(run_simulation(1))
```

</details>

### Binary Formats: Use Parquet

Never re-read a CSV in an iterative workflow. After the first read, write parquet.

One format, not two. Splitting the job across two formats, one for working data and one
for storage, has a failure mode of its own. A "working" file has a way of becoming the
shared one, and the moment it does, the tier you chose months ago is a format mismatch
nobody looks for. One format has no such seam. That is the reason for the rule; what
follows is why the one format is parquet.

Feather (Arrow IPC) is faster to read, and that is the only argument for it. Against it,
the [Arrow project's own FAQ](https://arrow.apache.org/faq/) says the IPC format does not
prioritize long-term storage, that parquet files are often much smaller, and that parquet
may be the better choice even for short-term caching when disk or network is slow. And
parquet is what everything else reads (DuckDB, Polars, Spark, BigQuery, pandas).

Feather keeps a narrow case: a short-lived handoff between two processes on the same
machine, written and consumed inside one run, never persisted. Outside that, use parquet.

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

# ── Parquet: the default for anything on disk ─────────────────────────────
parquet_path <- tempfile(fileext = ".parquet")
write_parquet(dt_raw, parquet_path)
dt <- as.data.table(read_parquet(parquet_path))

# Column selection on read — only the named columns leave the file
dt_sub <- as.data.table(read_parquet(parquet_path, col_select = c("id", "outcome")))
stopifnot(nrow(dt) == 1000L, identical(names(dt_sub), c("id", "outcome")))

# Compression is per-file; zstd is a good default when size matters
write_parquet(dt_raw, parquet_path, compression = "zstd")

# ── Format reference ───────────────────────────────────────────────────────
# parquet:  the default — compact, predicate pushdown, read by everything
# feather:  short-lived same-machine handoff only, written and consumed in one run
# RDS:      arbitrary R objects (models, lists) — not for data frames
# CSV:      only for handoff to tools that can't read binary formats
```

### Large Data: Arrow Datasets and DuckDB

For data that doesn't fit comfortably in memory, or large partitioned data on disk
where you only ever need a slice, Arrow datasets with DuckDB as the query engine
are the right architecture.

**Arrow `open_dataset()`** provides lazy evaluation over a directory of parquet
files. Filters, column selection, and group aggregations are pushed down to
the file layer — only the result enters R memory. Writing with `partitioning`
creates a Hive-style directory structure (`year=2021/group=treatment/`) that Arrow
exploits for partition pruning: `filter(year == 2021)` never touches files from other years.

**DuckDB** is an in-process analytical database that queries parquet files
directly, with the Arrow zero-copy integration meaning no data moves between
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
    AND    \"group\" = 'treatment'
  GROUP BY cohort
", part_dir)))
result_parquet

# The in-memory table and the partitioned files answer the same query the same way.
# all.equal(), not identical(): the files are summed in a different order, and floating
# point addition is not associative
stopifnot(isTRUE(all.equal(result_dt[order(cohort)], result_parquet[order(cohort)])))

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
dt[, verdict := fifelse(score > threshold, "pass", "fail")]
dt
stopifnot(all(dt$verdict %in% c("pass", "fail")), all(dt$category %in% c("high", "medium", "low")))
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

### S7: Learn It, Default to S3

S7 offers S4-like structure with S3-like simplicity, and it comes out of the R Consortium
working group (R-Core, Bioconductor, and Posit are all represented) as a proposed successor
to S3 and S4. That makes it the right thing to learn.

It is not the default. S7 is badged `lifecycle: experimental`, and its own README says the
authors "reserve the right" to make breaking changes. The rule is S3 unless a class needs
what S3 cannot give (validated, typed properties; dispatch on more than one argument), and
the reason is written down beside the class definition. A class built on S7 is a class you
have agreed to revisit when the API moves.

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
msg <- tryCatch(Interval(lo = 5, hi = 1), error = function(e) conditionMessage(e))
msg
stopifnot(grepl("@hi must be >= @lo", msg, fixed = TRUE))
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
# Fix: read once, write parquet; see the Large Data section
```

---

## Package Development

### Dependency Philosophy

Every dependency you add is a dependency your users carry, so each one should be able to
say why it is there. The objection this guide makes is to the tidyverse dialect, a second
grammar for operations base R and data.table already express, and to the dependency graph
that arrives with it. It is not an objection to dependencies as such. A package earns a
place on the list by meeting three criteria: (i) it does something base R and data.table do
not, or does it in a cross-language format or at a speed that matters; (ii) it does not
bring its own grammar for things you can already write; (iii) it is maintained, and its
lifecycle is stated. The approved list, each with the criterion it meets:

```r
# - data.table: reference semantics and a grouping grammar base R lacks; no dependencies
# - ggplot2:    a grammar of graphics base graphics does not have, and it stands alone
# - stringr:    one consistent string API; a thin layer over stringi
# - stringi:    ICU-backed Unicode and locale operations base R cannot do
# - arrow:      parquet, a cross-language on-disk format, and lazy datasets
# - duckdb:     out-of-core SQL over parquet, zero-copy with arrow
# - here:       project-root paths that survive test_dir() changing the working directory
# - lubridate:  date arithmetic base R makes error-prone; heavy date work only
# - S7:         validated, typed classes; experimental, so justified per class
# - testthat:   the test runner
# - targets:    the dependency graph for a multi-step analysis
# - tarchetypes: tar_quarto(), so the report is a target and cannot go stale
# - quarto:     renders the report from R; the Quarto CLI does the work
# - crew:       where targets run; the same pipeline on a laptop, a scheduler, or a cloud
# - parallel:   ships with R
# - Rcpp:       C++ once profiling has shown R is the bottleneck
# - Matrix:     sparse matrices
# - lme4/brms:  modeling
# - cmdstanr:   the Stan backend; posterior reads its draws
# - posterior:  draws and summaries from any Bayesian fit, independent of the backend

# Not worth adding to avoid writing 3 lines of base R:
# - dplyr   (use data.table)
# - purrr   (use lapply/vapply/Map)
# - tidyr   (use melt/dcast from data.table)
# - forcats (use factor() / levels())
# - readr   (use fread)
# - tibble  (use data.table or data.frame)
# - fst     (use parquet)
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
msg_col <- tryCatch(fit_model(dt, "y", c("x1", "missing_col")), error = conditionMessage)
msg_cls <- tryCatch(fit_model(as.data.frame(dt), "y", "x1"),    error = conditionMessage)
msg_col
msg_cls
stopifnot(grepl("missing_col", msg_col, fixed = TRUE), grepl("must be a data.table", msg_cls, fixed = TRUE))

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

<!-- example: skip -->
```r
install.packages(c("testthat", "here"))
```

For a standalone script workflow (no package), put tests in a `tests/` directory
and run them with `testthat::test_dir("tests/")`. Source the code under test with
`here::here()`, not a path relative to the project root: `test_dir()` and `test_file()`
change the working directory to `tests/` while the tests run. That is the one dependency
this layout costs; the alternative is to make the project a package, which is the layout
`test_dir()` assumes and what `usethis::use_testthat()` wires up. Either is fine. What is
not fine is a test file that only passes when run from one particular directory.

```
project/
├── .here              # empty file; marks the root for here::here()
├── R/
│   └── analysis.R
└── tests/
    └── test-analysis.R
```

### Writing Tests

<details>
<summary>Example test file</summary>

<!-- example: file=tests/test-analysis.R -->
```r
# tests/test-analysis.R
library(testthat)
# test_dir() runs with the working directory set to tests/, so source("R/analysis.R")
# does not resolve. here() finds the project root (a .git directory, an .Rproj file,
# or an empty .here file) from any working directory.
source(here::here("R", "analysis.R"))

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
  expect_error(compute_effect_size("a", 1:5), "must be numeric")
})

test_that("compute_effect_size handles equal vectors", {
  x <- c(1, 2, 3)
  expect_equal(compute_effect_size(x, x, type = "cohen_d"), 0)
})
```

</details>

### Core Expectations

<!-- example: skip -->
```r
# Equality
expect_equal(result, expected)           # numeric: tolerance sqrt(.Machine$double.eps), ~1.5e-8
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

<!-- example: file=tests/test-datatable.R -->
```r
# tests/test-datatable.R
library(testthat)
library(data.table)
source(here::here("R", "analysis.R"))

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

# In a package: devtools::test()

# Run a subset of files: filter is a regex on the file name with "test-" and ".R"
# stripped — not on test descriptions. This runs tests/test-analysis.R only
testthat::test_dir("tests/", filter = "analysis")
```

### What to Test

Test the contract of a function — its inputs, outputs, and error conditions —
not its implementation. If the body changes but the contract holds, your tests
should still pass.

<!-- example: file=tests/test-models.R -->
```r
# tests/test-models.R
library(testthat)
library(data.table)
source(here::here("R", "analysis.R"))

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

<!-- example: skip -->
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
<summary>_targets.R, R/functions.R, the data, and common commands</summary>

<!-- example: file=_targets.R -->
```r
# _targets.R
library(targets)

# Load your functions — keep them in R/ and source them here
tar_source("R/functions.R")

# Set options (packages available to all targets, common format, etc.)
tar_option_set(packages = c("data.table", "ggplot2"))

# Define the pipeline as a list of tar_target() calls
list(
  tar_target(raw_path,    "data/raw.csv", format = "file"),  # rerun if the file changes
  tar_target(raw_data,    load_raw(raw_path)),               # depends on raw_path
  tar_target(clean_data,  clean(raw_data)),                  # depends on raw_data
  tar_target(model,       fit_model(clean_data)),            # depends on clean_data
  tar_target(figure,      plot_results(model, clean_data))
)
```

<!-- example: file=R/functions.R -->
```r
# R/functions.R
load_raw <- function(path) {
  fread(path)
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
  dt <- copy(dt)
  dt[, fitted := fitted(model)]
  ggplot(dt, aes(x = score_z, y = outcome, colour = group)) +
    geom_point() +
    geom_line(aes(y = fitted)) +
    theme_bw()
}
```

A dozen rows of data, one of them with a missing outcome for `clean()` to drop:

<!-- example: file=data/raw.csv -->
```csv
id,group,age,score,outcome
1,A,21,52,10.1
2,A,25,61,11.4
3,A,30,48,9.2
4,A,34,70,12.8
5,A,41,55,10.9
6,A,45,66,
7,B,22,58,9.8
8,B,27,63,10.7
9,B,31,45,8.9
10,B,36,72,12.1
11,B,40,50,9.5
12,B,44,68,11.6
```

```r
library(targets)

# Run the pipeline — only outdated targets execute
tar_make()

# Inspect results
tar_read(clean_data)    # load a target's value into session
tar_load(model)         # load into environment by name

# Check pipeline status
tar_outdated()          # which targets need to rerun; nothing, right after tar_make()
tar_manifest()          # table of all targets and their commands
# tar_visnetwork()      # dependency graph in the Viewer; needs the visNetwork package

stopifnot(length(tar_outdated()) == 0L, inherits(model, "lm"), nrow(tar_read(clean_data)) == 11L)
```

</details>

### File Targets: Track Input and Output Files

When a target reads or writes a file, declare it with `format = "file"` so
targets tracks the file's hash, not just whether the code changed. The minimal pipeline
above already does this for its input; the output-file form is the second target here.

<!-- example: skip -->
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

Static branching, with the inputs known when the pipeline is written:

<!-- example: skip -->
```r
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
```

Dynamic branching, as a complete second pipeline script over the same functions and data:

<!-- example: file=_targets_branching.R -->
```r
# _targets_branching.R
library(targets)
tar_source("R/functions.R")
tar_option_set(packages = "data.table")

# One function per branch. It carries the group label in its output, because the
# branch names targets generates are hashes, not labels.
tidy_group <- function(dt) {
  co <- coef(lm(outcome ~ score_z, data = dt))
  data.table(term = names(co), estimate = unname(co), group = dt$group[1])
}

list(
  tar_target(raw_path,   "data/raw.csv", format = "file"),
  tar_target(raw_data,   load_raw(raw_path)),
  tar_target(clean_data, clean(raw_data)),

  # Split into a list of data.tables — one per group. iteration = "list" makes
  # each branch below receive one element; with the default "vector" iteration
  # a branch gets a length-one list instead, and lm() fails with "object not found"
  tar_target(
    group_data,
    split(clean_data, by = "group"),
    iteration = "list"
  ),

  # One branch per group. iteration = "list" again, so the downstream target
  # receives the branches as a plain list rbindlist() can stack; with the default,
  # targets stacks them itself and rbindlist() refuses the result
  tar_target(
    group_coefs,
    tidy_group(group_data),
    pattern   = map(group_data),
    iteration = "list"
  ),

  # Aggregate: naming the upstream target gives a downstream target every branch.
  # tar_read() is for interactive use — never call it inside a command
  tar_target(all_coefs, rbindlist(group_coefs))
)
```

A second script needs its own store, or it would invalidate the first pipeline's:

```r
library(targets)
tar_make(script = "_targets_branching.R", store = "_targets_branching")
all_coefs <- tar_read(all_coefs, store = "_targets_branching")
all_coefs
stopifnot(identical(names(all_coefs), c("term", "estimate", "group")),
          identical(sort(unique(all_coefs$group)), c("A", "B")))
```

The case that comes up most in analysis is neither of those: a table of specifications,
one row per model to fit, as in a multiverse or a specification curve. Rows are the
natural unit, and the default iteration handles them. `map(spec)` hands each branch one
row, and the downstream target receives the one-row results already stacked into a
data.table, with no `iteration = "list"` and no `rbindlist()`. The rule, then: branch over
the rows of a table with the default, and over the elements of a list with
`iteration = "list"`. This script also runs its branches on two local workers; the lines
that decide that are explained under Running Somewhere Else.

<!-- example: file=_targets_grid.R -->
```r
# _targets_grid.R: a specification grid, one branch per row
library(targets)
library(data.table)
tar_source("R/functions.R")
tar_option_set(
  packages   = "data.table",
  controller = crew::crew_controller_local(workers = 2),
  storage    = "worker",
  retrieval  = "worker"
)

# One specification in, one row out. The spec's own columns come along, so the result
# says which model it belongs to without a join
fit_spec <- function(dt, spec) {
  rhs <- if (spec$covariate == "none") "score_z" else paste("score_z", spec$covariate, sep = " + ")
  d   <- if (spec$subset == "all") dt else dt[group == spec$subset]
  fit <- lm(as.formula(paste("outcome ~", rhs)), data = d)
  data.table(spec, estimate = coef(fit)[["score_z"]], n = nrow(d))
}

list(
  tar_target(raw_path,   "data/raw.csv", format = "file"),
  tar_target(raw_data,   load_raw(raw_path)),
  tar_target(clean_data, clean(raw_data)),
  tar_target(spec,       CJ(covariate = c("none", "age"), subset = c("all", "A", "B"))),
  tar_target(spec_fit,   fit_spec(clean_data, spec), pattern = map(spec)),
  tar_target(curve,      spec_fit[order(estimate)])
)
```

```r
library(targets)
tar_make(script = "_targets_grid.R", store = "_targets_grid")
curve <- tar_read(curve, store = "_targets_grid")
curve
stopifnot(nrow(curve) == 6L, identical(names(curve), c("covariate", "subset", "estimate", "n")))
```

</details>

### TDD and targets Together

Write and test your functions in isolation with testthat. The pipeline wires
them together — it is not a substitute for function-level tests. `clean()` in
`R/functions.R` above is a pure function; its test is:

<!-- example: file=tests/test-functions.R -->
```r
# tests/test-functions.R — test the function, not the pipeline
library(testthat)
library(data.table)
source(here::here("R", "functions.R"))

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

### Running Somewhere Else

A pipeline is a graph of function calls. Where those calls run is a separate decision, and
targets keeps it separate: a `crew` controller, set once in `tar_option_set()`, launches the
workers, and the same `_targets.R` runs on a laptop, a shared server, an HPC scheduler, or
a cloud batch service. The controller is the only line that changes.

| Where | Controller | Package |
|---|---|---|
| This machine, several processes | `crew_controller_local()` | `crew` |
| A scheduler: SLURM, SGE, PBS/Torque, LSF | `crew_controller_slurm()`, `_sge()`, `_pbs()`, `_lsf()` | `crew.cluster` |
| Cloud batch | `crew_controller_aws_batch()` | `crew.aws.batch` |

The grid pipeline above already runs on two local workers. Its `tar_option_set()` call is
the whole deployment configuration:

<!-- example: skip -->
```r
tar_option_set(
  packages   = "data.table",
  controller = crew::crew_controller_local(workers = 2),
  storage    = "worker",    # workers write their results to the store themselves
  retrieval  = "worker"     # and read their inputs themselves
)
```

Swap the controller and nothing else moves:

<!-- example: skip -->
```r
# A scheduler: one worker per job, each asking for what a branch needs
controller = crew.cluster::crew_controller_slurm(
  workers         = 50,
  seconds_idle    = 120,                     # release the job when there is no work
  options_cluster = crew.cluster::crew_options_slurm(
    memory_gigabytes_required = 8,
    cpus_per_task             = 2,
    time_minutes              = 60
  )
)

# The same pipeline on a machine with no scheduler but many cores
controller = crew::crew_controller_local(workers = 16, seconds_idle = 60)
```

Three settings matter once the workers are not the main process. `storage = "worker"` and
`retrieval = "worker"` move data directly between workers and the store rather than through
the main process, which is otherwise both the bottleneck and the memory ceiling.
`memory = "transient"`, with `garbage_collection = TRUE`, drops a target's value from the
main process once its dependents have it, which is what keeps a pipeline of fitted models
from holding every fit at once. And a large data target should be a file, `format = "file"`
with a parquet path, so the store holds a pointer and the workers read the file (see Binary
Formats). A cheap target can stay on the main process with `deployment = "main"`, so no
worker is launched to add two numbers.

What does not change between backends: the functions in `R/`, their tests, the branching,
and the store layout. That is the argument for keeping the pipeline thin. A controller swap
is only free when nothing in `_targets.R` knows where it runs.

### Common Operations

<!-- example: skip -->
```r
# Add targets and testthat to your package list
tar_option_set(packages = c("data.table", "ggplot2", "stringr"))

# Invalidate a specific target (force rerun)
tar_invalidate(model)

# Delete all cached targets and start fresh
tar_destroy()

# Run in parallel: a crew controller, set once. See Running Somewhere Else
tar_option_set(controller = crew::crew_controller_local(workers = 4))
tar_make()

# Store targets in a non-default location (useful for large outputs).
# store is a tar_config_set() setting; tar_option_set(store = ...) errors with
# "unused argument"
tar_config_set(store = "cache/_targets")
```

---

## Reports: Quarto on Top of targets

A report is the thing a reader sees, and the rule for it is the rule for the pipeline: the
computation happens in targets, and the report reads it. A Quarto document that fits a
model in a chunk is a pipeline with no dependency graph, no cache, and no tests, and it
takes as long to render as the model takes to fit. Three practices follow, and the
pipeline below does all three.

**The report reads targets.** `tar_read()` and `tar_load()` in a chunk, and nothing else.
Figures are targets too (a ggplot object stores fine), so the report renders in seconds and
a figure can be tested before a reader sees it.

**The report is a target.** `tarchetypes::tar_quarto()` renders it inside `tar_make()`, and
because the document reads the store, targets sees the dependency: a report cannot be stale
relative to the fit that feeds it. Set `lightbox: true` in the HTML format, so dense
analysis figures are click-to-zoom, and `embed-resources: true`, so the file travels
alone.

**Strings a report emits are code, and tested.** A caption builder returns a declarative
sentence, finding first and mechanics after, and its test pins that shape. A caption is
read out of context, so it sits a notch more formal than the prose around it.

<!-- example: file=R/captions.R -->
```r
# R/captions.R
# A caption states the finding, then the mechanics, in one sentence
caption_fit <- function(model, dt) {
  b <- coef(summary(model))["score_z", ]
  sprintf("Outcome rises %.2f per SD of score (SE %.2f, N = %d).",
          b[["Estimate"]], b[["Std. Error"]], nrow(dt))
}
```

<!-- example: file=tests/test-captions.R -->
```r
# tests/test-captions.R
library(testthat)
library(data.table)
source(here::here("R", "captions.R"))

test_that("caption_fit leads with the finding and ends with N", {
  dt  <- data.table(outcome = c(1, 2, 4, 5), score_z = c(-1.2, -0.4, 0.4, 1.2))
  cap <- caption_fit(lm(outcome ~ score_z, data = dt), dt)
  expect_match(cap, "^Outcome rises [0-9.]+ per SD of score")
  expect_match(cap, "N = 4\\)\\.$")
})
```

The document itself. Four backticks fence it here only because it contains fences of its
own:

<!-- example: file=report.qmd -->
````markdown
---
title: "Score and outcome"
format:
  html:
    lightbox: true
    embed-resources: true
---

```{r}
#| include: false
library(targets)
library(data.table)
source(here::here("R", "captions.R"))
tar_load(c(model, figure, clean_data))
```

The fit is read from the pipeline; nothing here refits it.

```{r}
#| echo: false
#| fig-cap: !expr caption_fit(model, clean_data)
figure
```
````

The pipeline is the minimal one from above plus one target. Because the model targets are
already in the store, a run of this script builds nothing but the report:

<!-- example: file=_targets_report.R -->
```r
# _targets_report.R: the minimal pipeline plus the report
library(targets)
library(tarchetypes)
tar_source("R/functions.R")
tar_option_set(packages = c("data.table", "ggplot2"))

list(
  tar_target(raw_path,    "data/raw.csv", format = "file"),
  tar_target(raw_data,    load_raw(raw_path)),
  tar_target(clean_data,  clean(raw_data)),
  tar_target(model,       fit_model(clean_data)),
  tar_target(figure,      plot_results(model, clean_data)),
  tar_quarto(report, "report.qmd")   # depends on whatever the document tar_load()s
)
```

```r
library(targets)
tar_make(script = "_targets_report.R")
progress <- tar_progress()
progress
stopifnot(file.exists("report.html"),
          progress$progress[progress$name == "model"]  == "skipped",
          progress$progress[progress$name == "report"] == "completed")
html <- paste(readLines("report.html", warn = FALSE), collapse = "\n")
stopifnot(grepl("Outcome rises", html, fixed = TRUE), grepl("lightbox", html, fixed = TRUE))
```

---

## Naming and Style

<!-- example: skip -->
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
| `distinct(dt, col)` | `unique(dt[, .(col)])`; `unique(dt, by = "col")` keeps the other columns, like `.keep_all = TRUE` |
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
