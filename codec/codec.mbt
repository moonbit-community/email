///|
pub(all) enum MimeMode {
  Strict
  Lenient
} derive(Eq, Debug)

///|
pub(all) suberror ParseError {
  Malformed(String)
  Unsupported(String)
  CoreValidation(@core.ValidationError)
} derive(Eq, Debug)

///|
pub(open) trait MimeWriter {
  async fn write_text(Self, String) -> Unit
}

///|
priv struct CollectWriter {
  builder : StringBuilder
}

///|
fn CollectWriter::new() -> CollectWriter {
  { builder: StringBuilder(), }
}

///|
impl MimeWriter for CollectWriter with fn write_text(self, text) {
  self.builder.write_string(text)
}

///|
/// Minimal synchronous serializer kept for in-memory use cases and tests.
/// File-backed attachment sources require `render_to_rfc5322` or `write_to`.
pub fn to_rfc5322(message : @core.Message) -> String {
  if contains_file_source(message.body) {
    abort("file-backed attachments require async render_to_rfc5322/write_to")
  }
  let builder = StringBuilder()
  write_message_headers_sync(builder, message, Strict)
  builder.write_string("\r\n")
  write_body_sync(builder, message.body, [], Strict)
  builder.to_string()
}

///|
pub async fn render_to_rfc5322(
  message : @core.Message,
  mode~ : MimeMode = Strict,
) -> String {
  let writer = CollectWriter::new()
  write_to(writer, message, mode~)
  writer.builder.to_string()
}

///|
pub async fn[W : MimeWriter] write_to(
  writer : W,
  message : @core.Message,
  mode~ : MimeMode = Strict,
) -> Unit {
  write_message_headers(writer, message, mode)
  writer.write_text("\r\n")
  write_body(writer, message.body, [], mode)
}

///|
fn min_int(left : Int32, right : Int32) -> Int32 {
  if left < right {
    left
  } else {
    right
  }
}

///|
pub fn infer_content_type(filename : String) -> @core.ContentType {
  let extension = match filename.rev_split_once(".") {
    Some((_, ext)) => ext.to_owned().to_lower()
    None => ""
  }
  match extension {
    "txt" => @core.ContentType::new("text", "plain", [])
    "md" => @core.ContentType::new("text", "markdown", [])
    "html" | "htm" => @core.ContentType::new("text", "html", [])
    "json" => @core.ContentType::new("application", "json", [])
    "csv" => @core.ContentType::new("text", "csv", [])
    "xml" => @core.ContentType::new("application", "xml", [])
    "pdf" => @core.ContentType::new("application", "pdf", [])
    "png" => @core.ContentType::new("image", "png", [])
    "jpg" | "jpeg" => @core.ContentType::new("image", "jpeg", [])
    "gif" => @core.ContentType::new("image", "gif", [])
    "webp" => @core.ContentType::new("image", "webp", [])
    "svg" => @core.ContentType::new("image", "svg+xml", [])
    "zip" => @core.ContentType::new("application", "zip", [])
    "gz" => @core.ContentType::new("application", "gzip", [])
    "tar" => @core.ContentType::new("application", "x-tar", [])
    "mbt" => @core.ContentType::new("text", "plain", [])
    "jsonl" => @core.ContentType::new("application", "x-ndjson", [])
    _ => @core.ContentType::application_octet_stream()
  }
}

///|
pub fn parse_rfc5322(
  input : String,
  mode~ : MimeMode = Lenient,
) -> @core.Message raise ParseError {
  let normalized = normalize_message_input(input, mode)
  let (raw_headers, raw_body) = split_headers_and_body(normalized)
  let headers = parse_headers_block(raw_headers, mode)

  let from = parse_single_mailbox(required_header(headers, "From"))
  let to = parse_mailbox_list(optional_header(headers, "To").unwrap_or(""))
  let cc = parse_mailbox_list(optional_header(headers, "Cc").unwrap_or(""))
  let bcc = parse_mailbox_list(optional_header(headers, "Bcc").unwrap_or(""))
  let subject = decode_encoded_words(
    optional_header(headers, "Subject").unwrap_or(""),
  )
  let custom_headers = collect_message_headers(headers)
  let body = parse_entity(headers, raw_body, mode)

  match @core.Message::new(from, to, cc, bcc, subject, body, custom_headers) {
    Ok(message) => message
    Err(error) => raise CoreValidation(error)
  }
}

///|
fn write_message_headers_sync(
  builder : StringBuilder,
  message : @core.Message,
  mode : MimeMode,
) -> Unit {
  builder.write_string(
    header_line("From", format_mailboxes([message.from]), mode),
  )
  builder.write_string(header_line("To", format_mailboxes(message.to), mode))
  if !message.cc.is_empty() {
    builder.write_string(header_line("Cc", format_mailboxes(message.cc), mode))
  }
  builder.write_string(
    header_line("Subject", encode_unstructured_header(message.subject), mode),
  )
  for header in message.headers {
    builder.write_string(
      header_line(header.name, encode_unstructured_header(header.value), mode),
    )
  }
  write_body_headers_sync(builder, message.body, [], mode)
}

///|
async fn[W : MimeWriter] write_message_headers(
  writer : W,
  message : @core.Message,
  mode : MimeMode,
) -> Unit {
  writer.write_text(header_line("From", format_mailboxes([message.from]), mode))
  writer.write_text(header_line("To", format_mailboxes(message.to), mode))
  if !message.cc.is_empty() {
    writer.write_text(header_line("Cc", format_mailboxes(message.cc), mode))
  }
  writer.write_text(
    header_line("Subject", encode_unstructured_header(message.subject), mode),
  )
  for header in message.headers {
    writer.write_text(
      header_line(header.name, encode_unstructured_header(header.value), mode),
    )
  }
  write_body_headers(writer, message.body, [], mode)
}

///|
fn write_body_headers_sync(
  builder : StringBuilder,
  body : @core.Body,
  path : Array[Int32],
  mode : MimeMode,
) -> Unit {
  for field in body_header_fields(body, path) {
    let (name, value) = field
    builder.write_string(header_line(name, value, mode))
  }
}

///|
async fn[W : MimeWriter] write_body_headers(
  writer : W,
  body : @core.Body,
  path : Array[Int32],
  mode : MimeMode,
) -> Unit {
  for field in body_header_fields(body, path) {
    let (name, value) = field
    writer.write_text(header_line(name, value, mode))
  }
}

///|
fn body_header_fields(
  body : @core.Body,
  path : Array[Int32],
) -> Array[(String, String)] {
  match body {
    Text(text) =>
      [
        (
          "Content-Type",
          format_text_content_type(text.content_type, text.charset),
        ),
        (
          "Content-Transfer-Encoding",
          format_transfer_encoding(text.transfer_encoding),
        ),
      ]
    Binary(binary) => {
      let fields : Array[(String, String)] = [
        ("Content-Type", format_content_type(binary.content_type)),
        ("Content-Disposition", format_content_disposition(binary.disposition)),
        (
          "Content-Transfer-Encoding",
          format_transfer_encoding(binary.transfer_encoding),
        ),
      ]
      match binary.content_id {
        Some(content_id) =>
          fields.push(("Content-Id", "<" + content_id.value + ">"))
        None => ()
      }
      fields
    }
    Multipart(kind, _) => {
      let boundary = boundary_for(path)
      [
        (
          "Content-Type",
          "multipart/" +
          format_multipart_kind(kind) +
          "; boundary=\"" +
          boundary +
          "\"",
        ),
      ]
    }
  }
}

///|
fn write_body_sync(
  builder : StringBuilder,
  body : @core.Body,
  path : Array[Int32],
  mode : MimeMode,
) -> Unit {
  ignore(mode)
  match body {
    Text(text) =>
      builder.write_string(
        encode_text_content(text.content, text.transfer_encoding),
      )
    Binary(binary) =>
      match binary.source {
        InMemory(data) =>
          builder.write_string(
            format_binary_payload_bytes(data, binary.transfer_encoding),
          )
        FilePath(_) =>
          abort(
            "file-backed attachments require async render_to_rfc5322/write_to",
          )
      }
    Multipart(kind, parts) => {
      let boundary = boundary_for(path)
      for index, part in parts.iter2() {
        builder.write_string("--" + boundary + "\r\n")
        let child_path = append_path(path, index)
        write_body_headers_sync(builder, part, child_path, mode)
        builder.write_string("\r\n")
        write_body_sync(builder, part, child_path, mode)
        builder.write_string("\r\n")
      }
      builder.write_string("--" + boundary + "--")
      ignore(kind)
    }
  }
}

///|
async fn[W : MimeWriter] write_body(
  writer : W,
  body : @core.Body,
  path : Array[Int32],
  mode : MimeMode,
) -> Unit {
  ignore(mode)
  match body {
    Text(text) =>
      writer.write_text(
        encode_text_content(text.content, text.transfer_encoding),
      )
    Binary(binary) =>
      write_binary_payload(writer, binary.source, binary.transfer_encoding)
    Multipart(kind, parts) => {
      let boundary = boundary_for(path)
      for index, part in parts.iter2() {
        writer.write_text("--" + boundary + "\r\n")
        let child_path = append_path(path, index)
        write_body_headers(writer, part, child_path, mode)
        writer.write_text("\r\n")
        write_body(writer, part, child_path, mode)
        writer.write_text("\r\n")
      }
      writer.write_text("--" + boundary + "--")
      ignore(kind)
    }
  }
}

///|
async fn[W : MimeWriter] write_binary_payload(
  writer : W,
  source : @core.AttachmentSource,
  encoding : @core.TransferEncoding,
) -> Unit {
  match (source, encoding) {
    (InMemory(data), Base64) =>
      write_base64_lines(writer, Bytes::from_array(data))
    (InMemory(data), _) => writer.write_text(bytes_to_ascii_string(data))
    (FilePath(path), Base64) => write_base64_file(writer, path)
    (FilePath(path), _) => write_raw_file(writer, path)
  }
}

///|
async fn[W : MimeWriter] write_base64_lines(writer : W, data : Bytes) -> Unit {
  let mut first = true
  for start = 0; start < data.length(); {
    let end = min_int(start + 57, data.length())
    if !first {
      writer.write_text("\r\n")
    }
    writer.write_text(@base64.encode(data[start:end]))
    first = false
    continue end
  }
}

///|
async fn[W : MimeWriter] write_base64_file(writer : W, path : String) -> Unit {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let pending : Array[Byte] = []
  let mut first = true
  while file.read_some(max_len=4096) is Some(chunk) {
    for byte in chunk {
      pending.push(byte)
    }
    while pending.length() >= 57 {
      if !first {
        writer.write_text("\r\n")
      }
      writer.write_text(@base64.encode(Bytes::from_array(pending[:57])))
      let remaining = pending[57:].to_owned()
      pending.clear()
      for byte in remaining {
        pending.push(byte)
      }
      first = false
    }
  }
  if !pending.is_empty() {
    if !first {
      writer.write_text("\r\n")
    }
    writer.write_text(@base64.encode(Bytes::from_array(pending[:])))
  }
}

///|
async fn[W : MimeWriter] write_raw_file(writer : W, path : String) -> Unit {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  while file.read_some(max_len=4096) is Some(chunk) {
    writer.write_text(bytes_to_ascii_string(chunk.to_array()))
  }
}

///|
fn header_line(name : String, value : String, mode : MimeMode) -> String {
  let raw = name + ": " + value
  match mode {
    Strict => fold_header_line(raw, 78) + "\r\n"
    Lenient => raw + "\r\n"
  }
}

///|
fn fold_header_line(line : String, max_len : Int32) -> String {
  if line.length() <= max_len {
    return line
  }
  let tokens = line.split(" ").to_array()
  if tokens.is_empty() {
    return line
  }
  let builder = StringBuilder()
  let mut current = tokens[0].to_owned()
  for token_view in tokens[1:] {
    let token = token_view.to_owned()
    let candidate = current + " " + token
    if candidate.length() <= max_len {
      current = candidate
    } else {
      builder.write_string(current)
      builder.write_string("\r\n ")
      current = token
    }
  }
  builder.write_string(current)
  builder.to_string()
}

///|
fn format_mailboxes(mailboxes : Array[@core.Mailbox]) -> String {
  mailboxes.map(format_mailbox).join(", ")
}

///|
fn format_mailbox(mailbox : @core.Mailbox) -> String {
  match mailbox.display_name {
    Some(display_name) =>
      encode_phrase(display_name) + " <" + mailbox.address + ">"
    None => mailbox.address
  }
}

///|
fn format_text_content_type(
  content_type : @core.ContentType,
  charset : @core.Charset,
) -> String {
  format_content_type_with_extra(content_type, [
    ("charset", format_charset(charset)),
  ])
}

///|
fn format_content_type(content_type : @core.ContentType) -> String {
  format_content_type_with_extra(content_type, [])
}

///|
fn format_content_type_with_extra(
  content_type : @core.ContentType,
  extra_parameters : Array[(String, String)],
) -> String {
  let base = content_type.top_level + "/" + content_type.sub_type
  let parameters = [
    for param in content_type.parameters => (param.name, param.value)
  ]
  for parameter in extra_parameters {
    parameters.push(parameter)
  }
  if parameters.is_empty() {
    base
  } else {
    base + "; " + format_header_params(parameters)
  }
}

///|
fn format_content_disposition(disposition : @core.ContentDisposition) -> String {
  let parts : Array[String] = [format_disposition_kind(disposition.kind)]
  match disposition.filename {
    Some(filename) => parts.push(format_parameter("filename", filename))
    None => ()
  }
  if !disposition.parameters.is_empty() {
    parts.push(
      format_header_params(
        [
          for param in disposition.parameters => (param.name, param.value)
        ],
      ),
    )
  }
  parts.join("; ")
}

///|
fn format_header_params(parameters : Array[(String, String)]) -> String {
  parameters
  .map(parameter => format_parameter(parameter.0, parameter.1))
  .join("; ")
}

///|
fn format_parameter(name : String, value : String) -> String {
  if needs_rfc2231_encoding(value) {
    name + "*=UTF-8''" + percent_encode_utf8(value)
  } else if name != "filename" && is_parameter_token(value) {
    name + "=" + value
  } else {
    name + "=\"" + escape_quoted_string(value) + "\""
  }
}

///|
fn escape_quoted_string(value : String) -> String {
  value.replace_all(old="\\", new="\\\\").replace_all(old="\"", new="\\\"")
}

///|
fn needs_rfc2231_encoding(value : String) -> Bool {
  for c in value.iter() {
    if c == '"' || c == '\\' || c == ';' {
      return true
    }
    let code = c.to_int()
    if code < 32 || code > 126 {
      return true
    }
  }
  false
}

///|
fn is_parameter_token(value : String) -> Bool {
  if value == "" {
    return false
  }
  for c in value.iter() {
    let code = c.to_int()
    if !(code is ('0'..<='9' | 'A'..<='Z' | 'a'..<='z' | '-' | '_' | '.')) {
      return false
    }
  }
  true
}

///|
fn percent_encode_utf8(value : String) -> String {
  let bytes = @utf8.encode(value)
  let builder = StringBuilder()
  for byte in bytes {
    let code = byte.to_int()
    if is_attr_char(code) {
      builder.write_char(code.unsafe_to_char())
    } else {
      builder.write_char('%')
      builder.write_string(to_upper_hex(code))
    }
  }
  builder.to_string()
}

///|
fn is_attr_char(code : Int32) -> Bool {
  code is ('0'..<='9' | 'A'..<='Z' | 'a'..<='z') ||
  code
  is ('!' | '#' | '$' | '&' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~')
}

///|
fn encode_phrase(value : String) -> String {
  if needs_encoded_word(value) {
    encode_encoded_words(value)
  } else {
    value
  }
}

///|
fn encode_unstructured_header(value : String) -> String {
  if needs_encoded_word(value) {
    encode_encoded_words(value)
  } else {
    value
  }
}

///|
fn needs_encoded_word(value : String) -> Bool {
  for c in value.iter() {
    let code = c.to_int()
    if code < 32 || code > 126 {
      return true
    }
  }
  false
}

///|
fn encode_encoded_words(value : String) -> String {
  let bytes = @utf8.encode(value)
  let words : Array[String] = []
  for start = 0; start < bytes.length(); {
    let end = min_int(start + 30, bytes.length())
    words.push("=?UTF-8?B?" + @base64.encode(bytes[start:end]) + "?=")
    continue end
  }
  words.join(" ")
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
fn encode_text_content(
  content : String,
  encoding : @core.TransferEncoding,
) -> String {
  match encoding {
    QuotedPrintable => encode_quoted_printable(content)
    Base64 =>
      format_binary_payload_bytes(
        @utf8.encode(content).to_array(),
        @core.TransferEncoding::base64(),
      )
    _ => normalize_text_newlines(content)
  }
}

///|
fn encode_quoted_printable(content : String) -> String {
  let normalized = normalize_text_newlines(content)
  let bytes = @utf8.encode(normalized)
  let builder = StringBuilder()
  let mut line_len = 0
  for index in 0..<bytes.length() {
    let byte = bytes[index]
    if byte == b'\r' && index + 1 < bytes.length() && bytes[index + 1] == b'\n' {
      builder.write_string("\r\n")
      line_len = 0
      continue
    }
    if byte == b'\n' {
      continue
    }
    let chunk = quoted_printable_chunk(bytes, index)
    if line_len + chunk.length() > 75 {
      builder.write_string("=\r\n")
      line_len = 0
    }
    builder.write_string(chunk)
    line_len += chunk.length()
  }
  builder.to_string()
}

///|
fn quoted_printable_chunk(bytes : Bytes, index : Int32) -> String {
  let byte = bytes[index]
  let value = byte.to_int()
  let is_trailing_whitespace = (byte == b' ' || byte == b'\t') &&
    (
      index + 1 == bytes.length() ||
      (
        bytes[index + 1] == b'\r' &&
        index + 2 < bytes.length() &&
        bytes[index + 2] == b'\n'
      )
    )
  if should_escape_quoted_printable_byte(byte) || is_trailing_whitespace {
    "=" + to_upper_hex(value)
  } else {
    String::from_array([value.unsafe_to_char()])
  }
}

///|
fn normalize_text_newlines(content : String) -> String {
  let without_crlf = content.replace_all(old="\r\n", new="\n")
  without_crlf.replace_all(old="\r", new="\n").replace_all(old="\n", new="\r\n")
}

///|
fn should_escape_quoted_printable_byte(byte : Byte) -> Bool {
  let value = byte.to_int()
  byte == b'=' || value < 32 || value > 126 || byte == b'\x7f'
}

///|
fn format_binary_payload_bytes(
  data : Array[Byte],
  encoding : @core.TransferEncoding,
) -> String {
  match encoding {
    Base64 => encode_base64(data)
    _ => bytes_to_ascii_string(data)
  }
}

///|
fn encode_base64(data : Array[Byte]) -> String {
  encode_base64_mime(Bytes::from_array(data))
}

///|
fn encode_base64_mime(data : Bytes) -> String {
  let builder = StringBuilder()
  let mut first = true
  for start = 0; start < data.length(); {
    let end = min_int(start + 57, data.length())
    if !first {
      builder.write_string("\r\n")
    }
    builder.write_string(@base64.encode(data[start:end]))
    first = false
    continue end
  }
  builder.to_string()
}

///|
fn bytes_to_ascii_string(data : Array[Byte]) -> String {
  let builder = StringBuilder()
  for byte in data {
    builder.write_char(byte.to_int().unsafe_to_char())
  }
  builder.to_string()
}

///|
fn to_upper_hex(value : Int32) -> String {
  let digits = "0123456789ABCDEF"
  let high = (value >> 4) & 15
  let low = value & 15
  String::from_array([
    digits[high].unsafe_to_char(),
    digits[low].unsafe_to_char(),
  ])
}

///|
fn boundary_for(path : Array[Int32]) -> String {
  if path.is_empty() {
    "moonbit-email-boundary-root"
  } else {
    "moonbit-email-boundary-" + path.map(index => index.to_string()).join("-")
  }
}

///|
fn append_path(path : Array[Int32], index : Int32) -> Array[Int32] {
  let next = path.copy()
  next.push(index)
  next
}

///|
fn contains_file_source(body : @core.Body) -> Bool {
  match body {
    Text(_) => false
    Binary(binary) =>
      match binary.source {
        InMemory(_) => false
        FilePath(_) => true
      }
    Multipart(_, parts) => parts.any(contains_file_source)
  }
}

///|
fn normalize_message_input(
  input : String,
  mode : MimeMode,
) -> String raise ParseError {
  match mode {
    Strict => {
      if input.contains("\r") && !input.contains("\r\n") {
        raise Malformed("strict mode requires CRLF newlines")
      }
      if input.contains("\n") && !input.contains("\r\n") {
        raise Malformed("strict mode requires CRLF newlines")
      }
      input
    }
    Lenient => normalize_text_newlines(input)
  }
}

///|
fn split_headers_and_body(input : String) -> (String, String) raise ParseError {
  match input.split_once("\r\n\r\n") {
    Some((headers, body)) => (headers.to_owned(), body.to_owned())
    None => raise Malformed("missing header/body separator")
  }
}

///|
fn parse_headers_block(
  block : String,
  mode : MimeMode,
) -> Array[(String, String)] raise ParseError {
  ignore(mode)
  let lines = block.split("\r\n").to_array()
  let headers : Array[(String, String)] = []
  let mut current_name = ""
  let mut current_value = ""
  for line_view in lines {
    let line = line_view.to_owned()
    if line.has_prefix(" ") || line.has_prefix("\t") {
      if current_name == "" {
        raise Malformed("folded header without a leading field")
      }
      current_value = current_value + " " + line.trim().to_owned()
      continue
    }
    if current_name != "" {
      headers.push((current_name, current_value))
    }
    match line.split_once(":") {
      Some((name, value)) => {
        current_name = name.to_owned()
        current_value = value.trim().to_owned()
      }
      None => raise Malformed("invalid header line: " + line)
    }
  }
  if current_name != "" {
    headers.push((current_name, current_value))
  }
  headers
}

///|
fn header_name_matches(actual : String, expected : String) -> Bool {
  actual.to_lower() == expected.to_lower()
}

///|
fn required_header(
  headers : Array[(String, String)],
  name : String,
) -> String raise ParseError {
  match optional_header(headers, name) {
    Some(value) => value
    None => raise Malformed("missing required header: " + name)
  }
}

///|
fn optional_header(headers : Array[(String, String)], name : String) -> String? {
  for header_entry in headers {
    let (header_name, value) = header_entry
    if header_name_matches(header_name, name) {
      return Some(value)
    }
  }
  None
}

///|
fn collect_message_headers(
  headers : Array[(String, String)],
) -> Array[@core.Header] raise ParseError {
  let collected : Array[@core.Header] = []
  for header_entry in headers {
    let (name, value) = header_entry
    if is_message_header(name) {
      ()
    } else if is_body_header(name) {
      ()
    } else {
      match @core.Header::new(name, decode_encoded_words(value)) {
        Ok(header) => collected.push(header)
        Err(error) => raise CoreValidation(error)
      }
    }
  }
  collected
}

///|
fn is_message_header(name : String) -> Bool {
  header_name_matches(name, "From") ||
  header_name_matches(name, "To") ||
  header_name_matches(name, "Cc") ||
  header_name_matches(name, "Bcc") ||
  header_name_matches(name, "Subject")
}

///|
fn is_body_header(name : String) -> Bool {
  header_name_matches(name, "Content-Type") ||
  header_name_matches(name, "Content-Transfer-Encoding") ||
  header_name_matches(name, "Content-Disposition") ||
  header_name_matches(name, "Content-Id")
}

///|
fn parse_single_mailbox(value : String) -> @core.Mailbox raise ParseError {
  match parse_mailbox_list(value) {
    [mailbox] => mailbox
    [] => raise Malformed("expected a mailbox")
    _ => raise Malformed("expected a single mailbox")
  }
}

///|
fn parse_mailbox_list(value : String) -> Array[@core.Mailbox] raise ParseError {
  let trimmed = value.trim()
  if trimmed == "" {
    return []
  }
  let mailboxes : Array[@core.Mailbox] = []
  for segment in split_mailbox_segments(trimmed.to_owned()) {
    mailboxes.push(parse_mailbox(segment))
  }
  mailboxes
}

///|
fn split_mailbox_segments(value : String) -> Array[String] {
  let segments : Array[String] = []
  let mut current = ""
  let mut angle_depth = 0
  let mut in_quotes = false
  for ch in value.iter() {
    if ch == '"' {
      in_quotes = !in_quotes
      current = current + ch.to_string()
    } else if ch == '<' && !in_quotes {
      angle_depth += 1
      current = current + ch.to_string()
    } else if ch == '>' && !in_quotes && angle_depth > 0 {
      angle_depth -= 1
      current = current + ch.to_string()
    } else if ch == ',' && !in_quotes && angle_depth == 0 {
      segments.push(current.trim().to_owned())
      current = ""
    } else {
      current = current + ch.to_string()
    }
  }
  let trailing = current.trim().to_owned()
  if trailing != "" {
    segments.push(trailing)
  }
  segments
}

///|
fn parse_mailbox(value : String) -> @core.Mailbox raise ParseError {
  let trimmed = value.trim()
  match trimmed.split_once("<") {
    Some((display_name, address_tail)) => {
      let address_text = address_tail
        .before(">")
        .unwrap_or(address_tail)
        .trim()
        .to_owned()
      let display_text = display_name.trim().trim(chars="\"").to_owned()
      let normalized_display = if display_text == "" {
        None
      } else {
        Some(decode_encoded_words(display_text))
      }
      match @core.Mailbox::new(address_text, normalized_display) {
        Ok(mailbox) => mailbox
        Err(error) => raise CoreValidation(error)
      }
    }
    None =>
      match @core.Mailbox::address_only(trimmed.to_owned()) {
        Ok(mailbox) => mailbox
        Err(error) => raise CoreValidation(error)
      }
  }
}

///|
fn parse_entity(
  headers : Array[(String, String)],
  body_text : String,
  mode : MimeMode,
) -> @core.Body raise ParseError {
  let content_type_text = optional_header(headers, "Content-Type").unwrap_or(
    "text/plain; charset=utf-8",
  )
  let transfer_encoding_text = optional_header(
    headers, "Content-Transfer-Encoding",
  ).unwrap_or("7bit")
  let disposition_text = optional_header(headers, "Content-Disposition")
  let content_id_text = optional_header(headers, "Content-Id")

  let content_type = parse_content_type(content_type_text)
  let transfer_encoding = parse_transfer_encoding(transfer_encoding_text)
  if content_type.top_level.to_lower() == "multipart" {
    let boundary = find_parameter(content_type.parameters, "boundary")
    let boundary = match boundary {
      Some(value) => value
      None => raise Malformed("multipart entity missing boundary")
    }
    let parts = split_multipart_parts(body_text, boundary)
    let bodies : Array[@core.Body] = []
    for part_text in parts {
      let (part_headers_text, part_body_text) = split_headers_and_body(
        part_text,
      )
      let part_headers = parse_headers_block(part_headers_text, mode)
      bodies.push(parse_entity(part_headers, part_body_text, mode))
    }
    match
      @core.Body::multipart(multipart_kind_for(content_type.sub_type), bodies) {
      Ok(body) => body
      Err(error) => raise CoreValidation(error)
    }
  } else if content_type.top_level.to_lower() == "text" {
    let decoded_text = decode_text_body(body_text, transfer_encoding)
    let charset = charset_from_content_type(content_type)
    @core.Body::text(
      remove_parameter(content_type, "charset"),
      charset,
      transfer_encoding,
      decoded_text,
    )
  } else {
    let decoded_bytes = decode_binary_body(body_text, transfer_encoding)
    let disposition = parse_content_disposition(disposition_text)
    let filename = disposition.filename
    let content_id = parse_content_id(content_id_text)
    match
      @core.Body::binary(
        content_type,
        disposition,
        transfer_encoding,
        filename,
        content_id,
        @core.AttachmentSource::in_memory(decoded_bytes.to_array()),
      ) {
      Ok(body) => body
      Err(error) => raise CoreValidation(error)
    }
  }
}

///|
fn multipart_kind_for(sub_type : String) -> @core.MultipartKind {
  match sub_type.to_lower() {
    "mixed" => @core.MultipartKind::mixed()
    "alternative" => @core.MultipartKind::alternative()
    "related" => @core.MultipartKind::related()
    other => @core.MultipartKind::custom(other)
  }
}

///|
fn charset_from_content_type(content_type : @core.ContentType) -> @core.Charset {
  match find_parameter(content_type.parameters, "charset") {
    Some(value) =>
      match value.to_lower() {
        "utf-8" => @core.Charset::utf8()
        "us-ascii" => @core.Charset::us_ascii()
        other => @core.Charset::other(other)
      }
    None => @core.Charset::utf8()
  }
}

///|
fn parse_content_type(value : String) -> @core.ContentType raise ParseError {
  let segments = split_parameter_segments(value)
  if segments.is_empty() {
    raise Malformed("empty Content-Type")
  }
  let media_type = segments[0].trim().to_owned()
  match media_type.split_once("/") {
    Some((top_level, sub_type)) => {
      let parameters : Array[@core.HeaderParam] = []
      for segment in segments[1:] {
        match parse_parameter(segment) {
          Some((name, parameter_value)) =>
            parameters.push(@core.HeaderParam::new(name, parameter_value))
          None => ()
        }
      }
      @core.ContentType::new(
        top_level.trim().to_owned(),
        sub_type.trim().to_owned(),
        parameters,
      )
    }
    None => raise Malformed("invalid Content-Type: " + value)
  }
}

///|
fn parse_content_disposition(
  value : String?,
) -> @core.ContentDisposition raise ParseError {
  match value {
    Some(text) => {
      let segments = split_parameter_segments(text)
      if segments.is_empty() {
        raise Malformed("empty Content-Disposition")
      }
      let kind = match segments[0].trim().to_lower() {
        "inline" => @core.DispositionKind::inline()
        "attachment" => @core.DispositionKind::attachment()
        other => @core.DispositionKind::other(other.to_owned())
      }
      let parameters : Array[@core.HeaderParam] = []
      let mut filename : String? = None
      for segment in segments[1:] {
        match parse_parameter(segment) {
          Some((name, parameter_value)) =>
            if name.to_lower() == "filename" {
              filename = Some(parameter_value)
            } else {
              parameters.push(@core.HeaderParam::new(name, parameter_value))
            }
          None => ()
        }
      }
      match filename {
        Some(name) =>
          match
            @core.ContentDisposition::new(kind, filename=name, parameters~) {
            Ok(disposition) => disposition
            Err(error) => raise CoreValidation(error)
          }
        None =>
          match @core.ContentDisposition::new(kind, parameters~) {
            Ok(disposition) => disposition
            Err(error) => raise CoreValidation(error)
          }
      }
    }
    None =>
      match @core.ContentDisposition::new(@core.DispositionKind::attachment()) {
        Ok(disposition) => disposition
        Err(error) => raise CoreValidation(error)
      }
  }
}

///|
fn parse_parameter(segment : StringView) -> (String, String)? raise ParseError {
  let trimmed = segment.trim()
  if trimmed == "" {
    return None
  }
  match trimmed.split_once("=") {
    Some((raw_name, raw_value)) => {
      let name = raw_name.trim().to_owned()
      let value = raw_value.trim().to_owned()
      if name.has_suffix("*") {
        Some(
          (name[0:name.length() - 1].to_owned(), decode_rfc2231_value(value)),
        )
      } else {
        Some((name, strip_parameter_value(value)))
      }
    }
    None => raise Malformed("invalid parameter: " + trimmed.to_owned())
  }
}

///|
fn split_parameter_segments(value : String) -> Array[String] {
  let segments : Array[String] = []
  let mut current = ""
  let mut in_quotes = false
  for ch in value.iter() {
    if ch == '"' {
      in_quotes = !in_quotes
      current = current + ch.to_string()
    } else if ch == ';' && !in_quotes {
      segments.push(current.trim().to_owned())
      current = ""
    } else {
      current = current + ch.to_string()
    }
  }
  segments.push(current.trim().to_owned())
  segments
}

///|
fn decode_rfc2231_value(value : String) -> String raise ParseError {
  let stripped = strip_parameter_value(value)
  let encoded = match stripped.split_once("''") {
    Some((_, rest)) => rest.to_owned()
    None => stripped
  }
  let bytes = decode_percent_bytes(encoded)
  @utf8.decode(bytes) catch {
    _ => raise Malformed("invalid RFC2231 UTF-8 parameter")
  }
}

///|
fn strip_parameter_value(value : String) -> String {
  value.trim().trim(chars="\"").to_owned()
}

///|
fn find_parameter(
  parameters : Array[@core.HeaderParam],
  name : String,
) -> String? {
  for parameter in parameters {
    if parameter.name.to_lower() == name.to_lower() {
      return Some(parameter.value)
    }
  }
  None
}

///|
fn remove_parameter(
  content_type : @core.ContentType,
  name : String,
) -> @core.ContentType {
  @core.ContentType::new(
    content_type.top_level,
    content_type.sub_type,
    content_type.parameters.filter(param => {
      param.name.to_lower() != name.to_lower()
    }),
  )
}

///|
fn parse_transfer_encoding(
  value : String,
) -> @core.TransferEncoding raise ParseError {
  match value.trim().to_lower() {
    "7bit" => @core.TransferEncoding::seven_bit()
    "8bit" => @core.TransferEncoding::eight_bit()
    "quoted-printable" => @core.TransferEncoding::quoted_printable()
    "base64" => @core.TransferEncoding::base64()
    "binary" => @core.TransferEncoding::binary()
    other =>
      raise Unsupported("unsupported transfer encoding: " + other.to_owned())
  }
}

///|
fn parse_content_id(value : String?) -> @core.ContentId? {
  match value {
    Some(text) =>
      match @core.ContentId::new(text.trim().trim(chars="<>").to_owned()) {
        Ok(content_id) => Some(content_id)
        Err(_) => None
      }
    None => None
  }
}

///|
fn split_multipart_parts(
  body_text : String,
  boundary : String,
) -> Array[String] raise ParseError {
  let lines = body_text.split("\r\n").to_array()
  let start_marker = "--" + boundary
  let end_marker = start_marker + "--"
  let parts : Array[String] = []
  let mut current = ""
  let mut in_part = false
  let mut saw_boundary = false
  for line_view in lines {
    let line = line_view.to_owned()
    if line == start_marker {
      saw_boundary = true
      if in_part {
        parts.push(trim_trailing_crlf(current))
        current = ""
      }
      in_part = true
      continue
    }
    if line == end_marker {
      if in_part {
        parts.push(trim_trailing_crlf(current))
      }
      return parts
    }
    if in_part {
      current = current + line + "\r\n"
    }
  }
  if !saw_boundary {
    raise Malformed("multipart boundary not found")
  }
  parts
}

///|
fn trim_trailing_crlf(value : String) -> String {
  if value.has_suffix("\r\n") {
    value[0:value.length() - 2].to_owned()
  } else {
    value
  }
}

///|
fn decode_text_body(
  body_text : String,
  transfer_encoding : @core.TransferEncoding,
) -> String raise ParseError {
  match transfer_encoding {
    QuotedPrintable => bytes_to_text(decode_quoted_printable_bytes(body_text))
    Base64 => decode_base64_text(body_text)
    _ => body_text.replace_all(old="\r\n", new="\n")
  }
}

///|
fn decode_binary_body(
  body_text : String,
  transfer_encoding : @core.TransferEncoding,
) -> Bytes raise ParseError {
  match transfer_encoding {
    QuotedPrintable => decode_quoted_printable_bytes(body_text)
    Base64 => decode_base64_bytes(body_text)
    _ => @utf8.encode(body_text)
  }
}

///|
fn decode_base64_text(body_text : String) -> String raise ParseError {
  bytes_to_text(decode_base64_bytes(body_text))
}

///|
fn decode_base64_bytes(body_text : String) -> Bytes raise ParseError {
  @base64.decode(body_text, ignore_whitespace=true) catch {
    _ => raise Malformed("invalid base64 payload")
  }
}

///|
fn bytes_to_text(bytes : Bytes) -> String raise ParseError {
  @utf8.decode(bytes).replace_all(old="\r\n", new="\n") catch {
    _ => raise Malformed("invalid UTF-8 text payload")
  }
}

///|
fn decode_quoted_printable_bytes(body_text : String) -> Bytes raise ParseError {
  let bytes = @utf8.encode(body_text)
  let output : Array[Byte] = []
  for index = 0; index < bytes.length(); {
    let byte = bytes[index]
    if byte == b'=' {
      if index + 2 < bytes.length() &&
        bytes[index + 1] == b'\r' &&
        bytes[index + 2] == b'\n' {
        continue index + 3
      }
      guard index + 2 < bytes.length() else {
        raise Malformed("truncated quoted-printable escape")
      }
      let high = hex_digit(bytes[index + 1].to_int().unsafe_to_char())
      let low = hex_digit(bytes[index + 2].to_int().unsafe_to_char())
      match (high, low) {
        (Some(high), Some(low)) => {
          output.push((high * 16 + low).to_byte())
          continue index + 3
        }
        _ => raise Malformed("invalid quoted-printable escape")
      }
    } else if byte == b'\r' &&
      index + 1 < bytes.length() &&
      bytes[index + 1] == b'\n' {
      output.push(b'\n')
      continue index + 2
    } else {
      output.push(byte)
      continue index + 1
    }
  }
  Bytes::from_array(output)
}

///|
fn hex_digit(ch : Char) -> Int32? {
  match ch {
    '0'..<='9' => Some(ch.to_int() - '0'.to_int())
    'A'..<='F' => Some(ch.to_int() - 'A'.to_int() + 10)
    'a'..<='f' => Some(ch.to_int() - 'a'.to_int() + 10)
    _ => None
  }
}

///|
fn decode_percent_bytes(value : String) -> Bytes raise ParseError {
  let output : Array[Byte] = []
  for index = 0; index < value.length(); {
    let ch = value.code_unit_at(index).to_int().unsafe_to_char()
    if ch == '%' {
      guard index + 2 < value.length() else {
        raise Malformed("truncated percent escape")
      }
      let high = hex_digit(
        value.code_unit_at(index + 1).to_int().unsafe_to_char(),
      )
      let low = hex_digit(
        value.code_unit_at(index + 2).to_int().unsafe_to_char(),
      )
      match (high, low) {
        (Some(high), Some(low)) => {
          output.push((high * 16 + low).to_byte())
          continue index + 3
        }
        _ => raise Malformed("invalid percent escape")
      }
    } else {
      output.push(ch.to_int().to_byte())
      continue index + 1
    }
  }
  Bytes::from_array(output)
}

///|
fn decode_encoded_words(value : String) -> String raise ParseError {
  let builder = StringBuilder()
  let mut index = 0
  while index < value.length() {
    if index + 1 < value.length() &&
      value[index:index + 2] == "=?" &&
      find_encoded_word_end(value, index) is Some(end) {
      let token = value[index:end].to_owned()
      builder.write_string(decode_encoded_word(token))
      index = end
      while index < value.length() &&
            value.code_unit_at(index).to_int().unsafe_to_char() == ' ' {
        if index + 2 < value.length() && value[index + 1:index + 3] == "=?" {
          index += 1
        } else {
          builder.write_char(' ')
          index += 1
          break
        }
      }
    } else {
      builder.write_char(value.code_unit_at(index).to_int().unsafe_to_char())
      index += 1
    }
  }
  builder.to_string()
}

///|
fn find_encoded_word_end(value : String, start : Int32) -> Int32? {
  let marker = value[start:].find("?=")
  match marker {
    Some(offset) => Some(start + offset + 2)
    None => None
  }
}

///|
fn decode_encoded_word(token : String) -> String raise ParseError {
  guard token.has_prefix("=?") && token.has_suffix("?=") else {
    raise Malformed("invalid encoded-word")
  }
  let inner = token[2:token.length() - 2].to_owned()
  let parts = inner.split("?").to_array()
  guard parts.length() == 3 else {
    raise Malformed("invalid encoded-word parts")
  }
  let charset = parts[0].to_owned().to_lower()
  let encoding = parts[1].to_owned().to_upper()
  let payload = parts[2].to_owned()
  guard charset == "utf-8" else {
    raise Unsupported("only UTF-8 encoded-word headers are supported")
  }
  let bytes = match encoding {
    "B" => decode_base64_bytes(payload)
    "Q" => decode_encoded_word_q(payload)
    _ => raise Unsupported("unsupported encoded-word encoding: " + encoding)
  }
  bytes_to_text(bytes)
}

///|
fn decode_encoded_word_q(payload : String) -> Bytes raise ParseError {
  let normalized = payload.replace_all(old="_", new=" ")
  decode_quoted_printable_bytes(normalized)
}
