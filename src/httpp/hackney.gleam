//// This module contains the base code to interact with hackney in a low-level manner

import gleam/bit_array
import gleam/bool
import gleam/bytes_builder.{type BytesBuilder}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/http.{type Header, type Method}
import gleam/result

pub type Error {
  /// Hackney Error Type
  Other(Dynamic)
  /// Error returned when the connection is unexpectedly closed
  ConnectionClosed(partial_body: BitArray)
  TimedOut
  NoStatusOrHeaders
  /// could not decode BitArray to string
  InvalidUtf8Response
  /// when expecting a client ref, we did not get one back
  NoClientRefReturned
  /// when the client has already received a message and doesn't expect the message
  UnexpectedServerMessage(HttppMessage)
  /// when the client receives a message that it can't decode
  MessageNotDecoded(Dynamic)
}

/// A hackney client_ref
pub type ClientRef

/// Response of the hackney http client
pub type HackneyResponse {
  /// Received on response when neither `WithBody` or `Async` are used
  ClientRefResponse(status: Int, headers: List(Header), client_ref: ClientRef)
  /// Received when you use the `WithBody(True)` Option
  BinaryResponse(status: Int, headers: List(Header), body: BitArray)
  /// This is received on a HEAD request when response succeeded
  EmptyResponse(status: Int, headers: List(Header))
  /// This is received when used with the option Async
  /// You can use the passed in client ref to disambiguate messages received
  AsyncResponse(client_ref: ClientRef)
}

pub type Options {
  /// Receive a binary response
  WithBody(Bool)
  /// If using `WithBody(True)`, set maximum body size
  MaxBody(Int)
  /// Receive a `ClientRef` back
  Async
  /// Receive the response as message, use the function `selecting_http_message`
  StreamTo(process.Pid)
  /// Follow redirects, this enables the messages `Redirect` and `SeeOther`
  FollowRedirect(Bool)
  /// Max number of redirects
  MaxRedirect(Int)
  /// Basic auth username/password
  BasicAuth(BitArray, BitArray)
}

/// Send hackney a request, this is basically the direct
@external(erlang, "httpp_ffi", "send")
pub fn send(
  a: Method,
  b: String,
  c: List(http.Header),
  d: BytesBuilder,
  e: List(Options),
) -> Result(HackneyResponse, Error)

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
