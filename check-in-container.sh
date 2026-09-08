#!/usr/bin/env bash
# Run the guide's checker and its tests inside the verse-cmdstan container.
#
#   ./check-in-container.sh            # check only
#   ./check-in-container.sh --write    # check, and rewrite R-dev-examples.R
#
# Builds modern-r-dev-check from Dockerfile.check (a thin layer over
# jflournoy/verse-cmdstan) if it is missing or the Dockerfile changed, mounts this
# directory at /work, and runs the same two commands CI runs. The container has CmdStan,
# so the Bayesian block runs here even on a host without it.
set -euo pipefail
cd "$(dirname "$0")"

docker build -q -f Dockerfile.check -t modern-r-dev-check . > /dev/null
docker run --rm -v "$PWD:/work" -w /work -u "$(id -u):$(id -g)" -e HOME=/tmp \
  modern-r-dev-check bash -c 'Rscript check-examples.R "$@" && Rscript -e "testthat::test_dir(\"tests\", stop_on_failure = TRUE)"' _ "$@"
