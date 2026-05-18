///|
/// Whitebox inventory for codec internals.
test "fold long headers at compliant boundaries" {
  let folded = header_line(
    "Subject",
    encode_unstructured_header(
      "This is a very long subject line that should fold across multiple MIME header lines cleanly",
    ),
    Strict,
  )
  assert_true(folded.contains("\r\n "))
  assert_true(folded.has_prefix("Subject: "))
}

///|
test "generate unique boundaries for nested multipart nodes" {
  assert_true(boundary_for([]) == "moonbit-email-boundary-root")
  assert_true(boundary_for([0]) == "moonbit-email-boundary-0")
  assert_true(boundary_for([1, 2]) == "moonbit-email-boundary-1-2")
  assert_true(append_path([1, 2], 3) == [1, 2, 3])
}

///|
test "chunk base64 and quoted-printable output correctly" {
  assert_true(encode_base64([b'M', b'a', b'n']) == "TWFu")
  assert_true(encode_base64([b'O', b'K']) == "T0s=")
  assert_true(
    encode_quoted_printable("你好=MoonBit") == "=E4=BD=A0=E5=A5=BD=3DMoonBit",
  )
  assert_true(
    encode_base64_mime(
      Bytes::from_array([
        b'a', b'b', b'c', b'd', b'e', b'f', b'g', b'h', b'i', b'j', b'k', b'l', b'm',
        b'n', b'o', b'p', b'q', b'r', b's', b't', b'u', b'v', b'w', b'x', b'y', b'z',
        b'0', b'1', b'2', b'3', b'4', b'5', b'6', b'7', b'8', b'9', b'a', b'b', b'c',
        b'd', b'e', b'f', b'g', b'h', b'i', b'j', b'k', b'l', b'm', b'n', b'o', b'p',
        b'q', b'r', b's', b't', b'u', b'v',
      ]),
    ).contains("\r\n"),
  )
}

///|
test "separate strict and lenient parser modes" {
  let lf_only = "From: sender@example.com\nTo: reader@example.com\nSubject: Hi\n\nHello"
  try parse_rfc5322(lf_only, mode=Strict) catch {
    _ => ()
  } noraise {
    _ => abort("expected strict parser rejection")
  }
  let parsed = parse_rfc5322(lf_only, mode=Lenient) catch {
    _ => abort("expected lenient parser success")
  }
  assert_true(parsed.subject == "Hi")
}
