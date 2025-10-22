/// Use the async module if you want to fetch data asynchronously
///
/// ```gleam
///
/// fn fetch() {
///   let subject = uri.from_string("https://example.com")
///     |> request.from_uri()
///     |> async.send_async
///
///   let response = process.receive(subject, 1000)
///
/// }
///
/// ```
///
import gleam/bool
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
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

fn loop(
  response_subject: Subject(Response(BitArray)),
  messages: List(hackney.HttppMessage),
) {
  process.new_selector()
  |> hackney.selecting_http_message(mapping: fn(_, message) {
    case message {
      hackney.DoneStreaming -> {
        let response: Response(BitArray) = {
          let see_other =
            list.find(messages, fn(message) {
              case message {
                hackney.SeeOther(..) -> True
                _ -> False
              }
            })

          use <- bool.lazy_guard(when: result.is_ok(see_other), return: fn() {
            let assert Ok(hackney.SeeOther(location, headers)) = see_other
            let headers =
              list.append(process_headers(headers), [#("location", location)])
            Response(303, headers, <<>>)
          })

          let redirect =
            list.find(messages, fn(message) {
              case message {
                hackney.Redirect(..) -> True
                _ -> False
              }
            })

          use <- bool.lazy_guard(when: result.is_ok(redirect), return: fn() {
            let assert Ok(hackney.Redirect(location, headers)) = redirect
            let headers =
              list.append(process_headers(headers), [#("location", location)])
            Response(302, headers, <<>>)
          })

          let #(status, headers, body_builder) =
            list.fold(messages, #(404, [], bytes_tree.new()), fn(acc, message) {
              case message {
                hackney.Status(new_status) -> #(new_status, acc.1, acc.2)
                hackney.Headers(headers) -> #(acc.0, headers, acc.2)
                hackney.Binary(bin) -> #(
                  acc.0,
                  acc.1,
                  bytes_tree.append(acc.2, bin),
                )
                _ -> acc
              }
            })

          Response(
            status,
            process_headers(headers),
            bytes_tree.to_bit_array(body_builder),
          )
        }

        process.send(response_subject, response)
      }
      other_message ->
        loop(response_subject, list.append(messages, [other_message]))
    }
  })
  |> process.selector_receive_forever
}

/// Send a request and receive a subject which you can receive to get the response
pub fn send(
  req: Request(bytes_tree.BytesTree),
) -> Result(Subject(Response(BitArray)), hackney.Error) {
  let subject = process.new_subject()

  let receiving_process = process.spawn(fn() { loop(subject, []) })

  use _ <- result.try(
    req
    |> request.to_uri
    |> uri.to_string
    |> hackney.send(req.method, _, req.headers, req.body, [
      hackney.Async,
      hackney.StreamTo(receiving_process),
    ]),
  )

  Ok(subject)
}
