///|
test "parse smtp multiline and dot-stuffing helpers" {
  assert_true(response_is_final_line("250 localhost"))
  assert_true(!response_is_final_line("250-localhost"))
  assert_true(parse_response_text("250 AUTH PLAIN") == "AUTH PLAIN")
  assert_true(dot_stuff_message("a\r\n.b\r\n..c") == "a\r\n..b\r\n...c")
  let (stuffed, line_start) = dot_stuff_chunk(".hello\r\nworld\r\n.", true)
  assert_true(stuffed == "..hello\r\nworld\r\n..")
  let (_, trailing_line_start) = dot_stuff_chunk(".hello", true)
  assert_true(line_start == false)
  assert_true(trailing_line_start == false)
}

///|
test "parse smtp capabilities and retry boundaries helpers" {
  let capabilities = parse_capabilities([
    "localhost", "PIPELINING", "8BITMIME", "SIZE 4096", "STARTTLS", "AUTH LOGIN PLAIN XOAUTH2",
  ])
  assert_true(capabilities.supports_pipelining)
  assert_true(capabilities.supports_8bitmime)
  assert_true(capabilities.supports_starttls)
  assert_true(capabilities.max_message_size == Some(4096))
  assert_true(capabilities.supports_auth(SmtpAuthMechanism::Plain))
  assert_true(capabilities.supports_auth(SmtpAuthMechanism::Login))
  assert_true(capabilities.supports_auth(SmtpAuthMechanism::Xoauth2))

  let progress = SendProgress::{ data_started: false, }
  let retry_policy = SmtpRetryPolicy::new(max_retries=1, retry_delay_ms=0)
  assert_true(
    should_retry_send(
      retry_policy,
      ConnectionFailure(SmtpPhase::MailFrom, "closed"),
      progress,
      0,
    ),
  )
  progress.data_started = true
  assert_true(
    !should_retry_send(
      retry_policy,
      ConnectionFailure(SmtpPhase::FinalResponse, "closed"),
      progress,
      0,
    ),
  )
}

///|
async test "execute_phase maps timeout into smtp timeout error" {
  try {
    ignore(
      execute_phase(SmtpPhase::MailFrom, 30, async fn() { @async.sleep(100) }),
    )
    abort("expected timeout")
  } catch {
    Timeout(phase, timeout_ms) => {
      assert_true(phase == SmtpPhase::MailFrom)
      assert_true(timeout_ms == 30)
    }
    _ => abort("expected smtp timeout")
  }
}
