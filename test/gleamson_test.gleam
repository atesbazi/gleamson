import gleam/list
import gleeunit
import gleeunit/should
import gleamson.{Array, Bool, Float, Int, Null, Object, String}
import gleamson/decode
import gleamson/patch.{Add, Replace, Test}

pub fn main() {
  gleeunit.main()
}

// --- Parsing ---------------------------------------------------------------

pub fn parse_primitives_test() {
  gleamson.parse("null") |> should.equal(Ok(Null))
  gleamson.parse("true") |> should.equal(Ok(Bool(True)))
  gleamson.parse("false") |> should.equal(Ok(Bool(False)))
  gleamson.parse("42") |> should.equal(Ok(Int(42)))
  gleamson.parse("-7") |> should.equal(Ok(Int(-7)))
  gleamson.parse("3.14") |> should.equal(Ok(Float(3.14)))
  gleamson.parse("1e3") |> should.equal(Ok(Float(1000.0)))
  gleamson.parse("\"hi\"") |> should.equal(Ok(String("hi")))
}

pub fn parse_whitespace_test() {
  gleamson.parse("  [ 1 , 2 ]  ")
  |> should.equal(Ok(Array([Int(1), Int(2)])))
}

pub fn parse_nested_test() {
  let assert Ok(value) =
    gleamson.parse("{\"user\":{\"name\":\"Ada\",\"tags\":[\"a\",\"b\"]}}")
  gleamson.get(value, ["user", "name"])
  |> should.equal(Ok(String("Ada")))
}

pub fn parse_escapes_test() {
  gleamson.parse("\"a\\nb\\t\\\"c\"")
  |> should.equal(Ok(String("a\nb\t\"c")))
}

pub fn parse_unicode_test() {
  gleamson.parse("\"\\u00e7\"") |> should.equal(Ok(String("ç")))
}

pub fn parse_errors_test() {
  gleamson.parse("[") |> should.equal(Error(gleamson.UnexpectedEnd))
  gleamson.parse("") |> should.equal(Error(gleamson.UnexpectedEnd))

  let assert Error(gleamson.UnexpectedByte(_, _)) = gleamson.parse("{1}")
  Nil
}

// --- Encoding --------------------------------------------------------------

pub fn encode_test() {
  Object([#("game", String("Pac-Man")), #("score", Int(3_333_360))])
  |> gleamson.to_string
  |> should.equal("{\"game\":\"Pac-Man\",\"score\":3333360}")
}

pub fn round_trip_test() {
  let text = "{\"a\":[1,true,null,\"x\"],\"b\":1.5}"
  let assert Ok(value) = gleamson.parse(text)
  gleamson.to_string(value) |> should.equal(text)
}

// --- Decoding --------------------------------------------------------------

pub type Cat {
  Cat(name: String, lives: Int, nicknames: List(String))
}

fn cat_decoder() -> decode.Decoder(Cat) {
  use name <- decode.field("name", decode.string)
  use lives <- decode.field("lives", decode.int)
  use nicknames <- decode.field("nicknames", decode.list(decode.string))
  decode.success(Cat(name:, lives:, nicknames:))
}

pub fn decode_record_test() {
  let text = "{\"name\":\"Nono\",\"lives\":9,\"nicknames\":[\"Bug\",\"Boo\"]}"
  decode.from_string(text, cat_decoder())
  |> should.equal(Ok(Cat("Nono", 9, ["Bug", "Boo"])))
}

pub fn decode_error_path_test() {
  let text = "{\"name\":\"Nono\",\"lives\":\"nine\",\"nicknames\":[]}"
  let assert Error(decode.CouldNotDecode([error])) =
    decode.from_string(text, cat_decoder())
  error.path |> should.equal(["lives"])
}

pub fn decode_accumulates_test() {
  // Both `name` and `lives` have the wrong type; we expect *both* errors.
  let text = "{\"name\":42,\"lives\":\"nine\",\"nicknames\":[]}"
  let assert Error(decode.CouldNotDecode(errors)) =
    decode.from_string(text, cat_decoder())
  list.map(errors, fn(error) { error.path })
  |> should.equal([["name"], ["lives"]])
}

pub fn decode_run_first_test() {
  let assert Ok(value) = gleamson.parse("{\"name\":42,\"lives\":\"nine\"}")
  let assert Error(error) = decode.run_first(value, cat_decoder())
  error.path |> should.equal(["name"])
}

// --- New features ----------------------------------------------------------

pub fn pretty_test() {
  Object([#("a", Int(1)), #("b", Array([Int(2), Int(3)]))])
  |> gleamson.to_string_pretty
  |> should.equal("{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}")
}

pub fn merge_test() {
  let base = Object([#("a", Int(1)), #("b", Object([#("x", Int(1))]))])
  let patch = Object([#("b", Object([#("y", Int(2))])), #("a", Null)])
  gleamson.merge(base, patch)
  |> gleamson.to_string
  |> should.equal("{\"b\":{\"x\":1,\"y\":2}}")
}

pub fn semantic_equal_test() {
  let a = Object([#("x", Int(1)), #("y", Int(2))])
  let b = Object([#("y", Int(2)), #("x", Int(1))])
  should.equal(gleamson.semantically_equal(a, b), True)
  should.equal(a == b, False)
}

fn bool_to_int(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
}

pub fn one_of_test() {
  let dec = decode.one_of(decode.int, [decode.map(decode.bool, bool_to_int)])
  decode.run(Int(5), dec) |> should.equal(Ok(5))
  decode.run(Bool(True), dec) |> should.equal(Ok(1))
}

pub fn then_test() {
  let dec =
    decode.then(decode.int, fn(n) {
      case n >= 0 {
        True -> decode.success(n)
        False -> decode.failure(0, "a non-negative int")
      }
    })
  decode.run(Int(7), dec) |> should.equal(Ok(7))
  let assert Error([error]) = decode.run(Int(-1), dec)
  error.expected |> should.equal("a non-negative int")
}

pub fn index_decode_test() {
  decode.run(Array([String("a"), String("b")]), decode.index(1, decode.string))
  |> should.equal(Ok("b"))
}

pub fn pointer_test() {
  let assert Ok(value) = gleamson.parse("{\"a\":{\"b\":[10,20,30]}}")
  gleamson.pointer(value, "/a/b/1") |> should.equal(Ok(Int(20)))
  gleamson.pointer(value, "") |> should.equal(Ok(value))
  gleamson.pointer(value, "/a/x") |> should.equal(Error(Nil))
}

pub fn pointer_escape_test() {
  let assert Ok(value) = gleamson.parse("{\"a/b\":1,\"m~n\":2}")
  gleamson.pointer(value, "/a~1b") |> should.equal(Ok(Int(1)))
  gleamson.pointer(value, "/m~0n") |> should.equal(Ok(Int(2)))
}

pub type Side {
  Buy
  Sell
}

pub fn enum_test() {
  let side = decode.enum(#("buy", Buy), [#("sell", Sell)])
  decode.run(String("sell"), side) |> should.equal(Ok(Sell))
  let assert Error([error]) = decode.run(String("hold"), side)
  error.found |> should.equal("\"hold\"")
}

pub fn patch_apply_test() {
  let assert Ok(doc) = gleamson.parse("{\"a\":1,\"b\":[10,20]}")
  let ops = [Replace("/a", Int(2)), Add("/b/-", Int(30)), Add("/c", String("new"))]
  let assert Ok(result) = patch.apply(doc, ops)
  result
  |> gleamson.to_string
  |> should.equal("{\"a\":2,\"b\":[10,20,30],\"c\":\"new\"}")
}

pub fn patch_test_op_test() {
  let assert Ok(doc) = gleamson.parse("{\"a\":1}")
  patch.apply(doc, [Test("/a", Int(2))])
  |> should.equal(Error(patch.TestFailed("/a", Int(2), Int(1))))
}

pub fn diff_roundtrip_test() {
  let assert Ok(from) = gleamson.parse("{\"a\":1,\"b\":2,\"c\":[1,2]}")
  let assert Ok(to) = gleamson.parse("{\"a\":1,\"b\":3,\"c\":[1,2,4]}")
  let assert Ok(result) = patch.apply(from, patch.diff(from, to))
  gleamson.semantically_equal(result, to) |> should.equal(True)
}

pub fn patch_json_roundtrip_test() {
  let ops = [Replace("/b", Int(3)), Add("/c/-", Int(4))]
  let assert Ok(decoded) = decode.run(patch.to_json(ops), patch.decoder())
  decoded |> should.equal(ops)
}
