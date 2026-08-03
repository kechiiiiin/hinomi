.PHONY: help build debug test app install update uninstall run install-hooks uninstall-hooks status demo clean

APP_DIR ?= $(HOME)/Applications
APP := build/hinomi.app
INSTALLED := $(APP_DIR)/hinomi.app

help:
	@echo "hinomi — Claude Code セッションを画面上部で見張る常駐アプリ"
	@echo ""
	@echo "  make build            リリースビルド（swift build -c release）"
	@echo "  make test             ユニットテスト（swift test）"
	@echo "  make app              hinomi.app を組み立てて ad-hoc 署名"
	@echo "  make install          $(APP_DIR) に hinomi.app を配置して起動"
	@echo "  make update           git pull → test → install（更新はこれ一本で）"
	@echo "  make install-hooks    ~/.claude/settings.json に hooks を非破壊マージ"
	@echo "  make uninstall-hooks  追記した hooks を除去"
	@echo "  make status           socket / hooks の状況を表示"
	@echo "  make demo             fake イベントを流して UI を確認"
	@echo "  make uninstall        アプリを終了して $(APP_DIR) から削除"
	@echo "  make clean            ビルド生成物を削除"

build:
	swift build -c release

debug:
	swift build

test:
	swift test

app:
	bash scripts/build-app.sh

install: app
	@pkill -x hinomi 2>/dev/null || true
	@mkdir -p "$(APP_DIR)"
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
	@echo "==> 配置: $(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "==> 起動しました（メニューバーの炎アイコン）"
	@echo "    次に: make install-hooks"

# 取り込み → 検証 → 入れ替えを一本にする。--ff-only なので、ローカルに
# コミットが残っていれば pull で止まる（勝手に merge させない）
update:
	git pull --ff-only
	$(MAKE) test
	$(MAKE) install

run: build
	.build/release/hinomi

install-hooks:
	@if [ -x "$(INSTALLED)/Contents/MacOS/hinomi" ]; then \
		"$(INSTALLED)/Contents/MacOS/hinomi" install-hooks; \
	else \
		swift build -c release >/dev/null && .build/release/hinomi install-hooks; \
	fi

uninstall-hooks:
	@if [ -x "$(INSTALLED)/Contents/MacOS/hinomi" ]; then \
		"$(INSTALLED)/Contents/MacOS/hinomi" uninstall-hooks; \
	else \
		swift build -c release >/dev/null && .build/release/hinomi uninstall-hooks; \
	fi

status:
	@if [ -x "$(INSTALLED)/Contents/MacOS/hinomi" ]; then \
		"$(INSTALLED)/Contents/MacOS/hinomi" status || true; \
	else \
		swift build -c release >/dev/null && .build/release/hinomi status || true; \
	fi

demo:
	bash scripts/demo.sh

uninstall:
	@pkill -x hinomi 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@echo "==> 削除: $(INSTALLED)（hooks は make uninstall-hooks で外してください）"

clean:
	swift package clean
	rm -rf .build build
