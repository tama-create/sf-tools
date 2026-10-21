#!/bin/bash
# ==============================================================================
# ci-notify.sh - e2e（GitHub Actions）が失敗したとき、Slack に通知する
# ==============================================================================
# .github/workflows/e2e.yml の notify ジョブが、これを実行する。通知する内容は、実行の URL・イベント・ブランチ・コミットだけ
# （ログの内容・組織の情報は、含めない）。Slack の Bot Token とチャンネル ID は、e2e が、テスト用リポジトリの通知に使うものと同じ。
# 入力は、JSON を壊さないよう、形式を確認する（不正なら、通知せずに失敗する）。GitHub Actions 上だけで動く。
#
# 【環境変数】（必須）SLACK_BOT_TOKEN SLACK_CHANNEL_ID RUN_URL EVENT REF SHA
# ==============================================================================
set -u

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "ci-notify.sh は、GitHub Actions 上だけで動きます。" >&2
    exit 1
fi

missing=""
for v in SLACK_BOT_TOKEN SLACK_CHANNEL_ID RUN_URL EVENT REF SHA; do
    [[ -n "${!v:-}" ]] || missing="${missing} ${v}"
done
if [[ -n "$missing" ]]; then
    echo "必須の値が空です（値は表示しません）:${missing}" >&2
    exit 1
fi

# JSON に埋め込む値は、安全な文字だけを許す（引用符・改行・バックスラッシュを含む値は、通知しない）
[[ "$SLACK_CHANNEL_ID" =~ ^[A-Z0-9]{8,20}$ ]]                  || { echo "SLACK_CHANNEL_ID の形式が不正です。" >&2; exit 1; }
[[ "$RUN_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/actions/runs/[0-9]+$ ]] || { echo "RUN_URL の形式が不正です。" >&2; exit 1; }
[[ "$EVENT" =~ ^[a-z_]{3,30}$ ]]                               || { echo "EVENT の形式が不正です。" >&2; exit 1; }
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]]                       || { echo "REF の形式が不正です。" >&2; exit 1; }
[[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]]                               || { echo "SHA の形式が不正です。" >&2; exit 1; }

payload=$(printf '{"channel":"%s","text":":x: sf-tools の e2e（GitHub Actions）が失敗しました（%s / %s / %s）\\n%s"}' \
    "$SLACK_CHANNEL_ID" "$EVENT" "$REF" "${SHA:0:7}" "$RUN_URL")  # VAR=$(cmd) のため run 不使用

resp=$(curl -sS -X POST -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-type: application/json; charset=utf-8' \
    --data "$payload" https://slack.com/api/chat.postMessage) || { echo "Slack への接続に失敗しました。" >&2; exit 1; }  # VAR=$(cmd) のため run 不使用（Token をログに出さない）

if [[ "$resp" == *'"ok":true'* ]]; then
    echo "Slack に通知しました。"
else
    # 失敗の理由（error のコード。例: channel_not_found / not_in_channel / invalid_auth）だけを表示する
    err=$(printf '%s' "$resp" | sed -n 's/.*"error":"\([A-Za-z0-9_]*\)".*/\1/p')  # パイプのみのため run 不使用
    echo "Slack への通知に失敗しました（error: ${err:-不明}）。" >&2
    exit 1
fi
