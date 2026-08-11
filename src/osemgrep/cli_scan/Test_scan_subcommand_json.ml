(* SPDX-License-Identifier: LGPL-2.1-only *)

let t = Testo.create

open Test_scan_helpers

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* End-to-end tests for the JSON output of the scan subcommand.
 *
 * The snapshots lock in the fields whose presence pysemgrep's JSON output
 * guarantees, such as 'rules_by_engine' and 'engine_requested' which are
 * passed through from the core scan (see Cli_json_output.ml).
 *)

(*****************************************************************************)
(* Individual tests                                                          *)
(*****************************************************************************)

(* --json with a finding: the output carries the engine fields
 * ('"engine_requested":"OSS"' and one 'rules_by_engine' entry per rule)
 * alongside the results. *)
let test_json_output (caps : Scan_subcommand.caps) () =
  run_scan caps ~format_args:[ "--json" ] ~rule:"rules/eqeq.yaml"
    ~targets:[ "targets/basic/stupid.py" ] ()

(* --json without findings: the engine fields do not depend on any match
 * being found. *)
let test_json_output_without_findings (caps : Scan_subcommand.caps) () =
  run_scan caps ~format_args:[ "--json" ]
    ~rule:"rules/regex/regex-nosemgrep.yaml"
    ~targets:[ "targets/basic/stupid.py" ] ()

(*****************************************************************************)
(* Entry point                                                               *)
(*****************************************************************************)

let tests (caps : < Scan_subcommand.caps >) =
  Testo.categorize "Osemgrep Scan JSON output (e2e)"
    [
      t "--json with a finding" ~checked_output:(Testo.stdout ())
        ~normalize:normalise (test_json_output caps);
      t "--json without findings" ~checked_output:(Testo.stdout ())
        ~normalize:normalise
        (test_json_output_without_findings caps);
    ]
