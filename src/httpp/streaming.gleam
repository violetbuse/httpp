//// This module allows you to make an http request to a server and receive a streamed response back which
//// is sent to a process managing it. You can also define a custom message type and send messages and state
//// to this response handler.

import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic
import gleam/erlang/process.{type ExitReason, type Subject}
import gleam/float
import gleam/http.{type Header}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import httpp/hackney

pub type Message {
  Bits(BitArray)
  Done
}

/// This defines the behaviour of the request handler
/// *NOTE*: if the on_error handler does not receive a response, the handler will be shut down regardless of if it returns an Ok() result
/// if the initial response does not arrive within the timeout, the on_error handler will receive the `TimedOut` error
pub type StreamingRequestHandler(state, message_type) {
  StreamingRequestHandler(
    initial_state: state,
    req: Request(BytesTree),
    on_data: fn(Message, Response(Nil), state) -> Result(state, ExitReason),
    on_message: fn(message_type, Response(Nil), state) ->
      Result(state, ExitReason),
    on_error: fn(hackney.Error, Option(Response(Nil)), state) ->
      Result(state, ExitReason),
    initial_response_timeout: Int,
  )
}

fn initial_request_loop(
  request_state: #(Option(Int), Option(List(Header))),
  when_to_time_out: Int,
) -> Result(Response(Nil), hackney.Error) {
  case request_state {
    #(Some(status), Some(headers)) -> Ok(Response(status, headers, Nil))
    request_state -> {
      let next_selector =
        process.new_selector()
        |> hackney.selecting_http_message(mapping: fn(_, message) {
          case message {
            hackney.Status(status_code) ->
              initial_request_loop(
                #(Some(status_code), request_state.1),
                when_to_time_out,
              )
            hackney.Headers(headers) ->
              initial_request_loop(
                #(
                  request_state.0,
                  Some(
                    list.map(headers, fn(header) {
                      #(string.lowercase(header.0), header.1)
                    }),
                  ),
                ),
                when_to_time_out,
              )
            _ -> Error(hackney.NoStatusOrHeaders)
          }
        })

      case process.selector_receive(next_selector, 500) {
        Ok(inner) -> inner
        Error(_) -> {
          let system_time =
            timestamp.system_time() |> timestamp.to_unix_seconds |> float.round
          use <- bool.guard(
            when: system_time > when_to_time_out,
            return: Error(hackney.TimedOut),
          )
          initial_request_loop(request_state, when_to_time_out)
        }
      }
    }
  }
}

fn loop(
  message_subject: Subject(message_type),
  response: Response(Nil),
  state: state,
  handler: StreamingRequestHandler(state, message_type),
) {
  let next_state =
    process.new_selector()
    |> process.select_map(message_subject, handler.on_message(
      _,
      response,
      state,
    ))
    |> hackney.selecting_http_message(fn(_, http_message) {
      case http_message {
        hackney.Status(..)
        | hackney.Headers(..)
        | hackney.SeeOther(..)
        | hackney.Redirect(..) ->
          handler.on_error(
            hackney.UnexpectedServerMessage(http_message),
            Some(response),
            state,
          )
        hackney.Binary(bits) -> handler.on_data(Bits(bits), response, state)
        hackney.DoneStreaming -> handler.on_data(Done, response, state)
        hackney.NotDecoded(dyn) ->
          handler.on_error(
            hackney.MessageNotDecoded(dyn),
            Some(response),
            state,
          )
      }
    })
    |> process.selector_receive_forever

  result.try(next_state, loop(message_subject, response, _, handler))
}

/// Starts a streaming request manager, based on the spec
pub fn start(
  handler: StreamingRequestHandler(state, message_type),
) -> Result(Subject(message_type), actor.StartError) {
  let parent_subject: Subject(Subject(message_type)) = process.new_subject()

  process.spawn(fn() {
    let message_subject = process.new_subject()
    process.send(parent_subject, message_subject)

    let request_result =
      handler.req
      |> request.to_uri
      |> uri.to_string
      |> hackney.send(
        handler.req.method,
        _,
        handler.req.headers,
        handler.req.body,
        [hackney.Async],
      )

    use <- bool.guard(when: result.is_error(request_result), return: Nil)

    let system_time =
      timestamp.system_time() |> timestamp.to_unix_seconds |> float.round
    let timeout_time = system_time + handler.initial_response_timeout

    let response = initial_request_loop(#(None, None), timeout_time)

    let exit_reason = case response {
      Ok(response) ->
        case loop(message_subject, response, handler.initial_state, handler) {
          Ok(_) -> process.Normal
          Error(reason) -> reason
        }
      Error(err) -> {
        case handler.on_error(err, None, handler.initial_state) {
          Ok(_) ->
            process.Abnormal(dynamic.string(
              "streaming request manager could not get initial request data",
            ))
          Error(reason) -> reason
        }
      }
    }

    case exit_reason {
      process.Normal -> process.send_exit(process.self())
      process.Abnormal(reason) ->
        process.send_abnormal_exit(process.self(), reason)
      process.Killed -> process.kill(process.self())
    }
  })

  case process.receive(parent_subject, 10_000) {
    Ok(subject) -> Ok(subject)
    Error(_) -> Error(actor.InitTimeout)
  }
}
