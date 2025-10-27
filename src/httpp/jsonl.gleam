//// Use this to read newline delimites json streams
////
//// ```gleam
////
//// fn fetch() {
////   let subject = process.new_subject()
////   let request = uri.from_string("https://example.com/listen")
////     |> request.from_uri()
////
////   let decoder = {
////     use message <- decode.field("message", decode.string)
////     use sent_at <- decode.field("sent_at", decode.int)
////
////     decode.success(#(message, sent_at))
////   }
////
////   let mgr = json_lines_stream(request, 1000, decoder, subject)
////
////   // receive events just like any other message
////   let event = process.receive(subject, 1000)
//// }
//// ```

import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import httpp/hackney
import httpp/internal/util
import httpp/streaming

pub type JsonlEvent(datatype) {
  Line(datatype)
  Closed
}

type InternalState(datatype) {
  InternalState(current: String, decoder: decode.Decoder(datatype))
}

pub type JsonlManagerMessage {
  Shutdown
}

fn create_on_data(
  event_subject: process.Subject(JsonlEvent(datatype)),
) -> fn(streaming.Message, response.Response(Nil), InternalState(datatype)) ->
  Result(InternalState(datatype), process.ExitReason) {
  fn(message, response, state) {
    case message {
      streaming.Bits(bits) -> handle_bits(event_subject, bits, response, state)
      streaming.Done -> {
        process.send(event_subject, Closed)
        util.unlink_subject(event_subject)
        Error(process.Normal)
      }
    }
  }
}

fn handle_bits(
  event_subject: process.Subject(JsonlEvent(datatype)),
  bits: BitArray,
  _response: response.Response(Nil),
  state: InternalState(datatype),
) -> Result(InternalState(datatype), process.ExitReason) {
  use incoming <- result.try(
    bit_array.to_string(bits)
    |> result.replace_error(
      process.Abnormal(dynamic.string(
        "Server sent bits could not be read as string.",
      )),
    ),
  )

  let full_string = state.current <> incoming
  let lines =
    string.split(full_string, "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { string.is_empty(line) |> bool.negate })

  use <- bool.guard(
    when: list.is_empty(lines),
    return: Ok(InternalState(..state, current: "")),
  )

  let head = list.take(lines, list.length(lines) - 1)
  let assert Ok(last) = list.last(lines)

  let head_decoded =
    head
    |> list.try_map(fn(line) {
      case json.parse(line, state.decoder) {
        Ok(event) -> Ok(Line(event))
        Error(_) ->
          Error(
            process.Abnormal(dynamic.string(
              "Server sent json that could not be decoded: " <> line,
            )),
          )
      }
    })

  use head_events <- result.try(head_decoded)

  list.each(head_events, process.send(event_subject, _))

  case json.parse(last, state.decoder) {
    Ok(event) -> {
      process.send(event_subject, Line(event))
      Ok(InternalState(..state, current: ""))
    }
    Error(json.UnableToDecode(_)) ->
      Error(
        process.Abnormal(dynamic.string(
          "Server sent json that could not be decoded: " <> last,
        )),
      )
    Error(_) -> Ok(InternalState(..state, current: last))
  }
}

fn create_on_message(
  event_subject: process.Subject(JsonlEvent(datatype)),
) -> fn(JsonlManagerMessage, response.Response(Nil), InternalState(datatype)) ->
  Result(InternalState(datatype), process.ExitReason) {
  fn(message, _, _state) {
    case message {
      Shutdown -> {
        util.unlink_subject(event_subject)
        Error(process.Normal)
      }
    }
  }
}

fn create_on_error(
  _event_subject: process.Subject(JsonlEvent(datatype)),
) -> fn(
  hackney.Error,
  option.Option(response.Response(Nil)),
  InternalState(datatype),
) ->
  Result(InternalState(datatype), process.ExitReason) {
  fn(_, _, _) {
    Error(process.Abnormal(dynamic.string("jsonl handler received an error")))
  }
}

/// Send a request to an endpoint that returns a newline delimited stream
/// of json back on a subject you provide, decoded with your decoder. The
/// timeout sets how long the actor will wait for the first response
/// (status code, headers)
pub fn json_lines_stream(
  req: request.Request(BytesTree),
  timeout: Int,
  decoder: decode.Decoder(datatype),
  subject: process.Subject(JsonlEvent(datatype)),
) {
  let new_request = req |> request.set_header("connection", "keep-alive")

  streaming.start(streaming.StreamingRequestHandler(
    req: new_request,
    initial_state: InternalState("", decoder),
    on_data: create_on_data(subject),
    on_message: create_on_message(subject),
    on_error: create_on_error(subject),
    initial_response_timeout: timeout,
  ))
}
