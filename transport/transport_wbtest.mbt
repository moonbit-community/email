///|
/// Whitebox inventory for transport internals.
test "advance the smtp state machine in the expected order" {
  let from = @core.Mailbox::address_only("sender@example.com").unwrap()
  let to = @core.Mailbox::address_only("reader@example.com").unwrap()
  let envelope = @core.Envelope::new(from, [to]).unwrap()
  assert_true(
    build_smtp_trace(envelope) ==
    [
      "connect", "ehlo", "mail-from:sender@example.com", "rcpt-count:1", "data",
      "quit",
    ],
  )
}

///|
test "classify transient and permanent smtp failures" {
  assert_true(classify_smtp_status(421) == FailureClass::Transient)
  assert_true(classify_smtp_status(550) == FailureClass::Permanent)
}

///|
test "preserve queue order while respecting pool capacity" {
  let first : Array[Int] = []
  for index in 0..<5 {
    first.push(assign_connection_id(index, 2))
  }
  let second : Array[Int] = []
  for index in 0..<3 {
    second.push(assign_connection_id(index, 1))
  }
  let third : Array[Int] = []
  for index in 0..<4 {
    third.push(assign_connection_id(index, 1))
  }
  assert_true(first == [0, 1, 0, 1, 0])
  assert_true(second == [0, 0, 0])
  assert_true(third == [0, 0, 0, 0])
}
