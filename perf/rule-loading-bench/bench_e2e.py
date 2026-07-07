#!/usr/bin/env python3
"""End-to-end wall-clock decomposition of `opengrep scan` rule loading.

Measures three things and reports the deltas:
  1. CLI startup baseline:      opengrep scan --help
  2. Startup + rule loading:    opengrep scan --config RULES <empty dir>
  3. Full scan (optional):      opengrep scan --config RULES --target DIR

(2) - (1) approximates the cost of loading + validating your ruleset,
including the opengrep-core RPC validation subprocess.
(3) - (2) approximates the actual matching work.

Usage:
    python bench_e2e.py RULES_PATH [--target DIR] [--opengrep CMD] [--repeat N]
"""
import argparse
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run_timed(cmd, repeat):
    times = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        proc = subprocess.run(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        times.append(time.perf_counter() - t0)
        if proc.returncode not in (0, 1):  # 1 = findings, still a valid run
            print(
                f"WARNING: {' '.join(map(str, cmd))} exited "
                f"with code {proc.returncode}",
                file=sys.stderr,
            )
    return statistics.median(times)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("rules", type=Path, help="rules file (JSON or YAML)")
    ap.add_argument("--target", type=Path, help="real target dir for a full scan")
    ap.add_argument(
        "--opengrep",
        default="opengrep",
        help='opengrep command (e.g. "pipx run opengrep" or a dev binary path)',
    )
    ap.add_argument("--repeat", type=int, default=3)
    args = ap.parse_args()

    base_cmd = shlex.split(args.opengrep)
    if shutil.which(base_cmd[0]) is None and not Path(base_cmd[0]).exists():
        sys.exit(f"opengrep command not found: {base_cmd[0]!r} "
                 f"(use --opengrep to point at it)")

    common = ["scan", "--quiet"]

    print(f"Command: {args.opengrep}  |  median of {args.repeat} runs\n")

    t_help = run_timed(base_cmd + ["scan", "--help"], args.repeat)
    print(f"  CLI startup (scan --help):        {t_help:8.2f} s")

    with tempfile.TemporaryDirectory(prefix="opengrep-bench-empty-") as empty:
        t_empty = run_timed(
            base_cmd + common + ["--config", str(args.rules), empty],
            args.repeat,
        )
    print(f"  startup + rule load (empty dir):  {t_empty:8.2f} s")
    print(f"    -> rule loading + validation:   {t_empty - t_help:8.2f} s")

    if args.target:
        t_full = run_timed(
            base_cmd + common + ["--config", str(args.rules), str(args.target)],
            args.repeat,
        )
        print(f"  full scan of {args.target}:  {t_full:8.2f} s")
        print(f"    -> matching work:               {t_full - t_empty:8.2f} s")


if __name__ == "__main__":
    main()
