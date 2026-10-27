///|
pub(all) enum SmtpSecurity {
  Plain
  StartTls
  Tls
} derive(Eq, Debug)

///|
pub(all) enum SmtpAuthMechanism {
  Plain
  Login
  Xoauth2
} derive(Eq, Debug)

///|
pub(all) enum SmtpAuth {
  None
  Plain(String, String)
  Login(String, String)
  Xoauth2(String, String)
} derive(Eq, Debug)

///|
pub(all) enum SmtpPhase {
  Connect
  Greet
  Hello
  StartTls
  TlsHandshake
  Auth
  MailFrom
  RcptTo
  DataCommand
  MessageBody
  FinalResponse
  Quit
} derive(Eq, Debug)

///|
pub(all) enum SmtpTlsTrust {
  SystemRoot
  InsecureNoVerify
  CustomPemFile(String)
} derive(Eq, Debug)

///|
pub struct SmtpTimeouts {
  connect_ms : Int32
  greeting_ms : Int32
  command_ms : Int32
  data_ms : Int32
  idle_ms : Int32
} derive(Eq, Debug)

///|
pub struct SmtpRetryPolicy {
  max_retries : Int32
  retry_delay_ms : Int32
  retry_on_connection_failure : Bool
  retry_on_timeout : Bool
  retry_on_transient_failure : Bool
} derive(Eq, Debug)

///|
pub struct SmtpCapabilities {
  raw_lines : Array[String]
  auth_mechanisms : Array[SmtpAuthMechanism]
  supports_starttls : Bool
  supports_pipelining : Bool
  supports_8bitmime : Bool
  max_message_size : Int32?
} derive(Eq, Debug)

///|
pub struct SmtpConfig {
  host : String
  port : Int32
  hello_name : String
  security : SmtpSecurity
  auth : SmtpAuth
  tls_trust : SmtpTlsTrust
  timeouts : SmtpTimeouts
  retry_policy : SmtpRetryPolicy
  reuse_connection : Bool
} derive(Eq, Debug)

///|
pub suberror SmtpClientError {
  TransportClosed
  BusyTransport
  Timeout(SmtpPhase, Int32)
  ConnectionFailure(SmtpPhase, String)
  InvalidResponse(String)
  UnexpectedStatus(Int32, Int32, String)
  ServiceRejected(SmtpPhase, Int32, String, FailureClass)
  MissingExtension(String)
  MissingAuthMechanism(SmtpAuthMechanism)
  AuthFailed(String)
  ProtocolError(String)
} derive(Eq, Debug)

///|
priv enum LiveSmtpConnection {
  Plain(PlainSmtpSession)
  Tls(TlsSmtpSession)
}

///|
pub struct SmtpTransport {
  priv config : SmtpConfig
  priv mut closed : Bool
  priv mut in_flight : Bool
  priv mut live_connection : LiveSmtpConnection?
  priv mut last_capabilities : SmtpCapabilities?
  priv mut last_activity_ms : Int64
}

///|
priv enum OutgoingPayload {
  Encoded(String)
  Structured(@core.Message)
}

///|
priv struct SendProgress {
  mut data_started : Bool
}

///|
pub fn SmtpTimeouts::new(
  connect_ms~ : Int32 = 10_000,
  greeting_ms~ : Int32 = 10_000,
  command_ms~ : Int32 = 10_000,
  data_ms~ : Int32 = 120_000,
  idle_ms~ : Int32 = 60_000,
) -> SmtpTimeouts {
  { connect_ms, greeting_ms, command_ms, data_ms, idle_ms, }
}

///|
pub fn SmtpRetryPolicy::new(
  max_retries~ : Int32 = 1,
  retry_delay_ms~ : Int32 = 250,
  retry_on_connection_failure~ : Bool = true,
  retry_on_timeout~ : Bool = true,
  retry_on_transient_failure~ : Bool = true,
) -> SmtpRetryPolicy {
  {
    max_retries: if max_retries < 0 {
      0
    } else {
      max_retries
    },
    retry_delay_ms: if retry_delay_ms < 0 {
      0
    } else {
      retry_delay_ms
    },
    retry_on_connection_failure,
    retry_on_timeout,
    retry_on_transient_failure,
  }
}

///|
pub fn SmtpCapabilities::supports_auth(
  self : SmtpCapabilities,
  mechanism : SmtpAuthMechanism,
) -> Bool {
  self.auth_mechanisms.contains(mechanism)
}

///|
pub fn SmtpConfig::new(
  host : String,
  port : Int32,
  hello_name~ : String = "localhost",
  security~ : SmtpSecurity = Plain,
  auth~ : SmtpAuth = None,
  tls_trust~ : SmtpTlsTrust = SystemRoot,
  timeouts~ : SmtpTimeouts = SmtpTimeouts::new(),
  retry_policy~ : SmtpRetryPolicy = SmtpRetryPolicy::new(),
  reuse_connection~ : Bool = true,
) -> SmtpConfig {
  {
    host,
    port,
    hello_name,
    security,
    auth,
    tls_trust,
    timeouts,
    retry_policy,
    reuse_connection,
  }
}

///|
pub fn SmtpTransport::new(config : SmtpConfig) -> SmtpTransport {
  {
    config,
    closed: false,
    in_flight: false,
    live_connection: None,
    last_capabilities: None,
    last_activity_ms: 0L,
  }
}

///|
pub fn SmtpTransport::close(self : SmtpTransport) -> Unit {
  self.closed = true
  self.close_live_connection()
}

///|
pub fn SmtpTransport::capabilities(self : SmtpTransport) -> SmtpCapabilities? {
  self.last_capabilities
}

///|
pub async fn SmtpTransport::send(
  self : SmtpTransport,
  envelope : @core.Envelope,
  encoded_message : String,
) -> DeliveryOutcome {
  self.send_payload(envelope, Encoded(encoded_message))
}

///|
pub async fn SmtpTransport::send_message(
  self : SmtpTransport,
  envelope : @core.Envelope,
  message : @core.Message,
) -> DeliveryOutcome {
  self.send_payload(envelope, Structured(message))
}

///|
async fn SmtpTransport::send_payload(
  self : SmtpTransport,
  envelope : @core.Envelope,
  payload : OutgoingPayload,
) -> DeliveryOutcome {
  if self.closed {
    raise TransportClosed
  }
  if self.in_flight {
    raise BusyTransport
  }
  self.in_flight = true
  defer {
    self.in_flight = false
  }

  let mut attempt = 0
  for ;; {
    let progress = SendProgress::{ data_started: false, }
    try {
      self.ensure_live_connection()
      let outcome = self.deliver_with_live_connection(
        envelope, payload, progress,
      )
      self.last_activity_ms = @async.now()
      if !self.config.reuse_connection {
        self.close_live_connection()
      }
      return outcome
    } catch {
      err => {
        self.close_live_connection()
        if should_retry_send(self.config.retry_policy, err, progress, attempt) {
          attempt += 1
          if self.config.retry_policy.retry_delay_ms > 0 {
            @async.sleep(self.config.retry_policy.retry_delay_ms)
          }
          continue
        }
        raise err
      }
    }
  }
}

///|
async fn SmtpTransport::ensure_live_connection(self : SmtpTransport) -> Unit {
  if !self.config.reuse_connection {
    self.close_live_connection()
  } else if self.live_connection_is_stale() {
    self.close_live_connection()
  }
  if self.live_connection is Some(_) {
    return
  }
  let (connection, capabilities) = open_authenticated_connection(self.config)
  self.live_connection = Some(connection)
  self.last_capabilities = Some(capabilities)
  self.last_activity_ms = @async.now()
}

///|
fn SmtpTransport::live_connection_is_stale(self : SmtpTransport) -> Bool {
  if self.live_connection is None {
    return false
  }
  if self.config.timeouts.idle_ms <= 0 {
    return false
  }
  let idle_for = @async.now() - self.last_activity_ms
  idle_for > self.config.timeouts.idle_ms.to_int64()
}

///|
fn SmtpTransport::close_live_connection(self : SmtpTransport) -> Unit {
  match self.live_connection {
    Some(Plain(session)) => {
      session.io.close()
      self.live_connection = None
    }
    Some(Tls(session)) => {
      session.io.close()
      self.live_connection = None
    }
    None => ()
  }
}

///|
async fn SmtpTransport::deliver_with_live_connection(
  self : SmtpTransport,
  envelope : @core.Envelope,
  payload : OutgoingPayload,
  progress : SendProgress,
) -> DeliveryOutcome {
  match self.live_connection {
    Some(Plain(session)) =>
      match payload {
        Encoded(encoded_message) =>
          smtp_send_envelope_and_data(
            session,
            envelope,
            encoded_message,
            self.config.timeouts,
            progress,
          )
        Structured(message) =>
          smtp_send_message_and_data_streaming(
            session,
            PlainSmtpDataWriter::{ session, at_line_start: true, },
            envelope,
            message,
            self.config.timeouts,
            progress,
          )
      }
    Some(Tls(session)) =>
      match payload {
        Encoded(encoded_message) =>
          smtp_send_envelope_and_data(
            session,
            envelope,
            encoded_message,
            self.config.timeouts,
            progress,
          )
        Structured(message) =>
          smtp_send_message_and_data_streaming(
            session,
            TlsSmtpDataWriter::{ session, at_line_start: true, },
            envelope,
            message,
            self.config.timeouts,
            progress,
          )
      }
    None => raise ProtocolError("no active smtp connection")
  }
}

///|
async fn open_authenticated_connection(
  config : SmtpConfig,
) -> (LiveSmtpConnection, SmtpCapabilities) {
  match config.security {
    Plain => {
      let conn = execute_phase(Connect, config.timeouts.connect_ms, async fn() {
        @socket.Tcp::connect_to_host(config.host, port=config.port)
      })
      try {
        let session = PlainSmtpSession::{ io: conn, }
        let capabilities = smtp_greet_and_hello(session, config, true)
        smtp_auth(session, config.auth, capabilities, config.timeouts)
        (Plain(session), capabilities)
      } catch {
        err => {
          conn.close()
          raise err
        }
      }
    }
    Tls => {
      let conn = execute_phase(Connect, config.timeouts.connect_ms, async fn() {
        @socket.Tcp::connect_to_host(config.host, port=config.port)
      })
      let tls = execute_phase(TlsHandshake, config.timeouts.connect_ms, async fn() {
        @tls.Tls::client(
          conn,
          host=config.host,
          trust=smtp_tls_trust_to_async(config.tls_trust),
        )
      }) catch {
        err => {
          conn.close()
          raise err
        }
      }
      try {
        let session = TlsSmtpSession::{ io: tls, }
        let capabilities = smtp_greet_and_hello(session, config, true)
        smtp_auth(session, config.auth, capabilities, config.timeouts)
        (Tls(session), capabilities)
      } catch {
        err => {
          tls.close()
          raise err
        }
      }
    }
    StartTls => {
      let conn = execute_phase(Connect, config.timeouts.connect_ms, async fn() {
        @socket.Tcp::connect_to_host(config.host, port=config.port)
      })
      let plain = PlainSmtpSession::{ io: conn, }
      let negotiated = smtp_greet_and_hello(plain, config, false) catch {
        err => {
          conn.close()
          raise err
        }
      }
      guard negotiated.supports_starttls else {
        conn.close()
        raise MissingExtension("STARTTLS")
      }
      ignore(
        send_command_expect_status(
          plain,
          "STARTTLS",
          220,
          StartTls,
          config.timeouts.command_ms,
        ),
      ) catch {
        err => {
          conn.close()
          raise err
        }
      }
      let tls = execute_phase(TlsHandshake, config.timeouts.connect_ms, async fn() {
        @tls.Tls::client(
          plain.io,
          host=config.host,
          trust=smtp_tls_trust_to_async(config.tls_trust),
        )
      }) catch {
        err => {
          conn.close()
          raise err
        }
      }
      try {
        let session = TlsSmtpSession::{ io: tls, }
        let capabilities = send_hello(
          session,
          config.hello_name,
          false,
          config.timeouts.command_ms,
        )
        smtp_auth(session, config.auth, capabilities, config.timeouts)
        (Tls(session), capabilities)
      } catch {
        err => {
          tls.close()
          raise err
        }
      }
    }
  }
}

///|
fn auth_mechanism_for(auth : SmtpAuth) -> SmtpAuthMechanism? {
  match auth {
    None => None
    Plain(_, _) => Some(SmtpAuthMechanism::Plain)
    Login(_, _) => Some(SmtpAuthMechanism::Login)
    Xoauth2(_, _) => Some(SmtpAuthMechanism::Xoauth2)
  }
}

///|
fn require_auth_mechanism(
  capabilities : SmtpCapabilities,
  mechanism : SmtpAuthMechanism,
) -> Unit raise {
  if capabilities.auth_mechanisms.is_empty() {
    raise MissingExtension("AUTH")
  }
  if !capabilities.supports_auth(mechanism) {
    raise MissingAuthMechanism(mechanism)
  }
}

///|
async fn[X] execute_phase(
  phase : SmtpPhase,
  timeout_ms : Int32,
  work : async () -> X,
) -> X {
  try {
    if timeout_ms > 0 {
      @async.with_timeout(timeout_ms, work)
    } else {
      work()
    }
  } catch {
    @async.TimeoutError => raise Timeout(phase, timeout_ms)
    TransportClosed as err => raise err
    BusyTransport as err => raise err
    Timeout(_, _) as err => raise err
    InvalidResponse(_) as err => raise err
    UnexpectedStatus(_, _, _) as err => raise err
    ServiceRejected(_, _, _, _) as err => raise err
    MissingExtension(_) as err => raise err
    MissingAuthMechanism(_) as err => raise err
    AuthFailed(_) as err => raise err
    err => raise ConnectionFailure(phase, err.to_string())
  }
}

///|
priv trait SmtpSession {
  async fn read_line(Self) -> String
  async fn write_text(Self, String) -> Unit
}

///|
priv struct PlainSmtpSession {
  io : @socket.Tcp
}

///|
impl SmtpSession for PlainSmtpSession with fn read_line(self) {
  match self.io.read_until("\r\n") {
    Some(line) => line
    None => raise ProtocolError("connection closed while reading SMTP response")
  }
}

///|
impl SmtpSession for PlainSmtpSession with fn write_text(self, text) {
  self.io.write(text)
}

///|
priv struct TlsSmtpSession {
  io : @tls.Tls
}

///|
impl SmtpSession for TlsSmtpSession with fn read_line(self) {
  match self.io.read_until("\r\n") {
    Some(line) => line
    None => raise ProtocolError("connection closed while reading SMTP response")
  }
}

///|
impl SmtpSession for TlsSmtpSession with fn write_text(self, text) {
  self.io.write(text)
}

///|
priv struct PlainSmtpDataWriter {
  session : PlainSmtpSession
  mut at_line_start : Bool
}

///|
impl @codec.MimeWriter for PlainSmtpDataWriter with fn write_text(self, text) {
  let (stuffed, at_line_start) = dot_stuff_chunk(text, self.at_line_start)
  self.at_line_start = at_line_start
  self.session.write_text(stuffed)
}

///|
priv struct TlsSmtpDataWriter {
  session : TlsSmtpSession
  mut at_line_start : Bool
}

///|
impl @codec.MimeWriter for TlsSmtpDataWriter with fn write_text(self, text) {
  let (stuffed, at_line_start) = dot_stuff_chunk(text, self.at_line_start)
  self.at_line_start = at_line_start
  self.session.write_text(stuffed)
}

///|
fn empty_capabilities() -> SmtpCapabilities {
  {
    raw_lines: [],
    auth_mechanisms: [],
    supports_starttls: false,
    supports_pipelining: false,
    supports_8bitmime: false,
    max_message_size: (None : Int32?),
  }
}

///|
async fn[S : SmtpSession] smtp_greet_and_hello(
  session : S,
  config : SmtpConfig,
  fallback_ok : Bool,
) -> SmtpCapabilities {
  ignore(read_expect_status(session, 220, Greet, config.timeouts.greeting_ms))
  send_hello(
    session,
    config.hello_name,
    fallback_ok,
    config.timeouts.command_ms,
  )
}

///|
async fn[S : SmtpSession] send_hello(
  session : S,
  hello_name : String,
  fallback_ok : Bool,
  timeout_ms : Int32,
) -> SmtpCapabilities {
  write_line(session, "EHLO " + hello_name, Hello, timeout_ms)
  let first_line = read_line(session, Hello, timeout_ms)
  let code = parse_status_code_or_raise(first_line)
  if code == 250 {
    let lines = collect_multiline_response(
      session,
      first_line,
      Hello,
      timeout_ms,
    )
    return parse_capabilities(lines)
  }
  if fallback_ok && code >= 500 {
    ignore(
      send_command_expect_status(
        session,
        "HELO " + hello_name,
        250,
        Hello,
        timeout_ms,
      ),
    )
    return empty_capabilities()
  }
  let response = format_status_line(first_line)
  if code >= 400 && code < 600 {
    raise ServiceRejected(Hello, code, response, classify_smtp_status(code))
  }
  raise UnexpectedStatus(250, code, response)
}

///|
fn parse_capabilities(lines : Array[String]) -> SmtpCapabilities {
  let auth_mechanisms : Array[SmtpAuthMechanism] = []
  let mut supports_starttls = false
  let mut supports_pipelining = false
  let mut supports_8bitmime = false
  let mut max_message_size : Int32? = None
  for line in lines {
    let normalized = line.trim().to_upper()
    if normalized == "STARTTLS" {
      supports_starttls = true
    } else if normalized == "PIPELINING" {
      supports_pipelining = true
    } else if normalized == "8BITMIME" {
      supports_8bitmime = true
    } else if normalized.has_prefix("SIZE ") {
      max_message_size = parse_positive_int(normalized[5:].trim().to_owned())
    } else if normalized.has_prefix("AUTH ") {
      for token in normalized[5:].split(" ") {
        match parse_auth_mechanism_name(token.to_owned()) {
          Some(mechanism) =>
            if !auth_mechanisms.contains(mechanism) {
              auth_mechanisms.push(mechanism)
            }
          None => ()
        }
      }
    }
  }
  {
    raw_lines: lines,
    auth_mechanisms,
    supports_starttls,
    supports_pipelining,
    supports_8bitmime,
    max_message_size,
  }
}

///|
fn parse_auth_mechanism_name(name : String) -> SmtpAuthMechanism? {
  match name {
    "PLAIN" => Some(SmtpAuthMechanism::Plain)
    "LOGIN" => Some(SmtpAuthMechanism::Login)
    "XOAUTH2" => Some(SmtpAuthMechanism::Xoauth2)
    _ => None
  }
}

///|
async fn[S : SmtpSession] smtp_auth(
  session : S,
  auth : SmtpAuth,
  capabilities : SmtpCapabilities,
  timeouts : SmtpTimeouts,
) -> Unit {
  match auth_mechanism_for(auth) {
    Some(mechanism) => require_auth_mechanism(capabilities, mechanism)
    None => ()
  }
  match auth {
    None => ()
    Plain(username, password) => {
      let payload = encode_plain_auth(username, password)
      let line = send_command_capture(
        session,
        "AUTH PLAIN " + payload,
        Auth,
        timeouts.command_ms,
      )
      expect_auth_success(line)
    }
    Login(username, password) => {
      let line = send_command_capture(
        session,
        "AUTH LOGIN",
        Auth,
        timeouts.command_ms,
      )
      expect_auth_challenge(line)
      let username_line = send_command_capture(
        session,
        encode_base64_text(username),
        Auth,
        timeouts.command_ms,
      )
      expect_auth_challenge(username_line)
      let password_line = send_command_capture(
        session,
        encode_base64_text(password),
        Auth,
        timeouts.command_ms,
      )
      expect_auth_success(password_line)
    }
    Xoauth2(username, token) => {
      let payload = encode_xoauth2(username, token)
      let line = send_command_capture(
        session,
        "AUTH XOAUTH2 " + payload,
        Auth,
        timeouts.command_ms,
      )
      expect_auth_success(line)
    }
  }
}

///|
fn encode_plain_auth(username : String, password : String) -> String {
  encode_base64_text("\u{0000}" + username + "\u{0000}" + password)
}

///|
fn encode_xoauth2(username : String, token : String) -> String {
  encode_base64_text(
    "user=" + username + "\u{0001}auth=Bearer " + token + "\u{0001}\u{0001}",
  )
}

///|
fn encode_base64_text(text : String) -> String {
  @moonbitlang/core/encoding/base64.encode(
    @moonbitlang/core/encoding/utf8.encode(text),
  )
}

///|
fn expect_auth_success(line : String) -> Unit raise {
  let code = parse_status_code_or_raise(line)
  if code != 235 {
    raise AuthFailed(format_status_line(line))
  }
}

///|
fn expect_auth_challenge(line : String) -> Unit raise {
  let code = parse_status_code_or_raise(line)
  if code != 334 {
    raise AuthFailed(format_status_line(line))
  }
}

///|
async fn[S : SmtpSession] smtp_send_envelope_and_data(
  session : S,
  envelope : @core.Envelope,
  encoded_message : String,
  timeouts : SmtpTimeouts,
  progress : SendProgress,
) -> DeliveryOutcome {
  ignore(
    send_command_expect_status(
      session,
      "MAIL FROM:<" + envelope.mail_from.address + ">",
      250,
      MailFrom,
      timeouts.command_ms,
    ),
  )
  let accepted : Array[@core.Mailbox] = []
  let rejected : Array[@core.Mailbox] = []
  let mut rejection_response = "550 all recipients rejected"
  for recipient in envelope.rcpt_to {
    let line = send_command_capture(
      session,
      "RCPT TO:<" + recipient.address + ">",
      RcptTo,
      timeouts.command_ms,
    )
    let code = parse_status_code_or_raise(line)
    if code >= 200 && code < 300 {
      accepted.push(recipient)
    } else if code >= 400 && code < 600 {
      rejected.push(recipient)
      rejection_response = format_status_line(line)
    } else {
      raise InvalidResponse(line)
    }
  }
  if accepted.is_empty() {
    return DeliveryOutcome::partial([], rejected, [], rejection_response)
  }
  ignore(
    send_command_expect_status(
      session,
      "DATA",
      354,
      DataCommand,
      timeouts.command_ms,
    ),
  )
  progress.data_started = true
  write_text(
    session,
    dot_stuff_message(encoded_message) + "\r\n.\r\n",
    MessageBody,
    timeouts.data_ms,
  )
  let final_line = read_expect_status(
    session,
    250,
    FinalResponse,
    timeouts.command_ms,
  )
  let response = format_status_line(final_line)
  if rejected.is_empty() {
    DeliveryOutcome::all_accepted(accepted, response~)
  } else {
    DeliveryOutcome::partial(accepted, rejected, [], response)
  }
}

///|
async fn[S : SmtpSession, W : @codec.MimeWriter] smtp_send_message_and_data_streaming(
  session : S,
  writer : W,
  envelope : @core.Envelope,
  message : @core.Message,
  timeouts : SmtpTimeouts,
  progress : SendProgress,
) -> DeliveryOutcome {
  ignore(
    send_command_expect_status(
      session,
      "MAIL FROM:<" + envelope.mail_from.address + ">",
      250,
      MailFrom,
      timeouts.command_ms,
    ),
  )
  let accepted : Array[@core.Mailbox] = []
  let rejected : Array[@core.Mailbox] = []
  let mut rejection_response = "550 all recipients rejected"
  for recipient in envelope.rcpt_to {
    let line = send_command_capture(
      session,
      "RCPT TO:<" + recipient.address + ">",
      RcptTo,
      timeouts.command_ms,
    )
    let code = parse_status_code_or_raise(line)
    if code >= 200 && code < 300 {
      accepted.push(recipient)
    } else if code >= 400 && code < 600 {
      rejected.push(recipient)
      rejection_response = format_status_line(line)
    } else {
      raise InvalidResponse(line)
    }
  }
  if accepted.is_empty() {
    return DeliveryOutcome::partial([], rejected, [], rejection_response)
  }
  ignore(
    send_command_expect_status(
      session,
      "DATA",
      354,
      DataCommand,
      timeouts.command_ms,
    ),
  )
  progress.data_started = true
  execute_phase(MessageBody, timeouts.data_ms, async fn() {
    @codec.write_to(writer, message)
    session.write_text("\r\n.\r\n")
  })
  let final_line = read_expect_status(
    session,
    250,
    FinalResponse,
    timeouts.command_ms,
  )
  let response = format_status_line(final_line)
  if rejected.is_empty() {
    DeliveryOutcome::all_accepted(accepted, response~)
  } else {
    DeliveryOutcome::partial(accepted, rejected, [], response)
  }
}

///|
fn should_retry_send(
  retry_policy : SmtpRetryPolicy,
  err : Error,
  progress : SendProgress,
  attempt : Int32,
) -> Bool {
  if progress.data_started {
    return false
  }
  if attempt >= retry_policy.max_retries {
    return false
  }
  match err {
    ConnectionFailure(_, _) => retry_policy.retry_on_connection_failure
    Timeout(_, _) => retry_policy.retry_on_timeout
    ServiceRejected(_, _, _, failure_class) =>
      retry_policy.retry_on_transient_failure &&
      failure_class == FailureClass::Transient
    _ => false
  }
}

///|
async fn[S : SmtpSession] send_command_expect_status(
  session : S,
  command : String,
  expected : Int32,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> String {
  let line = send_command_capture(session, command, phase, timeout_ms)
  let code = parse_status_code_or_raise(line)
  if code != expected {
    raise_status_mismatch(expected, code, line, phase)
  }
  line
}

///|
async fn[S : SmtpSession] send_command_capture(
  session : S,
  command : String,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> String {
  write_line(session, command, phase, timeout_ms)
  read_line(session, phase, timeout_ms)
}

///|
async fn[S : SmtpSession] read_expect_status(
  session : S,
  expected : Int32,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> String {
  let line = read_line(session, phase, timeout_ms)
  let code = parse_status_code_or_raise(line)
  if code != expected {
    raise_status_mismatch(expected, code, line, phase)
  }
  line
}

///|
async fn[S : SmtpSession] write_line(
  session : S,
  command : String,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> Unit {
  write_text(session, command + "\r\n", phase, timeout_ms)
}

///|
async fn[S : SmtpSession] write_text(
  session : S,
  text : String,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> Unit {
  execute_phase(phase, timeout_ms, async fn() { session.write_text(text) })
}

///|
async fn[S : SmtpSession] read_line(
  session : S,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> String {
  execute_phase(phase, timeout_ms, async fn() { session.read_line() })
}

///|
fn raise_status_mismatch(
  expected : Int32,
  actual : Int32,
  line : String,
  phase : SmtpPhase,
) -> Unit raise {
  let response = format_status_line(line)
  if actual >= 400 && actual < 600 {
    raise ServiceRejected(phase, actual, response, classify_smtp_status(actual))
  }
  raise UnexpectedStatus(expected, actual, response)
}

///|
async fn[S : SmtpSession] collect_multiline_response(
  session : S,
  first_line : String,
  phase : SmtpPhase,
  timeout_ms : Int32,
) -> Array[String] {
  let lines : Array[String] = []
  let mut current = first_line
  for ;; {
    lines.push(parse_response_text(current))
    if response_is_final_line(current) {
      return lines
    }
    current = read_line(session, phase, timeout_ms)
  }
}

///|
fn response_is_final_line(line : String) -> Bool {
  line.length() >= 4 && line.code_unit_at(3).to_int() == ' '.to_int()
}

///|
fn parse_response_text(line : String) -> String {
  if line.length() <= 4 {
    ""
  } else {
    line[4:].to_owned()
  }
}

///|
fn parse_status_code_or_raise(line : String) -> Int32 raise {
  match parse_status_code(line) {
    Some(status) => status
    None => raise InvalidResponse(line)
  }
}

///|
fn format_status_line(line : String) -> String {
  line.trim().to_owned()
}

///|
fn parse_positive_int(text : String) -> Int32? {
  if text == "" {
    return None
  }
  let mut value = 0
  for ch in text.iter() {
    let unit = ch.to_int()
    if !is_ascii_digit_unit(unit) {
      return None
    }
    value = value * 10 + digit_value_unit(unit)
  }
  Some(value)
}

///|
fn dot_stuff_message(message : String) -> String {
  let stuffed = message.replace_all(old="\r\n.", new="\r\n..")
  if stuffed.has_prefix(".") {
    "." + stuffed
  } else {
    stuffed
  }
}

///|
fn dot_stuff_chunk(text : String, at_line_start : Bool) -> (String, Bool) {
  let builder = StringBuilder::new()
  let mut line_start = at_line_start
  for ch in text.iter() {
    if line_start && ch == '.' {
      builder.write_char('.')
    }
    builder.write_char(ch)
    if ch == '\n' {
      line_start = true
    } else if ch != '\r' {
      line_start = false
    }
  }
  (builder.to_string(), line_start)
}

///|
fn smtp_tls_trust_to_async(
  trust : SmtpTlsTrust,
) -> @moonbitlang/async/tls.TrustedRoot {
  match trust {
    SystemRoot => @tls.SystemRoot
    InsecureNoVerify => @tls.NoVerification
    CustomPemFile(path) => @tls.CustomPemFile(path)
  }
}
