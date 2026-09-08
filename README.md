# Modern R Development Guide (data.table Edition)

This guide is directly adapted from **Sarah Johnson's** Modern R Development Guide:
[gist.github.com/sj-io/3828d64d0969f2a0f05297e59e6c15ad](https://gist.github.com/sj-io/3828d64d0969f2a0f05297e59e6c15ad)

Sarah is a housing analyst at Princeton University's Eviction Lab and an R programmer.
Her guide established the structure, format, and scope that this one builds on.
The philosophical differences---favouring data.table, base R, and minimal dependencies
over tidyverse---are mine. I also separated the human-readable guide from the much 
more terse and directive CLAUDE.md. All errors are mine.

- GitHub: [sj-io](https://github.com/sj-io)
- Web: [sarahjohnson.io](https://sarahjohnson.io)

---

## Files in this repo

- [`R-dev-guide.md`](R-dev-guide.md) — the full human-readable guide
- [`R-dev-examples.R`](R-dev-examples.R) — runnable examples, generated from the guide; do not edit by hand
- [`CLAUDE_r-devel.md`](CLAUDE_r-devel.md) — directive instructions for Claude Code (modular, can be copied to other projects)
- [`check-examples.R`](check-examples.R) — runs every code block in the guide and regenerates the examples file
- [`tests/`](tests/) — the checker's own tests

## Checking the guide

Every fenced R block in the guide is run, in a fresh environment, by `check-examples.R`,
and `R-dev-examples.R` is generated from the guide rather than kept in sync by hand. A
guide that says something its own examples cannot do fails the check.

```bash
Rscript check-examples.R            # run every block; fail on any error or on drift
Rscript check-examples.R --write    # the same, then rewrite R-dev-examples.R
Rscript -e 'testthat::test_dir("tests")'
```

Two HTML comments control what a block does. Put either on the line before the fence.
A block with no marker is run.

```markdown
<!-- example: skip -->             illustrative; parsed and listed, never run
<!-- example: file=R/analysis.R --> written into the example project at that path
```

File blocks are written before anything runs, so the testing and pipeline sections are a
real project (`R/`, `tests/`, `_targets.R`, `data/raw.csv`) that `test_dir()` and
`tar_make()` are called on. Assertions inside the blocks (`stopifnot()`) say what the
result must look like, so a block that runs but returns the wrong shape also fails. The
same check runs in GitHub Actions on every push.

Nothing in the guide is only sketched. The Bayesian block fits a model through cmdstanr,
so the check needs CmdStan: on the host, `cmdstanr::install_cmdstan()`; in CI, a cached
install. The other route is the container the Bayesian work runs in anyway:

```bash
./check-in-container.sh            # verse-cmdstan plus targets, crew, and Quarto tooling
./check-in-container.sh --write
```

`Dockerfile.check` is a thin layer over `jflournoy/verse-cmdstan` that adds the packages
the checker needs and nothing else; the script builds it once and reuses it.

## Using the directives in your own project

### Standalone (rename to CLAUDE.md)

If you want Claude Code to automatically pick up these directives, copy and rename:

```bash
cp CLAUDE_r-devel.md ../your-project/CLAUDE.md
```

### Modular (router pattern)

Keep directives as separate files and create a `CLAUDE.md` that routes to them based on context. This lets you grow multiple guides without duplication:

```markdown
# Project Directives

## When to Consult Each Guide

### 🔴 Load for R Development Work

- [CLAUDE_r-devel.md](CLAUDE_r-devel.md) — When working with R code
  - Data.table-first philosophy
  - Approved packages and style standards
  - Testing, pipelines, and data I/O patterns
```

Claude Code will load `CLAUDE.md` and see the reference, and humans can click through to the specific guide they need.
