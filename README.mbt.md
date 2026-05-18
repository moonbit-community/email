# nexacodes/email

[English](README.mbt.md) | [简体中文](README.zh-CN.md)

`nexacodes/email` is a MoonBit email library with a small top-level facade for the common cases:

- compose plain text, HTML, or multipart messages
- derive SMTP envelopes
- encode to RFC 5322 / MIME
- send through SMTP with a small number of steps

If you only want the public surface, start from the top-level package and treat the lower packages as implementation detail.

## Facade API

The main facade exports:

- `compose_plain_text`
- `compose_html`
- `compose_mixed`
- `envelope_for`
- `send_plain_text`
- `send_html`
- `send_mixed`
- `to_rfc5322`
- `parse_rfc5322`
- `render_to_rfc5322`

It also re-exports the common data types you need at the call site, such as:

- `Mailbox`
- `Body`
- `Message`
- `Envelope`
- `SmtpConfig`
- `SmtpTransport`
- `FakeTransport`
- `FileTransport`

## Quick Start

For a low-ceremony compose flow:

```moonbit nocheck
// assuming you import the `nexacodes/email` facade package

///|
let from = Mailbox::new("sender@example.com", Some("Sender")) |> must_ok

///|
let to = Mailbox::address_only("reader@example.com") |> must_ok

///|
let message = compose_plain_text(from, [to], "Greetings", "Hello from MoonBit!")
  |> must_ok

///|
let envelope = envelope_for(message) |> must_ok

///|
let encoded = to_rfc5322(message)
```

For a one-step SMTP send:

```moonbit nocheck
///|
let config = SmtpConfig::new(
  "smtp.example.com",
  465,
  security=SmtpSecurity::Tls,
  auth=SmtpAuth::Plain("sender@example.com", "app-password"),
)

///|
let outcome = send_plain_text(
    config,
    from,
    [to],
    "Greetings",
    "Hello from MoonBit!",
  )
  |> must_ok
```

`send_plain_text`, `send_html`, and `send_mixed` return `Result[..., ValidationError]` for message construction failures. SMTP protocol and connection failures remain the responsibility of the transport layer.

## HTML and Attachments

For multipart mail with attachments:

```moonbit nocheck
///|
let attachment = Body::attachment_file(
    "report.pdf",
    "/path/to/report.pdf",
    content_type=infer_content_type("report.pdf"),
  )
  |> must_ok

///|
let message = compose_mixed(from, [to], "Monthly report", [
    Body::plain_text("See attachment."),
    attachment,
  ])
  |> must_ok
```

If you want to send that style of message in one step, use `send_mixed`.

## Testing and Local Inspection

For unit tests, use `FakeTransport`:

```moonbit nocheck
let transport = FakeTransport::new()
let outcome = transport.send_message(envelope, message) |> must_ok
```

For local `.eml` output, use `FileTransport`.

For real delivery, use `SmtpTransport`.

## Command-Line Example

The repository includes a runnable example in [cmd/main/main.mbt](cmd/main/main.mbt).

It demonstrates:

- QQ SMTP over TLS
- repeated `--attachment` arguments
- file-backed attachment sending through `SmtpTransport`

```bash
moon run cmd/main -- \
  --sender your-account@example.com \
  --recipient someone@example.com \
  --auth-code your-auth-code \
  --subject "MoonBit email test" \
  --body "Hello from nexacodes/email"
```

## Status

Available today:

- top-level facade helpers for compose and send flows
- MIME render and parse support
- in-memory and file-backed attachments
- fake, file, and real SMTP transports

Still evolving:

- higher-level extension features under `ext`
- provider-specific integrations

Architecture notes remain available in [docs/architecture.md](docs/architecture.md) if you want the lower-level package boundaries and design rationale.

## Development

```bash
moon check
moon test
moon info
moon fmt
```
