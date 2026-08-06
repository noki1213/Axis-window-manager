# Axis

A keyboard-driven tiling window manager for macOS.

https://note.com/elegant_hue/n/nc77a5d09e9a1

## Features

- Tiling Layout: Automatically arranges windows in a tiling layout.
- Keyboard Navigation: Move focus between windows.
- Window Movement: Reorganize windows with keyboard shortcuts.
- Step Move (Merge / Split): Move the focused window one step left/right — it splits out of a shared column into its own column, or merges into the neighboring column if it's already alone.
- Float: Pull a window out of the tiling layout and position it freely.
- Focus Follows Mouse: Automatically focus and raise the window under the mouse pointer (delay adjustable in Settings, can be turned off).
- Floating Windows on Top: Dialogs and floating windows are automatically kept above tiled windows. A rescue shortcut brings them all to the front at once.
- Zen Mode: Focus on a single window by centering it and hiding others (distraction-free).
- Gap Adjustment: Enter a mode where each key directly drives one edge of the focused window, growing or shrinking it on the spot. The edges you can actually move are outlined as you enter.
- Hide / Restore Windows: Hide the focused window out of the tiling layout, and restore it later next to where it used to sit.
- Placement Reservation: Decide where the next new window will land — stacked in the current column, a new column to the side, or floating — before it even opens.
- Window Palette: Quickly switch between windows across all workspaces.
- Workspace Peek: Hold Ctrl+Option to preview the adjacent workspaces as two cards in the middle of the screen.
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

### Step Move (Merge / Split)
- Move the focused window one step left or right
- If it shares a column with other windows, it splits out into its own single-window column next to it
- If it is already alone in a column, it merges into the end of the neighboring column instead
- Repeat the same key to keep walking the window across columns

### Float
- Removes the focused window from tiling and centers it on screen
- The window can then be freely repositioned with the mouse
- Other tiled windows rearrange to fill the gap
- Cycle focus between floating windows
- A rescue shortcut brings all floating windows to the front at once

### Zen Mode
- Centers the focused window and hides all other windows on the primary monitor
- If the window is on a secondary monitor, it will be moved to the primary monitor
- When exiting Zen Mode, the window is restored to its original position

### Gap Adjustment
- Enters a mode where each key directly controls one edge (left / right / top / bottom) of the focused window
- On entering, the edges that can actually be moved are drawn as faint lines, so you can see the mode is active and which edges are available — edges sitting against the screen border have nothing to move and are not shown
- Pressing the key expands that edge outward; holding Shift shrinks it inward
- The edge you are currently driving is highlighted with a thicker line
- No select-then-confirm step — each key press immediately moves the edge, and you can keep adjusting different edges in sequence
- Press Return or Escape to exit

### Hide / Restore Windows
- Hides the focused window (native minimize) and removes it from the tiling layout; remaining windows fill the gap
- Restoring brings it back next to where it used to sit: the same column if its neighbor is still there, otherwise a new column next to where that column used to be
- The most recently hidden window can be restored with a dedicated shortcut, or picked individually from the Window Palette's "Hidden" section

### Placement Reservation
- Reserve where the next newly opened window should be placed before it even appears
- After starting the reservation, press a key to choose: stack above/below in the focused column, open as a new column to the left/right, or open as a floating window
- A translucent preview shows the reserved area; it is consumed as soon as the next new window opens
- Pressing the reservation shortcut again cancels it, and it also expires automatically after a short timeout

### Window Palette
- Lists all windows across all workspaces
- Navigate up/down (across workspaces) and left/right (between windows)
- Floating windows toggled with Float appear in a "Float" section, windows not assigned to any workspace (e.g. System Settings, dialogs) appear in a "System" section, and windows hidden via Hide/Restore appear in a "Hidden" section — each at the bottom of its display column
- Press Return to switch to (or restore) the selected window

### Workspace Peek
- Hold down Ctrl+Option (with no other key) to preview the adjacent workspaces
- Two cards appear in the middle of the monitor — the left-neighbor workspace on the left, the right-neighbor on the right — each listing its windows with the same app icon, app name and window title as the Window Palette
- It appears after a short hold, so the modifiers used as a prefix for ordinary shortcuts do not trigger it
- Releasing the modifiers or pressing any other key dismisses it; once you have fired a shortcut, it stays hidden until you release the modifiers
- It is not shown while another mode is active

### Workspace Management
- Switch to next/previous workspace
- Move the focused window to next/previous workspace
- Empty workspaces are automatically removed and reordered

## Installation

### Download the app

1. Download the `.zip` from the [Releases](https://github.com/noki1213/Axis-window-manager/releases) page.
2. Unzip it and move `Axis.app` into your Applications folder.
3. Open it. **macOS will refuse the first time** — see below.

Axis is not notarized by Apple, because notarization requires a paid Apple Developer Program membership that I do not have. macOS therefore treats it as coming from an unidentified developer and blocks the first launch. This is expected, and you have two ways past it:

- Open System Settings → Privacy & Security, scroll to the bottom, and click **Open Anyway** next to the Axis message. Then open the app again.
- Or clear the quarantine flag from the terminal, then open it normally:

  ```sh
  xattr -cr /Applications/Axis.app
  ```

Only the first launch is affected. If you would rather not rely on a binary from a stranger, build it yourself instead.

### Build from source

Requires Xcode. No Apple Developer account needed.

```sh
git clone https://github.com/noki1213/Axis-window-manager.git
cd Axis-window-manager
./install.sh
```

`install.sh` builds an unsigned Release build and installs it to `/Applications`. Because you built it locally, macOS does not quarantine it and there is no first-launch prompt.

Either way, grant Accessibility permission when prompted — see Setup below.

## Requirements

- macOS 14.0 or later. Developed and tested on macOS 26; earlier versions should work but have not been verified.
- Apple Silicon or Intel (the released build is universal)
- Xcode 15.0 or later (only if building from source)
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
- 合流/分離（ステップ移動）：フォーカス中のウィンドウを左右へ1ステップ移動。複数ウィンドウの列にいれば抜けて隣に単独列として出て、単独列にいれば隣の列の末尾に合流します
- Float：ウィンドウをタイリングから外して、自由に配置できるフローティング状態にします
- Focus Follows Mouse：マウスを乗せたウィンドウを自動でフォーカス＆前面化します（遅延は設定で変更可能、オフにもできます）
- 浮遊ウィンドウの前面キープ：ダイアログなどの浮遊ウィンドウがタイルの裏に隠れないよう常に前面に保ちます。全部をまとめて前面に出す救出キーもあります
- Zen モード：一つのウィンドウに集中するため、中央に配置して他のウィンドウを非表示にします
- ギャップ操作：モードに入るとキーごとに上下左右いずれかの辺を直接担当し、その場で辺を動かしてサイズ調整します。入った時点で動かせる辺が線で表示されます
- ウィンドウを隠す/復元：フォーカス中のウィンドウをタイリングから隠し、あとで元にいた場所の近くへ復元します
- 配置予約：次に開く新規ウィンドウの置き場所（列内の上/下、左右の新規列、Float）を先に決めておきます
- ウィンドウパレット：全ワークスペースのウィンドウを一覧表示して素早く切り替え
- 隣ワークスペースのチラ見せ：Ctrl+Option を押しっぱなしにすると、画面中央に隣のワークスペースがカード2枚で表示されます
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

### 合流/分離（ステップ移動）
- フォーカス中のウィンドウを左右へ1ステップだけ移動
- 複数ウィンドウの列にいる場合：その列から抜けて、移動方向の隣に単独の列として出る
- 単独の列にいる場合：移動方向の隣の列の末尾に合流する
- 同じキーを連打することで、列から列へとウィンドウを渡り歩ける

### Float
- フォーカス中のウィンドウをタイリングから外して、画面中央に表示
- その後マウスで自由に位置を変更できる
- 他のタイリングされたウィンドウは、空いたスペースを埋めるように再配置される
- Float 中のウィンドウ間でフォーカスを切り替え
- 救出キーで、すべての浮遊ウィンドウをまとめて最前面に出せる

### Zen モード
- フォーカス中のウィンドウをメインモニターの中央に表示
- 他のすべてのウィンドウを非表示にして、集中できる環境を作成
- サブモニターのウィンドウも Zen モードにするとメインモニターに移動
- Zen モード解除時は、ウィンドウは元の位置に復元される

### ギャップ操作
- モードに入ると、キーごとにフォーカス中ウィンドウの辺（左右上下）を直接担当する
- 入った瞬間、実際に動かせる辺が薄い線で表示される。モードに入ったことと、どの辺を動かせるかが一目でわかる（画面端に接している辺は動かす相手がないため表示されない）
- 素押しでその辺を外側へ広げ、Shift を押しながらだと内側へ縮める
- いま操作している辺は太い線でハイライトされる
- 選択→確定という手順はなく、キーを押した瞬間に辺が動く。続けて別の辺を調整することもできる
- Return または Escape でモードを終了

### ウィンドウを隠す/復元する
- フォーカス中のウィンドウをネイティブ最小化でタイリングから隠す。残りのウィンドウは詰めて再配置される
- 復元すると、元にいた場所の近くに戻る：同じ列にいた隣人がまだいればその隣に、いなければ元その列があった位置の隣に新しい列として挿入される
- 最後に隠したウィンドウは専用ショートカットで復元できるほか、ウィンドウパレットの「Hidden」セクションから個別に選んで復元することもできる

### 配置予約
- 次に新しく開くウィンドウの置き場所を、開く前に先に決めておく
- 配置予約を開始した後、続けてキーを押して「フォーカス列の上/下に積む」「左/右に新規列として開く」「Float で開く」のいずれかを選ぶ
- 予約された領域は半透明のプレビューで表示され、次の新規ウィンドウが開いた時点で消費される
- もう一度配置予約のショートカットを押すと解除できるほか、一定時間で自動的に失効する

### ウィンドウパレット
- 全ワークスペースのウィンドウを一覧表示
- 上下に移動（ワークスペース間）、左右に移動（ウィンドウ間）
- Float で浮遊化したウィンドウは「Float」セクションに、ワークスペースに属さない浮遊ウィンドウ（システム設定・ダイアログ等）は「System」セクションに、隠す/復元機能で隠したウィンドウは「Hidden」セクションに、それぞれ各モニター列の一番下にまとめて表示
- Return で選択したウィンドウに切り替え（またはウィンドウを復元）

### 隣ワークスペースのチラ見せ
- Ctrl+Option（他の修飾キーなし）を押しっぱなしにすると、隣のワークスペースをプレビュー表示
- モニターの中央にカード2枚が並び、左に左隣、右に右隣のワークスペースの中身が出る。各ウィンドウはウィンドウパレットと同じアイコン・アプリ名・ウィンドウタイトルで表示される
- 少し押しっぱなしにしてから出るので、ショートカットの前置きとして Ctrl+Option を押しただけでは出ない
- 修飾キーを離すか他のキーを押すと消える。一度ショートカットを使ったら、修飾キーを離すまで出てこない
- 他のモード中は表示されない

### ワークスペース管理
- 次/前のワークスペースに切り替え
- フォーカス中のウィンドウを次/前のワークスペースに移動
- 空のワークスペースは自動的に削除され、ID が再割り当てされます

## インストール

### アプリをダウンロードする

1. [Releases](https://github.com/noki1213/Axis-window-manager/releases) から `.zip` をダウンロードします。
2. 展開して、`Axis.app` をアプリケーションフォルダに入れます。
3. 開きます。**初回は macOS に拒否されます**（下記参照）。

Axis は Apple の公証（notarization）を受けていません。公証には有料の Apple Developer Program のメンバーシップが必要で、私が持っていないためです。そのため macOS は「開発元が未確認のアプリ」として初回起動をブロックします。これは想定どおりの動作で、通す方法が2つあります。

- システム設定 → プライバシーとセキュリティ を開き、一番下までスクロールして、Axis についてのメッセージの横にある **このまま開く** をクリックします。そのあともう一度アプリを開いてください。
- またはターミナルで隔離属性を外してから、普通に開きます。

  ```sh
  xattr -cr /Applications/Axis.app
  ```

影響があるのは初回だけです。知らない人が作ったバイナリを実行したくない場合は、自分でビルドしてください。

### ソースからビルドする

Xcode が必要です。Apple Developer アカウントは不要です。

```sh
git clone https://github.com/noki1213/Axis-window-manager.git
cd Axis-window-manager
./install.sh
```

`install.sh` は未署名の Release ビルドを作成して `/Applications` にインストールします。自分でビルドしたアプリは macOS に隔離されないため、初回起動の確認は出ません。

どちらの方法でも、アクセシビリティ権限を求められたら許可してください（下のセットアップを参照）。

## 動作環境

- macOS 14.0 以降。開発と動作確認は macOS 26 で行っています。それより古いバージョンでも動作するはずですが、検証はしていません。
- Apple Silicon / Intel（配布しているアプリは両対応）
- Xcode 15.0 以降（ソースからビルドする場合のみ）
- アクセシビリティ権限（ウィンドウ管理に必要）

## セットアップ

1. Axis を起動
2. 起動ガイドが表示されるので、すべてのウィンドウを 1 つのデスクトップに移動してから続行
3. システム設定 > プライバシーとセキュリティ > アクセシビリティ を開く
4. Axis をリストに追加して有効化
5. 必要に応じて Axis を再起動
