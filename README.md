# X3D CCD Affinity

把游戏固定在**带 3D V-Cache 的那颗 CCD** 上运行。为 AMD 双 CCD 的 X3D 处理器而写，
主要解决"Windows 和 AMD 驱动没把游戏放到缓存 CCD 上"这件事。

适用于 **Ryzen 9 9950X3D / 7950X3D / 9900X3D**、Ryzen 9 PRO 9965X3D，
以及线程撕裂者以外的其他"双 CCD + 单侧 3D V-Cache"型号。

---

## 为什么需要它

以 9950X3D 为例，一颗 CPU 里有两颗 CCD：

| CCD | 逻辑 CPU | L3 缓存 | 特点 |
|---|---|---|---|
| **CCD0** | 0–15 | **96 MB**（32 + 64 堆叠） | 缓存大，游戏帧数高、1% low 稳 |
| CCD1 | 16–31 | 32 MB | 频率略高，适合解压/编译/渲染 |

实测（随机指针追逐，工作集 64 MB，单线程）：

```
CCD0 (0-15, 96MB) : 30.8 ns
CCD1 (16-31, 32MB): 85.8 ns        -> CCD0 快 64%
```

AMD 本意是让 `3D V-Cache Performance Optimizer` 驱动配合 Xbox Game Bar，
在游戏启动时自动停泊 CCD1，把游戏挤到 CCD0。实际使用中这条链路经常失效：

1. **Game Bar 不认识这个游戏** —— 独立游戏、模拟器、私服、非 Steam 平台、国产小体量作品
2. **BIOS 里 CPPC / 3D V-Cache Optimizer 没设成 Driver** —— AMD 驱动直接没接管
3. **新版 Windows 内核 AI Scheduler 与 AMD 停泊服务抢控制权** —— 已知冲突，实测 32 个逻辑处理器全部常驻可用，没有被停泊
4. **反作弊游戏**（EAC / BattlEye / nProtect / EA Javelin）拒绝第三方修改亲和性

这个项目用**固定的 CPU 亲和性**直接指定，不看 Game Bar、不看 Game Mode、不看电源计划。

---

## 组成

| 文件 | 作用 |
|---|---|
| `X3D-Tray.ps1` | **托盘程序**（推荐日常使用）。图形界面，可排序、可筛选、可随时改绑 |
| `X3D-CCDAffinity.ps1` | **守护进程**（无窗口）。按 `config.json` 长期自动绑定 |
| `launcher/launcher.cs` | 提权启动器源码，编译成 `X3D-Tray-Admin.exe` |
| `launcher/build.ps1` | 一键编译启动器（只依赖 Windows 自带的 csc.exe） |
| `Install-Task.ps1` / `Uninstall-Task.ps1` | 注册 / 撤销开机自启计划任务 |
| `config.example.json` | 配置模板 |

两个进程读同一份 `config.json`，互不冲突：

| 进程 | 权限 | 职责 |
|---|---|---|
| `X3D CCD Affinity Guard` | 普通 | 长期绑定 config 里的游戏 |
| `X3D CCD Affinity Tray` | 管理员 | 图形操作 + 绑定管理员权限的游戏 |

---

## 快速开始

### 1. 确认你自己 CPU 的 CCD 分布

**这一步不要跳过。** 不同型号上带缓存的 CCD 编号可能不同。

```powershell
pwsh -File .\X3D-CCDAffinity.ps1 -Status
```

输出会直接告诉你哪些逻辑 CPU 拥有大缓存。也可以手动验证：

```powershell
Get-CimInstance Win32_Processor | Select-Object Name, L3CacheSize
```

如果看起来不对，用 `GetLogicalProcessorInformation` 查每个 L3 域的掩码
（见 `X3D-CCDAffinity.ps1` 里的探测逻辑）。

### 2. 准备配置

```powershell
Copy-Item config.example.json config.json
```

编辑 `config.json`，把你想锁定的 exe 文件名填进 `ccd0-cache` 组的 `processes` 数组。

### 3. 构建提权启动器

```powershell
pwsh -File launcher\build.ps1
```

生成 `X3D-Tray-Admin.exe`，带 `requireAdministrator` 清单，双击即弹 UAC。
仓库不附带编译好的 exe，请自行构建（源码就在旁边，一眼能看完）。

### 4. 启动

双击 `X3D-Tray-Admin.exe`，UAC 点「是」。

首次以管理员启动后，托盘会自动注册 `X3D CCD Affinity Tray` 计划任务（Highest），
以后开机自启且不再弹 UAC。

也可以只跑守护进程（不需要管理员，但绑不了管理员游戏）：

```powershell
pwsh -File .\Install-Task.ps1
```

---

## 托盘界面

左键单击托盘图标打开面板，右键出菜单。

- **点表头排序**：程序 / PID / 窗口标题 / 当前 CPU / 绑定来源 / 目标，点一次正序，再点一次倒序
- **搜索框**：按程序名、窗口标题、PID 过滤
- **筛选标签**：全部 / CCD0 / CCD1 / 未绑定 / 需管理员
- **多选**：Ctrl / Shift 选择多行
- **双击某行**：直接绑到 CCD0

### 绑定来源标识

列表里「绑定来源」列会告诉你这个绑定是怎么来的：

| 标识 | 颜色 | 含义 |
|---|---|---|
| **配置** | 绿 | 来自 `config.json`，由守护进程长期维护 |
| **手动** | 琥珀 | 你在面板里临时点的，重启游戏后失效 |
| **手动覆盖** | 琥珀 | 你手动指定的目标和 config 不一致，config 不会覆盖它 |
| **继承** | 靛蓝 | 父进程已在 CCD0，子进程启动时天然继承 |
| **未绑定** | 灰 | 普通进程，跑在全部 32 核上 |

「当前 CPU」列用色块显示实际状态：青色 = CCD0（96 MB），蓝色 = CCD1，灰色 = 全核，
红色 = 需管理员（读不到亲和性）。

---

## 配置说明

```json
{
  "pollSeconds": 2,
  "retryAttempts": 6,
  "retryDelayMs": 400,
  "logRetainDays": 14,
  "groups": [
    {
      "name": "ccd0-cache",
      "mask": "0xFFFF",
      "priority": null,
      "enabled": true,
      "processes": [ "Cyberpunk2077.exe", "StarRail.exe" ]
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `mask` | `0xFFFF` = CPU 0-15（96 MB 三缓）；`0xFFFF0000` = CPU 16-31（高频） |
| `processes` | exe 文件名，大小写不敏感，必须带 `.exe` |
| `priority` | `null` / `AboveNormal` / `High` / `RealTime`，一般留 `null` |
| `logRetainDays` | 日志保留天数，超期自动删除 |
| `pollSeconds` | 守护进程扫描间隔 |

保存即生效，守护进程和托盘都会在 2 秒内重载，不用重启。

### 加新游戏时怎么找 exe 名

游戏跑起来时执行：

```powershell
Get-Process | Where-Object { $_.MainWindowTitle } |
    Select-Object Name, Id, MainWindowTitle, Path | Format-Table -AutoSize
```

`Name` 加上 `.exe` 就是需要填的值。或者直接在托盘面板里选中它、点「记住为长期规则」。

---

## 命令行

```powershell
# 查看当前状态（哪些配置中的游戏在跑、亲和性对不对）
pwsh -File .\X3D-CCDAffinity.ps1 -Status

# 扫一遍现有进程并立即绑定，不常驻
pwsh -File .\X3D-CCDAffinity.ps1 -Once

# 撤销所有绑定，让进程回到全部核心
pwsh -File .\X3D-CCDAffinity.ps1 -Reset
```

---

## 日志

按天一个文件，不再堆在单个文件里：

```
logs\tray-2026-11-25.log            托盘
logs\x3d-affinity-2026-11-25.log    守护进程
```

- 两个进程都是长驻的，跨零点自动切到新文件，不需要重启
- 保留天数由 `logRetainDays` 控制，切换时顺带删掉超期文件
- 托盘右键 →「打开日志目录」，直接打开 `logs\`
- 托盘空闲时只每 2 分钟写一条心跳，有变化才写详细记录

`logs\tray.lock` 是单实例锁，0 字节，正常现象。

---

## 关于管理员权限

星穹铁道、原神、绝区零、部分反作弊游戏都以**管理员权限**运行。普通权限读它们的
`ProcessorAffinity` 会返回 `0x0`、写入抛 `Access Denied`。所以：

- 托盘必须**以管理员身份**运行才能改这些游戏
- 守护进程（普通权限）对它们只能记录 `拒绝访问`，这是预期行为
- 用 `X3D-Tray-Admin.exe` 启动，或双击 `启动托盘(管理员).cmd`

带反作弊的游戏可能**连管理员也拒绝**修改亲和性。日志里会出现
`could not pin ... Access is denied`。这类游戏只能交给 AMD 驱动处理。

---

## BIOS 建议

即使使用本工具，也建议检查这两项，让 AMD 自己的调度正常工作：

1. **CPPC Dynamic Preferred Cores** → 设成 **Driver**（或 Auto）
2. **AMD 3D V-Cache Performance Optimizer** → **Auto / Enabled**

铭瑄 / 华硕 / 微星等常见路径：
`Advanced → AMD CBS → NBIO Common Options → SMU Common Options`，
或 `Advanced → AMD Overclocking`。

电源计划用 **平衡**。AMD 与微软的官方推荐组合是「平衡 + Game Bar + Game Mode」，
高性能计划在部分版本上会和停泊机制冲突。

---

## 和 Process Lasso 的关系

功能重叠，但本项目免费、开源、无需安装。区别：

- Process Lasso 是通用进程优化器，功能远多于此
- 本项目只做一件事：把指定 exe 钉在指定 CCD，附带一个能看清状态的界面

两者不要同时给同一个游戏设规则，会互相覆盖。

---

## 卸载

```powershell
pwsh -File .\Uninstall-Task.ps1
```

撤销计划任务并结束守护进程。想连托盘一起清掉，在任务管理器结束对应 `pwsh` 进程，
然后删除整个目录即可（不留注册表项、不留系统服务）。

---

## 已知限制

- 只处理 **64 个逻辑处理器以内**的掩码（`0xFFFF` 这类单组掩码），双路/超大核心数型号不适用
- 反作弊游戏可能拒绝修改，属于设计如此，不做绕过
- 掩码是按「CCD0 = CPU 0-15」写的，如果你的型号不同，务必先用 `-Status` 确认再改 `config.json`
- 仅 Windows 10 / 11

## License

MIT
