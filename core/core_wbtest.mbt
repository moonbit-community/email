///|
fn[T, E] must_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
fn[T] expect_validation_error(
  result : Result[T, ValidationError],
  expected : ValidationError,
) -> Unit {
  match result {
    Ok(_) => abort("expected Err result")
    Err(error) =>
      if error == expected {
        ()
      } else {
        abort("unexpected validation error")
      }
  }
}

///|
/// Whitebox inventory for core invariants.
test "preserve header insertion order when building a message" {
  let from = must_ok(Mailbox::address_only("sender@example.com"))
  let to = must_ok(Mailbox::address_only("reader@example.com"))
  let header1 = must_ok(Header::new("X-Trace", "one"))
  let header2 = must_ok(Header::new("X-Flow", "two"))
  let message = must_ok(
    Message::new(from, [to], [], [], "Headers", Body::plain_text("payload"), [
      header1, header2,
    ]),
  )
  assert_true(message.headers.length() == 2)
  assert_true(message.headers[0].name == "X-Trace")
  assert_true(message.headers[1].name == "X-Flow")
}

///|
test "normalize mailbox lists before envelope construction" {
  let sender = must_ok(Mailbox::address_only("sender@example.com"))
  let a = must_ok(Mailbox::new("alpha@example.com", Some("Alpha")))
  let b = must_ok(Mailbox::new("beta@example.com", Some("Beta")))
  let a_alias = must_ok(Mailbox::new("alpha@example.com", Some("Alias")))
  assert_true(normalize_mailboxes([a, b, a_alias]) == [a, b])
  let envelope = must_ok(Envelope::new(sender, [a, b, a_alias, b]))
  assert_true(envelope.rcpt_to == [a, b])
}

///|
test "reject invalid multipart nesting shapes" {
  let attachment = must_ok(Body::attachment("report.bin", [b'B']))
  expect_validation_error(
    validate_multipart(MultipartKind::Related, []),
    EmptyMultipart,
  )
  expect_validation_error(
    validate_multipart(MultipartKind::Alternative, [
      Body::plain_text("Hello"),
      attachment,
    ]),
    AlternativeRequiresTextParts,
  )
}
