# Codex Usage

Codex Usage 是一个 macOS 菜单栏工具，用来在不打开 Codex 主窗口的情况下查看两件事：

- Codex 额度还剩多少。
- Codex 当前有哪些任务在运行、完成、等待确认或等待回复。

菜单栏会分成两个区域：

```text
任务图标   5h 83%  7d 90%
```

左侧是任务状态图标，右侧是 5 小时和 7 天额度。两边可以分别点击，不会互相触发。

## 主要功能

### 额度监控

- 显示 Codex 5 小时额度和 7 天额度的剩余百分比。
- 显示额度窗口的重置时间。
- 刷新时保留上一次额度数字，避免菜单栏突然变成加载状态。
- 弹窗内展示今日 / 昨日本机 Codex token 活动节奏，按 0-23 点分布。
- 根据剩余额度给出轻量提示，例如适合开始长任务、建议聚焦、额度偏低。

### 任务状态

任务状态使用程序绘制的矢量图标，不使用 emoji，适合放在 macOS 菜单栏里长期显示。

| 状态 | 菜单栏表现 | 含义 |
| --- | --- | --- |
| 无任务 | 灰色站立小人 | 当前没有需要关注的任务 |
| 运行中 | 蓝色跑步小人 + 数字 | Codex 正在执行任务 |
| 完成未读 | 绿色欢呼小人 + 数字 | 任务完成了，但对应对话还没有查看 |
| 需要确认 | 黄色手掌 + 数字 | 需要批准权限、继续执行或安装插件 |
| 需要回复 | 紫蓝色对话气泡 + 数字 | 计划模式确认、问题回答或用户输入等待 |
| 错误 | 红色小人 + 感叹号 + 数字 | Codex 任务出现错误 |

图标顺序固定为：

```text
错误 -> 需要确认 -> 需要回复 -> 运行中 -> 完成未读
```

数字最多显示到 `99+`，避免菜单栏被撑得太宽。

### 一键跳转 Codex 对话

点击任务状态图标时：

- 没有任务：只刷新任务状态，不弹出额度窗口。
- 只有 1 个任务：直接打开对应的 Codex 对话。
- 有多个任务：弹出任务选择器，选择后跳到对应对话。
- 按住 Option 点击，或右键点击：打开完整面板。

跳转使用 Codex 的本地 deep link：

```text
codex://threads/{threadId}
```

如果 deep link 无法打开，会退回到打开 `/Applications/Codex.app`。

### 完整面板

点击菜单栏右侧额度文字，会打开完整面板。面板包含：

- `用量`：5 小时 / 7 天额度卡片、活动节奏、隐私提示。
- `任务`：运行中、完成未读、需要确认、需要回复、错误的完整列表。
- 手动刷新按钮。
- 外观模式切换：跟随系统、浅色、深色。
- 开机启动开关。
- 退出按钮。

## 安装和运行

### 下载已打包版本

普通用户建议直接下载 GitHub Releases 里的 `Codex.Usage.zip`：

```text
https://github.com/200966371/codex-usage/releases
```

下载后：

1. 解压 `Codex.Usage.zip`。
2. 双击打开 `Codex Usage.app`。
3. 如果 macOS 提示无法验证开发者，右键 `Codex Usage.app`，选择 `打开`。
4. 如仍被拦截，到 `系统设置 -> 隐私与安全性`，点击 `仍要打开`。
5. 打开后看 Mac 右上角菜单栏。

可以直接放在下载目录运行。想长期使用时，再把 `Codex Usage.app` 移到 Finder 里的 `应用程序` 文件夹。程序坞只是快捷入口，不是安装位置；这个工具是菜单栏 App，一般不需要固定到程序坞。

### 直接运行源码

要求：

- macOS 13 或更高版本。
- Xcode Command Line Tools。
- 本机已经登录 Codex。

运行：

```bash
swift run CodexUsage
```

### 打包 App

```bash
./scripts/build-app.sh
```

脚本会生成：

```text
dist/Codex Usage.app
dist/Codex Usage.zip
```

打开已打包 App：

```bash
open -n "dist/Codex Usage.app"
```

## 分享给别人

安装包不放在源码目录里分发，下载入口在 GitHub Releases：

```text
https://github.com/200966371/codex-usage/releases
```

当前发布附件名是 `Codex.Usage.zip`。

当前版本没有开发者签名和 notarize。别人第一次打开时，macOS 可能提示无法验证开发者。正式公开分发前，建议补上：

- Apple Developer ID 签名。
- notarize 公证。
- DMG 安装包。

## 数据来源和隐私

App 只读本机数据，不上传 token 或会话日志。

额度数据：

- 优先读取 macOS Keychain 里的 `Codex Auth`。
- 如果 Keychain 不可用，兜底读取 `~/.codex/auth.json`。
- 使用 access token 请求 `https://chatgpt.com/backend-api/wham/usage`。

任务状态：

- 优先通过 `codex app-server proxy` 读取 Codex app-server 的 `thread/list`。
- 读取 `~/.codex/.codex-global-state.json` 判断完成未读线程。
- 读取 `~/.codex/sessions` 辅助判断运行、等待回复和任务标题。
- 读取 `~/.codex/archived_sessions` 识别归档线程，避免归档任务继续出现在菜单栏。

本机活动节奏：

- 读取 `~/.codex/sessions` 中的会话记录，统计今日 / 昨日 token 活动。

## 开机启动

完整面板底部的 `开机启动` 按钮用于开启或关闭开机自动启动。

开启后会写入：

```text
~/Library/LaunchAgents/com.lifeibiji.codexusage.plist
```

如果移动了 App 位置，重新点一次 `开机启动` 即可更新启动路径。

## 常见问题

### 额度读不到

先确认 Codex 已经登录，并且登录模式是 ChatGPT。App 会优先读 Keychain，如果 token 太旧或登录过期，需要重新打开 Codex 登录一次。

### 任务状态读不到

任务状态依赖 Codex app-server 和本机会话日志。即使 app-server 暂时不可用，额度显示也不会受影响。

### 手动停止的任务还显示运行中

当前版本会识别 `turn_aborted`、`<turn_aborted>` 和 `aborted by user` 等停止标记。如果仍然显示异常，通常是对应会话日志还没有刷新到最新状态，等下一次轮询即可。

### 已归档任务还显示在菜单栏

任务状态会过滤 Codex 的归档会话。归档后的完成未读、需要回复、需要确认、运行中或错误任务，都不会继续显示在菜单栏任务状态里。

如果手动删除了归档记录，Codex 的全局未读状态里可能还残留 thread id。App 只会显示能从 app-server 或本地会话文件确认存在的未读任务；只有残留 id、没有真实会话记录的项目会被忽略。

### 任务标题显示不对

App 会过滤 Codex 注入的 `AGENTS.md instructions`、`environment_context` 和文件说明块，优先显示最近一条真实用户请求。

## 开发说明

常用命令：

```bash
swift build
swift run CodexUsage
./scripts/build-app.sh
```

当前项目没有 `Tests` target，所以 `swift test` 会提示 `no tests found`。

核心文件：

- `Sources/CodexUsage/CodexUsageApp.swift`：菜单栏、弹窗、用量面板、任务选择器。
- `Sources/CodexUsage/TaskStatusClient.swift`：Codex 任务状态读取和本地会话解析。
- `Sources/CodexUsage/TaskStatusModels.swift`：任务状态模型和排序规则。
- `Sources/CodexUsage/TaskStatusStripIcon.swift`：菜单栏动态图标绘制。
- `scripts/build-app.sh`：构建 `.app` 和 `.zip`。
