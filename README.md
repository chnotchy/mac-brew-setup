# macOS セットアップ

## 前提

- Apple Silicon の Mac
- ネットワークに接続済みであること

## 使い方

ターミナルを開き、次の1行を実行します。

```bash
curl -fsSL https://github.com/chnotchy/mac-brew-setup/archive/main.tar.gz | tar xz && ./mac-brew-setup-main/setup.sh
```


セットアップが完了すると、自動的に再起動します（再起動前に15秒のカウントダウンが表示され、Ctrl+C で中止できます）。再実行時など、変更した設定が無い場合は再起動しません。

### セットアップ結果の確認

`--check` を付けると、設定を一切変更せずに現在の状態だけを検証します。再起動後に実行することを推奨します。

セットアップ時に展開されたディレクトリがホームに残っているので、そこから実行します。

```bash
~/mac-brew-setup-main/setup.sh --check
```

## 手動での操作が必要な設定

**True Tone のオフ**は自動化できません。設定がディスプレイ固有IDに紐づいて保存されており、`defaults` から確実に変更する方法がないためです。セットアップの前半でディスプレイ設定を開いて操作を依頼します。既にオフであることを確認できた場合は依頼を省略します（`--check` では検証しません）。

## セットアップされる内容

### インストールされるアプリケーション（[Brewfile](Brewfile) で管理）

- Google Chrome
- OBS
- VLC
- DistroAV（OBS用NDIプラグイン）
- Docker Desktop（cask: `docker-desktop`）
- NDI Tools（cask: `ndi-tools`）
- ffmpeg（動画・音声の変換／配信用CLI）
- GStreamer（`gst-inspect-1.0` で VideoToolbox / SRT / AAC（`avenc_aac`）を確認）
- uv（Python パッケージマネージャ）
- MediaMTX（RTSP/RTMP/SRT/WebRTC のメディアサーバー）
- Docker Compose（Docker Desktop にも同梱）
- node_exporter（ログイン時に自動起動）
- jq
- defaultbrowser（デフォルトブラウザの設定に使用）

アプリを追加したい場合は [Brewfile](Brewfile) に追加するだけで反映されます。

### 変更されるmacOSの設定

- 共有: リモートログイン（SSH）と画面共有をオン（システム設定 > 一般 > 共有。セットアップの最初に有効化し、別の端末から `ssh <ユーザー名>@<ローカルホスト名>.local` で接続できるようにする）
- デフォルトブラウザをChromeに設定（確認ダイアログが出た場合は「Chromeを使用」を選択。自動設定できない場合はシステム設定を開いて手動設定を待ちます）
- スクリーンセーバー・ディスプレイ/システム/ディスクスリープを無効化（AC・バッテリー両方）
- トラックパッド・マウス設定
  - Tap to click を有効化
  - カーソル速度を最大化
  - クリック感度をLight（軽い）に設定
  - 3本指ドラッグを有効化（競合する3本指スワイプは無効化し、Mission Control・スペース切り替えは4本指スワイプに集約）
  - ナチュラルスクロールを有効化（コンテンツが指に追従する方向）
- キーボード入力（キーリピート・リピート開始をいずれも最速、長押しによるアクセント入力を無効化）
- ディスプレイごとに個別の操作スペースを有効化
- メニューバー表示（時計を秒表示・24時間表示、バッテリー残量をパーセンテージ表示）
- Finder表示（カラム表示、隠しファイル・拡張子表示、パスバー・ステータスバー表示）

## 任意: Blackmagic Desktop Video

再起動を1回で済ませるため、手順 1〜3 は setup.sh の実行前に行います。

1. [Blackmagic Design Support](https://www.blackmagicdesign.com/support) を開く
2. Capture and Playback から Desktop Video の Mac 用をダウンロードする（登録は任意。「Download Only」で可）
3. インストーラに従い、求められたらシステム拡張を許可する。再起動を求められても、ここでは再起動せずに setup.sh を実行する（setup.sh 完了時の再起動で反映される）
4. setup.sh 完了・再起動後に、次のコマンドで GStreamer の DeckLink 要素を含め、必要なプラグインが入っていることを確認する。「No such element」と出なければ OK

```bash
gst-inspect-1.0 decklinkvideosrc decklinkvideosink vtenc_h264 vtdec srtsink avenc_aac
```
