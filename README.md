# gleamson ✨

A pure-Gleam JSON library: a transparent value tree, a single-pass parser, and
combinator decoders. No FFI, no platform JSON dependency, identical behaviour on
Erlang and JavaScript.

```sh
gleam add gleamson
```

## Why another JSON library?

`gleamson` is written entirely in Gleam instead of delegating to the runtime's
native JSON facilities. The trade that buys you:

- **No Erlang/OTP version requirement.** Works wherever Gleam works.
- **The same behaviour on both targets**, down to the error positions.
- **Precise, positioned parse errors** on every runtime — no scraping of
  browser error strings.
- **A transparent `Json` type** you can pattern match on, walk, and build
  directly. JSON is just data here, not an opaque handle.

Honest note on speed: parsing leans on Gleam's bit-array pattern matching, which
is fast on the BEAM and allocation-light. For very large payloads on the
JavaScript target, a runtime's native `JSON.parse` (written in C++) will still
win on raw throughput. If you need that, parse natively and feed the result into
a `decode.Decoder`; the decoder layer doesn't care where the value came from.

## Encoding

```gleam
import gleamson.{Int, Null, Object, String}

Object([
  #("name", String("Lucy")),
  #("lives", Int(9)),
  #("flaws", Null),
  #("nicknames", gleamson.array(["Boo", "Bug"], of: String)),
])
|> gleamson.to_string
// -> {"name":"Lucy","lives":9,"flaws":null,"nicknames":["Boo","Bug"]}
```

Because `Json` is a transparent type, encoding is just building a value with its
constructors. The helpers `array`, `nullable`, and `from_dict` cover the common
shapes.

## Parsing into a value

```gleam
import gleamson

let assert Ok(value) = gleamson.parse("{\"user\":{\"name\":\"Ada\"}}")

gleamson.get(value, at: ["user", "name"])
// -> Ok(String("Ada"))
```

`field`, `get`, `index`, `to_dict`, and the `as_*` helpers let you walk a value
without ceremony. Object entries keep their order and duplicates, so
`parse |> to_string` round-trips faithfully.

## Decoding into your own types

```gleam
import gleamson
import gleamson/decode

pub type Cat {
  Cat(name: String, lives: Int, nicknames: List(String))
}

pub fn cat_from_json(text: String) -> Result(Cat, decode.Error) {
  let cat = {
    use name <- decode.field("name", decode.string)
    use lives <- decode.field("lives", decode.int)
    use nicknames <- decode.field("nicknames", decode.list(decode.string))
    decode.success(Cat(name:, lives:, nicknames:))
  }
  decode.from_string(text, cat)
}
```

A `Decoder(t)` is simply `fn(Json) -> #(t, List(DecodeError))`, so writing a
custom one is just writing a function.

**Errors accumulate.** When several fields are wrong, you get every error in
one go rather than stopping at the first:

```gleam
// {"name": 42, "lives": "nine"}  ->
//   Error(CouldNotDecode([
//     DecodeError("String", "Int", ["name"]),
//     DecodeError("Int", "String", ["lives"]),
//   ]))
```

Each error carries a `path` (e.g. `["lives"]`, or `["items", "2", "id"]` for
nested structures) pointing straight at the offending value.

Two runners let you choose how much you want back:

- `run(json, decoder) -> Result(t, List(DecodeError))` — every error.
- `run_first(json, decoder) -> Result(t, DecodeError)` — just the first.
- `from_string(text, decoder) -> Result(t, Error)` — parse + decode, with all
  decode errors wrapped in `CouldNotDecode`.

Combinators: `field`, `optional_field`, `at`, `list`, `dict`, `optional`, `map`,
`success`, `failure`, and the primitives `string` / `int` / `float` / `bool` /
`json`.

## Layout

```
src/gleamson.gleam        -- Json type, parser, encoder, value helpers
src/gleamson/decode.gleam -- combinator decoders over Json
test/gleamson_test.gleam  -- examples that double as a test suite
```

## License

Apache-2.0

## More utilities

**Pretty printing** — `to_string_pretty(json)` (2 spaces) or
`to_string_pretty_with(json, spaces: 4)` for human-readable, indented output.

**Merging** — `merge(into:, patch:)` applies a JSON Merge Patch (RFC 7386):
objects merge recursively, a `Null` deletes a key, anything else replaces.
Useful for layering config or applying partial updates.

**Structural equality** — `semantically_equal(a, b)` compares values while
ignoring object key order (arrays stay ordered). Handy in tests.

**Extra decoders** — alongside `field` / `list` / `dict` / `optional`:

- `one_of(first, [others])` — try decoders in turn, first success wins.
- `then(decoder, apply:)` — decode, then choose the next decoder; great for
  validation or discriminated unions keyed on a `"type"` field.
- `index(at:, of:)` — decode a single array element by position.

**Enum decoding** — `enum(first, or: [...])` maps JSON strings to your own
type's variants: `enum(#("buy", Buy), or: [#("sell", Sell)])`.

**JSON Pointer (RFC 6901)** — `pointer(value, "/a/items/0/id")` looks up a
value by path string; `""` returns the whole document, and keys with `/` or `~`
use the `~1` / `~0` escapes.

## JSON Patch (RFC 6902)

The `gleamson/patch` module applies and computes patches.

```gleam
import gleamson
import gleamson/patch.{Add, Replace}

let assert Ok(doc) = gleamson.parse("{\"a\":1,\"b\":[10]}")

// apply (atomic: all ops succeed, or none are applied)
let assert Ok(out) =
  patch.apply(doc, [Replace("/a", gleamson.Int(2)), Add("/b/-", gleamson.Int(20))])

// diff two documents into a patch
let ops = patch.diff(from: doc, to: out)

// patches are JSON too
patch.to_json(ops)                          // -> a Json array
decode.run(some_json, patch.decoder())      // -> Result(List(Operation), _)
```

Operations: `Add`, `Remove`, `Replace`, `Move`, `Copy`, `Test` (paths are JSON
Pointers). `diff` is correct but not minimal — array edits are positional, with
no move detection.
