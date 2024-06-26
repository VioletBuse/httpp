import gleam/bytes_builder
import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/option
import gleam/uri
import gleeunit
import gleeunit/should
import httpp/sse

pub fn main() {
  gleeunit.main()
}

fn receive_all(
  subject: process.Subject(sse.SSEEvent),
  rest,
) -> Result(List(sse.SSEEvent), Nil) {
  case process.receive(subject, 5000) {
    Ok(sse.Closed) -> Ok(list.concat([rest, []]))
    Ok(sse.Event(..) as event) ->
      receive_all(subject, list.concat([rest, [event]]))
    _ -> Error(Nil)
  }
}

pub fn sse_mixture_test() {
  let assert Ok(uri) = uri.parse("http://localhost:1773/sse/with-mixture")
  let assert Ok(request) = request.from_uri(uri)

  let req =
    request.set_header(request, "connection", "keep-alive")
    |> request.map(bytes_builder.from_string)

  let subject = process.new_subject()
  let _ = sse.event_source(req, subject)

  let events = receive_all(subject, [])

  should.equal(
    events,
    Ok([
      sse.Event(option.Some("event-1"), "0"),
      sse.Event(
        option.None,
        "line one of data\nline two of data\nline three of data",
      ),
      sse.Event(option.Some("event-3"), "hello\nworld"),
    ]),
  )
}
