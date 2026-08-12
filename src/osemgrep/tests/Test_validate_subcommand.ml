(* SPDX-License-Identifier: LGPL-2.1-only *)

let t = Testo.create

module F = Testutil_files

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* End-to-end tests for the validate subcommand, mostly about its --json
 * output.
 *
 * 'validate' runs the metarules of the 'p/semgrep-rule-lints' pack over the
 * rule files, which it fetches from the registry, so most tests here serve
 * that pack from a mock HTTP client rather than reaching the network. The
 * exception is the test of an unparseable configuration: no rule file can be
 * metachecked then, so no fetch happens and the test needs no mock at all.
 *)

(*****************************************************************************)
(* Fixtures *)
(*****************************************************************************)

(* the one request validate makes, see Semgrep_Registry.ml *)
let metarules_url_path = "/c/p/semgrep-rule-lints"

(* Stands in for the 'p/semgrep-rule-lints' pack. Flags any rule file that
 * mentions TODO-METACHECK, which is enough to exercise the reporting of a
 * metacheck finding without depending on what the real pack contains. *)
let metarules_yaml =
  {|rules:
  - id: opengrep.test.metacheck
    languages: [generic]
    severity: ERROR
    message: this rule was flagged by the metachecks
    pattern-regex: TODO-METACHECK
|}

let valid_rule =
  {|rules:
  - id: eqeq-bad
    pattern: $X == $X
    message: useless comparison
    languages: [python]
    severity: ERROR
|}

(* no 'message:', which Parse_rule rejects *)
let invalid_rule =
  {|rules:
  - id: eqeq-bad
    pattern: $X == $X
    languages: [python]
    severity: ERROR
|}

(* valid, but says the word the metarule above looks for *)
let rule_flagged_by_metacheck =
  {|rules:
  - id: eqeq-todo
    pattern: $X == $X
    message: TODO-METACHECK this message needs work
    languages: [python]
    severity: ERROR
|}

(* not YAML at all: the file cannot be parsed, so we get a fatal error and
 * there is nothing to metacheck *)
let unparseable_rule = {|rules: [|}

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* coupling: the masks of Test_scan_helpers.normalise. The version opening the
 * JSON document drifts every release, and the rule files live in a temporary
 * directory. *)
let normalise =
  [
    Testutil.mask_temp_paths ();
    Testo.mask_pcre_pattern {|\{"version":"([^"]*)","results"|};
  ]

let without_settings f =
  Semgrep_envvars.with_envvar "SEMGREP_SETTINGS_FILE" "nosettings.yaml" f

(* Serve the metarules pack instead of asking the registry for it. *)
let with_registry_mock (f : unit -> 'a) : 'a =
  let make_response (req : Cohttp.Request.t) (_body : Cohttp_lwt.Body.t) =
    let path = Uri.path (Cohttp.Request.uri req) in
    if String.equal path metarules_url_path then (
      Http_mock_client.check_method `GET (Cohttp.Request.meth req);
      Lwt.return
        (Http_mock_client.basic_response
           (Cohttp_lwt.Body.of_string metarules_yaml)))
    else Alcotest.failf "unexpected request to %s" path
  in
  Http_mock_client.with_testing_client make_response f ()

(* Run 'opengrep validate' over a rule file in a throw-away directory and
 * print the exit code, so that both the output and the code are part of the
 * snapshot. *)
let run_validate (caps : CLI.caps) ~(rule_files : (string * string) list)
    ~(args : string list) () =
  Testutil_files.with_tempdir ~chdir:true (fun tmp ->
      F.write tmp
        (rule_files
        |> List_.map (fun ((name : string), (content : string)) ->
               F.File (name, content)));
      let argv = Array.of_list ([ "opengrep"; "validate" ] @ args) in
      let exit_code = without_settings (fun () -> CLI.main caps argv) in
      UCommon.pr
        (Printf.sprintf "exit code: %d" (Exit_code.to_int exit_code)))

(*****************************************************************************)
(* Tests *)
(*****************************************************************************)

(* A valid configuration produces no document at all, as in pysemgrep: there
 * is nothing to report, and the caller learns that from the exit code. *)
let test_valid_json (caps : CLI.caps) () =
  with_registry_mock (fun () ->
      run_validate caps
        ~rule_files:[ ("rules.yaml", valid_rule) ]
        ~args:[ "--json"; "rules.yaml" ]
        ())

(* Without --json nothing is written on stdout either: the report is made of
 * Logs, which go to stderr. *)
let test_valid_no_json (caps : CLI.caps) () =
  with_registry_mock (fun () ->
      run_validate caps
        ~rule_files:[ ("rules.yaml", valid_rule) ]
        ~args:[ "rules.yaml" ]
        ())

(* A rule that does not parse is reported in 'errors', with empty 'results'
 * and 'paths.scanned'. *)
let test_invalid_rule_json (caps : CLI.caps) () =
  with_registry_mock (fun () ->
      run_validate caps
        ~rule_files:[ ("rules.yaml", invalid_rule) ]
        ~args:[ "--json"; "rules.yaml" ]
        ())

(* A finding of the metarules is reported as an error too, with the id of the
 * metarule and the path of the rule file it was found in. *)
let test_metacheck_finding_json (caps : CLI.caps) () =
  with_registry_mock (fun () ->
      run_validate caps
        ~rule_files:[ ("rules.yaml", rule_flagged_by_metacheck) ]
        ~args:[ "--json"; "rules.yaml" ]
        ())

(* With both kinds of error, the errors of the configuration come before the
 * metacheck ones, as in pysemgrep. *)
let test_error_order_json (caps : CLI.caps) () =
  with_registry_mock (fun () ->
      run_validate caps
        ~rule_files:
          [
            ("a_invalid.yaml", invalid_rule);
            ("b_metacheck.yaml", rule_flagged_by_metacheck);
          ]
        ~args:[ "--json"; "a_invalid.yaml"; "b_metacheck.yaml" ]
        ())

(* No mock here: a configuration that cannot be parsed leaves no rule file to
 * metacheck, so validate does not reach for the registry. *)
let test_unparseable_config_json_offline (caps : CLI.caps) () =
  run_validate caps
    ~rule_files:[ ("rules.yaml", unparseable_rule) ]
    ~args:[ "--json"; "rules.yaml" ]
    ()

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let tests (caps : CLI.caps) =
  Testo.categorize "Osemgrep Validate (e2e)"
    [
      t "valid config with --json prints no document"
        ~checked_output:(Testo.stdout ()) ~normalize:normalise
        (test_valid_json caps);
      t "valid config without --json prints nothing on stdout"
        ~checked_output:(Testo.stdout ()) ~normalize:normalise
        (test_valid_no_json caps);
      t "invalid rule with --json" ~checked_output:(Testo.stdout ())
        ~normalize:normalise
        (test_invalid_rule_json caps);
      t "metacheck finding with --json" ~checked_output:(Testo.stdout ())
        ~normalize:normalise
        (test_metacheck_finding_json caps);
      t "config errors are reported before metacheck ones"
        ~checked_output:(Testo.stdout ()) ~normalize:normalise
        (test_error_order_json caps);
      t "unparseable config with --json, without the registry"
        ~checked_output:(Testo.stdout ()) ~normalize:normalise
        (test_unparseable_config_json_offline caps);
    ]
