(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

open Lwt.Infix

(** {1 Basic signal} *)

type handler_response =
  | ContinueListening
  | StopListening

type 'a t = {
  mutable n : int;  (* how many handlers? *)
  mutable handlers : ('a -> handler_response Lwt.t) array;
  mutable alive : keepalive;   (* keep some signal alive *)
} (** Signal of type 'a *)

and keepalive =
  | Keep : 'a t -> keepalive
  | NotAlive : keepalive

let _exn_handler = ref (fun _ -> ())

let nop_handler _x = Lwt.return ContinueListening

let create () =
  let s = {
    n = 0;
    handlers = Array.make 3 nop_handler;
    alive = NotAlive;
  } in
  s

(* remove handler at index i *)
let remove s i =
  assert (s.n > 0 && i >= 0);
  if i < s.n - 1  (* erase handler with the last one *)
    then s.handlers.(i) <- s.handlers.(s.n - 1);
  s.handlers.(s.n - 1) <- nop_handler; (* free handler *)
  s.n <- s.n - 1;
  ()

let send s x =
  let rec loop i =
    Lwt.catch
      (fun () ->
         s.handlers.(i) x >>= function
         | ContinueListening -> Lwt.return false
         | StopListening -> Lwt.return true)
      (fun exn ->
         !_exn_handler exn;
         Lwt.return false  (* be conservative, keep... *)) >>= fun b ->
    if b then (
      remove s i;  (* i-th handler is done, remove it *)
      loop i
    ) else if i < s.n then (
      loop (i+1)
    ) else (
      Lwt.return ()
    ) in
  loop 0

let on s f =
  (* resize handlers if needed *)
  if s.n = Array.length s.handlers
    then begin
      let handlers = Array.make (s.n + 4) nop_handler in
      Array.blit s.handlers 0 handlers 0 s.n;
      s.handlers <- handlers
    end;
  s.handlers.(s.n) <- f;
  s.n <- s.n + 1

let on' s f =
  on s (fun x -> f x >>= fun _ -> Lwt.return ContinueListening)

let once s f =
  on s (fun x -> f x >>= fun _ -> Lwt.return StopListening)

let propagate a b =
  on a (fun x -> send b x >>= fun () -> Lwt.return ContinueListening)

(** {2 Combinators} *)

let map signal f =
  let signal' = create () in
  (* weak ref *)
  let r = Weak.create 1 in
  Weak.set r 0 (Some signal');
  on signal (fun x ->
    match Weak.get r 0 with
    | None -> Lwt.return StopListening
    | Some signal' -> send signal' (f x) >>=
      fun () -> Lwt.return ContinueListening);
  signal'.alive <- Keep signal;
  signal'

let filter signal p =
  let signal' = create () in
  (* weak ref *)
  let r = Weak.create 1 in
  Weak.set r 0 (Some signal');
  on signal (fun x ->
    match Weak.get r 0 with
    | None -> Lwt.return StopListening
    | Some signal' -> (if p x then send signal' x else Lwt.return ()) >>=
      fun () -> Lwt.return ContinueListening);
  signal'.alive <- Keep signal;
  signal'

let filter_map signal f =
  let signal' = create () in
  (* weak ref *)
  let r = Weak.create 1 in
  Weak.set r 0 (Some signal');
  on signal (fun x ->
    match Weak.get r 0 with
    | None -> Lwt.return StopListening
    | Some signal' ->
      begin match f x with
        | None -> Lwt.return ()
        | Some x -> send signal' x
      end >>= fun () ->
      Lwt.return ContinueListening);
  signal'.alive <- Keep signal;
  signal'

let set_exn_handler h = _exn_handler := h
