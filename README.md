# SimulMeet iOS 1.1 高可靠实时翻译版

原生 SwiftUI 应用，最低 iOS 16。支持 Doubao Seed 1.6 Flash、Doubao Seed 2.0 Mini、DeepSeek V4 Flash。

## 1.1 重点改进

- 临时识别字幕与正式句分离：partial 只显示，final/语义断句才进入队列。
- 每个正式句在调用翻译 API 前立即写入历史，接口失败也不会丢失原文。
- 历史状态：待翻译、翻译中、已完成、翻译失败。
- 失败自动重试；启用故障转移时可在豆包和 DeepSeek 之间自动切换。
- 流式译文：模型返回第一个字后立即更新字幕，不必等待完整响应。
- 重复译文校验：新原文却返回旧译文时，自动无上下文重试一次。
- 点击任意历史记录查看完整原文、完整译文、模型与错误信息。
- 失败记录支持手动重新翻译。
- 只有用户停留在历史底部时才自动跟随最新记录。
- 自定义术语、姓名、课程名会加入 Apple Speech `contextualStrings`。
- 上传资料中的文件名和英文专有词会辅助语音识别。
- 标点优先断句，约 1.15 秒静音兜底，比旧版 1.9 秒更快。
- Token 用量记录；助手问答和总结仍然只有点击时才调用模型。

## 构建未签名 IPA

GitHub Actions 工作流：`.github/workflows/build-unsigned-ipa.yml`

1. 上传项目全部内容到 GitHub 仓库根目录。
2. 打开 Actions。
3. 运行 `Build unsigned SimulMeet IPA`。
4. 下载 Artifacts 中的 `SimulMeet-unsigned-ipa`。
5. 用爱思助手或其他合法签名工具签名后安装到自己的设备。

## 重要限制

- 普通 iOS App 不能直接读取 Zoom、Teams、腾讯会议等其他 App 的内部音频。
- Apple Speech 的准确度仍受设备、网络、麦克风距离、口音和系统语言支持影响。
- 真正的多说话人分离、云端音频回放重识别，需要额外接入专业流式 ASR 服务及相应凭证。
- API Key 保存在 iPhone Keychain，不写入项目和 IPA。
