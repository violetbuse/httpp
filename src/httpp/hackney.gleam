//// This module contains the base code to interact with hackney in a low-level manner

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode.{type Dynamic}
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
  d: BytesTree,
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

/// if sending with async, put this in your selector to receive messages related to your request
pub fn selecting_http_message(
  selector: Selector(a),
  mapping transform: fn(ClientRef, HttppMessage) -> a,
) -> Selector(a) {
  let handler = fn(message: #(atom.Atom, ClientRef, Dynamic)) {
    let header_list_decoder =
      decode.list({
        use name <- decode.field(0, decode.string)
        use value <- decode.field(1, decode.string)
        decode.success(#(name, value))
      })

    let status_decoder = {
      use code <- decode.field(1, decode.int)
      decode.success(Status(code))
    }

    let headers_decoder = {
      use headers <- decode.field(1, header_list_decoder)
      decode.success(Headers(headers))
    }

    let redirect_decoder = {
      use location <- decode.field(1, decode.string)
      use headers <- decode.field(2, header_list_decoder)
      decode.success(Redirect(location, headers))
    }

    let see_other_decoder = {
      use data <- decode.field(1, decode.string)
      use headers <- decode.field(2, header_list_decoder)
      decode.success(SeeOther(data, headers))
    }

    let discriminant_decoder = {
      use discriminant <- decode.field(0, atom.decoder())

      case atom.to_string(discriminant) {
        "status" -> status_decoder
        "headers" -> headers_decoder
        "redirect" -> redirect_decoder
        "see_other" -> see_other_decoder
        _ -> decode.failure(DoneStreaming, "HttppMessage")
      }
    }

    let binary_decoder = {
      use binary <- decode.then(decode.bit_array)
      decode.success(Binary(binary))
    }

    let done_decoder = {
      use atom <- decode.then(atom.decoder())
      case atom.to_string(atom) {
        "done" -> decode.success(DoneStreaming)
        _ -> decode.failure(DoneStreaming, "HttppMessage")
      }
    }

    let error_decoder = {
      use dynamic <- decode.then(decode.dynamic)
      decode.success(NotDecoded(dynamic))
    }

    let decoder =
      decode.one_of(binary_decoder, or: [
        discriminant_decoder,
        done_decoder,
        error_decoder,
      ])

    let assert Ok(http_message) = decode.run(message.2, decoder)

    transform(message.1, http_message)
  }

  let tag = atom.create("hackney_response")

  insert_selector_handler(selector, #(tag, 3), handler)
}
