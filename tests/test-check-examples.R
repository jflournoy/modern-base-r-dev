# tests/test-check-examples.R
library(testthat)
source(here::here("check-examples.R"))

fixture <- c(
  "# Title",
  "",
  "## Section one",
  "",
  "```r",
  "x <- 1 + 1",
  "stopifnot(x == 2)",
  "```",
  "",
  "### Sub two",
  "",
  "<!-- example: skip -->",
  "```r",
  "undefined_thing()",
  "```",
  "",
  "<!-- example: file=data/raw.csv -->",
  "```csv",
  "a,b",
  "1,2",
  "```",
  "",
  "```",
  "project/",
  "└── R/",
  "```",
  "",
  "```r",
  "y <- read.csv(\"data/raw.csv\")",
  "stopifnot(nrow(y) == 1L)",
  "```"
)

test_that("parse_guide finds run, skip, and file blocks and ignores plain fences", {
  blocks <- parse_guide(fixture)
  expect_length(blocks, 4L)
  expect_equal(vapply(blocks, `[[`, "", "mode"), c("run", "skip", "file", "run"))
  expect_equal(vapply(blocks, `[[`, "", "section"), c("Section one", "Sub two", "Sub two", "Sub two"))
  expect_equal(blocks[[3]]$path, "data/raw.csv")
  expect_equal(blocks[[3]]$lang, "csv")
  expect_equal(blocks[[1]]$code, c("x <- 1 + 1", "stopifnot(x == 2)"))
  expect_equal(blocks[[1]]$line, 5L)
})

test_that("parse_guide refuses a marker that is not followed by a fence", {
  expect_error(parse_guide(c("<!-- example: skip -->", "prose", "```r", "1", "```")),
               "not followed by a fence")
  expect_error(parse_guide(c("<!-- example: skip -->")), "not followed by a fence")
  expect_error(parse_guide(c("<!-- example: skip -->", "<!-- example: skip -->", "```r", "1", "```")),
               "no fence between")
})

test_that("parse_guide refuses an unclosed fence", {
  expect_error(parse_guide(c("```r", "x <- 1")), "never closed")
})

test_that("write_project writes file blocks and a .here marker", {
  dir <- tempfile("proj-")
  write_project(parse_guide(fixture), dir)
  expect_true(file.exists(file.path(dir, ".here")))
  expect_equal(readLines(file.path(dir, "data", "raw.csv")), c("a,b", "1,2"))
})

test_that("run_block isolates blocks and reports errors, warnings, and output", {
  dir <- tempfile("proj-")
  blocks <- parse_guide(fixture)
  write_project(blocks, dir)
  ok <- run_block(blocks[[1]], dir)
  expect_equal(ok$status, "ok")
  reads_file <- run_block(blocks[[4]], dir)
  expect_equal(reads_file$status, "ok")
  leaks <- run_block(list(code = "stopifnot(x == 2)"), dir)
  expect_equal(leaks$status, "fail")
  expect_match(leaks$message, "'x' not found")
  warns <- run_block(list(code = c("warning('careful')", "print('after')")), dir)
  expect_equal(warns$status, "ok")
  expect_equal(warns$warnings, "careful")
  expect_equal(warns$output, "[1] \"after\"")
})

test_that("the gate catches the bug it was built for", {
  dir <- tempfile("proj-")
  write_project(list(), dir)
  bug <- list(code = c(
    "library(data.table)",
    "co <- coef(lm(dist ~ speed, cars))",
    "coefs <- as.data.table(co, keep.rownames = \"term\")",
    "stopifnot(identical(names(coefs), c(\"term\", \"V1\")))"
  ))
  expect_equal(run_block(bug, dir)$status, "fail")
})

test_that("generate_examples writes file blocks first, omits skips, and the result runs", {
  gen <- generate_examples(parse_guide(fixture))
  expect_match(gen[[1]], "^# Modern R Development Guide")
  expect_true(any(grepl("GENERATED", gen)))
  file_at <- grep("^# ── file: data/raw.csv", gen)
  first_run_at <- grep("^# ── Section one", gen)
  expect_length(file_at, 1L)
  expect_lt(file_at, first_run_at)
  expect_false(any(grepl("undefined_thing", gen)))
  expect_true(any(grepl("r\"---(a,b\n1,2)---\"", gen, fixed = TRUE)))

  old <- setwd(tempdir())
  on.exit(setwd(old), add = TRUE)
  env <- new.env(parent = globalenv())
  expect_no_error(eval(parse(text = gen), envir = env))
  expect_equal(env$x, 2)
  expect_equal(nrow(env$y), 1L)
})

with_fixture_root <- function(guide_lines, examples_lines = NULL) {
  root <- tempfile("root-")
  dir.create(root)
  writeLines(guide_lines, file.path(root, GUIDE))
  if (!is.null(examples_lines)) writeLines(examples_lines, file.path(root, EXAMPLES))
  root
}

test_that("main returns 0 when every block runs and the examples file is current", {
  root <- with_fixture_root(fixture, generate_examples(parse_guide(fixture)))
  out <- capture.output(n <- main(character(), root))
  expect_equal(n, 0L)
  expect_true(any(grepl("^SKIP  Sub two", out)))
  expect_true(any(grepl("^FILE  Sub two .* -> data/raw.csv", out)))
  expect_true(any(grepl("^OK    R-dev-examples.R matches", out)))
})

test_that("main counts a failing block and says which one", {
  broken <- c(fixture, "", "## Broken", "", "```r", "stop(\"boom\")", "```")
  root <- with_fixture_root(broken, generate_examples(parse_guide(broken)))
  out <- capture.output(n <- main(character(), root))
  expect_equal(n, 1L)
  expect_true(any(grepl("^FAIL  Broken \\(line", out)))
  expect_true(any(grepl("boom", out)))
})

test_that("main fails on drift and --write repairs it", {
  root <- with_fixture_root(fixture, "# stale")
  out <- capture.output(n <- main(character(), root))
  expect_equal(n, 1L)
  expect_true(any(grepl("does not match the guide", out)))
  capture.output(n <- main("--write", root))
  expect_equal(n, 0L)
  # A file block is one string with embedded newlines, so compare as text
  expect_equal(paste(readLines(file.path(root, EXAMPLES)), collapse = "\n"),
               paste(generate_examples(parse_guide(fixture)), collapse = "\n"))
  capture.output(n <- main(character(), root))
  expect_equal(n, 0L)
})

test_that("main names a missing package as a failure, not a skip", {
  missing <- c("## Missing", "", "```r", "library(notARealPackageXyz)", "```")
  root <- with_fixture_root(missing, generate_examples(parse_guide(missing)))
  out <- capture.output(n <- main(character(), root))
  expect_equal(n, 1L)
  expect_true(any(grepl("a missing package is a failure, not a skip", out)))
})

test_that("main rejects unknown arguments", {
  expect_error(main("--nope", tempdir()), "unknown argument")
})
