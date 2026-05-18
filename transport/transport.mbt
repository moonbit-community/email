///|
pub(all) enum TransportError {
  ClosedTransport
} derive(Eq, Debug)

///|
pub(all) enum FailureClass {
  Transient
  Permanent
} derive(Eq, Debug)

///|
pub struct DeliveryOutcome {
  accepted : Array[@core.Mailbox]
  rejected : Array[@core.Mailbox]
  unsent : Array[@core.Mailbox]
  response : String
  failure_class : FailureClass?
} derive(Eq, Debug)

///|
pub struct DeliveryRecord {
  envelope : @core.Envelope
  encoded_message : String
} derive(Eq, Debug)

///|
pub struct FileArtifact {
  path : String
  content : String
} derive(Eq, Debug)

///|
pub struct SmtpAttempt {
  envelope : @core.Envelope
  encoded_message : String
  connection_id : Int
  trace : Array[String]
} derive(Eq, Debug)

///|
pub struct FakeTransport {
  records : Array[DeliveryRecord]
  mut closed : Bool
} derive(Debug)

///|
pub struct FileTransport {
  root_dir : String
  artifacts : Array[FileArtifact]
  mut next_index : Int
  mut closed : Bool
} derive(Debug)

///|
pub struct SmtpTransport {
  pool_size : Int
  planned_outcomes : Array[DeliveryOutcome]
  mut next_plan_index : Int
  attempts : Array[SmtpAttempt]
  mut send_count : Int
  mut closed : Bool
} derive(Debug)

///|
pub fn DeliveryOutcome::all_accepted(
  recipients : Array[@core.Mailbox],
  response? : String = "250 OK",
) -> DeliveryOutcome {
  { accepted: recipients, rejected: [], unsent: [], response, failure_class: None }
}

///|
pub fn DeliveryOutcome::partial(
  accepted : Array[@core.Mailbox],
  rejected : Array[@core.Mailbox],
  unsent : Array[@core.Mailbox],
  response : String,
) -> DeliveryOutcome {
  let failure_class = derive_failure_class(accepted, rejected, unsent, response)
  { accepted, rejected, unsent, response, failure_class }
}

///|
pub fn FakeTransport::new() -> FakeTransport {
  { records: [], closed: false }
}

///|
pub fn FakeTransport::send(
  self : FakeTransport,
  envelope : @core.Envelope,
  encoded_message : String,
) -> Result[DeliveryOutcome, TransportError] {
  if self.closed {
    return Err(ClosedTransport)
  }
  self.records.push({ envelope, encoded_message })
  Ok(DeliveryOutcome::all_accepted(envelope.rcpt_to))
}

///|
pub fn FakeTransport::send_message(
  self : FakeTransport,
  envelope : @core.Envelope,
  message : @core.Message,
) -> Result[DeliveryOutcome, TransportError] {
  self.send(envelope, @codec.to_rfc5322(message))
}

///|
pub fn FakeTransport::close(self : FakeTransport) -> Unit {
  self.closed = true
}

///|
pub fn FakeTransport::records(self : FakeTransport) -> Array[DeliveryRecord] {
  self.records
}

///|
pub fn FileTransport::new(root_dir : String) -> FileTransport {
  { root_dir, artifacts: [], next_index: 0, closed: false }
}

///|
pub fn FileTransport::send(
  self : FileTransport,
  envelope : @core.Envelope,
  encoded_message : String,
) -> Result[DeliveryOutcome, TransportError] {
  if self.closed {
    return Err(ClosedTransport)
  }
  let artifact = {
    path: self.root_dir + "/" + format_artifact_name(self.next_index),
    content: encoded_message,
  }
  self.next_index += 1
  self.artifacts.push(artifact)
  Ok(DeliveryOutcome::all_accepted(envelope.rcpt_to))
}

///|
pub fn FileTransport::send_message(
  self : FileTransport,
  envelope : @core.Envelope,
  message : @core.Message,
) -> Result[DeliveryOutcome, TransportError] {
  self.send(envelope, @codec.to_rfc5322(message))
}

///|
pub fn FileTransport::close(self : FileTransport) -> Unit {
  self.closed = true
}

///|
pub fn FileTransport::artifacts(self : FileTransport) -> Array[FileArtifact] {
  self.artifacts
}

///|
pub fn SmtpTransport::new(
  pool_size? : Int = 1,
  planned_outcomes? : Array[DeliveryOutcome] = [],
) -> SmtpTransport {
  let normalized_pool = if pool_size < 1 { 1 } else { pool_size }
  {
    pool_size: normalized_pool,
    planned_outcomes,
    next_plan_index: 0,
    attempts: [],
    send_count: 0,
    closed: false,
  }
}

///|
pub fn SmtpTransport::send(
  self : SmtpTransport,
  envelope : @core.Envelope,
  encoded_message : String,
) -> Result[DeliveryOutcome, TransportError] {
  if self.closed {
    return Err(ClosedTransport)
  }
  let connection_id = assign_connection_id(self.send_count, self.pool_size)
  let trace = build_smtp_trace(envelope)
  self.attempts.push({ envelope, encoded_message, connection_id, trace })
  self.send_count += 1
  Ok(self.next_outcome(envelope))
}

///|
pub fn SmtpTransport::send_message(
  self : SmtpTransport,
  envelope : @core.Envelope,
  message : @core.Message,
) -> Result[DeliveryOutcome, TransportError] {
  self.send(envelope, @codec.to_rfc5322(message))
}

///|
pub fn SmtpTransport::close(self : SmtpTransport) -> Unit {
  self.closed = true
}

///|
pub fn SmtpTransport::attempts(self : SmtpTransport) -> Array[SmtpAttempt] {
  self.attempts
}

///|
fn SmtpTransport::next_outcome(
  self : SmtpTransport,
  envelope : @core.Envelope,
) -> DeliveryOutcome {
  match self.planned_outcomes.get(self.next_plan_index) {
    Some(outcome) => {
      self.next_plan_index += 1
      outcome
    }
    None => DeliveryOutcome::all_accepted(envelope.rcpt_to)
  }
}

///|
fn format_artifact_name(index : Int) -> String {
  let next = index + 1
  if next < 10 {
    "message-000" + next.to_string() + ".eml"
  } else if next < 100 {
    "message-00" + next.to_string() + ".eml"
  } else if next < 1000 {
    "message-0" + next.to_string() + ".eml"
  } else {
    "message-" + next.to_string() + ".eml"
  }
}

///|
fn build_smtp_trace(envelope : @core.Envelope) -> Array[String] {
  [
    "connect",
    "ehlo",
    "mail-from:" + envelope.mail_from.address,
    "rcpt-count:" + envelope.rcpt_to.length().to_string(),
    "data",
    "quit",
  ]
}

///|
fn classify_smtp_status(status : Int) -> FailureClass {
  if status >= 400 && status < 500 {
    Transient
  } else {
    Permanent
  }
}

///|
fn derive_failure_class(
  accepted : Array[@core.Mailbox],
  rejected : Array[@core.Mailbox],
  unsent : Array[@core.Mailbox],
  response : String,
) -> FailureClass? {
  if rejected.is_empty() && unsent.is_empty() {
    None
  } else {
    let _ = accepted
    match parse_status_code(response) {
      Some(status) => Some(classify_smtp_status(status))
      None => Some(Permanent)
    }
  }
}

///|
fn parse_status_code(response : String) -> Int? {
  if response.length() < 3 {
    return None
  }
  let c0 = response.code_unit_at(0).to_int()
  let c1 = response.code_unit_at(1).to_int()
  let c2 = response.code_unit_at(2).to_int()
  if is_ascii_digit_unit(c0) && is_ascii_digit_unit(c1) && is_ascii_digit_unit(c2) {
    Some(
      (digit_value_unit(c0) * 100) + (digit_value_unit(c1) * 10) + digit_value_unit(c2),
    )
  } else {
    None
  }
}

///|
fn is_ascii_digit_unit(code_unit : Int) -> Bool {
  code_unit >= '0'.to_int() && code_unit <= '9'.to_int()
}

///|
fn digit_value_unit(code_unit : Int) -> Int {
  code_unit - '0'.to_int()
}

///|
fn assign_connection_id(send_index : Int, pool_size : Int) -> Int {
  send_index % pool_size
}

///|
fn schedule_connection_ids(delivery_count : Int, pool_size : Int) -> Array[Int] {
  let normalized_pool = if pool_size < 1 { 1 } else { pool_size }
  let assigned : Array[Int] = []
  for index in 0..<delivery_count {
    assigned.push(assign_connection_id(index, normalized_pool))
  }
  assigned
}
