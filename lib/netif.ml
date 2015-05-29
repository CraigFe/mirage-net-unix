(*
 * Copyright (c) 2010-2013 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf

type +'a io = 'a Lwt.t
type id = string

(** IO operation errors *)
type error = [
  | `Unknown of string (** an undiagnosed error *)
  | `Unimplemented     (** operation not yet implemented in the code *)
  | `Disconnected      (** the device has been previously disconnected *)
]

type stats = {
  mutable rx_bytes : int64;
  mutable rx_pkts : int32;
  mutable tx_bytes : int64;
  mutable tx_pkts : int32;
}

type t = {
  id: id;
  dev: Lwt_unix.file_descr;
  mutable active: bool;
  mutable mac: Macaddr.t;
  stats : stats;
}

type vif_info = {
  vif_id: id;
  vif_fd: Unix.file_descr;
}

let devices = Hashtbl.create 1

let connect devname =
  try
    let fd, devname = Tuntap.opentap ~pi:false ~devname () in
    let dev = Lwt_unix.of_unix_file_descr ~blocking:false fd in
    let mac = Macaddr.make_local (fun _ -> Random.int 256) in
    Tuntap.set_up_and_running devname;
    printf "plugging into %s with mac %s..\n%!" devname (Macaddr.to_string mac);
    let active = true in
    let t = {
      id=devname; dev; active; mac;
      stats= { rx_bytes=0L;rx_pkts=0l;
               tx_bytes=0L; tx_pkts=0l } } in
    Hashtbl.add devices devname t;
    printf "Netif: connect %s\n%!" devname;
    return (`Ok t)
  with
    |Failure "tun[open]: Permission denied" ->
      let s = sprintf "Permission denied while opening the %s tun device.  Please re-run using sudo, and install the TuntapOSX package if you are on MacOS X." devname in
      return (`Error (`Unknown s))
    |exn -> return (`Error (`Unknown (Printexc.to_string exn)))

let disconnect t =
  printf "Netif: disconnect %s\n%!" t.id;
  Tuntap.closetun t.id;
  return ()

type macaddr = Macaddr.t
type page_aligned_buffer = Io_page.t
type buffer = Cstruct.t

let macaddr t = t.mac
let set_macaddr t mac = t.mac <- mac

let error_to_string =
  function
  | `Unknown message -> sprintf "undiagnosed error - %s" message
  | `Unimplemented   -> "operation not yet implemented"
  | `Disconnected    -> "device is disconnected"

(* Input a frame, and block if nothing is available *)
let rec read t page =
  let buf = Io_page.to_cstruct page in
  try_lwt
    (Lwt_cstruct.read t.dev buf
     >>= function
     | (-1) -> (* EAGAIN or EWOULDBLOCK *)
       read t page
     | 0 -> (* EOF *)
       return (`Error `Disconnected)
     | len ->
       t.stats.rx_pkts <- Int32.succ t.stats.rx_pkts;
       t.stats.rx_bytes <- Int64.add t.stats.rx_bytes (Int64.of_int len);
       return (`Ok (Cstruct.sub buf 0 len)))
  with
   | Unix.Unix_error(Unix.ENXIO, _, _) ->
     printf "[netif-input] device %s is down\n%!" t.id;
     return (`Error `Disconnected)
   | exn ->
     printf "[netif-input] error : %s\n%!" (Printexc.to_string exn);
     return `Continue

(* Loop and listen for packets permanently *)
(* this function has to be tail recursive, since it is called at the
   top level, otherwise memory of received packets and all reachable
   data is never claimed.  take care when modifying, here be dragons! *)
let rec listen t fn =
  match t.active with
  | true ->
    let page = Io_page.get 1 in
    read t page >|= (function
        | `Error e ->
          printf "[netif] error, %s, terminating listen loop\n%!" (error_to_string e);
          t.active <- false
        | `Continue -> ()
        | `Ok buf ->
          ignore_result
            (try_lwt
               fn buf
             with exn ->
               printf "[netif] error while handling %s bt: %s\n%!"
                 (Printexc.to_string exn) (Printexc.get_backtrace ());
               return_unit))
    >>= fun () ->
    listen t fn
  | false -> return_unit

(* Transmit a packet from an Io_page *)
let write t page =
  (* Unfortunately we peek inside the cstruct type here: *)
  lwt len' = Lwt_bytes.write t.dev page.Cstruct.buffer page.Cstruct.off page.Cstruct.len in
  t.stats.tx_pkts <- Int32.succ t.stats.tx_pkts;
  t.stats.tx_bytes <- Int64.add t.stats.tx_bytes (Int64.of_int page.Cstruct.len);
  if len' <> page.Cstruct.len then
    raise_lwt (Failure (sprintf "tap: partial write (%d, expected %d)" len' page.Cstruct.len))
  else
    return ()

(* TODO use writev: but do a copy for now *)
let writev t pages =
  match pages with
  |[] -> return ()
  |[page] -> write t page
  |pages ->
    let page = Io_page.(to_cstruct (get 1)) in
    let off = ref 0 in
    List.iter (fun p ->
        let len = Cstruct.len p in
        Cstruct.blit p 0 page !off len;
        off := !off + len;
      ) pages;
    let v = Cstruct.sub page 0 !off in
    write t v

let id t = t.id

let mac t = t.mac

let get_stats_counters t = t.stats

let reset_stats_counters t =
  t.stats.rx_bytes <- 0L;
  t.stats.rx_pkts  <- 0l;
  t.stats.tx_bytes <- 0L;
  t.stats.tx_pkts  <- 0l
