///|
/// Facade-level blackbox cases.
/// These cases keep the top-level package focused on low-ceremony user flows.
fn[T, E] must_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
test "re-export common compose and send entrypoints" {
  let from = must_ok(Mailbox::new("sender@example.com", Some("Sender")))
  let to = must_ok(Mailbox::address_only("reader@example.com"))
  let message = must_ok(compose_plain_text(from, [to], "Greetings", "Hello"))
  let envelope = must_ok(envelope_for(message))
  let encoded = to_rfc5322(message)
  let transport = FakeTransport::new()
  let outcome = must_ok(transport.send_message(envelope, message))
  assert_true(outcome.accepted == [to])
  assert_true(encoded.contains("From: Sender <sender@example.com>\r\n"))
  assert_true(encoded.contains("Subject: Greetings\r\n"))
}

///|
test "compose and send a plain text message with defaults" {
  let from = must_ok(Mailbox::address_only("sender@example.com"))
  let to = must_ok(Mailbox::address_only("reader@example.com"))
  let message = must_ok(compose_plain_text(from, [to], "Hello", "Facade flow"))
  let envelope = must_ok(envelope_for(message))
  let transport = FakeTransport::new()
  let outcome = must_ok(transport.send_message(envelope, message))
  assert_true(outcome.rejected.is_empty())
  assert_true(transport.records().length() == 1)
  assert_true(
    transport.records()[0].encoded_message.has_suffix("\r\n\r\nFacade flow"),
  )
}

///|
test "compose html plus attachments through facade helpers" {
  let from = must_ok(Mailbox::address_only("sender@example.com"))
  let to = must_ok(Mailbox::address_only("reader@example.com"))
  let attachment = must_ok(Body::attachment("report.txt", [b'O', b'K']))
  let message = must_ok(
    compose_mixed(from, [to], "Assets", [Body::html("<p>Hello</p>"), attachment]),
  )
  let envelope = must_ok(envelope_for(message))
  let transport = FakeTransport::new()
  let outcome = must_ok(transport.send_message(envelope, message))
  let encoded = transport.records()[0].encoded_message
  assert_true(outcome.accepted == [to])
  assert_true(encoded.contains("Content-Type: multipart/mixed;"))
  assert_true(
    encoded.contains(
      "Content-Disposition: attachment; filename=\"report.txt\"\r\n",
    ),
  )
}

///|
test "allow low-level escape hatches for pre-encoded messages and custom transport" {
  let from = must_ok(Mailbox::address_only("sender@example.com"))
  let to = must_ok(Mailbox::address_only("reader@example.com"))
  let envelope = must_ok(Envelope::new(from, [to]))
  let raw = "Subject: raw\r\n\r\npayload"
  let transport = FakeTransport::new()
  let outcome = must_ok(transport.send(envelope, raw))
  assert_true(outcome.accepted == [to])
  assert_true(transport.records()[0].encoded_message == raw)
}
