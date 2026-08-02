# hinomi（火の見）

複数の Claude Code セッションを、画面上部（ノッチ位置）の小さなオーバーレイで見張る macOS 常駐アプリ。
「どのセッションが動いていて、どれが自分を待たせているか」を、ターミナルを覗きに行かずに把握するための道具です。

- メニューバー常駐（Dock アイコンなし・`LSUIElement`）
- Claude Code の hooks から状態を受け取る（ポーリングなし）
- 完了・許可待ちで効果音＋ハイライト
- 行クリックでそのターミナルアプリを前面に
- 許可要求（`PermissionRequest`）に notch から **許可 / 拒否** を返せる（実際に許可を聞かれる場面でのみ表示）

個人用 MVP です。着想は [vibeisland](https://vibeisland.app/) の「画面上部でエージェントを見張る」という発想のみ。コード・ブランド・アセットは一切無関係の独立実装です。

---

## 必要環境

- macOS 14 以降（Apple Silicon / Intel どちらも。ノッチ有無は自動で吸収します）
- Swift 6 系ツールチェイン（Xcode か Command Line Tools）
- Claude Code（hooks が使えるバージョン）

## 導入

必要なもの: macOS 14+、Swift ツールチェイン（Xcode か Command Line Tools: `xcode-select --install`）、Claude Code。

```bash
gh auth login   # 未認証なら（kechiiiiin でブラウザ認証）
gh repo clone kechiiiiin/hinomi ~/work/hinomi
cd ~/work/hinomi

make test            # ユニットテスト
make install         # hinomi.app を組み立てて ~/Applications に配置し、起動する
make install-hooks   # ~/.claude/settings.json に hooks を非破壊マージ
```

`make install-hooks` の後、**既に開いている Claude Code は開き直してください**（hooks は起動時に読まれます）。

状況確認:

```bash
make status
# socket:  /Users/you/.hinomi/hinomi.sock
# 待ち受け: あり（アプリ起動中）
# hooks:   導入済み (/Users/you/.claude/settings.json)
# 許可UI:  有効 / 待ち 15秒 / matcher 全ツール
```

ログイン時に自動起動させたいときは、システム設定 → 一般 → ログイン項目 に `~/Applications/hinomi.app` を追加してください。

## 使い方

- **通常は畳んだ小さなピル**（炎アイコン＋セッション数＋状態ドット）。セッションが1件も無ければ引っ込みます
- **マウスを乗せると展開**して一覧が出ます。完了・許可待ちのイベントが来たときは自動で数秒開きます
- 一覧の各行: タイトル／プロジェクト名／状態／最終イベントからの経過／ターミナル名／直近の活動
- タイトルの優先順: **デスクトップアプリのセッションタイトル**（`~/Library/Application Support/Claude/claude-code-sessions` から `cliSessionId` で照合・15秒ごとに再取得）> 直近のユーザープロンプト > プロジェクト名。ターミナル起動のセッションはアプリのタイトルを持たないので、プロンプトが見出しになります
- **行をクリック**すると、そのセッションのターミナルアプリが前面に出ます（iTerm2 / Terminal.app / Ghostty / WezTerm / kitty / Alacritty / Warp / Hyper / VS Code / Cursor）。タブ単位のジャンプはしません
- 状態の色: 許可待ち=橙 / 入力待ち=黄 / 実行中=緑 / 完了=青 / 待機=灰
- メニューバーの炎アイコンから、表示の切り替え・一覧のクリア・hooks の導入と除去・ログと設定ファイルを開けます

オーバーレイは `.nonactivatingPanel` なので、**クリックしてもターミナルからフォーカスを奪いません**。全 Space・フルスクリーンの上に出ます。

## アーキテクチャ

```
  Claude Code（セッションを何枚開いても可）
    │  hooks: SessionStart / UserPromptSubmit / PreToolUse / Notification / Stop / SessionEnd / PermissionRequest
    ▼
  hinomi-hook（同梱の極小 CLI・約 400KB / 起動は数十ミリ秒）
    │   stdin の hook JSON に hinomi_* を足すだけ（元のフィールドは壊さない）
    │     hinomi_mode        event | ask
    │     hinomi_request_id  1回の問い合わせを識別
    │     hinomi_term_program / hinomi_term_session_id   ← $TERM_PROGRAM から
    │     hinomi_wait_seconds（ask のときだけ）
    │
    │  AF_UNIX ストリーム  ~/.hinomi/hinomi.sock（0600）
    │  1接続 = 改行終端の JSON 1件
    ▼
  hinomi.app（LSUIElement / メニューバー常駐）
    ├─ SocketServer     accept ループ（専用スレッド）→ 接続ごとに並列処理
    ├─ SessionStore     session_id ごとの状態機械（実行中/入力待ち/許可待ち/完了）
    ├─ NotchController  NSPanel(borderless + nonactivating, level=.statusBar,
    │                   canJoinAllSpaces) を画面上部中央へ。ホバーで展開
    └─ NSStatusItem     メニュー
    │
    │  ask のときだけ、同じ接続に {"decision":"allow|deny|none"} を1行書き戻す
    ▼
  hinomi-hook → stdout に Claude Code 向けの permissionDecision JSON → Claude Code が採用
```

オーバーレイは上端を画面最上部に合わせ、**メニューバー（ノッチ）の高さに重ねて表示します**（`panel.level = .statusBar` はメニューバーより上）。形も上角スクエア・下角丸のノッチ風です。

常駐時の負荷は「1秒ごとのタイマーで経過時間を再描画」＋「イベント受信時だけ処理」。ポーリングも常時 CPU 消費もありません。

## 動作確認（fake イベント）

アプリを起動した状態で:

```bash
./scripts/demo.sh          # 全部（3セッション → 実行中 → 完了 → 入力待ち → 許可要求 → Allow/Deny 実演）
./scripts/demo.sh basic    # セッション開始〜実行中〜完了
./scripts/demo.sh notify   # 入力待ち・許可要求（Notification 経由）
./scripts/demo.sh ask      # PermissionRequest の Allow/Deny（notch のボタンが出て、応答までブロックする）
./scripts/demo.sh clean    # デモ用セッションを一覧から消す
```

`ask` は本番の hook と同じ挙動です。notch のボタンを押すと `permissionDecision` JSON が標準出力に出て、放置すると何も出力せずに終わります（＝通常フローに戻る）。

生の socket を直接叩きたいときは:

```bash
echo '{"session_id":"t1","cwd":"'$HOME'/work/hinomi","hook_event_name":"Stop"}' \
  | ./build/hinomi.app/Contents/MacOS/hinomi-hook event
```

## 許可の Allow / Deny — 仕組みと制約

### 採った方式

公式仕様（[Hooks reference](https://code.claude.com/docs/en/hooks) の *PermissionRequest* と *Timeout Defaults*）に基づき、**同期ブロックする `PermissionRequest` フック**で実装しています。`PermissionRequest` は**実際に許可判断が必要になった時だけ**発火するので、自動許可（bypassPermissions・acceptEdits・allowlist 済みコマンド等）で端末に何も出ない場面では notch にもボタンは出ません。

1. `PermissionRequest`（既定は全ツール）で `hinomi-hook ask` が起動
2. hook が socket 越しにアプリへ問い合わせ、**応答が来るまでブロック**（既定15秒・`settings.json` の `timeout` は待ち時間+10秒）
3. notch に「許可 / 拒否」と残り秒数が出る
4. 押されたら hook が stdout に返す:
   ```json
   {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}},"suppressOutput":true}
   ```
5. 無応答のまま期限が来たら **何も出力せず exit 0**（decision なし）→ Claude Code は通常の許可フロー（端末のプロンプト）に進む

`PreToolUse` は監視専用（`async` の `event`）に降格しており、セッションを一切ブロックしません。旧構成（PreToolUse で ask）の settings.json が残っていても、`hinomi-hook` はイベント名を見て正しい出力形式（`permissionDecision`）を返します。

### 制約（承知して使うこと）

- **`allow` は通常の許可プロンプトを飛ばします。** notch のボタンは、端末で `y` を押すのと同じ重みがあります
- **待っている間、端末側の許可プロンプトの表示が最大 `permissionWaitSeconds` 秒遅れます**（hook の応答を待ってから通常フローに進むため）。既定を15秒に抑えているのはこのため。端末で答えたい派なら短く（例 5 秒）するか `permissionPromptEnabled: false` に
- **アプリが起動していなければ何も起きません。** socket が無い／接続できないときは即 exit 0 で無言終了し、通常フローに流れます。「hinomi が落ちていて Claude Code が止まる」ことはありません
- **`Notification` 由来の許可待ち表示にはボタンが出ません。** これは端末側で既にプロンプトが出ている状態の通知なので、hinomi からは状態表示とジャンプのみ（決めるのは端末）
- 他のフックが同じツールに `deny` を返した場合は deny が勝ちます（公式仕様どおり）
- 許可 UI が煩わしければ `~/.hinomi/config.json` で `permissionPromptEnabled: false` にし、`hinomi install-hooks` を再実行してください。`PermissionRequest` のエントリ自体が外れ、監視専用になります

## 設定 `~/.hinomi/config.json`

ファイルが無ければ既定値。一部のキーだけ書いても構いません（残りは既定値が使われます）。
変更後は hinomi を再起動、`permissionPromptEnabled` / `permissionWaitSeconds` / `permissionToolMatcher` を変えたときは `hinomi install-hooks` も再実行してください。

| キー | 既定 | 意味 |
| --- | --- | --- |
| `permissionPromptEnabled` | `true` | notch から Allow/Deny を返す |
| `permissionWaitSeconds` | `15` | 応答を待つ秒数（1〜120に丸める） |
| `permissionToolMatcher` | （空 = 全ツール） | 許可を尋ねる対象ツール（Claude Code の matcher 記法） |
| `doneSound` | `Glass` | 完了時の効果音（`/System/Library/Sounds` の名前・空文字で無音） |
| `permissionSound` | （無音） | 許可待ち・入力待ちの効果音。`"Funk"` 等の NSSound 名で有効化 |
| `autoExpandSeconds` | `6` | イベント時に自動展開しておく秒数 |
| `showWhenEmpty` | `false` | セッション0件でもピルを出す |
| `doneRetentionMinutes` | `30` | 完了セッションを一覧に残す分数 |

ログは `~/.hinomi/hinomi.log`（512KB で自動ローテート）。

## アンインストール

```bash
make uninstall-hooks   # ~/.claude/settings.json から hinomi の分だけ除去（バックアップを取る）
make uninstall         # アプリを終了して ~/Applications から削除
rm -rf ~/.hinomi       # 設定・ログ・socket
```

`install-hooks` / `uninstall-hooks` は書き換えの前に必ず
`~/.claude/settings.json.hinomi-backup-<日時>` を作ります。
hinomi のエントリは command 文字列に `hinomi-hook` を含むことで識別しており、**他ツールのフックには触りません**（同一グループに同居していても hinomi の分だけ抜きます）。

## サブコマンド

```
hinomi                     常駐アプリとして起動
hinomi install-hooks       hooks を非破壊マージ（--settings / --hook-path で対象を変更可）
hinomi uninstall-hooks     hinomi の hooks を除去
hinomi status              socket と hooks の状況（未起動なら exit 1）
hinomi hook <event|ask>    hinomi-hook と同じ動作（保険）
hinomi version
```

## 見送ったもの（MVP スコープ外）

- **タブ単位のジャンプ** — アプリのアクティベートまで。iTerm2/Ghostty はタブ復帰に AppleScript や独自 API が必要で、対応端末ごとに実装と権限が増えるため
- **トークン使用量・コスト表示** — hooks の入力に含まれず、`transcript_path` の JSONL を常時追尾する必要があるため
- **セッションへの操作（プロンプト送信・中断）** — hooks は読み取りと許可判断の口であって、外部から入力を送る経路ではない
- **ノッチ領域そのものへの描画（ノッチと一体化した見た目）** — 表示位置をメニューバー直下に統一し、ノッチ機/非ノッチ機で挙動を分けない方を選んだ
- **公証（notarization）・自動更新** — 個人用のため ad-hoc 署名のみ

## 開発

```
Sources/HinomiCore/   Foundation のみ（イベントのパース・状態機械・socket・hooks 導入）
Sources/hinomi/       AppKit + SwiftUI（notch パネル・メニューバー・CLI）
Sources/hinomi-hook/  hooks から呼ばれる極小クライアント
Tests/HinomiCoreTests/  45 tests（パース・状態遷移・非破壊マージ・socket 往復）
```

UI を持たない部分は全部 `HinomiCore` に寄せてあるので、`swift test` だけで挙動を確かめられます。

```bash
make test    # swift test
make build   # swift build -c release
make app     # .app 組み立て + ad-hoc 署名
```
