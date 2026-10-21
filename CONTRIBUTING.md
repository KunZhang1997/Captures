# 参与 Captures

可以提交问题、改进建议、文档修正或 Pull Request。开发环境和首次构建步骤见 [README](README.md#build-from-source)。

## 反馈问题

请说明 macOS 版本、Captures 版本或提交号、复现步骤，以及预期和实际结果。提供图片时使用虚构内容，遮去个人信息。

## 提交修改

1. Fork 仓库并创建功能分支。
2. 保持改动围绕一个具体问题，保留已有的本地工作。
3. 完成与改动相称的检查，在 PR 中写明结果和未覆盖的部分。

原生应用使用 Swift、SwiftUI、AppKit、ScreenCaptureKit 和 Apple Vision。`project.yml` 是 Xcode 配置源；修改配置后运行 `xcodegen generate`，生成的 `.xcodeproj` 不提交。

## 签名与测试

所有构建使用有效 Apple Developer 签名证书。设置好自己的团队和证书后，可在 Xcode 运行测试，或显式覆盖命令行配置：

```bash
xcodebuild test \
  -project Captures.xcodeproj \
  -scheme Captures \
  -configuration Debug \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development: Your Name (YOUR_CERTIFICATE_ID)"
```

Push 和 Pull Request 的 CI 检查项目生成、属性列表与脚本语法。维护者可在 Actions 手动启用签名构建与测试，需要仓库 secrets `CERTIFICATE_P12` 和 `CERTIFICATE_PASSWORD`。没有配置签名的仓库仍可完成源码检查；源码检查通过不代表应用已通过构建或交互验证。

## 原型与素材

`design/all-in-one-prototype.html` 是唯一交互原型；修改前先阅读 [原型约定](docs/prototype-guide.md) 和 [AGENTS.md](AGENTS.md)。截图与录屏示例使用虚构内容。可用以下命令重新生成原型参考图：

```bash
swift design/generate-demo-reference.swift
```

本地设计审查证据、原始截图、签名材料和环境配置不提交。发布安装包需要单独完成 Apple 签名、公证和产物验证，配置示例保留在 `docs/release-workflow.example.yml`，本仓库尚未启用自动发布安装包；公开安装包由维护者在本机构建、公证并验证后手动上传。

## 许可

提交的项目代码遵循 [MIT](LICENSE) 许可。保留 [NOTICE](NOTICE) 与已有第三方许可；引入外部代码或素材时说明其来源。
