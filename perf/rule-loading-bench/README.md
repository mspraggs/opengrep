# Rule-loading benchmarks

Scripts to measure where `opengrep scan` spends time loading, parsing, and
validating a ruleset. Run them against your own rules file to get concrete
numbers before deciding which optimization to pursue.

All scripts need the Python environment that has the opengrep CLI installed
(so they exercise the real code, not a reimplementation).

## 1. Stage-by-stage pipeline breakdown

```
/path/to/env/bin/python bench_stages.py /path/to/rules.json [--repeat 5]
```

Times each stage of the Python rule-loading pipeline separately: deserialize,
`YamlTree.wrap`, validation (both the RPC path that spawns `opengrep-core`
and the pure-Python jsonschema path), `Rule` construction, and the
re-serialization sent to the core binary. Works with JSON or YAML rules.
If `opengrep-core` is not installed, the RPC stage is skipped with a note.

## 2. End-to-end scan decomposition

```
python bench_e2e.py /path/to/rules.json [--target /some/repo] [--opengrep opengrep]
```

Wall-clock timing of real `opengrep scan` invocations: `--help` (startup
baseline), a scan of an empty directory (startup + rule loading +
validation), and optionally a full scan of `--target`. Reports the deltas so
you can see how much of a real scan is rule loading vs. matching.

## 3. cProfile drill-down

```
./bench_profile.sh /path/to/rules.json /path/to/env/bin/python
```

Profiles a scan of an empty directory with cProfile and prints the top
functions in the rule-loading modules. Profiles `pyopengrep` (the Python
CLI) — the `opengrep` wrapper may dispatch to the OCaml binary, which
cProfile cannot see into. Writes `rule_load.prof`; view interactively with
`snakeviz rule_load.prof`.
