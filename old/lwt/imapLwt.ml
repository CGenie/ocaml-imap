(* The MIT License (MIT)

   Copyright (c) 2014 Nicolas Ojeda Bar <n.oje.bar@gmail.com>

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE. *)

open ImapTypes

let _ =
  Lwt_log.default := Lwt_log.channel ~template:"$(message)" ~close_mode:`Keep ~channel:Lwt_io.stderr ()
  (* Lwt_log.Section.set_level Lwt_log.Section.main Lwt_log.Debug *)

let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)

let _ =
  (* prerr_endline "Initialising SSL..."; *)
  Ssl.init ()

exception ErrorP of error

exception StreamError

let _ =
  Printexc.register_printer
    (function
      | ErrorP err ->
          Some (ImapCore.string_of_error err)
      | StreamError ->
          Some "input/output error"
      | _ ->
          None)

module type IndexSet = sig
  type elt
  type t
  val empty : t
  val range : elt -> elt -> t
  val from : elt -> t
  val until : elt -> t
  val all : t
  val index : elt -> t
  val length : t -> int
  val add_range : elt -> elt -> t -> t
  val add : elt -> t -> t
  val remove_range : elt -> elt -> t -> t
  val remove : elt -> t -> t
  val contains : elt -> t -> bool
  val printer : Format.formatter -> t -> unit
  val to_string : t -> string
end

module IndexSet : sig
  include IndexSet with type elt = Uint32.t
  val to_imap_set : t -> ImapSet.t
  val of_imap_set : ImapSet.t -> t
end = struct
  type elt = Uint32.t
  type t = (elt * elt) list
  let cmp = Uint32.compare
  let succ = Uint32.add Uint32.one
  let pred n = Uint32.sub n Uint32.one
  let min l r = if cmp l r <= 0 then l else r
  let max l r = if cmp l r <= 0 then r else l
  let empty = []
  let range l r = if cmp l r <= 0 then (l, r) :: [] else (r, l) :: []
  let from l = (l, Uint32.max_int) :: []
  let until l = if cmp l Uint32.zero = 0 then [] else (Uint32.one, l) :: []
  let all = from Uint32.one
  let index n = range n n
  let length s =
    let l (l, r) = succ Uint32.(sub r l) |> Uint32.to_int in
    List.fold_left (fun acc x -> acc + (l x)) 0 s
  let add_range l r s =
    let l, r = if cmp l r <= 0 then l, r else r, l in
    let rec loop l r = function
        [] -> (l, r) :: []
      | (h, k) :: rest when cmp r (pred h) < 0 ->
          (l, r) :: (h, k) :: rest
      | (h, k) :: rest when cmp (succ k) l < 0 ->
          (h, k) :: loop l r rest
      | (h, k) :: rest (* when cmp (pred h) r <= 0 || cmp l (succ k) <= 0 *) ->
          loop (min l h) (max r k) rest
    in
    loop l r s
  let add n = add_range n n
  let remove_range l r s =
    let l, r = if cmp l r <= 0 then l, r else r, l in
    let rec loop l r = function
        [] -> []
      | (h, k) :: rest when cmp r h < 0 ->
          (h, k) :: rest
      | (h, k) :: rest when cmp k l < 0 ->
          (h, k) :: loop l r rest
      | (h, k) :: rest when cmp l h <= 0 && cmp r k < 0 ->
          (succ r, k) :: rest
      | (h, k) :: rest when cmp h l < 0 && cmp r k < 0 ->
          (h, pred l) :: (succ r, k) :: rest
      | (h, k) :: rest when cmp l h <= 0 && cmp k r <= 0 ->
          loop l r rest
      | (h, k) :: rest (* when cmp h l < 0 && cmp k r <= 0 *) ->
          (h, pred l) :: loop l r rest
    in
    loop l r s
  let remove n = remove_range n n
  let contains n s = List.exists (fun (l, r) -> cmp l n <= 0 && cmp n r <= 0) s
  let printer ppf s =
    let open Format in
    let pr ppf (l, r) =
      if Uint32.compare l r = 0 then
        fprintf ppf "%s" (Uint32.to_string l)
      else
        fprintf ppf "%s-%s" (Uint32.to_string l) (Uint32.to_string r)
    in
    match s with
      [] -> fprintf ppf "(empty)"
    | x :: [] -> pr ppf x
    | x :: xs -> pr ppf x; List.iter (fun x -> fprintf ppf ",%a" pr x) xs
  let to_string s =
    printer Format.str_formatter s;
    Format.flush_str_formatter ()
  let to_imap_set s =
    let f l = if cmp l Uint32.max_int = 0 then Uint32.zero else l in
    List.map (fun (l, r) -> (f l, f r)) s
  let of_imap_set s =
    let f l = if cmp l Uint32.zero = 0 then Uint32.max_int else l in
    List.fold_left (fun s (l, r) -> add_range (f l) (f r) s) empty s
end

module type Num = sig
  type t
  val of_int : int -> t
  val compare : t -> t -> int
  val zero : t
  val one : t
  val to_string : t -> string
  val of_string : string -> t
  val printer : Format.formatter -> t -> unit
end

module Uid = Uint32
module UidSet = IndexSet
module Seq = Uint32
module SeqSet = IndexSet

module Modseq = Uint64
module Gmsgid = Uint64
module Gthrid = Uint64

type connection_type =
    Clear
  | TLS of string option

type folder_flag =
    Marked
  | Unmarked
  | NoSelect
  | NoInferiors
  | Inbox
  | SentMail
  | Starred
  | AllMail
  | Trash
  | Drafts
  | Spam
  | Important
  | Archive

type message_flag =
    Seen
  | Answered
  | Flagged
  | Deleted
  | Draft
  | MDNSent
  | Forwarded
  | SubmitPending
  | Submitted

type messages_request_kind =
    Uid
  | Flags
  | Headers
  | Structure
  | InternalDate
  | FullHeaders
  | HeaderSubject
  | GmailLabels
  | GmailMessageID
  | GmailThreadID
  | ExtraHeaders of string list
  | Size

type workaround =
    Gmail
  | Yahoo
  | Exchange2003

type auth_capability =
    Anonymous
  | CRAMMD5
  | DigestMD5
  | External
  | GSSAPI
  | KerberosV4
  | Login
  | NTLM
  | OTP
  | Plain
  | SKey
  | SRP

type capability =
    ACL
  | Binary
  | Catenate
  | Children
  | CompressDeflate
  | Condstore
  | Enable
  | Idle
  | Id
  | LiteralPlus
  | MultiAppend
  | Namespace
  | QResync
  | Quote
  | Sort
  | StartTLS
  | ThreadORderedSubject
  | ThreadReferences
  | UIDPlus
  | Unselect
  | XList
  | Auth of auth_capability
  | XOAuth2
  | Gmail

type encoding =
    Bit7
  | Bit8
  | Binary
  | Base64
  | QuotedPrintable
  | Other
  | UUEncode

type search_key =
    All
  | From of string
  | To of string
  | Cc of string
  | Bcc of string
  | Recipient of string
  (** Recipient is the combination of To, Cc and Bcc *)
  | Subject of string
  | Content of string
  | Body of string
  | UIDs of ImapSet.t
  | Header of string * string
  | Read
  | Unread
  | Flagged
  | Unflagged
  | Answered
  | Unanswered
  | Draft
  | Undraft
  | Deleted
  | Spam
  | BeforeDate of float
  | OnDate of float
  | SinceDate of float
  | BeforeReceiveDate of float
  | OnReceiveDate of float
  | SinceReceiveDate of float
  | SizeLarger of int
  | SizeSmaller of int
  | GmailThreadID of Gthrid.t
  | GmailMessageID of Gmsgid.t
  | GmailRaw of string
  | Or of search_key * search_key
  | And of search_key * search_key
  | Not of search_key

type error =
    Connection
  (* | TLSNotAvailable *)
  | Parse
  | Certificate
  | Authentication
  | GmailIMAPNotEnabled
  | GmailExceededBandwidthLimit
  | GmailTooManySimultaneousConnections
  | MobileMeMoved
  | YahooUnavailable
  | NonExistantFolder
  | Rename
  | Delete
  | Create
  | Subscribe
  | Append
  | Copy
  | Expunge
  | Fetch
  | Idle
  | Identity
  | Namespace
  | Store
  | Capability
  | StartTLSNotAvailable
  | SendMessageIllegalAttachment
  | StorageLimit
  | SendMessageNotAllowed
  | NeedsConnectToWebmail
  | SendMessage
  | AuthenticationRequired
  | FetchMessageList
  | DeleteMessage
  | InvalidAccount
  | File
  | Compression
  | NoSender
  | NoRecipient
  | Noop

type folder_status =
  { unseen_count : int;
    message_count : int;
    recent_count : int;
    uid_next : Uid.t;
    uid_validity : Uid.t;
    highest_mod_seq_value : Modseq.t }

type folder =
  { path : string;
    delimiter : char option;
    flags : folder_flag list }

type multipart_type =
    Mixed
  | Related
  | Alternative
  | Signed

type singlepart_type =
    Basic
  | Message of part

and single_part =
  { part_id : string;
    size : int;
    filename : string option;
    mime_type : string;
    charset : string option;
    content_id : string option;
    content_location : string option;
    content_description : string option;
    part_type : singlepart_type }

and multi_part =
  { part_id : string;
    mime_type : string;
    parts : part list;
    part_type : multipart_type }

and part =
    Single of single_part
  | Multipart of multi_part

type address =
  { display_name : string;
    mailbox : string }

type envelope =
  { message_id : string;
    references : string list;
    in_reply_to : string list;
    sender : address option;
    from : address option;
    to_ : address list;
    cc : address list;
    bcc : address list;
    reply_to : address list;
    subject : string }

module M = Map.Make
    (struct
      type t = string
      let compare s1 s2 = String.compare (String.lowercase s1) (String.lowercase s2)
    end)

type message =
  { uid : Uid.t;
    size : int;
    mod_seq_value : Modseq.t;
    gmail_labels : string list;
    gmail_message_id : Gmsgid.t;
    gmail_thread_id : Gthrid.t;
    flags : message_flag list;
    internal_date : float;
    main_part : part option;
    envelope : envelope option;
    extra_headers : string M.t }

type sync_result =
  { vanished_messages : IndexSet.t;
    modified_or_added_messages : message list }

exception Error of error

let capabilities_of_imap_capabilities caps =
  let rec loop acc = function
      [] ->
        List.rev acc
    | CAPABILITY_NAME name :: rest ->
        begin
          match String.uppercase name with
            "STARTTLS"         -> loop (StartTLS :: acc) rest
          | "ID"               -> loop (Id :: acc) rest
          | "XLIST"            -> loop (XList :: acc) rest
          | "X-GM-EXT-1"       -> loop (Gmail :: acc) rest
          | "IDLE"             -> loop (Idle :: acc) rest
          | "CONDSTORE"        -> loop (Condstore :: acc) rest
          | "QRESYNC"          -> loop (QResync :: acc) rest
          | "XOAUTH2"          -> loop (XOAuth2 :: acc) rest
          | "COMPRESS=DEFLATE" -> loop (CompressDeflate :: acc) rest
          | "NAMESPACE"        -> loop (Namespace :: acc) rest
          | "CHILDREN"         -> loop (Children :: acc) rest
          | _                  -> loop acc rest
        end
    | CAPABILITY_AUTH_TYPE name :: rest ->
        begin
          match String.uppercase name with
            "PLAIN" -> loop (Auth Plain :: acc) rest
          | "LOGIN" -> loop (Auth Login :: acc) rest
          | _ -> loop acc rest
        end
  in
  loop [] caps

module Conn : sig
  type connected_info =
    { mutable imap_state : ImapTypes.state;
      sock : Lwt_ssl.socket;
      mutable condstore_enabled : bool;
      mutable qresync_enabled : bool; (* FIXME set these somewhere ! *)
      mutable compressor : (Cryptokit.transform * Cryptokit.transform) option;
      mutable capabilities : capability list;
      mutable idling : unit Lwt.u option }
  type selected_info
    (* { current_folder : string; *)
    (*   uid_next : Uid.t; *)
    (*   uid_validity : Uid.t; *)
    (*   mod_sequence_value : Modseq.t; *)
    (*   folder_msg_count : int option; *)
    (*   first_unseen_uid : Uid.t } *)
  type connection
  val run : 'a ImapCore.command -> connected_info -> 'a Lwt.t
  val connect_if_needed :
    conn_type:connection_type ->
    port:int ->
    host:string -> connection -> connected_info Lwt.t
  val login_if_needed :
    conn_type:connection_type ->
    port:int ->
    host:string ->
    username:string ->
    password:string -> connection -> connected_info Lwt.t
  val select_if_needed :
    conn_type:connection_type ->
    port:int ->
    host:string ->
    username:string ->
    password:string -> connection -> string -> (connected_info * selected_info) Lwt.t
  val disconnect :
    connection -> unit Lwt.t
  val new_connection :
    unit -> connection
  val is_idle :
    connection -> bool
  val is_selecting_folder :
    string -> connection -> bool
  val reset_auto_disconnect :
    connection -> (unit -> 'a Lwt.t) -> 'a Lwt.t
  val logout :
    connection -> unit Lwt.t
  val wait_read :
    connected_info -> unit Lwt.t
end = struct
  type connected_info =
    { mutable imap_state : ImapTypes.state;
      sock : Lwt_ssl.socket;
      mutable condstore_enabled : bool;
      mutable qresync_enabled : bool; (* FIXME set these somewhere ! *)
      mutable compressor : (Cryptokit.transform * Cryptokit.transform) option;
      mutable capabilities : capability list;
      mutable idling : unit Lwt.u option }

  type selected_info =
    { current_folder : string;
      uid_next : Uid.t;
      uid_validity : Uid.t;
      mod_sequence_value : Modseq.t;
      folder_msg_count : int option;
      first_unseen_uid : Uid.t }

  type state =
      DISCONNECTED
    | CONNECTED of connected_info
    | LOGGEDIN of connected_info
    | SELECTED of connected_info * selected_info

  let fully_write sock buf pos len =
    let rec loop pos len =
      if len <= 0 then
        Lwt.return_unit
      else
        lwt n = try_lwt Lwt_ssl.write sock buf pos len with _ -> raise_lwt StreamError in
        loop (pos + n) (len - n)
    in
    loop pos len

  let read sock buf pos len =
    try_lwt Lwt_ssl.read sock buf pos len with _ -> raise_lwt StreamError

  let run c s =
    let open ImapControl in
    let buf = Bytes.create 65536 in
    let rec loop in_buf = function
        Ok (x, st) ->
          s.imap_state <- st;
          Lwt.return x
      | Fail (err, st) ->
          s.imap_state <- st;
          raise_lwt (ErrorP err)
      | Flush (str, k) ->
          lwt () = Lwt_log.debug_f ">>>>\n%s>>>>\n" str in
          lwt () =
            match s.compressor with
              None -> fully_write s.sock str 0 (String.length str)
            | Some (enc, _) ->
                enc # put_string str;
                enc # flush;
                let buf, pos, len = enc # get_substring in
                fully_write s.sock buf pos len
          in
          (* lwt () = fully_write s.sock str 0 (String.length str) in *)
          loop in_buf (k ())
      | Need k ->
          match_lwt read s.sock buf 0 (String.length buf) with
          | 0 ->
              loop in_buf (k End)
          | _ as n ->
              let str =
                match s.compressor with
                  None -> String.sub buf 0 n
                | Some (_, dec) ->
                    dec # put_substring buf 0 n;
                    dec # flush;
                    dec # get_string
              in
              lwt () = Lwt_log.debug_f "<<<<\n%s<<<<\n" str in
              Buffer.add_substring in_buf str 0 (String.length str);
              loop in_buf (k More)
    in
    loop s.imap_state.in_buf (run c s.imap_state)

  type connection =
    { mutable state : state;
      mutex : Lwt_mutex.t;
      mutable auto_disconnect : unit Lwt.t }

  let disconnect c =
    match c.state with
      CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
        lwt () = try_lwt Lwt_ssl.close ci.sock with _ -> Lwt.return_unit in
        c.state <- DISCONNECTED;
        Lwt.return_unit
    | DISCONNECTED ->
        Lwt.return_unit

  let cache_capabilities c =
    lwt ci =
      match c.state with
        CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
          Lwt.return ci
      | DISCONNECTED ->
          assert_lwt false
    in
    lwt caps =
      try_lwt
        if List.length ci.imap_state.cap_info > 0 then
          Lwt.return ci.imap_state.cap_info
        else
          run ImapCommands.capability ci
      with
        exn ->
          disconnect c >> Lwt_log.debug ~exn "capabilities failed" >> raise_lwt (Error Capability)
    in
    ci.capabilities <- capabilities_of_imap_capabilities caps;
    Lwt.return_unit

  let ssl_context ssl_method ca_file =
    let ctx = Ssl.create_context ssl_method Ssl.Client_context in
    match ca_file with
      None ->
        ctx
    | Some ca_file ->
        Ssl.load_verify_locations ctx ca_file "";
        Ssl.set_verify ctx [Ssl.Verify_peer] None;
        ctx

  let connect ~conn_type ~port ~host c =
    lwt () = match c.state with
        DISCONNECTED -> Lwt.return_unit
      | _            -> assert_lwt false
    in
    try_lwt
      let he = Unix.gethostbyname host in
      let sa = Unix.ADDR_INET (he.Unix.h_addr_list.(0), port) in
      let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      lwt () = Lwt_unix.connect fd sa in
      lwt sock =
        match conn_type with
          Clear ->
            Lwt.return (Lwt_ssl.plain fd)
        | TLS ca_file ->
            let context = ssl_context Ssl.SSLv23 ca_file in
            lwt sock = Lwt_ssl.ssl_connect fd context in
            lwt () = Lwt_log.debug "SSL connection ok" in
            let ssl_sock = match Lwt_ssl.ssl_socket sock with Some sock -> sock | None -> assert false in
            let cert = Ssl.get_certificate ssl_sock in
            Ssl.verify ssl_sock;
            lwt () = Lwt_log.debug_f "Certificate issuer: %s" (Ssl.get_issuer cert) in
            lwt () = Lwt_log.debug_f "Subject: %s" (Ssl.get_subject cert) in
            Lwt.return sock
      in
      let ci =
        { imap_state = ImapCore.fresh_state;
          sock;
          condstore_enabled = false;
          qresync_enabled = false;
          compressor = None;
          capabilities = [];
          idling = None }
      in
      lwt _ = run ImapCore.greeting ci in
      c.state <- CONNECTED ci;
      lwt () = cache_capabilities c in
      Lwt.return ci
    with
      Ssl.Verify_error _ ->
        raise_lwt (Error Certificate)
    | _ ->
        raise_lwt (Error Connection)

  let connect_if_needed ~conn_type ~port ~host c =
    match c.state with
      DISCONNECTED ->
        connect ~conn_type ~port ~host c
    | CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
        Lwt.return ci

  let enable_compression c =
    lwt ci = match c.state with
        CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
          Lwt.return ci
      | DISCONNECTED ->
          assert_lwt false
    in
    lwt () = assert_lwt (ci.compressor = None) in
    lwt () =
      try_lwt
        run ImapCommands.Compress.compress ci
      with
        StreamError ->
          disconnect c >> raise_lwt (Error Connection)
      | ErrorP (ParseError _) ->
          raise_lwt (Error Parse)
      | _ ->
          raise_lwt (Error Compression)
    in
    ci.compressor <- Some (Cryptokit.Zlib.compress (), Cryptokit.Zlib.uncompress ());
    Lwt.return_unit

  let enable_feature c feature =
    lwt ci =
      match c.state with
        CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
          Lwt.return ci
      | DISCONNECTED ->
          assert_lwt false
    in
    try_lwt
      lwt _ = run (ImapCommands.Enable.enable [CAPABILITY_NAME feature]) ci in
      Lwt.return true
    with
      exn -> Lwt_log.debug_f ~exn "could not enable %S" feature >> Lwt.return false

  let has_capability c cap =
    match c.state with
      CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
        List.mem cap ci.capabilities
    | DISCONNECTED ->
        false

  let enable_features s =
    lwt () =
      if has_capability s CompressDeflate then
        try_lwt
          enable_compression s
        with
          exn -> Lwt_log.debug ~exn "could not enable compression"
      else
        Lwt.return_unit
    in
    if has_capability s QResync then
      enable_feature s "QRESYNC" >> Lwt.return_unit
    else if has_capability s Condstore then
      enable_feature s "CONDSTORE" >> Lwt.return_unit
    else
      Lwt.return_unit

  let contains str response =
    let rec index i =
      if i + String.length str > String.length response then
        false
      else
        let rec loop j =
          j >= String.length str || (str.[j] = response.[i + j] && loop (j+1))
        in
        loop 0
    in
    let rec loop i = index i || loop (i+1) in
    loop 0

  let login ~username ~password c =
    lwt ci = match c.state with
        CONNECTED ci ->
          Lwt.return ci
      | LOGGEDIN _ | SELECTED _ | DISCONNECTED ->
          assert_lwt false
    in
    lwt () =
      try_lwt
        run (ImapCommands.login username password) ci
      with
        exn ->
          lwt () = Lwt_log.debug ~exn "login error" in
          match exn with
            StreamError ->
              disconnect c >> raise_lwt (Error Connection)
          | ErrorP (ParseError _) ->
              raise_lwt (Error Parse)
          | _ ->
              let contains str = contains str ci.imap_state.imap_response in
              if contains "not enabled for IMAP use" then
                raise_lwt (Error GmailIMAPNotEnabled)
              else if contains "bandwidth limits" then
                raise_lwt (Error GmailExceededBandwidthLimit)
              else if contains "Too many simultaneous connections" then
                raise_lwt (Error GmailTooManySimultaneousConnections)
              else if contains "Maximum number of connections" then
                raise_lwt (Error GmailTooManySimultaneousConnections)
              else if contains "http://me.com/move" then
                raise_lwt (Error MobileMeMoved)
              else if contains "OCF12" then
                raise_lwt (Error YahooUnavailable)
              else
                raise_lwt (Error Authentication)
    in
    c.state <- LOGGEDIN ci;
    lwt () = cache_capabilities c in
    lwt () = enable_features c in
    Lwt.return ci

  let login_if_needed ~conn_type ~port ~host ~username ~password c =
    lwt _ = connect_if_needed ~conn_type ~port ~host c in
    match c.state with
      CONNECTED _ ->
        login ~username ~password c
    | LOGGEDIN ci | SELECTED (ci, _) ->
        Lwt.return ci
    | DISCONNECTED ->
        assert_lwt false

  let get_mod_sequence_value state =
    let open ImapCommands.Condstore in
    let rec loop = function
        [] -> Modseq.zero
      | EXTENSION_DATA (RESP_TEXT_CODE, RESP_TEXT_CODE_HIGHESTMODSEQ n) :: _ -> n
      | EXTENSION_DATA (RESP_TEXT_CODE, RESP_TEXT_CODE_NOMODSEQ) :: _ -> Modseq.zero
      | _ :: rest -> loop rest
    in
    loop state.rsp_info.rsp_extension_list

  let select c folder =
    lwt ci = match c.state with
        LOGGEDIN ci | SELECTED (ci, _) ->
          Lwt.return ci
      | DISCONNECTED | CONNECTED _ ->
          assert_lwt false
    in
    lwt () =
      try_lwt
        run (ImapCommands.select folder) ci
      with
        exn ->
          lwt () = Lwt_log.debug ~exn "select error" in
          match exn with
            StreamError ->
              disconnect c >> raise_lwt (Error Connection)
          | ErrorP (ParseError _) ->
              (* FIXME set state to LOGGEDIN ? *)
              raise_lwt (Error Parse)
          | _ ->
              c.state <- LOGGEDIN ci;
              raise_lwt (Error NonExistantFolder)
    in
    let st = ci.imap_state in
    let si =
      { current_folder = folder;
        uid_next = st.sel_info.sel_uidnext;
        uid_validity = st.sel_info.sel_uidvalidity;
        folder_msg_count = st.sel_info.sel_exists;
        first_unseen_uid = st.sel_info.sel_first_unseen;
        mod_sequence_value = get_mod_sequence_value st }
    in
    c.state <- SELECTED (ci, si);
    Lwt.return (ci, si)

  let select_if_needed ~conn_type ~port ~host ~username ~password c folder =
    lwt _ = login_if_needed ~conn_type ~port ~host ~username ~password c in
    match c.state with
      SELECTED (ci, si)->
        if String.lowercase si.current_folder <> String.lowercase folder then
          select c folder
        else
          Lwt.return (ci, si)
    | LOGGEDIN _ ->
        select c folder
    | _ ->
        assert_lwt false

  let logout c =
    match c.state with
      CONNECTED ci | LOGGEDIN ci | SELECTED (ci, _) ->
        lwt () =
          try_lwt
            let () = match ci.idling with Some waker -> Lwt.wakeup waker () | None -> () in
            run ImapCommands.logout ci
          with
            _ -> Lwt.return_unit
        in
        c.state <- DISCONNECTED;
        Lwt.return_unit
    | DISCONNECTED ->
        Lwt.return_unit

  let new_connection () =
    { state = DISCONNECTED; mutex = Lwt_mutex.create (); auto_disconnect = Lwt.return_unit }

  let is_idle c =
    not (Lwt_mutex.is_locked c.mutex)

  let is_selecting_folder folder c =
    match c.state with
      SELECTED (_, si) -> String.uppercase si.current_folder = String.uppercase folder
    | _ -> false

  let reset_auto_disconnect c f =
    Lwt.cancel c.auto_disconnect;
    Lwt.finalize f begin fun () ->
      if is_idle c then
        c.auto_disconnect <-
          (Lwt_unix.sleep 60. >> Lwt_log.debug "disconnecting automatically..." >> disconnect c);
      Lwt.return_unit
    end

  let wait_read ci =
    Lwt_unix.wait_read (Lwt_ssl.get_fd ci.sock)
end

let handle_imap_error err c exn =
  lwt () = Lwt_log.debug ~exn "error" in
  match exn with
    StreamError ->
      Conn.disconnect c >> raise_lwt (Error Connection)
  | ErrorP (ParseError _) ->
      raise_lwt (Error Parse)
  | _ ->
      raise_lwt (Error err)

module Session = struct
  type session =
    { conn_type : connection_type;
      username : string;
      password : string;
      host : string;
      port : int;
      max_connections : int;
      mutable connections : Conn.connection list }

  let create_session ?(max_connections = 2) ?(conn_type = TLS None) ?port ~host ~username ~password () =
    let port = match port with
      Some n -> n
    | None   -> match conn_type with Clear -> 143 | TLS _ -> 993 in
    { conn_type;
      username;
      password;
      host;
      port;
      max_connections;
      connections = [] }

  let new_connection s =
    let r = Conn.new_connection () in
    s.connections <- r :: s.connections;
    (* Lwt_log.ign_debug "new connection!"; *)
    r

  let acquire ?folder s =
    try
      match folder with
        None        -> List.find Conn.is_idle s.connections
      | Some folder -> List.find (Conn.is_selecting_folder folder) s.connections
    with
      Not_found ->
        if List.length s.connections < s.max_connections then
          new_connection s
        else
          List.nth s.connections (Random.int (List.length s.connections))

  let use s ?folder f =
    let c = acquire ?folder s in
    Conn.reset_auto_disconnect c (fun () -> f c)

  let with_loggedin s f ferr =
    use s begin fun c ->
      lwt ci = Conn.login_if_needed s.conn_type s.port s.host s.username s.password c in
      try_lwt f ci with exn -> ferr c exn
    end

  let with_folder s folder f ferr =
    use s begin fun c ->
      lwt ci, _ = Conn.select_if_needed s.conn_type s.port s.host s.username s.password c folder in
      try_lwt f ci with exn -> ferr c exn
    end

  let with_connected s f ferr =
    use s begin fun c ->
      lwt ci = Conn.connect_if_needed s.conn_type s.port s.host c in
      try_lwt f ci with exn -> ferr c exn
    end

  let logout s =
    Lwt_list.iter_p Conn.logout s.connections
end

type session = Session.session

let create_session = Session.create_session

let logout = Session.logout

let folder_status s ~folder =
  let status_att_list : status_att list =
    STATUS_ATT_UNSEEN :: STATUS_ATT_MESSAGES :: STATUS_ATT_RECENT ::
    STATUS_ATT_UIDNEXT :: STATUS_ATT_UIDVALIDITY :: []
  in
  let rec loop fs = function
      [] ->
        fs
    | STATUS_ATT_MESSAGES message_count :: rest ->
        loop {fs with message_count} rest
    | STATUS_ATT_RECENT recent_count :: rest ->
        loop {fs with recent_count} rest
    | STATUS_ATT_UIDNEXT uid_next :: rest ->
        loop {fs with uid_next} rest
    | STATUS_ATT_UIDVALIDITY uid_validity :: rest ->
        loop {fs with uid_validity} rest
    | STATUS_ATT_UNSEEN unseen_count :: rest ->
        loop {fs with unseen_count} rest
    | STATUS_ATT_HIGHESTMODSEQ highest_mod_seq_value :: rest ->
        loop {fs with highest_mod_seq_value} rest
    | _ :: rest ->
        loop fs rest
  in
  lwt status =
    Session.with_loggedin s begin fun ci ->
      let status_att_list : status_att list =
        if ci.Conn.condstore_enabled then STATUS_ATT_HIGHESTMODSEQ :: status_att_list else status_att_list
      in
      Conn.run (ImapCommands.status folder status_att_list) ci
    end (handle_imap_error NonExistantFolder)
  in
  let fs =
    { unseen_count = 0;
      message_count = 0;
      recent_count = 0;
      uid_next = Uid.zero;
      uid_validity = Uid.zero;
      highest_mod_seq_value = Modseq.zero }
  in
  Lwt.return (loop fs status.st_info_list)

let noop s =
  Session.with_loggedin s (Conn.run ImapCommands.noop) (handle_imap_error Noop)

let mb_keyword_flag =
  [ "Inbox", Inbox;
    "AllMail", AllMail;
    "Sent", SentMail;
    "Spam", Spam;
    "Starred", Starred;
    "Trash", Trash;
    "Important", Important;
    "Drafts", Drafts;
    "Archive", Archive;
    "All", AllMail;
    "Junk", Spam;
    "Flagged", Starred ]

let imap_mailbox_flags_to_flags imap_flags =
  let flags =
    match imap_flags.mbf_sflag with
      None ->
        []
    | Some MBX_LIST_SFLAG_NOSELECT ->
        NoSelect :: []
    | Some MBX_LIST_SFLAG_MARKED ->
        Marked :: []
    | Some MBX_LIST_SFLAG_UNMARKED ->
        Unmarked :: []
  in
  let mb_keyword_flag = List.map (fun (k, v) -> (String.uppercase k, v)) mb_keyword_flag in
  List.fold_left (fun l imap_oflag ->
      match imap_oflag with
        MBX_LIST_OFLAG_NOINFERIORS ->
          NoInferiors :: l
      | MBX_LIST_OFLAG_EXT of_flag_ext ->
          let of_flag_ext = String.uppercase of_flag_ext in
          try List.assoc of_flag_ext mb_keyword_flag :: l with Not_found -> l)
    flags imap_flags.mbf_oflags

(* let fetch_delimiter_if_needed s = *)
(*   lwt ci = connect_if_needed s in *)
(*   match ci.delimiter with *)
(*     None -> *)
(*       lwt imap_folders = *)
(*         try_lwt *)
(*           run ci (ImapCommands.list "" "") *)
(*         with *)
(*           StreamError -> *)
(*             lwt () = disconnect s in *)
(*             raise_lwt (Error Connection) *)
(*         | _ -> *)
(*             None *)
(*   | Some c -> *)
(*       Lwt.return c *)

let fetch_all_folders s =
  let results mb_list =
    let flags = imap_mailbox_flags_to_flags mb_list.mb_flag in
    let path = if String.uppercase mb_list.mb_name = "INBOX" then "INBOX" else mb_list.mb_name in
    { path; delimiter = mb_list.mb_delimiter; flags }
  in
  lwt imap_folders =
        (* lwt delimiter = fetch_delimiter_if_needed ci in FIXME *)
    Session.with_loggedin s (Conn.run (ImapCommands.list "" "*"))
      (handle_imap_error NonExistantFolder)
  in
  Lwt.return (List.map results imap_folders)

let rename_folder s ~folder ~new_name =
  Session.with_folder s "INBOX" (Conn.run (ImapCommands.rename folder new_name))
    (handle_imap_error Rename)

let delete_folder s ~folder =
  Session.with_folder s "INBOX" (Conn.run (ImapCommands.delete folder))
    (handle_imap_error Delete)

let create_folder s ~folder =
  Session.with_folder s "INBOX" (Conn.run (ImapCommands.create folder))
    (handle_imap_error Create)

let subscribe_folder s ~folder =
  Session.with_folder s "INBOX" (Conn.run (ImapCommands.subscribe folder))
    (handle_imap_error Subscribe)

let unsubscribe_folder s ~folder =
  Session.with_folder s "INBOX" (Conn.run (ImapCommands.unsubscribe folder))
    (handle_imap_error Subscribe)

let flag_to_lep = function
    Seen          -> FLAG_SEEN
  | Flagged       -> FLAG_FLAGGED
  | Deleted       -> FLAG_DELETED
  | Answered      -> FLAG_ANSWERED
  | Draft         -> FLAG_DRAFT
  | Forwarded     -> FLAG_KEYWORD "$Forwarded"
  | MDNSent       -> FLAG_KEYWORD "$MDNSent"
  | SubmitPending -> FLAG_KEYWORD "$SubmitPending"
  | Submitted     -> FLAG_KEYWORD "$Submitted"

let append_message s ~folder ~message ?(customflags = []) ~flags =
  let flags = (List.map (fun fl -> FLAG_KEYWORD fl) customflags) @ (List.map flag_to_lep flags) in
  Session.with_folder s folder begin fun ci ->
    lwt _, uidresult = Conn.run (ImapCommands.Uidplus.uidplus_append folder ~flags message) ci in
    Lwt.return uidresult
  end (handle_imap_error Append)

let copy_messages s ~folder ~uids ~dest =
  lwt uidvalidity, src_uid, dst_uid =
    Session.with_folder s folder
      (Conn.run (ImapCommands.Uidplus.uidplus_uid_copy uids dest))
      (handle_imap_error Copy)
  in
  let h = Hashtbl.create 0 in
  ImapSet.iter2 (Hashtbl.add h) src_uid dst_uid;
  Lwt.return h

let expunge_folder s ~folder =
  Session.with_folder s folder (Conn.run ImapCommands.expunge)
    (handle_imap_error Expunge)

let flags_from_lep_att_dynamic att_list =
  let rec loop (acc : message_flag list) = function
      [] -> List.rev acc
    | FLAG_FETCH_OTHER flag :: rest ->
        begin
          match flag with
            FLAG_ANSWERED -> loop (Answered :: acc) rest
          | FLAG_FLAGGED  -> loop (Flagged :: acc) rest
          | FLAG_DELETED  -> loop (Deleted :: acc) rest
          | FLAG_SEEN     -> loop (Seen :: acc) rest
          | FLAG_DRAFT    -> loop (Draft :: acc) rest
          | FLAG_KEYWORD "$Forwarded"     -> loop (Forwarded :: acc) rest
          | FLAG_KEYWORD "$MDNSent"       -> loop (MDNSent :: acc) rest
          | FLAG_KEYWORD "$SubmitPending" -> loop (SubmitPending :: acc) rest
          | FLAG_KEYWORD "$Submitted"     -> loop (Submitted :: acc) rest
          | _ -> loop acc rest
        end
    | _ :: rest ->
        loop acc rest
  in
  loop [] att_list

(* let is_known_custom_flag = function *)
(*   | "$MDNSent" *)
(*   | "$Forwarded" *)
(*   | "$SubmitPending" *)
(*   | "$Submitted" -> true *)
(*   | _ -> false *)

(* let custom_flags_from_lep_att_dynamic att_list = *)
(*   let rec loop = function *)
(*     | [] -> [] *)
(*     | FLAG_FETCH_OTHER (FLAG_KEYWORD kw) :: rest when not (is_known_custom_flag kw) -> *)
(*         kw :: loop rest *)
(*     | _ :: rest -> *)
(*         loop rest *)
(*   in *)
(*   loop att_list *)

let import_imap_address ad =
  { display_name = ad.ad_personal_name; (* FIXME mime decode *)
    mailbox = ad.ad_mailbox_name ^ "@" ^ ad.ad_host_name }

let import_imap_envelope env =
  let sender =
    let l = List.map import_imap_address env.env_sender in
    if List.length l > 0 then Some (List.hd l) else None
  in
  let from =
    let l = List.map import_imap_address env.env_from in
    if List.length l > 0 then Some (List.hd l) else None
  in
  { message_id = env.env_message_id; (* FIXME mailimf_msg_id_parse *)
    references = [];
    reply_to = List.map import_imap_address env.env_reply_to;
    sender;
    from;
    to_ = List.map import_imap_address env.env_to;
    cc = List.map import_imap_address env.env_cc;
    bcc = List.map import_imap_address env.env_bcc;
    in_reply_to = [env.env_in_reply_to]; (* fixme msg_id_list_parse *)
    subject = env.env_subject }

let import_imap_body body =
  let basic_part part_id basic ext =
    let mime_type = match basic.bd_media_basic.med_basic_type with
        MEDIA_BASIC_APPLICATION ->
          "application/" ^ basic.bd_media_basic.med_basic_subtype
      | MEDIA_BASIC_AUDIO ->
          "audio/" ^ basic.bd_media_basic.med_basic_subtype
      | MEDIA_BASIC_IMAGE ->
          "image/" ^ basic.bd_media_basic.med_basic_subtype
      | MEDIA_BASIC_MESSAGE ->
          "message/" ^ basic.bd_media_basic.med_basic_subtype
      | MEDIA_BASIC_VIDEO ->
          "video/" ^ basic.bd_media_basic.med_basic_subtype
      | MEDIA_BASIC_OTHER s ->
          s ^ "/" ^ basic.bd_media_basic.med_basic_subtype
    in
    { part_id = String.concat "." (List.rev part_id);
      size = basic.bd_fields.bd_size;
      filename = None;
      mime_type;
      charset = None;
      content_id = basic.bd_fields.bd_id;
      content_location = None;
      content_description = basic.bd_fields.bd_description;
      part_type = Basic }
  in
  let text_part part_id (text : body_type_text) ext =
    { part_id = String.concat "." (List.rev part_id);
      size = text.bd_fields.bd_size;
      filename = None;
      mime_type = "text/" ^ text.bd_media_text;
      charset = None;
      content_id = text.bd_fields.bd_id;
      content_location = None;
      content_description = text.bd_fields.bd_description;
      part_type = Basic }
  in
  let rec msg_part part_id msg ext =
    let next_part_id = match msg.bd_body with
        BODY_1PART _ -> "1" :: part_id
      | BODY_MPART _ -> part_id
    in
    { part_id = String.concat "." (List.rev part_id);
      size = msg.bd_fields.bd_size;
      filename = None;
      mime_type = "message/rfc822";
      charset = None;
      content_id = msg.bd_fields.bd_id;
      content_location = None;
      content_description = msg.bd_fields.bd_description;
      part_type = Message (part next_part_id msg.bd_body) }
  and single_part part_id sp =
    match sp.bd_data with
      BODY_TYPE_1PART_BASIC basic ->
        basic_part part_id basic sp.bd_ext_1part
    | BODY_TYPE_1PART_MSG msg ->
        msg_part part_id msg sp.bd_ext_1part
    | BODY_TYPE_1PART_TEXT text ->
        text_part part_id text sp.bd_ext_1part
  and multi_part part_id mp =
    let rec loop count = function
        []         -> []
      | bd :: rest -> part (string_of_int count :: part_id) bd :: loop (count + 1) rest
    in
    let parts = loop 1 mp.bd_list in
    let part_type = match String.lowercase mp.bd_media_subtype with
        "alternative" -> Alternative
      | "related"     -> Related
      | _             -> Mixed
    in
    { part_id = String.concat "." (List.rev part_id);
      mime_type = "multipart/" ^ mp.bd_media_subtype;
      parts;
      part_type }
  and part part_id = function
      BODY_1PART sp -> Single (single_part part_id sp)
    | BODY_MPART mp -> Multipart (multi_part part_id mp)
  in
  match body with
    BODY_1PART _ -> part ["1"] body
  | BODY_MPART _ -> part [] body

type request_type =
    UID
  | Sequence

let fetch_messages s ~folder ~request ~req_type ?(modseq = Modseq.zero) ?mapping ?(start_uid = Uid.zero) ~imapset () =
  let request = if List.mem Uid request then request else Uid :: request in
  (* FIXME MboxMailWorkaround *)

  let needs_flags = ref (List.mem Flags (request : messages_request_kind list)) in
  let needs_gmail_labels = ref (List.mem (GmailLabels : messages_request_kind) request) in
  let needs_gmail_thread_id = ref (List.mem (GmailThreadID : messages_request_kind) request) in
  let needs_gmail_message_id = ref (List.mem (GmailMessageID : messages_request_kind) request) in
  let needs_body = ref (List.mem Structure request) in

  let rec loop acc headers = function
      [] ->
        List.rev acc, List.rev headers
    | Uid :: rest ->
        loop (FETCH_ATT_UID :: acc) headers rest
    | Flags :: rest ->
        loop (FETCH_ATT_FLAGS :: acc) headers rest
    | GmailLabels :: rest ->
        loop (ImapCommands.XGmExt1.fetch_att_xgmlabels :: acc) headers rest
    | GmailThreadID :: rest ->
        loop (ImapCommands.XGmExt1.fetch_att_xgmthrid :: acc) headers rest
    | GmailMessageID :: rest ->
        loop (ImapCommands.XGmExt1.fetch_att_xgmmsgid :: acc) headers rest
    | FullHeaders :: rest ->
        loop acc
          ("Date" :: "Subject" :: "From" :: "Sender" :: "Reply-To" ::
           "To" :: "Cc" :: "Message-ID" :: "References" :: "In-Reply-To" :: headers)
          rest
    | Headers :: rest ->
        loop (FETCH_ATT_ENVELOPE :: acc) ("References" :: headers) rest
    | HeaderSubject :: rest ->
        loop (FETCH_ATT_ENVELOPE :: acc) ("References" :: "Subject" :: headers) rest
    | Size :: rest ->
        loop (FETCH_ATT_RFC822_SIZE :: acc) headers rest
    | Structure :: rest ->
        loop (FETCH_ATT_BODYSTRUCTURE :: acc) headers rest
    | InternalDate :: rest ->
        loop (FETCH_ATT_INTERNALDATE :: acc) headers rest
    | ExtraHeaders extra :: rest ->
        loop acc (extra @ headers) rest
  in
  let fetch_atts, headers = loop [] [] request in

  let needs_header = List.length headers > 0 in

  let fetch_atts =
    if needs_header then
      FETCH_ATT_BODY_PEEK_SECTION
        (Some (SECTION_SPEC_SECTION_MSGTEXT (SECTION_MSGTEXT_HEADER_FIELDS headers)), None) :: fetch_atts
    else
      fetch_atts
  in

  let fetch_type = FETCH_TYPE_FETCH_ATT_LIST fetch_atts in

  let msg_att_handler msg_att =
    let flags = ref [] in
    let uid = ref Uid.zero in
    let size = ref 0 in
    let gmail_labels = ref [] in
    let gmail_message_id = ref Gmsgid.zero in
    let gmail_thread_id = ref Gthrid.zero in
    let mod_seq_value = ref Modseq.zero in
    let internal_date = ref 0. in
    let main_part = ref None in
    let envelope = ref None in
    let extra_headers = ref M.empty in

    let handle_msg_att_item = function
        MSG_ATT_ITEM_DYNAMIC flags' ->
          flags := flags_from_lep_att_dynamic flags';
          needs_flags := false
      | MSG_ATT_ITEM_STATIC (MSG_ATT_UID uid') ->
          uid := uid'
      | MSG_ATT_ITEM_STATIC (MSG_ATT_ENVELOPE env) ->
          envelope := Some (import_imap_envelope env);
      | MSG_ATT_ITEM_STATIC (MSG_ATT_BODYSTRUCTURE body) ->
          main_part := Some (import_imap_body body);
          needs_body := false;
      | MSG_ATT_ITEM_STATIC (MSG_ATT_RFC822_SIZE size') ->
          size := size'
      | MSG_ATT_ITEM_STATIC (MSG_ATT_INTERNALDATE dt) ->
          internal_date := ImapUtils.internal_date_of_imap_date dt
      | MSG_ATT_ITEM_EXTENSION (ImapCommands.Condstore.MSG_ATT_MODSEQ mod_seq_value') ->
          mod_seq_value := mod_seq_value'
      | MSG_ATT_ITEM_EXTENSION (ImapCommands.XGmExt1.MSG_ATT_XGMLABELS gmail_labels') ->
          gmail_labels := gmail_labels';
          needs_gmail_labels := false
      | MSG_ATT_ITEM_EXTENSION (ImapCommands.XGmExt1.MSG_ATT_XGMMSGID gmail_message_id') ->
          gmail_message_id := gmail_message_id';
          needs_gmail_message_id := false
      | MSG_ATT_ITEM_EXTENSION (ImapCommands.XGmExt1.MSG_ATT_XGMTHRID gmail_thread_id') ->
          gmail_thread_id := gmail_thread_id';
          needs_gmail_thread_id := false
      | MSG_ATT_ITEM_STATIC (MSG_ATT_BODY_SECTION
                          {sec_section = Some (SECTION_SPEC_SECTION_MSGTEXT t); sec_body_part = sl})
      | MSG_ATT_ITEM_STATIC (MSG_ATT_BODY_SECTION
                          {sec_section =
                             Some (SECTION_SPEC_SECTION_PART (_, Some (SECTION_TEXT_MSGTEXT t)));
                           sec_body_part = sl}) ->
          begin
            match ImapParser.(run_string (rep imf_field) sl) with
            | Some fields ->
                extra_headers := List.fold_left (fun hdrs (h, v) -> M.add h v hdrs) !extra_headers fields
            | None ->
                ()
          end
      | _ ->
          (* TODO *)
          ()
    in

    List.iter handle_msg_att_item (fst msg_att);

    (* if !needs_flag || !needs_gmail_labels || !needs_gmail_message_id then assert false *)

    { uid = !uid; size = !size; mod_seq_value = !mod_seq_value;
      gmail_labels = !gmail_labels; gmail_message_id = !gmail_message_id;
      gmail_thread_id = !gmail_thread_id; flags = !flags; internal_date = !internal_date;
      main_part = !main_part; envelope = !envelope; extra_headers = !extra_headers }
  in

  let vanished = ref None in

  lwt result =
    Session.with_folder s folder begin fun ci ->
      match req_type, modseq = Modseq.zero, ci.Conn.condstore_enabled, ci.Conn.qresync_enabled with
        UID, false, true, _ ->
          Conn.run (ImapCommands.Condstore.uid_fetch_changedsince imapset modseq fetch_type) ci
      | UID, false, _, true ->
          lwt r, v = Conn.run (ImapCommands.QResync.uid_fetch_qresync imapset fetch_type modseq) ci in
          vanished := Some v;
          Lwt.return r
      | UID, true, _, _ ->
          Conn.run (ImapCommands.uid_fetch imapset fetch_type) ci
      | Sequence, false, _, true ->
          lwt r, v = Conn.run (ImapCommands.QResync.fetch_qresync imapset fetch_type modseq) ci in
          vanished := Some v;
          Lwt.return r
      | Sequence, false, true, _ ->
          Conn.run (ImapCommands.Condstore.fetch_changedsince imapset modseq fetch_type) ci
      | Sequence, true, _, _ ->
          Conn.run (ImapCommands.fetch imapset fetch_type) ci
      | _, false, false, false ->
          assert_lwt false
    end (handle_imap_error Fetch)
  in
  let modified_or_added_messages = List.map msg_att_handler result in
  let vanished_messages = match !vanished with
      None -> IndexSet.empty
    | Some v -> IndexSet.of_imap_set v.ImapCommands.QResync.qr_known_uids
  in
  Lwt.return { vanished_messages; modified_or_added_messages }

let fetch_messages_by_uid s ~folder ~request ~uids =
  let imapset = IndexSet.to_imap_set uids in
  lwt sr = fetch_messages s ~folder ~request ~req_type:UID ~imapset () in
  Lwt.return sr.modified_or_added_messages

let fetch_messages_by_number s ~folder ~request ~seqs =
  let imapset = IndexSet.to_imap_set seqs in
  lwt sr = fetch_messages s ~folder ~request ~req_type:Sequence ~imapset () in
  Lwt.return sr.modified_or_added_messages

let fetch_message_by_uid s ~folder ~uid =
  let fetch_type = FETCH_TYPE_FETCH_ATT (FETCH_ATT_BODY_PEEK_SECTION (None, None)) in
  let extract_body = function
      (result, _) :: [] ->
        let rec loop = function
            [] ->
              assert false
          | MSG_ATT_ITEM_STATIC (MSG_ATT_BODY_SECTION {sec_body_part}) :: _ ->
              sec_body_part
          | _ :: rest ->
              loop rest
        in
        Lwt.return (loop result)
    | _ ->
        raise_lwt (Error Fetch)
        (* assert false *)
  in
  lwt result =
    Session.with_folder s folder
      (Conn.run (ImapCommands.uid_fetch (ImapSet.single uid) fetch_type))
      (handle_imap_error Fetch)
  in
  extract_body result

let fetch_number_uid_mapping s ~folder ~from_uid ~to_uid =
  let result = Hashtbl.create 0 in
  let imap_set = ImapSet.interval from_uid to_uid in
  let fetch_type = FETCH_TYPE_FETCH_ATT FETCH_ATT_UID in
  let rec extract_uid = function
      [] -> ()
    | (att_item, att_number) :: rest ->
        let rec loop = function
            [] ->
              extract_uid rest
          | MSG_ATT_ITEM_STATIC (MSG_ATT_UID uid) :: _ ->
              if Uid.compare uid from_uid >= 0 then Hashtbl.add result att_number uid;
              extract_uid rest
          | _ :: rest ->
              loop rest
        in
        loop att_item
  in
  lwt fetch_result =
    Session.with_folder s folder
      (Conn.run (ImapCommands.uid_fetch imap_set fetch_type))
      (handle_imap_error Fetch)
  in
  extract_uid fetch_result;
  Lwt.return result

let imap_date_of_date t =
  let tm = Unix.localtime t in
  (tm.Unix.tm_mday, tm.Unix.tm_mon + 1, tm.Unix.tm_year + 1900)

let rec imap_search_key_from_search_key = function
    All                 -> SEARCH_KEY_ALL
  | From str            -> SEARCH_KEY_FROM str
  | To str              -> SEARCH_KEY_TO str
  | Cc str              -> SEARCH_KEY_CC str
  | Bcc str             -> SEARCH_KEY_BCC str
  | Recipient str       -> SEARCH_KEY_OR (SEARCH_KEY_TO str, SEARCH_KEY_OR (SEARCH_KEY_CC str, SEARCH_KEY_BCC str))
  | Subject str         -> SEARCH_KEY_SUBJECT str
  | Content str         -> SEARCH_KEY_TEXT str
  | Body str            -> SEARCH_KEY_BODY str
  | UIDs imapset        -> SEARCH_KEY_INSET imapset
  | Header (k, v)       -> SEARCH_KEY_HEADER (k, v)
  | Read                -> SEARCH_KEY_SEEN
  | Unread              -> SEARCH_KEY_UNSEEN
  | Flagged             -> SEARCH_KEY_FLAGGED
  | Unflagged           -> SEARCH_KEY_UNFLAGGED
  | Answered            -> SEARCH_KEY_ANSWERED
  | Unanswered          -> SEARCH_KEY_UNANSWERED
  | Draft               -> SEARCH_KEY_DRAFT
  | Undraft             -> SEARCH_KEY_UNDRAFT
  | Deleted             -> SEARCH_KEY_DELETED
  | Spam                -> SEARCH_KEY_KEYWORD "Junk"
  | BeforeDate t        -> SEARCH_KEY_SENTBEFORE (imap_date_of_date t)
  | OnDate t            -> SEARCH_KEY_SENTON (imap_date_of_date t)
  | SinceDate t         -> SEARCH_KEY_SENTSINCE (imap_date_of_date t)
  | BeforeReceiveDate t -> SEARCH_KEY_BEFORE (imap_date_of_date t)
  | OnReceiveDate t     -> SEARCH_KEY_ON (imap_date_of_date t)
  | SinceReceiveDate t  -> SEARCH_KEY_SINCE (imap_date_of_date t)
  | SizeLarger n        -> SEARCH_KEY_LARGER n
  | SizeSmaller n       -> SEARCH_KEY_SMALLER n
  | GmailThreadID id    -> SEARCH_KEY_XGMTHRID id
  | GmailMessageID id   -> SEARCH_KEY_XGMMSGID id
  | GmailRaw str        -> SEARCH_KEY_XGMRAW str
  | Or (k1, k2)         -> SEARCH_KEY_OR (imap_search_key_from_search_key k1, imap_search_key_from_search_key k2)
  | And (k1, k2)        -> SEARCH_KEY_AND (imap_search_key_from_search_key k1, imap_search_key_from_search_key k2)
  | Not k               -> SEARCH_KEY_NOT (imap_search_key_from_search_key k)

let search s ~folder ~key =
  (* let charset =  FIXME yahoo *)
  let key = imap_search_key_from_search_key key in
  lwt result_list =
    Session.with_folder s folder (Conn.run (ImapCommands.uid_search key))
      (handle_imap_error Fetch)
  in
  let result = List.fold_left (fun s n -> UidSet.add n s) UidSet.empty result_list in
  Lwt.return result

let store_flags s ~folder ~uids ~kind ~flags ?(customflags = []) () =
  let imap_flag_of_flag = function
      Seen          -> FLAG_SEEN
    | Answered      -> FLAG_ANSWERED
    | Flagged       -> FLAG_FLAGGED
    | Deleted       -> FLAG_DELETED
    | Draft         -> FLAG_DRAFT
    | MDNSent       -> FLAG_KEYWORD "$MDNSent"
    | Forwarded     -> FLAG_KEYWORD "$Forwarded"
    | SubmitPending -> FLAG_KEYWORD "$SubmitPending"
    | Submitted     -> FLAG_KEYWORD "$Submitted"
  in
  let imap_flags = List.map (fun fl -> FLAG_KEYWORD fl) customflags in
  let imap_flags = List.fold_left (fun l fl -> imap_flag_of_flag fl :: l) imap_flags flags in
  let store_att_flags = { fl_sign = kind; fl_silent = true; fl_flag_list = imap_flags } in
  Session.with_folder s folder (Conn.run (ImapCommands.uid_store uids store_att_flags))
    (handle_imap_error Store)

let add_flags s ~folder ~uids ~flags ?customflags () =
  let uids = UidSet.to_imap_set uids in
  store_flags s ~folder ~uids ~kind:STORE_ATT_FLAGS_ADD ~flags ?customflags ()

let remove_flags s ~folder ~uids ~flags ?customflags () =
  let uids = UidSet.to_imap_set uids in
  store_flags s ~folder ~uids ~kind:STORE_ATT_FLAGS_REMOVE ~flags ?customflags ()

let set_flags s ~folder ~uids ~flags ?customflags () =
  let uids = UidSet.to_imap_set uids in
  store_flags s ~folder ~uids ~kind:STORE_ATT_FLAGS_SET ~flags ?customflags ()

let store_labels s ~folder ~uids ~kind ~labels =
  Session.with_folder s folder
    (Conn.run (ImapCommands.XGmExt1.uid_store_xgmlabels uids kind true labels))
    (handle_imap_error Store)

let add_labels s ~folder ~uids ~labels =
  let uids = UidSet.to_imap_set uids in
  store_labels s ~folder ~uids ~kind:STORE_ATT_FLAGS_ADD ~labels

let remove_labels s ~folder ~uids ~labels =
  let uids = UidSet.to_imap_set uids in
  store_labels s ~folder ~uids ~kind:STORE_ATT_FLAGS_REMOVE ~labels

let set_labels s ~folder ~uids ~labels =
  let uids = UidSet.to_imap_set uids in
  store_labels s ~folder ~uids ~kind:STORE_ATT_FLAGS_SET ~labels

let capability s =
  lwt caps =
    Session.with_connected s begin fun ci ->
      lwt caps = Conn.run ImapCommands.capability ci in
      (* lwt () = cache_capabilities s in (\* FIXME refactor *\) *)
      Lwt.return caps
    end (handle_imap_error Capability)
  in
  Lwt.return (capabilities_of_imap_capabilities caps)

let identity s client_id =
  let client_id = List.map (fun (k, v) -> (k, Some v)) client_id in
  lwt server_id =
    Session.with_connected s
      (Conn.run (ImapCommands.Id.id client_id))
      (handle_imap_error Identity)
  in
  Lwt.return (List.map (function (k, None) -> (k, "") | (k, Some v) -> (k, v)) server_id)

(* let uid_next s = *)
(*   match s.state with *)
(*     SELECTED (_, si) -> *)
(*       si.uid_next *)
(*   | _ -> *)
(*       invalid_arg "uid_next" *)

(* let uid_validity s = *)
(*   match s.state with *)
(*     SELECTED (_, si) -> *)
(*       si.uid_validity *)
(*   | _ -> *)
(*       invalid_arg "uid_validity" *)

(* let mod_sequence_value s = *)
(*   match s.state with *)
(*     SELECTED (_, si) -> *)
(*       si.mod_sequence_value *)
(*   | _ -> *)
(*       invalid_arg "mod_sequence_value" *)

let idle s ~folder ?(last_known_uid = Uid.zero) () =
  let waiter, waker = Lwt.task () in
  let t =
    lwt msgs =
      if Uid.compare Uid.zero last_known_uid = 0 then
        Lwt.return_nil
      else
        fetch_messages_by_uid s ~folder ~request:[] ~uids:(UidSet.from last_known_uid)
    in
    if List.length msgs > 0 then
      Lwt.return_unit
    else
      Session.with_folder s folder begin fun ci ->
        lwt () = Conn.run ImapCommands.Idle.idle_start ci in
        ci.Conn.idling <- Some waker;
        try_lwt
          lwt () = Lwt.pick [ Conn.wait_read ci; Lwt_unix.sleep (29. *. 60.); waiter ] in
          Conn.run ImapCommands.Idle.idle_done ci
        finally
          ci.Conn.idling <- None;
          Lwt.return_unit
      end (handle_imap_error Idle)
  in
  t, waker
