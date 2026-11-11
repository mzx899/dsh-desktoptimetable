# Git 推送约定（2026-11-08 起）

## 仓库

- 远端：`https://github.com/mzx899/dsh-desktoptimetable.git`
- **只推 `code` 分支。`main` 绝对不动**（远端 main 与 code 当前都是初始提交，
  我们永不推送 main；导出仓库已把 push refspec 锁成 `code:code`，
  哪怕手滑敲 `git push` 也只会动 code）。

## 从哪儿推

- 推送源不是项目根目录，而是 **`推送仓库/`**：由 `rsync` 从项目里导出，
  只含源码 / 网页资源 / 测试 / 文档 / 构建脚本。
- 排除项（必须留在外面）：`build/`、`版本迭代/`（94MB 归档）、
  `.frames_analysis/`（108MB 临时分析）、`.DS_Store`、`*.bak`。

同步命令（在项目根目录执行）：

```bash
rsync -a --exclude='.DS_Store' --exclude='*.bak' \
  Sources Resources Tests docs scripts .github \
  Makefile Package.swift README.md CHANGELOG.md LICENSE .gitignore \
  "推送仓库/"
```

## 什么时候问用户

**只在新任务开始时、且这次是大版本跃迁（次版本 x.(y+1).0 或 2.0）时问一次**
「要不要提交到 git」。补丁版（x.y.z+1）**不问、不推送** —— 改动照常写进
CHANGELOG / 文档，等下一次大版本跃迁时一起推。

## 首次推送记录（2026-11-08）

- 远端改用 **SSH**（`git@github.com:mzx899/dsh-desktoptimetable.git`）：
  HTTPS 没有写入凭据（`No anonymous write access`），
  SSH key（`~/.ssh/id_ed25519`）已验证为 `Hi mzx899!`。
- 推送：`c9e48e1..ecb4573  code -> code`（快进，没有 force）。
- 结果：`code` = `ecb4573`（142 个文件），`main` 仍停在 `c9e48e1`，**没动**。
- 验证：`git clone -b code` 到 `/tmp` → `make app` 通过、`make test` **2052 项断言全过**
  （证明仓库里这份源码完整、可编译）。

## 第二次推送记录（2026-11-11）

- 触发：用户明确要求「推送到仓库」（这次是 1.5.3 之后的累积推送，不是版本跃迁）。
- 推送内容：`af8c28a..eadba21  code -> code`（快进，没有 force），**50 个文件**，
  覆盖 1.5.4 ~ 1.5.9 + `[未发布]` 里的全部改动
  （天气卡 / 日记改日期 / 面板文字不可框选 / 面板不透明度 50% 居中 /
  弹窗锚点 / 窗口层级 / 设置面板首次打开位置修复 …）。
- 结果：`code` = `eadba21`（218 个文件），`main` 仍停在 `c9e48e1 Initial commit`，**没动**。
- 推送前后自检：
  - `git status` 里没有 `build/`、`版本迭代/`、`.frames_analysis/`、`.DS_Store`、`*.bak`；
  - `推送仓库/` 这份副本自己 `make app` 通过、`make test` **2220 项断言全过**；
  - `git clone -b code` 到 `/tmp/dt-check` → `make app` 通过、
    `make test` **2220 项断言全过**，本轮新自检 `--verify-settings-first-open` 也 ✅；
  - `.git` 体积 11M（`git ls-files | wc -l` = 168 → 推送后 218）。

## 推送步骤（用户同意后）

```bash
cd "推送仓库"
# 1. 先同步一次（见上面的 rsync）
# 2. 提交（消息里带版本号）
git add -A
git commit -m "DesktopTimetable <版本>：<一句话摘要>"
# 3. 只推 code（refspec 已锁，写全也只是保险）
git push origin code
```

推送前自检：

- `git status` 里不应出现 `build/`、`版本迭代/`、`.frames_analysis/`；
- `git ls-files | wc -l` 约 141（源码全量）；`du -sh .git` 应在几 MB；
- 推完可以 `git clone -b code <仓库> /tmp/check && cd /tmp/check && make test`
  —— 能编译 + 2046+ 断言通过，才算「真的没缺源码」。
