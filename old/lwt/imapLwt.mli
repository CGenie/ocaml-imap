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

(** The type of index sets, e.g., sets of UIDs or Sequence Numbers. *)
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

(** The type of IMAP numbers such as UIDs, Sequence numbers, Gmail message IDs,
    MODSEQs, etc. *)
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

module Uid : Num
module UidSet : IndexSet with type elt = Uid.t
module Seq : Num
module SeqSet : IndexSet with type elt = Seq.t

module Modseq : Num
module Gmsgid : Num (** Gmail message id *)
module Gthrid : Num (** Gmail thread id *)

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
  | Recipient of string (* Recipient is the combination of To, Cc and Bcc *)
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

module M : Map.S with type key = string

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

exception Error of error

type session

val create_session :
  ?max_connections:int ->
  ?conn_type:connection_type ->
  ?port:int ->
  host:string ->
  username:string ->
  password:string ->
  unit -> session
    (** Creates a new IMAP session. The session will open up to
        [max_connections] concurrent connections to the IMAP server, but never
        more than one to a single folder. *)

val logout :
  session -> unit Lwt.t
    (** Disconnects from the server. *)

val folder_status :
  session ->
  folder:string -> folder_status Lwt.t
    (** Returns folder status info (like UIDNext, Unseen, ...) *)

val noop :
  session -> unit Lwt.t
    (** Performs a No-Op operation on the IMAP server. *)

val fetch_all_folders :
  session -> folder list Lwt.t
    (** Gets all folders. *)

val rename_folder :
  session ->
  folder:string ->
  new_name:string -> unit Lwt.t
    (** Renames a folder. *)

val delete_folder :
  session ->
  folder:string -> unit Lwt.t
    (** Deletes a folder. *)

val create_folder :
  session ->
  folder:string -> unit Lwt.t
    (** Creates a new folder. *)

val append_message :
  session ->
  folder:string ->
  message:string ->
  ?customflags:string list ->
  flags:message_flag list -> Uid.t Lwt.t
    (** Upload a message. *)

val subscribe_folder :
  session ->
  folder:string -> unit Lwt.t
    (** Subscribe to a folder. *)

val unsubscribe_folder :
  session ->
  folder:string -> unit Lwt.t
    (** Unsubscribe to a folder. *)

val copy_messages :
  session ->
  folder:string ->
  uids:ImapSet.t ->
  dest:string ->
  (Uid.t, Uid.t) Hashtbl.t Lwt.t
    (** Copy messages between two folders.  Returns the mapping between old UIDs
        and new UIDs. *)

val expunge_folder :
  session ->
  folder:string -> unit Lwt.t
    (** Expunges (deletes trashed messages) a folder. *)

val fetch_messages_by_uid :
  session ->
  folder:string ->
  request:messages_request_kind list ->
  uids:UidSet.t ->
  message list Lwt.t
    (** Fetches message information given their UIDs. *)

val fetch_messages_by_number :
  session ->
  folder:string ->
  request:messages_request_kind list ->
  seqs:SeqSet.t ->
  message list Lwt.t
    (** Fetches message information given their sequence numbers. *)

val fetch_message_by_uid :
  session ->
  folder:string ->
  uid:Uid.t -> string Lwt.t
    (** Fetch the raw contents of a message given its UID. *)

val fetch_number_uid_mapping :
  session ->
  folder:string ->
  from_uid:Uid.t ->
  to_uid:Uid.t ->
  (Seq.t, Uid.t) Hashtbl.t Lwt.t

val search :
  session ->
  folder:string ->
  key:search_key -> UidSet.t Lwt.t
    (** Search for messages satisfying [key].  Returns the UIDs of matching
        messages. *)

val add_flags :
  session ->
  folder:string ->
  uids:UidSet.t ->
  flags:message_flag list ->
  ?customflags:string list ->
  unit -> unit Lwt.t
    (** Add message flags. *)

val remove_flags :
  session ->
  folder:string ->
  uids:UidSet.t ->
  flags:message_flag list ->
  ?customflags:string list ->
  unit -> unit Lwt.t
    (** Remove message flags. *)

val set_flags :
  session ->
  folder:string ->
  uids:UidSet.t ->
  flags:message_flag list ->
  ?customflags:string list ->
  unit -> unit Lwt.t
    (** Set message flags. *)

val add_labels :
  session ->
  folder:string ->
  uids:UidSet.t ->
  labels:string list -> unit Lwt.t
    (** Add Gmail labels. *)

val remove_labels :
  session ->
  folder:string ->
  uids:UidSet.t ->
  labels:string list -> unit Lwt.t
    (** Remove Gmail labels. *)

val set_labels :
  session ->
  folder:string ->
  uids:UidSet.t ->
  labels:string list -> unit Lwt.t
    (** Sets Gmail labels. *)

val capability :
  session -> capability list Lwt.t
    (** Requests capabilities of the server. *)

val identity :
  session ->
  (string * string) list -> (string * string) list Lwt.t
    (** Sends client ID and returns server ID.  Requires ID extension. *)

val idle :
  session ->
  folder:string ->
  ?last_known_uid:Uid.t ->
  unit -> unit Lwt.t * unit Lwt.u
    (** Start IDLEing.  Returns [(t, u)], where [t] will wait until there
        something is received from the server, and [u] can be used to stop the
        IDLEing prematurely.  Requires IDLE extension. *)
