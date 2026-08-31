#!/bin/bash

set -eE

# エラーハンドリング関数
handle_error() {
    local line="$1"
    local command="$2"
    local func="${FUNCNAME[1]}"

    echo "エラーが発生しました"
    echo "  処理: ${func:-メイン処理}"
    echo "  コマンド: $command"
    echo "  行番号（目安）: $line"
    echo "スクリプトを終了します"
    exit 1
}

# エラートラップを設定
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# root で実行すると defaults の書き込み先が root ユーザーになり、設定が反映されない
if [ "$(id -u)" -eq 0 ]; then
    echo "このスクリプトは sudo を付けずに実行してください"
    exit 1
fi

# brew コマンドのたびに自動更新（タップの再取得）が走ると台あたり数分かかるため抑止する
export HOMEBREW_NO_AUTO_UPDATE=1

# ネットワーク疎通確認に使うURL（Appleのキャプティブポータル検出用エンドポイント）
NETWORK_CHECK_URL="http://captive.apple.com/hotspot-detect.html"
# 非対話モード（--yes）でネットワーク接続を待つタイムアウト（秒）
NETWORK_WAIT_AUTO=600
# Command Line Tools のGUIインストール待ちタイムアウト（秒）
CLT_WAIT=1800
# デフォルトブラウザ変更の確認ダイアログ操作を待つタイムアウト（秒）
DEFAULT_BROWSER_WAIT=600
# デフォルトブラウザをGUIで手動設定してもらう場合の待ちタイムアウト（秒）
DEFAULT_BROWSER_MANUAL_WAIT=600
# 操作を促すメッセージを再表示する間隔（秒）
REMINDER_INTERVAL=60

# 離席していても戻ってきた時に状況が分かるよう、待ち状況を再表示する
print_waiting_notice() {
    local waited="$1"
    shift

    echo
    echo "  [待機中 $((waited / 60))分経過] $*"
}

# ネットワーク状態を判定する
#   0: オンライン / 2: キャプティブポータル（要ログイン）疑い / 1: オフライン
check_network() {
    local body
    body="$(curl -fsSL --max-time 5 "$NETWORK_CHECK_URL" 2>/dev/null)" || return 1

    case "$body" in
        *"<TITLE>Success</TITLE>"*) return 0 ;;
        *) return 2 ;;
    esac
}

is_online() {
    local rc=0
    check_network || rc=$?
    [ "$rc" -eq 0 ]
}

# オンラインになるまで待つ（利用者がターミナルに戻らなくても自動で検知して進む）
# 第1引数がタイムアウト秒数。0 を渡すと接続されるまで無制限に待つ
wait_for_online() {
    local timeout="$1"
    local waited=0
    local rc

    while [ "$timeout" -le 0 ] || [ "$waited" -lt "$timeout" ]; do
        rc=0
        check_network || rc=$?

        if [ "$rc" -eq 0 ]; then
            echo
            return 0
        fi

        if [ "$waited" -gt 0 ] && [ $((waited % REMINDER_INTERVAL)) -eq 0 ]; then
            if [ "$rc" -eq 2 ]; then
                print_waiting_notice "$waited" "ログインページ（キャプティブポータル）の認証が必要です"
                echo "  ブラウザで $NETWORK_CHECK_URL を開き、認証を完了してください"
            else
                print_waiting_notice "$waited" "Wi-Fiに接続してください（システム設定またはメニューバーから）"
            fi
        fi

        printf '.'
        sleep 3
        waited=$((waited + 3))
    done

    echo
    return 1
}

# Wi-Fiのネットワークデバイス名（通常は en0）を取得
wifi_device() {
    networksetup -listallhardwareports 2>/dev/null \
        | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

# システム設定のWi-Fi画面を開く（OSバージョン差を吸収するため順にフォールバック）
open_wifi_settings() {
    open "x-apple.systempreferences:com.apple.wifi-settings-extension" 2>/dev/null && return 0
    open "x-apple.systempreferences:com.apple.Network-Settings.extension" 2>/dev/null && return 0
    open "/System/Library/PreferencePanes/Network.prefPane" 2>/dev/null && return 0
    return 1
}

# ネットワーク接続を確保する（接続済みなら何も聞かずにスキップ）
ensure_network() {
    echo "ネットワーク接続を確認中"

    if is_online; then
        echo "ネットワークに接続済みのため、Wi-Fi設定はスキップします"
        return
    fi

    echo "ネットワークに接続されていません"
    echo "以降の処理（Homebrew・アプリのインストール）にはインターネット接続が必須です"

    # Wi-Fiがオフだと設定画面から接続できないため、先に有効化しておく
    local dev
    dev="$(wifi_device)"
    if [ -n "$dev" ]; then
        networksetup -setairportpower "$dev" on 2>/dev/null || true
    fi

    if open_wifi_settings; then
        echo "システム設定のWi-Fi画面を開きました。ネットワークに接続してください"
    else
        echo "設定画面を開けませんでした。メニューバーのWi-Fiアイコンから接続してください"
    fi
    echo "接続を検知すると自動的に続きを実行します（このターミナルに戻る必要はありません）"

    # 非対話モードでは無制限に待たず、タイムアウトしたら中止する
    if [ "$AUTO_YES" = "true" ]; then
        echo "最大 $((NETWORK_WAIT_AUTO / 60)) 分待機します"

        if wait_for_online "$NETWORK_WAIT_AUTO"; then
            echo "ネットワークに接続されました"
            return
        fi

        echo "ネットワークに接続できなかったため、セットアップを中止します"
        exit 1
    fi

    echo "中止する場合は Ctrl+C を押してください"
    wait_for_online 0
    echo "ネットワークに接続されました"
}

# Command Line Tools が使える状態かどうか
command_line_tools_installed() {
    # CLT単体パッケージが入っている場合
    if pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
        return 0
    fi

    # Xcode.app が選択されている場合はそのツールチェインで足りる
    local dev
    dev="$(xcode-select -p 2>/dev/null)" || return 1
    [ -n "$dev" ] && [ -x "$dev/usr/bin/git" ]
}

# Command Line Tools をインストールする
install_command_line_tools() {
    local placeholder="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    local label=""
    local waited=0

    # このプレースホルダがあると softwareupdate の一覧にCLTが現れる
    sudo touch "$placeholder" 2>/dev/null || true

    echo "softwareupdate 経由でのインストールを試みます（数分かかります）"
    label="$(softwareupdate -l 2>/dev/null \
        | grep -E '^[[:space:]]*\*' \
        | grep 'Command Line Tools' \
        | grep -v 'beta' \
        | sed -E 's/^[[:space:]]*\*[[:space:]]*(Label:[[:space:]]*)?//' \
        | sed -E 's/[[:space:]]*$//' \
        | sort -V \
        | tail -n 1)" || true

    if [ -n "$label" ]; then
        echo "対象: $label"
        if sudo softwareupdate -i "$label" --verbose; then
            sudo rm -f "$placeholder" 2>/dev/null || true
            return 0
        fi
        echo "softwareupdate でのインストールに失敗しました"
    else
        echo "softwareupdate に該当するパッケージが見つかりませんでした"
    fi

    sudo rm -f "$placeholder" 2>/dev/null || true

    # フォールバック: GUIのインストーラを起動し、完了を検知するまで待つ
    echo "GUIのインストーラを起動します"
    xcode-select --install >/dev/null 2>&1 || true
    echo "表示されたダイアログで「インストール」を選んでください"
    echo "完了を検知すると自動的に続きを実行します（中止する場合は Ctrl+C）"

    while [ "$waited" -lt "$CLT_WAIT" ]; do
        if command_line_tools_installed; then
            echo
            return 0
        fi

        if [ "$waited" -gt 0 ] && [ $((waited % REMINDER_INTERVAL)) -eq 0 ]; then
            print_waiting_notice "$waited" "Command Line Tools のインストールダイアログで「インストール」を選んでください"
        fi

        printf '.'
        sleep 5
        waited=$((waited + 5))
    done

    echo
    return 1
}

# Command Line Tools を確保する
ensure_command_line_tools() {
    echo "Command Line Tools を確認中"

    if command_line_tools_installed; then
        echo "Command Line Tools は既にインストールされています（$(xcode-select -p 2>/dev/null)）"
        return
    fi

    echo "Command Line Tools がインストールされていません"

    if ! install_command_line_tools; then
        echo "Command Line Tools のインストールを確認できませんでした"
        echo "手動で 'xcode-select --install' を実行してから、再度このスクリプトを実行してください"
        exit 1
    fi

    # 参照先が未設定なら CLT を選択しておく
    if ! xcode-select -p >/dev/null 2>&1 && [ -d "/Library/Developer/CommandLineTools" ]; then
        sudo xcode-select --switch /Library/Developer/CommandLineTools || true
    fi

    echo "Command Line Tools のインストール完了"
}

# sudo認証をスクリプト冒頭に一本化
request_sudo() {
    echo "管理者権限が必要な設定があるため、最初にパスワードを入力してください"
    sudo -v

    # スクリプト実行中はsudoのタイムスタンプを延長し続け、途中でパスワード再入力を求めない
    (
        while true; do
            sudo -n true
            sleep 60
            kill -0 "$$" 2>/dev/null || exit
        done
    ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

# Homebrew タップのクリーンアップ
cleanup_homebrew_taps() {
    echo "Homebrew タップをクリーンアップ中"
    
    # 問題のあるタップを削除
    local problematic_taps=(
        "homebrew/homebrew-cask-versions"
        "homebrew/cask-versions"
    )
    
    for tap in "${problematic_taps[@]}"; do
        if brew tap | grep -q "$tap" 2>/dev/null; then
            echo "問題のあるタップを削除中: $tap"
            brew untap "$tap" 2>/dev/null || true
        fi
    done
}

# Homebrew のセットアップ
setup_homebrew() {
    echo "Homebrew をセットアップ中"
    
    # PATHが通っていないだけの場合に備え、実体があれば先に読み込む
    if ! command -v brew &> /dev/null && [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    
    if command -v brew &> /dev/null; then
        echo "Homebrew は既にインストールされています"
        
        # タップをクリーンアップ
        cleanup_homebrew_taps
        
        return
    fi
    
    echo "Homebrew をインストール中"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # パスを追加
    if ! grep -q 'brew shellenv' ~/.zprofile 2>/dev/null; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
    
    # 初回セットアップ後のクリーンアップ
    cleanup_homebrew_taps
    
    echo "Homebrew インストール完了"
}

# Brewfile に基づいてアプリケーションをインストール
install_apps() {
    echo "Brewfile に基づいてアプリケーションをインストール中"
    
    if [ ! -f "$SCRIPT_DIR/Brewfile" ]; then
        echo "Brewfile が見つかりません: $SCRIPT_DIR/Brewfile"
        exit 1
    fi
    
    if brew bundle --file="$SCRIPT_DIR/Brewfile"; then
        echo "アプリケーションのインストール完了"
    else
        echo "一部アプリケーションのインストールに失敗しましたが、処理を続行します"
    fi
}

# Chrome をインストールする
install_chrome() {
    echo "Chrome をインストール中"

    if [ -d "/Applications/Google Chrome.app" ]; then
        echo "Chrome は既にインストールされています"
        return
    fi

    if ! brew install --cask google-chrome; then
        echo "Chrome のインストールに失敗しました。後続の一括インストールで再試行します"
    fi
}

# 現在デフォルトブラウザ（httpsハンドラ）に設定されているアプリのBundle IDを取得
# LaunchServices の設定は cfprefsd 管理のため defaults 経由で読む
current_default_browser() {
    defaults export com.apple.LaunchServices/com.apple.launchservices.secure - 2>/dev/null \
        | plutil -convert json -o - - 2>/dev/null \
        | jq -r '.LSHandlers[]? | select(.LSHandlerURLScheme == "https") | .LSHandlerRoleAll' 2>/dev/null \
        | head -n 1
}

chrome_is_default_browser() {
    local handler
    handler="$(current_default_browser | tr '[:upper:]' '[:lower:]')"
    [ "$handler" = "com.google.chrome" ]
}

# Chromeがデフォルトブラウザになるまで待つ（確認ダイアログや手動操作を待つため）
wait_for_default_browser() {
    local timeout="$1"
    local notice="$2"
    local waited=0

    while [ "$waited" -lt "$timeout" ]; do
        if chrome_is_default_browser; then
            echo
            return 0
        fi

        if [ "$waited" -gt 0 ] && [ $((waited % REMINDER_INTERVAL)) -eq 0 ]; then
            print_waiting_notice "$waited" "$notice"
        fi

        printf '.'
        sleep 5
        waited=$((waited + 5))
    done

    echo
    return 1
}

# デフォルトブラウザの設定画面を開く（OSバージョン差を吸収するため順にフォールバック）
open_default_browser_settings() {
    open "x-apple.systempreferences:com.apple.Desktop-Settings.extension" 2>/dev/null && return 0
    open "x-apple.systempreferences:com.apple.preference.general" 2>/dev/null && return 0
    open "/System/Library/PreferencePanes/Appearance.prefPane" 2>/dev/null && return 0
    return 1
}

# デフォルトブラウザをChromeに設定
# LaunchServices のplistを直接書き換える方法はAppleのサポート外で、
# httpsスキームのハンドラは変更できないため defaultbrowser コマンドを使う
set_chrome_default_browser() {
    echo "デフォルトブラウザをChromeに設定中"

    if [ ! -d "/Applications/Google Chrome.app" ]; then
        echo "Chrome がインストールされていないため、スキップします"
        return
    fi

    if ! command -v jq &> /dev/null; then
        echo "jq が見つからないため、設定結果を検証できません"
        echo "システム設定から手動で設定してください"
        open_default_browser_settings || true
        return
    fi

    if chrome_is_default_browser; then
        echo "既にChromeがデフォルトブラウザに設定されています"
        return
    fi

    if command -v defaultbrowser &> /dev/null; then
        defaultbrowser chrome >/dev/null 2>&1 || true

        # OSの確認ダイアログが出ることがあるため、反映されるまで待つ
        echo "確認ダイアログが表示された場合は「Chromeを使用」を選んでください"

        if wait_for_default_browser "$DEFAULT_BROWSER_WAIT" \
            "確認ダイアログが表示されていたら「Chromeを使用」を選んでください"; then
            echo "Chromeをデフォルトブラウザに設定しました"
            return
        fi

        echo "コマンドでの設定を確認できませんでした"
    else
        echo "defaultbrowser コマンドが見つかりませんでした"
    fi

    # 自動設定できなかった場合はGUIへ誘導する
    echo "システム設定を開きます。「デフォルトのWebブラウザ」でChromeを選んでください"
    open_default_browser_settings || echo "設定画面を開けませんでした"

    if wait_for_default_browser "$DEFAULT_BROWSER_MANUAL_WAIT" \
        "システム設定 > デスクトップとDock > デフォルトのWebブラウザ でChromeを選んでください"; then
        echo "Chromeをデフォルトブラウザに設定しました"
        return
    fi

    echo "Chromeがデフォルトブラウザに設定されていません"
    echo "セットアップ完了後に手動で設定してください"
}

# スクリーンセーバーとスリープを無効化（AC電源・バッテリー電源の両方）
disable_screensaver_and_sleep() {
    echo "スクリーンセーバーとスリープを無効化中"
    
    # スクリーンセーバーを無効化
    defaults -currentHost write com.apple.screensaver idleTime 0
    
    # ディスプレイ・システム・ハードディスクのスリープを無効化（AC・バッテリー両方）
    sudo pmset -a displaysleep 0 sleep 0 disksleep 0
    
    echo "スクリーンセーバーとスリープを無効化しました"
}

# トラックパッド・マウス設定
configure_trackpad() {
    echo "トラックパッド・マウス設定を変更中"
    
    # Tap to click を有効化
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
    defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
    defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
    
    # カーソル速度を最大に設定（トラックパッド・マウス両方）
    defaults write NSGlobalDomain com.apple.trackpad.scaling -float 3.0
    defaults write NSGlobalDomain com.apple.mouse.scaling -float 3.0
    
    # Click を Light（軽いクリック）に設定
    defaults write com.apple.AppleMultitouchTrackpad FirstClickThreshold -int 0
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad FirstClickThreshold -int 0
    
    # 3本指ドラッグを有効化
    defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true

    # 3本指ドラッグと競合する3本指スワイプを無効化
    # （Mission Control・スペース切り替えは4本指スワイプに集約する）
    defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture -int 0
    defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerVertSwipeGesture -int 0
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerHorizSwipeGesture -int 0
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerVertSwipeGesture -int 0
    defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture -int 2
    defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture -int 2
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture -int 2
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture -int 2

    # ナチュラルスクロールを無効化（一般的なスクロール方向にする）
    defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
    
    # Dock を再起動
    killall Dock 2>/dev/null || true
    
    echo "トラックパッド・マウス設定を完了しました"
    echo "  - Tap to click: 有効"
    echo "  - カーソル速度: 最大"
    echo "  - Click: Light（軽い）"
    echo "  - 3本指ドラッグ: 有効（Mission Controlなどは4本指スワイプ）"
    echo "  - ナチュラルスクロール: 無効"
}

# 時計とバッテリー表示設定
configure_menubar() {
    echo "メニューバーの表示設定を変更中"
    
    # 時計の表示形式を設定（秒表示、24時間表示）
    defaults write com.apple.menuextra.clock DateFormat -string "EEE d MMM HH:mm:ss"
    defaults write com.apple.menuextra.clock FlashDateSeparators -bool false
    
    # バッテリーのパーセンテージ表示を有効化
    defaults write com.apple.menuextra.battery ShowPercent -string "YES"
    defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true
    
    echo "メニューバーの表示設定を完了しました"
    echo "  - 時計: 秒表示・24時間表示"
    echo "  - バッテリー: パーセンテージ表示"
}

# Finder表示設定
configure_finder() {
    echo "Finderをカラム表示に設定中"
    
    # デフォルトビューをカラム表示に設定
    defaults write com.apple.finder FXPreferredViewStyle -string "clmv"
    
    # 隠しファイルを表示
    defaults write com.apple.finder AppleShowAllFiles -bool true
    
    # ファイル拡張子を表示
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true
    
    # パスバーを表示
    defaults write com.apple.finder ShowPathbar -bool true
    
    # ステータスバーを表示
    defaults write com.apple.finder ShowStatusBar -bool true
    
    # タイトルバーにフルパスを表示
    defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
    
    # サイドバーにホームフォルダを表示
    defaults write com.apple.finder ShowSidebar -bool true
    
    # Finder を再起動
    killall Finder 2>/dev/null || true
    
    echo "Finder表示設定を完了しました"
    echo "  - カラム表示"
    echo "  - 隠しファイル・拡張子表示"
    echo "  - パスバー・ステータスバー表示"
    echo "  - フルパスをタイトルバーに表示"
}

# ---------------------------------------------------------------------------
# 検証モード（--check）
# 設定は一切変更せず、実際の状態を読み取って PASS/FAIL を表示する
# 再起動後にこれを実行することで、その端末の設定が完了しているかを確認できる
# ---------------------------------------------------------------------------

CHECK_PASS=0
CHECK_FAIL=0

# defaults の値を取得する（未設定なら空文字を返す）
read_default() {
    defaults read "$1" "$2" 2>/dev/null || true
}

read_default_currenthost() {
    defaults -currentHost read "$1" "$2" 2>/dev/null || true
}

check_ok() {
    echo "  [OK] $1"
    CHECK_PASS=$((CHECK_PASS + 1))
}

check_ng() {
    echo "  [NG] $1${2:+（$2）}"
    CHECK_FAIL=$((CHECK_FAIL + 1))
}

# 期待値と実際の値を比較する
check_value() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$actual" = "$expected" ]; then
        check_ok "$name"
    else
        check_ng "$name" "期待: $expected / 実際: ${actual:-未設定}"
    fi
}

# コマンドの成否で判定する
check_condition() {
    local name="$1"
    local detail="$2"
    shift 2

    if "$@" >/dev/null 2>&1; then
        check_ok "$name"
    else
        check_ng "$name" "$detail"
    fi
}

# スリープ設定がAC・バッテリーの両方で無効になっているか
sleep_is_disabled() {
    local values
    values="$(pmset -g custom 2>/dev/null \
        | awk '$1=="displaysleep" || $1=="sleep" || $1=="disksleep" {print $2}')"

    [ -n "$values" ] && ! echo "$values" | grep -qv '^0$'
}

node_exporter_is_running() {
    brew services list 2>/dev/null | awk '$1=="node_exporter" {print $2}' | grep -q "started"
}

run_checks() {
    echo "セットアップ結果を検証します"
    echo

    echo "[前提ツール]"
    check_condition "Command Line Tools" "未インストール" command_line_tools_installed
    check_condition "Homebrew" "未インストール" command -v brew

    if command -v brew &> /dev/null; then
        check_condition "Brewfile のパッケージ" \
            "未導入の項目あり。brew bundle check --verbose --file=$SCRIPT_DIR/Brewfile で確認" \
            brew bundle check --file="$SCRIPT_DIR/Brewfile"
        check_condition "node_exporter サービス" "起動していません" node_exporter_is_running
    fi

    echo
    echo "[デフォルトブラウザ]"
    if command -v jq &> /dev/null; then
        local handler
        handler="$(current_default_browser)"
        check_condition "Chromeが既定" "現在: ${handler:-未設定}" chrome_is_default_browser
    else
        check_ng "Chromeが既定" "jq が無いため検証できません"
    fi

    echo
    echo "[スリープ・スクリーンセーバー]"
    check_value "スクリーンセーバー無効" "0" "$(read_default_currenthost com.apple.screensaver idleTime)"
    check_condition "スリープ無効（AC・バッテリー両方）" "有効なままの項目があります" sleep_is_disabled

    echo
    echo "[トラックパッド・マウス]"
    check_value "Tap to click（内蔵）" "1" "$(read_default com.apple.AppleMultitouchTrackpad Clicking)"
    check_value "Tap to click（Bluetooth）" "1" "$(read_default com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking)"
    check_value "カーソル速度（トラックパッド）" "3" "$(read_default NSGlobalDomain com.apple.trackpad.scaling)"
    check_value "カーソル速度（マウス）" "3" "$(read_default NSGlobalDomain com.apple.mouse.scaling)"
    check_value "クリック感度Light" "0" "$(read_default com.apple.AppleMultitouchTrackpad FirstClickThreshold)"
    check_value "3本指ドラッグ" "1" "$(read_default com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag)"
    check_value "ナチュラルスクロール無効" "0" "$(read_default NSGlobalDomain com.apple.swipescrolldirection)"

    echo
    echo "[メニューバー]"
    check_value "時計の表示形式" "EEE d MMM HH:mm:ss" "$(read_default com.apple.menuextra.clock DateFormat)"
    check_value "バッテリー％表示" "1" "$(read_default_currenthost com.apple.controlcenter BatteryShowPercentage)"

    echo
    echo "[Finder]"
    check_value "カラム表示" "clmv" "$(read_default com.apple.finder FXPreferredViewStyle)"
    check_value "隠しファイル表示" "1" "$(read_default com.apple.finder AppleShowAllFiles)"
    check_value "拡張子表示" "1" "$(read_default NSGlobalDomain AppleShowAllExtensions)"
    check_value "パスバー表示" "1" "$(read_default com.apple.finder ShowPathbar)"
    check_value "ステータスバー表示" "1" "$(read_default com.apple.finder ShowStatusBar)"
    check_value "フルパス表示" "1" "$(read_default com.apple.finder _FXShowPosixPathInTitle)"

    echo
    echo "============================================================"
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo " 結果: すべて OK（$CHECK_PASS 項目）"
        echo "============================================================"
        return 0
    fi

    echo " 結果: $CHECK_FAIL 件の未設定あり（OK: $CHECK_PASS 件）"
    echo " setup.sh を再実行するか、上記の [NG] 項目を手動で設定してください"
    echo "============================================================"
    return 1
}

# セットアップ完了後の再起動確認
prompt_reboot() {
    echo "一部の設定は再起動後に反映されます"
    
    if [ "$AUTO_YES" = "true" ]; then
        echo "再起動します..."
        sudo shutdown -r now
        return
    fi
    
    # パイプ実行などで標準入力がない場合、read は即失敗するため再起動は行わない
    if [ ! -t 0 ]; then
        echo "対話できない環境のため、再起動をスキップしました。手動で再起動してください"
        return
    fi
    
    local answer=""
    read -r -p "今すぐ再起動しますか？ [y/N] " answer || true
    case "$answer" in
        [yY]*)
            echo "再起動します..."
            sudo shutdown -r now
            ;;
        *)
            echo "再起動をスキップしました。設定を反映するには手動で再起動してください"
            ;;
    esac
}

main() {
    AUTO_YES="false"
    
    case "${1:-}" in
        -y|--yes)
            AUTO_YES="true"
            ;;
        --check)
            # 検証のみ。設定は変更しないため管理者権限も不要
            if run_checks; then
                exit 0
            fi
            exit 1
            ;;
    esac
    
    echo "macOS セットアップ"
    
    # 最初にネットワーク接続を確保する（以降の処理はすべて接続を前提とする）
    ensure_network
    
    # 管理者権限をあらかじめ取得し、以降のsudoプロンプトをなくす
    # （Command Line Tools のインストールにも必要なため、ここで取得しておく）
    request_sudo
    
    # インストールに時間がかかるため、先にスリープを無効化しておく
    disable_screensaver_and_sleep
    
    # Command Line Tools のセットアップ（Homebrew などの前提）
    ensure_command_line_tools
    
    # Homebrew のセットアップ
    setup_homebrew
    
    install_chrome
    set_chrome_default_browser
    
    echo
    echo "============================================================"
    echo " ここから先は操作不要です。この端末を離れて構いません"
    echo " 残りの処理: アプリの一括インストール → macOS設定 → 再起動"
    echo "============================================================"
    echo
    
    # アプリケーションのインストール
    install_apps
    
    # macOS設定の変更
    configure_trackpad
    configure_menubar
    configure_finder
    
    echo "セットアップ完了"
    
    prompt_reboot
}
main "$@"
