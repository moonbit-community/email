///|
/// Top-level facade package.
/// Keep this package thin and use it to re-export stable APIs from subpackages.
pub using @core {
  type AttachmentSource,
  type BinaryBody,
  type Body,
  type Charset,
  type ContentDisposition,
  type ContentId,
  type ContentType,
  type DispositionKind,
  type Envelope,
  type Header,
  type HeaderParam,
  type Mailbox,
  type Message,
  type MultipartKind,
  type TextBody,
  type TransferEncoding,
  type ValidationError,
}

///|
pub using @codec {
  infer_content_type,
  parse_rfc5322,
  render_to_rfc5322,
  to_rfc5322,
  type MimeMode,
}

///|
pub using @transport {
  type DeliveryOutcome,
  type DeliveryRecord,
  type FailureClass,
  type FakeTransport,
  type FileArtifact,
  type FileTransport,
  type SmtpAuth,
  type SmtpAuthMechanism,
  type SmtpCapabilities,
  type SmtpClientError,
  type SmtpConfig,
  type SmtpPhase,
  type SmtpRetryPolicy,
  type SmtpSecurity,
  type SmtpTransport,
  type SmtpTimeouts,
  type StubSmtpTransport,
  type SmtpTlsTrust,
  type TransportError,
}

///|
pub fn compose_message(
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  body : Body,
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
) -> Result[Message, ValidationError] {
  Message::new(from, to, cc, bcc, subject, body, headers)
}

///|
pub fn compose_plain_text(
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  content : String,
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
) -> Result[Message, ValidationError] {
  compose_message(
    from,
    to,
    subject,
    Body::plain_text(content),
    cc~,
    bcc~,
    headers~,
  )
}

///|
pub fn compose_html(
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  content : String,
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
) -> Result[Message, ValidationError] {
  compose_message(from, to, subject, Body::html(content), cc~, bcc~, headers~)
}

///|
pub fn compose_mixed(
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  parts : Array[Body],
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
) -> Result[Message, ValidationError] {
  match Body::mixed(parts) {
    Ok(body) => compose_message(from, to, subject, body, cc~, bcc~, headers~)
    Err(error) => Err(error)
  }
}

///|
async fn send_composed_message(
  config : SmtpConfig,
  message_result : Result[Message, ValidationError],
  mail_from : Mailbox?,
) -> Result[DeliveryOutcome, ValidationError] {
  match message_result {
    Ok(message) => {
      let envelope_result = match mail_from {
        Some(value) => Envelope::from_message(value, message)
        None => Envelope::from_message(message.from, message)
      }
      match envelope_result {
        Ok(envelope) => {
          let transport = SmtpTransport::new(config)
          Ok(transport.send_message(envelope, message))
        }
        Err(error) => Err(error)
      }
    }
    Err(error) => Err(error)
  }
}

///|
pub fn envelope_for(
  message : Message,
  mail_from? : Mailbox,
) -> Result[Envelope, ValidationError] {
  let sender = match mail_from {
    Some(value) => value
    None => message.from
  }
  Envelope::from_message(sender, message)
}

///|
pub async fn send_plain_text(
  config : SmtpConfig,
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  content : String,
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
  mail_from? : Mailbox,
) -> Result[DeliveryOutcome, ValidationError] {
  send_composed_message(
    config,
    compose_plain_text(from, to, subject, content, cc~, bcc~, headers~),
    mail_from,
  )
}

///|
pub async fn send_html(
  config : SmtpConfig,
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  content : String,
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
  mail_from? : Mailbox,
) -> Result[DeliveryOutcome, ValidationError] {
  send_composed_message(
    config,
    compose_html(from, to, subject, content, cc~, bcc~, headers~),
    mail_from,
  )
}

///|
pub async fn send_mixed(
  config : SmtpConfig,
  from : Mailbox,
  to : Array[Mailbox],
  subject : String,
  parts : Array[Body],
  cc? : Array[Mailbox] = [],
  bcc? : Array[Mailbox] = [],
  headers? : Array[Header] = [],
  mail_from? : Mailbox,
) -> Result[DeliveryOutcome, ValidationError] {
  send_composed_message(
    config,
    compose_mixed(from, to, subject, parts, cc~, bcc~, headers~),
    mail_from,
  )
}
