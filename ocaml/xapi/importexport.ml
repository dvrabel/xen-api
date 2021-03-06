(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
(** Common definitions and functions shared between the import and export code.
 * @group Import and Export
 *)

(** Represents a database record (the reference gets converted to a small string) *)
type obj = { cls: string; id: string; snapshot: XMLRPC.xmlrpc }

(** Version information attached to each export and checked on import *)
type version = 
    { hostname: string;
      date: string;
      product_version: string;
      product_brand: string;
      build_number: string;
      xapi_vsn_major: int;
      xapi_vsn_minor: int;
      export_vsn: int; (* 0 if missing, indicates eg whether to expect sha1sums in the stream *)
    }

(** An exported VM has a header record: *)
type header = 
    { version: version;
      objects: obj list }

exception Version_mismatch of string

module D=Debug.Debugger(struct let name="importexport" end)
open D

let find kvpairs where x = 
    if not(List.mem_assoc x kvpairs) 
    then raise (Failure (Printf.sprintf "Failed to find key '%s' in %s" x where))
    else List.assoc x kvpairs 

let string_of_obj x = x.cls ^ "  " ^ x.id

let _class = "class"
let _id = "id"
let _snapshot = "snapshot"

let xmlrpc_of_obj x = XMLRPC.To.structure
  [ _class,    XMLRPC.To.string x.cls;
    _id,       XMLRPC.To.string x.id;
    _snapshot, x.snapshot ]

let obj_of_xmlrpc x = 
  let kvpairs = XMLRPC.From.structure x in
  let find = find kvpairs "object data" in
  { cls      = XMLRPC.From.string (find _class);
    id       = XMLRPC.From.string (find _id);
    snapshot = find _snapshot }

(** Return a version struct corresponding to this host *)
let this_version __context = 
  let host = Helpers.get_localhost ~__context in
  let (_: API.host_t) = Db.Host.get_record ~__context ~self:host in  
  { hostname = Version.hostname;
    date = Version.date;
    product_version = Version.product_version;
    product_brand = Version.product_brand;
    build_number = Version.build_number;
    xapi_vsn_major = Xapi_globs.version_major;
    xapi_vsn_minor = Xapi_globs.version_minor;
    export_vsn = Xapi_globs.export_vsn;
  }

(** Raises an exception if a prospective import cannot be handled by this code.
    This will get complicated over time... *)
let assert_compatable ~__context other_version = 
  let this_version = this_version __context in
  let error() = 
    error "Import version is incompatible";
    raise (Api_errors.Server_error(Api_errors.import_incompatible_version, [])) in
  (* error if major versions differ; also error if this host has a
     lower minor vsn than the import *)
  if this_version.xapi_vsn_major<>other_version.xapi_vsn_major || this_version.xapi_vsn_minor<other_version.xapi_vsn_minor then
    error()

open Xapi_globs
let xmlrpc_of_version x =
  XMLRPC.To.structure
    [ _hostname,        XMLRPC.To.string x.hostname;
      _date,            XMLRPC.To.string x.date;
      _product_version, XMLRPC.To.string x.product_version;
      _product_brand,   XMLRPC.To.string x.product_brand;
      _build_number,    XMLRPC.To.string x.build_number;
      _xapi_major,      XMLRPC.To.string (string_of_int Xapi_globs.version_major);
      _xapi_minor,      XMLRPC.To.string (string_of_int Xapi_globs.version_minor);
      _export_vsn,      XMLRPC.To.string (string_of_int Xapi_globs.export_vsn);
    ]

exception Failure of string
let version_of_xmlrpc x = 
  let kvpairs = XMLRPC.From.structure x in
  let find = find kvpairs "version data" in
  { hostname        = XMLRPC.From.string (find _hostname);
    date            = XMLRPC.From.string (find _date);
    product_version = XMLRPC.From.string (find _product_version);
    product_brand   = XMLRPC.From.string (find _product_brand);
    build_number    = XMLRPC.From.string (find _build_number);
    xapi_vsn_major  = int_of_string (XMLRPC.From.string (find _xapi_major));
    xapi_vsn_minor  = int_of_string (XMLRPC.From.string (find _xapi_minor));
    export_vsn      = try int_of_string (XMLRPC.From.string (find _export_vsn)) with _ -> 0;
  }

let _version = "version"
let _objects = "objects"

let xmlrpc_of_header x = 
  XMLRPC.To.structure
    [ _version, xmlrpc_of_version x.version;
      _objects,   XMLRPC.To.array (List.map xmlrpc_of_obj x.objects);
    ]

let header_of_xmlrpc x = 
  let kvpairs = XMLRPC.From.structure x in
  let find = find kvpairs "contents data" in
  { version = version_of_xmlrpc (find _version);
    objects   = XMLRPC.From.array obj_of_xmlrpc (find _objects);
  }

(* This function returns true when the VM record was created pre-ballooning. *)
let vm_exported_pre_dmc (x: obj) = 
  let structure = XMLRPC.From.structure x.snapshot in
  (* The VM.parent field was added in rel_midnight_ride, at the same time as ballooning.
     XXX: Replace this with something specific to the ballooning feature if possible. *)
  not(List.mem_assoc "parent" structure)

open Client

(** HTTP header type used for streaming binary data *)
let content_type = Http.Hdr.content_type ^ ": application/octet-stream"

let xmlrpc_of_checksum_table table = API.To.string_to_string_map table
let checksum_table_of_xmlrpc xml = API.From.string_to_string_map "" xml

let compare_checksums a b = 
  let success = ref true in
  List.iter (fun (filename, csum) ->
	       if List.mem_assoc filename b 
	       then (let expected = List.assoc filename b in
		     if csum <> expected
		     then begin
		       error "File %s checksum mismatch (%s <> %s)" filename csum expected;
		       success := false
		     end
		     else debug "File %s checksum ok (%s = %s)" filename csum expected;
		    ) 
	       else begin 
		 error "Missing checksum for file %s (expected %s)" filename csum;
		 success := false;
	       end) a;
  !success

let get_default_sr rpc session_id = 
  let pool = List.hd (Client.Pool.get_all rpc session_id) in
  let sr = Client.Pool.get_default_SR rpc session_id pool in
  try ignore(Client.SR.get_uuid rpc session_id sr); sr 
  with _ -> raise (Api_errors.Server_error(Api_errors.default_sr_not_found, [ Ref.string_of sr ]))

(** Check that the SR is visible on the specified host *) 
let check_sr_availability_host ~__context sr host =
  try 
    ignore(Xapi_vm_helpers.assert_can_see_specified_SRs ~__context ~reqd_srs:[sr] ~host);
    true
  with _ -> false
    
let check_sr_availability ~__context sr =
  let localhost = Helpers.get_localhost ~__context in
  check_sr_availability_host ~__context sr localhost
    
let find_host_for_sr ~__context sr =
  let choose_fn ~host = 
    Xapi_vm_helpers.assert_can_see_specified_SRs ~__context ~reqd_srs:[sr] ~host in
    Xapi_vm_helpers.choose_host ~__context ~choose_fn ()

let check_vm_host_SRs ~__context vm host =
  try 
    Xapi_vm_helpers.assert_can_see_SRs ~__context ~self:vm ~host;
    Xapi_vm_helpers.assert_host_is_live ~__context ~host;
    true
  with 
      _ -> false 

let find_host_for_VM ~__context vm =
  Xapi_vm_helpers.choose_host ~__context ~vm:vm ~choose_fn:(Xapi_vm_helpers.assert_can_see_SRs ~__context ~self:vm) ()

(* On any import error, we try to cleanup the bits we have created *)
type cleanup_stack = (Context.t -> (Xml.xml -> Xml.xml) -> API.ref_session -> unit) list

let cleanup (x: cleanup_stack) = 
  (* Always perform the cleanup with a fresh login + context to prevent problems with
     any user-supplied one being invalidated *)
  Server_helpers.exec_with_new_task "VM.import (cleanup)" ~task_in_database:true
    (fun __context ->
       Helpers.call_api_functions ~__context
	 (fun rpc session_id ->
	    List.iter (fun action -> 
			 Helpers.log_exn_continue "executing cleanup action" (action __context rpc) session_id) x
	 )
    )

