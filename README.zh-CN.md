# nexacodes/email

[English](README.mbt.md) | [简体中文](README.zh-CN.md)

`nexacodes/email` 是一个面向 MoonBit 的邮件库，顶层提供了一组偏易用的 facade API，覆盖最常见的邮件场景：

- 组装纯文本、HTML 或 multipart 邮件
- 生成 SMTP envelope
- 编码为 RFC 5322 / MIME
- 用较少步骤通过 SMTP 发送

如果你只关心公共接口，直接从顶层包开始使用即可；`core`、`codec`、`transport` 这些下层包可以先当作实现细节。

## Facade API

顶层 facade 目前主要暴露：

- `compose_plain_text`
- `compose_html`
- `compose_mixed`
- `envelope_for`
- `send_plain_text`
- `send_html`
- `send_mixed`
- `to_rfc5322`
- `parse_rfc5322`
- `render_to_rfc5322`

同时也重导出了常见调用点需要的类型，例如：

- `Mailbox`
- `Body`
- `Message`
- `Envelope`
- `SmtpConfig`
- `SmtpTransport`
- `FakeTransport`
- `FileTransport`

## 快速开始

如果你想走“先组装，再编码/发送”的低样板路径：

```moonbit nocheck
// 假设你已经导入了 `nexacodes/email` 顶层 facade 包

///|
let from = Mailbox::new("sender@example.com", Some("Sender")) |> must_ok

///|
let to = Mailbox::address_only("reader@example.com") |> must_ok

///|
let message = compose_plain_text(from, [to], "Greetings", "Hello from MoonBit!")
  |> must_ok

///|
let envelope = envelope_for(message) |> must_ok

///|
let encoded = to_rfc5322(message)
```

如果你想直接一步走 SMTP 发送：

```moonbit nocheck
///|
let config = SmtpConfig::new(
  "smtp.example.com",
  465,
  security=SmtpSecurity::Tls,
  auth=SmtpAuth::Plain("sender@example.com", "app-password"),
)

///|
let outcome = send_plain_text(
    config,
    from,
    [to],
    "Greetings",
    "Hello from MoonBit!",
  )
  |> must_ok
```

这里的 `send_plain_text`、`send_html`、`send_mixed` 在“消息构造失败”时会返回 `Result[..., ValidationError]`；真正的 SMTP 协议或连接错误仍然属于 transport 层的职责。

## HTML 与附件

如果你要构造带附件的 multipart 邮件：

```moonbit nocheck
///|
let attachment = Body::attachment_file(
    "report.pdf",
    "/path/to/report.pdf",
    content_type=infer_content_type("report.pdf"),
  )
  |> must_ok

///|
let message = compose_mixed(from, [to], "Monthly report", [
    Body::plain_text("See attachment."),
    attachment,
  ])
  |> must_ok
```

如果希望一步发送这种结构的消息，可以直接使用 `send_mixed`。

## 测试与本地检查

做单元测试时，优先用 `FakeTransport`：

```moonbit nocheck
let transport = FakeTransport::new()
let outcome = transport.send_message(envelope, message) |> must_ok
```

如果你想把邮件落成 `.eml` 文件做本地检查，可以使用 `FileTransport`。

如果你需要真实网络投递，则使用 `SmtpTransport`。

## 命令行示例

仓库里自带了一个可运行示例，位于 [cmd/main/main.mbt](cmd/main/main.mbt)。

它当前演示了：

- 通过 QQ SMTP over TLS 发送
- 重复传入 `--attachment`
- 用 `SmtpTransport` 发送 file-backed attachment

```bash
moon run cmd/main -- \
  --sender your-account@example.com \
  --recipient someone@example.com \
  --auth-code your-auth-code \
  --subject "MoonBit email test" \
  --body "Hello from nexacodes/email"
```

## 当前状态

目前已经具备：

- 顶层 facade 的 compose / send helpers
- MIME 渲染与解析
- 内存附件和文件附件
- fake、file、real SMTP 三类主要 transport

仍在演进中的部分：

- `ext` 下更高层的扩展能力
- provider-specific 集成

如果你想看更底层的模块边界和设计原因，可以继续读 [docs/architecture.md](docs/architecture.md)。

## 开发

```bash
moon check
moon test
moon info
moon fmt
```
