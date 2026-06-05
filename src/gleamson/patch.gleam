//// JSON Patch (RFC 6902): describe and apply changes to a `gleamson.Json`
//// document, and compute the difference between two documents.
////
//// A patch is a list of `Operation`s applied in order and atomically — if any
//// operation fails, `apply` returns an error and the original document is
//// left untouched. Paths are JSON Pointers (RFC 6901).
////
//// ```gleam
//// import gleamson
//// import gleamson/patch.{Add, Replace}
////
//// let assert Ok(doc) = gleamson.parse("{\"a\":1,\"b\":[10]}")
//// let assert Ok(out) =
////   patch.apply(doc, [Replace("/a", gleamson.Int(2)), Add("/b/-", gleamson.Int(20))])
//// // out == {"a":2,"b":[10,20]}
//// ```

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleamson.{type Json, Array, Object, String}
import gleamson/decode

/// A single JSON Patch operation. Paths and `from` are JSON Pointer strings.
pub type Operation {
  Add(path: String, value: Json)
  Remove(path: String)
  Replace(path: String, value: Json)
  Move(from: String, path: String)
  Copy(from: String, path: String)
  Test(path: String, value: Json)
}

/// Why applying a patch failed.
pub type PatchError {
  /// A path referred to a location that does not exist.
  PathNotFound(path: String)
  /// A path was not a valid JSON Pointer for the target.
  InvalidPath(path: String)
  /// A `Test` operation did not match.
  TestFailed(path: String, expected: Json, actual: Json)
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------

/// Apply a patch to a document. All operations succeed, or none are applied.
pub fn apply(
  json: Json,
  operations: List(Operation),
) -> Result(Json, PatchError) {
  list.try_fold(operations, json, apply_one)
}

fn apply_one(json: Json, operation: Operation) -> Result(Json, PatchError) {
  case operation {
    Add(path, value) -> {
      use path <- result.try(tokens(path))
      add_at(json, path, value)
    }
    Remove(path) -> {
      use path <- result.try(tokens(path))
      remove_at(json, path)
    }
    Replace(path, value) -> {
      use path <- result.try(tokens(path))
      replace_at(json, path, value)
    }
    Copy(from, path) -> {
      use from <- result.try(tokens(from))
      use path <- result.try(tokens(path))
      use value <- result.try(get_at(json, from))
      add_at(json, path, value)
    }
    Move(from, path) -> {
      use from <- result.try(tokens(from))
      use path <- result.try(tokens(path))
      use value <- result.try(get_at(json, from))
      use without <- result.try(remove_at(json, from))
      add_at(without, path, value)
    }
    Test(path, value) -> {
      use parsed <- result.try(tokens(path))
      use actual <- result.try(get_at(json, parsed))
      case gleamson.semantically_equal(actual, value) {
        True -> Ok(json)
        False -> Error(TestFailed(path, value, actual))
      }
    }
  }
}

// --- Pointer-based read/insert/remove --------------------------------------

fn get_at(json: Json, path: List(String)) -> Result(Json, PatchError) {
  case path {
    [] -> Ok(json)
    [head, ..rest] -> {
      use child <- result.try(get_child(json, head))
      get_at(child, rest)
    }
  }
}

fn add_at(
  json: Json,
  path: List(String),
  value: Json,
) -> Result(Json, PatchError) {
  case path {
    // Adding at the root replaces the whole document.
    [] -> Ok(value)
    [token] -> add_here(json, token, value)
    [head, ..rest] -> {
      use child <- result.try(get_child(json, head))
      use updated <- result.try(add_at(child, rest, value))
      set_child(json, head, updated)
    }
  }
}

fn add_here(json: Json, token: String, value: Json) -> Result(Json, PatchError) {
  case json {
    Object(entries) -> Ok(Object(set_key(entries, token, value)))
    Array(items) ->
      case token {
        "-" -> Ok(Array(list.append(items, [value])))
        _ ->
          case parse_index(token) {
            Ok(i) ->
              case i <= list.length(items) {
                True -> Ok(Array(insert_at(items, i, value)))
                False -> Error(PathNotFound(token))
              }
            Error(_) -> Error(InvalidPath(token))
          }
      }
    _ -> Error(PathNotFound(token))
  }
}

fn remove_at(json: Json, path: List(String)) -> Result(Json, PatchError) {
  case path {
    [] -> Error(InvalidPath(""))
    [token] -> remove_here(json, token)
    [head, ..rest] -> {
      use child <- result.try(get_child(json, head))
      use updated <- result.try(remove_at(child, rest))
      set_child(json, head, updated)
    }
  }
}

fn remove_here(json: Json, token: String) -> Result(Json, PatchError) {
  case json {
    Object(entries) ->
      case has_key(entries, token) {
        True -> Ok(Object(delete_key(entries, token)))
        False -> Error(PathNotFound(token))
      }
    Array(items) ->
      case parse_index(token) {
        Ok(i) ->
          case i < list.length(items) {
            True -> Ok(Array(delete_at(items, i)))
            False -> Error(PathNotFound(token))
          }
        Error(_) -> Error(InvalidPath(token))
      }
    _ -> Error(PathNotFound(token))
  }
}

fn replace_at(
  json: Json,
  path: List(String),
  value: Json,
) -> Result(Json, PatchError) {
  case path {
    [] -> Ok(value)
    [token] -> replace_here(json, token, value)
    [head, ..rest] -> {
      use child <- result.try(get_child(json, head))
      use updated <- result.try(replace_at(child, rest, value))
      set_child(json, head, updated)
    }
  }
}

fn replace_here(
  json: Json,
  token: String,
  value: Json,
) -> Result(Json, PatchError) {
  case json {
    Object(entries) ->
      case has_key(entries, token) {
        True -> Ok(Object(set_key(entries, token, value)))
        False -> Error(PathNotFound(token))
      }
    Array(items) ->
      case parse_index(token) {
        Ok(i) ->
          case i < list.length(items) {
            True -> Ok(Array(replace_index(items, i, value)))
            False -> Error(PathNotFound(token))
          }
        Error(_) -> Error(InvalidPath(token))
      }
    _ -> Error(PathNotFound(token))
  }
}

fn get_child(json: Json, token: String) -> Result(Json, PatchError) {
  case json {
    Object(entries) ->
      case list.key_find(entries, token) {
        Ok(value) -> Ok(value)
        Error(_) -> Error(PathNotFound(token))
      }
    Array(items) ->
      case parse_index(token) {
        Ok(i) -> element_at(items, i, token)
        Error(_) -> Error(InvalidPath(token))
      }
    _ -> Error(PathNotFound(token))
  }
}

fn set_child(json: Json, token: String, child: Json) -> Result(Json, PatchError) {
  case json {
    Object(entries) -> Ok(Object(set_key(entries, token, child)))
    Array(items) ->
      case parse_index(token) {
        Ok(i) ->
          case i < list.length(items) {
            True -> Ok(Array(replace_index(items, i, child)))
            False -> Error(PathNotFound(token))
          }
        Error(_) -> Error(InvalidPath(token))
      }
    _ -> Error(PathNotFound(token))
  }
}

// ---------------------------------------------------------------------------
// Diffing
// ---------------------------------------------------------------------------

/// Compute a patch that turns `from` into `to`. The result is correct but not
/// guaranteed minimal: array changes are emitted positionally rather than by
/// detecting moves.
pub fn diff(from from: Json, to to: Json) -> List(Operation) {
  diff_at(from, to, "")
}

fn diff_at(from: Json, to: Json, path: String) -> List(Operation) {
  case gleamson.semantically_equal(from, to) {
    True -> []
    False ->
      case from, to {
        Object(a), Object(b) -> diff_objects(a, b, path)
        Array(a), Array(b) -> diff_arrays(a, b, path, 0)
        _, _ -> [Replace(path, to)]
      }
  }
}

fn diff_objects(
  a: List(#(String, Json)),
  b: List(#(String, Json)),
  path: String,
) -> List(Operation) {
  let removes =
    list.filter_map(a, fn(entry) {
      case has_key(b, entry.0) {
        True -> Error(Nil)
        False -> Ok(Remove(join(path, entry.0)))
      }
    })
  let changes =
    list.flat_map(b, fn(entry) {
      let #(key, value_b) = entry
      case list.key_find(a, key) {
        Ok(value_a) -> diff_at(value_a, value_b, join(path, key))
        Error(_) -> [Add(join(path, key), value_b)]
      }
    })
  list.append(removes, changes)
}

fn diff_arrays(
  a: List(Json),
  b: List(Json),
  path: String,
  i: Int,
) -> List(Operation) {
  case a, b {
    [], [] -> []
    [], [y, ..ys] -> [Add(join(path, "-"), y), ..diff_arrays([], ys, path, i)]
    // Removing repeatedly at the same index works: each removal shifts the
    // next element down into that index.
    [_, ..xs], [] -> [
      Remove(join(path, int.to_string(i))),
      ..diff_arrays(xs, [], path, i)
    ]
    [x, ..xs], [y, ..ys] ->
      list.append(
        diff_at(x, y, join(path, int.to_string(i))),
        diff_arrays(xs, ys, path, i + 1),
      )
  }
}

// ---------------------------------------------------------------------------
// JSON interop
// ---------------------------------------------------------------------------

/// Encode a patch as a JSON value (an array of operation objects).
pub fn to_json(operations: List(Operation)) -> Json {
  gleamson.array(operations, of: operation_to_json)
}

fn operation_to_json(operation: Operation) -> Json {
  case operation {
    Add(path, value) ->
      Object([
        #("op", String("add")),
        #("path", String(path)),
        #("value", value),
      ])
    Remove(path) -> Object([#("op", String("remove")), #("path", String(path))])
    Replace(path, value) ->
      Object([
        #("op", String("replace")),
        #("path", String(path)),
        #("value", value),
      ])
    Move(from, path) ->
      Object([
        #("op", String("move")),
        #("from", String(from)),
        #("path", String(path)),
      ])
    Copy(from, path) ->
      Object([
        #("op", String("copy")),
        #("from", String(from)),
        #("path", String(path)),
      ])
    Test(path, value) ->
      Object([
        #("op", String("test")),
        #("path", String(path)),
        #("value", value),
      ])
  }
}

/// A decoder for a JSON Patch document (an array of operations). Pair it with
/// `gleamson.parse` / `decode.from_string` to read a patch off the wire.
pub fn decoder() -> decode.Decoder(List(Operation)) {
  decode.list(operation_decoder())
}

fn operation_decoder() -> decode.Decoder(Operation) {
  use op <- decode.field("op", decode.string)
  case op {
    "add" -> {
      use path <- decode.field("path", decode.string)
      use value <- decode.field("value", decode.json)
      decode.success(Add(path, value))
    }
    "remove" -> {
      use path <- decode.field("path", decode.string)
      decode.success(Remove(path))
    }
    "replace" -> {
      use path <- decode.field("path", decode.string)
      use value <- decode.field("value", decode.json)
      decode.success(Replace(path, value))
    }
    "move" -> {
      use from <- decode.field("from", decode.string)
      use path <- decode.field("path", decode.string)
      decode.success(Move(from, path))
    }
    "copy" -> {
      use from <- decode.field("from", decode.string)
      use path <- decode.field("path", decode.string)
      decode.success(Copy(from, path))
    }
    "test" -> {
      use path <- decode.field("path", decode.string)
      use value <- decode.field("value", decode.json)
      decode.success(Test(path, value))
    }
    _ ->
      decode.failure(
        Remove(""),
        "a JSON Patch op (add/remove/replace/move/copy/test)",
      )
  }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn tokens(path: String) -> Result(List(String), PatchError) {
  case path {
    "" -> Ok([])
    _ ->
      case string.split(path, "/") {
        ["", ..rest] -> Ok(list.map(rest, unescape))
        _ -> Error(InvalidPath(path))
      }
  }
}

fn unescape(token: String) -> String {
  token
  |> string.replace("~1", "/")
  |> string.replace("~0", "~")
}

fn join(path: String, token: String) -> String {
  path <> "/" <> escape(token)
}

fn escape(token: String) -> String {
  token
  |> string.replace("~", "~0")
  |> string.replace("/", "~1")
}

fn parse_index(token: String) -> Result(Int, Nil) {
  case int.parse(token) {
    Ok(i) if i >= 0 -> Ok(i)
    _ -> Error(Nil)
  }
}

fn has_key(entries: List(#(String, Json)), key: String) -> Bool {
  list.any(entries, fn(entry) { entry.0 == key })
}

fn delete_key(
  entries: List(#(String, Json)),
  key: String,
) -> List(#(String, Json)) {
  list.filter(entries, fn(entry) { entry.0 != key })
}

fn set_key(
  entries: List(#(String, Json)),
  key: String,
  value: Json,
) -> List(#(String, Json)) {
  case has_key(entries, key) {
    True ->
      list.map(entries, fn(entry) {
        case entry.0 == key {
          True -> #(key, value)
          False -> entry
        }
      })
    False -> list.append(entries, [#(key, value)])
  }
}

fn element_at(items: List(Json), i: Int, token: String) -> Result(Json, PatchError) {
  let #(_, rest) = list.split(items, i)
  case rest {
    [value, ..] -> Ok(value)
    [] -> Error(PathNotFound(token))
  }
}

fn insert_at(items: List(Json), i: Int, value: Json) -> List(Json) {
  let #(before, after) = list.split(items, i)
  list.append(before, [value, ..after])
}

fn delete_at(items: List(Json), i: Int) -> List(Json) {
  let #(before, after) = list.split(items, i)
  case after {
    [_, ..tail] -> list.append(before, tail)
    [] -> before
  }
}

fn replace_index(items: List(Json), i: Int, value: Json) -> List(Json) {
  let #(before, after) = list.split(items, i)
  case after {
    [_, ..tail] -> list.append(before, [value, ..tail])
    [] -> list.append(before, [value])
  }
}
