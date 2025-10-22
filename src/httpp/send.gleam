/// This is a regular send request module
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/http.{type Header}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import httpp/hackney

fn process_headers(list: List(Header)) -> List(Header) {
  list.map(list, fn(header) { #(string.lowercase(header.0), header.1) })
}

pub fn send_bits(
  req: Request(BytesTree),
) -> Result(Response(BitArray), hackney.Error) {
  use response <- result.try(
    req
    |> request.to_uri
    |> uri.to_string
    |> hackney.send(req.method, _, req.headers, req.body, [
      hackney.WithBody(True),
    ]),
  )

  let result = case response {
    hackney.ClientRefResponse(status, headers, client_ref) -> {
      case hackney.body(client_ref) {
        Ok(body_bits) -> Ok(#(status, process_headers(headers), body_bits))
        Error(err) -> Error(err)
      }
    }
    hackney.BinaryResponse(status, headers, binary) ->
      Ok(#(status, process_headers(headers), binary))
    hackney.EmptyResponse(status, headers) ->
      Ok(#(status, process_headers(headers), <<>>))
    _received -> {
      // io.debug(received)
      panic as "received invalid response from hackney with {with_body, true}"
    }
  }

  use #(status, headers, binary) <- result.try(result)

  Ok(Response(status, headers, binary))
}

pub fn send(req: Request(String)) -> Result(Response(String), hackney.Error) {
  use response <- result.try(
    req
    |> request.map(bytes_tree.from_string)
    |> send_bits,
  )

  case bit_array.to_string(response.body) {
    Ok(body) -> Ok(response.set_body(response, body))
    Error(_) -> Error(hackney.InvalidUtf8Response)
  }
}
