
(** {1 Core IRC state} *)

open Prelude
open Containers
open Lwt.Infix

module Msg = Irc_message

type connection = Irc_client_lwt.connection_t

type privmsg = {
  nick: string; (* author *)
  to_: string; (* target *)
  message: string;
}

let is_chan s =
  s<>"" && s.[0] = '#' && not (String.contains s ' ')

let reply_to msg =
  if is_chan msg.to_
  then msg.to_ (* reply on same channel *)
  else msg.nick (* in pv *)

let privmsg_of_msg msg =
  match msg.Msg.command with
  | Msg.PRIVMSG (to_, message) ->
    Some
      { nick = Option.get_exn msg.Msg.prefix |> get_nick;
        to_;
        message }
  | _ -> None

let string_of_privmsg msg =
  Printf.sprintf "{nick:%s, to:%s, msg: %s}" msg.nick msg.to_ msg.message

module type S = sig
  val connection : connection Lwt.t

  val init : unit Lwt.t
  val exit : unit Lwt.t

  val send_exit : unit -> unit

  val messages : Msg.t Signal.t

  val privmsg : privmsg Signal.t

  val line_cut_threshold : int ref
  (** Above [!line_cut_threshold], multi-line messages are cut with "..." *)

  val send_privmsg_l :
    target:string -> messages:string list -> unit Lwt.t

  val send_privmsg :
    target:string -> message:string -> unit Lwt.t
  (** Helper for sending messages, splitting lines, etc. *)

  val send_notice_l :
    target:string -> messages:string list -> unit Lwt.t

  val send_notice :
    target:string -> message:string -> unit Lwt.t
  (** Helper for sending notices, splitting lines, etc. *)

  val send_join : channel:string -> unit Lwt.t

  val talk : target:string -> Talk.t -> unit Lwt.t

  val run : unit Lwt.t
  (** Feed to {!Lwt_main.run} *)
end

type t = (module S)

let of_conn c : t =
  let module M = struct
    let _conn = c

    let init, send_init = Lwt.wait ()
    let exit, send_exit = Lwt.wait ()

    let send_exit () = Lwt.wakeup send_exit ()

    let messages = Signal.create ()
    let privmsg = Signal.filter_map messages privmsg_of_msg

    let line_cut_threshold = ref 10

    let run =
      _conn >>= fun connection ->
      Irc_client_lwt.listen ~connection
        ~callback:(fun _ msg_or_err ->
          match msg_or_err with
            | `Ok msg -> Signal.send messages msg
            | `Error err -> Printf.eprintf "%s\n%!" err; Lwt.return ()) >>= fun () ->
      Irc_client_lwt.send_quit ~connection

    let connection =
      Lwt.wakeup send_init ();
      _conn >>= fun conn ->
      Lwt.return conn

    let process_list_ ~f ~target ~messages:lines =
      (* keep at most 4 *)
      let lines =
        let len = List.length lines in
        if len > !line_cut_threshold
        then CCList.take 4 lines @ [Printf.sprintf "(…%d more lines…)" (len-4)]
        else lines
      in
      connection >>= fun c ->
      Lwt_list.iter_s
        (fun message -> f ~connection:c ~target ~message)
        lines

    let split_lines_ s =
      let nl = Str.regexp_string "\n" in
      Str.split nl s

    let flat_map f l = List.map f l |> List.flatten

    let send_privmsg_l ~target ~messages =
      process_list_ ~f:Irc_client_lwt.send_privmsg ~target ~messages:(flat_map split_lines_ messages)

    let send_notice_l ~target ~messages =
      process_list_ ~f:Irc_client_lwt.send_notice ~target ~messages:(flat_map split_lines_ messages)

    let send_privmsg ~target ~message =
      process_list_ ~target ~messages:(split_lines_ message) ~f:Irc_client_lwt.send_privmsg

    let send_notice ~target ~message =
      process_list_ ~target ~messages:(split_lines_ message) ~f:Irc_client_lwt.send_notice

    let send_join ~channel =
      connection >>= fun c ->
      Irc_client_lwt.send_join ~connection:c ~channel

    let talk ~target ty =
      let message = Talk.select ty in
      send_privmsg ~target ~message
  end in
  (module M : S)

let of_config conf =
  let c =
    let module C = Config in
    Irc_client_lwt.connect_by_name
      ~username:conf.C.username ~realname:conf.C.realname ~nick:conf.C.nick
      ~server:conf.C.server ~port:conf.C.port
      ()
    >>= (function
      | Some c -> Lwt.return c
      | None -> failwith "Bad server address")
  in
  of_conn c
