///|
/// Inspired by plugin and middleware patterns from mature mail ecosystems.
test "middleware can observe and wrap the send pipeline" {
  // TODO: define extension hooks around compose, encode, and send steps.
}

///|
test "dkim signing decorates encoded output without mutating message semantics" {
  // TODO: define signing behavior as an opt-in extension.
}

///|
test "failover transport retries the next backend after transient failure" {
  // TODO: define composite transport behavior for high-availability sending.
}

///|
test "round-robin transport rotates fairly across backends" {
  // TODO: define backend selection behavior for composite transports.
}

///|
test "template rendering feeds message builders before encoding" {
  // TODO: define extension boundaries between rendering and core message data.
}

///|
test "metrics and tracing hooks observe one delivery attempt once" {
  // TODO: define non-invasive observability hooks.
}
