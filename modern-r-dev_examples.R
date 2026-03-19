# Modern R Development Guide — Runnable Examples
# Companion to modern-r-dev_jflournoy.md
# Each section is self-contained and can be run independently.

# ── Package Installation ──────────────────────────────────────────────────────

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


# ── Pipes: Prefer Intermediate Variables ─────────────────────────────────────

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
filtered   <- dt[!is.na(score)]
aggregated <- filtered[, .(mean_score = mean(score), n = .N), by = .(group, year)]
reshaped   <- dcast(aggregated, group ~ year, value.var = "mean_score")
result     <- merge(reshaped, ref, by = "group", all.x = TRUE)
result

# When intermediate objects would be large, modify in place
dt[, score_z := (score - mean(score)) / sd(score)]
dt[, flag    := score_z > 2]
dt[, label   := fcase(flag & group == "A", "outlier_A",
                      flag & group == "B", "outlier_B",
                      default = "normal")]
dt


# ── data.table: [i, j, by] Grammar ───────────────────────────────────────────

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
dt[, score_z := (score - mean(score)) / sd(score)]

# by: grouping
dt[, .(mean_score = mean(score)), by = group]
dt[, .(mean_score = mean(score)), by = .(group, year)]

# All three together
dt[age > 18, .(mean_score = mean(score), n = .N), by = group]


# ── Column Operations ─────────────────────────────────────────────────────────

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


# ── Grouping and Aggregation ──────────────────────────────────────────────────

library(data.table)

set.seed(42)
dt <- data.table(
  group = rep(c("A", "B", "C"), each = 30),
  year  = rep(rep(2021:2023, each = 10), 3),
  value = rnorm(90, mean = 100, sd = 15),
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


# ── Joins ─────────────────────────────────────────────────────────────────────

library(data.table)

dt_a <- data.table(
  id   = c("s01", "s02", "s03", "s04"),
  year = c(2021, 2021, 2022, 2022),
  score = c(82, 74, 91, 68)
)
dt_b <- data.table(
  id    = c("s01", "s02", "s03", "s05"),
  group = c("ctrl", "treat", "ctrl", "treat")
)

# merge: inner, left, compound key
merge(dt_a, dt_b, by = "id")                          # inner
merge(dt_a, dt_b, by = "id", all.x = TRUE)            # left join
merge(dt_a, dt_b, by.x = "id", by.y = "id")           # explicit names

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


# ── Reshaping ─────────────────────────────────────────────────────────────────

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


# ── Reference Semantics ───────────────────────────────────────────────────────

library(data.table)

dt <- data.table(x = 1:3, y = c("a", "b", "c"))

# dt_copy and dt point to the same object — modifying one changes both
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


# ── Base R: Functional Programming ───────────────────────────────────────────

# lapply / vapply / Map / Reduce on simple data — no files needed
dt_list <- list(
  A = data.frame(score = c(80, 90, 70)),
  B = data.frame(score = c(60, 85, 75)),
  C = data.frame(score = c(95, 55, 88))
)

# lapply: always returns a list
means_list <- lapply(dt_list, function(d) mean(d$score))
means_list

# vapply: type-safe, returns named numeric vector
means_vec <- vapply(dt_list, function(d) mean(d$score), numeric(1))
means_vec

# Map: two parallel lists
list_a <- list(1:3, 4:6, 7:9)
list_b <- list(10, 20, 30)
Map(function(x, y) x + y, list_a, list_b)

# Reduce: cumulative sum of vectors
Reduce("+", list(1:4, 5:8, 9:12))
Reduce("+", list(1:4, 5:8, 9:12), accumulate = TRUE)


# ── Apply Over Matrices ───────────────────────────────────────────────────────

library(data.table)

mat <- matrix(c(1, 2, NA, 4, 5, 6, 7, NA, 9), nrow = 3)

colMeans(mat, na.rm = TRUE)
rowSums(mat, na.rm = TRUE)
apply(mat, 1, function(x) sum(x^2, na.rm = TRUE))  # row-wise
apply(mat, 2, max, na.rm = TRUE)                    # col-wise

# On a data.table
dt <- data.table(a = c(1, 2, 3), b = c(4, NA, 6), c = c(7, 8, 9))
dt[, lapply(.SD, mean, na.rm = TRUE), .SDcols = is.numeric]


# ── Strings: stringr ──────────────────────────────────────────────────────────

library(stringr)

x    <- c("apple-42", "banana-7", "cherry-100", "NA-value", "café")
name <- "world"

# Detection
str_detect(x, "\\d+")
str_starts(x, "ban")
str_ends(x, "\\d")
str_count(x, "[aeiou]")

# Extraction
str_extract(x, "\\d+")
str_extract_all(x, "[a-z]+")
str_match(x, "(\\w+)-(\\d+)")

# Substitution
str_replace(x, "-", "_")
str_replace_all(x, "[aeiou]", "*")

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


# ── Strings: stringi ──────────────────────────────────────────────────────────

library(stringi)

x <- c("café", "naïve", "résumé", "hello")

stri_trans_general(x, "Latin-ASCII")       # strip accents: "cafe", "naive", ...
stri_sort(x, locale = "fr_FR")             # French locale sort
stri_pad_left(c("a", "bb", "ccc"), width = 5)
stri_count_regex(x, "[aeiou]")
stri_extract_all_words("the quick brown fox")


# ── Date/Time ─────────────────────────────────────────────────────────────────

Sys.Date()
as.Date("2024-01-15")
format(Sys.Date(), "%Y-%m")

start_date <- as.Date("2024-01-01")
end_date   <- as.Date("2024-06-30")
end_date - start_date
as.numeric(end_date - start_date)

seq(as.Date("2024-01-01"), as.Date("2024-06-01"), by = "month")


# ── ggplot2 ───────────────────────────────────────────────────────────────────

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

# Compute summaries in data.table, then plot
summary_dt <- dt[, .(
  mean = mean(score, na.rm = TRUE),
  se   = sd(score, na.rm = TRUE) / sqrt(.N)
), by = .(group, wave)]

ggplot(summary_dt, aes(x = wave, y = mean, color = group)) +
  geom_line() +
  geom_errorbar(aes(ymin = mean - se, ymax = mean + se), width = 0.2) +
  theme_bw()

# Custom reusable theme
my_theme <- theme_bw(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    strip.background = element_rect(fill = "grey92"),
    legend.position  = "bottom"
  )

# Prepare confidence intervals, then plot
plot_dt <- dt[, .(
  n        = .N,
  pct_pass = mean(passed),
  ci_lo    = mean(passed) - 1.96 * sqrt(mean(passed) * (1 - mean(passed)) / .N),
  ci_hi    = mean(passed) + 1.96 * sqrt(mean(passed) * (1 - mean(passed)) / .N)
), by = cohort]

ggplot(plot_dt, aes(x = cohort, y = pct_pass, ymin = ci_lo, ymax = ci_hi)) +
  geom_pointrange() +
  my_theme


# ── Functions ─────────────────────────────────────────────────────────────────

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


# ── Avoid Growing Objects ─────────────────────────────────────────────────────

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


# ── lapply + rbindlist: The Core Pattern ─────────────────────────────────────

library(data.table)
library(stringr)

# Core pattern: function returns one data.table per item, combine with rbindlist
summarise_group <- function(grp, dt) {
  d <- dt[group == grp]
  d[, .(group = grp, n = .N, mean_score = mean(score), sd_score = sd(score))]
}

set.seed(3)
dt      <- data.table(group = rep(c("A","B","C"), each = 40),
                      score = rnorm(120, 70, 10))
groups  <- unique(dt$group)
results <- lapply(groups, summarise_group, dt = dt)
rbindlist(results)

# idcol: label which split produced each row
fit_group <- function(group_dt) {
  as.data.table(coef(lm(score ~ 1, data = group_dt)), keep.rownames = "term")
}
dt_list <- split(dt, by = "group")
rbindlist(lapply(dt_list, fit_group), idcol = "group")

# use.names + fill: safe stacking when columns may differ
r1 <- data.table(a = 1, b = 2)
r2 <- data.table(a = 3,      c = 5)
rbindlist(list(r1, r2), use.names = TRUE, fill = TRUE)

# Index-based: seed per simulation
run_simulation <- function(sim_id) {
  set.seed(sim_id)
  x <- rnorm(30)
  data.table(sim_id = sim_id, estimate = mean(x), se = sd(x) / sqrt(length(x)))
}
sim_results <- rbindlist(lapply(seq_len(50), run_simulation))
sim_results

# Nested: two loops, flatten once
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


# ── Large Data: In-Place Modifications ───────────────────────────────────────

library(data.table)

set.seed(5)
dt <- data.table(
  id        = 1:500,
  value     = rnorm(500, 100, 20),
  group     = sample(c("A","B"), 500, replace = TRUE),
  score     = rnorm(500)
)
threshold <- 110

# Modify in place — no copies
dt[, log_val := log(value)]
dt[, `:=`(
  scaled = (value - min(value)) / (max(value) - min(value)),
  flag   = value > threshold
)]

# Avoid unnecessary copies: filter once
result_bad  <- dt[group == "A"][score > 0, .(n = .N)]   # two passes
result_good <- dt[group == "A" & score > 0, .(n = .N)]  # one pass
result_good

# Explicit copy when you need an independent subset
group_a <- copy(dt[group == "A"])


# ── Column Types ─────────────────────────────────────────────────────────────

library(data.table)

dt <- data.table(
  id       = c(1L, 2L, 3L),
  date_str = c("2024-01-15", "2024-03-22", "2024-07-04"),
  group    = c("A", "B", "A"),
  count    = c(10.0, 20.0, 30.0)
)

dt[, lapply(.SD, class)]

dt[, id    := as.character(id)]
dt[, date  := as.IDate(date_str, format = "%Y-%m-%d")]
dt[, group := as.factor(group)]
dt[, count := as.integer(count)]

dt[, lapply(.SD, class)]


# ── Keys and Indices ─────────────────────────────────────────────────────────

library(data.table)

set.seed(6)
dt <- data.table(
  id    = paste0("s", sprintf("%03d", 1:100)),
  group = sample(c("control", "treatment"), 100, replace = TRUE),
  score = rnorm(100, 75, 10)
)

# Key for fast repeated lookup by id
setkey(dt, id)
dt["s042"]

# Key for joins
dt_meta <- data.table(
  id     = paste0("s", sprintf("%03d", 1:100)),
  cohort = sample(c("C1","C2","C3"), 100, replace = TRUE)
)
setkey(dt_meta, id)
dt_meta[dt]  # keyed join

# Secondary index — doesn't reorder the table
setindex(dt, group)
dt[.("treatment"), on = "group"]


# ── Parallelism ───────────────────────────────────────────────────────────────

library(data.table)
library(parallel)

n_cores <- max(1L, parallel::detectCores(logical = FALSE) - 1L)

run_simulation <- function(sim_id) {
  set.seed(sim_id)
  x <- rnorm(100)
  data.table(sim_id = sim_id, estimate = mean(x), se = sd(x) / sqrt(length(x)))
}

# mclapply (fork-based, Unix/Mac)
# WARNING: unstable inside RStudio/Positron on macOS — run from terminal if hangs occur
sim_results <- rbindlist(mclapply(seq_len(50), run_simulation, mc.cores = n_cores,
                                  mc.set.seed = TRUE))
sim_results

# parLapply (socket cluster, works on Windows)
cl <- makeCluster(n_cores)
clusterExport(cl, varlist = "run_simulation")
invisible(clusterEvalQ(cl, library(data.table)))
clusterSetRNGStream(cl, iseed = 42)

sim_results2 <- rbindlist(parLapply(cl, seq_len(50), run_simulation))
stopCluster(cl)
sim_results2

# Quick check before parallelising — is one item worth the overhead?
system.time(run_simulation(1))


# ── Binary Formats: Feather and Parquet ──────────────────────────────────────

library(data.table)
library(arrow)

set.seed(7)
dt_raw <- data.table(
  id      = 1:1000,
  outcome = rnorm(1000),
  group   = sample(c("A","B","C"), 1000, replace = TRUE),
  date    = seq.Date(as.Date("2022-01-01"), by = "day", length.out = 1000)
)

# Feather: fast reads, good for iterative work
feather_path <- tempfile(fileext = ".arrow")
write_feather(dt_raw, feather_path)
dt <- as.data.table(read_feather(feather_path))

# Column selection on read
dt_sub <- as.data.table(read_feather(feather_path, col_select = c("id", "outcome")))

# Parquet: best compression, good for storage and sharing
parquet_path <- tempfile(fileext = ".parquet")
write_parquet(dt_raw, parquet_path)
dt2     <- as.data.table(read_parquet(parquet_path))
dt2_sub <- as.data.table(read_parquet(parquet_path, col_select = c("id", "group")))


# ── Arrow Datasets and DuckDB ─────────────────────────────────────────────────

library(data.table)
library(arrow)
library(duckdb)

set.seed(8)
dt <- data.table(
  id      = 1:400,
  year    = rep(2020:2023, each = 100),
  group   = sample(c("control","treatment"), 400, replace = TRUE),
  cohort  = sample(c("C1","C2"), 400, replace = TRUE),
  outcome = rnorm(400, 10, 2),
  weight  = runif(400)
)

# Write a partitioned dataset
part_dir <- file.path(tempdir(), "partitioned")
write_dataset(dt, path = part_dir, format = "parquet",
              partitioning = c("year", "group"))

# DuckDB: register a data.table as a virtual table (zero copy) and query it
# SQL is the query language here — there are no dplyr-style verbs without loading
# dplyr, which conflicts with data.table. SQL is the right tool for this layer.
con <- dbConnect(duckdb())
duckdb_register(con, "dt", dt)

# WHERE = filter rows, SELECT = choose columns, GROUP BY = aggregate
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

# DuckDB also handles window functions cleanly
result_ranked <- as.data.table(dbGetQuery(con, "
  SELECT   id, cohort, outcome,
           ROW_NUMBER() OVER (PARTITION BY cohort ORDER BY outcome DESC) AS rnk
  FROM     dt
  WHERE    year >= 2021
"))
result_ranked

# Query partitioned parquet files directly — without loading anything into R first
result_parquet <- as.data.table(dbGetQuery(con, sprintf("
  SELECT   cohort, AVG(outcome) AS mean_outcome, COUNT(*) AS n
  FROM     read_parquet('%s/**/*.parquet')
  WHERE    year = 2021
  GROUP BY cohort
", part_dir)))
result_parquet

dbDisconnect(con, shutdown = TRUE)


# ── Memory Monitoring ─────────────────────────────────────────────────────────

library(data.table)

dt    <- data.table(x = rnorm(1e5), y = rnorm(1e5))
small <- data.table(a = 1:10)

format(object.size(dt), units = "MB")

tables()  # accurate sizes for all data.tables in session

sizes <- vapply(ls(), function(nm) object.size(get(nm)), numeric(1))
head(sort(sizes, decreasing = TRUE), 5)

rm(small)
gc()


# ── Vectorization ─────────────────────────────────────────────────────────────

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


# ── OOP: S3 ───────────────────────────────────────────────────────────────────

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
  coefs   = coef(fit),
  vcov_mat = vcov(fit),
  df      = df.residual(fit),
  call    = fit$call
)
print(res)
coef(res)


# ── OOP: S4 ───────────────────────────────────────────────────────────────────

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


# ── OOP: S7 ───────────────────────────────────────────────────────────────────

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


# ── Performance: Profiling and Benchmarking ───────────────────────────────────

library(data.table)
library(bench)

set.seed(11)
dt <- data.table(
  x     = rnorm(1e5),
  group = sample(letters[1:5], 1e5, replace = TRUE)
)

# system.time for a quick check
system.time(dt[, .(mean_x = mean(x)), by = group])

# bench::mark for rigorous comparison
bench::mark(
  data_table  = dt[, .(mean_x = mean(x)), by = group],
  base_tapply = tapply(dt$x, dt$group, mean),
  min_iterations = 20,
  check = FALSE
)

# profvis::profvis for line-level flame graph (opens in viewer)
# library(profvis)
# profvis(dt[, .(mean_x = mean(x)), by = group])


# ── Input Validation and Error Messages ──────────────────────────────────────

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
