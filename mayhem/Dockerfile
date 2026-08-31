# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for lunasvg — builds on top of the org C/C++ base image
# (ghcr.io/savantenvs/base), which already provides debian + clang/llvm + libFuzzer/afl++ + the
# identities + the build-contract ENV.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t lunasvg-commit .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV.
ARG SOURCE_DATE_EPOCH

# Sanitizer override (undefaulted ARG so the base's ENV flows through when not passed):
# --build-arg SANITIZER_FLAGS="...".
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# lunasvg is a self-contained CMake project (cmake/ninja/clang all present in the base; its only
# dependency, plutovg, is vendored in-tree under plutovg/ — no extra apt packages needed).

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
