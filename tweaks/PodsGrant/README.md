# PodsGrant Enhanced (优化增强版)

本工程基于开源项目 [LNSSPsd/PodsGrant](https://github.com/LNSSPsd/PodsGrant) 进行深度逆向重构与性能调优，旨在解决老版本 iOS（iOS 13 ~ 16+）连接新一代 AirPods / Beats 耳机时的弹窗丢失、延迟过高与兼容性问题。

---

## 🚀 核心优化与重大改进

### 1. 彻底解决「开机 / 重启后无弹窗」
* **解锁通知监听 (`com.apple.mobile.keybagd.first_unlock`)**：由于 iOS 开机未解锁前 `/var/mobile` 处于 Data Protection 加密状态，原版一旦读取失败会直接置空退出。优化版增加了开机 Fallback 机制并在首次解锁后自动重新热加载配置。
* **修复 `PGS_global_os_ver` 在 `sharingd` 中恒为 0 的严重 Bug**：原版仅在 `bluetoothd` 中初始化系统版本，导致 `sharingd` 守护进程无法识别 iOS 16 及以上预设映射。优化版确保所有注入进程均能精准获取系统主版本。

### 2. 毫秒级极速开盖弹窗（开启动画迟钝优化）
* **消除双重内存分配 (Zero-Copy 优化)**：原版在 `SFBLEScanner` 的高频回调中频繁进行 `malloc` $\rightarrow$ `memcpy` $\rightarrow$ `[NSData dataWithBytes:]` $\rightarrow$ `free`。优化版直接利用可变数据就地打补丁，杜绝了内存震荡 (Memory Thrashing)。
* **广播报文安全边界检查与高频 micro-cache**：增加报文长度合法性校验，并添加最近匹配设备的单项缓存，避免同一副耳机 50 次/秒高频广播下的无谓循环遍历。

### 3. 扩充现代耳机型号支持
* 补充了 **AirPods 4（标准版 & ANC 降噪版）**、**AirPods Pro 2 (USB-C & Lightning)**、**Beats Studio Buds+**、**Beats Solo 4** 等型号的 PID 转换预设。

---

## 🛠️ 构建与编译

本项目已配置完整的 **GitHub Actions CI/CD** 自动化构建工作流：
* 每次推送代码至 `main` 分支时，GitHub Actions 将自动在 macOS 运行环境中编译生成 **Rootful** 和 **Rootless**（无根越狱）两个架构的 `.deb` 安装包。
* 可在仓库的 **Actions** 页面直接下载最新的构建产物（Artifacts）。

### 本地编译（需配置 Theos）：
```bash
# 传统越狱包
make package FINALPACKAGE=1

# 无根越狱包 (Rootless - Dopamine 等)
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

---

## 📜 鸣谢与开源协议
* 原作核心逆向与汇编掩码设计：[LNSSPsd (Ruphane)](https://github.com/LNSSPsd/PodsGrant)
* 本优化工程依据 **MIT License** 开放。
