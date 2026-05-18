///|
fn cli_command() -> @argparse.Command {
  @argparse.Command(
    "send-qq-email",
    about="Send a test email through QQ SMTP over TLS.",
    version="0.1.0",
    arg_required_else_help=true,
    options=[
      @argparse.OptionArg("sender", about="QQ sender address", required=true),
      @argparse.OptionArg("recipient", about="Recipient address", required=true),
      @argparse.OptionArg(
        "auth-code",
        about="QQ SMTP authorization code",
        required=true,
      ),
      @argparse.OptionArg("subject", about="Message subject", default_values=[
        "MoonBit QQ SMTP test",
      ]),
      @argparse.OptionArg("body", about="Plain text body", default_values=[
        "This message was sent by nexacodes/email cmd/main.",
      ]),
      @argparse.OptionArg(
        "attachment",
        about="Attachment file path, can be repeated",
        action=Append,
      ),
    ],
  )
}

///|
fn option_value(matches : @argparse.Matches, name : String) -> String {
  matches.values.get(name).unwrap_or([])[0]
}

///|
fn option_values(matches : @argparse.Matches, name : String) -> Array[String] {
  matches.values.get(name).unwrap_or([])
}

///|
fn mailbox_or_panic(label : String, address : String) -> @core.Mailbox {
  match @core.Mailbox::address_only(address) {
    Ok(mailbox) => mailbox
    Err(_) => {
      println("Invalid \{label} address: \{address}")
      panic()
    }
  }
}

///|
fn envelope_or_panic(
  sender : @core.Mailbox,
  recipient : @core.Mailbox,
) -> @core.Envelope {
  match @core.Envelope::new(sender, [recipient]) {
    Ok(envelope) => envelope
    Err(_) => {
      println("Failed to build SMTP envelope")
      panic()
    }
  }
}

///|
fn attachment_filename(path : String) -> String {
  let slash = path.rev_find("/")
  let backslash = path.rev_find("\\")
  let start = match (slash, backslash) {
    (Some(left), Some(right)) => if left > right { left + 1 } else { right + 1 }
    (Some(index), None) => index + 1
    (None, Some(index)) => index + 1
    (None, None) => 0
  }
  path[start:].to_owned()
}

///|
fn attachment_part_or_panic(path : String) -> @core.Body {
  let filename = attachment_filename(path)
  if filename == "" {
    println("Attachment path has no filename: \{path}")
    panic()
  }
  match
    @core.Body::attachment_file(
      filename,
      path,
      content_type=@codec.infer_content_type(filename),
    ) {
    Ok(body) => body
    Err(_) => {
      println("Failed to build attachment body for \{path}")
      panic()
    }
  }
}

///|
fn email_body_or_panic(
  body : String,
  attachment_paths : Array[String],
) -> @core.Body {
  if attachment_paths.is_empty() {
    return @core.Body::plain_text(body)
  }
  let parts : Array[@core.Body] = [@core.Body::plain_text(body)]
  for path in attachment_paths {
    parts.push(attachment_part_or_panic(path))
  }
  match @core.Body::mixed(parts) {
    Ok(multipart) => multipart
    Err(_) => {
      println("Failed to build multipart email body")
      panic()
    }
  }
}

///|
fn message_or_panic(
  sender : @core.Mailbox,
  recipient : @core.Mailbox,
  subject : String,
  body : @core.Body,
) -> @core.Message {
  match @core.Message::new(sender, [recipient], [], [], subject, body, []) {
    Ok(message) => message
    Err(_) => {
      println("Failed to build email message")
      panic()
    }
  }
}

///|
fn print_outcome(outcome : @transport.DeliveryOutcome) -> Unit {
  println("SMTP response: \{outcome.response}")
  println("Accepted recipients: \{outcome.accepted.length()}")
  println("Rejected recipients: \{outcome.rejected.length()}")
  println("Unsent recipients: \{outcome.unsent.length()}")
}

///|
async fn main {
  let matches = cli_command().parse()
  let sender_address = option_value(matches, "sender")
  let recipient_address = option_value(matches, "recipient")
  let auth_code = option_value(matches, "auth-code")
  let subject = option_value(matches, "subject")
  let body_text = option_value(matches, "body")
  let attachment_paths = option_values(matches, "attachment")

  let sender = mailbox_or_panic("sender", sender_address)
  let recipient = mailbox_or_panic("recipient", recipient_address)
  let envelope = envelope_or_panic(sender, recipient)
  let body = email_body_or_panic(body_text, attachment_paths)
  let message = message_or_panic(sender, recipient, subject, body)

  let config = @transport.SmtpConfig::new(
    "smtp.qq.com",
    465,
    security=@transport.SmtpSecurity::Tls,
    auth=@transport.SmtpAuth::Plain(sender_address, auth_code),
  )
  let transport = @transport.SmtpTransport::new(config)

  println("Connecting to smtp.qq.com:465 over TLS...")
  println("Sending from \{sender_address} to \{recipient_address} ...")
  if !attachment_paths.is_empty() {
    println("Attachments: \{attachment_paths.length()}")
  }

  try {
    let outcome = transport.send_message(envelope, message)
    print_outcome(outcome)
    if outcome.accepted.is_empty() {
      println("No recipients were accepted by the SMTP server.")
      panic()
    }
    println("Email send attempt completed.")
  } catch {
    err => {
      println("Send failed: \{err.to_string()}")
      panic()
    }
  }
}
