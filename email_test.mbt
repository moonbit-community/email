///|
/// Facade-level blackbox cases.
/// These cases keep the top-level package focused on low-ceremony user flows.
test "re-export common compose and send entrypoints" {
  // TODO: verify that the facade exposes the smallest useful public surface.
}

///|
test "compose and send a plain text message with defaults" {
  // TODO: verify the one-shot happy path built on top of subpackages.
}

///|
test "compose html plus attachments through facade helpers" {
  // TODO: verify that common multipart flows stay ergonomic at the facade level.
}

///|
test "allow low-level escape hatches for pre-encoded messages and custom transport" {
  // TODO: verify that advanced users can drop below the facade when needed.
}
