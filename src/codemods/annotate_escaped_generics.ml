(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
open Loc_collections

module SymbolMap = WrappedMap.Make (struct
  type t = Ty_symbol.symbol

  let compare = Stdlib.compare
end)

let norm_opts = Ty_normalizer_env.default_options

(* Change the name of the symbol to avoid local aliases *)
let localize (str : string) = Printf.sprintf "$IMPORTED$_%s" str

let localize_type =
  let remote_syms = ref SymbolMap.empty in
  let localize_symbol symbol =
    match symbol.Ty.sym_provenance with
    | Ty.Remote { Ty.imported_as = None } ->
      let local_name = localize symbol.Ty.sym_name in
      Utils_js.print_endlinef "local_name: %s" local_name;
      let sym_provenance =
        Ty.Remote { Ty.imported_as = Some (ALoc.none, local_name, Ty.TypeMode) }
      in
      let imported = { symbol with Ty.sym_provenance; sym_name = local_name } in
      remote_syms := SymbolMap.add symbol imported !remote_syms;
      imported
    | _ -> symbol
  in
  let o =
    object (_self)
      inherit [_] Ty.endo_ty

      method! on_symbol _env s =
        Utils_js.print_endlinef "Localizing symbol: %s" (Ty_debug.dump_symbol s);
        localize_symbol s
    end
  in
  fun ty ->
    remote_syms := SymbolMap.empty;
    let ty' = o#on_t () ty in
    (ty', !remote_syms)

let remote_symbols_map tys =
  List.fold_left
    (fun acc ty ->
      Ty_utils.symbols_of_type ty
      |> List.fold_left
           (fun a symbol ->
             let { Ty.sym_provenance; sym_name; sym_anonymous; _ } = symbol in
             match sym_provenance with
             | Ty.Remote { Ty.imported_as = None } when not sym_anonymous ->
               (* Anonymous symbols will cause errors to the serializer.
                * Discard them here as well. *)
               let local_alias =
                 {
                   Ty.sym_provenance = Ty.Local;
                   sym_def_loc = ALoc.none;
                   sym_anonymous;
                   sym_name = localize sym_name;
                 }
               in
               Utils_js.print_endlinef "Localizing: %s" local_alias.Ty.sym_name;
               SymbolMap.add symbol local_alias a
             | _ -> a)
           acc)
    SymbolMap.empty
    tys

let gen_import_statements file (symbols : Ty_symbol.symbol SymbolMap.t) =
  let dummy_loc = Loc.none in
  let raw_from_string (str : string) = Printf.sprintf "%S" str in
  let gen_import_statement remote_symbol local_symbol =
    let { Ty.sym_def_loc = remote_loc; sym_name = remote_name; _ } = remote_symbol in
    let { Ty.sym_name = local_name; _ } = local_symbol in
    let remote_source = ALoc.source remote_loc in
    let remote_source =
      match remote_source with
      | Some remote_source -> remote_source
      | None -> failwith "No source"
    in
    Hh_logger.debug "remote source %s" (File_key.to_string file);

    let { Module_heaps.module_name; _ } =
      let reader = State_reader.create () in
      Module_heaps.Reader.get_info_unsafe ~reader ~audit:Expensive.warn remote_source
    in
    (* Relativize module name *)
    let module_name =
      match module_name with
      | Modulename.String s -> s
      | Modulename.Filename f ->
        let f = File_key.to_string f in
        let dir = Filename.dirname (File_key.to_string file) in
        Filename.concat "./" (Files.relative_path dir f)
    in
    let remote_name = Flow_ast_utils.ident_of_source (dummy_loc, remote_name) in
    let local_name = Flow_ast_utils.ident_of_source (dummy_loc, local_name) in
    Ast.Statement.
      ( dummy_loc,
        ImportDeclaration
          {
            ImportDeclaration.import_kind = ImportDeclaration.ImportType;
            source =
              ( dummy_loc,
                {
                  Ast.StringLiteral.value = module_name;
                  raw = raw_from_string module_name;
                  comments = None;
                } );
            default = None;
            specifiers =
              Some
                ImportDeclaration.(
                  ImportNamedSpecifiers
                    [{ kind = None; local = Some local_name; remote = remote_name }]);
            comments = None;
          } )
  in
  SymbolMap.fold (fun remote local acc -> gen_import_statement remote local :: acc) symbols []

(* Turn T[empty] into empty, if the empty came from generate-tests *)

module Normalizer = struct
  exception EmptyFound

  class simplify_empty =
    object (self)
      inherit [unit] Type_mapper.t as super

      val mutable seen = ISet.empty

      method! def_type cx map_cx t =
        let open Type in
        match t with
        | EmptyT Zeroed -> raise EmptyFound
        | _ -> super#def_type cx map_cx t

      method! type_ cx map_cx t =
        let open Type in
        match t with
        | UnionT (r, urep) ->
          let any_non_empty = ref false in
          let test_member r t =
            try
              let t = self#type_ cx map_cx t in
              any_non_empty := true;
              t
            with EmptyFound -> DefT (r, bogus_trust (), EmptyT Zeroed)
          in
          let urep' = UnionRep.ident_map (test_member r) urep in
          if not !any_non_empty then
            raise EmptyFound
          else if urep' == urep then
            t
          else
            UnionT (r, urep')
        | _ -> super#type_ cx map_cx t

      method tvar cx map_cx _r id =
        let open Constraint in
        let open Type in
        let (root_id, root) = Context.find_root cx id in
        if ISet.mem root_id seen then
          id
        else begin
          seen <- ISet.add root_id seen;

          let constraints =
            match root.constraints with
            | FullyResolved (u, t) -> FullyResolved (u, self#type_ cx map_cx t)
            | Resolved (u, t) -> Resolved (u, self#type_ cx map_cx t)
            | Unresolved bounds ->
              let any_non_empty = ref (TypeMap.cardinal bounds.lower = 0) in
              let test_member r t =
                try
                  let t = self#type_ cx map_cx t in
                  any_non_empty := true;
                  t
                with EmptyFound -> DefT (r, bogus_trust (), EmptyT Zeroed)
              in
              let lower =
                TypeMap.fold
                  (fun t tr map -> TypeMap.add (test_member (TypeUtil.reason_of_t t) t) tr map)
                  bounds.lower
                  TypeMap.empty
              in
              if not !any_non_empty then
                raise EmptyFound
              else
                Unresolved { bounds with lower }
          in
          let root = Root { root with constraints } in
          Context.add_tvar cx root_id root;
          id
        end

      (* overridden in type_ *)
      method eval_id _cx _map_cx id = id

      method props cx map_cx id =
        let props_map = Context.find_props cx id in
        let props_map' =
          SMap.ident_map (Type.Property.ident_map_t (self#type_ cx map_cx)) props_map
        in
        let id' =
          if props_map == props_map' then
            id
          (* When mapping results in a new property map, we have to use a
             generated id, rather than a location from source. *)
          else
            Context.generate_property_map cx props_map'
        in
        id'

      (* These should already be fully-resolved. *)
      method exports _cx _map_cx id = id

      method call_prop cx map_cx id =
        let t = Context.find_call cx id in
        let t' = self#type_ cx map_cx t in
        if t == t' then
          id
        else
          Context.make_call_prop cx t'

      method use_type _cx _map_cx ut = ut

      method visit cx t =
        let open Type in
        try self#type_ cx () t
        with EmptyFound -> DefT (TypeUtil.reason_of_t t, bogus_trust (), EmptyT Zeroed)
    end

  let ty_at_loc norm_opts ccx loc =
    let open Type.TypeScheme in
    let { Codemod_context.Typed.full_cx; file; file_sig; typed_ast; _ } = ccx in
    let aloc = ALoc.of_loc loc in
    match Typed_ast_utils.find_exact_match_annotation typed_ast aloc with
    | None -> Error Codemod_context.Typed.MissingTypeAnnotation
    | Some scheme ->
      let scheme = { scheme with type_ = (new simplify_empty)#visit full_cx scheme.type_ } in
      let genv = Ty_normalizer_env.mk_genv ~full_cx ~file ~file_sig ~typed_ast in
      (match Ty_normalizer.from_scheme ~options:norm_opts ~genv scheme with
      | Ok ty -> Ok ty
      | Error e -> Error (Codemod_context.Typed.NormalizationError e))
end

(* The mapper *)

module UnitStats : Insert_type_utils.BASE_STATS with type t = unit = struct
  type t = unit

  let empty = ()

  let combine _ _ = ()

  let serialize _s = []

  let report _s = []
end

module Accumulator = Insert_type_utils.Acc (UnitStats)
module Unit_Codemod_annotator = Codemod_annotator.Make (UnitStats)

let reporter =
  {
    Codemod_report.report = Codemod_report.StringReporter Accumulator.report;
    combine = Accumulator.combine;
    empty = Accumulator.empty;
  }

type accumulator = Accumulator.t

let mapper ~default_any ~preserve_literals ~max_type_size (ask : Codemod_context.Typed.t) =
  let imports_react =
    Insert_type_imports.ImportsHelper.imports_react ask.Codemod_context.Typed.file_sig
  in
  let options = ask.Codemod_context.Typed.options in
  let exact_by_default = Options.exact_by_default options in
  let metadata =
    Context.docblock_overrides ask.Codemod_context.Typed.docblock ask.Codemod_context.Typed.metadata
  in
  let { Context.strict; strict_local; _ } = metadata in
  let lint_severities =
    if strict || strict_local then
      StrictModeSettings.fold
        (fun lint_kind lint_severities ->
          LintSettings.set_value lint_kind (Severity.Err, None) lint_severities)
        (Options.strict_mode options)
        (Options.lint_severities options)
    else
      Options.lint_severities options
  in
  let suppress_types = Options.suppress_types options in
  let escape_locs =
    let cx = Codemod_context.Typed.context ask in
    let errors = Context.errors cx in
    Flow_error.ErrorSet.fold
      (fun err locs ->
        match Flow_error.msg_of_error err with
        | Error_message.EEscapedGeneric { annot_reason = Some annot_reason; _ } ->
          ALocSet.add (Reason.aloc_of_reason annot_reason) locs
        | _ -> locs)
      errors
      ALocSet.empty
  in

  object (this)
    inherit
      Unit_Codemod_annotator.mapper
        ~max_type_size
        ~exact_by_default
        ~lint_severities
        ~suppress_types
        ~imports_react
        ~preserve_literals
        ~default_any
        ask as super

    val mutable remote_symbols_map = SymbolMap.empty

    method private register_remote_symbols syms =
      remote_symbols_map <- SymbolMap.fold SymbolMap.add syms remote_symbols_map

    method private is_directive_statement (stmt : (Loc.t, Loc.t) Ast.Statement.t) =
      let open Ast.Statement in
      match stmt with
      | (_loc, Expression { Expression.directive = Some _; _ })
      | (_loc, ImportDeclaration { ImportDeclaration.import_kind = ImportDeclaration.ImportType; _ })
        ->
        true
      | _ -> false

    method private add_statement_after_directive_and_type_imports
        (block_stmts : (Loc.t, Loc.t) Ast.Statement.t list)
        (insert_stmts : (Loc.t, Loc.t) Ast.Statement.t list) =
      match block_stmts with
      | [] -> insert_stmts
      | stmt :: block when this#is_directive_statement stmt ->
        (* TODO make tail-recursive *)
        stmt :: this#add_statement_after_directive_and_type_imports block insert_stmts
      | _ -> insert_stmts @ block_stmts

    method private make_annotation loc ty =
      match ty with
      | Ok (Ty.Type ty) ->
        begin
          match this#replace_type_node_with_ty loc ty with
          | Ok t -> Ast.Type.Available (loc, t)
          | Error _ -> Ast.Type.Missing loc
        end
      | _ -> Ast.Type.Missing loc

    method private post_run () = ()

    method! binding_pattern ?(kind = Ast.Statement.VariableDeclaration.Var) ((pat_loc, patt) as expr)
        =
      let open Ast.Pattern in
      let open Ast.Pattern.Identifier in
      match patt with
      | Identifier ({ Identifier.name = (loc, _); annot = Ast.Type.Missing annot_loc; _ } as id) ->
        let aloc = ALoc.of_loc loc in
        if ALocSet.mem aloc escape_locs then
          let annot = this#make_annotation annot_loc (Normalizer.ty_at_loc norm_opts ask loc) in
          super#binding_pattern ~kind (pat_loc, Identifier { id with annot })
        else
          super#binding_pattern ~kind expr
      | _ -> super#binding_pattern ~kind expr

    method! type_annotation_hint annot =
      match annot with
      | Flow_ast.Type.Available _ -> annot
      | Flow_ast.Type.Missing loc ->
        let aloc = ALoc.of_loc loc in
        if ALocSet.mem aloc escape_locs then
          this#make_annotation loc (Normalizer.ty_at_loc norm_opts ask loc)
        else
          annot

    method! program prog =
      remote_symbols_map <- SymbolMap.empty;
      let (loc, { Ast.Program.statements = stmts; comments; all_comments }) = super#program prog in
      let { Codemod_context.Typed.file; _ } = ask in
      let import_stmts = gen_import_statements file remote_symbols_map in
      let stmts = this#add_statement_after_directive_and_type_imports stmts import_stmts in
      (loc, { Ast.Program.statements = stmts; comments; all_comments })
  end

let visit ~default_any ~preserve_literals ~max_type_size =
  Codemod_utils.make_visitor
    (Codemod_utils.Mapper (mapper ~default_any ~preserve_literals ~max_type_size))
