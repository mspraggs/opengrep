(* Romain Calascibetta
 *
 * Copyright (C) 2023-2024 Semgrep Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* A really basic profiler.
 *
 * TODO: diff with libs/profiling/? Worth yet another profiling lib?
 * or was it written to match what was done in pysemgrep?
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type t = (string, value) Hashtbl.t
and value = Start of float | Recorded of float

(*****************************************************************************)
(* API *)
(*****************************************************************************)

let make () = Hashtbl.create 0x100

let start profiler ~name =
  match Hashtbl.find_opt profiler name with
  | Some (Start start_time) ->
      let now = Unix.gettimeofday () in
      Hashtbl.replace profiler name (Recorded (now -. start_time))
  | Some (Recorded _) -> Fmt.invalid_arg "%s was already profiled" name
  | None ->
      let now = Unix.gettimeofday () in
      Hashtbl.add profiler name (Start now)

let stop profiler ~name =
  match Hashtbl.find_opt profiler name with
  | Some (Start _) -> start profiler ~name
  | Some (Recorded _) ->
      Fmt.invalid_arg "Profiler.stop: %s already recorded" name
  | None -> Fmt.invalid_arg "Profiler.stop: %s does not exist" name

let stop_ign profiler ~name =
  try stop profiler ~name with
  | _ -> ()

let record profiler ~name fn =
  let t0 = Unix.gettimeofday () in
  let finally () =
    let t1 = Unix.gettimeofday () in
    Hashtbl.add profiler name (Recorded (t1 -. t0))
  in
  Common.protect ~finally fn

(* A metric that is still running is reported with the time elapsed so far,
 * which is what lets "total_time" be reported: it is stopped only after the
 * output has been produced (see Scan_subcommand.ml). pysemgrep gets the same
 * number a different way, by saving "total_time" just before building the
 * output.
 *
 * coupling: this must not stop the running metrics instead. Output.ml reads
 * the raw start timestamp of "total_time" for the start_time of the GitLab
 * formats, which only a Start entry carries.
 *
 * A name recorded several times ('record' uses Hashtbl.add) is resolved the
 * way Hashtbl.find does, the last recording winning, as with the dict of
 * pysemgrep's ProfileManager. Sorting by name keeps the JSON output
 * deterministic; it also happens to give the order in which pysemgrep
 * inserts the metrics it has in common with us.
 *)
let snapshot profiler =
  let now = Unix.gettimeofday () in
  Hashtbl.fold (fun name _value acc -> name :: acc) profiler []
  |> List.sort_uniq String.compare
  |> List_.map (fun name ->
         match Hashtbl.find profiler name with
         | Recorded time -> (name, time)
         | Start start_time -> (name, now -. start_time))
