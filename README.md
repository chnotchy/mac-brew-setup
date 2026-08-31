# macOS セットアップ

## 前提

- Apple Silicon の Mac
- ネットワークに接続済みであること

## 使い方

ターミナルを開き、次の1行を実行します。

```bash
curl -fsSL https://github.com/chnotchy/mac-brew-setup/archive/main.tar.gz | tar xz && ./mac-brew-setup-main/setup.sh
```


確認なしで最後まで自動実行し、完了後に自動再起動する場合は `--yes`（または `-y`）を付けます。

```bash
curl -fsSL https://github.com/chnotchy/mac-brew-setup/archive/main.tar.gz | tar xz && ./mac-brew-setup-main/setup.sh --yes
```

### セットアップ結果の確認

`--check` を付けると、設定を一切変更せずに現在の状態だけを検証します。再起動後に実行することを推奨します。

```bash
./setup.sh --check
```

## セットアップされる内容

### インストールされるアプリケーション（[Brewfile](Brewfile) で管理）

- Google Chrome
- OBS
- DistroAV（OBS用NDIプラグイン）
- Docker Desktop（cask: `docker-desktop`）
- NDI Tools（cask: `ndi-tools`）
- ffmpeg（動画・音声の変換／配信用CLI）
- MediaMTX（RTSP/RTMP/SRT/WebRTC のメディアサーバー）
- node_exporter（ログイン時に自動起動）
- jq
- defaultbrowser（デフォルトブラウザの設定に使用）

アプリを追加したい場合は [Brewfile](Brewfile) に追加するだけで反映されます。

### 変更されるmacOSの設定

- デフォルトブラウザをChromeに設定（確認ダイアログが出た場合は「Chromeを使用」を選択。自動設定できない場合はシステム設定を開いて手動設定を待ちます）
- スクリーンセーバー・ディスプレイ/システム/ディスクスリープを無効化（AC・バッテリー両方）
- トラックパッド・マウス設定
  - Tap to click を有効化
  - カーソル速度を最大化
  - クリック感度をLight（軽い）に設定
  - 3本指ドラッグを有効化（競合する3本指スワイプは無効化し、Mission Control・スペース切り替えは4本指スワイプに集約）
  - ナチュラルスクロールを無効化
- メニューバー表示（時計を秒表示・24時間表示、バッテリー残量をパーセンテージ表示）
- Finder表示（カラム表示、隠しファイル・拡張子表示、パスバー・ステータスバー表示）
