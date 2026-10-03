#!/bin/bash
# ==============================================================================
# run_tests.sh - sf-tools テストスイート実行スクリプト
# ==============================================================================
# 使い方: bash tests/run_tests.sh [テストファイル名]
#   引数なし → 全テストを順番に実行
#   引数あり → 指定したテストのみ実行（例: bash run_tests.sh test_sf-hook.sh）
# ==============================================================================

# Windows Git Bash の場合は WSL で自動リダイレクト（高速化）
if [[ "$(uname -s)" =~ MINGW|MSYS ]] && command -v wsl >/dev/null 2>&1; then
    WSL_SCRIPT=$(echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" \
        | sed 's|^/\([a-z]\)/|/mnt/\1/|')
    MSYS_NO_PATHCONV=1 exec wsl bash "$WSL_SCRIPT" "$@"
fi

# WSL で /mnt/ 配下（Windows FS）から実行された場合、ネイティブ FS に同期して再実行
# /mnt/c/ 経由の tar / rsync は 9P プロトコルのオーバーヘッドで極めて遅いため、
# ~/sf-tools（ext4）に一度同期してから実行することで大幅に高速化する。
if [[ "$(uname -s)" == "Linux" ]] && [[ "${BASH_SOURCE[0]}" == /mnt/* ]]; then
    _src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    _dst="${HOME}/sf-tools"
    echo "  [run_tests] WSL ネイティブ FS に同期中: ${_dst} ..."
    rsync -a --delete "${_src}/" "${_dst}/"
    exec bash "${_dst}/tests/run_tests.sh" "$@"
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$TESTS_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_tests.log"
TOTAL_PASSED=0
TOTAL_FAILED=0
FAIL_LINES=""  # 失敗したテスト行を蓄積

CLR_PASS='\033[32m'
CLR_FAIL='\033[31m'
CLR_HEAD='\033[36m'
CLR_RST='\033[0m'

# 実行するテストファイルを順番に定義
TEST_FILES=(
    test_common.sh
    test_init-common.sh
    test_sf-unhook.sh
    test_sf-hook.sh
    test_sf-init.sh
    test_sf-upgrade.sh
    test_sf-install.sh
    test_sf-start.sh
    test_sf-restart.sh
    test_sf-metasync.sh
    test_sf-release.sh
    test_sf-deploy.sh
    test_sf-dryrun.sh
    test_sf-job.sh
    test_sf-next.sh
    test_sf-check.sh
    test_sf-prepush.sh
    test_sf-push.sh
    test_sf-update-secret.sh
    test_sf-launcher.sh
    test_sf-precommit.sh
    test_security.sh
)

# ------------------------------------------------------------------------------
# テスト未登録チェック（引数なし＝全実行時のみ）
# tests/test_*.sh が TEST_FILES に全て含まれているか検証する。
# 漏れがあれば WARNING を表示してデグレ検知漏れを防ぐ。
# ------------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    _missing=()
    for _f in "$TESTS_DIR"/test_*.sh; do
        _name=$(basename "$_f")
        [[ "$_name" == "test_helper.sh" ]] && continue  # ヘルパーファイルは除外
        _found=0
        for _registered in "${TEST_FILES[@]}"; do
            [[ "$_registered" == "$_name" ]] && { _found=1; break; }
        done
        [[ $_found -eq 0 ]] && _missing+=("$_name")
    done
    if [[ ${#_missing[@]} -gt 0 ]]; then
        echo -e "${CLR_FAIL}[WARNING] 以下のテストファイルが TEST_FILES に未登録です:${CLR_RST}"
        for _m in "${_missing[@]}"; do
            echo -e "${CLR_FAIL}  - $_m${CLR_RST}"
        done
        echo -e "${CLR_FAIL}  run_tests.sh の TEST_FILES に追加してください。${CLR_RST}"
        echo ""
    fi
fi

# --changed フラグ: git 変更ファイルから対応テストを自動選択
if [[ "${1:-}" == "--changed" ]]; then
    shift
    _changed_tests=()
    _run_all=0

    while IFS= read -r _file; do
        case "$_file" in
            bin/sf-*.sh)
                # bin/sf-foo.sh → test_sf-foo.sh
                _t="test_$(basename "$_file")"
                _changed_tests+=("$_t")
                ;;
            lib/common.sh)
                _changed_tests+=("test_common.sh")
                ;;
            phases/init/*)
                _changed_tests+=("test_sf-init.sh")
                ;;
            hooks/pre-push)
                _changed_tests+=("test_sf-prepush.sh")
                ;;
            tests/test_helper.sh)
                # 共通ヘルパー変更は全テストに影響するため全件実行
                _run_all=1
                break
                ;;
        esac
    done < <(git -C "$TESTS_DIR/.." diff --name-only HEAD 2>/dev/null)

    if [[ $_run_all -eq 0 && ${#_changed_tests[@]} -gt 0 ]]; then
        # 重複排除
        mapfile -t TEST_FILES < <(printf '%s\n' "${_changed_tests[@]}" | sort -u)
        echo "  [--changed] 対象テスト: ${TEST_FILES[*]}"
    elif [[ $_run_all -eq 0 && ${#_changed_tests[@]} -eq 0 ]]; then
        echo "  [--changed] 変更ファイルに対応するテストなし → 全テスト実行"
    fi
fi

# 引数指定があれば対象を絞る（--changed 以外の通常引数）
if [[ $# -gt 0 ]]; then
    TEST_FILES=("$@")
fi

# 画面とログファイルの両方に出力する関数
tee_log() { tee -a "$LOG_FILE"; }

# ログファイルを初期化
echo "====== テスト開始: $(date '+%Y-%m-%d %H:%M:%S') ======" > "$LOG_FILE"

echo ""
echo "========================================"
echo "  sf-tools テストスイート"
echo "========================================"

# 引数1件のみ（単一ファイル指定）の場合は並列化不要なのでそのまま実行
_run_single() {
    local test_path="$1"
    echo "" | tee_log
    local output
    output=$(bash "$test_path" 2>&1)
    echo "$output" | tee_log
    TOTAL_PASSED=$(( TOTAL_PASSED + $(echo "$output" | grep -c '\[PASS\]' || true) ))
    TOTAL_FAILED=$(( TOTAL_FAILED + $(echo "$output" | grep -c '\[FAIL\]'  || true) ))
    FAIL_LINES+="$(echo "$output" | grep '\[FAIL\]' || true)"$'\n'
}

if [[ ${#TEST_FILES[@]} -eq 1 ]]; then
    # 単一ファイル: 逐次実行
    test_path="$TESTS_DIR/${TEST_FILES[0]}"
    if [[ ! -f "$test_path" ]]; then
        echo -e "${CLR_FAIL}[SKIP] ${TEST_FILES[0]} が見つかりません${CLR_RST}" | tee_log
    else
        _run_single "$test_path"
    fi
else
    # 複数ファイル: 並列実行（各ファイルをバックグラウンドで起動し tmp に出力を保存）
    declare -a _pids=()
    declare -a _tmps=()

    for test_file in "${TEST_FILES[@]}"; do
        test_path="$TESTS_DIR/$test_file"
        if [[ ! -f "$test_path" ]]; then
            _pids+=(-1)
            _tmps+=("")
            continue
        fi
        tmp=$(mktemp /tmp/sftest-XXXX)
        bash "$test_path" > "$tmp" 2>&1 &
        _pids+=($!)
        _tmps+=("$tmp")
    done

    # 起動順に wait → 出力を順番に表示・集計
    for i in "${!TEST_FILES[@]}"; do
        test_file="${TEST_FILES[$i]}"
        pid="${_pids[$i]}"
        tmp="${_tmps[$i]}"

        if [[ "$pid" == "-1" ]]; then
            echo -e "${CLR_FAIL}[SKIP] ${test_file} が見つかりません${CLR_RST}" | tee_log
            continue
        fi

        wait "$pid"
        echo "" | tee_log
        output=$(cat "$tmp")
        echo "$output" | tee_log
        TOTAL_PASSED=$(( TOTAL_PASSED + $(echo "$output" | grep -c '\[PASS\]' || true) ))
        TOTAL_FAILED=$(( TOTAL_FAILED + $(echo "$output" | grep -c '\[FAIL\]'  || true) ))
        FAIL_LINES+="$(echo "$output" | grep '\[FAIL\]' || true)"$'\n'
        rm -f "$tmp"
    done
fi

# 総合サマリー
TOTAL=$((TOTAL_PASSED + TOTAL_FAILED))
# 緑太文字 / 赤太文字（背景なし）
CLR_OK='\033[32;1m'
CLR_NG='\033[31;1m'

echo "" | tee_log
W=60  # バナー内側の幅
_banner_line() { local c="$1" msg="$2"; local pad=$(( (W - ${#msg}) / 2 )); printf "${c}    %${pad}s%s%$(( W - pad - ${#msg} ))s    ${CLR_RST}\n" "" "$msg" ""; }
_banner_border() { local c="$1"; printf "${c}    "; printf '=%.0s' $(seq 1 $W); printf "    ${CLR_RST}\n"; }
_banner_blank() { local c="$1"; printf "${c}    %${W}s    ${CLR_RST}\n" ""; }

if [[ $TOTAL_FAILED -eq 0 ]]; then
    MSG=">>> ALL ${TOTAL} TESTS PASSED !! <<<"
    {
        echo ""
        _banner_blank  "$CLR_OK"
        _banner_border "$CLR_OK"
        _banner_blank  "$CLR_OK"
        _banner_line   "$CLR_OK" "$MSG"
        _banner_blank  "$CLR_OK"
        _banner_border "$CLR_OK"
        _banner_blank  "$CLR_OK"
        echo ""
    } | tee_log
    exit 0
else
    MSG=">>> FAILED: ${TOTAL_FAILED} / ${TOTAL} TESTS <<<"
    {
        echo ""
        _banner_blank  "$CLR_NG"
        _banner_border "$CLR_NG"
        _banner_blank  "$CLR_NG"
        _banner_line   "$CLR_NG" "$MSG"
        _banner_blank  "$CLR_NG"
        _banner_border "$CLR_NG"
        _banner_blank  "$CLR_NG"
        echo ""
        # 失敗したテスト一覧を表示
        echo -e "${CLR_NG}  失敗したテスト:${CLR_RST}"
        echo "$FAIL_LINES" | grep -v '^$' | sed "s/^/  /" | tee_log
        echo ""
    } | tee_log
    exit 1
fi
