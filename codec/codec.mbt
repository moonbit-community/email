///|
/// Minimal RFC 5322 serializer for the first project milestone.
/// This keeps policy intentionally small: CRLF line endings, stable multipart
/// boundaries, and no `Bcc` header emission.
pub fn to_rfc5322(message : @core.Message) -> String {
  let builder = StringBuilder::new()
  write_message_headers(builder, message)
  builder.write_string("\r\n")
  write_body(builder, message.body, [])
  builder.to_string()
}

///|
fn write_message_headers(builder : StringBuilder, message : @core.Message) -> Unit {
  write_header_line(builder, "From", format_mailboxes([message.from]))
  write_header_line(builder, "To", format_mailboxes(message.to))
  if !message.cc.is_empty() {
    write_header_line(builder, "Cc", format_mailboxes(message.cc))
  }
  write_header_line(builder, "Subject", message.subject)
  for header in message.headers {
    write_header_line(builder, header.name, header.value)
  }
  write_body_headers(builder, message.body, [])
}

///|
fn write_body_headers(builder : StringBuilder, body : @core.Body, path : Array[Int]) -> Unit {
  match body {
    Text(text) => {
      write_header_line(
        builder,
        "Content-Type",
        format_text_content_type(text.content_type, text.charset),
      )
      write_header_line(
        builder,
        "Content-Transfer-Encoding",
        format_transfer_encoding(text.transfer_encoding),
      )
    }
    Binary(binary) => {
      write_header_line(builder, "Content-Type", format_content_type(binary.content_type))
      write_header_line(
        builder,
        "Content-Disposition",
        format_content_disposition(binary.disposition),
      )
      write_header_line(
        builder,
        "Content-Transfer-Encoding",
        format_transfer_encoding(binary.transfer_encoding),
      )
      match binary.content_id {
        Some(content_id) => write_header_line(builder, "Content-Id", "<" + content_id.value + ">")
        None => ()
      }
    }
    Multipart(kind, _) => {
      let boundary = boundary_for(path)
      write_header_line(
        builder,
        "Content-Type",
        "multipart/" + format_multipart_kind(kind) + "; boundary=\"" + boundary + "\"",
      )
    }
  }
}

///|
fn write_body(builder : StringBuilder, body : @core.Body, path : Array[Int]) -> Unit {
  match body {
    Text(text) => builder.write_string(encode_text_content(text.content, text.transfer_encoding))
    Binary(binary) => builder.write_string(format_binary_payload(binary.data, binary.transfer_encoding))
    Multipart(kind, parts) => {
      let boundary = boundary_for(path)
      for index, part in parts.iter2() {
        builder.write_string("--" + boundary + "\r\n")
        let child_path = append_path(path, index)
        write_body_headers(builder, part, child_path)
        builder.write_string("\r\n")
        write_body(builder, part, child_path)
        builder.write_string("\r\n")
      }
      builder.write_string("--" + boundary + "--")
      ignore(kind)
    }
  }
}

///|
fn write_header_line(builder : StringBuilder, name : String, value : String) -> Unit {
  builder.write_string(name)
  builder.write_string(": ")
  builder.write_string(value)
  builder.write_string("\r\n")
}

///|
fn format_mailboxes(mailboxes : Array[@core.Mailbox]) -> String {
  mailboxes.map(format_mailbox).join(", ")
}

///|
fn format_mailbox(mailbox : @core.Mailbox) -> String {
  match mailbox.display_name {
    Some(display_name) => display_name + " <" + mailbox.address + ">"
    None => mailbox.address
  }
}

///|
fn format_text_content_type(content_type : @core.ContentType, charset : @core.Charset) -> String {
  format_content_type(content_type) + "; charset=" + format_charset(charset)
}

///|
fn format_content_type(content_type : @core.ContentType) -> String {
  let base = content_type.top_level + "/" + content_type.sub_type
  if content_type.parameters.is_empty() {
    base
  } else {
    base + "; " + format_header_params(content_type.parameters)
  }
}

///|
fn format_content_disposition(disposition : @core.ContentDisposition) -> String {
  let parts : Array[String] = [format_disposition_kind(disposition.kind)]
  match disposition.filename {
    Some(filename) => parts.push("filename=\"" + filename + "\"")
    None => ()
  }
  if !disposition.parameters.is_empty() {
    parts.push(format_header_params(disposition.parameters))
  }
  parts.join("; ")
}

///|
fn format_header_params(parameters : Array[@core.HeaderParam]) -> String {
  parameters.map(param => param.name + "=\"" + param.value + "\"").join("; ")
}

///|
fn format_charset(charset : @core.Charset) -> String {
  match charset {
    Utf8 => "utf-8"
    UsAscii => "us-ascii"
    Other(name) => name
  }
}

///|
fn format_transfer_encoding(encoding : @core.TransferEncoding) -> String {
  match encoding {
    SevenBit => "7bit"
    EightBit => "8bit"
    QuotedPrintable => "quoted-printable"
    Base64 => "base64"
    Binary => "binary"
  }
}

///|
fn format_disposition_kind(kind : @core.DispositionKind) -> String {
  match kind {
    Inline => "inline"
    Attachment => "attachment"
    Other(name) => name
  }
}

///|
fn format_multipart_kind(kind : @core.MultipartKind) -> String {
  match kind {
    Mixed => "mixed"
    Alternative => "alternative"
    Related => "related"
    Custom(name) => name
  }
}

///|
fn encode_text_content(content : String, encoding : @core.TransferEncoding) -> String {
  match encoding {
    QuotedPrintable => encode_quoted_printable(content)
    _ => content
  }
}

///|
fn encode_quoted_printable(content : String) -> String {
  let utf8 = @buffer.new(size_hint=content.length())
  utf8.write_string_utf8(content)
  let bytes = utf8.to_bytes()
  let builder = StringBuilder::new()
  for byte in bytes {
    if byte == b'\r' {
      ()
    } else if byte == b'\n' {
      builder.write_string("\r\n")
    } else if should_escape_quoted_printable_byte(byte) {
      builder.write_char('=')
      builder.write_string(to_upper_hex(byte.to_int()))
    } else {
      builder.write_char(byte.to_int().unsafe_to_char())
    }
  }
  builder.to_string()
}

///|
fn should_escape_quoted_printable_byte(byte : Byte) -> Bool {
  let value = byte.to_int()
  byte == b'=' || value < 32 || value > 126
}

///|
fn format_binary_payload(data : Array[Byte], encoding : @core.TransferEncoding) -> String {
  match encoding {
    Base64 => encode_base64(data)
    _ => bytes_to_ascii_string(data)
  }
}

///|
fn encode_base64(data : Array[Byte]) -> String {
  @base64.encode(@buffer.from_array(data).to_bytes())
}

///|
fn bytes_to_ascii_string(data : Array[Byte]) -> String {
  let builder = StringBuilder::new()
  for byte in data {
    builder.write_char(byte.to_int().unsafe_to_char())
  }
  builder.to_string()
}

///|
fn to_upper_hex(value : Int) -> String {
  let digits = "0123456789ABCDEF"
  let high = (value >> 4) & 15
  let low = value & 15
  String::from_array([digits[high].unsafe_to_char(), digits[low].unsafe_to_char()])
}

///|
fn boundary_for(path : Array[Int]) -> String {
  if path.is_empty() {
    "moonbit-email-boundary-root"
  } else {
    "moonbit-email-boundary-" + path.map(index => index.to_string()).join("-")
  }
}

///|
fn append_path(path : Array[Int], index : Int) -> Array[Int] {
  let next = path.copy()
  next.push(index)
  next
}
