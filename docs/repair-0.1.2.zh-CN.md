# PosterForge 0.1.2：服务内存与 launchd 域

## 已知事实与验收边界

用户已在 SE 2 / iOS 16.7.2 / Dopamine Rootless 确认 0.1.1 容器诊断成功，后台约每 10 秒重启，退出原因为 `JETSAM_REASON_MEMORY_PERPROCESSLIMIT`，active/inactive 限额均为 6 MB。这不是容器找不到或 UUID 错误。

本轮不连接、安装或操作手机，不改系统全局 Jetsam 配置。可以完成研究、代码修复、主机测试和 `.deb` 构建；**192 MiB 是否在这台手机真正生效，以及服务是否持续稳定，必须等待设备操作者返回实际服务 PID 的只读诊断结果，不能预先宣称完成真机验证**。

## 限额方案与研究依据

- 本服务 LaunchDaemon 添加 `JetsamProperties/JetsamMemoryLimit=192`，作为启动时的有限预算声明。没有把全局 daemon-override 的 `ActiveSoftMemoryLimit` 等键盲目复制到 job plist，也不使用 RSS/AddressSpace 的 rlimit 代替 Jetsam。
- plist 是私有配置接口，不能仅凭 plist 内容认定 iOS 16 已采纳。daemon 进入 `main`、创建 Foundation 对象之前，使用 `dlsym` 获取 `memorystatus_control`，通过命令 7 设置**自身 PID**的 active/inactive 有限限额，再用命令 8 回读。已有更高正值限额不降低，未设置为 unlimited，也没有改变 Jetsam 优先级或全局属性。
- 使用 16 字节的四字段 ABI，保留有界 fatal 限额。若接口不存在、权限拒绝、SET 被拦截或读回低于预算，日志记录 errno 和前后值，重任务保留在 Requests，不把 SET 的返回成功当作限额已生效。
- Dopamine 的公开 launchd hook 会拦截命令 6；因此不把命令 6 返回零当作证据。本实现采用独立 active/inactive 属性接口，并始终回读。192 MiB 是本项目的初始工程预算，不是 Apple 对该应用的推荐值；在内存压力下仍可能被系统回收。

主来源：

- [Apple XNU 8796.141.3 memorystatus ABI](https://github.com/apple-oss-distributions/xnu/blob/xnu-8796.141.3/bsd/sys/kern_memorystatus.h)：命令 7/8、结构体、fatal 属性。
- [同版本内核实现](https://github.com/apple-oss-distributions/xnu/blob/xnu-8796.141.3/bsd/kern/kern_memorystatus.c)：root/权限检查、单 PID 限额设置和实际属性读取。该版本属于 iOS 16 时代的参考源码，不代表已确认本机运行内核的精确 tag。
- [Apple launchd 私有键定义](https://github.com/apple-oss-distributions/launchd/blob/main/liblaunch/launch_priv.h)：JetsamProperties / JetsamMemoryLimit。公开 launchd 源码较旧，不能代替 iOS 16 真机回读。
- [Dopamine 的 Jetsam hook](https://github.com/opa334/Dopamine/blob/2.x/BaseBin/launchdhook/src/jetsam_hook.c)：拦截行为的实现依据。

## 内存优化

1. 原 daemon 的最外层 `@autoreleasepool` 随无限 run loop 一直存活。改为每次 run-loop 迭代、每次队列回调和每条请求独立排空；空队列不创建 builder，容器枚举逐候选排空，Completed 诊断仅保留身份与最多 255 条尾部记录，完整枚举仍写日志。
2. 原 ZIP 同时持有整个压缩包 NSData 和单文件大小的解压 NSData。改为单个只读 FD + `pread`：EOCD 最多 65,557 字节；stored/deflate 数据使用两个 64 KiB 缓冲区流式校验 CRC、写入独占创建的暂存文件，不加载完整资产，也不依赖 mmap。
3. 保留压缩包 256 MiB、单文件 256 MiB、总展开 1 GiB、20,000 条目的限制；再限制 central directory 8 MiB、文件名 1,024 字节、文件名合计 4 MiB。目录索引和 Foundation 元数据仍占内存，不能把“128 KiB 解压缓冲区”表述为整个进程仅占 128 KiB。
4. ID 随机化逐文件排空，只读入至多 1 MiB 的元数据 plist；超限明确拒绝。大资产不读入内存。错误对象跨池保持强引用，损坏/截断/CRC/写入失败均返回错误；只清理本次暂存文件。
5. 主机回归测试对 stored 64 MiB 和 deflate 展开 128 MiB 的真实 ZIP 解压，记录 native harness 的峰值 RSS，要求低于 80 MiB。该测试验证算法不会按资产大小分配，不代表已测量手机的 Jetsam physical footprint。

## 核查 user / foreground 与实际注册域

安装脚本和移除脚本只针对 `system/com.posterforge.daemon` 使用显式 `bootstrap` / `bootout` / `kickstart`；安装后打印实际 system job。没有用隐含当前调用者域的 `load`，没有把服务移到 user/GUI 域，也没有提升为 foreground/Interactive 来回避限制。`ProcessType=Background` 是调度类型，与 bootstrap domain、UID、Jetsam active/inactive 是不同维度。

单独看到 `user` 或 `foreground` 提示，无法确认后台服务注册在哪个域；root UID、PPID=1 或 XPC_SERVICE_NAME 同样不能独自证明 system 注册。需要关联**同一个 PID**：

```sh
sudo launchctl print system/com.posterforge.daemon
sudo launchctl procinfo <上面列出的实际PID>
sudo /var/jb/usr/libexec/posterforged --diagnose-runtime <同一个实际PID>
```

包内还提供只读汇总脚本：

```sh
sudo /var/jb/usr/libexec/posterforge-diagnose-service
```

它打印 system job、user/0、user/501、gui/501 的同名服务、对应 PID 的内核限额、procinfo 和 pid domain；不会注册/卸载/重启服务，不会设置内存限额，也不处理队列或修改壁纸。如果另一域存在第二个 PID，只报告，不自动 bootout。501 是常见 mobile UID；若设备实际 UID 不同，应另查实际 user/GUI 域。

## 设备操作者的验收步骤（本次未执行）

1. 用 Sileo 升级 0.1.2，不删除旧壁纸，不修改系统文件。安装脚本只重启本服务，不再顺带终止 Preferences / PosterBoard。
2. 运行上述只读汇总脚本，保留完整输出和 `/var/mobile/Library/Logs/PosterForge.log`。
3. 确认 system job 的 program/plist 路径正确、PID 与诊断 `targetPID` 相同，且 `targetIsDiagnosticProcess=false`。`--diagnose-runtime` 不带 PID 只查新建的诊断进程，**不能用于证明后台限额**。
4. 内核查询应有 `success=true`、`readbackErrno=0`、`budgetSatisfied=true`，`after.activeMB` / `after.inactiveMB` 至少 192。`success=true` 单独只代表查询成功；若仍是 6、errno 非零或 budgetSatisfied=false，限额尚未验证通过。脚本在预算不足时返回非零。
5. 间隔至少 60 秒再次执行，确认服务 PID 没变、run count 未持续增长，没有新增 per-process-limit Jetsam。对照 launchctl 显示与内核 GET 结果；若数值冲突，保留两者，不能只凭静态 job 配置断言实际限制。
6. 稳定后仅导入一个确认与 iOS 16 兼容的 Descriptor `.tendies`，检查最新 Completed 的 success/errorDetails 及 Collections；确认导入后限额和 PID 仍稳定。失败时停止反复重试并保留日志。

本轮仍保留 Container 格式拒绝、路径/链接校验、随机 UUID、独占发布及旧壁纸保护。照片/视频的 logicalScreenClass 和 index.xml 问题继续独立待办，未在本次修改。
