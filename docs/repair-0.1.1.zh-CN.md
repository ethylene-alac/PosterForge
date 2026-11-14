# PosterForge 0.1.1 修复与验证

基于 `mubixbyte/PosterForge` 的 `1acacd5`（完整提交号见交付校验记录）。
针对用户提供的 iPhone SE 2、iOS 16.7.2 (20H115)、Dopamine Rootless 症状修复。
当前交付是源码、补丁、构建工作流及验证说明。尚未连接手机、运行远端 Actions 或生成可安装的 `.deb`；不能把语法检查当作真机验证。

## 修改与判断

| 任务 | 原因 / 原行为 | 修复 |
| --- | --- | --- |
| A 容器定位 | 原本已遍历 UUID 并匹配元数据，但枚举和 plist 读取全部忽略错误，权限拒绝也变成“找不到” | 保留动态枚举；只接受 UUID 目录且 `MCMMetadataIdentifier` 严格等于 `com.apple.PosterBoard`；不使用设备上的 UUID 常量；多个匹配时报错；完整记录路径、枚举数量、元数据标识、读/解析错误、UID/EUID/GID、mode、access 与 errno |
| B daemon 权限 | launchd 已配置 root，但签名只有 `no-container`、platform 和无关的 library validation 声明；root 身份本身不能证明能够访问应用数据容器 | 仅给 daemon 增加 `com.apple.private.security.no-sandbox` 与 `com.apple.private.security.storage.AppDataContainers`；保留 platform/no-container，移除无关的 skip-library-validation；使用绝对路径指定签名文件；CI 从两个签名切片实际提取并检查权限 |
| C 裁剪 Done | 回调触发 `Wallpaper name` 时裁剪导航窗口仍处于 presented 状态 | 先关闭整个裁剪 navigation controller，在 dismissal completion 调用一次回调；防止连续 Done；空裁剪不继续；Photos picker 也在关闭完成后开始加载，避免缓存图片快速回调引发同类竞态 |
| D Tendies | 模糊匹配任何名称包含 descriptor 的目录，Container 内的 descriptors 也可能被误导入；外部 unzip 和写入错误处理不完整 | 使用有界 ZIP 检查及 zlib 解压；精确识别 descriptor/descriptors；明确拒绝 Container、混合格式、路径穿越、链接、重复路径等；验证后在暂存目录随机化，每一步检查错误；保留嵌套 asset ID |
| E 构建 | 现有配置没有验证签名、切片和最终包布局；control/APT 元数据仍写 iphoneos-arm | 升级为 0.1.1；明确 iphoneos-arm64、arm64/arm64e、iOS 16.0 最低版本、Rootless；macOS Actions 完成测试→编译→解包/签名验证→上传，APT 发布改为显式勾选 |
| 现有数据保护 | 安装前删除同名目录，刷新时整份覆盖 Apple 偏好 plist | 在 PosterForge 目录内暂存，新目录用 `renamex_np(..., RENAME_EXCL)` 原子发布，任何目标已存在都失败；仅可删除带本版本所有权标记的条目；不改写 Apple plist，不运行系统容器 chmod/chown，不重置保护属性 |

权限不足是根据源码和现象推断的高可能原因，尚未在该手机确认。新诊断会明确区分“父目录枚举失败”“元数据读取失败”“plist 无效”“没有匹配”和“多个匹配”，而不是盲目更换 UUID。`/var` 与 `/private/var` 通过系统别名指向同一位置，日志包含解析后的路径；更换别名不能解决沙盒拒绝。

参考依据：Dopamine 自身 [idownloadd 的签名配置](https://github.com/opa334/Dopamine/blob/2.x/BaseBin/idownloadd/entitlements.plist) 使用应用数据容器存储权限；[RootHide 开发文档](https://github.com/RootHide/Developer/blob/main/entitlements.md) 说明 no-sandbox 与存储权限的用途（该文档是补充机制参考，不代表把你的环境按 RootHide 打包）。Rootless 包和架构遵循 [Theos Rootless 文档](https://theos.dev/docs/rootless)。Tendies 格式根据 [Nugget 格式说明](https://github.com/NoIdentity2/nugget/blob/main/documentation.md) 及其解析逻辑核对。

## 获取 `.deb`

1. 将修复源码提交到你有写入权限的 GitHub 仓库。原仓库可直接应用交付补丁；源码 ZIP 包也包含 `.github/workflows/build.yml`。本次没有修改远端仓库。
2. 进入 **Actions → Build rootless deb → Run workflow**，选择含修复的分支。让 `publish_apt_repository` 保持未勾选。
3. 等待 `build` 成功，下载 **PosterForge-0.1.1-rootless** artifact。其中应包含 `com.posterforge.wallpapers_0.1.1_iphoneos-arm64.deb`、`SHA256SUMS`、`toolchain.txt`。
4. CI 会验证包 `Architecture=iphoneos-arm64`、Version=0.1.1，daemon 和偏好 bundle 都包含 arm64/arm64e，且两个 daemon 签名切片均含所需权限。**PosterForge-build-diagnostics** 保存日志、Mach-O 构建版本及实际权限 dump。
5. 失败时先查看报错步骤和 diagnostics，不使用旧 0.1.0 包冒充修复产物。普通 push/PR 构建不公开发布 APT 仓库。

本地 macOS 构建方式：

```sh
export THEOS=/opt/theos
sh Tests/run-host-tests.sh
make clean
make package FINALPACKAGE=1 ARCHS="arm64 arm64e" TARGET=iphone:clang:latest:16.0 THEOS_PACKAGE_SCHEME=rootless
```

需要 Theos、Xcode 的 iPhoneOS SDK、ldid、GNU make 和 Debian 打包工具。使用更新 SDK 编译时，最低系统版本仍为 iOS 16.0；不是要求手机升级。

## 安装与只读诊断

先记录当前壁纸及已有第三方条目；保留原始照片/视频和 `.tendies` 文件。安装包仅部署 PosterForge 自己的程序、偏好页、launchd 配置和运行目录，不执行容器搬迁、恢复或清空。

将构建得到的 `.deb` 复制到手机，用 Sileo 打开并安装，或在手机 SSH/终端执行（依赖需先安装）：

```sh
sudo dpkg -i ./com.posterforge.wallpapers_0.1.1_iphoneos-arm64.deb
dpkg-query -W -f='${Version} ${Architecture}\n' com.posterforge.wallpapers
sudo launchctl print system/com.posterforge.daemon
sudo /var/jb/usr/libexec/posterforged --diagnose-container
sudo tail -n 200 /var/mobile/Library/Logs/PosterForge.log
```

应看到版本 0.1.1、架构 iphoneos-arm64、服务有 PID；daemon 启动日志应显示 `uid=0 euid=0`。
`--diagnose-container` 只读取目录与元数据，不处理队列、不创建壁纸。诊断 JSON 应为 `success=true`，container 应等于当前通过元数据确认的 PosterBoard 容器。你提供的 `6E8F5ADF-5157-452C-BB5B-E217BE3F261E` 仅用于此次人工比对，不存在于生产代码中；若系统迁移了容器，以当前元数据为准。

若手动诊断成功但后台仍失败，比较后台日志的 PID/EUID 和启动版本，确认已运行新二进制。必要时仅重启本项目服务：

```sh
sudo launchctl kickstart -k system/com.posterforge.daemon
```

若仍有 EPERM/EACCES，保留 JSON、日志和 Completed 的 `errorDetails`。使用 Actions 的签名 dump 核对实际构建，不对系统容器执行 chmod、chown、复制、迁移或路径写死。设备对私有权限的接受情况仍需结合越狱环境诊断。

## 功能验收

1. **照片命名**：设置 → PosterForge → + → Photo or video → 选择照片 → 裁剪 → Done。裁剪窗口应完全关闭，然后出现一次 Wallpaper name。连续点 Done 不应出现重复命名窗口。Cancel 不应提交新请求。
2. **生成结果**：命名后 Add，等待数秒。Requests 清空本身不表示成功；到 Completed 中检查对应新记录：

   ```sh
   ls -lt "/var/mobile/Library/Application Support/PosterForge/Completed"
   plutil -p "/var/mobile/Library/Application Support/PosterForge/Completed/<本次请求ID>.plist"
   ```

   成功应有 `success=true`。失败应有可读 `error` 和结构化 `errorDetails`，底层错误带 domain/code/path。旧 Completed 不会自动重试；先添加一张新照片测试即可，不需清空旧结果或壁纸。
3. **原生显示**：打开添加新壁纸 → Collections，确认新条目可预览、添加，原有壁纸与条目仍在。分别测试 Home blur 开/关，以及一段短视频。SE 2 的最终显示、渲染类与刷新行为必须真机确认。
4. **Descriptor 导入**：使用你有权使用、与 iOS 16 兼容的包。`descriptor/<条目>/...` 或 `descriptors/<条目>/...` 均应导入；允许外层包装目录和名称大小写变化；允许一个包含多个条目。每个条目得到新 UUID；顶层 wallpaper ID 随机化，嵌套 asset ID 保持原值。
5. **拒绝测试**：Container-only、Container 与 Descriptor 混合包应返回 `Container-format ... not supported`；`video-descriptors`、`ordered-descriptors` 等未支持 provider/布局不按普通 Collections 导入。含绝对路径、`..`、链接、损坏 plist 或 CRC 的包应失败，不向 PosterBoard 发布不完整条目。
6. **已有目录保护**：代码使用独占 rename，目标 UUID 已存在时失败；不要通过覆盖真实壁纸来测试碰撞。0.1.0 旧条目没有 `.posterforge-owned.plist`，本版本拒绝自动删除，避免误删。不要手工补写标记后删除系统条目。

## 验证范围与限制

- Windows 可执行配置/脚本检查，并使用 iOS 16.5 SDK 对 arm64、arm64e 做 Objective-C 语法检查；这不验证链接、签名执行或设备沙盒。
- `Tests/run-host-tests.sh` 在 macOS 编译并调用真实的 Foundation 容器扫描、ZIP 解压及 ID 随机化函数。测试覆盖动态 UUID、歧义、丢失/损坏/不可读元数据，以及 Descriptor 正反例、CRC、路径穿越、链接和嵌套 ID 保留；不接触手机。仅跑 Windows unittest 时，平台运行测试会显示 skipped。
- 当前 ZIP 支持 stored/deflate、UTF-8/ASCII 文件名；拒绝加密、多卷、ZIP64。限制为压缩包 256 MiB、展开总量 1 GiB、单文件 256 MiB、最多 20,000 条目。
- 数据格式正确不保证所有社区壁纸兼容 iOS 16；来自更高版本的渲染类/资源可能不可用。
- 刷新不再写 Apple 偏好 plist；某些设备可能需要手动重新打开壁纸界面。不要为了刷新重置整个 PosterBoard 容器。
- 暂存与目标必须位于同一数据卷；跨卷 rename 会返回明确错误，不退回覆盖式复制。导入中途失败只回滚本次新发布的目录，尽力清理失败会在日志记录；不会清空原有目录。
