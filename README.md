# Axis

A keyboard-driven tiling window manager for macOS.

https://note.com/elegant_hue/n/nc77a5d09e9a1

## Features

- Tiling Layout: Automatically arranges windows in a tiling layout.
- Keyboard Navigation: Move focus between windows.
- Window Movement: Reorganize windows with keyboard shortcuts.
- Hover Mode: Float a window above the tiling layout and position it freely.
- Focus Follows Mouse: Automatically focus and raise the window under the mouse pointer (delay adjustable in Settings, can be turned off).
- Floating Windows on Top: Dialogs and floating windows are automatically kept above tiled windows. A rescue shortcut brings them all to the front at once.
- Zen Mode: Focus on a single window by centering it and hiding others (distraction-free).
- Gap Selection Mode: Resize windows by selecting and moving gaps between them.
- Window Selection Mode: Select and merge multiple windows into columns.
- Window Palette: Quickly switch between windows across all workspaces.
- Visual Feedback: Border highlights around the focused window. Menu bar icon changes based on current mode.
- Smart Workspaces: Efficiently navigate and move windows between workspaces. Empty workspaces are automatically cleaned up.
- Custom Keyboard Shortcuts: Remap all shortcuts from the Settings window.
- State Persistence: Workspaces and window positions are preserved across sleep/lock and app restarts.
- Safe Quit: When Axis exits, all windows are restored to visible positions on screen.

## Customizing Keyboard Shortcuts

1. Click the Axis icon in the menu bar
2. Select "Settings..."
3. Open the Shortcuts tab
4. Click the key field next to the action you want to change
5. Press the new key combination
6. The shortcut is applied immediately

If the key combination is already used by another action, a conflict warning will appear. To restore all shortcuts to their defaults, click "Restore Defaults" at the bottom of the settings.

## Modes

### Normal Mode
- Move focus between windows (up / down / left / right)
- Move windows to a different position
- Resize windows (shrink / expand)
- Reset layout (single column per window)

### Hover Mode
- Removes the focused window from tiling and centers it on screen
- The window can then be freely repositioned with the mouse
- Other tiled windows rearrange to fill the gap
- Cycle focus between hover windows

### Zen Mode
- Centers the focused window and hides all other windows on the primary monitor
- If the window is on a secondary monitor, it will be moved to the primary monitor
- When exiting Zen Mode, the window is restored to its original position

### Window Palette
- Lists all windows across all workspaces
- Navigate up/down (across workspaces) and left/right (between windows)
- Floating windows not assigned to any workspace (e.g. System Settings, dialogs) appear in a "Float" section at the bottom of each display column
- Press Return to switch to the selected window

### Window Selection Mode
- Navigate and select multiple windows
- Merge selected windows vertically into a column
- Split merged windows back apart
- Press Escape to exit

### Gap Selection & Resizing
- Select a gap (left / right / top / bottom) around the focused window
- Use directional keys to adjust the gap size
- Press Return to confirm or Escape to cancel

### Workspace Management
- Switch to next/previous workspace
- Move the focused window to next/previous workspace
- Empty workspaces are automatically removed and reordered

### Monitor Cursor
- Move the mouse cursor to the next monitor

## Installation

1. Clone this repository
2. Open `Axis.xcodeproj` in Xcode
3. Build and run the project
4. Grant Accessibility permissions when prompted

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later (for building)
- Accessibility permissions (required for window management)

## Setup

1. Launch Axis
2. A startup guide will appear — move all windows to a single desktop before continuing
3. Go to System Settings > Privacy & Security > Accessibility
4. Add Axis to the list and enable it
5. Restart Axis if needed

## License

MIT

---

# 日本語ドキュメント

macOS 向けのキーボード操作タイリングウィンドウマネージャーです。

## 機能

- タイリングレイアウト：ウィンドウを自動的にタイル状に配置します
- キーボード操作：ウィンドウ間のフォーカス移動
- ウィンドウ移動：キーボードショートカットでウィンドウを再配置
- ホバーモード：ウィンドウをタイリングから外して、自由に配置できるフローティング状態にします
- Focus Follows Mouse：マウスを乗せたウィンドウを自動でフォーカス＆前面化します（遅延は設定で変更可能、オフにもできます）
- 浮遊ウィンドウの前面キープ：ダイアログなどの浮遊ウィンドウがタイルの裏に隠れないよう常に前面に保ちます。全部をまとめて前面に出す救出キーもあります
- Zen モード：一つのウィンドウに集中するため、中央に配置して他のウィンドウを非表示にします
- ギャップ選択モード：ウィンドウ間のギャップを選択して移動することでリサイズ
- ウィンドウ選択モード：複数のウィンドウを選択してまとめて列に統合
- ウィンドウパレット：全ワークスペースのウィンドウを一覧表示して素早く切り替え
- ビジュアルフィードバック：フォーカス中のウィンドウに枠線を表示。現在のモードに応じてメニューバーのアイコンが変化
- スマートワークスペース：ワークスペース間の移動と、ウィンドウの移動を効率的に実行。空のワークスペースは自動削除されます
- カスタムキーボードショートカット：設定画面からすべてのショートカットを自由に変更できます
- 状態の永続化：スリープやロックからの復帰後もワークスペースとウィンドウ配置を維持します
- 安全な終了：Axis 終了時、すべてのウィンドウを画面内の見える位置に復元します

## ショートカットの設定方法

1. メニューバーの Axis アイコンをクリック
2. Settings... を選択
3. Shortcuts タブを開く
4. 変更したい操作の横にあるキー表示部分をクリック
5. 新しいキーの組み合わせを押す
6. ショートカットはすぐに反映されます

すでに他の操作で使われているキーの組み合わせを設定しようとすると、重複の警告が表示されます。すべてのショートカットを元に戻したい場合は、設定画面の下にある「デフォルトに戻す」をクリックしてください。

## モード

### ノーマルモード
- ウィンドウ間のフォーカス移動（上下左右）
- ウィンドウの位置変更
- ウィンドウのリサイズ（縮小・拡大）
- レイアウトのリセット（各ウィンドウを1列に）

### ホバーモード
- フォーカス中のウィンドウをタイリングから外して、画面中央に表示
- その後マウスで自由に位置を変更できる
- 他のタイリングされたウィンドウは、空いたスペースを埋めるように再配置される
- ホバー中のウィンドウ間でフォーカスを切り替え

### Zen モード
- フォーカス中のウィンドウをメインモニターの中央に表示
- 他のすべてのウィンドウを非表示にして、集中できる環境を作成
- サブモニターのウィンドウも Zen モードにするとメインモニターに移動
- Zen モード解除時は、ウィンドウは元の位置に復元される

### ウィンドウパレット
- 全ワークスペースのウィンドウを一覧表示
- 上下に移動（ワークスペース間）、左右に移動（ウィンドウ間）
- ワークスペースに属さない浮遊ウィンドウ（システム設定・ダイアログ等）は、各モニター列の一番下に「Float」セクションとして表示
- Return で選択したウィンドウに切り替え

### ウィンドウ選択モード
- ウィンドウ間を移動して複数選択
- 選択したウィンドウを縦に統合して列にまとめる
- 統合したウィンドウを分割して元に戻す
- Escape でモードを終了

### ギャップ選択とリサイズ
- フォーカス中のウィンドウの周りのギャップ（左右上下）を選択
- 方向キーでギャップのサイズを調整
- Return で確定、Escape でキャンセル

### ワークスペース管理
- 次/前のワークスペースに切り替え
- フォーカス中のウィンドウを次/前のワークスペースに移動
- 空のワークスペースは自動的に削除され、ID が再割り当てされます

### モニター間のカーソル移動
- マウスカーソルを次のモニターに移動

## インストール

1. このリポジトリをクローン
2. Xcode で Axis.xcodeproj を開く
3. プロジェクトをビルドして実行
4. アクセシビリティ権限を求められたら許可する

## 動作環境

- macOS 14.0 以降
- Xcode 15.0 以降（ビルド用）
- アクセシビリティ権限（ウィンドウ管理に必要）

## セットアップ

1. Axis を起動
2. 起動ガイドが表示されるので、すべてのウィンドウを 1 つのデスクトップに移動してから続行
3. システム設定 > プライバシーとセキュリティ > アクセシビリティ を開く
4. Axis をリストに追加して有効化
5. 必要に応じて Axis を再起動
