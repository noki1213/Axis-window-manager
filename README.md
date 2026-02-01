# Axis

A keyboard-driven tiling window manager for macOS.

https://note.com/elegant_hue/n/nc77a5d09e9a1

## Features

- **Tiling Layout**: Automatically arranges windows in a tiling layout.
- **Keyboard Navigation**: Move focus between windows using vim-style keys (J/K/L/I).
- **Window Movement**: Reorganize windows with keyboard shortcuts.
- **Zen Mode**: Focus on a single window by centering it and hiding others (distraction-free).
- **Gap Selection Mode**: Resize windows by selecting and moving gaps between them.
- **Window Selection Mode**: Select and merge multiple windows into columns.
- **Window Palette**: Quickly switch between windows across all workspaces.
- **Visual Feedback**: Border highlights around the focused window.
- **Smart Workspaces**: Efficiently navigate and move windows between workspaces. Empty workspaces are automatically cleaned up.

## Keyboard Shortcuts

All shortcuts use `Ctrl + Option` as the base modifier.

### Basic Navigation (Normal Mode)
- `Ctrl + Option + J`: Move focus left
- `Ctrl + Option + L`: Move focus right
- `Ctrl + Option + I`: Move focus up
- `Ctrl + Option + K`: Move focus down

### Window Movement
- `Ctrl + Option + Shift + J`: Move window left
- `Ctrl + Option + Shift + L`: Move window right
- `Ctrl + Option + Shift + I`: Move window up
- `Ctrl + Option + Shift + K`: Move window down

### Zen Mode
- `Ctrl + Option + Z`: Toggle Zen Mode (Focus Mode)

### Window Palette
- `Ctrl + Option + P`: Open Window Palette
  - `I/K`: Navigate up/down (across workspaces)
  - `J/L`: Navigate left/right (between windows)
  - `Return`: Switch to selected window

### Window Selection Mode
- `Ctrl + Option + W`: Enter window selection mode
  - `J/K/L/I`: Navigate focus
  - `Return`: Select/Deselect window
  - `V`: Merge selected windows vertically
  - `Shift + V`: Split selected windows
  - `Escape`: Exit mode

### Gap Selection & Resizing
**Quick Resize (Direct Entry)**

Directly select gaps around the focused window and resize immediately:
- `Ctrl + Option + S`: Select Left Gap
- `Ctrl + Option + F`: Select Right Gap
- `Ctrl + Option + E`: Select Top Gap
- `Ctrl + Option + D`: Select Bottom Gap

Once selected, use `J/K/L/I` to adjust the gap size, `Return` to confirm, or `Escape` to cancel.

**Standard Entry**
- `Ctrl + Option + G`: Enter Gap Selection Mode

**In Mode:**
- `J/K/L/I`: Move gap (Resize)
- `Return`: Confirm
- `Escape`: Cancel

### Window Resizing (Normal Mode)
- `Ctrl + Option + -`: Shrink focused window
- `Ctrl + Option + =`: Expand focused window
- `Ctrl + Option + R`: Reset layout (Single column per window)

### Workspace Management
- `Ctrl + Option + O`: Switch to next workspace
- `Ctrl + Option + U`: Switch to previous workspace
- `Ctrl + Option + Shift + O`: Move focused window to next workspace
- `Ctrl + Option + Shift + U`: Move focused window to previous workspace

*Note: Empty workspaces are automatically removed and reordered.*

### Monitor Cursor
- `Ctrl + Option + M` (or `Q`): Move mouse cursor to next monitor

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
2. Go to System Settings > Privacy & Security > Accessibility
3. Add Axis to the list and enable it
4. Restart Axis if needed

## License

MIT

---

# 日本語ドキュメント

macOS 向けのキーボード操作タイリングウィンドウマネージャーです。

## 機能

- タイリングレイアウト：ウィンドウを自動的にタイル状に配置します
- キーボード操作：vim スタイルのキー（J/K/L/I）でウィンドウ間のフォーカス移動
- ウィンドウ移動：キーボードショートカットでウィンドウを再配置
- Zen モード：一つのウィンドウに集中するため、中央に配置して他のウィンドウを非表示にします
- ギャップ選択モード：ウィンドウ間のギャップを選択して移動することでリサイズ
- ウィンドウ選択モード：複数のウィンドウを選択してまとめて列に統合
- ウィンドウパレット：全ワークスペースのウィンドウを一覧表示して素早く切り替え
- ビジュアルフィードバック：フォーカス中のウィンドウに枠線を表示
- スマートワークスペース：ワークスペース間の移動と、ウィンドウの移動を効率的に実行。空のワークスペースは自動削除されます

## キーボードショートカット

すべてのショートカットは Ctrl + Option を基本修飾キーとして使用します。

### 基本操作（ノーマルモード）
- Ctrl + Option + J：左のウィンドウにフォーカス移動
- Ctrl + Option + L：右のウィンドウにフォーカス移動
- Ctrl + Option + I：上のウィンドウにフォーカス移動
- Ctrl + Option + K：下のウィンドウにフォーカス移動

### ウィンドウの移動
- Ctrl + Option + Shift + J：ウィンドウを左に移動
- Ctrl + Option + Shift + L：ウィンドウを右に移動
- Ctrl + Option + Shift + I：ウィンドウを上に移動
- Ctrl + Option + Shift + K：ウィンドウを下に移動

### Zen モード
- Ctrl + Option + Z：Zen モードの切り替え

### ウィンドウパレット
- Ctrl + Option + P：ウィンドウパレットを開く
  - I/K：上下に移動（ワークスペース間）
  - J/L：左右に移動（ウィンドウ間）
  - Return：選択したウィンドウに切り替え

### ウィンドウ選択モード
- Ctrl + Option + W：ウィンドウ選択モードに入る
  - J/K/L/I：フォーカス移動
  - Return：ウィンドウを選択/選択解除
  - V：選択したウィンドウを縦に統合
  - Shift + V：選択したウィンドウを分割
  - Escape：モードを終了

### ギャップ選択とリサイズ
クイックリサイズ（直接入力）

フォーカス中のウィンドウの周りのギャップを直接選択して、すぐにリサイズできます：
- Ctrl + Option + S：左のギャップを選択
- Ctrl + Option + F：右のギャップを選択
- Ctrl + Option + E：上のギャップを選択
- Ctrl + Option + D：下のギャップを選択

選択後、J/K/L/I でギャップのサイズを調整し、Return で確定、Escape でキャンセルできます。

標準入力
- Ctrl + Option + G：ギャップ選択モードに入る

モード内の操作：
- J/K/L/I：ギャップを移動（リサイズ）
- Return：確定
- Escape：キャンセル

### ウィンドウのリサイズ（ノーマルモード）
- Ctrl + Option + -：フォーカス中のウィンドウを縮小
- Ctrl + Option + =：フォーカス中のウィンドウを拡大
- Ctrl + Option + R：レイアウトをリセット（各ウィンドウを1列に）

### ワークスペース管理
- Ctrl + Option + O：次のワークスペースに切り替え
- Ctrl + Option + U：前のワークスペースに切り替え
- Ctrl + Option + Shift + O：フォーカス中のウィンドウを次のワークスペースに移動
- Ctrl + Option + Shift + U：フォーカス中のウィンドウを前のワークスペースに移動

注意：空のワークスペースは自動的に削除され、ID が再割り当てされます。

### モニター間のカーソル移動
- Ctrl + Option + M（または Q）：マウスカーソルを次のモニターに移動

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
2. システム設定 > プライバシーとセキュリティ > アクセシビリティ を開く
3. Axis をリストに追加して有効化
4. 必要に応じて Axis を再起動