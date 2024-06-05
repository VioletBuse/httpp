import gleam/bit_array
import gleam/bool
import gleam/bytes_builder.{type BytesBuilder}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/http.{type Header, type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

pub type Error {
  /// Hackney Error Type
  Other(Dynamic)
  NoStatusOrHeaders
  /// could not decode BitArray to string
  InvalidUtf8Response
  /// when expecting a client ref, we did not get one back
  NoClientRefReturned
}

/// A hackney client_ref
pub type ClientRef

type FfiResponse {
  ClientRefResponse(Int, List(Header), ClientRef)
  BinaryResponse(Int, List(Header), BitArray)
  ResponseWithoutBody(Int, List(Header))
  SoloClientRefResponse(ClientRef)
}

type Options {
  WithBody(Bool)
  Async
}

@external(erlang, "httpp_ffi", "send")
fn send_ffi(
  a: Method,
  b: String,
  c: List(http.Header),
  d: BytesBuilder,
  e: List(Options),
) -> Result(FfiResponse, Error)

@external(erlang, "hackney", "body")
fn body_ffi(a: ClientRef) -> Result(BitArray, Error)

/// retrieve the full body from a client_ref
pub fn body(ref client_ref: ClientRef) -> Result(BitArray, Error) {
  body_ffi(client_ref)
}

/// retrieve the full body from a client ref as a string
pub fn body_string(ref client_ref: ClientRef) -> Result(String, Error) {
  use bits <- result.try(body_ffi(client_ref))
  bit_array.to_string(bits) |> result.map_error(fn(_) { InvalidUtf8Response })
}

/// send and receive bits from the server
pub fn send_bits(
  req: Request(BytesBuilder),
) -> Result(Response(BitArray), Error) {
  use response <- result.then(
    req
    |> request.to_uri
    |> uri.to_string
    |> send_ffi(req.method, _, req.headers, req.body, [WithBody(True)]),
  )

  case response {
    ClientRefResponse(status, headers, client_ref) -> {
      use bits <- result.try(body_ffi(client_ref))
      Ok(Response(
        status: status,
        headers: list.map(headers, normalize_header),
        body: bits,
      ))
    }
    BinaryResponse(status, headers, bits) ->
      Ok(Response(
        status: status,
        headers: list.map(headers, normalize_header),
        body: bits,
      ))
    ResponseWithoutBody(status, headers) ->
      Ok(
        Response(
          status: status,
          headers: list.map(headers, normalize_header),
          body: <<>>,
        ),
      )
    SoloClientRefResponse(..) ->
      panic as "hackney was not set to stream so this response should not be possible"
  }
}

/// send a request to the server and get a client ref back, which you can use to get response info and such
pub fn send_async(req: Request(BytesBuilder)) -> Result(ClientRef, Error) {
  use response <- result.then(
    req
    |> request.to_uri
    |> uri.to_string
    |> send_ffi(req.method, _, req.headers, req.body, [Async]),
  )

  case response {
    ClientRefResponse(_, _, client_ref) -> Ok(client_ref)
    SoloClientRefResponse(client_ref) -> Ok(client_ref)
    _ -> Error(NoClientRefReturned)
  }
}

pub type HttppMessage {
  Status(Int)
  Headers(List(Header))
  Binary(BitArray)
  Redirect(String, List(Header))
  SeeOther(String, List(Header))
  DoneStreaming
  /// In case we couldn't decode the message, you'll get the dynamic version
  NotDecoded(Dynamic)
}

@external(erlang, "httpp_ffi", "insert_selector_handler")
fn insert_selector_handler(
  a: Selector(payload),
  for for: tag,
  mapping mapping: fn(message) -> payload,
) -> Selector(payload)

fn decode_on_atom_disc(
  atom: atom.Atom,
  decoder: fn(Dynamic) -> Result(a, dynamic.DecodeErrors),
) -> fn(Dynamic) -> Result(a, dynamic.DecodeErrors) {
  fn(dyn) {
    use decoded_atom <- result.try(dynamic.element(0, atom.from_dynamic)(dyn))
    use <- bool.guard(
      when: decoded_atom != atom,
      return: Error([
        dynamic.DecodeError(
          found: "atom: " <> atom.to_string(decoded_atom),
          expected: "atom: " <> atom.to_string(atom),
          path: [],
        ),
      ]),
    )

    decoder(dyn)
  }
}

/// if sending with async, put this in your selector to receive messages related to your request
pub fn selecting_http_message(
  selector: Selector(a),
  mapping transform: fn(ClientRef, HttppMessage) -> a,
) -> Selector(a) {
  let handler = fn(message: #(atom.Atom, ClientRef, Dynamic)) {
    let headers_decoder =
      dynamic.list(dynamic.tuple2(dynamic.string, dynamic.string))

    let decoder =
      dynamic.any([
        decode_on_atom_disc(
          atom.create_from_string("status"),
          dynamic.decode1(Status, dynamic.element(1, dynamic.int)),
        ),
        decode_on_atom_disc(
          atom.create_from_string("headers"),
          dynamic.decode1(Headers, dynamic.element(1, headers_decoder)),
        ),
        dynamic.decode1(Binary, dynamic.bit_array),
        decode_on_atom_disc(
          atom.create_from_string("redirect"),
          dynamic.decode2(
            Redirect,
            dynamic.element(1, dynamic.string),
            dynamic.element(2, headers_decoder),
          ),
        ),
        decode_on_atom_disc(
          atom.create_from_string("see_other"),
          dynamic.decode2(
            SeeOther,
            dynamic.element(1, dynamic.string),
            dynamic.element(2, headers_decoder),
          ),
        ),
        fn(a) {
          use atom <- result.try(atom.from_dynamic(a))
          let atom_str = atom.to_string(atom)
          case atom_str {
            "done" -> Ok(DoneStreaming)
            found ->
              Error([
                dynamic.DecodeError(found: found, expected: "done", path: []),
              ])
          }
        },
        fn(b) { Ok(NotDecoded(b)) },
      ])

    let assert Ok(http_message) = decoder(message.2)

    transform(message.1, http_message)
  }

  let tag = atom.create_from_string("hackney_response")

  insert_selector_handler(selector, #(tag, 3), handler)
}

/// send a normal http request with text and stuff
pub fn send(req: Request(String)) -> Result(Response(String), Error) {
  use response <- result.then(
    req
    |> request.map(bytes_builder.from_string)
    |> send_bits,
  )

  case bit_array.to_string(response.body) {
    Error(_) -> Error(InvalidUtf8Response)
    Ok(body) -> Ok(response.set_body(response, body))
  }
}

@external(erlang, "hackney", "stream_body")
fn stream_body_ffi(a: ClientRef) -> Dynamic

pub type StreamBodyResult {
  Next(BitArray)
  Done
  Err(Dynamic)
}

fn decode_stream_body_next(
  dyn: Dynamic,
) -> Result(StreamBodyResult, dynamic.DecodeErrors) {
  use atom <- result.try(dynamic.element(0, atom.from_dynamic)(dyn))
  use next_bits <- result.try(dynamic.element(1, dynamic.bit_array)(dyn))

  let atom_str = atom.to_string(atom)
  case atom_str {
    "ok" -> Ok(Next(next_bits))
    found ->
      Error([dynamic.DecodeError(found: found, expected: "ok", path: [])])
  }
}

fn decode_stream_body_done(
  dyn: Dynamic,
) -> Result(StreamBodyResult, dynamic.DecodeErrors) {
  dynamic.any([
    fn(a) {
      use atom <- result.try(atom.from_dynamic(a))
      let str_repr = atom.to_string(atom)
      case str_repr {
        "done" -> Ok(Done)
        found ->
          Error([dynamic.DecodeError(expected: "done", found: found, path: [])])
      }
    },
    fn(b) {
      use atom <- result.try(dynamic.element(0, atom.from_dynamic)(b))
      let str_repr = atom.to_string(atom)
      case str_repr {
        "done" -> Ok(Done)
        found ->
          Error([dynamic.DecodeError(expected: "done", found: found, path: [])])
      }
    },
  ])(dyn)
}

fn decode_stream_body_error(
  dyn: Dynamic,
) -> Result(StreamBodyResult, dynamic.DecodeErrors) {
  use atom <- result.try(dynamic.element(0, atom.from_dynamic)(dyn))
  use error_term <- result.try(dynamic.element(1, dynamic.dynamic)(dyn))

  let string_repr = atom.to_string(atom)

  case string_repr {
    "error" -> Ok(Err(error_term))
    found ->
      Error([dynamic.DecodeError(expected: "error", found: found, path: [])])
  }
}

fn stream_body_internal(ref: ClientRef) -> StreamBodyResult {
  let decoder =
    dynamic.any([
      decode_stream_body_next,
      decode_stream_body_done,
      decode_stream_body_error,
      fn(a) { Ok(Err(a)) },
    ])

  let dyn = stream_body_ffi(ref)

  let assert Ok(result) = decoder(dyn)

  result
}

// fn receive(ref: ClientRef) -> StreamBodyResult {
//   stream_body_internal(ref)
// }

fn normalize_header(header: http.Header) -> http.Header {
  #(string.lowercase(header.0), header.1)
}
