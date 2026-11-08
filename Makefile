APP_NAME    := DesktopTimetable
## 1.3.0 是**次版本**（新功能：设置 → 外观 →「课表大小」滑块，
## 整体等比缩放桌面课表，70% ~ 当前屏幕上限；锚点是卡片中心）。
## 按小版本惯例**不换** bundle id —— 和 1.2.0 ~ 1.2.7 是同一个 App，
## 日历 / 提醒事项授权、登录项、通知身份全部延续，不用重新登记。
BUNDLE_ID   := com.desktoptimetable.app.v120
VERSION     := 1.4.3
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
## 根目录入口的名字带版本号，好和旁边的旧版并存：
##   DesktopTimetable-1.0.0.app —— 旧版（第一代，保留备份用）
##   DesktopTimetable-1.0.1.app —— 第二代（右键编辑）
##   DesktopTimetable-1.3.0.app —— 当前版（日期覆盖层 + 已完成的提醒事项 + 课表大小）
ROOT_APP    := $(APP_NAME)-$(VERSION).app
SOURCES     := $(shell find Sources/DesktopTimetable -name '*.swift')
TEST_SRC    := $(shell find Sources/DesktopTimetable -name '*.swift' ! -name 'main.swift') \
               $(shell find Tests -name '*.swift')
SWIFTC_FLAGS := -O -warnings-as-errors

.PHONY: all build app test verify run run-a clean dmg install

all: app

## 编译可执行文件（只需 Command Line Tools，不需要完整 Xcode）
build:
	@mkdir -p $(BUILD_DIR)
	swiftc $(SWIFTC_FLAGS) -o $(BUILD_DIR)/$(APP_NAME) $(SOURCES)
	@echo "→ $(BUILD_DIR)/$(APP_NAME)"

## 组装 .app bundle
app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp "Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@cp "Resources/Timetable.html" "Resources/Timetable.css" "Resources/Timetable.js" \
	   "Resources/pushpin-outline.png" "Resources/pushpin-solid.png" \
	   "$(APP_BUNDLE)/Contents/Resources/"
	@cp "Resources/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - "$(APP_BUNDLE)" >/dev/null
	@echo "→ $(APP_BUNDLE)"

## 跑测试（自带断言运行器，不依赖 XCTest）
test:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -o $(BUILD_DIR)/tests $(TEST_SRC)
	@$(BUILD_DIR)/tests

## 自检：多课表存储 / 迁移 / 网页渲染 / 快照模式
##
## 用 DT_DATA_DIR 指向临时目录跑，**不碰用户真实课表**。
##
## 注意：DT_DATA_DIR 必须真的传下去。以前这里没设，结果自检直接跑在用户的
## 真实数据目录上 —— 迁移虽然不丢数据（是复制，根目录旧文件仍在），
## 但会平白在真实目录里建出 timetables/，还可能把真实课表当成待迁移数据。
## 临时目录里先拷一份真实课表进去，才能测到「迁移」这条路径本身。
verify: app
	@VDIR=`mktemp -d /tmp/dt-verify-XXXXXX`; \
	 for f in schedule_data.json semester.json config.json; do \
	   cp "$$HOME/Library/Application Support/DesktopTimetable/$$f" "$$VDIR/" 2>/dev/null || true; \
	 done; \
	 echo "自检用临时目录：$$VDIR（不碰真实课表）"; \
	 DT_DATA_DIR="$$VDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-timetables; \
	 echo ""; \
	 echo "── 网页渲染（标题 / 表格 / 冲突标记）──"; \
	 DT_DATA_DIR="$$VDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-web-render; \
	 echo ""; \
	 echo "── 快照模式（B 模式必须是 0 次 takeSnapshot）──"; \
	 DT_DATA_DIR="$$VDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-snapshot-mode; \
	 echo ""; \
	 echo "── 新建/切换课表后立即刷新（同一分钟内读网页标题）──"; \
	 DT_DATA_DIR="$$VDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-switch-refresh; \
	 echo ""; \
	 echo "── 设置面板必须从顶部开始显示（文档视图要 flipped）──"; \
	 PVDIR2=`mktemp -d /tmp/dt-ps-XXXXXX`; \
	 cp "$$HOME/Library/Application Support/DesktopTimetable/config.json" "$$PVDIR2/" 2>/dev/null || true; \
	 DT_DATA_DIR="$$PVDIR2" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-panel-scroll; \
	 rm -rf "$$PVDIR2"; \
	 echo ""; \
	 echo "── 设置面板两级结构（板块首页 → 分类设置页）──"; \
	 SVDIR=`mktemp -d /tmp/dt-sect-XXXXXX`; \
	 DT_DATA_DIR="$$SVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-panel-sections; \
	 SECT_RC=$$?; \
	 rm -rf "$$SVDIR"; \
	 if [ $$SECT_RC -ne 0 ]; then \
	   echo "❌ 设置面板两级结构自检没通过（退出码 $$SECT_RC）"; \
	   exit 1; \
	 fi
	 echo ""; \
	 echo "── 真实鼠标点击板块按钮（不能点不中）──"; \
	 CVDIR=`mktemp -d /tmp/dt-click-XXXXXX`; \
	 DT_DATA_DIR="$$CVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-panel-click; \
	 CLICK_RC=$$?; \
	 rm -rf "$$CVDIR"; \
	 if [ $$CLICK_RC -ne 0 ]; then \
	   echo "❌ 板块按钮点击自检没通过（退出码 $$CLICK_RC）"; \
	   exit 1; \
	 fi
	 echo ""; \
	 echo "── 扩张/收缩动画（中心全程不动）──"; \
	 AVDIR=`mktemp -d /tmp/dt-anim-XXXXXX`; \
	 DT_DATA_DIR="$$AVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-panel-animation; \
	 ANIM_RC=$$?; \
	 rm -rf "$$AVDIR"; \
	 if [ $$ANIM_RC -ne 0 ]; then \
	   echo "❌ 面板动画自检没通过（退出码 $$ANIM_RC）"; \
	   exit 1; \
	 fi
	 echo ""; \
	 echo "── 切换课表后课程预览立即重绘（表格行数要跟着变）──"; \
	 PVDIR=`mktemp -d /tmp/dt-pv-XXXXXX`; \
	 cp "$$HOME/Library/Application Support/DesktopTimetable/config.json" "$$PVDIR/" 2>/dev/null || true; \
	 DT_DATA_DIR="$$PVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-preview-refresh; \
	 rm -rf "$$PVDIR"; \
	 rm -rf "$$VDIR"; \
	 echo ""; \
	 echo "── 单周临时覆盖（两道关 / 写盘 / 撤销）──"; \
	  OVDIR=`mktemp -d /tmp/dt-ov-XXXXXX`; \
	 printf '%s' '[{"name":"高等数学","day":3,"block":1,"weeks":[1,2,3,4,5,6,7,8],"weeksLabel":"1-8","courseID":"M1","code":"","teacher":"李雷","loc":"教三-201"},{"name":"大学英语","day":1,"block":0,"weeks":[1,2,3,4,5,6],"weeksLabel":"1-6","courseID":"E1","code":"","teacher":"韩梅梅","loc":"外语-102"},{"name":"体育","day":3,"block":1,"weeks":[1,2],"weeksLabel":"1-2","courseID":"P1","code":"","teacher":"李雷","loc":"操场"}]' > "$$OVDIR/schedule_data.json"; \
	 printf '{"start":"%s","maxWeek":16}' "$$(date -v-14d +%Y-%m-%d)" > "$$OVDIR/semester.json"; \
	 DT_DATA_DIR="$$OVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-override-flow; \
	 rm -rf "$$OVDIR";
	 @echo "";
	 @echo "── 覆盖导入（来源保护 / 逐条冲突 / 真正写盘 / 焦点恢复）──"; \
	 IMDIR=`mktemp -d /tmp/dt-import-XXXXXX`; \
	 DT_DATA_DIR="$$IMDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-import-flow; \
	 IMPORT_RC=$$?; \
	 rm -rf "$$IMDIR"; \
	 if [ $$IMPORT_RC -ne 0 ]; then \
	   echo "❌ 覆盖导入自检没通过（退出码 $$IMPORT_RC）"; \
	   exit 1; \
	 fi
	 @echo "";
	 @echo "── 真机焦点闭环（经 LaunchServices 启动，验 key window + 真实点击）──"; \
	 FDIR=`mktemp -d /tmp/dt-focus-XXXXXX`; \
	 DT_DATA_DIR="$$FDIR" DT_FOCUS_REPORT="$$FDIR/report.txt" \
	   open -n "$(APP_BUNDLE)" --env DT_DATA_DIR="$$FDIR" --env DT_FOCUS_REPORT="$$FDIR/report.txt" \
	        --args --verify-focus-flow; \
	 for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
	   [ -f "$$FDIR/report.txt" ] && break; \
	   sleep 1; \
	 done; \
	 if [ -f "$$FDIR/report.txt" ]; then \
	   cat "$$FDIR/report.txt"; \
	 else \
	   echo "❌ 真机焦点自检没有产出报告（app 可能没起来）"; \
	   rm -rf "$$FDIR"; exit 1; \
	 fi; \
	 if grep -q "✅" "$$FDIR/report.txt"; then \
	   rm -rf "$$FDIR"; \
	 else \
	   echo "❌ 真机焦点闭环没通过"; \
	   rm -rf "$$FDIR"; exit 1; \
	 fi
	@echo "";
	@echo "── 统一设置层 + 上课提醒规划（不请求权限 / 不注册登录项）──"; \
	 RMDIR=`mktemp -d /tmp/dt-rm-XXXXXX`; \
	 printf '[{"name":"高等数学","day":%s,"block":0,"weeks":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16],"weeksLabel":"1-16","courseID":"M1","code":"","teacher":"李雷","loc":"教三-201"}]' "$$(date -v+1d +%u)" > "$$RMDIR/schedule_data.json"; \
	 printf '{"start":"%s","maxWeek":16}' "$$(date -v-14d +%Y-%m-%d)" > "$$RMDIR/semester.json"; \
	 DT_DATA_DIR="$$RMDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-reminder-plan; \
	 rm -rf "$$RMDIR";
	@echo "";
	@echo "── 设置面板「提醒与启动」卡片（原有卡片不能被改坏）──"; \
	 SCDIR=`mktemp -d /tmp/dt-sc-XXXXXX`; \
	 DT_DATA_DIR="$$SCDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-settings-card; \
	 rm -rf "$$SCDIR";
	@echo "";
	@echo "── 「提前提醒」下拉框的自定义分钟数 ──"; \
	 LCDIR=`mktemp -d /tmp/dt-lc-XXXXXX`; \
	 DT_DATA_DIR="$$LCDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-lead-custom; \
	 LCRC=$$?; \
	 rm -rf "$$LCDIR"; \
	 if [ $$LCRC -ne 0 ]; then echo "❌ 自定义提前提醒自检没通过"; exit 1; fi
	@echo "";
	@echo "── 面板内层滚动视图的滚轮要交给外层面板 ──"; \
	 WVDIR=`mktemp -d /tmp/dt-wh-XXXXXX`; \
	 cp "$$HOME/Library/Application Support/DesktopTimetable/config.json" "$$WVDIR/" 2>/dev/null || true; \
	 DT_DATA_DIR="$$WVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-wheel-routing; \
	 rm -rf "$$WVDIR";
	 @echo "";
	 @echo "── 「在访达中显示」时面板给访达让路（层级 / 步骤顺序）──"; \
	  FRVDIR=`mktemp -d /tmp/dt-fr-XXXXXX`; \
	  DT_DATA_DIR="$$FRVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-finder-reveal; \
	  rm -rf "$$FRVDIR";
	 @echo "";
	 @echo "── 悬停判定（桌面窗口不算遮挡 / 被盖住要淡出）──"; \
	  HVDIR=`mktemp -d /tmp/dt-hv-XXXXXX`; \
	  DT_DATA_DIR="$$HVDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-hover; \
	  HV_RC=$$?; \
	  rm -rf "$$HVDIR"; \
	  if [ $$HV_RC -ne 0 ]; then echo "❌ 悬停判定自检没通过（退出码 $$HV_RC）"; exit 1; fi
	 @echo "";
	 @echo "── 课表图钉固定（拖动 / 固定 / 位置记忆 / 弹窗锚点）──"; \
	 PINDIR=`mktemp -d /tmp/dt-pin-XXXXXX`; \
	 DT_DATA_DIR="$$PINDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-pin-flow; \
	 PIN_RC=$$?; \
	 rm -rf "$$PINDIR"; \
	 if [ $$PIN_RC -ne 0 ]; then echo "❌ 图钉固定自检没通过（退出码 $$PIN_RC）"; exit 1; fi
	 @echo "";
	 @echo "── 日期覆盖层（农历 / 锚点 / 状态机 / EventKit / 护栏）──"; \
	 DPDIR=`mktemp -d /tmp/dt-dp-XXXXXX`; \
	 DT_DATA_DIR="$$DPDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-day-panel; \
	 DP_RC=$$?; \
	 rm -rf "$$DPDIR"; \
	 if [ $$DP_RC -ne 0 ]; then echo "❌ 日期覆盖层自检没通过（退出码 $$DP_RC）"; exit 1; fi
	 @echo "";
	 @echo "── 已完成的提醒事项（收起不读取 / 恢复 / 删除 / 批量 / 权限）──"; \
	 CRDIR=`mktemp -d /tmp/dt-cr-XXXXXX`; \
	 DT_DATA_DIR="$$CRDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-completed-reminders; \
	 CR_RC=$$?; \
	 rm -rf "$$CRDIR"; \
	 if [ $$CR_RC -ne 0 ]; then echo "❌ 已完成的提醒事项自检没通过（退出码 $$CR_RC）"; exit 1; fi
	 @echo "";
	 @echo "── 日期覆盖层真实点击 + 原生推送不能重建表头（「表头闪」回归）──"; \
	 DPCIDIR=`mktemp -d /tmp/dt-dpc-XXXXXX`; \
	 DT_DATA_DIR="$$DPCIDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-day-panel-click; \
	 DPCI_RC=$$?; \
	 rm -rf "$$DPCIDIR"; \
	 if [ $$DPCI_RC -ne 0 ]; then echo "❌ 日期覆盖层真实点击自检没通过（退出码 $$DPCI_RC）"; exit 1; fi
	 @echo "";
	 @echo "── 真按键进网页输入框（key window → first responder → 输入框）──"; \
	 TYDIR=`mktemp -d /tmp/dt-typing-XXXXXX`; \
	 DT_DATA_DIR="$$TYDIR" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" --verify-typing; \
	 TY_RC=$$?; \
	 rm -rf "$$TYDIR"; \
	 if [ $$TY_RC -ne 0 ]; then echo "❌ 文本输入自检没通过（退出码 $$TY_RC）"; exit 1; fi

## 编译并启动（默认 B：网页直接上屏）
run: app
	@open "$(APP_BUNDLE)"

## 以 A 模式启动（快照贴图），用于回归测试
run-a: app
	@DT_SNAPSHOT=1 "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"

## 安装到项目根目录
##
## 根目录并排放两个 App：
##   DesktopTimetable-1.0.0.app —— 旧版（第一代，保留备份用）
##   DesktopTimetable-1.0.1.app —— 第二代（右键编辑）
##   DesktopTimetable-1.2.3.app —— 当前版（日期覆盖层 + 已完成的提醒事项）
##
## A/B 不是两份源码，而是同一份源码的两种渲染模式：
##   · B = 默认，网页直接上屏
##   · A = DT_SNAPSHOT=1，快照贴图
##
## `make app` 只重建 build/ 里的产物；改完代码要 `make install` 才会同步到根目录入口。
install: app
	@rm -rf "$(ROOT_APP)"
	@ditto "$(APP_BUNDLE)" "$(ROOT_APP)"
	@echo "→ 已安装：$(ROOT_APP)（当前版，B 模式）"

## 打包 dmg
dmg: app
	@rm -f "$(BUILD_DIR)/$(APP_NAME).dmg"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP_BUNDLE)" \
		-ov -format UDZO "$(BUILD_DIR)/$(APP_NAME).dmg"
	@echo "→ $(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf .build "$(BUILD_DIR)"
