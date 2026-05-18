///|
/// Inspired by Nodemailer message generation, Python email policies, and MimeKit.
test "serialize plain text message to rfc5322 output" {
  let from = guard_ok(@core.Mailbox::new("sender@example.com", Some("Sender")))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let message = guard_ok(
    @core.Message::new(from, [to], [], [], "Greetings", @core.Body::plain_text("Hello"), []),
  )
  let encoded = to_rfc5322(message)
  assert_true(encoded.contains("From: Sender <sender@example.com>\r\n"))
  assert_true(encoded.contains("To: reader@example.com\r\n"))
  assert_true(encoded.contains("Subject: Greetings\r\n"))
  assert_true(encoded.contains("Content-Type: text/plain; charset=utf-8\r\n"))
  assert_true(encoded.has_suffix("\r\n\r\nHello"))
}

///|
test "serialize multipart alternative with deterministic boundary policy" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let body = guard_ok(
    @core.Body::alternative([
      @core.Body::plain_text("Hello"),
      @core.Body::html("<p>Hello</p>"),
    ]),
  )
  let message = guard_ok(@core.Message::new(from, [to], [], [], "Multipart", body, []))
  let encoded = to_rfc5322(message)
  assert_true(
    encoded.contains(
      "Content-Type: multipart/alternative; boundary=\"moonbit-email-boundary-root\"\r\n",
    ),
  )
  assert_true(encoded.contains("--moonbit-email-boundary-root\r\n"))
  assert_true(encoded.contains("Content-Type: text/plain; charset=utf-8\r\n"))
  assert_true(encoded.contains("Content-Type: text/html; charset=utf-8\r\n"))
  assert_true(encoded.contains("--moonbit-email-boundary-root--"))
}

///|
test "encode non-ascii headers and text bodies" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let message = guard_ok(
    @core.Message::new(from, [to], [], [], "Hello", @core.Body::plain_text("你好=MoonBit"), []),
  )
  let encoded = to_rfc5322(message)
  assert_true(encoded.contains("Content-Transfer-Encoding: quoted-printable\r\n"))
  assert_true(encoded.has_suffix("\r\n\r\n=E4=BD=A0=E5=A5=BD=3DMoonBit"))
}

///|
test "omit bcc from encoded output by default" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let bcc = guard_ok(@core.Mailbox::address_only("hidden@example.com"))
  let message = guard_ok(
    @core.Message::new(from, [to], [], [bcc], "Hidden", @core.Body::plain_text("Hi"), []),
  )
  let encoded = to_rfc5322(message)
  assert_true(!encoded.contains("Bcc:"))
  assert_true(encoded.contains("To: reader@example.com\r\n"))
}

///|
test "serialize attachment and inline asset headers and payloads" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let html = @core.Body::html("<img src=\"cid:logo\">")
  let inline_logo = guard_ok(
    @core.Body::inline_asset(
      "logo",
      "logo.png",
      @core.ContentType::new("image", "png", []),
      [b'P', b'N', b'G'],
    ),
  )
  let related = guard_ok(@core.Body::related([html, inline_logo]))
  let attachment = guard_ok(@core.Body::attachment("report.txt", [b'O', b'K']))
  let body = guard_ok(@core.Body::mixed([related, attachment]))
  let message = guard_ok(@core.Message::new(from, [to], [], [], "Assets", body, []))
  let encoded = to_rfc5322(message)
  assert_true(encoded.contains("Content-Id: <logo>\r\n"))
  assert_true(encoded.contains("Content-Disposition: inline; filename=\"logo.png\"\r\n"))
  assert_true(encoded.contains("Content-Disposition: attachment; filename=\"report.txt\"\r\n"))
  assert_true(encoded.contains("\r\nT0s=\r\n"))
}

///|
test "roundtrip eml parse and serialize for supported messages" {
  // TODO: define the supported lossless roundtrip surface.
}

///|
fn[T, E] guard_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}
