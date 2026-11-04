///|
// The dependency exposes its TLS server API specifically for tests.
#cfg(all(not(target="wasm"), not(platform="windows")))
#warnings("-alert_internal")
async fn smtp_test_tls_server(conn : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server_from_pair(
    conn,
    conn,
    private_key_file="transport/testdata/tls/key.pem",
    private_key_type=PEM,
    certificate_file="transport/testdata/tls/cert.pem",
    certificate_type=PEM,
  )
}

///|
#cfg(all(not(target="wasm"), platform="windows"))
#warnings("-alert_internal")
async fn smtp_test_tls_server(conn : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server_from_pair(
    conn,
    conn,
    pfx_file="transport/testdata/tls/cert.pfx",
  )
}

///|
#cfg(target="wasm")
#warnings("-alert_internal")
async fn smtp_test_tls_server(conn : @socket.Tcp) -> @tls.Tls {
  @tls.Tls::server_from_pair(
    conn,
    conn,
    private_key_file="transport/testdata/tls/key.pem",
    private_key_type=PEM,
    certificate_file="transport/testdata/tls/cert.pem",
    certificate_type=PEM,
    pfx_file="transport/testdata/tls/cert.pfx",
  )
}

///|
async fn smtp_test_secure_hello(
  conn : @socket.Tcp,
  security : @transport.SmtpSecurity,
) -> @tls.Tls {
  if security == StartTls {
    conn.write("220 localhost\r\n")
    assert_eq(conn.read_until("\r\n"), Some("EHLO localhost"))
    conn.write("250-localhost\r\n250 STARTTLS\r\n")
    assert_eq(conn.read_until("\r\n"), Some("STARTTLS"))
    conn.write("220 ready for TLS\r\n")
  }
  let tls = smtp_test_tls_server(conn)
  errdefer tls.close()
  if security == Tls {
    tls.write("220 localhost\r\n")
  }
  assert_eq(tls.read_until("\r\n"), Some("EHLO localhost"))
  tls
}

///|
fn smtp_test_secure_transport(
  server : @socket.TcpServer,
  security : @transport.SmtpSecurity,
  reuse_connection~ : Bool = true,
) -> @transport.SmtpTransport {
  @transport.SmtpTransport::new(
    @transport.SmtpConfig::new(
      "127.0.0.1",
      server.addr.port(),
      security~,
      tls_trust=InsecureNoVerify,
      retry_policy=@transport.SmtpRetryPolicy::new(max_retries=0),
      reuse_connection~,
    ),
  )
}

///|
async fn smtp_test_complete_secure_delivery(tls : @tls.Tls) -> Unit {
  assert_eq(tls.read_until("\r\n"), Some("MAIL FROM:<sender@example.com>"))
  tls.write("250 sender ok\r\n")
  assert_eq(tls.read_until("\r\n"), Some("RCPT TO:<reader@example.com>"))
  tls.write("250 recipient ok\r\n")
  assert_eq(tls.read_until("\r\n"), Some("DATA"))
  tls.write("354 send message\r\n")
  let mut saw_subject = false
  for ;; {
    let line = tls.read_until("\r\n")
    if line == Some(".") {
      break
    }
    assert_true(line is Some(_))
    if line == Some("Subject: Greetings") {
      saw_subject = true
    }
  }
  assert_true(saw_subject)
  tls.write("250 queued\r\n")
}

///|
async fn smtp_test_assert_tcp_closed(conn : @socket.Tcp) -> Unit {
  // Read the underlying TCP, not TLS EOF/close_notify. Drain any remaining
  // TLS records, but require a real socket EOF or a specific reset error.
  @async.with_timeout(1_000, () => {
    try {
      while conn.read_some() is Some(_) {
        ()
      }
    } catch {
      @os_error.OSError(code, ..) as err => {
        let is_reset = match @async.platform {
          Linux => code == 104 // ECONNRESET
          MacOS => code == 54 // ECONNRESET
          Windows => code == 10054 || code == 64 // WSAECONNRESET / ERROR_NETNAME_DELETED
        }
        if !is_reset {
          raise err
        }
      }
      err => raise err
    }
  })
}

///|
async fn smtp_test_secure_cancellation(
  security : @transport.SmtpSecurity,
  during_delivery~ : Bool,
) -> Unit {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let transport = smtp_test_secure_transport(server, security)
  defer transport.close()
  let (envelope, _, encoded) = sample_message_native()
  @async.with_timeout(10_000, () => {
    @async.with_task_group() <| group => {
      {
        let sending = group.spawn(() => transport.send(envelope, encoded))
        let (conn, _) = server.accept()
        defer conn.close()
        let tls = smtp_test_secure_hello(conn, security)
        defer tls.close()
        if during_delivery {
          tls.write("250 localhost\r\n")
          assert_eq(
            tls.read_until("\r\n"),
            Some("MAIL FROM:<sender@example.com>"),
          )
        }
        // The command has arrived; leave its reply pending before cancelling.
        sending.cancel()
        try ignore(sending.wait()) catch {
          @async.WaitedTaskAlreadyCancelled => ()
          err => fail("unexpected send error: \{err.to_string()}")
        } noraise {
          _ => fail("expected cancelled send")
        }
        smtp_test_assert_tcp_closed(conn)
      }
      // Reuse the same transport with retries disabled, proving cancellation
      // clears both the in-flight guard and the cached connection.
      let sending = group.spawn(() => transport.send(envelope, encoded))
      let (conn, _) = server.accept()
      defer conn.close()
      let tls = smtp_test_secure_hello(conn, security)
      defer tls.close()
      tls.write("250 localhost\r\n")
      smtp_test_complete_secure_delivery(tls)
      assert_eq(sending.wait().accepted, envelope.rcpt_to)
      transport.close()
      smtp_test_assert_tcp_closed(conn)
    }
  })
}

///|
async fn smtp_test_secure_initialization_failure(
  security : @transport.SmtpSecurity,
) -> Unit {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let transport = smtp_test_secure_transport(server, security)
  defer transport.close()
  let (envelope, _, encoded) = sample_message_native()
  @async.with_timeout(10_000, () => {
    @async.with_task_group() <| group => {
      let sending = group.spawn(
        () => transport.send(envelope, encoded),
        allow_failure=true,
      )
      let (conn, _) = server.accept()
      defer conn.close()
      let tls = smtp_test_secure_hello(conn, security)
      defer tls.close()
      tls.write("not an SMTP response\r\n")
      try ignore(sending.wait()) catch {
        @transport.SmtpClientError::InvalidResponse(_) => ()
        err => fail("unexpected initialization error: \{err.to_string()}")
      } noraise {
        _ => fail("expected initialization failure")
      }
      smtp_test_assert_tcp_closed(conn)
    }
  })
}

///|
async fn smtp_test_secure_close(
  security : @transport.SmtpSecurity,
  reuse_connection~ : Bool,
) -> Unit {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let transport = smtp_test_secure_transport(
    server,
    security,
    reuse_connection~,
  )
  defer transport.close()
  let (envelope, _, encoded) = sample_message_native()
  @async.with_timeout(10_000, () => {
    @async.with_task_group() <| group => {
      if reuse_connection {
        let sending = group.spawn(() => transport.send(envelope, encoded))
        let (conn, _) = server.accept()
        defer conn.close()
        let tls = smtp_test_secure_hello(conn, security)
        defer tls.close()
        tls.write("250 localhost\r\n")
        smtp_test_complete_secure_delivery(tls)
        assert_eq(sending.wait().accepted, envelope.rcpt_to)
        let second = group.spawn(() => transport.send(envelope, encoded))
        smtp_test_complete_secure_delivery(tls)
        assert_eq(second.wait().accepted, envelope.rcpt_to)
        transport.close()
        transport.close()
        smtp_test_assert_tcp_closed(conn)
      } else {
        for _ in 0..<2 {
          let sending = group.spawn(() => transport.send(envelope, encoded))
          let (conn, _) = server.accept()
          defer conn.close()
          let tls = smtp_test_secure_hello(conn, security)
          defer tls.close()
          tls.write("250 localhost\r\n")
          smtp_test_complete_secure_delivery(tls)
          assert_eq(sending.wait().accepted, envelope.rcpt_to)
          // No explicit transport.close(): sending must release this socket.
          smtp_test_assert_tcp_closed(conn)
        }
      }
    }
  })
}

///|
async test "TLS cancellation during EHLO closes TCP and allows delivery after reconnect" {
  smtp_test_secure_cancellation(Tls, during_delivery=false)
}

///|
async test "TLS cancellation during delivery closes TCP and allows delivery after reconnect" {
  smtp_test_secure_cancellation(Tls, during_delivery=true)
}

///|
async test "STARTTLS cancellation during secure EHLO closes TCP and allows delivery after reconnect" {
  smtp_test_secure_cancellation(StartTls, during_delivery=false)
}

///|
async test "STARTTLS cancellation during delivery closes TCP and allows delivery after reconnect" {
  smtp_test_secure_cancellation(StartTls, during_delivery=true)
}

///|
async test "TLS initialization failure after handshake closes TCP" {
  smtp_test_secure_initialization_failure(Tls)
}

///|
async test "STARTTLS initialization failure after handshake closes TCP" {
  smtp_test_secure_initialization_failure(StartTls)
}

///|
async test "TLS reused connection closes TCP on explicit and repeated close" {
  smtp_test_secure_close(Tls, reuse_connection=true)
}

///|
async test "STARTTLS reused connection closes TCP on explicit and repeated close" {
  smtp_test_secure_close(StartTls, reuse_connection=true)
}

///|
async test "TLS delivery without connection reuse closes each TCP connection" {
  smtp_test_secure_close(Tls, reuse_connection=false)
}

///|
async test "STARTTLS delivery without connection reuse closes each TCP connection" {
  smtp_test_secure_close(StartTls, reuse_connection=false)
}
