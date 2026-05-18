///|
/// Whitebox inventory for transport internals.
test "advance the smtp state machine in the expected order" {
  let from = @core.Mailbox::address_only("sender@example.com").unwrap()
  let to = @core.Mailbox::address_only("reader@example.com").unwrap()
  let envelope = @core.Envelope::new(from, [to]).unwrap()
  assert_true(
    build_smtp_trace(envelope) == [
      "connect",
      "ehlo",
      "mail-from:sender@example.com",
      "rcpt-count:1",
      "data",
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
  assert_true(schedule_connection_ids(5, 2) == [0, 1, 0, 1, 0])
  assert_true(schedule_connection_ids(3, 1) == [0, 0, 0])
  assert_true(schedule_connection_ids(4, 0) == [0, 0, 0, 0])
}
