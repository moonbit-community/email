///|
let smtp_test_port = 4625

///|
enum FakeAuthMode {
  None
  Plain
  Login
  Xoauth2
} derive(Eq, Debug)

///|
struct SmtpTranscript {
  lines : Array[String]
  mut data : String
  mut connection_count : Int32
}

///|
struct ConnectionScenario {
  ehlo_lines : Array[String]
  auth_mode : FakeAuthMode
  reject_second_recipient : Bool
  greet_delay_ms : Int32
  mail_from_delay_ms : Int32
  mail_from_seen : @async.Semaphore?
  close_before_mail_from_response : Bool
  close_after_data_command : Bool
}

///|
fn[T, E] guard_ok_native(result : Result[T, E]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("expected Ok result")
  }
}

///|
fn sample_message_native() -> (@core.Envelope, @core.Message, String) {
  let from = guard_ok_native(@core.Mailbox::address_only("sender@example.com"))
  let to = guard_ok_native(@core.Mailbox::address_only("reader@example.com"))
  let message = guard_ok_native(
    @core.Message::new(
      from,
      [to],
      [],
      [],
      "Greetings",
      @core.Body::plain_text("Hello"),
      [],
    ),
  )
  let envelope = guard_ok_native(@core.Envelope::new(from, [to]))
  let encoded = @codec.to_rfc5322(message)
  (envelope, message, encoded)
}

///|
fn SmtpTranscript::new() -> SmtpTranscript {
  { lines: [], data: "", connection_count: 0, }
}

///|
fn scenario_with_auth(auth_mode : FakeAuthMode) -> ConnectionScenario {
  let ehlo_lines = match auth_mode {
    None => ["localhost"]
    Plain => ["localhost", "AUTH PLAIN"]
    Login => ["localhost", "AUTH LOGIN PLAIN XOAUTH2"]
    Xoauth2 => ["localhost", "AUTH XOAUTH2 PLAIN"]
  }
  {
    ehlo_lines,
    auth_mode,
    reject_second_recipient: false,
    greet_delay_ms: 0,
    mail_from_delay_ms: 0,
    mail_from_seen: None,
    close_before_mail_from_response: false,
    close_after_data_command: false,
  }
}

///|
fn guard_some_capabilities(
  value : @transport.SmtpCapabilities?,
) -> @transport.SmtpCapabilities {
  match value {
    Some(capabilities) => capabilities
    None => abort("expected negotiated capabilities")
  }
}

///|
fn count_prefix(lines : Array[String], prefix : String) -> Int32 {
  let mut count = 0
  for line in lines {
    if line.has_prefix(prefix) {
      count += 1
    }
  }
  count
}

///|
async fn write_multiline_response(
  conn : @socket.Tcp,
  lines : Array[String],
) -> Unit {
  if lines.is_empty() {
    conn.write("250 localhost\r\n")
    return
  }
  for index, line in lines {
    let separator = if index + 1 == lines.length() { " " } else { "-" }
    conn.write("250" + separator + line + "\r\n")
  }
}

///|
async fn run_fake_smtp_server(
  port : Int32,
  transcript : SmtpTranscript,
  scenarios : Array[ConnectionScenario],
) -> Unit {
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  run_fake_smtp_server_on(server, transcript, scenarios)
}

///|
async fn run_fake_smtp_server_parallel(
  port : Int32,
  transcript : SmtpTranscript,
  scenarios : Array[ConnectionScenario],
) -> Unit {
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  run_fake_smtp_server_parallel_on(server, transcript, scenarios)
}

///|
async fn run_fake_smtp_server_on(
  server : @socket.TcpServer,
  transcript : SmtpTranscript,
  scenarios : Array[ConnectionScenario],
) -> Unit {
  defer server.close()
  for scenario in scenarios {
    match @async.with_timeout_opt(500, () => server.accept()) {
      Some((conn, _)) => {
        transcript.connection_count += 1
        handle_fake_smtp_connection(conn, transcript, scenario) catch {
          _ => ()
        }
        conn.close()
      }
      None => return
    }
  }
}

///|
async fn run_fake_smtp_server_parallel_on(
  server : @socket.TcpServer,
  transcript : SmtpTranscript,
  scenarios : Array[ConnectionScenario],
) -> Unit {
  defer server.close()
  @async.with_task_group() <| group => {
    for scenario in scenarios {
      match @async.with_timeout_opt(500, () => server.accept()) {
        Some((conn, _)) => {
          transcript.connection_count += 1
          group.spawn_bg(async fn() {
            defer conn.close()
            handle_fake_smtp_connection(conn, transcript, scenario) catch {
              _ => ()
            }
          })
        }
        None => return
      }
    }
  }
}

///|
async fn handle_fake_smtp_connection(
  conn : @socket.Tcp,
  transcript : SmtpTranscript,
  scenario : ConnectionScenario,
) -> Unit {
  if scenario.greet_delay_ms > 0 {
    @async.sleep(scenario.greet_delay_ms)
  }
  conn.write("220 moonbit test smtp\r\n")
  let mut rcpt_index = 0
  let mut in_data = false
  let mut login_stage = 0
  for ;; {
    match conn.read_until("\r\n") {
      None => return
      Some(line) => {
        if in_data {
          if line == "." {
            in_data = false
            conn.write("250 queued\r\n")
          } else {
            transcript.data = transcript.data + line + "\n"
          }
          continue
        }
        transcript.lines.push(line)
        if login_stage == 1 {
          login_stage = 2
          conn.write("334 UGFzc3dvcmQ6\r\n")
          continue
        }
        if login_stage == 2 {
          login_stage = 0
          conn.write("235 authenticated\r\n")
          continue
        }
        if line.has_prefix("EHLO ") {
          write_multiline_response(conn, scenario.ehlo_lines)
        } else if line.has_prefix("HELO ") {
          conn.write("250 localhost\r\n")
        } else if line.has_prefix("AUTH PLAIN ") && scenario.auth_mode == Plain {
          conn.write("235 authenticated\r\n")
        } else if line == "AUTH LOGIN" && scenario.auth_mode == Login {
          login_stage = 1
          conn.write("334 VXNlcm5hbWU6\r\n")
        } else if line.has_prefix("AUTH XOAUTH2 ") &&
          scenario.auth_mode == Xoauth2 {
          conn.write("235 authenticated\r\n")
        } else if line.has_prefix("AUTH ") {
          conn.write("535 authentication failed\r\n")
        } else if line.has_prefix("MAIL FROM:") {
          if scenario.close_before_mail_from_response {
            return
          }
          match scenario.mail_from_seen {
            Some(semaphore) => semaphore.release()
            None => ()
          }
          if scenario.mail_from_delay_ms > 0 {
            @async.sleep(scenario.mail_from_delay_ms)
          }
          conn.write("250 sender ok\r\n")
        } else if line.has_prefix("RCPT TO:") {
          rcpt_index += 1
          if scenario.reject_second_recipient && rcpt_index == 2 {
            conn.write("550 rejected\r\n")
          } else {
            conn.write("250 recipient ok\r\n")
          }
        } else if line == "DATA" {
          conn.write("354 end with <CRLF>.<CRLF>\r\n")
          if scenario.close_after_data_command {
            return
          }
          in_data = true
        } else if line == "QUIT" {
          conn.write("221 bye\r\n")
          return
        } else {
          conn.write("500 unsupported\r\n")
        }
      }
    }
  }
}

///|
async test "real smtp transport sends a message over tcp" {
  let transcript = SmtpTranscript::new()
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port,
    auth=Plain("user", "pass"),
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port, transcript, [
        scenario_with_auth(Plain),
      ])
    })
    @async.sleep(20)
    let outcome = transport.send(envelope, encoded)
    assert_true(outcome.accepted == envelope.rcpt_to)
    transport.close()
  }
  assert_true(transcript.connection_count == 1)
  assert_true(transcript.lines[0] == "EHLO localhost")
  assert_true(transcript.lines[1].has_prefix("AUTH PLAIN "))
  assert_true(transcript.lines[2] == "MAIL FROM:<sender@example.com>")
  assert_true(transcript.lines[3] == "RCPT TO:<reader@example.com>")
  assert_true(transcript.lines[4] == "DATA")
  assert_true(transcript.data.contains("Subject: Greetings"))
  assert_true(transcript.data.contains("Hello"))
}

///|
async test "real smtp transport reports partial recipient rejection" {
  let transcript = SmtpTranscript::new()
  let from = guard_ok_native(@core.Mailbox::address_only("sender@example.com"))
  let accepted = guard_ok_native(@core.Mailbox::address_only("ok@example.com"))
  let rejected = guard_ok_native(@core.Mailbox::address_only("no@example.com"))
  let envelope = guard_ok_native(
    @core.Envelope::new(from, [accepted, rejected]),
  )
  let encoded = "Subject: hi\r\n\r\nbody"
  let config = @transport.SmtpConfig::new("127.0.0.1", smtp_test_port + 1)
  let transport = @transport.SmtpTransport::new(config)
  let scenario = { ..scenario_with_auth(None), reject_second_recipient: true, }
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 1, transcript, [scenario])
    })
    @async.sleep(20)
    let outcome = transport.send(envelope, encoded)
    assert_true(outcome.accepted == [accepted])
    assert_true(outcome.rejected == [rejected])
    assert_true(outcome.failure_class == Some(Permanent))
    transport.close()
  }
}

///|
async test "real smtp transport reuses an authenticated connection" {
  let transcript = SmtpTranscript::new()
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 2,
    auth=Plain("user", "pass"),
    reuse_connection=true,
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 2, transcript, [
        scenario_with_auth(Plain),
      ])
    })
    @async.sleep(20)
    ignore(transport.send(envelope, encoded))
    ignore(transport.send(envelope, encoded))
    transport.close()
  }
  assert_true(transcript.connection_count == 1)
  assert_true(count_prefix(transcript.lines, "EHLO ") == 1)
  assert_true(count_prefix(transcript.lines, "AUTH PLAIN ") == 1)
  assert_true(count_prefix(transcript.lines, "MAIL FROM:") == 2)
  assert_true(count_prefix(transcript.lines, "DATA") == 2)
}

///|
async test "real smtp transport models capabilities and supports login auth" {
  let transcript = SmtpTranscript::new()
  let scenario = {
    ehlo_lines: [
      "localhost", "PIPELINING", "8BITMIME", "SIZE 12345", "STARTTLS", "AUTH LOGIN PLAIN XOAUTH2",
    ],
    auth_mode: Login,
    reject_second_recipient: false,
    greet_delay_ms: 0,
    mail_from_delay_ms: 0,
    mail_from_seen: None,
    close_before_mail_from_response: false,
    close_after_data_command: false,
  }
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 3,
    auth=Login("user", "pass"),
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 3, transcript, [scenario])
    })
    @async.sleep(20)
    ignore(transport.send(envelope, encoded))
    transport.close()
  }
  let capabilities = guard_some_capabilities(transport.capabilities())
  assert_true(capabilities.supports_pipelining)
  assert_true(capabilities.supports_8bitmime)
  assert_true(capabilities.supports_starttls)
  assert_true(capabilities.max_message_size == Some(12345))
  assert_true(capabilities.supports_auth(Plain))
  assert_true(capabilities.supports_auth(Login))
  assert_true(capabilities.supports_auth(Xoauth2))
  assert_true(transcript.lines[1] == "AUTH LOGIN")
  assert_true(transcript.lines[2] == @base64.encode(@utf8.encode("user")))
  assert_true(transcript.lines[3] == @base64.encode(@utf8.encode("pass")))
}

///|
async test "real smtp transport supports xoauth2 auth" {
  let transcript = SmtpTranscript::new()
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 4,
    auth=Xoauth2("user@example.com", "oauth-token"),
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 4, transcript, [
        scenario_with_auth(Xoauth2),
      ])
    })
    @async.sleep(20)
    ignore(transport.send(envelope, encoded))
    transport.close()
  }
  assert_true(transcript.lines[1].has_prefix("AUTH XOAUTH2 "))
}

///|
async test "real smtp transport rejects concurrent send on the same instance" {
  let transcript = SmtpTranscript::new()
  let mail_from_seen = @async.Semaphore(1, initial_value=0)
  let scenario = {
    ..scenario_with_auth(Plain),
    mail_from_delay_ms: 200,
    mail_from_seen: Some(mail_from_seen),
  }
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 5,
    auth=Plain("user", "pass"),
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 5, transcript, [scenario])
    })
    @async.sleep(20)
    let first_send = root.spawn(() => transport.send(envelope, encoded))
    ignore(@async.with_timeout(500, () => mail_from_seen.acquire()))
    try {
      ignore(transport.send(envelope, encoded))
      abort("expected BusyTransport")
    } catch {
      @transport.SmtpClientError::BusyTransport => ()
      _ => abort("expected BusyTransport")
    }
    let outcome = first_send.wait()
    assert_true(outcome.accepted == envelope.rcpt_to)
    transport.close()
  }
  assert_true(transcript.connection_count == 1)
  assert_true(count_prefix(transcript.lines, "MAIL FROM:") == 1)
}

///|
async test "independent smtp transports can progress concurrently" {
  let transcript = SmtpTranscript::new()
  let first_mail_from_seen = @async.Semaphore(1, initial_value=0)
  let second_mail_from_seen = @async.Semaphore(1, initial_value=0)
  let scenarios = [
    {
      ..scenario_with_auth(Plain),
      mail_from_delay_ms: 200,
      mail_from_seen: Some(first_mail_from_seen),
    },
    {
      ..scenario_with_auth(Plain),
      mail_from_delay_ms: 200,
      mail_from_seen: Some(second_mail_from_seen),
    },
  ]
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 8,
    auth=Plain("user", "pass"),
  )
  let transport1 = @transport.SmtpTransport::new(config)
  let transport2 = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server_parallel(smtp_test_port + 8, transcript, scenarios)
    })
    @async.sleep(20)
    let send1 = root.spawn(() => transport1.send(envelope, encoded))
    let send2 = root.spawn(() => transport2.send(envelope, encoded))
    ignore(@async.with_timeout(500, () => first_mail_from_seen.acquire()))
    ignore(@async.with_timeout(500, () => second_mail_from_seen.acquire()))
    let outcome1 = send1.wait()
    let outcome2 = send2.wait()
    assert_true(outcome1.accepted == envelope.rcpt_to)
    assert_true(outcome2.accepted == envelope.rcpt_to)
    transport1.close()
    transport2.close()
  }
  assert_true(transcript.connection_count == 2)
  assert_true(count_prefix(transcript.lines, "MAIL FROM:") == 2)
}

///|
async test "real smtp transport retries connection failures before DATA" {
  let transcript = SmtpTranscript::new()
  let first = {
    ..scenario_with_auth(None),
    close_before_mail_from_response: true,
  }
  let second = scenario_with_auth(None)
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 6,
    retry_policy=@transport.SmtpRetryPolicy::new(
      max_retries=1,
      retry_delay_ms=0,
    ),
    reuse_connection=false,
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 6, transcript, [first, second])
    })
    @async.sleep(20)
    let outcome = transport.send(envelope, encoded)
    assert_true(outcome.accepted == envelope.rcpt_to)
    transport.close()
  }
  assert_true(transcript.connection_count == 2)
}

///|
async test "real smtp transport does not retry once DATA has started" {
  let transcript = SmtpTranscript::new()
  let first = { ..scenario_with_auth(None), close_after_data_command: true, }
  let second = scenario_with_auth(None)
  let config = @transport.SmtpConfig::new(
    "127.0.0.1",
    smtp_test_port + 7,
    retry_policy=@transport.SmtpRetryPolicy::new(
      max_retries=1,
      retry_delay_ms=0,
    ),
    reuse_connection=false,
  )
  let transport = @transport.SmtpTransport::new(config)
  let (envelope, _, encoded) = sample_message_native()
  @async.with_task_group() <| root => {
    root.spawn_bg(async fn() {
      run_fake_smtp_server(smtp_test_port + 7, transcript, [first, second])
    })
    @async.sleep(20)
    try {
      ignore(transport.send(envelope, encoded))
      abort("expected connection failure after DATA")
    } catch {
      @transport.SmtpClientError::ProtocolError(_) => ()
      @transport.SmtpClientError::ConnectionFailure(_, _) => ()
      _ => abort("unexpected error")
    }
    transport.close()
  }
  assert_true(transcript.connection_count == 1)
}

///|
async test "real smtp transport closes cancelled connections and can reconnect" {
  let port = smtp_test_port + 9
  let server = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  defer server.close()
  let transport = @transport.SmtpTransport::new(
    @transport.SmtpConfig::new(
      "127.0.0.1",
      port,
      retry_policy=@transport.SmtpRetryPolicy::new(max_retries=0),
    ),
  )
  defer transport.close()
  let (envelope, _, encoded) = sample_message_native()
  @async.with_timeout(2_000, () => {
    @async.with_task_group() <| group => {
      // Cancel during hello, then during delivery, and reconnect after both.
      for begin_delivery in [false, true, false] {
        let sending = group.spawn(() => transport.send(envelope, encoded))
        let (conn, _) = server.accept()
        defer conn.close()
        conn.write("220 localhost\r\n")
        assert_eq(conn.read_until("\r\n"), Some("EHLO localhost"))
        if begin_delivery {
          conn.write("250 localhost\r\n")
          assert_eq(
            conn.read_until("\r\n"),
            Some("MAIL FROM:<sender@example.com>"),
          )
        }
        sending.cancel()
        try ignore(sending.wait()) catch {
          @async.WaitedTaskAlreadyCancelled => ()
          err => fail("unexpected send error: \{err.to_string()}")
        } noraise {
          _ => fail("expected cancelled send")
        }
        assert_eq(conn.read_until("\r\n"), None)
      }
    }
  })
}
