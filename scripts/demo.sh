#!/usr/bin/env bash
# hinomi に fake イベントを流して UI を確認する。
#
#   ./scripts/demo.sh          全部（3セッション分の一連の流れ → 許可待ちの実演）
#   ./scripts/demo.sh basic    セッション開始〜実行中〜完了まで
#   ./scripts/demo.sh notify   入力待ち・許可要求（Notification 経由）
#   ./scripts/demo.sh ask      PreToolUse の Allow/Deny（notch のボタンが出る／応答を待つ）
#   ./scripts/demo.sh clean    デモ用セッションを一覧から消す
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find_hook() {
  if [[ -n "${HINOMI_HOOK:-}" ]]; then echo "$HINOMI_HOOK"; return; fi
  for candidate in \
    "$ROOT/build/hinomi.app/Contents/MacOS/hinomi-hook" \
    "$ROOT/.build/release/hinomi-hook" \
    "$HOME/Applications/hinomi.app/Contents/MacOS/hinomi-hook" \
    "/Applications/hinomi.app/Contents/MacOS/hinomi-hook"; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return; }
  done
  echo ""
}

HOOK="$(find_hook)"
if [[ -z "$HOOK" ]]; then
  echo "hinomi-hook が見つかりません。先に 'make build' か 'make app' を実行してください。" >&2
  exit 1
fi

SOCKET="${HINOMI_SOCKET:-$HOME/.hinomi/hinomi.sock}"
if [[ ! -S "$SOCKET" ]]; then
  echo "警告: $SOCKET が見当たりません。hinomi.app を起動してから試してください。" >&2
fi

send() {  # send <mode> <json>
  printf '%s' "$2" | "$HOOK" "$1"
}

demo_basic() {
  echo "==> セッション開始 3件（iTerm2 / Ghostty / Terminal）"
  TERM_PROGRAM="iTerm.app" send event '{"session_id":"hinomi-demo-1","cwd":"'"$HOME"'/work/astro-blog","hook_event_name":"SessionStart","source":"startup"}'
  TERM_PROGRAM="ghostty" send event '{"session_id":"hinomi-demo-2","cwd":"'"$HOME"'/work/zaiko-watch","hook_event_name":"SessionStart","source":"startup"}'
  TERM_PROGRAM="Apple_Terminal" send event '{"session_id":"hinomi-demo-3","cwd":"'"$HOME"'/work/hinomi","hook_event_name":"SessionStart","source":"resume"}'
  sleep 1

  echo "==> 指示を投入 → 実行中に"
  TERM_PROGRAM="iTerm.app" send event '{"session_id":"hinomi-demo-1","cwd":"'"$HOME"'/work/astro-blog","hook_event_name":"UserPromptSubmit","prompt":"記事を書いて"}'
  TERM_PROGRAM="ghostty" send event '{"session_id":"hinomi-demo-2","cwd":"'"$HOME"'/work/zaiko-watch","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm run build && npm test -- --watch=false"}}'
  sleep 1

  echo "==> 1件だけ完了（Stop → 効果音＋ハイライト）"
  TERM_PROGRAM="Apple_Terminal" send event '{"session_id":"hinomi-demo-3","cwd":"'"$HOME"'/work/hinomi","hook_event_name":"Stop","stop_reason":"end_turn","last_assistant_message":"ビルドとテストが通りました"}'
}

demo_notify() {
  echo "==> 入力待ち（Notification: idle_prompt）"
  TERM_PROGRAM="iTerm.app" send event '{"session_id":"hinomi-demo-1","cwd":"'"$HOME"'/work/astro-blog","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
  sleep 1
  echo "==> 許可要求（Notification: permission_prompt）"
  TERM_PROGRAM="ghostty" send event '{"session_id":"hinomi-demo-2","cwd":"'"$HOME"'/work/zaiko-watch","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
}

demo_ask() {
  echo "==> PreToolUse (ask): notch に「許可 / 拒否」が出ます。押すか、放置してタイムアウトさせてください。"
  echo "    （このコマンドは応答が返るまでブロックします＝本番の hook と同じ挙動）"
  local out
  out="$(TERM_PROGRAM="ghostty" send ask '{"session_id":"hinomi-demo-2","cwd":"'"$HOME"'/work/zaiko-watch","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_demo","tool_input":{"command":"rm -rf ./build && npm run deploy"}}')"
  if [[ -z "$out" ]]; then
    echo "<-- 出力なし（decision なし＝通常の許可フローに流れる）"
  else
    echo "<-- Claude Code に返す JSON:"
    echo "$out"
  fi
}

demo_clean() {
  echo "==> デモ用セッションを終了させる"
  for id in hinomi-demo-1 hinomi-demo-2 hinomi-demo-3; do
    send event '{"session_id":"'"$id"'","hook_event_name":"SessionEnd","end_reason":"other"}'
  done
}

case "${1:-all}" in
  basic) demo_basic ;;
  notify) demo_notify ;;
  ask) demo_ask ;;
  clean) demo_clean ;;
  all)
    demo_basic
    sleep 1
    demo_notify
    sleep 1
    demo_ask
    echo
    echo "後片付け: ./scripts/demo.sh clean"
    ;;
  *)
    echo "usage: $0 [all|basic|notify|ask|clean]" >&2
    exit 64
    ;;
esac
