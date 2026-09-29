# ZCode-Deploy

ZCode 人格部署工具 — 一键把 system prompt 整层换成你自己的越狱词。

> **本仓库是 [zzooymc-source/ZCode-Deploy](https://github.com/zzooymc-source/ZCode-Deploy) 的修改版（fork）。**
> 原项目提供了 ZCode system prompt 替换的原始实现；本仓库修复了
> ZCode 2026-09-19 重新打包后补丁全部失效的问题，并补齐了校验与发布流程。

## 这是什么

针对 ZCode 的 system prompt 替换工具。

ZCode 的 system prompt 由 `zcode.cjs` 拼装，包含产品身份声明（"You are ZCode"）、
安全策略、上下文管理规则、日期提醒等注入内容。本工具修改这些注入点，
把整个 system 层替换为 `人格.txt` 的内容 —— 你的词直接成为唯一的 system prompt。

部署后模型收到的请求：

```
system:   人格.txt（唯一）
messages: 正常对话
tools:    工具定义（不变）

不含 "You are ZCode"
不含产品安全策略
不含上下文管理规则
不含日期提醒
不含 Skills 列表
```

## 使用

1. （可选）把 `人格.txt` 换成你自己的词（UTF-8）
2. 双击 `部署.bat`
3. 开新对话，生效

命令行方式：

```powershell
powershell -ExecutionPolicy Bypass -File deploy.ps1 install    # 部署
powershell -ExecutionPolicy Bypass -File deploy.ps1 restore    # 恢复原版
powershell -ExecutionPolicy Bypass -File deploy.ps1 status     # 查看状态
powershell -ExecutionPolicy Bypass -File deploy.ps1 diag       # 注入点诊断
```

## 换人格

直接编辑 `人格.txt`，保存，开新对话生效。不需要重启，不需要重跑部署。

## 原理

对 `zcode.cjs` 做六个补丁。**锚点按语义字面量定位，不依赖压缩后的变量名**，
所以 ZCode 更新重命名内部变量后依然有效：

| # | 定位锚点（稳定字面量） | 修改内容 | 作用 |
|---|------------------------|----------|------|
| 1 | `"You are ZCode, an interactive coding agent"` | 赋值改为空串 | 删除产品身份声明 |
| 2 | `this.config.customSystemPrompt?.trim()` | 改为 `readFileSync(人格.txt)` | system prompt 换成外部文件 |
| 3 | `name:"Agent Identity",source:"identity"` | 所在函数改读外部文件 | Agent Identity 片段同步替换 |
| 4 | `name:"Current Date",source:"current_date"` | 所在函数开头插 `return null;` | 移除日期提醒注入 |
| 5 | `name:"Skills",source:"skills"` | 同上 | 移除 Skills 列表注入 |
| 6 | `name:"Request User Context"` | 同上 | 移除 User Context 注入 |

定位方式：找到锚点字面量后，用**花括号配平**回溯出真正包住它的那个函数，再对其动手。
这样即使 ZCode 把 `Djo` 改名成 `FVs`、把 `Eut` 改名成 `Qfn`，补丁照样命中。

补丁 2 利用产品自带的 `customSystemPrompt` 入口。ZCode 在设置了该入口时会自动跳过
System Context / Environment Info / Memory 等片段，所以一个补丁就清掉了大半注入。

## 安全设计（v2）

| 机制 | 说明 |
|------|------|
| 失败即中止 | 任一补丁未命中就**不写入**，退出码 1，并打印注入点诊断 |
| 语法校验 | 写入前用 `node --check` 校验补丁结果，不通过绝不落盘 |
| 原子性 | 校验通过才覆盖 `zcode.cjs`；原文件在被覆盖前已归档 |
| 幂等 | 重复跑 install 全部报「跳过」，不会重复注入 |
| 备份轮转 | 每次操作把当前文件归档到 `backups` 目录，保留最近 6 份 |
| 备份保鲜 | ZCode 更新后 `.bak` 自动刷新为新版原版，**restore 不会再降级应用** |

## 验证

两步，都很快：

```
验证.bat
```

它会做两件事：

1. `deploy.ps1 diag` —— 列出 cjs 里全部 10 个注入片段及其产物函数
2. `verify-patch.cjs` —— **真正执行**补丁后的函数，确认：
   - 注入的读取表达式确实读得到 `人格.txt`
   - 日期 / Skills / User Context 三个函数实际返回 `null`
   - CLI Prefix 实际返回空串
   - Agent Identity 的 content 就是 `人格.txt` 全文

也可以直接看 ZCode 的模型请求日志：

```
%USERPROFILE%\.zcode\cli\rollout\model-io-*.jsonl
```

检查点：system 层应为 `人格.txt` 全文，且不含 `You are ZCode`、不含安全策略、不含日期提醒。

## 注意

- **ZCode 更新后**：重跑 `部署.bat` 即可。更新会覆盖 `zcode.cjs`，脚本会自动识别新版原版、
  刷新备份、重新打补丁。如果新版连注入点结构都变了，脚本会**明确报错并给出诊断**，
  不会再像旧版那样「静默无效果」。
- **文件夹移动后**：需要重跑 `部署.bat`（人格文件路径写死在 cjs 里）。
- **`deploy.ps1` 必须保持 UTF-8 with BOM 编码**。它含中文，而 Windows PowerShell 5.1 对无 BOM 的
  脚本按系统 ANSI（GBK）解码，会把中文字节连同后面的引号一起吃掉并报 `Unexpected token` 语法错。
  用 VS Code 改脚本时请设置 `"files.encoding": "utf8bom"`。
- **安装路径检测**：优先用运行中的 ZCode 进程路径，其次 `ZCODE_DIR` 环境变量，
  其次常见位置（含 `D:\app\zcode`），最后扫盘。检测结果缓存到 `zcode-dir.txt`。
- 仅修改本地安装的软件，不触碰服务端。

## 文件说明

```
部署.bat            一键部署
恢复.bat            恢复原版
查看状态.bat        查状态
验证.bat            诊断 + 功能验证
deploy.ps1          主脚本（install / restore / status / diag）
verify-patch.cjs    功能验证器（真正执行补丁后的函数）
人格.txt            人格文件（唯一编辑入口）
backups             原版归档目录（保留最近 6 份，restore 失败时可手动挑）
zcode-dir.txt       上次检测到的 ZCode 目录缓存
修改记录.md         完整技术分析与变更记录
```

## 来源与致谢

本仓库是 **[zzooymc-source/ZCode-Deploy](https://github.com/zzooymc-source/ZCode-Deploy)** 的修改版，原仓库地址：
https://github.com/zzooymc-source/ZCode-Deploy

原项目完成了基础工作：定位 ZCode 的 system prompt 拼装入口、发现 `customSystemPrompt`
这个产品自带的合法注入点、验证整层替换的可行性。本仓库在其之上做了以下改动：

| | 原仓库 v1 | 本仓库 v2.0.0 |
|---|---|---|
| 补丁锚点 | 压缩变量名硬编码（`Djo` / `Eut` / `fre` …） | 语义字面量 + 花括号配平定位 |
| 补丁未命中 | 黄色警告，仍然写入并报「部署完成」 | 中止、退出码 1、打印注入点诊断 |
| 写入前校验 | 无 | `node --check` 语法门禁，不通过不落盘 |
| 备份策略 | `.bak` 固定为首次部署版本 | 自动刷新，restore 不再降级应用 |
| 验证手段 | 人工翻模型请求日志 | `verify-patch.cjs` 真正执行补丁后的函数 |
| 发布流程 | 手动打包 | `build-release.ps1` 白名单打包 + SHA256 清单 |

## 免责声明

本工具仅用于修改本地安装的软件配置。请遵守 ZCode 服务条款，自行承担使用风险。
