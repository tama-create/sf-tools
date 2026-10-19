#!/bin/bash
# ==============================================================================
# diag.sh - セットアップの状態の診断（sf-init.sh --status が使う）
# ==============================================================================
# リポジトリのセットアップが、どこまで正しくできているかを、GitHub から読み取って、項目ごとに表示する。
# 何も変更しない（読み取りのみ）。「どこで間違えたか分からない」を、なくすための部品。
#
# 【表示する記号】
#   ✓  できている
#   ✗  不足している（直し方を、すぐ下に表示する。不足の数に数える）
#   ！ 注意（直近のワークフローが失敗している、など。不足には数えない）
#   ？ 確認できなかった（通信エラー・権限不足など。不足には数えない）
#
# 【確認する項目】
#   1. リポジトリ    : GitHub にあるか / branches.txt の各ブランチがあるか / ワークフロー 5 本があるか
#   2. Secrets       : PAT_TOKEN / SLACK_BOT_TOKEN / SF_PRIVATE_KEY / 段階ごとの SF_CONSUMER_KEY_*
#   3. Variables     : SLACK_CHANNEL_ID / 段階ごとの SF_USERNAME_* / SF_INSTANCE_URL_*
#                      （組織の種類の記録 SF_ORG_* は、なくても不足に数えない: 古いバージョンで作ったプロジェクトのため）
#   4. 直近の実行    : wf-metasync / wf-release / wf-validate / wf-propagate の、直近の 1 回の結果（参考）
#   Salesforce 側（外部クライアントアプリ・JWT 接続）は、ログインが必要なため、ここでは確認しない。
#   直近の wf-metasync / wf-release が成功していれば、JWT 接続は、できている。
#
# 【使い方】（呼び出し側が、lib/common.sh を source 済みであること）
#   source lib/diag.sh
#   diag_run "owner/force-xxx" main staging develop   # 段階（ブランチ名）を、並べて渡す
#   # 不足の数は、DIAG_NG に入る（0 なら、不足なし）
# ==============================================================================

DIAG_NG=0   # 不足の数

# 段階（ブランチ名）→ Secrets / Variables の接尾辞
_diag_suffix() {
    case "$1" in
        main)    echo "PROD" ;;
        staging) echo "STG" ;;
        develop) echo "DEV" ;;
        *)       echo "" ;;
    esac
}

# 1 行を表示する。引数: 状態（ok / ng / warn / unknown）ラベル [直し方]
_diag_line() {
    local state="$1" label="$2" hint="${3:-}" sym color
    case "$state" in
        ok)      sym="✓"; color="$CLR_SUCCESS" ;;
        ng)      sym="✗"; color="$CLR_ERR"; DIAG_NG=$((DIAG_NG + 1)) ;;
        warn)    sym="！"; color="$CLR_WARNING" ;;
        *)       sym="？"; color="$CLR_INFO" ;;
    esac
    printf '    %b%s%b %s\n' "$color" "$sym" "$CLR_RESET" "$label" >&2
    if [[ "$state" == "ng" && -n "$hint" ]]; then
        printf '        直し方: %s\n' "$hint" >&2
    fi
}

# 名前の一覧（改行区切り）に、名前があるか。引数: 一覧 名前
_diag_has() { printf '%s\n' "$1" | grep -qx -- "$2"; }  # 条件チェックのため run 不使用

# 名前が、一覧にあれば ✓、なければ ✗（直し方つき）を表示する。引数: 一覧 名前 直し方
_diag_need() {
    if _diag_has "$1" "$2"; then
        _diag_line ok "$2"
    else
        _diag_line ng "$2 がありません" "$3"
    fi
}

# 名前の一覧を、取得する。成功: 標準出力に一覧・戻り値 0 / 失敗（通信エラー・権限不足）: 戻り値 1
#   引数: 種類（secret / variable / branches / workflows）リポジトリ
_diag_names() {
    local kind="$1" repo="$2" out
    case "$kind" in
        secret)    out=$(gh secret list -R "$repo" 2>/dev/null) || return 1 ;;      # VAR=$(cmd) のため run 不使用
        variable)  out=$(gh variable list -R "$repo" 2>/dev/null) || return 1 ;;    # VAR=$(cmd) のため run 不使用
        branches)  out=$(gh api "repos/${repo}/branches" --paginate --jq '.[].name' 2>/dev/null) || return 1 ;;  # VAR=$(cmd) のため run 不使用
        workflows) out=$(gh api "repos/${repo}/contents/.github/workflows" --jq '.[].name' 2>/dev/null) || return 1 ;;  # VAR=$(cmd) のため run 不使用
        *) return 1 ;;
    esac
    # secret / variable の一覧は「名前 TAB ...」の形式。ほかは、1 行 1 名前
    printf '%s\n' "$out" | tr -d '\r' | awk '{print $1}'
}

# ワークフロー 1 つの、直近の実行の結果を、1 行で表示する。引数: リポジトリ ワークフローのファイル名
_diag_last_run() {
    local repo="$1" wf="$2" out status concl at
    if ! out=$(gh run list -R "$repo" --workflow "$wf" --limit 1 \
            --json status,conclusion,createdAt \
            --jq 'if length==0 then "none" else .[0] | "\(.status) \(.conclusion) \(.createdAt)" end' 2>/dev/null); then  # 条件チェック
        _diag_line unknown "${wf}: 直近の実行を、確認できませんでした"
        return 0
    fi
    out="${out%$'\r'}"
    if [[ -z "$out" || "$out" == "none" ]]; then
        _diag_line unknown "${wf}: まだ、実行されていません"
        return 0
    fi
    read -r status concl at <<< "$out"
    at="${at/T/ }"; at="${at:0:16} UTC"
    case "${status}:${concl}" in
        completed:success) _diag_line ok   "${wf}: 直近の実行は、成功です（${at}）" ;;
        completed:*)       _diag_line warn "${wf}: 直近の実行は、成功していません（${concl:-不明}。${at}）。GitHub の Actions で、ログを確認してください" ;;
        *)                 _diag_line unknown "${wf}: 実行中、または、待機中です（${at}）" ;;
    esac
}

# 診断を実行して、結果を表示する。引数: リポジトリ（owner/name）段階（ブランチ名）...
diag_run() {
    local repo="$1"; shift
    local -a tiers=("$@")
    local tier suffix names wf
    DIAG_NG=0

    echo "" >&2
    echo -e "  ${CLR_WARNING}【セットアップの状態】${CLR_RESET}（✓ できている / ✗ 不足 / ！ 注意 / ？ 確認できず）" >&2

    # --- 1. リポジトリ ---
    echo "  リポジトリ" >&2
    if gh repo view "$repo" --json name > /dev/null 2>&1; then  # 条件チェック
        _diag_line ok "GitHub に、リポジトリがあります（${repo}）"
    else
        _diag_line ng "GitHub に、リポジトリが見つかりません（${repo}）" "リポジトリの作成からやり直す: プロジェクトのフォルダで sf-init.sh"
    fi
    if names=$(_diag_names branches "$repo"); then  # 条件チェック
        for tier in "${tiers[@]}"; do
            if _diag_has "$names" "$tier"; then
                _diag_line ok "ブランチ ${tier} があります"
            else
                _diag_line ng "ブランチ ${tier} がありません" "force-* の中で sf-init.sh --add-tier ${tier}"
            fi
        done
    else
        _diag_line unknown "ブランチの一覧を、確認できませんでした"
    fi
    if names=$(_diag_names workflows "$repo"); then  # 条件チェック
        for wf in wf-metasync.yml wf-propagate.yml wf-release.yml wf-sequence.yml wf-validate.yml; do
            if _diag_has "$names" "$wf"; then
                _diag_line ok "ワークフロー ${wf} があります"
            else
                _diag_line ng "ワークフロー ${wf} がありません" "force-* の中で sf-sync-wf.sh"
            fi
        done
    else
        _diag_line unknown "ワークフローの一覧を、確認できませんでした"
    fi

    # --- 2. Secrets ---
    echo "  Secrets（登録した値の名前。値そのものは、読めません）" >&2
    if names=$(_diag_names secret "$repo"); then  # 条件チェック
        _diag_need "$names" PAT_TOKEN "プロジェクトのフォルダで sf-init.sh --only 6"
        _diag_need "$names" SLACK_BOT_TOKEN "プロジェクトのフォルダで sf-init.sh --only 7"
        _diag_need "$names" SF_PRIVATE_KEY "プロジェクトのフォルダで sf-init.sh --only 10"
        for tier in "${tiers[@]}"; do
            suffix=$(_diag_suffix "$tier")
            [[ -n "$suffix" ]] && _diag_need "$names" "SF_CONSUMER_KEY_${suffix}" "force-* の中で sf-init.sh --reconnect ${tier}"
        done
    else
        _diag_line unknown "Secrets の一覧を、確認できませんでした（権限がない、または、通信エラー）"
    fi

    # --- 3. Variables ---
    echo "  Variables" >&2
    if names=$(_diag_names variable "$repo"); then  # 条件チェック
        _diag_need "$names" SLACK_CHANNEL_ID "プロジェクトのフォルダで sf-init.sh --only 7"
        for tier in "${tiers[@]}"; do
            suffix=$(_diag_suffix "$tier")
            [[ -n "$suffix" ]] || continue
            _diag_need "$names" "SF_USERNAME_${suffix}" "force-* の中で sf-init.sh --reconnect ${tier}"
            _diag_need "$names" "SF_INSTANCE_URL_${suffix}" "force-* の中で sf-init.sh --reconnect ${tier}"
            if ! _diag_has "$names" "SF_ORG_ID_${suffix}"; then
                _diag_line warn "SF_ORG_ID_${suffix} がありません（組織の種類が、記録されていません）。force-* の中で sf-init.sh --reconnect ${tier} で、記録できます"
            fi
        done
    else
        _diag_line unknown "Variables の一覧を、確認できませんでした（権限がない、または、通信エラー）"
    fi

    # --- 4. 直近のワークフローの実行（参考。Salesforce 側の接続は、ここで分かる） ---
    echo "  直近のワークフローの実行（成功していれば、Salesforce への JWT 接続も、できています）" >&2
    for wf in wf-metasync.yml wf-release.yml wf-validate.yml wf-propagate.yml; do
        _diag_last_run "$repo" "$wf"
    done

    echo "" >&2
    if [[ "$DIAG_NG" -eq 0 ]]; then
        echo -e "  ${CLR_SUCCESS}✓ セットアップに、不足はありません。${CLR_RESET}" >&2
    else
        echo -e "  ${CLR_ERR}✗ 不足が ${DIAG_NG} 件あります。上の「直し方」を実行してください。${CLR_RESET}" >&2
    fi
}
