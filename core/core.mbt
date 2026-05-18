///|
/// Shared validation errors for core domain constructors.
pub(all) enum ValidationError {
  EmptyAddress
  MissingAtSign
  MultipleAtSigns
  MissingLocalPart
  MissingDomain
  UnexpectedWhitespace
  EmptyHeaderName
  IllegalHeaderNameChar(Char)
  IllegalHeaderValueChar(Char)
  EmptyRecipients
  EmptyMessageRecipients
  EmptyMultipart
  AlternativeNeedsTwoParts
  AlternativeRequiresTextParts
  EmptyFilename
  EmptyContentId
} derive(Eq, Debug)

///|
pub enum Charset {
  Utf8
  UsAscii
  Other(String)
} derive(Eq, Debug)

///|
pub enum TransferEncoding {
  SevenBit
  EightBit
  QuotedPrintable
  Base64
  Binary
} derive(Eq, Debug)

///|
pub enum DispositionKind {
  Inline
  Attachment
  Other(String)
} derive(Eq, Debug)

///|
pub enum MultipartKind {
  Mixed
  Alternative
  Related
  Custom(String)
} derive(Eq, Debug)

///|
pub struct HeaderParam {
  name : String
  value : String
} derive(Eq, Debug)

///|
pub struct ContentType {
  top_level : String
  sub_type : String
  parameters : Array[HeaderParam]
} derive(Eq, Debug)

///|
pub struct ContentId {
  value : String
} derive(Eq, Debug)

///|
pub struct ContentDisposition {
  kind : DispositionKind
  filename : String?
  parameters : Array[HeaderParam]
} derive(Eq, Debug)

///|
pub struct Mailbox {
  display_name : String?
  address : String
} derive(Eq, Debug)

///|
pub struct Header {
  name : String
  value : String
} derive(Eq, Debug)

///|
pub struct TextBody {
  content_type : ContentType
  charset : Charset
  transfer_encoding : TransferEncoding
  content : String
} derive(Eq, Debug)

///|
pub struct BinaryBody {
  content_type : ContentType
  disposition : ContentDisposition
  transfer_encoding : TransferEncoding
  filename : String?
  content_id : ContentId?
  data : Array[Byte]
} derive(Eq, Debug)

///|
pub enum Body {
  Text(TextBody)
  Binary(BinaryBody)
  Multipart(MultipartKind, Array[Body])
} derive(Eq, Debug)

///|
pub struct Message {
  from : Mailbox
  to : Array[Mailbox]
  cc : Array[Mailbox]
  bcc : Array[Mailbox]
  subject : String
  headers : Array[Header]
  body : Body
} derive(Eq, Debug)

///|
pub struct Envelope {
  mail_from : Mailbox
  rcpt_to : Array[Mailbox]
} derive(Eq, Debug)

///|
pub fn ContentType::new(
  top_level : String,
  sub_type : String,
  parameters : Array[HeaderParam],
) -> ContentType {
  ContentType::{ top_level, sub_type, parameters }
}

///|
pub fn ContentType::text_plain() -> ContentType {
  ContentType::new("text", "plain", [])
}

///|
pub fn ContentType::text_html() -> ContentType {
  ContentType::new("text", "html", [])
}

///|
pub fn ContentType::application_octet_stream() -> ContentType {
  ContentType::new("application", "octet-stream", [])
}

///|
pub fn Header::new(
  name : String,
  value : String,
) -> Result[Header, ValidationError] {
  match validate_header_name(name) {
    Ok(_) =>
      match validate_header_value(value) {
        Ok(_) => Ok(Header::{ name, value })
        Err(error) => Err(error)
      }
    Err(error) => Err(error)
  }
}

///|
pub fn Mailbox::new(
  address : String,
  display_name : String?,
) -> Result[Mailbox, ValidationError] {
  match validate_address(address) {
    Ok(_) => Ok(Mailbox::{ display_name, address })
    Err(error) => Err(error)
  }
}

///|
pub fn Mailbox::address_only(
  address : String,
) -> Result[Mailbox, ValidationError] {
  Mailbox::new(address, None)
}

///|
pub fn Body::plain_text(content : String) -> Body {
  Text(TextBody::{
    content_type: ContentType::text_plain(),
    charset: Charset::Utf8,
    transfer_encoding: TransferEncoding::QuotedPrintable,
    content,
  })
}

///|
pub fn Body::html(content : String) -> Body {
  Text(TextBody::{
    content_type: ContentType::text_html(),
    charset: Charset::Utf8,
    transfer_encoding: TransferEncoding::QuotedPrintable,
    content,
  })
}

///|
pub fn Body::attachment(
  filename : String,
  data : Array[Byte],
) -> Result[Body, ValidationError] {
  if filename == "" {
    return Err(EmptyFilename)
  }
  Ok(
    Binary(BinaryBody::{
      content_type: ContentType::application_octet_stream(),
      disposition: ContentDisposition::{
        kind: DispositionKind::Attachment,
        filename: Some(filename),
        parameters: [],
      },
      transfer_encoding: TransferEncoding::Base64,
      filename: Some(filename),
      content_id: None,
      data,
    }),
  )
}

///|
pub fn Body::inline_asset(
  content_id : String,
  filename : String,
  content_type : ContentType,
  data : Array[Byte],
) -> Result[Body, ValidationError] {
  if content_id == "" {
    return Err(EmptyContentId)
  }
  if filename == "" {
    return Err(EmptyFilename)
  }
  Ok(
    Binary(BinaryBody::{
      content_type,
      disposition: ContentDisposition::{
        kind: DispositionKind::Inline,
        filename: Some(filename),
        parameters: [],
      },
      transfer_encoding: TransferEncoding::Base64,
      filename: Some(filename),
      content_id: Some(ContentId::{ value: content_id }),
      data,
    }),
  )
}

///|
pub fn Body::mixed(parts : Array[Body]) -> Result[Body, ValidationError] {
  make_multipart(MultipartKind::Mixed, parts)
}

///|
pub fn Body::alternative(parts : Array[Body]) -> Result[Body, ValidationError] {
  make_multipart(MultipartKind::Alternative, parts)
}

///|
pub fn Body::related(parts : Array[Body]) -> Result[Body, ValidationError] {
  make_multipart(MultipartKind::Related, parts)
}

///|
pub fn Message::new(
  from : Mailbox,
  to : Array[Mailbox],
  cc : Array[Mailbox],
  bcc : Array[Mailbox],
  subject : String,
  body : Body,
  headers : Array[Header],
) -> Result[Message, ValidationError] {
  if to.is_empty() && cc.is_empty() && bcc.is_empty() {
    return Err(EmptyMessageRecipients)
  }
  Ok(Message::{ from, to, cc, bcc, subject, headers, body })
}

///|
pub fn Message::all_recipients(self : Message) -> Array[Mailbox] {
  let all : Array[Mailbox] = []
  for mailbox in self.to {
    all.push(mailbox)
  }
  for mailbox in self.cc {
    all.push(mailbox)
  }
  for mailbox in self.bcc {
    all.push(mailbox)
  }
  all
}

///|
pub fn Envelope::new(
  mail_from : Mailbox,
  rcpt_to : Array[Mailbox],
) -> Result[Envelope, ValidationError] {
  let normalized = normalize_mailboxes(rcpt_to)
  if normalized.is_empty() {
    return Err(EmptyRecipients)
  }
  Ok(Envelope::{ mail_from, rcpt_to: normalized })
}

///|
pub fn Envelope::from_message(
  mail_from : Mailbox,
  message : Message,
) -> Result[Envelope, ValidationError] {
  Envelope::new(mail_from, message.all_recipients())
}

///|
fn make_multipart(
  kind : MultipartKind,
  parts : Array[Body],
) -> Result[Body, ValidationError] {
  match validate_multipart(kind, parts) {
    Ok(_) => Ok(Multipart(kind, parts))
    Err(error) => Err(error)
  }
}

///|
fn validate_multipart(
  kind : MultipartKind,
  parts : Array[Body],
) -> Result[Unit, ValidationError] {
  if parts.is_empty() {
    return Err(EmptyMultipart)
  }
  match kind {
    Alternative => {
      if parts.length() < 2 {
        return Err(AlternativeNeedsTwoParts)
      }
      for part in parts {
        match part {
          Text(_) => ()
          _ => return Err(AlternativeRequiresTextParts)
        }
      }
      Ok(())
    }
    _ => Ok(())
  }
}

///|
fn normalize_mailboxes(mailboxes : Array[Mailbox]) -> Array[Mailbox] {
  let normalized : Array[Mailbox] = []
  for mailbox in mailboxes {
    if contains_mailbox_address(normalized, mailbox.address) {
      ()
    } else {
      normalized.push(mailbox)
    }
  }
  normalized
}

///|
fn contains_mailbox_address(
  mailboxes : Array[Mailbox],
  address : String,
) -> Bool {
  for mailbox in mailboxes {
    if mailbox.address == address {
      return true
    }
  }
  false
}

///|
fn validate_header_name(name : String) -> Result[Unit, ValidationError] {
  if name == "" {
    return Err(EmptyHeaderName)
  }
  for c in name.iter() {
    if c == ':' || c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      return Err(IllegalHeaderNameChar(c))
    }
  }
  Ok(())
}

///|
fn validate_header_value(value : String) -> Result[Unit, ValidationError] {
  for c in value.iter() {
    if c == '\n' || c == '\r' {
      return Err(IllegalHeaderValueChar(c))
    }
  }
  Ok(())
}

///|
fn validate_address(address : String) -> Result[Unit, ValidationError] {
  if address == "" {
    return Err(EmptyAddress)
  }
  if contains_address_whitespace(address) {
    return Err(UnexpectedWhitespace)
  }
  let mut at_count = 0
  let mut at_index = -1
  for index, c in address.iter2() {
    if c == '@' {
      at_count = at_count + 1
      at_index = index
    }
  }
  if at_count == 0 {
    return Err(MissingAtSign)
  }
  if at_count > 1 {
    return Err(MultipleAtSigns)
  }
  let local_part = address[:at_index].to_owned()
  let domain = address[at_index + 1:].to_owned()
  if local_part == "" {
    return Err(MissingLocalPart)
  }
  if domain == "" {
    return Err(MissingDomain)
  }
  Ok(())
}

///|
fn contains_address_whitespace(address : String) -> Bool {
  for c in address.iter() {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      return true
    }
  }
  false
}
