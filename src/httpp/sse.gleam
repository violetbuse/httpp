//// Use this to receive server sent events
////
//// ```gleam
////
//// fn fetch() {
////   let subject = process.new_subject()
////   let request = uri.from_string("https://example.com/listen")
////     |> request.from_uri()
////
////   let mgr = event_source(request, 1000, subject)
////
////   // receive events like any other message
////   let event = process.receive(subject, 1000)
//// }
//// ```
////

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/erlang/process.{type ExitReason, type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import httpp/hackney
import httpp/internal/util
import httpp/streaming

pub type SSEEvent {
  Event(event_type: Option(String), event_id: Option(String), data: String)
  Closed
}

type InternalState {
  InternalState(current: String)
}

pub type SSEManagerMessage {
  Shutdown
}

fn create_on_data(
  event_subject: Subject(SSEEvent),
) -> fn(streaming.Message, Response(Nil), InternalState) ->
  Result(InternalState, ExitReason) {
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

type EventComponents {
  Data(String)
  EventType(String)
  EventId(String)
  Comment(String)
  Empty
  Invalid
}

// fn process_string(
//   input: String,
//   current: Option(#(Option(String), String)),
// ) -> #(List(SSEEvent), String) {
//   case input
// }

fn handle_bits(
  event_subject: Subject(SSEEvent),
  bits: BitArray,
  _response: Response(Nil),
  state: InternalState,
) -> Result(InternalState, ExitReason) {
  use incoming <- result.try(
    bit_array.to_string(bits)
    |> result.replace_error(
      process.Abnormal(dynamic.string(
        "Server sent bits could not be read as string.",
      )),
    ),
  )

  let full_str = state.current <> incoming
  let split_vals = string.split(full_str, "\n\n")

  let event_candidates = list.take(split_vals, list.length(split_vals) - 1)
  let assert Ok(new_current) = list.last(split_vals)

  let events =
    event_candidates
    |> list.map(string.split(_, "\n"))
    |> list.map(
      list.map(_, fn(line) {
        case line {
          "" -> Empty
          ":" <> comment -> Comment(comment)
          "data: " <> data | "data:" <> data -> Data(data)
          "event: " <> event_type | "event:" <> event_type ->
            EventType(event_type)
          "id: " <> event_id | "id:" <> event_id -> EventId(event_id)
          _ -> Invalid
        }
      }),
    )
    |> list.filter(
      list.any(_, fn(component) {
        case component {
          Comment(..) -> False
          _ -> True
        }
      }),
    )
    |> list.map(
      list.fold(_, #(None, None, ""), fn(acc, component) {
        case component {
          Invalid | Empty | Comment(..) -> acc
          EventType(event_type) -> #(Some(event_type), acc.1, acc.2)
          EventId(event_id) -> #(acc.0, Some(event_id), acc.2)
          Data(data) ->
            case acc.2 {
              "" -> #(acc.0, acc.1, data)
              prefix -> #(acc.0, acc.1, prefix <> "\n" <> string.trim_end(data))
            }
        }
      }),
    )
    |> list.map(fn(tuple) { Event(tuple.0, tuple.1, tuple.2) })

  list.each(events, process.send(event_subject, _))

  Ok(InternalState(new_current))
}

fn create_on_message(
  event_subject: Subject(SSEEvent),
) -> fn(SSEManagerMessage, Response(Nil), InternalState) ->
  Result(InternalState, ExitReason) {
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
  _event_subject: Subject(SSEEvent),
) -> fn(hackney.Error, Option(Response(Nil)), InternalState) ->
  Result(InternalState, ExitReason) {
  fn(_, _, _) {
    Error(process.Abnormal(dynamic.string("sse handler received an error")))
  }
}

/// Send a request to a server-sent events endpoint, and receive events
/// back on a subject you provide. The timeout sets how long the actor will
/// wait for the first response (status code, headers)
pub fn event_source(
  req: request.Request(BytesTree),
  timeout: Int,
  subject: Subject(SSEEvent),
) {
  let new_request = req |> request.set_header("connection", "keep-alive")

  streaming.start(streaming.StreamingRequestHandler(
    req: new_request,
    initial_state: InternalState(""),
    on_data: create_on_data(subject),
    on_message: create_on_message(subject),
    on_error: create_on_error(subject),
    initial_response_timeout: timeout,
  ))
}
