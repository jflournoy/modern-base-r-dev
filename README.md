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
- [`R-dev-examples.R`](R-dev-examples.R) — runnable examples
- [`CLAUDE_r-devel.md`](CLAUDE_r-devel.md) — directive instructions for Claude Code (modular, can be copied to other projects)

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
