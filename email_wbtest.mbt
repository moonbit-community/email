///|
/// Facade-level whitebox cases.
fn[T, E] must_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
test "facade stays thin and delegates to subpackages" {
  let from = must_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = must_ok(@core.Mailbox::address_only("reader@example.com"))
  let facade_message = must_ok(
    compose_plain_text(from, [to], "Delegation", "Hello"),
  )
  let core_message = must_ok(
    @core.Message::new(
      from,
      [to],
      [],
      [],
      "Delegation",
      @core.Body::plain_text("Hello"),
      [],
    ),
  )
  assert_true(facade_message == core_message)
  assert_true(
    must_ok(envelope_for(facade_message)) ==
    must_ok(@core.Envelope::from_message(from, core_message)),
  )
}

///|
test "facade avoids duplicating mime and transport internals" {
  let from = must_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = must_ok(@core.Mailbox::address_only("reader@example.com"))
  let attachment = must_ok(@core.Body::attachment("report.txt", [b'O', b'K']))
  let message = must_ok(
    compose_mixed(from, [to], "Assets", [
      @core.Body::plain_text("Hello"),
      attachment,
    ]),
  )
  assert_true(to_rfc5322(message) == @codec.to_rfc5322(message))
}
