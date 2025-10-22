import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/erlang/process.{type ExitReason, type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import httpp/hackney
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
  case bit_array.to_string(bits) {
    Error(_) ->
      Error(
        process.Abnormal(dynamic.string(
          "Server sent bits could not be read as string",
        )),
      )
    Ok(stringified) -> {
      let full_str = state.current <> stringified
      let split_vals = string.split(full_str, "\n\n")

      echo full_str
      echo split_vals

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
                  prefix -> #(
                    acc.0,
                    acc.1,
                    prefix <> "\n" <> string.trim_end(data),
                  )
                }
            }
          }),
        )
        |> list.map(fn(tuple) { Event(tuple.0, tuple.1, tuple.2) })

      list.each(events, fn(event) { process.send(event_subject, event) })

      Ok(InternalState(new_current))
    }
  }
}

fn create_on_message(
  _event_subject: Subject(SSEEvent),
) -> fn(SSEManagerMessage, Response(Nil), InternalState) ->
  Result(InternalState, ExitReason) {
  fn(_, _, state) { Ok(state) }
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
  let new_request =
    req
    |> request.set_header("connection", "keep-alive")

  streaming.start(streaming.StreamingRequestHandler(
    req: new_request,
    initial_state: InternalState(""),
    on_data: create_on_data(subject),
    on_message: create_on_message(subject),
    on_error: create_on_error(subject),
    initial_response_timeout: timeout,
  ))
}
