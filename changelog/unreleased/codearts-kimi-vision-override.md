### English

- CodeArts `kimi-k3.1-pro` no longer rejects image input: the upstream catalog leaves it `supports_images=false`, but live red/blue probes on a cn-north-4 account proved the chat endpoint answers vision questions correctly, so the gateway now applies a measured vision override instead of the stale declaration.

### 中文

- 码道 `kimi-k3.1-pro` 不再拒绝图片输入：上游目录把它标为 `supports_images=false`，但在 cn-north-4 账号上红/蓝对照实测证明聊天端点能正确回答视觉问题，网关现在按实测覆盖表放行，而不再跟随过时的目录声明。
