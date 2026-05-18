///|
/// Whitebox inventory for codec internals.
test "fold long headers at compliant boundaries" {
  // TODO: define the low-level folding behavior.
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
}

///|
test "separate strict and lenient parser modes" {
  // TODO: define parser behavior differences without changing the public AST.
}
