///|
/// Inspired by Nodemailer message generation, Python email policies, and MimeKit.
test "serialize plain text message to rfc5322 output" {
  let from = guard_ok(@core.Mailbox::new("sender@example.com", Some("Sender")))
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
  let message = guard_ok(
    @core.Message::new(from, [to], [], [], "Multipart", body, []),
  )
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
  let from = guard_ok(@core.Mailbox::new("sender@example.com", Some("月兔")))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let message = guard_ok(
    @core.Message::new(
      from,
      [to],
      [],
      [],
      "你好 MoonBit",
      @core.Body::plain_text("你好=MoonBit"),
      [],
    ),
  )
  let encoded = to_rfc5322(message)
  assert_true(
    encoded.contains("From: =?UTF-8?B?5pyI5YWU?= <sender@example.com>\r\n"),
  )
  assert_true(encoded.contains("Subject: =?UTF-8?B?5L2g5aW9IE1vb25CaXQ=?=\r\n"))
  assert_true(
    encoded.contains("Content-Transfer-Encoding: quoted-printable\r\n"),
  )
  assert_true(encoded.has_suffix("\r\n\r\n=E4=BD=A0=E5=A5=BD=3DMoonBit"))
}

///|
test "omit bcc from encoded output by default" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let bcc = guard_ok(@core.Mailbox::address_only("hidden@example.com"))
  let message = guard_ok(
    @core.Message::new(
      from,
      [to],
      [],
      [bcc],
      "Hidden",
      @core.Body::plain_text("Hi"),
      [],
    ),
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
  let message = guard_ok(
    @core.Message::new(from, [to], [], [], "Assets", body, []),
  )
  let encoded = to_rfc5322(message)
  assert_true(encoded.contains("Content-Id: <logo>\r\n"))
  assert_true(
    encoded.contains("Content-Disposition: inline; filename=\"logo.png\"\r\n"),
  )
  assert_true(
    encoded.contains(
      "Content-Disposition: attachment; filename=\"report.txt\"\r\n",
    ),
  )
  assert_true(encoded.contains("\r\nT0s=\r\n"))
}

///|
test "encode non-ascii attachment filenames with RFC2231 parameters" {
  let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let attachment = guard_ok(@core.Body::attachment("报告.txt", [b'O', b'K']))
  let message = guard_ok(
    @core.Message::new(
      from,
      [to],
      [],
      [],
      "Attachment",
      guard_ok(@core.Body::mixed([@core.Body::plain_text("Hello"), attachment])),
      [],
    ),
  )
  let encoded = to_rfc5322(message)
  assert_true(
    encoded.contains(
      "Content-Disposition: attachment; filename*=UTF-8''%E6%8A%A5%E5%91%8A.txt\r\n",
    ),
  )
}

///|
async test "render file-backed attachments without loading them into the model" {
  @async.with_task_group() <| group => {
    let root_dir = @fs.tmpdir(prefix="moonbit-email-codec-")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root_dir, recursive=true))
    }
    let path = root_dir + "/report.txt"
    @fs.write_file(
      path,
      "streamed attachment",
      create_mode=@fs.CreateOrTruncate,
    )
    let from = guard_ok(@core.Mailbox::address_only("sender@example.com"))
    let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
    let attachment = guard_ok(
      @core.Body::attachment_file(
        "report.txt",
        path,
        content_type=infer_content_type("report.txt"),
      ),
    )
    let body = guard_ok(
      @core.Body::mixed([@core.Body::plain_text("Hello"), attachment]),
    )
    let message = guard_ok(
      @core.Message::new(from, [to], [], [], "Stream", body, []),
    )
    let encoded = render_to_rfc5322(message)
    assert_true(encoded.contains("Content-Type: text/plain\r\n"))
    assert_true(encoded.contains("c3RyZWFtZWQgYXR0YWNobWVudA=="))
  }
}

///|
test "roundtrip eml parse and serialize for supported messages" {
  let from = guard_ok(@core.Mailbox::new("sender@example.com", Some("Sender")))
  let to = guard_ok(@core.Mailbox::address_only("reader@example.com"))
  let attachment = guard_ok(@core.Body::attachment("report.txt", [b'O', b'K']))
  let message = guard_ok(
    @core.Message::new(
      from,
      [to],
      [],
      [],
      "Roundtrip",
      guard_ok(@core.Body::mixed([@core.Body::plain_text("Hello"), attachment])),
      [guard_ok(@core.Header::new("X-Trace", "one"))],
    ),
  )
  let encoded = to_rfc5322(message)
  let parsed = parse_rfc5322(encoded, mode=Strict) catch {
    _ => abort("expected message to parse")
  }
  let reencoded = to_rfc5322(parsed)
  assert_true(reencoded == encoded)
}

///|
test "lenient parser accepts LF-only line endings while strict parser rejects them" {
  let eml = "From: sender@example.com\nTo: reader@example.com\nSubject: Hi\n\nHello"
  let parsed = parse_rfc5322(eml, mode=Lenient) catch {
    _ => abort("expected lenient parse success")
  }
  assert_true(parsed.subject == "Hi")
  try parse_rfc5322(eml, mode=Strict) catch {
    _ => ()
  } noraise {
    _ => abort("expected strict parse failure")
  }
}

///|
fn[T, E] guard_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}
