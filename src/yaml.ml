open Sexplib.Conv
open Rresult

module B = Yaml_ffi.M
module T = Yaml_types.M

type version =
  | V1_0
  | V1_1 [@@deriving sexp]

type encoding =
  | Any
  | Utf16be
  | Utf16le
  | Utf8 [@@deriving sexp]

type scalar_style =
  | Any
  | Plain
  | Single_quoted
  | Double_quoted
  | Literal
  | Folded [@@deriving sexp]

type tag_directive = {
  handle: string;
  prefix: string;
} [@@deriving sexp]

let error_to_msg e =
  match e with
  | `None -> "No error"
  | `Memory -> "Reader error"
  | `Scanner -> "Scanner error"
  | `Parser -> "Parser error"
  | `Composer -> "Compose error"
  | `Writer -> "Writer error"
  | `Emitter -> "Emitter error"
  | `E i -> "Unknown error code " ^ (Int64.to_string i)

let scalar_style_of_ffi s : scalar_style =
  match s with
  | `Any -> Any
  | `Plain -> Plain
  | `Single_quoted -> Single_quoted
  | `Double_quoted -> Double_quoted
  | `Literal -> Literal
  | `Folded -> Folded
  | `E err -> raise (Invalid_argument ("invalid scalar style"^(Int64.to_string err)))

let encoding_of_ffi e : encoding =
  match e with
  | `Any -> Any
  | `Utf16be -> Utf16be
  | `Utf16le -> Utf16le
  | `Utf8 -> Utf8
  | `E err -> raise (Invalid_argument ("invalid encoding "^(Int64.to_string err)))

let tag_directive_of_ffi e =
  let open Ctypes in
  let handle = !@ (e |-> T.Tag_directive.handle) in
  let prefix = !@ (e |-> T.Tag_directive.prefix) in
  { handle; prefix }

let list_of_tag_directives tds =
  let open Ctypes in
  let module TEDT = T.Event.Document_start.Tag_directives in
  let hd = !@ (tds |-> TEDT.start) in
(* TODO not clear how to parse this as not a linked list *)
  let acc = [hd] in
  List.map tag_directive_of_ffi acc
 
let version_of_directive ~major ~minor =
  match major, minor with
  | 1,0 -> V1_0
  | 1,1 -> V1_1
  | _ -> raise (Invalid_argument (Printf.sprintf "Unsupported Yaml version %d.%d" major minor))

module Mark = struct
  type t = {
    index: int;
    line: int;
    column: int;
  } [@@deriving sexp]

  let of_ffi m =
    let open Ctypes in
    let int_field f = getf m f |> Unsigned.Size_t.to_int in
    let index = int_field T.Mark.index in
    let line = int_field T.Mark.line in
    let column = int_field T.Mark.column in
    { index; line; column }
end

module Event = struct
  type pos = {
    start_mark: Mark.t;
    end_mark: Mark.t;
  } [@@deriving sexp]

  type t =
   | Stream_start of { pos: pos; encoding: encoding }
   | Document_start of { pos: pos; version: version option; implicit: bool }
   | Document_end of { pos: pos; implicit: bool }
   | Mapping_start of { pos: pos; anchor: string option; tag: string option; implicit: bool; style: scalar_style }
   | Mapping_end of { pos: pos }
   | Stream_end of { pos: pos }
   | Scalar of { pos: pos; anchor: string option; tag: string option; value: string; plain_implicit: bool; quoted_implicit: bool; style: scalar_style }
   | Sequence_start of { pos: pos; anchor: string option; tag: string option; implicit: bool; style: scalar_style }
   | Sequence_end of { pos:pos }
   | Alias of { pos: pos; anchor: string }
   | Nothing of { pos: pos }
   [@@deriving sexp]

  let of_ffi e : t =
    let open T.Event in
    let open Ctypes in
    let ty = getf e _type in
    let data = getf e data in
    let start_mark = getf e start_mark |> Mark.of_ffi in
    let end_mark = getf e end_mark |> Mark.of_ffi in
    let pos = { start_mark; end_mark } in
    match ty with
    |`Stream_start ->
       let start = getf data Data.stream_start in
       let encoding = getf start Stream_start.encoding |> encoding_of_ffi in
       Stream_start { pos; encoding }
    |`Document_start ->
       let ds = getf data Data.document_start in
       let version =
         let vd = getf ds Document_start.version_directive in
         match vd with
         |None -> None
         |Some vd -> let vd = !@ vd in
           let major = getf vd T.Version_directive.major in
           let minor = getf vd T.Version_directive.minor in
           Some (version_of_directive ~major ~minor) in
       let implicit = getf ds Document_start.implicit <> 0 in
       Document_start { pos; version; implicit}
    |`Mapping_start ->
      let ms = getf data Data.mapping_start in
      let anchor = getf ms Mapping_start.anchor in
      let tag = getf ms Mapping_start.tag in
      let implicit = getf ms Mapping_start.implicit <> 0 in
      let style = getf ms Mapping_start.style |> scalar_style_of_ffi in
      Mapping_start { pos; anchor; tag; implicit; style }
    |`Scalar ->
      let s = getf data Data.scalar in
      let anchor = getf s Scalar.anchor in
      let tag = getf s Scalar.tag in
      let value = getf s Scalar.value in
      let plain_implicit = getf s Scalar.plain_implicit <> 0 in
      let quoted_implicit = getf s Scalar.quoted_implicit <> 0 in
      let style = getf s Scalar.style |> scalar_style_of_ffi in
      Scalar { pos; anchor; tag; value; plain_implicit; quoted_implicit; style }
    |`Document_end ->
      let de = getf data Data.document_end in
      let implicit = getf de Document_end.implicit <> 0 in
      Document_end { pos; implicit }
    |`Sequence_start ->
      let ss = getf data Data.sequence_start in
      let anchor = getf ss Sequence_start.anchor in
      let tag = getf ss Sequence_start.tag in
      let implicit = getf ss Sequence_start.implicit <> 0 in
      let style = getf ss Sequence_start.style |> scalar_style_of_ffi in
      Sequence_start {pos; anchor; tag; implicit; style}
    |`Sequence_end -> Sequence_end {pos}
    |`Mapping_end -> Mapping_end {pos}
    |`Stream_end -> Stream_end {pos}
    |`Alias ->
      let a = getf data Data.alias in
      let anchor = 
        match getf a Alias.anchor with
        | None -> raise (Invalid_argument "empty anchor alias")
        | Some a -> a in
      Alias { pos; anchor }
    |`None -> Nothing {pos}
    |`E i -> raise (Invalid_argument ("Unexpected event, internal library error "^(Int64.to_string i)))
    
end

let version = B.version
let get_version () =
  let major = Ctypes.(allocate int 0) in
  let minor = Ctypes.(allocate int 0) in
  let patch = Ctypes.(allocate int 0) in
  B.get_version major minor patch;
  let major = Ctypes.((!@) major) in
  let minor = Ctypes.((!@) minor) in
  let patch = Ctypes.((!@) patch) in
  major, minor, patch

type parser = {
  p: T.Parser.t Ctypes.structure Ctypes.ptr;
  e: T.Event.t Ctypes.structure Ctypes.ptr;
}

let parser () =
  let p = Ctypes.(allocate_n T.Parser.t ~count:1) in
  let e = Ctypes.(allocate_n T.Event.t ~count:1) in
  let r = B.parser_init p in
  match r with
  | 1 -> R.ok {p;e}
  | _ -> R.error_msg "error initialising parser"

let set_input_string {p;_} s =
  let len = String.length s |> Unsigned.Size_t.of_int in
  B.parser_set_input_string p s len

let do_parse {p;e} =
  let open Ctypes in
  let r = B.parser_parse p e in
  match r with
  | 1 -> Event.of_ffi (!@ e) |> R.ok
  | _ -> R.error_msg "error calling parser"
