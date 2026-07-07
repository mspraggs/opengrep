#!/usr/bin/env python3
"""Stage-by-stage benchmark of the opengrep CLI rule-loading pipeline.

Times each stage of the real code path a scan pays when loading rules:
deserialize -> YamlTree wrap -> validation (RPC and jsonschema variants)
-> Rule construction -> re-serialization for opengrep-core.

Usage:
    python bench_stages.py RULES_PATH [--repeat N]

RULES_PATH may be a JSON or YAML rules file; the format is auto-detected the
same way the CLI does (JSON is tried first).
"""
import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path
from tempfile import mkstemp

try:
    from semgrep.config_resolver import Config
    from semgrep.config_resolver import parse_config_string
    from semgrep.rule_lang import EmptySpan
    from semgrep.rule_lang import parse_yaml_preserve_spans
    from semgrep.rule_lang import validate_yaml
    from semgrep.rule_lang import YamlTree
except ImportError as e:
    sys.exit(
        f"Could not import the semgrep package ({e}).\n"
        "Run this script with the Python environment that has the opengrep\n"
        "CLI installed, e.g.:\n"
        "  /path/to/opengrep-venv/bin/python bench_stages.py rules.json\n"
        "or install the CLI into a venv first (needs the generated\n"
        "semgrep_interfaces): pip install -e cli/"
    )


def timed(fn, repeat):
    """Return (median_seconds, last_result). Never lets one failure abort."""
    times = []
    result = None
    for _ in range(repeat):
        t0 = time.perf_counter()
        result = fn()
        times.append(time.perf_counter() - t0)
    return statistics.median(times), result


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("rules", type=Path, help="rules file (JSON or YAML)")
    ap.add_argument("--repeat", type=int, default=5, help="repeats per stage")
    args = ap.parse_args()

    contents = args.rules.read_text()
    size_mb = len(contents) / 1e6

    is_json = True
    try:
        parsed = json.loads(contents)
    except json.JSONDecodeError:
        is_json = False

    results = {}  # label -> seconds

    # Stage 1+2: deserialize and wrap into YamlTree
    if is_json:
        results["json.loads"], parsed = timed(
            lambda: json.loads(contents), args.repeat
        )
        results["YamlTree.wrap (JSON path)"], tree = timed(
            lambda: YamlTree.wrap(json.loads(contents), EmptySpan), args.repeat
        )
        n_rules = len(parsed.get("rules", []))
    else:
        results["ruamel parse + span wrap (YAML path)"], tree = timed(
            lambda: parse_yaml_preserve_spans(contents, str(args.rules)),
            args.repeat,
        )
        n_rules = len(tree.value["rules"].value) if "rules" in tree.value else 0

    def fresh_tree():
        if is_json:
            return YamlTree.wrap(json.loads(contents), EmptySpan)
        return parse_yaml_preserve_spans(contents, str(args.rules))

    # Stage 3a: validation via RPC (spawns opengrep-core -rpc), as a scan does.
    # validate_yaml mutates the tree (version filtering), so re-wrap per repeat
    # outside the timed region is not possible with `timed`; instead each timed
    # call includes only validate_yaml on a tree built just before.
    core_available = True
    try:
        from semgrep.semgrep_core import SemgrepCore

        SemgrepCore.executable_path()
    except Exception:
        core_available = False

    fd, tmp_path = mkstemp(suffix=".rules", prefix="bench-")
    with os.fdopen(fd, "w") as fp:
        fp.write(contents)
    try:
        if core_available:
            def rpc_validate_stage():
                t = fresh_tree()
                t0 = time.perf_counter()
                validate_yaml(t, str(args.rules), rules_tmp_path=tmp_path)
                return time.perf_counter() - t0

            results["validate_yaml (RPC, spawns core)"] = statistics.median(
                rpc_validate_stage() for _ in range(args.repeat)
            )
        else:
            print(
                "NOTE: opengrep-core binary not found; skipping the RPC "
                "validation stage (a real scan pays this).",
                file=sys.stderr,
            )

        def jsonschema_stage():
            t = fresh_tree()
            t0 = time.perf_counter()
            try:
                validate_yaml(t, str(args.rules), force_jsonschema=True)
            except Exception as e:
                print(f"jsonschema validation raised: {e!r}", file=sys.stderr)
            return time.perf_counter() - t0

        results["validate_yaml (jsonschema only)"] = statistics.median(
            jsonschema_stage() for _ in range(args.repeat)
        )

        # Stage 4: Rule construction (per-rule unroll_dict) via Config._validate
        def rules_stage():
            t = fresh_tree()
            t0 = time.perf_counter()
            valid, _errs, _missed = Config._validate({"bench": t})
            rules = Config(valid).get_rules(no_rewrite_rule_ids=True)
            return time.perf_counter() - t0, rules

        samples = [rules_stage() for _ in range(args.repeat)]
        results["Config._validate + Rule construction"] = statistics.median(
            s[0] for s in samples
        )
        rules = samples[-1][1]

        # Stage 5: re-serialization for opengrep-core (core_runner.py)
        results["json.dumps for core (indent=2, sort_keys)"], _ = timed(
            lambda: json.dumps(
                {"rules": [r._raw for r in rules]}, indent=2, sort_keys=True
            ),
            args.repeat,
        )
        results["json.dumps for core (no indent)"], _ = timed(
            lambda: json.dumps({"rules": [r._raw for r in rules]}, sort_keys=True),
            args.repeat,
        )

        # Stage 6: the whole thing as a scan pays it (includes temp-file write,
        # parse, and validation — RPC if core is available)
        def full():
            return parse_config_string(
                "bench",
                contents,
                str(args.rules),
                force_jsonschema=not core_available,
            )

        label = "parse_config_string (end-to-end{})".format(
            "" if core_available else ", jsonschema fallback"
        )
        results[label], _ = timed(full, args.repeat)
    finally:
        os.unlink(tmp_path)

    fmt = "json" if is_json else "yaml"
    print(f"\n{args.rules} — {n_rules} rules, {size_mb:.2f} MB ({fmt}), "
          f"median of {args.repeat} runs\n")
    width = max(len(k) for k in results)
    for label, secs in results.items():
        print(f"  {label:<{width}}  {secs * 1000:9.1f} ms")

    dominant = max(results, key=results.get)
    print(f"\nDominant stage: {dominant} "
          f"({results[dominant] * 1000:.0f} ms)")


if __name__ == "__main__":
    main()
