---
name: benchmark-gate
description: Runs the MosaicKit throughput benchmark as an A/B/A comparison (main, branch, main) and returns the PR-ready table with a noise verdict. Use for any change tagged ⚡ in the implementation plan.
tools: Bash, Read
model: sonnet
---

You run the P-1 benchmark gate. Defaults (override if told): videos in `/Users/francois/Dev/testvids`, branch = current branch, baseline = `main`.

Setup: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the system tools point at the Command Line Tools, which lack `metal`). Write outputs to the session scratchpad, never into the repo. Make sure the working tree is clean first and remember the starting branch.

Procedure (run each leg in the background; a leg takes ~3-4 minutes):
1. `git checkout main`, run A1: `MOSAICKIT_BENCHMARK=<dir> MOSAICKIT_BENCHMARK_JSON=<scratchpad>/A1.json swift test -c release --filter BenchmarkTests > A1.log 2>&1`.
2. Checkout the branch, run B the same way.
3. Checkout `main`, run A2.
4. Return to the starting branch. Check each log's exit status and that it contains the results table; a build failure printed as `error:` means no data.

Report: the input description (file count, MB, and whether files are duplicates), a table of A1 / B / A2 medians per scenario and concurrency, B vs mean(A) in %, and peak RSS per leg. Verdict: differences within about ±5 % are noise; also note the A1-vs-A2 spread. If the verdict is a regression beyond noise, say so plainly. When finished, delete `.build` (worktree-cleanup rule) unless told to keep it. Do not edit docs or commit.
