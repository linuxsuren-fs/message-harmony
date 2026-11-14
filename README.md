# message-harmony

[message-hub](https://github.com/LinuxSuRen/message-hub) 的鸿蒙（HarmonyOS / ArkTS）客户端。

message-hub 是一个自托管的消息接收与转发中间件（Go + Vue）。本客户端运行在鸿蒙手机上，用于：

- 配置自建服务端地址
- 邮箱 + 密码登录（会话 Cookie 有效期 12 小时）
- 实时订阅（SSE）本人租户与公开消息
- 分页列表展示，支持 全部 / 本租户 / 公开 三种范围筛选

零第三方依赖：仅使用系统 API（`@ohos.net.http`、`@ohos.data.preferences`、ArkUI），`oh-package.json5` 的 dependencies 为空。

## 功能

- **登录页**：服务器地址 / 邮箱 / 密码；地址与登录态通过 Preferences 持久化，冷启动自动恢复未过期会话
- **消息页**：
  - 顶部 全部 / 本租户 / 公开 分段筛选 + 手动刷新，列表触底按游标加载更多
  - 消息卡片：标题、正文摘要、topic、级别标签（info 蓝 / warning 橙 / error 红）、公开标记、本地化时间
  - SSE 实时推送：新消息去重后插入列表顶部，状态条实时显示连接状态
  - 右上菜单：退出登录（清会话回登录页）
- **多语言**：base（zh）中文为主，`en_US` 英文齐备
- 会话过期（401）自动清理并回到登录页

## 快速开始

1. 准备一个运行中的 message-hub 服务端（或任何实现了下方 API 的服务）
2. 安装应用（二选一）：
   - **DevEco Studio 连真机运行（推荐）**：用 DevEco Studio 打开本工程，连接鸿蒙真机，直接 Run
   - **从 Releases 下载 hap**：注意 Release 流水线产出的 HAP **未签名**，无法直接安装；请用 DevEco Studio 的签名工具（File → Project Structure → Signing Configs）自行签名后再通过 hdc 安装
3. 打开应用：填写服务器地址（如 `https://message.example.com`）→ 输入邮箱密码登录 → 进入消息列表
4. 服务端产生新消息时，列表顶部会实时出现（约 1 秒内），无需手动刷新

## 本地构建

环境要求：DevEco Studio 5.0+ 或鸿蒙命令行工具（`DEVECO_SDK_HOME` 指向本机 SDK，`hvigorw` 在 PATH 中）。

- **DevEco Studio**：打开工程根目录，直接 Build → Build Hap(s)/APP(s)
- **命令行**：

  ```bash
  hvigorw --mode module -p module=entry@default -p product=default assembleHap --no-daemon
  ```

  产物位于 `entry/build/default/outputs/default/`。Release 包：`-p product=default -p buildMode=release assembleHap --no-daemon`。

  注：当前工具链（hvigor 6.x）中 `assembleHap` 是模块级任务，需 `--mode module` 指定模块；`buildMode` 取值需与 `build-profile.json5` 中 `buildModeSet` 声明的小写 `release` 一致。

工程内也保留了 `hvigorw` / `hvigorw.bat` / `hvigorw.js` 包装器：命令行工具已引导过本工程（存在 `.hvigor/` 工作区）后，可直接 `./hvigorw` 调用；全新环境建议优先使用 PATH 中的 `hvigorw`。

CI（GitHub Actions）会在 ubuntu 上自动安装鸿蒙 SDK 并构建 debug HAP（见 `.github/workflows/ci.yml`）；打 `v*` 标签时自动构建并发布未签名的 release HAP。

## 工作原理

- **登录与 Cookie**：`POST /api/v1/auth/login` 成功后从响应头 `Set-Cookie` 抓取 `mh_session`，保存在内存与 Preferences 中，后续 REST 与 SSE 请求手动携带 `Cookie` 头；SSE 流响应头若带回新 Cookie 也会滚动更新（会话续期）
- **SSE over http dataReceive**：`http.createHttp()` + `requestInStream` 建立长连接；`on('dataReceive')` 把到达的 `ArrayBuffer` 追加进字节缓冲，按 `\n\n`（兼容 `\r\n\r\n`）分帧，逐行解析 `event:` / `data:` 字段；`heartbeat` 帧忽略，`message` 帧解析为消息对象回调页面
- **断线重连**：指数退避 1s → 2s → 4s … 上限 60s；连接成功后退避清零。另有心跳看门狗：约 20 秒一次心跳，超过 75 秒无任何数据则强制断开重连
- **资源释放**：消息页 `aboutToDisappear` 时销毁 SSE 连接与全部定时器

## 服务端 API

客户端按以下契约访问（`{base}` 为配置的服务器地址）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/health` | 健康检查 `{"status":"ok","version":"0.0.1"}` |
| POST | `/api/v1/auth/login` | `{"email","password"}` → 用户信息 + `Set-Cookie: mh_session=...`（12h） |
| GET | `/api/v1/messages?limit=50&cursor=&scope=all\|own\|public` | 分页消息（id 降序，`next_cursor` 为 null 表示没有更多） |
| GET | `/api/v1/stream` | SSE 流：`retry: 5000`；`event: message` + 消息 JSON；`event: heartbeat`（约 20s 一次） |

所有响应为 JSON；非 2xx 响应体为 `{"error":"人类可读信息"}`，客户端会解析该字段并用 Toast 展示。

## 协议

[MIT](./LICENSE)（沿用上游 LICENSE）。
