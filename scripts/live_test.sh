#!/bin/bash
# B 模式运行时自检：启动 app（DT_LIVE_TEST=1），等 live 测试跑完，
# 把结果从 /tmp/tt_live_results.txt 拷到指定路径，然后结束 app。
#
# 用法：
#   ./scripts/live_test.sh                    # 自动准备一份带课表的临时数据
#   ./scripts/live_test.sh <数据目录> <输出文件>
#
# 关键：**必须让临时目录里有课表数据**。
# 空目录启动的话，课表是空的，网页只渲染出 70 个空格子、0 门课，
# 于是「点击课程格」「悬停课程格」「右键出课程菜单」「查看详情」「编辑器窗口」
# 这一批全都会 FAIL —— 那是「没东西可点」，不是代码坏了。
# （曾经真踩过这个坑：一次 live 测试 5 个 FAIL，根因是临时目录没拷数据。）
set -u
cd "$(dirname "$0")/.."

OUT="${2:-/tmp/tt_live_results.txt}"
APP=./build/DesktopTimetable.app/Contents/MacOS/DesktopTimetable
REAL_DATA="$HOME/Library/Application Support/DesktopTimetable"

if [ -n "${1:-}" ]; then
    DATA_DIR="$1"
else
    # 自建临时目录，并把真实课表拷进去（拷副本，不动原件）。
    DATA_DIR="$(mktemp -d /tmp/dt-livetest-XXXXXX)"
    trap 'rm -rf "$DATA_DIR"' EXIT
    for f in schedule_data.json semester.json config.json; do
        [ -f "$REAL_DATA/$f" ] && cp "$REAL_DATA/$f" "$DATA_DIR/"
    done
    if [ ! -f "$DATA_DIR/schedule_data.json" ]; then
        echo "没找到真实课表数据（$REAL_DATA/schedule_data.json），live 测试会因空课表而误报" >&2
        exit 1
    fi
    echo "临时数据目录：${DATA_DIR}（已拷入真实课表副本）"
fi

rm -f /tmp/tt_live_results.txt "$OUT"
export DT_LIVE_TEST=1
export DT_LIVE_EXIT=1
export DT_DATA_DIR="$DATA_DIR"

"$APP" > /tmp/tt_live_stdout.txt 2>&1 &
APP_PID=$!

for i in $(seq 1 40); do
    [ -f /tmp/tt_live_results.txt ] && break
    kill -0 $APP_PID 2>/dev/null || break
    sleep 1
done

# DT_LIVE_EXIT=1 会让 app 跑完自己退出；等它，超时就强杀。
for i in $(seq 1 5); do
    kill -0 $APP_PID 2>/dev/null || break
    sleep 1
done
kill $APP_PID 2>/dev/null
wait $APP_PID 2>/dev/null

if [ -f /tmp/tt_live_results.txt ]; then
    # 输出路径可能就是结果文件本身，那样 cp 会报 "identical (not copied)"。
    if [ "$OUT" != "/tmp/tt_live_results.txt" ]; then
        cp /tmp/tt_live_results.txt "$OUT"
    fi
    echo "results -> $OUT"
    echo "---- 成绩 ----"
    grep -E "^FAIL" "$OUT" || echo "全部 PASS（无 FAIL 行）"
    grep -cE "^PASS" "$OUT" | sed 's/^/PASS 项数：/'
    grep -cE "^FAIL" "$OUT" | sed 's/^/FAIL 项数：/'
else
    echo "没有产生结果文件"
    tail -30 /tmp/tt_live_stdout.txt
    exit 1
fi
