open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

let prefix = "create"
let raise_errorf = Ppx_deriving.raise_errorf

let find_main labels =
  List.fold_left (fun (main, labels) ({ pld_type; pld_loc } as label) ->
    match Ppx_deriving.attr ~prefix "main" pld_type.ptyp_attributes with
    | Some (_, PStr []) ->
      begin match main with
      | Some _ -> raise_errorf ~loc:pld_loc "Duplicate [@deriving.%s.main] annotation" prefix
      | None -> Some label, labels
      end
    | Some ({ loc }, _) -> raise_errorf ~loc "Invalid [@deriving.%s.main] syntax" prefix
    | None -> main, label :: labels)
    (None, []) labels

let str_of_type ~options ~path ({ ptype_loc = loc } as type_decl) =
  let mapper =
    match type_decl.ptype_kind with
    | Ptype_record labels ->
      let fields =
        labels |> List.map (fun { pld_name = { txt = name; loc } } ->
          name, evar name) in
      let main, labels = find_main labels in
      let fn =
        match main with
        | Some { pld_name = { txt = name }} ->
          Exp.fun_ "" None (pvar name) (record fields)
        | None ->
          Exp.fun_ "" None (punit ()) (record fields)
      in
      List.fold_left (fun accum { pld_name = { txt = name }; pld_type } ->
        match Ppx_deriving.attr ~prefix "default" pld_type.ptyp_attributes with
        | Some (_, PStr [{ pstr_desc = Pstr_eval (default, _) }]) ->
          Exp.fun_ ("?"^name) (Some default) (pvar name) accum
        | Some ({ loc }, _) -> raise_errorf ~loc "Invalid [@deriving.%s.default] syntax" prefix
        | None ->
        match pld_type with
        | [%type: [%t? _] list] ->
          Exp.fun_ ("?"^name) (Some [%expr []]) (pvar name) accum
        | [%type: [%t? _] option] ->
          Exp.fun_ ("?"^name) None (pvar name) accum
        | _ -> Exp.fun_ name None (pvar name) accum)
        fn labels
    | _ -> raise_errorf ~loc "Can only derive %s for record types" prefix
  in
  [Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Prefix prefix) type_decl)) mapper]

let wrap_predef_option typ =
  let predef_option = mknoloc (Ldot (Lident "*predef*", "option")) in
  Typ.constr predef_option [typ]

let sig_of_type ~options ~path ({ ptype_loc = loc } as type_decl) =
  let typ = Ppx_deriving.core_type_of_type_decl type_decl in
  let typ =
    match type_decl.ptype_kind with
    | Ptype_record labels ->
      let main, labels = find_main labels in
      let typ =
        match main with
        | Some { pld_name = { txt = name }; pld_type } ->
          Typ.arrow "" pld_type typ
        | None ->
          Typ.arrow "" (tconstr "unit" []) typ
      in
      List.fold_left (fun accum { pld_name = { txt = name; loc }; pld_type } ->
        match Ppx_deriving.attr ~prefix "default" pld_type.ptyp_attributes with
        | Some (_, PStr _)  -> Typ.arrow ("?"^name) (wrap_predef_option pld_type) accum
        | Some ({ loc }, _) -> raise_errorf ~loc "Invalid [@deriving.%s.default] syntax" prefix
        | None ->
        match pld_type with
        | [%type: [%t? _] list] ->
          Typ.arrow ("?"^name) (wrap_predef_option pld_type) accum
        | [%type: [%t? opt] option] ->
          Typ.arrow ("?"^name) (wrap_predef_option opt) accum
        | _ -> Typ.arrow name pld_type accum)
        typ labels
    | _ -> raise_errorf ~loc "Can only derive %s for record types" prefix
  in
  [Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix prefix) type_decl)) typ)]

let () =
  Ppx_deriving.(register prefix {
    core_type = None;
    structure = (fun ~options ~path type_decls ->
      [Str.value Nonrecursive (List.concat (List.map (str_of_type ~options ~path) type_decls))]);
    signature = (fun ~options ~path type_decls ->
      List.concat (List.map (sig_of_type ~options ~path) type_decls));
  })