# SMTP TLS test fixtures

These self-signed localhost credentials are public test data. The private key
is only for the local regression test server; never use it for a real service.
Tests disable certificate verification to isolate connection cleanup behavior.

`cert.pem` and `key.pem` serve native Linux/macOS and wasm on those hosts.
`cert.pfx` contains the same certificate and key with an empty password for
native Windows and wasm on Windows. The PFX uses SHA-1/3DES for compatibility
with the Windows certificate importer. Tests require no OpenSSL executable.

To regenerate all three fixtures with OpenSSL, run from this directory:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
  -days 36500 -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1'
openssl pkcs12 -export -out cert.pfx -inkey key.pem -in cert.pem \
  -passout pass: -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
```
