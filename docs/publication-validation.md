# 首次开源验证记录

日期：2026-10-21。当前项目版本：0.0.1，构建号：8。

本次公开的是开发中的源码。安装包、Apple 公证、外部 Mac 验收和完整人工交互验收不属于本次源码公开结果。

## 已完成的整理

- README 包含产品介绍、实际操作、权限说明、默认快捷键和源码构建步骤。
- 保留上游 Git 提交历史，补齐 MIT 全文、上游署名与第三方组件说明。
- 真实浏览页面参考图保留在本地忽略目录，公开素材使用可重新生成的虚构示例。
- GitHub 与反馈入口指向本仓库；介绍页不再指向上游安装包或使用上游域名作为本分支官网。
- 默认 CI 检查源码配置；签名构建与测试由维护者显式触发。安装包发布配置仅保留为不执行的文档示例。

## 本次检查

| 检查 | 结果 |
| --- | --- |
| XcodeGen 项目生成 | 通过 |
| 项目、CI workflow 与发布配置示例的 YAML 解析 | 通过 |
| Info.plist、entitlements 与发布脚本语法 | 通过 |
| Apple Developer ID 签名的 Debug 构建与现有测试 | 169 项测试通过，0 失败 |
| 测试构建的 `codesign --verify --deep --strict` | 通过，Apple Developer ID 信任链 |
| Astro 介绍页 `npm ci` 与 `npm run build` | 通过 |
| 公开源码中的常见凭据格式及私人绝对路径检查 | 通过，未发现匹配 |
| 本地设计证据、原始截图、签名材料的 Git 排除检查 | 通过 |
| README 与贡献文档的相对链接检查 | 通过 |
| 公开原型参考图 | 已生成并查看，1440 × 3600 虚构内容 |

本地测试环境为 Xcode 27.1、arm64 macOS。签名使用维护者现有 Apple Developer ID 证书。测试执行命令结构如下，证书占位符需替换为自己的有效身份：

```bash
xcodegen generate
xcodebuild test -project Captures.xcodeproj -scheme Captures \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=YOUR_VALID_APPLE_SIGNING_IDENTITY
```

测试只证明现有自动化覆盖范围。CI 的默认源码检查不会访问维护者的签名证书。

## 尚未覆盖

完整的多屏操作、不同权限组合、中文输入法、长时间滚动拼接、VoiceOver、减少动态效果与外部 Mac 使用验收需要进一步验证。HTML 原型、单元测试和签名构建各自只说明对应范围，不能相互替代。
