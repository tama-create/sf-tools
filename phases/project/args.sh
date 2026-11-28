#!/bin/bash
# ==============================================================================
# phases/project/args.sh - sf-project.sh の部品: 引数の解析と、保守用のモード（--add-tier・--remove-tier・--verify・--status・--reconnect）への振り分け（3 章）
# ==============================================================================
# bin/sf-project.sh が source する（単独では動かさない）。変数・関数は、sf-project.sh の 1〜2 章と、先に source した部品が用意する。
# 引数（"$@"）は、sf-project.sh のものが、そのまま見える（source に引数を渡さないため。shift も、sf-project.sh の引数に効く）。
# 2026-11-28 に、929 行あった sf-project.sh の 3〜6 章と 8 章を、部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# Phase のスクリプト（phases/init/）とは別のフォルダに置く（phases/init/ の *.sh は、単独で動かす前提のテストがあるため）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-project.sh が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 3. 引数解析
# ------------------------------------------------------------------------------
ONLY_PHASE=""
RESUME_PHASE=1
ADD_TIER_MODE=""
REMOVE_TIER_MODE=""
PURGE_SECRETS_MODE=0
RECONNECT_MODE=""
STATUS_MODE=0
VERIFY_MODE=0
VERIFY_ARGS=()   # --verify のオプション（--plan / --cleanup / --no-metasync / --components / --validate-only / --with-objects）。verify.sh に、そのまま渡す

# --only / --resume の値の検査（Phase 番号 1〜10 の整数だけ）。値なしだと shift 2 が失敗して引数の解析が終わらず（Ctrl+C は無効）、
# 数字以外・範囲外だと存在しない Phase を「成功」として実行してしまうため、解析の時点で拒否する。
_require_phase_number() {
    local opt="$1" val="${2-}"
    [[ "$val" =~ ^([1-9]|10)$ ]] || die "${opt} には、Phase 番号（1〜10 の整数）を指定してください: ${val:-（指定なし）}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help ;;   # 2 つ目以降の --help / -h（第 1 引数のときは、上で処理済み）。ヘルプを表示して終了 0
        --owner)
            [[ -n "${2:-}" ]] || die "--owner には、GitHub のオーナー（組織名またはユーザー名）を指定してください。"
            export SF_INIT_OWNER="$2"
            shift 2
            ;;
        --project)
            [[ -n "${2:-}" ]] || die "--project には、プロジェクト名（force-XXXX の XXXX の部分）を指定してください。"
            export SF_INIT_PROJECT="$2"
            shift 2
            ;;
        --only)
            _require_phase_number "--only" "${2-}"
            ONLY_PHASE="$2"
            shift 2
            ;;
        --resume)
            _require_phase_number "--resume" "${2-}"
            RESUME_PHASE="$2"
            shift 2
            ;;
        --add-tier)
            [[ -n "${2:-}" && "${2}" != -* ]] || die "--add-tier には、追加する段階（staging または develop）を指定してください。"
            ADD_TIER_MODE="$2"
            shift 2
            ;;
        --remove-tier)
            [[ -n "${2:-}" && "${2}" != -* ]] || die "--remove-tier には、外す段階（staging または develop）を指定してください。"
            REMOVE_TIER_MODE="$2"
            shift 2
            ;;
        --purge-secrets)
            PURGE_SECRETS_MODE=1   # --remove-tier と一緒にだけ指定できる（下で、単独の指定を拒否する）
            shift
            ;;
        --reconnect)
            RECONNECT_MODE="$2"   # - で始まる値も受け取る（段階の名前かどうかは、reconnect.sh が確認する）
            [[ -n "$RECONNECT_MODE" ]] || die "--reconnect には、main・staging・develop のいずれかを指定してください。"
            shift 2
            ;;
        --status)
            STATUS_MODE=1
            shift
            ;;
        --verify)
            VERIFY_MODE=1
            shift
            ;;
        --plan|--cleanup|--no-metasync|--components|--validate-only|--with-objects)
            VERIFY_ARGS+=("$1")   # --verify と一緒に指定するもの（下で、--verify なしの指定を拒否する）
            shift
            ;;
        *)
            die "不明なオプションです: $1
使い方:
  ~/sf-tools/bin/sf-project.sh                       # Phase 1〜10 を順次実行（途中で止まった状態があれば、続き / 最初からを選ぶ）
  ~/sf-tools/bin/sf-project.sh --project XXXX         # プロジェクト名（force-XXXX の XXXX）を指定する（--owner でオーナーも指定できる）
  ~/sf-tools/bin/sf-project.sh --resume N             # Phase N から最後まで順次実行（質問なし）
  ~/sf-tools/bin/sf-project.sh --only N               # Phase N のみ実行
  ~/sf-tools/bin/sf-project.sh --add-tier staging     # staging tier を追加
  ~/sf-tools/bin/sf-project.sh --add-tier develop     # develop tier を追加
  ~/sf-tools/bin/sf-project.sh --remove-tier develop  # develop tier を外す（branches.txt の行を消す PR を作る）
  ~/sf-tools/bin/sf-project.sh --remove-tier develop --purge-secrets  # 外したあと（PR のマージ後）に、接続情報を消す
  ~/sf-tools/bin/sf-project.sh --reconnect main       # main の接続先（Salesforce 組織）を付け替える
  ~/sf-tools/bin/sf-project.sh --status               # セットアップの診断と、段階ごとの接続先を一覧にする
  ~/sf-tools/bin/sf-project.sh --verify               # 動作の確認（Hello World を、各段階にリリースして、削除する。--plan / --cleanup / --no-metasync）
  ~/sf-tools/bin/sf-project.sh --verify --components  # パターン別のサンプルを、develop の組織だけに、リリースして、削除する（--validate-only: 検証のみ）
  ~/sf-tools/bin/sf-project.sh --verify --components --with-objects  # オブジェクト系も、リリースして、削除する"
            ;;
    esac
done

# sf が終了コードを正しく返すか確認する（npm 版が前提。NG なら案内を表示して中断する）
# --resume / --only / --add-tier / --verify / --status / --reconnect のときも確認する（--help 以外の、すべての実行で確認する）。
# sf が未インストールのとき・GitHub Actions 上では、check_sf_cli は何もしない
check_sf_cli

# --add-tier と --remove-tier は、逆の操作のため、同時に指定できない（ほかのモードのように、片方を黙って無視しない）
if [[ -n "$ADD_TIER_MODE" && -n "$REMOVE_TIER_MODE" ]]; then
    die "--add-tier と --remove-tier は、同時に指定できません。"
fi
# --purge-secrets は、--remove-tier と一緒にだけ指定できる
if [[ "$PURGE_SECRETS_MODE" -eq 1 && -z "$REMOVE_TIER_MODE" ]]; then
    die "--purge-secrets は、--remove-tier と一緒に指定してください。"
fi

# 保守用のモード: --add-tier → --remove-tier → --verify → --status → --reconnect の順で、最初に該当した 1 つだけを実行して終了する
# --add-tier モードは通常のフェーズループとは別処理（--verify なしの --plan などの拒否より先に判定する）
if [[ -n "$ADD_TIER_MODE" ]]; then
    log "HEADER" "tier 追加モード: ${ADD_TIER_MODE} (${SCRIPT_NAME}.sh)"
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export ADD_TIER="$ADD_TIER_MODE"
    bash "${SCRIPT_DIR}/../phases/init/add_tier.sh" \
        || die "--add-tier ${ADD_TIER_MODE} が失敗しました。"  # 対話があるため run 不使用（run は出力を一時ファイルに書き出す）
    exit $RET_OK
fi

# --remove-tier モード（段階を外す。--purge-secrets のときは、外したあとに接続情報を消す。phases/init/remove_tier.sh）
if [[ -n "$REMOVE_TIER_MODE" ]]; then
    log "HEADER" "tier を外すモード: ${REMOVE_TIER_MODE}$([[ "$PURGE_SECRETS_MODE" -eq 1 ]] && echo "（--purge-secrets）") (${SCRIPT_NAME}.sh)"
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export REMOVE_TIER="$REMOVE_TIER_MODE"
    export REMOVE_TIER_PURGE="$PURGE_SECRETS_MODE"
    bash "${SCRIPT_DIR}/../phases/init/remove_tier.sh" \
        || die "--remove-tier ${REMOVE_TIER_MODE} が失敗しました。"  # 対話があるため run 不使用（run は出力を一時ファイルに書き出す）
    exit $RET_OK
fi

# --plan / --cleanup / --no-metasync / --components / --validate-only / --with-objects は、--verify と一緒にだけ指定できる
if [[ "$VERIFY_MODE" -eq 0 && ${#VERIFY_ARGS[@]} -gt 0 ]]; then
    die "${VERIFY_ARGS[*]} は、--verify と一緒に指定してください。"
fi

# --verify モード（動作の確認。force-* ディレクトリの中で実行する。管理者向けの警告・確認は、verify.sh が行う）
if [[ "$VERIFY_MODE" -eq 1 ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # 検証の失敗（終了コード 1）は、表示のとおり。エラー終了のメッセージは、出さない
    bash "${SCRIPT_DIR}/../phases/init/verify.sh" ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}  # 対話があるため run 不使用（同上）
    exit $?
fi

# --status モード（読み取りのみ。force-* ディレクトリの中で実行する）
if [[ "$STATUS_MODE" -eq 1 ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # 診断で不足があるとき（終了コード 1）は、表示のとおり。エラー終了のメッセージは、出さない
    bash "${SCRIPT_DIR}/../phases/init/status.sh"  # 画面への表示が目的のため run 不使用（run は出力を一時ファイルに書き出す）
    exit $?
fi

# --reconnect モード（1 つの段階の接続先を付け替える。force-* ディレクトリの中で実行する）
if [[ -n "$RECONNECT_MODE" ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export RECONNECT_TIER="$RECONNECT_MODE"
    bash "${SCRIPT_DIR}/../phases/init/reconnect.sh" || die "--reconnect ${RECONNECT_MODE} が失敗しました。"  # 対話があるため run 不使用
    exit $RET_OK
fi

# 実行範囲を決定する
if [[ -n "$ONLY_PHASE" ]]; then
    START_PHASE=$ONLY_PHASE
    END_PHASE=$ONLY_PHASE
else
    START_PHASE=$RESUME_PHASE
    END_PHASE=10
fi
