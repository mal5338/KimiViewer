# KimiViewer（HarmonyOS）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[kimi-dashboard](https://github.com/mal5338/kimi-dashboard)（Kimi Code 会话看板）的鸿蒙 Pad 端客户端。原生 WebView 全屏加载自建的看板服务，首次启动配置访问地址即可使用。

## 功能

- **全屏 Web 入口**：加载 kimi-dashboard 看板页，支持地址本地持久化（首次启动引导填写 `http(s)://` 地址）
- **文件下载桥**：网页内调用 `kimiNative.downloadFile(url)`，由原生侧流式下载（临时文件 + `requestInStream`，支持大文件；缺省从 URL 解析文件名），保存到用户目录
- **Web 样式注入**：按系统深浅色动态注入页面样式（状态栏纯黑对齐等）
- **状态管理**：看板地址、提示次数等通过 Preferences 持久化

## 构建

1. 使用 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 打开本项目
2. 真机/模拟器运行需先在 DevEco 中生成签名（`File > Project Structure > Signing Configs`，勾选 Automatically generate 即可自动写入 `build-profile.json5`）
3. `compatibleSdkVersion: 6.1.1(24)`，API 12+ 真机均可

## 关联项目

- 服务端 + Web 看板：[kimi-dashboard](https://github.com/mal5338/kimi-dashboard)
- Android 手机端：[kimi-viewer-android](https://github.com/mal5338/kimi-viewer-android)

## License

[MIT](LICENSE)
