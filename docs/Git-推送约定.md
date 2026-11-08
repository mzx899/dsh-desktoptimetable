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
