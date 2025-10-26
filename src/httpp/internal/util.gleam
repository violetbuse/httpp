import gleam/erlang/process

pub fn unlink_subject(subject: process.Subject(any)) -> Nil {
  case process.subject_owner(subject) {
    Error(_) -> Nil
    Ok(pid) -> process.unlink(pid)
  }
}
