#!/usr/bin/env Rscript
# check-examples.R: every code block in R-dev-guide.md runs, and R-dev-examples.R is
# generated from the guide rather than maintained by hand.
#
#   Rscript check-examples.R          run every block; fail if any block fails, or if
#                                     R-dev-examples.R has drifted from the guide
#   Rscript check-examples.R --write  the same, then rewrite R-dev-examples.R
#
# A marker is an HTML comment on the line before a fence:
#
#   <!-- example: skip -->            illustrative; parsed, listed, not run, not emitted
#   <!-- example: file=R/foo.R -->    written into the example project at that path,
#                                     before any block runs (any fence language)
#
# Every other ```r block runs in a fresh environment whose parent is the global
# environment, with the working directory set to the example project. A block that
# depends on an earlier block fails, and that is the point. A missing package is a
# failure, not a skip. Warnings are reported beside the block that raised them.
#
# The functions are plain so tests/test-check-examples.R can source this file; main()
# runs only when the file is executed with Rscript.

GUIDE    <- "R-dev-guide.md"
EXAMPLES <- "R-dev-examples.R"

MARKER_RE <- "^<!-- example: (skip|file=(\\S+)) -->$"
FENCE_RE  <- "^```(\\w*)$"

parse_guide <- function(lines) {
  blocks  <- list()
  heading <- ""
  marker  <- NULL
  i <- 1L
  while (i <= length(lines)) {
    line <- lines[[i]]
    if (grepl("^#{2,3} ", line)) heading <- sub("^#{2,3} ", "", line)
    m <- regmatches(line, regexec(MARKER_RE, line))[[1]]
    if (length(m)) {
      if (!is.null(marker)) {
        stop(sprintf("line %d: a marker follows the marker at line %d with no fence between",
                     i, marker$line))
      }
      marker <- list(line = i,
                     mode = if (identical(m[[2]], "skip")) "skip" else "file",
                     path = if (identical(m[[2]], "skip")) NA_character_ else m[[3]])
      i <- i + 1L
      next
    }
    fence <- regmatches(line, regexec(FENCE_RE, line))[[1]]
    if (length(fence)) {
      lang  <- fence[[2]]
      start <- i
      i <- i + 1L
      code <- character()
      while (i <= length(lines) && !grepl("^```", lines[[i]])) {
        code <- c(code, lines[[i]])
        i <- i + 1L
      }
      if (i > length(lines)) stop(sprintf("line %d: fence is never closed", start))
      if (!is.null(marker)) {
        blocks[[length(blocks) + 1L]] <- list(section = heading, line = start, lang = lang,
                                              mode = marker$mode, path = marker$path,
                                              code = code)
        marker <- NULL
      } else if (identical(lang, "r")) {
        blocks[[length(blocks) + 1L]] <- list(section = heading, line = start, lang = lang,
                                              mode = "run", path = NA_character_,
                                              code = code)
      }
      i <- i + 1L
      next
    }
    if (!is.null(marker) && nzchar(trimws(line))) {
      stop(sprintf("line %d: the marker at line %d is not followed by a fence",
                   i, marker$line))
    }
    i <- i + 1L
  }
  if (!is.null(marker)) stop(sprintf("the marker at line %d is not followed by a fence",
                                     marker$line))
  blocks
}

write_project <- function(blocks, dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  file.create(file.path(dir, ".here"))
  for (b in blocks) {
    if (!identical(b$mode, "file")) next
    p <- file.path(dir, b$path)
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    writeLines(b$code, p)
  }
  invisible(dir)
}

run_block <- function(block, dir) {
  env <- new.env(parent = globalenv())
  old <- setwd(dir)
  on.exit(setwd(old), add = TRUE)
  warnings <- character()
  output   <- character()
  result <- withCallingHandlers(
    tryCatch({
      output <- capture.output(eval(parse(text = block$code), envir = env))
      list(status = "ok", message = "")
    }, error = function(e) list(status = "fail", message = conditionMessage(e))),
    warning = function(w) {
      warnings <<- c(warnings, conditionMessage(w))
      invokeRestart("muffleWarning")
    },
    message = function(m) invokeRestart("muffleMessage")
  )
  c(result, list(warnings = warnings, output = output))
}

rule_line <- function(title) {
  pad <- max(0L, 76L - nchar(title))
  sprintf("# ── %s %s", title, strrep("─", pad))
}

raw_string <- function(code) {
  text <- paste(code, collapse = "\n")
  if (grepl(")---\"", text, fixed = TRUE)) {
    stop("a file block contains the raw-string closer )---\", which cannot be embedded")
  }
  paste0("r\"---(", text, ")---\"")
}

generate_examples <- function(blocks) {
  files <- Filter(function(b) identical(b$mode, "file"), blocks)
  runs  <- Filter(function(b) identical(b$mode, "run"),  blocks)
  header <- c(
    "# Modern R Development Guide: runnable examples",
    "#",
    "# GENERATED from R-dev-guide.md by check-examples.R. Do not edit this file; edit the",
    "# guide and run:  Rscript check-examples.R --write",
    "#",
    "# Runs top to bottom. The first section creates a temporary project directory and",
    "# writes the guide's project files into it; every later section runs from there.",
    "",
    rule_line("Example project"),
    "example_dir <- file.path(tempdir(), \"modern-r-dev-examples\")",
    "dir.create(example_dir, recursive = TRUE, showWarnings = FALSE)",
    "setwd(example_dir)",
    "invisible(file.create(\".here\"))",
    ""
  )
  file_lines <- unlist(lapply(files, function(b) c(
    rule_line(sprintf("file: %s", b$path)),
    if (dirname(b$path) != ".") {
      sprintf("dir.create(%s, recursive = TRUE, showWarnings = FALSE)", deparse(dirname(b$path)))
    },
    sprintf("writeLines(%s, %s)", raw_string(b$code), deparse(b$path)),
    ""
  )))
  run_lines <- unlist(lapply(runs, function(b) c(rule_line(b$section), b$code, "")))
  c(header, file_lines, run_lines)
}

script_root <- function() {
  file_arg <- grep("^--file=", commandArgs(), value = TRUE)
  if (length(file_arg)) return(dirname(normalizePath(sub("^--file=", "", file_arg[[1]]))))
  getwd()
}

main <- function(args = commandArgs(trailingOnly = TRUE), root = script_root()) {
  write   <- "--write" %in% args
  unknown <- setdiff(args, "--write")
  if (length(unknown)) stop("unknown argument(s): ", paste(unknown, collapse = " "))

  guide_path    <- file.path(root, GUIDE)
  examples_path <- file.path(root, EXAMPLES)
  if (!file.exists(guide_path)) stop("guide not found at ", guide_path)

  blocks <- parse_guide(readLines(guide_path))
  dir    <- tempfile("modern-r-dev-examples-")
  write_project(blocks, dir)

  pdf(NULL)
  on.exit(dev.off(), add = TRUE)

  n_run <- 0L
  failures <- 0L
  for (b in blocks) {
    label <- sprintf("%s (line %d)", b$section, b$line)
    if (identical(b$mode, "skip")) {
      cat(sprintf("SKIP  %s: illustrative, not run\n", label))
      next
    }
    if (identical(b$mode, "file")) {
      cat(sprintf("FILE  %s -> %s\n", label, b$path))
      next
    }
    n_run <- n_run + 1L
    r <- run_block(b, dir)
    if (identical(r$status, "ok")) {
      note <- if (length(r$warnings)) {
        sprintf("  [%d warning(s); first: %s]", length(r$warnings), r$warnings[[1]])
      } else ""
      cat(sprintf("OK    %s%s\n", label, note))
    } else {
      failures <- failures + 1L
      cat(sprintf("FAIL  %s\n      %s\n", label, r$message))
      if (grepl("no package called", r$message)) {
        cat("      install it; a missing package is a failure, not a skip\n")
      }
    }
  }

  # File blocks are single strings with embedded newlines, so compare text, not lines
  generated <- generate_examples(blocks)
  current   <- if (file.exists(examples_path)) paste(readLines(examples_path), collapse = "\n")
  if (write) {
    writeLines(generated, examples_path)
    cat(sprintf("WROTE %s\n", EXAMPLES))
  } else if (!identical(current, paste(generated, collapse = "\n"))) {
    failures <- failures + 1L
    cat(sprintf("FAIL  %s does not match the guide; run: Rscript check-examples.R --write\n",
                EXAMPLES))
  } else {
    cat(sprintf("OK    %s matches the guide\n", EXAMPLES))
  }

  cat(sprintf("\n%d block(s) run, %d failure(s)\n", n_run, failures))
  invisible(failures)
}

if (sys.nframe() == 0L) {
  quit(status = if (main() > 0L) 1L else 0L, save = "no")
}
