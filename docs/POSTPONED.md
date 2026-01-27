# Axis 保留中の課題・後回しにする問題

> **注意**: このファイルに記載されている課題は、現時点では優先度が低く、後で実装する予定のものです。

---

## 1. ⏸️ MacBookスクリーンでウィンドウが画面端からはみ出す問題（保留中）
- **現象**: 最小サイズが大きいウィンドウが、モニターの端に配置されると、ウィンドウが画面外にはみ出す
- **原因**: ウィンドウの最小サイズを考慮せず均等分割しているため
- **試した解決策（動作せず）**:
  - `calculateWindowWidths()` メソッドを追加し、各ウィンドウの最小サイズを考慮した幅を計算
  - 最小サイズより小さい場合は最小サイズを適用し、他のウィンドウの幅で調整
  - `adjustFrameToFitScreen()` メソッドを追加
  - → 何度試しても正しく動作しないため、一旦保留

---

## 2. ⏸️ 仮想デスクトップ（Space）の切り替え機能（保留中）
- **目標**: ctrl+option+U/O で仮想デスクトップを左右に切り替える
- **試した解決策（動作せず）**:
  - CGEvent でキーボードイベント（ctrl+左矢印/右矢印）をシミュレート
    - `CGEventSource(stateID: .hidSystemState)` + `.cghidEventTap` → 動作せず
    - `CGEventSource(stateID: .combinedSessionState)` + `.cgAnnotatedSessionEventTap` → 動作せず
  - AppleScript で System Events にキーイベントを送信
    - → エラー: "Not authorized to send Apple events to System Events." (-1743)
    - Automation 権限の設定が必要だが、複雑なため保留
- **考えられる原因**:
  - macOS のセキュリティ制限により、Space 切り替えのキーイベントがブロックされている可能性
  - Private API を使う必要があるかもしれない
