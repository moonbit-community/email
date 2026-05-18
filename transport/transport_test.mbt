///|
fn[T, E] guard_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
fn[T] expect_transport_error(
  result : Result[T, TransportError],
  expected : TransportError,
) -> Unit {
  match result {
    Ok(_) => abort("expected transport error")
    Err(error) =>
      if error == expected {
        ()
      } else {
        abort("unexpected transport error")
      }
  }
}

///|
fn sample_message() -> (@core.Envelope, @core.Message, String) {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let message = guard_ok(
    @core.Message::new(from, [to], [], [], "Greetings", @core.Body::plain_text("Hello"), []),
  )
  let envelope = guard_ok(@core.Envelope::new(from, [to]))
  let encoded = @codec.to_rfc5322(message)
  (envelope, message, encoded)
}

///|
/// Inspired by lettre StubTransport, Nodemailer pooled SMTP, and SMTP clients
/// that distinguish explicit envelope handling from message headers.
test "fake transport records envelope and encoded message" {
  let (envelope, _, encoded) = sample_message()
  let transport = FakeTransport::new()
  let outcome = guard_ok(transport.send(envelope, encoded))
  assert_true(outcome.accepted == envelope.rcpt_to)
  assert_true(outcome.rejected.is_empty())
  assert_true(transport.records().length() == 1)
  assert_true(transport.records()[0].envelope == envelope)
  assert_true(transport.records()[0].encoded_message == encoded)
}

///|
test "file transport writes eml artifacts for inspection" {
  let (envelope, _, encoded) = sample_message()
  let transport = FileTransport::new("/tmp/outbox")
  let outcome = guard_ok(transport.send(envelope, encoded))
  assert_true(outcome.accepted == envelope.rcpt_to)
  assert_true(transport.artifacts().length() == 1)
  assert_true(transport.artifacts()[0].path == "/tmp/outbox/message-0001.eml")
  assert_true(transport.artifacts()[0].content == encoded)
}

///|
test "smtp send uses explicit envelope instead of inferring from headers" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let visible = guard_ok(@core.Mailbox::address_only("visible@example.com"))
  let hidden = guard_ok(@core.Mailbox::address_only("hidden@example.com"))
  let message = guard_ok(
    @core.Message::new(
      from,
      [visible],
      [],
      [],
      "Explicit envelope",
      @core.Body::plain_text("Hello"),
      [],
    ),
  )
  let envelope = guard_ok(@core.Envelope::new(from, [hidden]))
  let transport = SmtpTransport::new()
  let outcome = guard_ok(transport.send_message(envelope, message))
  assert_true(outcome.accepted == [hidden])
  assert_true(transport.attempts().length() == 1)
  assert_true(transport.attempts()[0].envelope.rcpt_to == [hidden])
  assert_true(transport.attempts()[0].encoded_message.contains("To: visible@example.com\r\n"))
}

///|
test "surface partial recipient acceptance in the result model" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let accepted = guard_ok(@core.Mailbox::address_only("ok@example.com"))
  let rejected = guard_ok(@core.Mailbox::address_only("no@example.com"))
  let unsent = guard_ok(@core.Mailbox::address_only("later@example.com"))
  let envelope = guard_ok(@core.Envelope::new(from, [accepted, rejected, unsent]))
  let planned = DeliveryOutcome::partial(
    [accepted],
    [rejected],
    [unsent],
    "450 mailbox busy",
  )
  let transport = SmtpTransport::new(planned_outcomes=[planned])
  let outcome = guard_ok(transport.send(envelope, "raw message"))
  assert_true(outcome.accepted == [accepted])
  assert_true(outcome.rejected == [rejected])
  assert_true(outcome.unsent == [unsent])
  assert_true(outcome.response == "450 mailbox busy")
  assert_true(outcome.failure_class == Some(FailureClass::Transient))
}

///|
test "reuse pooled smtp connections across messages" {
  let (envelope, _, encoded) = sample_message()
  let transport = SmtpTransport::new(pool_size=1)
  ignore(guard_ok(transport.send(envelope, encoded)))
  ignore(guard_ok(transport.send(envelope, encoded)))
  assert_true(transport.attempts().length() == 2)
  assert_true(transport.attempts()[0].connection_id == 0)
  assert_true(transport.attempts()[1].connection_id == 0)
}

///|
test "close transport gracefully and reject sends after shutdown" {
  let (envelope, _, encoded) = sample_message()
  let transport = FakeTransport::new()
  transport.close()
  expect_transport_error(
    transport.send(envelope, encoded),
    TransportError::ClosedTransport,
  )
}
