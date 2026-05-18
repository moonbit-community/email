# Email Library Architecture

本文档定义 MoonBit `email` 库的目标模块划分、职责边界和依赖方向。

目标不是机械移植某个现有库，而是吸收成熟设计后，在 MoonBit 中构建一套可维护、可扩展、可测试的邮件发送基础设施。

## Design Goals

- 把“邮件内容建模”和“邮件投递”严格拆开。
- 把高层易用 API 和底层可控 API 同时保留。
- 让 MIME 编解码可独立演进，不与 SMTP 实现耦合。
- 让扩展能力以外挂形式存在，避免污染核心模型。
- 优先支持可靠的测试方式，例如 `.eml` 输出、内存传输和 fake transport。

## Module Map

建议拆分为四个核心模块：

- `core`
- `codec`
- `transport`
- `ext`

推荐的依赖方向如下：

```text
core
  ^
  |
codec
  ^
  |
ext

core
  ^
  |
transport
  ^
  |
ext
```

约束如下：

- `core` 不依赖其他 email 模块。
- `codec` 只依赖 `core`。
- `transport` 只依赖 `core`。
- `ext` 可以依赖前三者，但前三者不能反向依赖 `ext`。

## Module Responsibilities

### `core`

`core` 是纯领域模型层，负责表达“一封邮件是什么”。

负责内容：

- 地址模型：`Address`、`Mailbox`、显示名、地址列表。
- SMTP envelope 模型：`reverse-path`、`forward-path`、收件人集合。
- 消息模型：`Message`、`Header`、正文结构、multipart 树。
- MIME 相关的抽象数据：`ContentType`、`ContentDisposition`、`ContentId`、`Charset`、传输编码枚举。
- 构建期校验：地址合法性、必填字段、multipart 结构合法性、附件和 inline 资源的语义约束。
- 错误模型：构造失败、校验失败、缺失字段、冲突配置。

明确不负责：

- MIME 字节流生成与解析。
- SMTP/LMTP/HTTP provider 等网络投递。
- TLS、认证、重试、连接池。
- DKIM 签名、模板渲染、自动重试等增强能力。

设计要求：

- 必须显式区分 message headers 和 SMTP envelope，不能混为一个对象。
- 数据结构尽量保持无副作用，便于测试、比较、序列化和重用。
- 提供高层 builder，也保留足够低层的结构体/构造器，方便高级用户直接操控。

### `codec`

`codec` 负责 `core` 与 RFC 5322/MIME 字节表示之间的转换。

负责内容：

- 邮件头序列化与解析。
- header folding / unfolding。
- MIME multipart 边界生成。
- `quoted-printable`、`base64`、7bit/8bit 等传输编码。
- `encoded-word`、参数编码等非 ASCII 头字段处理。
- 文本正文和二进制附件的序列化策略。
- `.eml` 读写支持。
- parser / serializer policy，例如换行风格、最大行长、严格/宽松模式。

明确不负责：

- 网络传输与 SMTP 会话管理。
- 认证、TLS、连接池、重试。
- 高层业务功能，例如模板系统或批量投递编排。

设计要求：

- 输入是 `core` 的消息模型，输出是可发送的字节流或流式 writer 接口。
- parser 和 serializer 要尽量共用同一套核心语义，避免读写行为分叉。
- 对大附件优先支持流式处理，避免无谓地把整封邮件一次性拼成大字符串。
- 严格模式与兼容模式要分开，便于对规范性和兼容性分别调优。

### `transport`

`transport` 负责“如何把已经准备好的邮件发出去”。

负责内容：

- 统一 transport 抽象，例如 `send(envelope, message)`。
- SMTP client 实现。
- 连接建立、EHLO/HELO、扩展协商。
- STARTTLS/TLS 策略。
- AUTH 机制协商与认证。
- 投递结果模型，例如 accepted / rejected / response。
- 连接复用、keep-alive、超时、并发安全策略。
- 测试 transport、内存 transport、文件 transport。

明确不负责：

- 修改消息语义。
- 决定 MIME 结构。
- 负责模板渲染或业务重试编排。
- 把 SMTP server 的兼容修复散落到 `core`。

设计要求：

- transport 输入应同时拿到 envelope 和已编码消息，不能依赖从消息头反推 SMTP 收件人。
- 结果类型不能只返回 `Bool`，至少要能表达成功、部分成功、失败原因和服务端响应。
- 抽象层先稳定，再往下挂 SMTP、sendmail 或其他 provider。
- 测试 transport 要先于真实网络 transport 落地，保证上层可测试。

### `ext`

`ext` 负责可选增强能力，不进入最小核心闭包。

负责内容：

- middleware / plugin 机制。
- DKIM 签名、后续可扩展到 S/MIME、PGP。
- template 渲染、变量注入。
- failover、round-robin、retry policy、批量发送编排。
- tracing、logging、metrics。
- provider-specific 适配器，例如某些 HTTP 邮件服务。
- 调试辅助工具，例如 message dump、delivery recorder。

明确不负责：

- 成为所有基础类型的定义处。
- 反向侵入 `core` 的数据模型。
- 让 `core` 或 `transport` 为单个扩展特性背负不必要复杂度。

设计要求：

- 默认可选，不应让核心用户为高级功能付出额外复杂度。
- 尽量通过组合、包装、middleware 和 adapter 扩展，而不是修改 core API。
- 对外暴露的扩展点要稳定、颗粒度清晰。

## Cross-Cutting Rules

以下规则适用于所有模块：

- 邮件头与 envelope 分离：`From/To/Cc/Bcc` 属于 message，SMTP `MAIL FROM/RCPT TO` 属于 envelope。
- 数据模型优先：先定义稳定 AST 和结果类型，再写具体协议代码。
- 可测试优先：每一层都应有不依赖真实 SMTP 的测试入口。
- 流式优先：附件和大消息避免无必要的整块复制。
- 严格错误语义：区分构造错误、编码错误、协议错误和服务端拒收错误。

## Test-First Workflow

每个包在实现之前，先定义测试用例，再补实现。

约束如下：

- 每个包先创建空的 blackbox 测试文件 `_test.mbt`。
- 每个包先创建空的 whitebox 测试文件 `_wbtest.mbt`。
- 测试先固定 case 名称和行为边界，暂不调用未实现 API。
- 等 case 清单稳定后，再逐步填充实现和断言。

测试 case 的能力面可以参考成熟库的常见覆盖范围，例如：

- Nodemailer：message configuration、attachments、alternatives、embedded images、pooled SMTP。
- lettre：message builder、multipart 组合、attachment、stub transport。
- MimeKit：BodyBuilder、text/html body、linked resources、attachments。
- Angus Mail / Python `smtplib`：envelope 语义、部分收件人成功、投递结果建模。

## Public API Strategy

建议对外提供两类 API：

### High-Level API

面向大多数用户，提供：

- 消息 builder。
- 默认编码策略。
- 一步发送或少量步骤发送。
- 常见 transport 的简单构造方式。

### Low-Level API

面向高级用户，提供：

- 手工构造 envelope。
- 手工控制 header/body/multipart。
- 直接访问 MIME 编码器。
- raw send / pre-encoded send。
- transport 生命周期控制。

这两类 API 应构建在同一套底层模块之上，而不是分别维护两套逻辑。

## Suggested Package Layout

如果后续按目录拆包，建议采用：

```text
/core
/codec
/transport
/ext
/cmd
```

推荐各目录独立 `moon.pkg`，并保留一个顶层门面包用于重导出常用能力。

顶层门面包建议只做两件事：

- 重导出稳定且高频的公共 API。
- 提供最常用的组合式 helper。

顶层门面包不应承载复杂实现。

## Recommended Implementation Order

为了降低风险，建议实现顺序如下：

1. `core`
2. `codec`
3. `transport` 中的 fake/file transport
4. `transport` 中的 SMTP transport
5. `ext`

这样可以先把消息模型、编码模型和测试面稳定下来，再接真实 SMTP。

## Initial Scope

第一阶段建议最小闭包如下：

- 纯文本邮件。
- `text/plain + text/html` multipart alternative。
- 附件和 inline 资源。
- SMTP envelope。
- `.eml` 序列化。
- fake/file transport。
- 基础 SMTP 发送。

第二阶段再考虑：

- parser 宽松兼容模式。
- 连接池。
- DKIM。
- failover / round-robin。
- provider adapter。

## Non-Goals For The First Version

第一版不建议一开始就做：

- 完整邮件客户端能力。
- IMAP/POP3。
- 全量加密签名体系。
- 复杂模板引擎。
- 过早支持太多 provider-specific 特性。

这些能力可以在 `ext` 或后续模块中渐进演化。
