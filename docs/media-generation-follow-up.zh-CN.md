# 照片与视频生成后续问题

这两项与 0.1.1 的容器定位、权限诊断、裁剪命名回调和 Descriptor Tendies 导入分别跟踪；本次提交仅记录，保持生成逻辑不变。

1. `Daemon/PFPosterBuilder.m` 生成的 `Wallpaper.plist` 把 `logicalScreenClass` 写死为 `375w-812h@3x~iphone`。后续应根据目标设备/屏幕配置确定正确值，并在 iPhone SE 2 上验证照片与视频显示。
2. `writeIndexAt:width:height:error:` 通过统一的 `PFWritePlist` 写入 `index.xml`，当前输出是二进制 plist。后续应核实 PosterBoard 所需的 XML 格式，单独修复并验证生成文件。

在上述问题完成前，不将 0.1.1 的照片/视频生成标记为完整验收。当前真机验证顺序仍为：只读容器诊断成功 → 导入确认兼容 iOS 16 的 Descriptor `.tendies` → 检查 Completed 与 Collections。
