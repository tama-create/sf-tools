#!/bin/bash
# ==============================================================================
# run_tests.sh - sf-tools テストスイート実行スクリプト
# ==============================================================================
# 使い方: bash tests/run_tests.sh [テストファイル名]
#   引数なし → 全テストを順番に実行
#   引数あり → 指定したテストのみ実行（例: bash run_tests.sh test_sf-hook.sh）
#   --jobs N / --serial : 同時に動かすテストファイルの数（既定: CPU の数。環境変数 SF_TEST_JOBS でも指定できる。
#                         --serial は 1 = 1 つずつ）。時間のかかるファイルから先に起動する（全体の時間を短くするため）
#   --shard I/N         : テストファイルを N 組に分け、I 番目（1 始まり）の組だけを実行する（GitHub Actions で、複数のジョブに分けて、並列に動かすため。
#                         Windows の全件が約 21 分かかるのを、短くする）。分け方は、ファイルごとの目安の時間（_weight）で、重いものから、いちばん軽い組へ、
#                         順に割り当てる（どの環境でも、同じ分け方になる）。N 組を全部動かすと、全ファイルが、ちょうど 1 回ずつ動く
#   環境変数 SF_TEST_LIST_ONLY=1 : 実行せずに、対象のテストファイル名を表示して終わる（--shard の分け方の確認用）
#   環境変数 SF_TEST_TIMES=1 : 各ファイルの所要時間（[TIME] 行）を、最後に、長い順に表示する（_weight の目安を、実測で直すため）
# ==============================================================================

# Windows Git Bash の場合は WSL で自動リダイレクト（高速化）
#   SF_TEST_NO_WSL=1 で、移らない（GitHub Actions の Windows ランナーなど、WSL を使えない環境で、Git Bash のまま実行する）
if [[ "$(uname -s)" =~ MINGW|MSYS ]] && [[ "${SF_TEST_NO_WSL:-}" != "1" ]] && command -v wsl >/dev/null 2>&1; then
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

# WSL（非対話の bash）では、nvm が読み込まれず、nvm で入れた node が見つからない（nvm は ~/.bashrc で読み込まれるため）。
# node が見つからず、nvm の node があるときだけ、その bin を PATH に加える（lib/typecheck.js のテストが、node を使う）。
# 通常の環境（node が PATH にある・nvm がない）には、影響しない
if ! command -v node >/dev/null 2>&1 && [[ -d "${HOME}/.nvm/versions/node" ]]; then  # 存在確認のため run 不使用
    _nvm_node=""
    for _d in "${HOME}"/.nvm/versions/node/v*/bin; do [[ -x "$_d/node" ]] && _nvm_node="$_d"; done  # 最後（番号順で最も新しい）を使う
    [[ -n "$_nvm_node" ]] && export PATH="${_nvm_node}:${PATH}"
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$TESTS_DIR/../logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_tests.log"
TOTAL_PASSED=0
TOTAL_FAILED=0
FAIL_LINES=""  # 失敗したテスト行を蓄積
TIME_LINES=""  # ファイルごとの所要時間（[TIME] 行）を蓄積（SF_TEST_TIMES=1 のとき、最後に表示する）

CLR_PASS='\033[32m'
CLR_FAIL='\033[31m'
CLR_HEAD='\033[36m'
CLR_RST='\033[0m'

# テストは、実行する環境に左右されないこと。GitHub Actions 上では GITHUB_ACTIONS=true が設定されており、
# sf-tools のスクリプトは、これを見て動作を変える（確認・警告を飛ばす・e2e を拒否するなど）。
# そのため、ここで外す（GITHUB_ACTIONS=true の動作を確認するテストは、そのテストの中で、明示的に設定する）
unset GITHUB_ACTIONS CI

# 実際の Git・npm・sf の「更新」を、テストが実行しないための保護。
#   sf-install.sh は、sf-upgrade.sh をバックグラウンドで起動する。テストは、短い待ちのあとに、モック（偽の npm / sf / git）の
#   フォルダを消すため、動作の遅い環境（Windows の Git Bash）では、残りの処理が、本物の
#   `git update-git-for-windows --yes`（Git for Windows のインストーラー。実行中の Git Bash 自体が壊れ、終了コード 2304 で
#   異常終了した）・`npm install -g`・`sf update` を実行してしまう。
#   PATH の先頭に、これらの「更新」だけを無効にする代理のコマンドを置く（ほかの使い方は、本物にそのまま渡す。モックは、
#   各テストが、さらにその前に置くので、変わらない）。本物がない場合は、代理も作らない（「npm がない」環境のテストを保つため）
_make_guard_bin() {
    local d real
    d=$(mktemp -d "${TMPDIR:-/tmp}/sftest-guard-XXXX") || return 1
    real=$(command -v git 2>/dev/null) || real=""
    if [[ -n "$real" ]]; then
        cat > "$d/git" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "update-git-for-windows" ]]; then
    echo "[sftest-guard] git update-git-for-windows は、テストでは実行しません" >&2; exit 0
fi
exec "$real" "\$@"
EOF
        chmod +x "$d/git"
    fi
    real=$(command -v npm 2>/dev/null) || real=""
    if [[ -n "$real" ]]; then
        cat > "$d/npm" <<EOF
#!/bin/bash
_g=0
for _a in "\$@"; do [[ "\$_a" == "-g" || "\$_a" == "--global" ]] && _g=1; done
case "\${1:-}" in
    install|i|add|update|up|upgrade|uninstall|remove|rm)
        if [[ \$_g -eq 1 ]]; then
            echo "[sftest-guard] npm \$* は、テストでは実行しません" >&2; exit 0
        fi ;;
esac
exec "$real" "\$@"
EOF
        chmod +x "$d/npm"
    fi
    real=$(command -v sf 2>/dev/null) || real=""
    if [[ -n "$real" ]]; then
        cat > "$d/sf" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "update" ]]; then
    echo "[sftest-guard] sf update は、テストでは実行しません" >&2; exit 0
fi
exec "$real" "\$@"
EOF
        chmod +x "$d/sf"
    fi
    printf '%s' "$d"
}
# SF_TEST_LIST_ONLY=1（一覧を表示するだけ。テストは動かさない）のときは、保護用のフォルダは不要（動作の遅い環境で、作成に数秒かかるため）
if [[ "${SF_TEST_LIST_ONLY:-}" != "1" ]] && [[ -z "${SF_TEST_GUARD_BIN:-}" || ! -d "${SF_TEST_GUARD_BIN:-}" ]]; then
    SF_TEST_GUARD_BIN=$(_make_guard_bin) || SF_TEST_GUARD_BIN=""
    if [[ -n "$SF_TEST_GUARD_BIN" ]]; then
        export SF_TEST_GUARD_BIN
        export PATH="${SF_TEST_GUARD_BIN}:${PATH}"
        trap 'rm -rf "${SF_TEST_GUARD_BIN:?}" 2>/dev/null' EXIT   # run 不使用: 保護用の一時フォルダの後始末
    fi
fi

# 同時に動かすテストファイルの数（先頭の --jobs N / --jobs=N / --serial を、読み取る）
JOBS="${SF_TEST_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"   # macOS には nproc がない
while [[ "${1:-}" == "--jobs" || "${1:-}" == --jobs=* || "${1:-}" == "--serial" ]]; do
    case "$1" in
        --serial)  JOBS=1; shift ;;
        --jobs)    JOBS="${2:-}"; shift 2 || shift ;;
        --jobs=*)  JOBS="${1#--jobs=}"; shift ;;
    esac
done
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "--jobs には、1 以上の整数を指定してください: ${JOBS}" >&2
    exit 2
fi

# --shard I/N（先頭の --jobs などと同じ並びで、読み取る）
SHARD=""
while [[ "${1:-}" == "--shard" || "${1:-}" == --shard=* ]]; do
    case "$1" in
        --shard)   SHARD="${2:-}"; shift 2 || shift ;;
        --shard=*) SHARD="${1#--shard=}"; shift ;;
    esac
done
if [[ -n "$SHARD" ]]; then
    if ! [[ "$SHARD" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] || (( ${SHARD%/*} > ${SHARD#*/} )); then
        echo "--shard には、I/N（1 <= I <= N）の形で指定してください: ${SHARD}" >&2
        exit 2
    fi
fi

# 時間のかかるファイル（先に起動する。最後に長いものが残って、全体が伸びるのを避ける）
HEAVY_FIRST=(test_integration-init.sh test_integration-init2.sh test_integration-init3.sh test_integration.sh test_integration-git.sh test_sf-init.sh test_sf-init2.sh test_sf-init3.sh test_e2e.sh test_verify.sh test_sf-release.sh test_sf-install.sh)

# ファイルごとの所要時間の目安（秒。--shard が、組に分けるときの重み。未登録は 10）。
#   値は、GitHub Actions の Windows での実測（2026-10-20・コミット 5eb8c6f の SF_TEST_TIMES=1 の [TIME] 行。ジョブの中で並列に動かした値）
#   厳密である必要はない（目安が少しずれても、全ファイルが、ちょうど 1 回ずつ動く）。大きくずれたら、実測で直す
_weight() {   # 結果は、変数 _W に入れる（$(...) で呼ぶと、Windows の Git Bash では、ファイルごとにプロセスを起動して遅い）
    case "$1" in
        test_sf-init.sh|test_sf-init2.sh|test_sf-init3.sh) _W=320 ;;   # 元は 1 ファイルで 960 秒（Actions の Windows）。3 つに均等に分けた
        test_verify.sh) _W=640 ;;
        test_e2e.sh) _W=510 ;;
        test_integration-init.sh) _W=370 ;;
        test_integration-init2.sh) _W=330 ;;
        test_integration-init3.sh) _W=270 ;;
        test_integration-misc.sh) _W=230 ;;
        test_integration.sh) _W=220 ;;
        test_sf-install.sh) _W=185 ;;
        test_integration-git.sh) _W=140 ;;
        test_integration-job.sh) _W=125 ;;
        test_common.sh|test_integration-metasync.sh|test_sf-release.sh) _W=120 ;;
        test_integration-next.sh|test_integration-guards.sh) _W=85 ;;
        test_project-identity.sh|test_sf-metasync.sh|test_integration-coverage.sh) _W=75 ;;
        test_integration-rerun.sh|test_init-common.sh|test_sf-deploy.sh) _W=62 ;;
        test_sf-job.sh|test_sf-sync-wf.sh|test_sf-next.sh|test_sf-prepush.sh|test_sf-start.sh|test_wf-sequence.sh) _W=50 ;;
        test_integration-secrets.sh|test_sf-hook.sh) _W=40 ;;
        test_sf-typecheck.sh|test_sf-push.sh|test_sf-upgrade.sh|test_org.sh|test_diag.sh|test_run-tests.sh) _W=28 ;;
        *) _W=10 ;;
    esac
}

# 実行するテストファイルを順番に定義
TEST_FILES=(
    test_common.sh
    test_wizard.sh
    test_org.sh
    test_diag.sh
    test_verify.sh
    test_init-common.sh
    test_sf-unhook.sh
    test_sf-hook.sh
    test_sf-init.sh
    test_sf-init2.sh
    test_sf-init3.sh
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
    test_sf-typecheck.sh
    test_sf-prepush.sh
    test_sf-push.sh
    test_sf-update-secret.sh
    test_sf-launcher.sh
    test_sf-precommit.sh
    test_security.sh
    test_e2e.sh
    test_sf-sync-wf.sh
    test_wf-sequence.sh
    test_project-identity.sh
    test_integration-coverage.sh
    test_integration.sh
    test_integration-git.sh
    test_integration-guards.sh
    test_integration-secrets.sh
    test_integration-job.sh
    test_integration-misc.sh
    test_integration-init.sh
    test_integration-init2.sh
    test_integration-metasync.sh
    test_integration-next.sh
    test_integration-init3.sh
    test_integration-rerun.sh
    test_run-tests.sh
    test_site.sh
    test_docs.sh
    test_cli_args.sh
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
        # 結合テストのカバレッジ表のガード: コマンド・フック・ワークフロー・計画書が変わったとき
        case "$_file" in
            bin/sf-*.sh|hooks/*|templates/.github/workflows/*.yml|doc/integration-test-plan.md|tests/test_integration-coverage.sh)
                _changed_tests+=("test_integration-coverage.sh")
                ;;
        esac
        # 結合テスト（L1）: コマンド・フック・結合テストの部品が変わったとき（時間がかかる: 1 回に数分）
        case "$_file" in
            bin/sf-*.sh|hooks/*|tests/integration/*|tests/test_integration.sh|tests/test_integration-[!c]*.sh)
                _changed_tests+=("test_integration.sh" "test_integration-git.sh" "test_integration-guards.sh" "test_integration-secrets.sh" "test_integration-job.sh" "test_integration-misc.sh" "test_integration-init.sh" "test_integration-init2.sh" "test_integration-metasync.sh" "test_integration-next.sh" "test_integration-init3.sh" "test_integration-rerun.sh")
                ;;
        esac
        case "$_file" in
            bin/sf-*.sh)
                # bin/sf-foo.sh → test_sf-foo.sh
                _t="test_$(basename "$_file")"
                _changed_tests+=("$_t")
                [[ "$_t" == "test_sf-init.sh" ]] && _changed_tests+=("test_sf-init2.sh" "test_sf-init3.sh")   # sf-init のテストは、3 つのファイルに分けてある
                ;;
            lib/common.sh|lib/input.sh|lib/platform.sh)
                # common.sh は、input.sh / platform.sh / project.sh を source する（どれを変えても、test_common.sh）
                _changed_tests+=("test_common.sh")
                ;;
            lib/wizard.sh)
                _changed_tests+=("test_wizard.sh")
                ;;
            lib/org.sh)
                _changed_tests+=("test_org.sh")
                ;;
            lib/project.sh)
                _changed_tests+=("test_common.sh" "test_project-identity.sh")
                ;;
            lib/diag.sh)
                _changed_tests+=("test_diag.sh")
                ;;
            lib/typecheck.js)
                _changed_tests+=("test_sf-typecheck.sh")
                ;;
            templates/.github/workflows/wf-sequence.yml)
                _changed_tests+=("test_wf-sequence.sh" "test_sf-sync-wf.sh")
                ;;
            config/changeset-types.txt)
                _changed_tests+=("test_sf-typecheck.sh")
                ;;
            config/metadata-capability.txt)
                _changed_tests+=("test_sf-check.sh")
                ;;
            lib/verify-common.sh)
                _changed_tests+=("test_verify.sh")
                ;;
            phases/init/verify.sh)
                _changed_tests+=("test_verify.sh")
                ;;
            phases/init/*|tests/init-test-lib.sh)
                _changed_tests+=("test_sf-init.sh" "test_sf-init2.sh" "test_sf-init3.sh")   # sf-init のテストは、3 つのファイルに分けてある（共通の部品: tests/init-test-lib.sh）
                ;;
            hooks/pre-push)
                _changed_tests+=("test_sf-prepush.sh")
                ;;
            tests/e2e/*)
                _changed_tests+=("test_e2e.sh")
                ;;
            *.md|tests/test_docs.sh)
                _changed_tests+=("test_docs.sh")
                ;;
            site/*|.github/workflows/pages.yml|tests/test_site.sh)
                _changed_tests+=("test_site.sh")
                ;;
            tests/test_cli_args.sh)
                _changed_tests+=("test_cli_args.sh")
                ;;
            tests/run_tests.sh|tests/test_run-tests.sh)
                _changed_tests+=("test_run-tests.sh")
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
        # mapfile は Bash 4 以降のため使わない（macOS 標準の Bash 3.2 で動かす）
        TEST_FILES=()
        while IFS= read -r _tf; do TEST_FILES+=("$_tf"); done < <(printf '%s\n' "${_changed_tests[@]}" | sort -u)
        echo "  [--changed] 対象テスト: ${TEST_FILES[*]}"
    elif [[ $_run_all -eq 0 && ${#_changed_tests[@]} -eq 0 ]]; then
        echo "  [--changed] 変更ファイルに対応するテストなし → 全テスト実行"
    fi
fi

# 引数指定があれば対象を絞る（--changed 以外の通常引数）
if [[ $# -gt 0 ]]; then
    TEST_FILES=("$@")
fi

# CI の全件テスト用: 結合テスト（test_integration.sh）は、別のジョブ（OS ごと）で動かすため、全件の実行から外す。
#   SF_TEST_SKIP_INTEGRATION=1 のとき、引数なし・--changed の実行から外す（ファイルを名指しした実行は、そのまま動く）
if [[ "${SF_TEST_SKIP_INTEGRATION:-}" == "1" && $# -eq 0 ]]; then
    _kept=()
    for _tf in "${TEST_FILES[@]}"; do
        # test_integration-coverage.sh（表のガード。速い）は、残す。そのほかの test_integration*.sh（結合テスト L1）を、外す
        [[ "$_tf" == test_integration*.sh && "$_tf" != "test_integration-coverage.sh" ]] || _kept+=("$_tf")
    done
    TEST_FILES=("${_kept[@]}")
fi

# --shard I/N: N 組に分けて、I 番目の組だけを実行する。重い順に並べ、いちばん軽い組へ、順に割り当てる（貪欲法。同じ重さなら、番号の小さい組）。
#   並べ方は、重み（大きい順）→ ファイル名（辞書順）。どの環境でも、同じ分け方になる
if [[ -n "$SHARD" ]]; then
    _si=${SHARD%/*}; _sn=${SHARD#*/}
    _loads=(); for (( _k = 0; _k < _sn; _k++ )); do _loads[_k]=0; done
    _mine=()
    while IFS= read -r _line; do
        _w="${_line%% *}"; _f="${_line#* }"
        _best=0
        for (( _k = 1; _k < _sn; _k++ )); do (( _loads[_k] < _loads[_best] )) && _best=$_k; done
        _loads[_best]=$(( _loads[_best] + _w ))
        (( _best == _si - 1 )) && _mine+=("$_f")
    done < <(for _f in "${TEST_FILES[@]}"; do _weight "$_f"; printf '%s %s\n' "$_W" "$_f"; done | sort -k1,1nr -k2,2)
    echo "  [--shard ${SHARD}] 対象テスト（${#_mine[@]} 件）: ${_mine[*]:-なし}" >&2
    if [[ ${#_mine[@]} -eq 0 ]]; then echo "  この組には、実行するテストがありません。" >&2; exit 0; fi
    TEST_FILES=("${_mine[@]}")
fi
# SF_TEST_LIST_ONLY=1: 実行せずに、対象のテストファイル名を、1 行ずつ表示して終わる（--shard の分け方の確認用）
if [[ "${SF_TEST_LIST_ONLY:-}" == "1" ]]; then
    printf '%s\n' "${TEST_FILES[@]}"
    exit 0
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
    # 複数ファイル: 並列実行（各ファイルをバックグラウンドで起動し tmp に出力を保存）。
    #   同時に動かす数は JOBS まで（全ファイルを一斉に動かすと、CPU を取り合って、かえって遅くなる）。
    #   起動の順は、時間のかかるファイルが先。表示と集計は、TEST_FILES の順
    declare -a _pids=()
    declare -a _tmps=()
    declare -a _order=()
    for i in "${!TEST_FILES[@]}"; do _pids[$i]=-1; _tmps[$i]=""; done
    for _h in "${HEAVY_FIRST[@]}"; do
        for i in "${!TEST_FILES[@]}"; do
            [[ "${TEST_FILES[$i]}" == "$_h" ]] && _order+=("$i")
        done
    done
    for i in "${!TEST_FILES[@]}"; do
        _in=0
        for _j in "${_order[@]}"; do [[ "$_j" == "$i" ]] && { _in=1; break; }; done
        [[ $_in -eq 0 ]] && _order+=("$i")
    done

    for i in "${_order[@]}"; do
        test_path="$TESTS_DIR/${TEST_FILES[$i]}"
        [[ -f "$test_path" ]] || continue   # 見つからないファイルは、pid が -1 のまま（表示のときに SKIP）
        while (( $(jobs -rp | wc -l) >= JOBS )); do
            # wait -n は使わない（Bash 4.3 以降の機能。macOS 標準の 3.2 で動かすため。CLAUDE.md 2.2）。少し待って、数え直す
            sleep 0.2
        done
        # SF_TEST_PROGRESS=1: 起動するテストファイルを、順に表示する（結果は、全部の起動後にまとめて出るため、
        #   途中で異常終了したときに、どのファイルで止まったかを、分かるようにする。GitHub Actions の Windows 用）
        [[ "${SF_TEST_PROGRESS:-}" == "1" ]] && echo "  [START] ${TEST_FILES[$i]} ($(date '+%H:%M:%S'))" >&2
        tmp=$(mktemp /tmp/sftest-XXXX)
        # 標準入力は閉じる（入力待ちで、止まらないため）。ファイルごとの所要時間（[TIME] 行）を、出力の最後に足す
        ( _t0=$SECONDS; bash "$test_path"; _rc=$?; echo "  [TIME] ${TEST_FILES[$i]} $(( SECONDS - _t0 )) 秒"; exit $_rc ) > "$tmp" 2>&1 < /dev/null &
        _pids[$i]=$!
        _tmps[$i]="$tmp"
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
        TIME_LINES+="$(echo "$output" | grep '\[TIME\]' || true)"$'\n'
        rm -f "$tmp"
    done
fi

# 所要時間（SF_TEST_TIMES=1 のとき。長い順。_weight の目安を、実測で直すための表示）
if [[ "${SF_TEST_TIMES:-}" == "1" && -n "${TIME_LINES//[[:space:]]/}" ]]; then
    echo "" | tee_log
    echo "  所要時間（長い順。並列で動かしているため、単独で動かすより、長めに出る）:" | tee_log
    printf '%s\n' "$TIME_LINES" | grep '\[TIME\]' | sort -k3,3nr | head -25 | tee_log
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
