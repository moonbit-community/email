///|
fn[T, E] guard_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
fn[T] expect_transport_error(
  result : Result[T, @transport.TransportError],
  expected : @transport.TransportError,
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
    @core.Message::new(
      from,
      [to],
      [],
      [],
      "Greetings",
      @core.Body::plain_text("Hello"),
      [],
    ),
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
  let transport = @transport.FakeTransport::new()
  let outcome = guard_ok(transport.send(envelope, encoded))
  assert_true(outcome.accepted == envelope.rcpt_to)
  assert_true(outcome.rejected.is_empty())
  assert_true(transport.records().length() == 1)
  assert_true(transport.records()[0].envelope == envelope)
  assert_true(transport.records()[0].encoded_message == encoded)
}

///|
async test "file transport writes eml artifacts for inspection" {
  @async.with_task_group() <| group => {
    let root_dir = @fs.tmpdir(prefix="moonbit-email-outbox-")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root_dir, recursive=true))
    }
    let (envelope, _, encoded) = sample_message()
    let transport = @transport.FileTransport::new(root_dir)
    let outcome = guard_ok(transport.send(envelope, encoded))
    let artifact_path = root_dir + "/message-0001.eml"
    let disk_content = @fs.read_file(artifact_path).text()
    assert_true(outcome.accepted == envelope.rcpt_to)
    assert_true(transport.artifacts().length() == 1)
    assert_true(transport.artifacts()[0].path == artifact_path)
    assert_true(transport.artifacts()[0].content == encoded)
    assert_true(disk_content == encoded)
  }
}

///|
async test "file transport surfaces io failures as transport errors" {
  @async.with_task_group() <| group => {
    let root_dir = @fs.tmpdir(prefix="moonbit-email-outbox-")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root_dir, recursive=true))
    }
    let blocker = root_dir + "/blocker"
    @fs.write_file(blocker, "not a directory", create_mode=CreateOrTruncate)
    let (envelope, _, encoded) = sample_message()
    let transport = @transport.FileTransport::new(blocker)
    match transport.send(envelope, encoded) {
      Ok(_) => abort("expected file transport io failure")
      Err(IoFailure(message)) => assert_true(message != "")
      Err(_) => abort("unexpected transport error")
    }
  }
}

///|
async test "file transport send_message supports file-backed attachments" {
  @async.with_task_group() <| group => {
    let root_dir = @fs.tmpdir(prefix="moonbit-email-outbox-")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root_dir, recursive=true))
    }
    let attachment_path = root_dir + "/report.txt"
    @fs.write_file(
      attachment_path,
      "streamed attachment",
      create_mode=CreateOrTruncate,
    )
    let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
    let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
    let attachment = guard_ok(
      @core.Body::attachment_file(
        "report.txt",
        attachment_path,
        content_type=@codec.infer_content_type("report.txt"),
      ),
    )
    let message = guard_ok(
      @core.Message::new(
        from,
        [to],
        [],
        [],
        "Streaming",
        guard_ok(
          @core.Body::mixed([@core.Body::plain_text("Hello"), attachment]),
        ),
        [],
      ),
    )
    let envelope = guard_ok(@core.Envelope::new(from, [to]))
    let transport = @transport.FileTransport::new(root_dir + "/outbox")
    let outcome = guard_ok(transport.send_message(envelope, message))
    let disk_content = @fs.read_file(root_dir + "/outbox/message-0001.eml").text()
    assert_true(outcome.accepted == [to])
    assert_true(disk_content.contains("Content-Type: text/plain\r\n"))
    assert_true(disk_content.contains("c3RyZWFtZWQgYXR0YWNobWVudA=="))
  }
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
  let transport = @transport.StubSmtpTransport::new()
  let outcome = guard_ok(transport.send_message(envelope, message))
  assert_true(outcome.accepted == [hidden])
  assert_true(transport.attempts().length() == 1)
  assert_true(transport.attempts()[0].envelope.rcpt_to == [hidden])
  assert_true(
    transport.attempts()[0].encoded_message.contains(
      "To: visible@example.com\r\n",
    ),
  )
}

///|
test "surface partial recipient acceptance in the result model" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let accepted = guard_ok(@core.Mailbox::address_only("ok@example.com"))
  let rejected = guard_ok(@core.Mailbox::address_only("no@example.com"))
  let unsent = guard_ok(@core.Mailbox::address_only("later@example.com"))
  let envelope = guard_ok(
    @core.Envelope::new(from, [accepted, rejected, unsent]),
  )
  let planned = @transport.DeliveryOutcome::partial(
    [accepted],
    [rejected],
    [unsent],
    "450 mailbox busy",
  )
  let transport = @transport.StubSmtpTransport::new(planned_outcomes=[planned])
  let outcome = guard_ok(transport.send(envelope, "raw message"))
  assert_true(outcome.accepted == [accepted])
  assert_true(outcome.rejected == [rejected])
  assert_true(outcome.unsent == [unsent])
  assert_true(outcome.response == "450 mailbox busy")
  assert_true(outcome.failure_class == Some(Transient))
}

///|
test "reuse pooled smtp connections across messages" {
  let (envelope, _, encoded) = sample_message()
  let transport = @transport.StubSmtpTransport::new(pool_size=1)
  ignore(guard_ok(transport.send(envelope, encoded)))
  ignore(guard_ok(transport.send(envelope, encoded)))
  assert_true(transport.attempts().length() == 2)
  assert_true(transport.attempts()[0].connection_id == 0)
  assert_true(transport.attempts()[1].connection_id == 0)
}

///|
test "close transport gracefully and reject sends after shutdown" {
  let (envelope, _, encoded) = sample_message()
  let transport = @transport.FakeTransport::new()
  transport.close()
  expect_transport_error(transport.send(envelope, encoded), ClosedTransport)
}
