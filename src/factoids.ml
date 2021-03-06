open Prelude
open Containers
open Lwt.Infix

type key = string
type value =
  | StrList of string list
  | Int of int
type factoid = {key: key; value: value}
type t = factoid StrMap.t
type json = Yojson.Safe.json

type op =
  | Get of key
  | Set of factoid
  | Set_force of factoid
  | Append of factoid
  | Incr of key
  | Decr of key

let key_of_string s : key option =
  let s = String.trim s in
  if String.contains s ' ' then None
  else Some s

let string_of_value = function
  | Int i -> string_of_int i
  | StrList l -> Prelude.string_list_to_string l

let string_of_op = function
  | Get k -> "get " ^ k
  | Set {key;value} -> "set " ^ key ^ " := " ^ string_of_value value
  | Set_force {key;value} -> "set_force " ^ key ^ " := " ^ string_of_value value
  | Append {key;value} -> "append " ^ key ^ " += " ^ string_of_value value
  | Incr k -> "incr " ^ k
  | Decr k -> "decr " ^ k

let mk_key key =
  match key_of_string key with
  | None -> invalid_arg ("mk_key : `" ^ key ^ "`")
  | Some key -> key

let mk_factoid key value =
  let key = mk_key key in
  let value = String.trim value in
  try {key; value = Int (int_of_string value)}
  with Failure _ -> {key; value = StrList [value]}

let re_set = Str.regexp "^![ ]*\\([^!=+ -]+\\)[ ]*=\\(.*\\)$"
let re_set_force = Str.regexp "^![ ]*\\([^!=+ -]+\\)[ ]*:=\\(.*\\)$"
let re_append = Str.regexp "^![ ]*\\([^!=+ -]+\\)[ ]*\\+=\\(.*\\)$"
let re_get = Str.regexp "^![ ]*\\([^!=+ -]+\\)[ ]*$"
let re_incr = Str.regexp "^![ ]*\\([^!=+ -]+\\)[ ]*\\+\\+[ ]*$"
let re_decr = Str.regexp "^![ ]*\\([^!=+ -]+\\)[ ]*--[ ]*$"

let parse_op msg : op option =
  let open Option in
  let mk_get k = Get (mk_key k) in
  let mk_set k v = Set (mk_factoid k v) in
  let mk_set_force k v = Set_force (mk_factoid k v) in
  let mk_append k v = Append (mk_factoid k v) in
  let mk_incr k = Incr (mk_key k) in
  let mk_decr k = Decr (mk_key k) in
  (re_match2 mk_append re_append msg)
  <+>
  (re_match2 mk_set re_set msg)
  <+>
  (re_match2 mk_set_force re_set_force msg)
  <+>
  (re_match1 mk_get re_get msg)
  <+>
  (re_match1 mk_incr re_incr msg)
  <+>
  (re_match1 mk_decr re_decr msg)
  <+>
  None

(* read the json file *)
let read_json (file:string) : json option Lwt.t =
  Lwt.catch
    (fun () ->
       Lwt_io.with_file ~mode:Lwt_io.input file
         (fun ic ->
            Lwt_io.read ic >|= fun s ->
            try Yojson.Safe.from_string s |> some
            with _ -> None))
    (fun _ -> Lwt.return_none)

exception Could_not_parse

let as_str (j:json) : string = match j with
  | `String s -> s
  | _ -> raise Could_not_parse

let as_value (j: json) : value = match j with
  | `List l -> StrList (List.map as_str l)
  | `Int i -> Int i
  | _ -> raise Could_not_parse

let get key (fcs:t) : value =
  try (StrMap.find key fcs).value
  with Not_found -> StrList []

let mem key (fcs:t) : bool = StrMap.mem key fcs

let set ({key;_} as f) (fcs:t): t =
  StrMap.add key f fcs

let append {key;value} (fcs:t): t =
  let value' =
    match (StrMap.find key fcs).value, value with
    | Int i, Int j -> Int (i+j)
    | StrList l, StrList l' -> StrList (l @ l')
    | StrList l, Int j -> StrList (string_of_int j :: l)
    | Int i, StrList l -> StrList (string_of_int i :: l)
    | exception Not_found -> value
  in
  StrMap.add key {key; value = value'} fcs

let incr key (fcs:t): int option * t =
  let value = try (StrMap.find key fcs).value with Not_found -> Int 0 in
  match value with
  | Int i ->
    let count = i + 1 in
    (Some count, StrMap.add key {key; value = Int count} fcs)
  | _ -> (None, fcs)

let decr key (fcs:t): int option * t =
  let value = try (StrMap.find key fcs).value with Not_found -> Int 0 in
  match value with
  | Int i ->
    let count = i - 1 in
    (Some count, StrMap.add key {key; value = Int count} fcs)
  | _ -> (None, fcs)

let search tokens (fcs:t): value =
  (* does the pair [key, value] match the given token? *)
  let tok_matches key value tok =
    CCString.mem ~sub:tok key ||
    begin match value with
      | Int i -> key = string_of_int i
      | StrList l ->
        List.exists
          (fun s -> CCString.mem ~sub:tok s)
          l
    end
  in
  let matches =
    StrMap.fold
      (fun _ {key; value} choices ->
         if List.for_all (tok_matches key value) tokens
         then ("!"^key, value) :: choices
         else choices)
      fcs []
    |> (function
      | [] -> []
      | [k,v] -> [k ^ " -> " ^ string_of_value v] (* keep result *)
      | l -> List.map fst l
    )

  in
  StrList [Prelude.string_list_to_string matches]

let random (fcs:t): string =
  let l = StrMap.to_list fcs in
  match l with
    | [] -> ""
    | _ ->
      let _, fact = DistribM.uniform l |> DistribM.run in
      let msg_val = match fact.value with
        | StrList [] -> assert false
        | StrList l -> DistribM.uniform l |> DistribM.run
        | Int i -> string_of_int i
      in
      Printf.sprintf "!%s: %s" fact.key msg_val

(* parsing/outputting the factoids json *)
let factoids_of_json (json: json): t option =
  try
    begin match json with
      | `Assoc l ->
        List.fold_left
          (fun acc (k, v) ->
             let v = as_value v in
             let key = match key_of_string k with
               | Some k -> k
               | None -> raise Could_not_parse
             in
             append {key;value=v} acc
          )
          StrMap.empty l
      | _ -> raise Could_not_parse
    end
    |> some
  with Could_not_parse -> None

let json_of_factoids (factoids: t): json =
  let l =
    StrMap.fold
      (fun _ {key; value} acc ->
         let jvalue = match value with
           | StrList l -> `List (List.map (fun s -> `String s) l)
           | Int i -> `Int i in
         (key, jvalue) :: acc)
      factoids
      []
  in
  `Assoc l

let dump_factoids (factoids: t): string =
  json_of_factoids factoids |> Yojson.Safe.to_string

(* operations *)

let empty = StrMap.empty

let read_file ~(file:string) : t Lwt.t =
  read_json file >|= function
  | None -> StrMap.empty
  | Some data -> factoids_of_json data |? StrMap.empty

let write_file ~file (fs: t) : unit Lwt.t =
  let file' = file ^ ".tmp" in
  let s = dump_factoids fs in
  Lwt_io.with_file ~mode:Lwt_io.output file'
    (fun oc ->
       Lwt_io.write oc s >>= fun () ->
       Lwt_io.flush oc)
  >>= fun () ->
  Sys.rename file' file;
  Lwt.return ()

type state = {
  mutable st_cur: t;
  st_conf: Config.t;
}

let save state =
  write_file ~file:state.st_conf.Config.factoids_file state.st_cur
and reload state =
  read_file ~file:state.st_conf.Config.factoids_file >|= fun fs ->
  state.st_cur <- fs

let init _ config : state Lwt.t =
  print_endline "load initial factoids file...";
  let state = {st_cur=empty; st_conf=config;} in
  reload state >|= fun () ->
  state

let msg_of_value (v:value): string option = match v with
  | Int i -> Some (string_of_int i)
  | StrList [] -> None
  | StrList [message] -> Some message
  | StrList l -> Some (DistribM.uniform l |> DistribM.run)

let cmd_search state =
  Command.make_simple ~descr:"search in factoids" ~prefix:"search" ~prio:10
    (fun _ s ->
       let tokens =
         String.trim s
         |> Str.split (Str.regexp "[ \t]+")
       in
       search tokens state.st_cur |> msg_of_value |> Lwt.return
    )

let cmd_see state =
  Command.make_simple ~descr:"see a factoid's content" ~prefix:"see" ~prio:10
    (fun _ s ->
       let v = get (mk_key s) state.st_cur in
       let msg = match v with
         | Int i -> string_of_int i
         | StrList [] -> "not found."
         | StrList l -> Prelude.string_list_to_string l
       in
       Some msg |> Lwt.return
    )

let cmd_random state =
  Command.make_simple ~descr:"random factoid" ~prefix:"random" ~prio:10
    (fun _ _ ->
       let msg = random state.st_cur in
       Some msg |> Lwt.return
    )

let cmd_reload state =
  Command.make_simple ~descr:"reload factoids" ~prefix:"reload" ~prio:10
    (fun _ _ ->
       reload state >|= fun () -> Some (Talk.select Talk.Ack)
    )

let cmd_factoids state =
  let reply (module C:Core.S) msg =
    let target = Core.reply_to msg in
    let matched x = Command.Cmd_match x in
    let reply_value (v:value) = match v with
      | Int i ->
        C.send_notice ~target ~message:(string_of_int i) |> matched
      | StrList [] -> Lwt.return_unit |> matched
      | StrList [message] ->
        C.send_notice ~target ~message |> matched
      | StrList l ->
        let message = DistribM.uniform l |> DistribM.run in
        C.send_notice ~target ~message |> matched
    and count_update_message (k: key) = function
      | None -> Lwt.return_unit
      | Some count ->
        C.send_notice ~target
          ~message:(Printf.sprintf "%s : %d" (k :> string) count)
    in
    let op = parse_op msg.Core.message in
    CCOpt.iter (fun c -> Log.logf "parsed command `%s`" (string_of_op c)) op;
    begin match op with
      | Some (Get k) ->
        reply_value (get k state.st_cur)
      | Some (Set f) ->
        if mem f.key state.st_cur then (
          C.talk ~target Talk.Err |> matched
        ) else (
          state.st_cur <- set f state.st_cur;
          (save state >>= fun () -> C.talk ~target Talk.Ack) |> matched
        )
      | Some (Set_force f) ->
        state.st_cur <- set f state.st_cur;
        (save state >>= fun () -> C.talk ~target Talk.Ack) |> matched
      | Some (Append f) ->
        state.st_cur <- append f state.st_cur;
        (save state >>= fun () -> C.talk ~target Talk.Ack) |> matched
      | Some (Incr k) ->
        let count, state' = incr k state.st_cur in
        state.st_cur <- state';
        (save state >>= fun () -> count_update_message k count) |> matched
      | Some (Decr k) ->
        let count, state' = decr k state.st_cur in
        state.st_cur <- state';
        (save state >>= fun () -> count_update_message k count) |> matched
      | None -> Command.Cmd_skip
    end
  in
  Command.make
    ~name:"factoids" ~prio:80 reply
    ~descr:"factoids, triggered by the following commands:

    - `!foo` will retrieve one of the factoids associated with `foo`, if any
    - `!foo = bar` maps `foo` to `bar`, unless `foo` is mapped yet
      (in which case it fails)
    - `!foo += bar` adds `bar` to the mappings of `foo`
    - `!foo := bar` maps `foo` to `bar` even if `foo` is already mapped
    "

let commands state: Command.t list =
  [ cmd_factoids state;
    cmd_search state;
    cmd_reload state;
    cmd_see state;
    cmd_random state;
  ]

let plugin : Plugin.t =
  let module P = Plugin in
  (* create state *)
  let cleanup state = save state in
  P.stateful ~init ~stop:cleanup commands
