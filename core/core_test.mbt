///|
fn[T, E] must_ok(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
fn[T] expect_validation_error(
  result : Result[T, @core.ValidationError],
  expected : @core.ValidationError,
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
/// Inspired by mature message builders such as Nodemailer, lettre, and MimeKit.
test "build mailbox with display name and address" {
  let mailbox = must_ok(@core.Mailbox::new("alice@example.com", Some("Alice")))
  assert_true(mailbox.address == "alice@example.com")
  assert_true(mailbox.display_name == Some("Alice"))
}

///|
test "build plain text message with explicit smtp envelope" {
  let from = must_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = must_ok(@core.Mailbox::address_only("reader@example.com"))
  let body = @core.Body::plain_text("Hello, MoonBit")
  let message = must_ok(
    @core.Message::new(from, [to], [], [], "Greetings", body, []),
  )
  let envelope = must_ok(@core.Envelope::new(from, [to]))
  assert_true(message.from == from)
  assert_true(message.subject == "Greetings")
  match message.body {
    Text(text) => {
      assert_true(text.content == "Hello, MoonBit")
      assert_true(text.content_type == @core.ContentType::text_plain())
    }
    _ => abort("expected text body")
  }
  assert_true(envelope.mail_from == from)
  assert_true(envelope.rcpt_to == [to])
}

///|
test "build multipart alternative text and html message" {
  let body = must_ok(
    @core.Body::alternative([
      @core.Body::plain_text("Hello"),
      @core.Body::html("<p>Hello</p>"),
    ]),
  )
  match body {
    Multipart(kind, parts) => {
      match kind {
        Alternative => ()
        _ => abort("expected alternative kind")
      }
      assert_true(parts.length() == 2)
      match parts[0] {
        Text(_) => ()
        _ => abort("expected text/plain part")
      }
      match parts[1] {
        Text(_) => ()
        _ => abort("expected text/html part")
      }
    }
    _ => abort("expected multipart alternative body")
  }
}

///|
test "build multipart mixed with inline resource and attachment" {
  let html = @core.Body::html("<p>Hello<img src=\"cid:logo\"></p>")
  let logo = must_ok(
    @core.Body::inline_asset(
      "logo",
      "logo.png",
      @core.ContentType::new("image", "png", []),
      [b'P', b'N', b'G'],
    ),
  )
  let related = must_ok(@core.Body::related([html, logo]))
  let attachment = must_ok(
    @core.Body::attachment("report.pdf", [b'P', b'D', b'F']),
  )
  let mixed = must_ok(@core.Body::mixed([related, attachment]))
  match mixed {
    Multipart(kind, parts) => {
      match kind {
        Mixed => ()
        _ => abort("expected mixed kind")
      }
      assert_true(parts.length() == 2)
      match parts[0] {
        Multipart(inner_kind, inner_parts) => {
          match inner_kind {
            Related => ()
            _ => abort("expected related kind")
          }
          assert_true(inner_parts.length() == 2)
        }
        _ => abort("expected multipart related body")
      }
      match parts[1] {
        Binary(binary) => {
          assert_true(binary.filename == Some("report.pdf"))
          assert_true(binary.content_id == None)
          match binary.source {
            InMemory(data) => assert_true(data == [b'P', b'D', b'F'])
            _ => abort("expected in-memory attachment source")
          }
        }
        _ => abort("expected attachment body")
      }
    }
    _ => abort("expected multipart mixed body")
  }
}

///|
test "reject invalid mailbox, empty recipients, and invalid attachment metadata" {
  expect_validation_error(@core.Mailbox::address_only(""), EmptyAddress)
  expect_validation_error(
    @core.Mailbox::address_only("alice example.com"),
    UnexpectedWhitespace,
  )
  let from = must_ok(@core.Mailbox::address_only("sender@example.com"))
  expect_validation_error(
    @core.Message::new(
      from,
      [],
      [],
      [],
      "No recipients",
      @core.Body::plain_text("Hi"),
      [],
    ),
    EmptyMessageRecipients,
  )
  expect_validation_error(@core.Body::attachment("", [b'X']), EmptyFilename)
  expect_validation_error(
    @core.Body::inline_asset(
      "",
      "logo.png",
      @core.ContentType::new("image", "png", []),
      [b'X'],
    ),
    EmptyContentId,
  )
}

///|
test "keep message recipients separate from smtp envelope recipients" {
  let from = must_ok(@core.Mailbox::address_only("sender@example.com"))
  let visible = must_ok(@core.Mailbox::address_only("visible@example.com"))
  let hidden = must_ok(@core.Mailbox::address_only("hidden@example.com"))
  let message = must_ok(
    @core.Message::new(
      from,
      [visible],
      [],
      [hidden],
      "Hidden recipient flow",
      @core.Body::plain_text("Hi"),
      [],
    ),
  )
  let envelope = must_ok(@core.Envelope::new(from, [hidden]))
  assert_true(message.to == [visible])
  assert_true(message.bcc == [hidden])
  assert_true(message.all_recipients() == [visible, hidden])
  assert_true(envelope.rcpt_to == [hidden])
}

///|
test "reject alternative multipart containing attachments" {
  let attachment = must_ok(@core.Body::attachment("report.txt", [b'R']))
  expect_validation_error(
    @core.Body::alternative([@core.Body::plain_text("Hello"), attachment]),
    AlternativeRequiresTextParts,
  )
  expect_validation_error(
    @core.Body::alternative([@core.Body::plain_text("Hello")]),
    AlternativeNeedsTwoParts,
  )
}

///|
test "reject header injection characters" {
  expect_validation_error(
    @core.Header::new("X Unsafe", "value"),
    IllegalHeaderNameChar(' '),
  )
  expect_validation_error(
    @core.Header::new("X-Safe", "line1\rline2"),
    IllegalHeaderValueChar('\r'),
  )
}

///|
test "derive smtp envelope from message recipients with deduplication" {
  let from = must_ok(@core.Mailbox::address_only("sender@example.com"))
  let to = must_ok(@core.Mailbox::address_only("reader@example.com"))
  let cc = must_ok(
    @core.Mailbox::new("reader@example.com", Some("Reader Alias")),
  )
  let bcc = must_ok(@core.Mailbox::address_only("hidden@example.com"))
  let message = must_ok(
    @core.Message::new(
      from,
      [to],
      [cc],
      [bcc],
      "Recipients",
      @core.Body::plain_text("Hi"),
      [],
    ),
  )
  let envelope = must_ok(@core.Envelope::from_message(from, message))
  assert_true(envelope.mail_from == from)
  assert_true(envelope.rcpt_to == [to, bcc])
}

///|
test "allow file-backed attachment sources without loading payloads" {
  let attachment = must_ok(
    @core.Body::attachment_file("report.txt", "/tmp/report.txt"),
  )
  let inline = must_ok(
    @core.Body::inline_asset_file(
      "logo",
      "logo.png",
      "/tmp/logo.png",
      @core.ContentType::new("image", "png", []),
    ),
  )
  match attachment {
    Binary(binary) =>
      match binary.source {
        FilePath(path) => assert_true(path == "/tmp/report.txt")
        _ => abort("expected file-backed attachment")
      }
    _ => abort("expected binary attachment")
  }
  match inline {
    Binary(binary) => {
      match binary.content_id {
        Some(id) => assert_true(id.value == "logo")
        None => abort("expected inline content id")
      }
      match binary.source {
        FilePath(path) => assert_true(path == "/tmp/logo.png")
        _ => abort("expected file-backed inline asset")
      }
    }
    _ => abort("expected binary inline asset")
  }
}
