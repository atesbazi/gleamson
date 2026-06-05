//// gleamson — a pure-Gleam JSON library.
////
//// Unlike libraries that delegate to a platform's native JSON facilities,
//// `gleamson` is written entirely in Gleam. That means:
////
////   * It runs identically on the Erlang and JavaScript targets.
////   * It has no Erlang/OTP version requirement.
////   * Parse errors carry a precise byte position, on every runtime.
////   * The `Json` value is a transparent type you can pattern match on,
////     transform, and build directly — no opaque box.
////
//// Parsing is a single pass over a `BitArray` using Gleam's bit-array
//// pattern matching, which compiles to fast binary matching on the BEAM.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

/// A JSON value.
///
/// This type is transparent on purpose: you can pattern match on it, build it
/// with its constructors, and walk it with the helpers in this module.
///
/// ```gleam
/// Object([
///   #("game", String("Pac-Man")),
///   #("score", Int(3_333_360)),
///   #("flaws", Null),
/// ])
/// ```
///
/// Object entries keep their original order and allow duplicate keys, so a
/// parse → encode round trip preserves the document faithfully. Use `to_dict`
/// if you want `O(1)` repeated lookups instead.
pub type Json {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  Array(List(Json))
  Object(List(#(String, Json)))
}

/// Everything that can go wrong while parsing, with a byte position where it
/// is meaningful.
pub type ParseError {
  /// The input ended while a value was still expected.
  UnexpectedEnd
  /// An unexpected byte was found at `position`. `byte` is the offending
  /// character, or a short description / `0x..` hex if it is not printable.
  UnexpectedByte(byte: String, position: Int)
  /// A run of bytes that looked like a token but could not be interpreted,
  /// for example a malformed number. `token` is the offending text.
  UnexpectedToken(token: String, position: Int)
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse a JSON string into a `Json` value.
///
/// ```gleam
/// parse("[1, 2, 3]")
/// // -> Ok(Array([Int(1), Int(2), Int(3)]))
///
/// parse("[")
/// // -> Error(UnexpectedEnd)
/// ```
pub fn parse(from json: String) -> Result(Json, ParseError) {
  parse_bits(bit_array.from_string(json))
}

/// Parse JSON from a `BitArray`. Useful when the bytes come straight off the
/// wire and you would rather not allocate an intermediate `String`.
pub fn parse_bits(from json: BitArray) -> Result(Json, ParseError) {
  let len = bit_array.byte_size(json)
  use #(value, rest) <- result.try(parse_value(skip_whitespace(json), len))
  let trailing = skip_whitespace(rest)
  case trailing {
    <<>> -> Ok(value)
    <<byte, _:bits>> ->
      Error(UnexpectedByte(describe_byte(byte), position(trailing, len)))
    _ -> Error(UnexpectedEnd)
  }
}

type Parsed(a) =
  Result(#(a, BitArray), ParseError)

fn parse_value(bits: BitArray, len: Int) -> Parsed(Json) {
  case bits {
    <<"null":utf8, rest:bits>> -> Ok(#(Null, rest))
    <<"true":utf8, rest:bits>> -> Ok(#(Bool(True), rest))
    <<"false":utf8, rest:bits>> -> Ok(#(Bool(False), rest))
    <<"\"":utf8, rest:bits>> -> {
      use #(value, remainder) <- result.try(parse_string(rest, len))
      Ok(#(String(value), remainder))
    }
    <<"{":utf8, rest:bits>> -> parse_object(skip_whitespace(rest), len, [])
    <<"[":utf8, rest:bits>> -> parse_array(skip_whitespace(rest), len, [])
    <<byte, _:bits>> ->
      case byte == 0x2D || { byte >= 0x30 && byte <= 0x39 } {
        True -> parse_number(bits, len)
        False -> Error(UnexpectedByte(describe_byte(byte), position(bits, len)))
      }
    _ -> Error(UnexpectedEnd)
  }
}

fn parse_array(bits: BitArray, len: Int, acc: List(Json)) -> Parsed(Json) {
  case bits {
    // An empty array is the only place where `]` may follow `[` directly.
    <<"]":utf8, rest:bits>> -> Ok(#(Array(list.reverse(acc)), rest))
    _ -> parse_array_element(bits, len, acc)
  }
}

fn parse_array_element(bits: BitArray, len: Int, acc: List(Json)) -> Parsed(Json) {
  use #(value, rest) <- result.try(parse_value(bits, len))
  let acc = [value, ..acc]
  let rest = skip_whitespace(rest)
  case rest {
    // After a comma a value is required, so trailing commas are rejected.
    <<",":utf8, after:bits>> ->
      parse_array_element(skip_whitespace(after), len, acc)
    <<"]":utf8, after:bits>> -> Ok(#(Array(list.reverse(acc)), after))
    <<byte, _:bits>> ->
      Error(UnexpectedByte(describe_byte(byte), position(rest, len)))
    _ -> Error(UnexpectedEnd)
  }
}

fn parse_object(
  bits: BitArray,
  len: Int,
  acc: List(#(String, Json)),
) -> Parsed(Json) {
  case bits {
    // An empty object is the only place where `}` may follow `{` directly.
    <<"}":utf8, rest:bits>> -> Ok(#(Object(list.reverse(acc)), rest))
    _ -> parse_object_member(bits, len, acc)
  }
}

fn parse_object_member(
  bits: BitArray,
  len: Int,
  acc: List(#(String, Json)),
) -> Parsed(Json) {
  case bits {
    <<"\"":utf8, rest:bits>> -> {
      use #(key, rest) <- result.try(parse_string(rest, len))
      let rest = skip_whitespace(rest)
      case rest {
        <<":":utf8, after:bits>> -> {
          use #(value, rest) <- result.try(
            parse_value(skip_whitespace(after), len),
          )
          let acc = [#(key, value), ..acc]
          let rest = skip_whitespace(rest)
          case rest {
            // After a comma another key is required (no trailing comma).
            <<",":utf8, more:bits>> ->
              parse_object_member(skip_whitespace(more), len, acc)
            <<"}":utf8, more:bits>> -> Ok(#(Object(list.reverse(acc)), more))
            <<byte, _:bits>> ->
              Error(UnexpectedByte(describe_byte(byte), position(rest, len)))
            _ -> Error(UnexpectedEnd)
          }
        }
        <<byte, _:bits>> ->
          Error(UnexpectedByte(describe_byte(byte), position(rest, len)))
        _ -> Error(UnexpectedEnd)
      }
    }
    <<byte, _:bits>> ->
      Error(UnexpectedByte(describe_byte(byte), position(bits, len)))
    _ -> Error(UnexpectedEnd)
  }
}

// --- Strings ---------------------------------------------------------------

fn parse_string(bits: BitArray, len: Int) -> Parsed(String) {
  parse_string_loop(bits, len, <<>>)
}

fn parse_string_loop(bits: BitArray, len: Int, acc: BitArray) -> Parsed(String) {
  case bits {
    <<"\"":utf8, rest:bits>> ->
      case bit_array.to_string(acc) {
        Ok(value) -> Ok(#(value, rest))
        Error(_) ->
          Error(UnexpectedByte("invalid UTF-8", position(bits, len)))
      }
    <<"\\":utf8, rest:bits>> -> parse_escape(rest, len, acc)
    <<byte, rest:bits>> ->
      case byte < 0x20 {
        // Control characters must be escaped inside JSON strings.
        True -> Error(UnexpectedByte(describe_byte(byte), position(bits, len)))
        False -> parse_string_loop(rest, len, <<acc:bits, byte>>)
      }
    _ -> Error(UnexpectedEnd)
  }
}

fn parse_escape(bits: BitArray, len: Int, acc: BitArray) -> Parsed(String) {
  case bits {
    <<"\"":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x22>>)
    <<"\\":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x5C>>)
    <<"/":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x2F>>)
    <<"b":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x08>>)
    <<"f":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x0C>>)
    <<"n":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x0A>>)
    <<"r":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x0D>>)
    <<"t":utf8, rest:bits>> -> parse_string_loop(rest, len, <<acc:bits, 0x09>>)
    <<"u":utf8, rest:bits>> -> parse_unicode_escape(rest, len, acc)
    <<byte, _:bits>> ->
      Error(UnexpectedByte(describe_byte(byte), position(bits, len)))
    _ -> Error(UnexpectedEnd)
  }
}

fn parse_unicode_escape(
  bits: BitArray,
  len: Int,
  acc: BitArray,
) -> Parsed(String) {
  case bits {
    <<a, b, c, d, rest:bits>> ->
      case hex4(a, b, c, d) {
        Ok(code) ->
          case code >= 0xD800 && code <= 0xDBFF {
            True -> parse_low_surrogate(rest, len, acc, code)
            False -> append_codepoint(code, rest, len, acc)
          }
        Error(_) ->
          Error(UnexpectedByte("invalid \\u escape", position(bits, len)))
      }
    _ -> Error(UnexpectedEnd)
  }
}

fn parse_low_surrogate(
  bits: BitArray,
  len: Int,
  acc: BitArray,
  high: Int,
) -> Parsed(String) {
  case bits {
    <<"\\u":utf8, a, b, c, d, rest:bits>> ->
      case hex4(a, b, c, d) {
        Ok(low) ->
          case low >= 0xDC00 && low <= 0xDFFF {
            True -> {
              let code = 0x10000 + { high - 0xD800 } * 0x400 + { low - 0xDC00 }
              append_codepoint(code, rest, len, acc)
            }
            False ->
              Error(UnexpectedByte("invalid low surrogate", position(bits, len)))
          }
        Error(_) ->
          Error(UnexpectedByte("invalid \\u escape", position(bits, len)))
      }
    _ ->
      Error(UnexpectedByte("unpaired surrogate", position(bits, len)))
  }
}

fn append_codepoint(
  code: Int,
  rest: BitArray,
  len: Int,
  acc: BitArray,
) -> Parsed(String) {
  case string.utf_codepoint(code) {
    Ok(cp) -> parse_string_loop(rest, len, <<acc:bits, cp:utf8_codepoint>>)
    Error(_) ->
      Error(UnexpectedByte("invalid code point", position(rest, len)))
  }
}

// --- Numbers ---------------------------------------------------------------

fn parse_number(bits: BitArray, len: Int) -> Parsed(Json) {
  let #(lexeme_bits, rest) = take_number(bits, <<>>)
  case bit_array.to_string(lexeme_bits) {
    Ok(lexeme) ->
      case is_integer_lexeme(lexeme) {
        True ->
          case int.parse(lexeme) {
            Ok(value) -> Ok(#(Int(value), rest))
            Error(_) -> Error(UnexpectedToken(lexeme, position(bits, len)))
          }
        False ->
          case float.parse(normalize_float(lexeme)) {
            Ok(value) -> Ok(#(Float(value), rest))
            Error(_) -> Error(UnexpectedToken(lexeme, position(bits, len)))
          }
      }
    Error(_) -> Error(UnexpectedByte("invalid UTF-8", position(bits, len)))
  }
}

fn take_number(bits: BitArray, acc: BitArray) -> #(BitArray, BitArray) {
  case bits {
    <<byte, rest:bits>> ->
      case is_number_char(byte) {
        True -> take_number(rest, <<acc:bits, byte>>)
        False -> #(acc, bits)
      }
    _ -> #(acc, bits)
  }
}

fn is_number_char(byte: Int) -> Bool {
  byte >= 0x30 && byte <= 0x39
  || byte == 0x2D
  || byte == 0x2B
  || byte == 0x2E
  || byte == 0x65
  || byte == 0x45
}

fn is_integer_lexeme(lexeme: String) -> Bool {
  case
    string.contains(lexeme, "."),
    string.contains(lexeme, "e"),
    string.contains(lexeme, "E")
  {
    False, False, False -> True
    _, _, _ -> False
  }
}

/// `float.parse` is backed by Erlang's `binary_to_float`, which insists on a
/// decimal point. JSON allows `1e9`, so we make sure the mantissa has one and
/// normalise the exponent letter to lowercase. The result is then parsed
/// identically on both targets.
fn normalize_float(lexeme: String) -> String {
  let lexeme = string.replace(lexeme, "E", "e")
  case string.split_once(lexeme, "e") {
    Ok(#(mantissa, exponent)) -> {
      let mantissa = case string.contains(mantissa, ".") {
        True -> mantissa
        False -> mantissa <> ".0"
      }
      mantissa <> "e" <> exponent
    }
    Error(_) -> lexeme
  }
}

// --- Lexer helpers ---------------------------------------------------------

fn skip_whitespace(bits: BitArray) -> BitArray {
  case bits {
    <<0x20, rest:bits>> -> skip_whitespace(rest)
    <<0x09, rest:bits>> -> skip_whitespace(rest)
    <<0x0A, rest:bits>> -> skip_whitespace(rest)
    <<0x0D, rest:bits>> -> skip_whitespace(rest)
    _ -> bits
  }
}

fn position(bits: BitArray, len: Int) -> Int {
  len - bit_array.byte_size(bits)
}

fn hex4(a: Int, b: Int, c: Int, d: Int) -> Result(Int, Nil) {
  use a <- result.try(hex_digit(a))
  use b <- result.try(hex_digit(b))
  use c <- result.try(hex_digit(c))
  use d <- result.try(hex_digit(d))
  Ok({ { { a * 16 + b } * 16 + c } * 16 } + d)
}

fn hex_digit(byte: Int) -> Result(Int, Nil) {
  case byte {
    _ if byte >= 0x30 && byte <= 0x39 -> Ok(byte - 0x30)
    _ if byte >= 0x41 && byte <= 0x46 -> Ok(byte - 0x41 + 10)
    _ if byte >= 0x61 && byte <= 0x66 -> Ok(byte - 0x61 + 10)
    _ -> Error(Nil)
  }
}

fn describe_byte(byte: Int) -> String {
  case byte >= 0x20 && byte <= 0x7E {
    True ->
      case string.utf_codepoint(byte) {
        Ok(cp) -> string.from_utf_codepoints([cp])
        Error(_) -> byte_hex(byte)
      }
    False -> byte_hex(byte)
  }
}

fn byte_hex(byte: Int) -> String {
  "0x" <> string.uppercase(to_hex(byte))
}

fn to_hex(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> to_hex_loop(n, "")
  }
}

fn to_hex_loop(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> to_hex_loop(n / 16, hex_char(n % 16) <> acc)
  }
}

fn hex_char(digit: Int) -> String {
  case digit {
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    15 -> "f"
    _ -> int.to_string(digit)
  }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Render a `Json` value to a compact string.
///
/// Prefer `to_string_tree` when feeding the BEAM's IO, which is optimised for
/// iodata.
///
/// ```gleam
/// to_string(Array([Int(1), Int(2), Int(3)]))
/// // -> "[1,2,3]"
/// ```
pub fn to_string(json: Json) -> String {
  json
  |> to_string_tree
  |> string_tree.to_string
}

/// Render a `Json` value to a `StringTree` (iodata).
pub fn to_string_tree(json: Json) -> StringTree {
  case json {
    Null -> string_tree.from_string("null")
    Bool(True) -> string_tree.from_string("true")
    Bool(False) -> string_tree.from_string("false")
    Int(value) -> string_tree.from_string(int.to_string(value))
    Float(value) -> string_tree.from_string(float.to_string(value))
    String(value) ->
      string_tree.from_string("\"")
      |> string_tree.append_tree(escape_string(value))
      |> string_tree.append("\"")
    Array(items) -> encode_array(items)
    Object(entries) -> encode_object(entries)
  }
}

fn encode_array(items: List(Json)) -> StringTree {
  case items {
    [] -> string_tree.from_string("[]")
    [first, ..rest] -> {
      let body =
        list.fold(rest, to_string_tree(first), fn(acc, item) {
          acc
          |> string_tree.append(",")
          |> string_tree.append_tree(to_string_tree(item))
        })
      string_tree.from_string("[")
      |> string_tree.append_tree(body)
      |> string_tree.append("]")
    }
  }
}

fn encode_object(entries: List(#(String, Json))) -> StringTree {
  case entries {
    [] -> string_tree.from_string("{}")
    [first, ..rest] -> {
      let body =
        list.fold(rest, encode_pair(first), fn(acc, pair) {
          acc
          |> string_tree.append(",")
          |> string_tree.append_tree(encode_pair(pair))
        })
      string_tree.from_string("{")
      |> string_tree.append_tree(body)
      |> string_tree.append("}")
    }
  }
}

fn encode_pair(pair: #(String, Json)) -> StringTree {
  let #(key, value) = pair
  string_tree.from_string("\"")
  |> string_tree.append_tree(escape_string(key))
  |> string_tree.append("\":")
  |> string_tree.append_tree(to_string_tree(value))
}

fn escape_string(input: String) -> StringTree {
  input
  |> string.to_utf_codepoints
  |> list.fold(string_tree.new(), fn(tree, cp) {
    string_tree.append(tree, escape_codepoint(cp))
  })
}

fn escape_codepoint(cp: UtfCodepoint) -> String {
  case string.utf_codepoint_to_int(cp) {
    0x22 -> "\\\""
    0x5C -> "\\\\"
    0x08 -> "\\b"
    0x0C -> "\\f"
    0x0A -> "\\n"
    0x0D -> "\\r"
    0x09 -> "\\t"
    code if code < 0x20 -> "\\u" <> pad_hex4(code)
    _ -> string.from_utf_codepoints([cp])
  }
}

fn pad_hex4(code: Int) -> String {
  let hex = to_hex(code)
  case string.length(hex) {
    1 -> "000" <> hex
    2 -> "00" <> hex
    3 -> "0" <> hex
    _ -> hex
  }
}

// ---------------------------------------------------------------------------
// Encoder conveniences
// ---------------------------------------------------------------------------

/// Encode a list as a JSON array using a per-item encoder.
///
/// ```gleam
/// array(["a", "b"], of: String)
/// // -> Array([String("a"), String("b")])
/// ```
pub fn array(from items: List(a), of encode: fn(a) -> Json) -> Json {
  Array(list.map(items, encode))
}

/// Encode an `Option`, using `Null` for `None`.
pub fn nullable(from value: Option(a), of encode: fn(a) -> Json) -> Json {
  case value {
    Some(inner) -> encode(inner)
    None -> Null
  }
}

/// Build an `Object` from a `Dict`.
pub fn from_dict(
  values: Dict(k, v),
  keys: fn(k) -> String,
  encode: fn(v) -> Json,
) -> Json {
  Object(
    dict.fold(values, [], fn(acc, key, value) {
      [#(keys(key), encode(value)), ..acc]
    }),
  )
}

// ---------------------------------------------------------------------------
// Walking a Json value
// ---------------------------------------------------------------------------

/// Look up a key in an object.
pub fn field(json: Json, named name: String) -> Result(Json, Nil) {
  case json {
    Object(entries) -> list.key_find(entries, name)
    _ -> Error(Nil)
  }
}

/// Follow a path of object keys.
///
/// ```gleam
/// get(value, at: ["user", "name"])
/// ```
pub fn get(json: Json, at path: List(String)) -> Result(Json, Nil) {
  list.try_fold(path, json, fn(current, key) { field(current, named: key) })
}

/// Index into an array.
pub fn index(json: Json, at i: Int) -> Result(Json, Nil) {
  case json {
    Array(items) if i >= 0 -> list.first(list.drop(items, i))
    _ -> Error(Nil)
  }
}

/// Convert an object to a `Dict` for repeated `O(1)` lookups. Later keys win
/// on duplicates.
pub fn to_dict(json: Json) -> Result(Dict(String, Json), Nil) {
  case json {
    Object(entries) -> Ok(dict.from_list(entries))
    _ -> Error(Nil)
  }
}

pub fn as_string(json: Json) -> Result(String, Nil) {
  case json {
    String(value) -> Ok(value)
    _ -> Error(Nil)
  }
}

pub fn as_int(json: Json) -> Result(Int, Nil) {
  case json {
    Int(value) -> Ok(value)
    _ -> Error(Nil)
  }
}

pub fn as_float(json: Json) -> Result(Float, Nil) {
  case json {
    Float(value) -> Ok(value)
    Int(value) -> Ok(int.to_float(value))
    _ -> Error(Nil)
  }
}

pub fn as_bool(json: Json) -> Result(Bool, Nil) {
  case json {
    Bool(value) -> Ok(value)
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------------------
// Pretty printing
// ---------------------------------------------------------------------------

/// Render a `Json` value as indented, human-readable text using two spaces per
/// nesting level.
///
/// ```gleam
/// to_string_pretty(Object([#("a", Int(1))]))
/// // -> "{\n  \"a\": 1\n}"
/// ```
pub fn to_string_pretty(json: Json) -> String {
  to_string_pretty_with(json, spaces: 2)
}

/// Like `to_string_pretty`, but with a configurable number of spaces per level.
pub fn to_string_pretty_with(json: Json, spaces spaces: Int) -> String {
  json
  |> pretty(0, spaces)
  |> string_tree.to_string
}

fn pretty(json: Json, depth: Int, spaces: Int) -> StringTree {
  case json {
    Array([]) -> string_tree.from_string("[]")
    Object([]) -> string_tree.from_string("{}")
    Array(items) -> pretty_array(items, depth, spaces)
    Object(entries) -> pretty_object(entries, depth, spaces)
    // Scalars render the same as in compact mode.
    _ -> to_string_tree(json)
  }
}

fn pretty_array(items: List(Json), depth: Int, spaces: Int) -> StringTree {
  let item_indent = string.repeat(" ", { depth + 1 } * spaces)
  let close_indent = string.repeat(" ", depth * spaces)
  let body =
    items
    |> list.map(fn(item) {
      string_tree.from_string(item_indent)
      |> string_tree.append_tree(pretty(item, depth + 1, spaces))
    })
    |> join_trees(",\n")
  string_tree.from_string("[\n")
  |> string_tree.append_tree(body)
  |> string_tree.append("\n")
  |> string_tree.append(close_indent)
  |> string_tree.append("]")
}

fn pretty_object(
  entries: List(#(String, Json)),
  depth: Int,
  spaces: Int,
) -> StringTree {
  let item_indent = string.repeat(" ", { depth + 1 } * spaces)
  let close_indent = string.repeat(" ", depth * spaces)
  let body =
    entries
    |> list.map(fn(entry) {
      let #(key, value) = entry
      string_tree.from_string(item_indent)
      |> string_tree.append("\"")
      |> string_tree.append_tree(escape_string(key))
      |> string_tree.append("\": ")
      |> string_tree.append_tree(pretty(value, depth + 1, spaces))
    })
    |> join_trees(",\n")
  string_tree.from_string("{\n")
  |> string_tree.append_tree(body)
  |> string_tree.append("\n")
  |> string_tree.append(close_indent)
  |> string_tree.append("}")
}

fn join_trees(trees: List(StringTree), separator: String) -> StringTree {
  case trees {
    [] -> string_tree.new()
    [first, ..rest] ->
      list.fold(rest, first, fn(acc, tree) {
        acc
        |> string_tree.append(separator)
        |> string_tree.append_tree(tree)
      })
  }
}

// ---------------------------------------------------------------------------
// Merging (JSON Merge Patch, RFC 7386)
// ---------------------------------------------------------------------------

/// Merge `patch` into `base`. Objects are merged recursively, a `Null` in the
/// patch removes that key, and any non-object patch replaces the base value.
/// Handy for layering configuration or applying partial updates.
///
/// ```gleam
/// merge(into: Object([#("a", Int(1)), #("b", Int(2))]), patch: Object([#("b", Null)]))
/// // -> Object([#("a", Int(1))])
/// ```
pub fn merge(into base: Json, patch patch: Json) -> Json {
  case base, patch {
    Object(base_entries), Object(patch_entries) ->
      Object(merge_entries(base_entries, patch_entries))
    _, _ -> patch
  }
}

fn merge_entries(
  base: List(#(String, Json)),
  patch: List(#(String, Json)),
) -> List(#(String, Json)) {
  list.fold(patch, base, fn(acc, entry) {
    let #(key, value) = entry
    case value {
      Null -> list.filter(acc, fn(kv) { kv.0 != key })
      _ -> upsert(acc, key, merge(value_for(acc, key), value))
    }
  })
}

fn value_for(entries: List(#(String, Json)), key: String) -> Json {
  case list.key_find(entries, key) {
    Ok(value) -> value
    Error(_) -> Null
  }
}

fn upsert(
  entries: List(#(String, Json)),
  key: String,
  value: Json,
) -> List(#(String, Json)) {
  case list.any(entries, fn(kv) { kv.0 == key }) {
    True ->
      list.map(entries, fn(kv) {
        case kv.0 == key {
          True -> #(key, value)
          False -> kv
        }
      })
    False -> list.append(entries, [#(key, value)])
  }
}

// ---------------------------------------------------------------------------
// Structural comparison
// ---------------------------------------------------------------------------

/// Compare two values for equality while ignoring the order of object keys.
/// Arrays stay order-sensitive, since JSON arrays are ordered. Great for tests
/// where `==` would be too strict about key order.
pub fn semantically_equal(a: Json, b: Json) -> Bool {
  case a, b {
    Object(entries_a), Object(entries_b) ->
      list.length(entries_a) == list.length(entries_b)
      && list.all(entries_a, fn(entry) {
        case list.key_find(entries_b, entry.0) {
          Ok(value_b) -> semantically_equal(entry.1, value_b)
          Error(_) -> False
        }
      })
    Array(items_a), Array(items_b) -> elements_equal(items_a, items_b)
    _, _ -> a == b
  }
}

fn elements_equal(a: List(Json), b: List(Json)) -> Bool {
  case a, b {
    [], [] -> True
    [x, ..xs], [y, ..ys] -> semantically_equal(x, y) && elements_equal(xs, ys)
    _, _ -> False
  }
}

// ---------------------------------------------------------------------------
// JSON Pointer (RFC 6901)
// ---------------------------------------------------------------------------

/// Look up a value by a JSON Pointer string, e.g. `"/user/items/0/id"`.
///
/// An empty string returns the whole document. Object keys containing `/` or
/// `~` are escaped as `~1` and `~0` respectively, per RFC 6901.
///
/// ```gleam
/// pointer(value, "/a/b/1")   // 2nd element of a.b
/// pointer(value, "")         // the whole value
/// pointer(value, "/a~1b")    // the key "a/b"
/// ```
pub fn pointer(json: Json, path: String) -> Result(Json, Nil) {
  case path {
    "" -> Ok(json)
    _ ->
      case string.split(path, "/") {
        // A valid pointer starts with "/", so the first token is empty.
        ["", ..tokens] ->
          follow_tokens(json, list.map(tokens, unescape_token))
        _ -> Error(Nil)
      }
  }
}

fn follow_tokens(json: Json, tokens: List(String)) -> Result(Json, Nil) {
  case tokens {
    [] -> Ok(json)
    [token, ..rest] -> {
      use child <- result.try(resolve_token(json, token))
      follow_tokens(child, rest)
    }
  }
}

fn resolve_token(json: Json, token: String) -> Result(Json, Nil) {
  case json {
    Object(_) -> field(json, named: token)
    Array(_) ->
      case int.parse(token) {
        Ok(i) -> index(json, at: i)
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn unescape_token(token: String) -> String {
  // Order matters: "~1" before "~0", per RFC 6901.
  token
  |> string.replace("~1", "/")
  |> string.replace("~0", "~")
}
