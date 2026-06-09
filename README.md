# Codex Usage

一个 macOS 右上角菜单栏小工具，用来直接查看 Codex 用量：

```text
5h 83%  7d 90%
```

弹窗里会显示 5 小时 / 7 天剩余额度、今日/昨日 24 小时本机 token 活动、外观模式和开机启动。

## 本地运行

```bash
swift run CodexUsage
```

或打开已打包的 App：

```bash
open -n "dist/Codex Usage.app"
```

## 分享给别人

当前本地版可以直接把这个 App 发给别人：

```text
dist/Codex Usage.app
```

建议压缩成 zip 再分享：

```bash
ditto -c -k --keepParent "dist/Codex Usage.app" "Codex Usage.zip"
```

注意：现在还没有开发者签名和 notarize。别人第一次打开时，macOS 可能提示“无法验证开发者”。正式发给粉丝前，建议做：

- Apple Developer ID 签名
- notarize 公证
- 打包成 DMG

## 开机启动

弹窗底部的 **启动** 按钮用于开机自动启动。

它会在用户本机写入：

```text
~/Library/LaunchAgents/com.lifeibiji.codexusage.plist
```

如果用户移动了 App 位置，重新点一次 **启动** 即可更新启动路径。

## 数据来源

App 只读本机数据：

- Codex OAuth：优先读 macOS Keychain 的 `Codex Auth`
- 兜底读 `~/.codex/auth.json`
- 今日/昨日活动读 `~/.codex/sessions`

Token 和会话日志只留在本机。
