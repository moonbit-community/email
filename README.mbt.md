# username/email

MoonBit email library workspace.

架构设计文档见：

- [docs/architecture.md](docs/architecture.md)

当前采用的模块划分为：

- `core`
- `codec`
- `transport`
- `ext`

当前采用测试先行流程：

- 先为每个包定义空的 `_test.mbt` 和 `_wbtest.mbt`
- 先固定测试 case，再逐步填充实现
