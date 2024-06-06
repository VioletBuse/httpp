# httpp

[![Package Version](https://img.shields.io/hexpm/v/httpp)](https://hex.pm/packages/httpp)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/httpp/)

```sh
gleam add httpp
```
```gleam
import httpp/async
import gleam/http/request
import gleam/uri
import gleam/bytes_builder
import gleam/erlang/process

pub fn main() {
  let response_subject = uri.parse("https://example.com")
  |> request.from_uri
  |> request.map(bytes_builder.from_string)
  |> async.send

  // asynchronously send an http request and receive it later
  process.receive(response_subject, 2000)
}
```

Further documentation can be found at <https://hexdocs.pm/httpp>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
