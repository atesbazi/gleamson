//// Combinator decoders that turn a `gleamson.Json` value into typed Gleam data.
////
//// Decoders here *accumulate* errors: when one field fails, decoding keeps
//// going so you get every problem at once, not just the first. A decoder
//// always produces a best-effort value alongside a list of errors, where
//// failed parts are filled with a zero value; that value is discarded by the
//// runners unless the error list is empty.
////
//// A `Decoder(t)` is just a function `fn(Json) -> #(t, List(DecodeError))`, so
//// you can write your own as a plain function. Records are built with `use`.
////
//// ```gleam
//// import gleamson
//// import gleamson/decode
////
//// pub type Cat {
////   Cat(name: String, lives: Int, nicknames: List(String))
//// }
////
//// pub fn cat_from_json(text: String) -> Result(Cat, decode.Error) {
////   let cat = {
////     use name <- decode.field("name", decode.string)
////     use lives <- decode.field("lives", decode.int)
////     use nicknames <- decode.field("nicknames", decode.list(decode.string))
////     decode.success(Cat(name:, lives:, nicknames:))
////   }
////   decode.from_string(text, cat)
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamson.{
  type Json, type ParseError, Array, Bool, Float, Int, Null, Object, String,
}

/// Why a value could not be decoded: what was expected, what was found, and
/// the path to the offending value.
pub type DecodeError {
  DecodeError(expected: String, found: String, path: List(String))
}

/// A decoder produces a best-effort value together with any errors found.
/// An empty error list means success.
pub type Decoder(t) =
  fn(Json) -> #(t, List(DecodeError))

/// A failure when going straight from text to typed data.
pub type Error {
  /// The bytes were not valid JSON.
  CouldNotParse(ParseError)
  /// The JSON was valid but did not match the decoder. Holds every error.
  CouldNotDecode(List(DecodeError))
}

// --- Runners ---------------------------------------------------------------

/// Run a decoder, collecting *all* errors.
pub fn run(
  json: Json,
  using decoder: Decoder(t),
) -> Result(t, List(DecodeError)) {
  case decoder(json) {
    #(value, []) -> Ok(value)
    #(_, errors) -> Error(errors)
  }
}

/// Run a decoder but report only the first error. Handy when a single error
/// is all you want to surface to the caller.
pub fn run_first(
  json: Json,
  using decoder: Decoder(t),
) -> Result(t, DecodeError) {
  case decoder(json) {
    #(value, []) -> Ok(value)
    #(_, [first, ..]) -> Error(first)
  }
}

/// Parse a string and decode it in one step, collecting all decode errors.
pub fn from_string(
  from text: String,
  using decoder: Decoder(t),
) -> Result(t, Error) {
  case gleamson.parse(text) {
    Ok(json) ->
      case run(json, decoder) {
        Ok(value) -> Ok(value)
        Error(errors) -> Error(CouldNotDecode(errors))
      }
    Error(error) -> Error(CouldNotParse(error))
  }
}

// --- Primitives ------------------------------------------------------------

pub fn string(json: Json) -> #(String, List(DecodeError)) {
  case json {
    String(value) -> #(value, [])
    _ -> #("", [mismatch("String", json)])
  }
}

pub fn int(json: Json) -> #(Int, List(DecodeError)) {
  case json {
    Int(value) -> #(value, [])
    _ -> #(0, [mismatch("Int", json)])
  }
}

/// Decodes a JSON number as a float, accepting integer literals too.
pub fn float(json: Json) -> #(Float, List(DecodeError)) {
  case json {
    Float(value) -> #(value, [])
    Int(value) -> #(int.to_float(value), [])
    _ -> #(0.0, [mismatch("Float", json)])
  }
}

pub fn bool(json: Json) -> #(Bool, List(DecodeError)) {
  case json {
    Bool(value) -> #(value, [])
    _ -> #(False, [mismatch("Bool", json)])
  }
}

/// A decoder that accepts anything and hands back the raw `Json`.
pub fn json(value: Json) -> #(Json, List(DecodeError)) {
  #(value, [])
}

/// A decoder that always succeeds with the given value. Used to finish a
/// `use` chain.
pub fn success(value: t) -> Decoder(t) {
  fn(_json) { #(value, []) }
}

/// A decoder that always fails, reporting `expected`. `zero` is the value used
/// to keep accumulating in surrounding decoders.
pub fn failure(zero: t, expected: String) -> Decoder(t) {
  fn(json) { #(zero, [mismatch(expected, json)]) }
}

// --- Combinators -----------------------------------------------------------

/// Decode a field of an object, then continue with the rest of the record.
/// A failing field does not stop the others from being checked.
pub fn field(
  named name: String,
  of field_decoder: Decoder(a),
  then next: fn(a) -> Decoder(final),
) -> Decoder(final) {
  fn(json: Json) {
    case json {
      Object(entries) ->
        case list.key_find(entries, name) {
          Ok(child) -> {
            let #(value, field_errors) = field_decoder(child)
            let field_errors =
              list.map(field_errors, fn(error) { push(error, name) })
            let #(rest, rest_errors) = next(value)(json)
            #(rest, list.append(field_errors, rest_errors))
          }
          Error(_) -> {
            let #(zero, _) = field_decoder(Null)
            let #(rest, rest_errors) = next(zero)(json)
            #(rest, [missing_field(name), ..rest_errors])
          }
        }
      _ -> {
        // Not an object at all: report once and fill the record with zeros.
        let #(zero, _) = field_decoder(Null)
        let #(rest, _) = next(zero)(Null)
        #(rest, [mismatch("Object", json)])
      }
    }
  }
}

/// Like `field`, but a missing key or `null` value yields `None` instead of
/// an error.
pub fn optional_field(
  named name: String,
  of field_decoder: Decoder(a),
  then next: fn(Option(a)) -> Decoder(final),
) -> Decoder(final) {
  fn(json: Json) {
    case json {
      Object(entries) ->
        case list.key_find(entries, name) {
          Ok(Null) -> next(None)(json)
          Ok(child) -> {
            let #(value, field_errors) = field_decoder(child)
            let field_errors =
              list.map(field_errors, fn(error) { push(error, name) })
            let #(rest, rest_errors) = next(Some(value))(json)
            #(rest, list.append(field_errors, rest_errors))
          }
          Error(_) -> next(None)(json)
        }
      _ -> {
        let #(rest, _) = next(None)(Null)
        #(rest, [mismatch("Object", json)])
      }
    }
  }
}

/// Decode a value found by following a path of object keys.
pub fn at(path: List(String), inner: Decoder(a)) -> Decoder(a) {
  fn(json: Json) {
    case gleamson.get(json, path) {
      Ok(child) -> {
        let #(value, errors) = inner(child)
        let errors =
          list.map(errors, fn(error) {
            DecodeError(error.expected, error.found, list.append(path, error.path))
          })
        #(value, errors)
      }
      Error(_) -> {
        let #(zero, _) = inner(Null)
        #(zero, [
          DecodeError("value at " <> string.join(path, "."), "nothing", path),
        ])
      }
    }
  }
}

/// Decode a JSON array, applying `inner` to every element and collecting every
/// element's errors.
pub fn list(of inner: Decoder(a)) -> Decoder(List(a)) {
  fn(json: Json) {
    case json {
      Array(items) -> decode_items(items, inner, 0, [], [])
      _ -> #([], [mismatch("Array", json)])
    }
  }
}

fn decode_items(
  items: List(Json),
  inner: Decoder(a),
  index: Int,
  values: List(a),
  errors: List(DecodeError),
) -> #(List(a), List(DecodeError)) {
  case items {
    [] -> #(list.reverse(values), errors)
    [first, ..rest] -> {
      let #(value, item_errors) = inner(first)
      let item_errors =
        list.map(item_errors, fn(error) { push(error, int.to_string(index)) })
      decode_items(rest, inner, index + 1, [value, ..values], list.append(
        errors,
        item_errors,
      ))
    }
  }
}

/// Decode a JSON object into a `Dict` keyed by its string keys.
pub fn dict(of value_decoder: Decoder(v)) -> Decoder(Dict(String, v)) {
  fn(json: Json) {
    case json {
      Object(entries) -> decode_entries(entries, value_decoder, dict.new(), [])
      _ -> #(dict.new(), [mismatch("Object", json)])
    }
  }
}

fn decode_entries(
  entries: List(#(String, Json)),
  value_decoder: Decoder(v),
  acc: Dict(String, v),
  errors: List(DecodeError),
) -> #(Dict(String, v), List(DecodeError)) {
  case entries {
    [] -> #(acc, errors)
    [#(key, value), ..rest] -> {
      let #(decoded, entry_errors) = value_decoder(value)
      let entry_errors =
        list.map(entry_errors, fn(error) { push(error, key) })
      decode_entries(
        rest,
        value_decoder,
        dict.insert(acc, key, decoded),
        list.append(errors, entry_errors),
      )
    }
  }
}

/// Wrap a decoder so that `null` becomes `None`.
pub fn optional(of inner: Decoder(a)) -> Decoder(Option(a)) {
  fn(json: Json) {
    case json {
      Null -> #(None, [])
      _ -> {
        let #(value, errors) = inner(json)
        #(Some(value), errors)
      }
    }
  }
}

/// Transform a decoder's value. Errors are carried through unchanged.
pub fn map(decoder: Decoder(a), with transform: fn(a) -> b) -> Decoder(b) {
  fn(json: Json) {
    let #(value, errors) = decoder(json)
    #(transform(value), errors)
  }
}

// --- Internal --------------------------------------------------------------

fn mismatch(expected: String, found: Json) -> DecodeError {
  DecodeError(expected: expected, found: type_name(found), path: [])
}

fn missing_field(name: String) -> DecodeError {
  DecodeError(expected: "field \"" <> name <> "\"", found: "nothing", path: [
    name,
  ])
}

fn push(error: DecodeError, segment: String) -> DecodeError {
  DecodeError(error.expected, error.found, [segment, ..error.path])
}

fn type_name(json: Json) -> String {
  case json {
    Null -> "Null"
    Bool(_) -> "Bool"
    Int(_) -> "Int"
    Float(_) -> "Float"
    String(_) -> "String"
    Array(_) -> "Array"
    Object(_) -> "Object"
  }
}

// --- More combinators ------------------------------------------------------

/// Try `first`; if it fails, try each decoder in `others` in turn, returning
/// the first that succeeds. If none match, every branch's errors are reported.
///
/// ```gleam
/// // a field that may arrive as an int or as a bool
/// one_of(int, [map(bool, fn(b) { case b { True -> 1 False -> 0 } })])
/// ```
pub fn one_of(first: Decoder(a), or others: List(Decoder(a))) -> Decoder(a) {
  fn(json: Json) {
    case first(json) {
      #(value, []) -> #(value, [])
      #(zero, errors) -> first_success(others, json, zero, errors)
    }
  }
}

fn first_success(
  decoders: List(Decoder(a)),
  json: Json,
  zero: a,
  errors: List(DecodeError),
) -> #(a, List(DecodeError)) {
  case decoders {
    [] -> #(zero, errors)
    [decoder, ..rest] ->
      case decoder(json) {
        #(value, []) -> #(value, [])
        #(_, more) -> first_success(rest, json, zero, list.append(errors, more))
      }
  }
}

/// Decode a value, then use it to choose the next decoder. Useful for
/// validation, or for discriminated unions (read a "type" field, then decode
/// the matching shape). This short-circuits: if the first decoder fails, the
/// chosen one is not run.
///
/// ```gleam
/// use n <- then(int)
/// case n >= 0 {
///   True -> success(n)
///   False -> failure(0, "a non-negative int")
/// }
/// ```
pub fn then(decoder: Decoder(a), apply next: fn(a) -> Decoder(b)) -> Decoder(b) {
  fn(json: Json) {
    case decoder(json) {
      #(value, []) -> {
        let chosen = next(value)
        chosen(json)
      }
      #(value, errors) -> {
        let chosen = next(value)
        let #(zero, _) = chosen(json)
        #(zero, errors)
      }
    }
  }
}

/// Decode the element at a given array index.
pub fn index(at position: Int, of inner: Decoder(a)) -> Decoder(a) {
  fn(json: Json) {
    case json {
      Array(_) ->
        case gleamson.index(json, position) {
          Ok(child) -> {
            let #(value, errors) = inner(child)
            #(value, list.map(errors, fn(error) {
              push(error, int.to_string(position))
            }))
          }
          Error(_) -> {
            let #(zero, _) = inner(Null)
            #(zero, [
              DecodeError(
                "element at index " <> int.to_string(position),
                "nothing",
                [int.to_string(position)],
              ),
            ])
          }
        }
      _ -> {
        let #(zero, _) = inner(Null)
        #(zero, [mismatch("Array", json)])
      }
    }
  }
}

/// Decode a JSON string by mapping it to a value from a fixed set, the way
/// you'd decode an enum-like custom type. The first pair's value doubles as the
/// fallback used while accumulating errors.
///
/// ```gleam
/// pub type Side {
///   Buy
///   Sell
/// }
///
/// let side = enum(#("buy", Buy), or: [#("sell", Sell)])
/// ```
pub fn enum(
  first: #(String, a),
  or others: List(#(String, a)),
) -> Decoder(a) {
  let variants = [first, ..others]
  let fallback = first.1
  fn(json: Json) {
    case json {
      String(text) ->
        case list.key_find(variants, text) {
          Ok(value) -> #(value, [])
          Error(_) ->
            #(fallback, [
              DecodeError(
                expected: "one of: " <> allowed(variants),
                found: "\"" <> text <> "\"",
                path: [],
              ),
            ])
        }
      _ -> #(fallback, [mismatch("String", json)])
    }
  }
}

fn allowed(variants: List(#(String, a))) -> String {
  variants
  |> list.map(fn(pair) { "\"" <> pair.0 <> "\"" })
  |> string.join(", ")
}
