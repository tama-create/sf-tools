#!/bin/bash
# ==============================================================================
# test_sf-log.sh - sf-log.sh のテスト
# ==============================================================================
# 偽の sf（tests/mock-sf-log.js。小さな偽の組織。2026-11-23 に開発組織で確かめた TraceFlag の動きをまねる）で確かめる。
# 設計: doc/sf-log-design.md 12 章（テスト）
#
# 【テストケース】
#   1. start: DebugLevel を作る・上書きする／TraceFlag を作る・自分のものは延ばす（作り直さない）／.state・.status
#   2. start: ほかの USER_DEBUG は、確認のあと「元の期限と今から 2 分後の早いほう」に縮め、その 1 秒後から作る（延ばさない）／
#      N なら何も変えない／2 つ以上なら止まる／DEVELOPER_LOG には触れない／縮めたあとの作成の失敗は、元に戻さず書く
#   3. start --auto: 答えがない・端末でない → 10（答えを保存しない）／auto on → 0／auto off → 10／組織が違う → 聞き直す／
#      ほかの USER_DEBUG → 触らずに 10／予約名・本番 → 10（手動は中断）
#   4. 引数の誤り（--hours・--level・--max・--since・--owner・不明なオプション・サブコマンド・--auto を pull に）
#   5. pull: 自分のログだけを保存し、要約を作る／取りたいログより新しいログがすべて自分のものなら -n、混ざれば -i／
#      -n の直後にできた他の人のログは保存せず、押し出された自分のログは -i で取る／想定しない名前のファイル → 失敗／
#      一覧の失敗 → 失敗（name だけを記録）／他の人の ID を sf-log.log に残さない／51 本以上（何回かに分ける）／
#      --max・--since・2 回目は新しいものだけ
#   6. stop: 自分の TraceFlag だけを消す・手元のログは残す・ないとき・すでに消えているとき／status・auto on|off
#   7. collect（取得役）: 裏で取る・二重に起動しない・pull は取得役に頼む・TraceFlag を延ばす（残り 60 分未満）／
#      止まる: leave（最後の持ち主）・stop・持ち主が死んだ・上限の時間・印の入れ替わり（組織に何もしない）／
#      leave: ほかの持ち主がいれば止めない／start --auto --owner: 登録・後始末の最中（CLOSING）は待つ・死んだ CLOSING は消す／
#      別の組織の取得役が動いているときの pull は中断
#   8. begin（sf-start の前面）: sf を呼ばない・答えがなければ 10・予約名 10・答えが on → 裏で準備して取得役になる／
#      登録していない印の leave は何もしない／止めたら期限の表示を消す／
#      裏の準備の失敗 → 1 回だけやり直す（成功したら WARNING を消す・失敗が続けば error・持ち主が死んでいればやり直さない）
#   9. 環境の混在（Git Bash と WSL。doc/sf-log-design.md 5.6。SF_LOG_TEST_RUNTIME で環境の代わりをする）:
#      別の環境の取得役が動いている（合図が 30 分以内・読めない・未来）→ begin・start --auto は 10、start・pull・stop・auto は中断、
#      leave・collect は 0（何も書かない・sf を呼ばない）、status は「別の環境で動作中」／合図が古い → 止まったもの（別の環境の PID に
#      何も送らない）／古い形（RUNTIME なし）は 12 時間「環境不明」／不正な名前・unknown は「環境不明」／自分が unknown なら判断しない／
#      名乗り（.claim）: 別の環境の新しい名乗り → 取らない・status は「起動待ち」／古い名乗り → 名乗り直す／同じ環境の名乗りは印を変えない／
#      失敗したら、自分の名乗りだけを、同じ環境のほかの持ち主がいないときに消す／ロック: 別の環境のロックは 10 分で消す・新しければ待つ／
#      取得役: RUNTIME・HEARTBEAT を書き、書き直す・別の環境の印を外す・名乗りの AT を書き直す・後始末で名乗りを消す
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-log.sh ===${CLR_RST}"

SFLOG="$SF_TOOLS_DIR/bin/sf-log.sh"
MOCKJS="$SF_TOOLS_DIR/tests/mock-sf-log.js"
LOCKJS="$SF_TOOLS_DIR/tests/mock-org-lock.js"   # 偽の組織の読み書きのロック（偽の sf と _org_set で取り合わない）
ME="005000000000001AAA"
OTHER="005000000000002AAA"

# 文字どおりに含むか（[ ] などを grep の正規表現として読ませないため）
_has()   { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3" "'$2' が出力に含まれていない"; }
_hasnt() { [[ "$1" == *"$2"* ]] && fail "$3" "'$2' が出力に含まれている" || pass "$3"; }

# テストの環境を作る。結果: TD（force-* のフォルダ）・MB（偽の sf）・FK（偽の組織）
_env() {
    TD=$(setup_force_dir); MB=$(setup_mock_bin); FK=$(mktemp -d "${TMPDIR:-/tmp}/fake-org-XXXX")
    export MOCK_CALL_LOG="$MB/calls.log"; : > "$MOCK_CALL_LOG"
    # sf の更新のロックは、本物のホームのものを見ない（手元で sf-upgrade.sh が動いていても、テストを待たせない）
    export SF_TOOLS_UPGRADE_LOCK="$FK/upgrade.lock"
    # Windows の Node が読めるよう、パスを Windows の形にしてから渡す（cygpath がない OS では、そのまま）
    cat > "$MB/sf" <<EOF
#!/bin/bash
FAKE_ORG=\$(cygpath -m "\$FAKE_ORG" 2>/dev/null || printf '%s' "\$FAKE_ORG")
MOCK_CALL_LOG=\$(cygpath -m "\$MOCK_CALL_LOG" 2>/dev/null || printf '%s' "\$MOCK_CALL_LOG")
export FAKE_ORG MOCK_CALL_LOG
exec node "$MOCKJS" "\$@"
EOF
    chmod +x "$MB/sf"
    printf '{"userId":"%s","orgId":"00D000000000001AAA","orgType":"Developer Edition"}\n' "$ME" > "$FK/org.json"
}
# 後片付け。取得役・持ち主の代わりの sleep が残っていれば止める
_done() {
    local p
    p=$(grep '^PID=' "$TD/logs/apex/.collector" 2>/dev/null | cut -d= -f2)
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
    for p in ${SLEEPERS:-}; do kill "$p" 2>/dev/null; done
    SLEEPERS=""
    teardown "$TD" "$MB" "$FK"
}

# sf-log.sh を実行する（標準入力は、既定で空 = 端末でない）。結果: OUT・RC
_run() {
    OUT=$(cd "$TD" && FAKE_ORG="$FK" PATH="$MB:$PATH" SF_TOOLS_SF_CHECK_STAMP="$FK/stamp" SF_LOG_TEST_FAST=1 bash "$SFLOG" "$@" 2>&1 < /dev/null); RC=$?
}
# 標準入力に文字を渡して実行する。引数: 入力 引数...
_run_in() {
    local in="$1"; shift
    OUT=$(cd "$TD" && printf '%s' "$in" | FAKE_ORG="$FK" PATH="$MB:$PATH" SF_TOOLS_SF_CHECK_STAMP="$FK/stamp" SF_LOG_TEST_FAST=1 bash "$SFLOG" "$@" 2>&1); RC=$?
}
# 偽の組織を JavaScript で読む・書く。引数: 式（o が状態）。書くときは _org_set
_org()     { node -e 'const f=process.argv[1]; const o=JSON.parse(require("fs").readFileSync(f,"utf8")); console.log(eval(process.argv[2]))' "$FK/org.json" "$1"; }
# _org_set は、偽の sf と同じロックを取ってから読み書きする（ロックなしだと、取得役の偽の sf が、足したログを古い状態の書き戻しで消すことがあった。2026-11-24）
_org_set() { node -e 'const fs=require("fs"); const L=require(process.argv[3]); const f=process.argv[1]; L.lock(f); const o=JSON.parse(fs.readFileSync(f,"utf8")); eval(process.argv[2]); L.writeAtomic(f, JSON.stringify(o))' "$FK/org.json" "$1" "$LOCKJS"; }
# 手元の状態のファイルから 1 つ読む。引数: ファイル名（.state など） キー
_kv() { grep "^$2=" "$TD/logs/apex/$1" 2>/dev/null | head -1 | cut -d= -f2-; }
# ログを足す（ms は今からの秒。負なら過去）。引数: ID ユーザー 秒 [本文]
_log() {
    _org_set "o.logs=o.logs||[]; o.logs.push({Id:'$1',LogUserId:'$2',StartTime:new Date(Date.now()+($3)*1000).toISOString().replace(/\.\d{3}Z\$/,'Z'),Operation:'/aura',Status:'成功',LogLength:100,DurationMilliseconds:5})"
}
# 有効な TraceFlag を、偽の組織に直接足す（他の道具・設定画面で作られたもの）。引数: ID 種類 期限（今からの秒）
_tf() {
    _org_set "o.traceFlags=o.traceFlags||[]; o.traceFlags.push({Id:'$1',TracedEntityId:'$ME',LogType:'$2',DebugLevelId:'7dl000000000099AAA',StartDate:Date.now()-60000,ExpirationDate:Date.now()+($3)*1000})"
}

# ------------------------------------------------------------------------------
# 偽の組織の読み書きのロック（tests/mock-org-lock.js）。ロックがあるあいだは書かずに待ち、強制終了で残った古いロックは取り直す
test_mock_org_lock() {
    echo ""; echo -e "${CLR_HEAD}[TEST] テストの道具: 偽の組織の読み書きのロック${CLR_RST}"
    _env
    printf '{}' > "$FK/org.json"
    mkdir "$FK/org.json.lock"
    _org_set "o.x=1" & local bp=$!
    sleep 2
    assert_equals "$(_org 'o.x')" "undefined" "ロックがあるあいだは、書かずに待つ"
    rmdir "$FK/org.json.lock"
    wait "$bp"
    assert_equals "$(_org 'o.x')" "1" "ロックが外れたら、書く"
    assert_file_not_exists "$FK/org.json.lock" "書いたあと、ロックを外す"
    # 強制終了で残ったロック（10 秒より古い）→ 取り直して書く
    mkdir "$FK/org.json.lock"
    node -e 'const fs=require("fs"); const t=(Date.now()-60000)/1000; fs.utimesSync(process.argv[1], t, t)' "$FK/org.json.lock"
    _org_set "o.y=2"
    assert_equals "$(_org 'o.y')" "2" "古いロック → 取り直して書く"
    # 偽の sf も、同じロックを取る（読むだけの呼び出しでも、待つ）
    mkdir "$FK/org.json.lock"
    ( cd "$TD" && FAKE_ORG="$FK" PATH="$MB:$PATH" "$MB/sf" --version >/dev/null 2>&1 ) & bp=$!
    sleep 2
    _alive "$bp" && pass "偽の sf も、ロックがあるあいだは待つ" || fail "偽の sf も、ロックがあるあいだは待つ"
    rmdir "$FK/org.json.lock"
    wait "$bp"
    assert_file_not_exists "$FK/org.json.lock" "偽の sf も、終わったらロックを外す"
    _done
}

# start は、sf の更新（sf-upgrade.sh）が動いているあいだ、sf を呼ばずに待つ（入れ替えの途中に sf を呼ぶと失敗する。2026-11-24）
test_start_waits_for_upgrade() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start: sf の更新が終わるのを待つ${CLR_RST}"
    _env
    local sp t0
    # 3 秒で終わる「sf の更新」の代わり
    sleep 3 & sp=$!; SLEEPERS="$SLEEPERS $sp"
    printf 'PID=%s\n' "$sp" > "$SF_TOOLS_UPGRADE_LOCK"
    t0=$SECONDS
    _run start -o dev -y
    assert_exit_ok "$RC" "更新が終わったら、start が成功する"
    [[ $((SECONDS - t0)) -ge 2 ]] && pass "更新が終わるまで待つ" || fail "更新が終わるまで待つ" "$((SECONDS - t0)) 秒"
    _has "$OUT" "sf の更新（sf-upgrade.sh）が終わるのを待ちます" "待つことを表示する"
    _has "$OUT" "sf の更新が終わりました" "終わったことを表示する"
    # 死んだ PID のロック → 待たない
    printf 'PID=%s\n' "$sp" > "$SF_TOOLS_UPGRADE_LOCK"
    _run start -o dev -y
    assert_exit_ok "$RC" "死んだ PID のロック → そのまま成功する"
    _hasnt "$OUT" "終わるのを待ちます" "死んだ PID のロック → 待たない"
    _done
}

# 待つあいだに持ち主（sf-start）がいなくなったら、準備をやめる（--auto。テスト用の上限は 10 秒）
test_start_upgrade_owner_left() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start --auto: 更新を待つあいだに sf-start が終わったら、準備をやめる${CLR_RST}"
    _env
    local sp op mark
    sleep 30 & sp=$!; SLEEPERS="$SLEEPERS $sp"
    printf 'PID=%s\n' "$sp" > "$SF_TOOLS_UPGRADE_LOCK"
    mkdir -p "$TD/logs/apex"
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    # 持ち主（sf-start の代わり）は、待ち始めたあとの 2 秒で終わる
    sleep 2 & op=$!; SLEEPERS="$SLEEPERS $op"
    mark="${op}:$(date +%s):t$RANDOM"
    printf '%s\n' "$mark" > "$TD/logs/apex/.owners"
    : > "$MOCK_CALL_LOG"
    _run start -o dev --auto --owner "$mark"
    assert_exit_ok "$RC" "持ち主がいない → 0 で終わる"
    _has "$OUT" "準備をやめます" "準備をやめたことを表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf data" "組織に問い合わせない"
    _done
}

# start が「取得中」を書くとき、今日の本数も数え直す（前回の値を残さない。ランチャーは取得中に変わった時点で 1 回だけ描き直す。2026-11-24）
test_start_count_today() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start: 今日の本数（COUNT_TODAY）を数え直して書く${CLR_RST}"
    _env
    local today; today=$(date +%Y%m%d)
    mkdir -p "$TD/logs/apex/$today"
    : > "$TD/logs/apex/$today/100000_07L000000000001AAA_a.log"
    : > "$TD/logs/apex/$today/100001_07L000000000002AAA_b.log"
    printf 'STATE=stopped\nCOUNT_TODAY=0\n' > "$TD/logs/apex/.status"
    _run start -o dev -y
    assert_exit_ok "$RC" "start が成功する"
    assert_equals "$(_kv .status STATE)" "collecting" ".status を collecting にする"
    assert_equals "$(_kv .status COUNT_TODAY)" "2" "前回の 0 を残さず、今日のフォルダの本数を書く"
    _done
}

test_start_basic() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start: DebugLevel と TraceFlag を作る・延ばす${CLR_RST}"
    _env
    _run start -o dev -y
    assert_exit_ok "$RC" "start が成功する"
    assert_equals "$(_org 'o.debugLevels.length')" "1" "DebugLevel を 1 つ作る"
    assert_equals "$(_org 'o.debugLevels[0].DeveloperName+" "+o.debugLevels[0].ApexCode+" "+o.debugLevels[0].Database')" "sf_tools_log_standard FINE INFO" "DebugLevel の名前と値（standard）"
    assert_equals "$(_org 'o.traceFlags.length+" "+o.traceFlags[0].LogType')" "1 USER_DEBUG" "USER_DEBUG の TraceFlag を作る"
    assert_equals "$(_org 'Math.round((o.traceFlags[0].ExpirationDate-o.traceFlags[0].StartDate)/3600000)')" "2" "期限は既定の 2 時間"
    local tf; tf=$(_org 'o.traceFlags[0].Id')
    assert_equals "$(_kv .state TRACE_FLAG_ID)" "$tf" ".state に、作った TraceFlag の ID を書く"
    assert_equals "$(_kv .status STATE)" "collecting" ".status を collecting にする"
    _has "$OUT" "デバッグログを取り始めました" "取り始めたことを表示する"

    _org_set "o.debugLevels[0].ApexCode='NONE'"
    _run start -o dev -y --hours 5 --level detail
    assert_exit_ok "$RC" "2 回目の start（--level detail）が成功する"
    assert_equals "$(_org 'o.debugLevels.length')" "2" "detail は、別の DebugLevel（sf_tools_log_detail）を作る"
    _run start -o dev -y --hours 5
    assert_equals "$(_org 'o.debugLevels.length+" "+o.debugLevels[0].ApexCode')" "2 FINE" "standard の DebugLevel は作り直さず、値を上書きする"
    assert_equals "$(_org 'o.traceFlags.length+" "+o.traceFlags[0].Id')" "1 $tf" "自分の TraceFlag は作り直さず、延ばす（ID が同じ）"
    assert_equals "$(_org 'Math.round((o.traceFlags[0].ExpirationDate-o.traceFlags[0].StartDate)/3600000)')" "5" "--hours 5 で延ばす"
    _done
}

test_start_other_traceflags() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start: ほかの TraceFlag${CLR_RST}"
    _env
    # ほかの USER_DEBUG（期限は 1 時間後）→ N なら何も変えない
    _tf 7tf000000000901AAA USER_DEBUG 3600
    _run_in "yn" start -o dev   # 1 文字目: 送信の注意に Y・2 文字目: 止める確認に N
    assert_exit_fail "$RC" "ほかの USER_DEBUG があり、確認で N → 中断"
    assert_equals "$(_org 'o.traceFlags.length')" "1" "N → TraceFlag を作らない"
    _has "$OUT" "7tf000000000901AAA" "ほかの TraceFlag の ID を表示する"
    # Y → 期限を今から 2 分後に縮め、その 1 秒後から作る
    _run_in "yy" start -o dev   # 送信の注意に Y・止める確認に Y
    assert_exit_ok "$RC" "Y → 成功する"
    assert_equals "$(_org 'const t=o.traceFlags[0]; (t.ExpirationDate-Date.now() <= 125000 && t.ExpirationDate-Date.now() > 60000)')" "true" "ほかの USER_DEBUG の期限を、今から約 2 分後に縮める（消さない）"
    assert_equals "$(_org 'o.traceFlags[1].StartDate - o.traceFlags[0].ExpirationDate')" "1000" "新しい TraceFlag は、縮めた期限の 1 秒後から始める"
    _done

    # 元の期限が 2 分より短い → 延ばさない（更新しない）
    _env
    _tf 7tf000000000902AAA USER_DEBUG 90
    local before; before=$(_org 'o.traceFlags[0].ExpirationDate')
    _run start -o dev -y
    assert_exit_ok "$RC" "元の期限が 2 分以内でも成功する"
    assert_equals "$(_org 'o.traceFlags[0].ExpirationDate')" "$before" "元の期限が 2 分より短ければ、延ばさない（変えない）"
    _done

    # DEVELOPER_LOG（Developer Console）には触れない
    _env
    _tf 7tf000000000903AAA DEVELOPER_LOG 3600
    before=$(_org 'o.traceFlags[0].ExpirationDate')
    _run start -o dev -y
    assert_exit_ok "$RC" "DEVELOPER_LOG があっても、確認なしで作れる"
    assert_equals "$(_org 'o.traceFlags.length+" "+o.traceFlags[0].ExpirationDate')" "2 $before" "DEVELOPER_LOG には触れない"
    _done

    # USER_DEBUG が 2 つ以上 → 止まる
    _env
    _tf 7tf000000000904AAA USER_DEBUG 3600
    _org_set "o.traceFlags.push({Id:'7tf000000000905AAA',TracedEntityId:'$ME',LogType:'USER_DEBUG',DebugLevelId:'x',StartDate:null,ExpirationDate:Date.now()+3600000})"
    _run start -o dev -y
    assert_exit_fail "$RC" "有効な USER_DEBUG が 2 つ → 中断"
    assert_equals "$(_org 'o.traceFlags.length')" "2" "2 つ → 何も作らない"
    _done

    # 縮めたあとに作成が失敗 → 元に戻さず、事実を書く
    _env
    _tf 7tf000000000906AAA USER_DEBUG 3600
    _org_set "o.fail={'create:TraceFlag':'UNKNOWN_EXCEPTION'}"
    _run start -o dev -y
    assert_exit_fail "$RC" "作成の失敗 → 中断"
    _has "$OUT" "縮めた TraceFlag は、元に戻していません: 7tf000000000906AAA" "縮めた ID を書く"
    _has "$OUT" "UNKNOWN_EXCEPTION" "失敗の name を書く"
    assert_equals "$(_kv .state TRACE_FLAG_ID)" "" "失敗 → .state に TraceFlag の ID を書かない"
    _done
}

test_start_auto() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start --auto${CLR_RST}"
    _env
    _run start -o dev --auto --owner "123:456:abc"
    assert_equals "$RC" "10" "答えがなく、端末でない → 10（取らない）"
    assert_file_not_exists "$TD/logs/apex/.consent" "端末でない → 答えを保存しない"
    assert_equals "$(_org 'o.traceFlags.length')" "0" "取らない → TraceFlag を作らない"
    assert_equals "$(_kv .status STATE)" "skipped" ".status を skipped にする"
    _run auto on -o dev
    assert_exit_ok "$RC" "auto on が成功する"
    assert_equals "$(_kv .consent AUTO)" "on" ".consent の AUTO を on にする"
    _run start -o dev --auto
    assert_exit_ok "$RC" "auto on → start --auto が 0"
    assert_equals "$(_org 'o.traceFlags.length')" "1" "auto on → TraceFlag を作る"
    _run auto off -o dev
    _run start -o dev --auto
    assert_equals "$RC" "10" "auto off → 10"
    _has "$OUT" "自動で取らない設定" "auto off の理由を表示する"
    # 同じエイリアスで、答えたときと別の組織 → 取らず、答えを消す（次の sf-start の begin で聞き直す）。start --auto は尋ねない
    _run auto on -o dev
    _org_set "o.orgId='00D000000000009AAA'"
    _run start -o dev --auto
    assert_equals "$RC" "10" "答えた組織 ID と違う → 10（取らない）"
    _has "$OUT" "別の組織に入り直した" "組織 ID が違う理由を表示する"
    assert_equals "$(_kv .consent AUTO)" "" "組織 ID が違う → 答えを消す（次の sf-start で聞き直す）"
    assert_equals "$(_org '(o.traceFlags||[]).length')" "1" "組織 ID が違う → 新しい組織に TraceFlag を作らない（前の 1 つのまま）"
    # 組織 ID がまだ空（begin で答えた直後）→ 取る。今の組織 ID を書く
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    _run start -o dev --auto
    assert_exit_ok "$RC" "答えの組織 ID が空 → 取る"
    assert_equals "$(_kv .consent ORG_ID)" "00D000000000009AAA" "答えの組織 ID が空 → 今の組織 ID を書く"
    _done

    # ほかの USER_DEBUG → 触らずに 10
    _env
    _run auto on -o dev
    _tf 7tf000000000911AAA USER_DEBUG 3600
    local before; before=$(_org 'o.traceFlags[0].ExpirationDate')
    _run start -o dev --auto
    assert_equals "$RC" "10" "--auto: ほかの USER_DEBUG → 10"
    assert_equals "$(_org 'o.traceFlags.length+" "+o.traceFlags[0].ExpirationDate')" "1 $before" "--auto: ほかの TraceFlag に触れない"
    _done

    # 予約名・本番
    _env
    _run start -o develop --auto
    assert_equals "$RC" "10" "--auto: 予約名 → 10"
    _run start -o develop -y
    assert_exit_fail "$RC" "手動: 予約名 → 中断"
    _org_set "o.orgType='Enterprise Edition'"
    _run start -o dev --auto
    assert_equals "$RC" "10" "--auto: 本番 → 10"
    _run pull -o dev
    assert_exit_fail "$RC" "pull: 本番 → 中断"
    assert_equals "$(_org 'o.traceFlags.length')" "0" "予約名・本番 → TraceFlag を作らない"
    _done
}

test_args() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 引数の誤り${CLR_RST}"
    _env
    local a
    for a in "start --hours 0" "start --hours 24" "start --hours x" "start --level max" "pull --max 0" "pull --since -5" \
             "start --auto --owner bad" "pull --auto" "start --nope" "nope" "auto maybe" ""; do
        # shellcheck disable=SC2086  # 引数を分けて渡す
        _run $a -o dev
        assert_exit_fail "$RC" "引数の誤り → 中断: ${a:-（なし）}"
    done
    assert_equals "$(_org '(o.traceFlags||[]).length')" "0" "引数の誤り → 組織に書き込まない"
    _run --help
    _has "$OUT" "【使い方】" "--help で冒頭コメントを表示する"
    _done
}

test_pull() {
    echo ""; echo -e "${CLR_HEAD}[TEST] pull${CLR_RST}"
    _env
    _run start -o dev -y
    # 自分 3 本と、その間に他の人の 1 本 → -i で 1 本ずつ（他の人の本文を取らない）
    _log 07L000000000001AAA "$ME" 1; _log 07L000000000002AAA "$OTHER" 2; _log 07L000000000003AAA "$ME" 3; _log 07L000000000004AAA "$ME" 4
    : > "$MOCK_CALL_LOG"
    _run pull -o dev
    assert_exit_ok "$RC" "pull が成功する"
    _has "$OUT" "3 本" "要約の 1 行目（3 本）を表示する"
    _has "$OUT" "logs/apex/latest.md" "latest.md のパスを表示する"
    assert_file_exists "$TD/logs/apex/latest.md" "latest.md を作る"
    assert_equals "$(ls "$TD"/logs/apex/2*/*.log 2>/dev/null | wc -l | tr -d ' ')" "3" "自分のログ 3 本だけを保存する"
    assert_equals "$(ls "$TD"/logs/apex/2*/ | grep -c 07L000000000002AAA)" "0" "他の人のログは保存しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "apex get log -n" "他の人のログが混ざる → -n を使わない"
    assert_file_contains "$MOCK_CALL_LOG" "apex get log -i 07L000000000001AAA" "他の人のログが混ざる → -i で 1 本ずつ"
    assert_file_not_contains "$TD/sf-tools/logs/sf-log.log" "$OTHER" "sf-log.log に、他の人のユーザー ID を残さない"
    assert_file_not_contains "$TD/sf-tools/logs/sf-log.log" "07L000000000002AAA" "sf-log.log に、他の人のログの ID を残さない"
    assert_dir_not_exists "$TD/logs/apex/.fetch" "一時フォルダを残さない"
    assert_equals "$(wc -l < "$TD/logs/apex/.index" | tr -d ' ')" "3" "目録に 3 本"
    # 2 回目: 新しいもの（自分だけ）→ -n で 1 回
    _log 07L000000000005AAA "$ME" 5; _log 07L000000000006AAA "$ME" 6
    : > "$MOCK_CALL_LOG"
    _run pull -o dev
    assert_exit_ok "$RC" "2 回目の pull が成功する"
    _has "$OUT" "・2 本・" "2 回目は、新しい 2 本だけを要約する"
    assert_equals "$(grep -c "apex get log" "$MOCK_CALL_LOG")" "1" "自分のログだけ → sf apex get log を 1 回で取る"
    assert_file_contains "$MOCK_CALL_LOG" "apex get log -n 2" "自分のログだけ → -n 2"
    # 3 回目: 新しいものなし
    _run pull -o dev
    _has "$OUT" "・0 本・" "新しいログがなければ 0 本"
    # --since: 直近の分をもう一度
    _run pull -o dev --since 60
    _has "$OUT" "・5 本・" "--since 60 は、直近 60 分のログを全部入れる"
    # --max
    _run pull -o dev --since 60 --max 2
    _has "$(cat "$TD/logs/apex/latest.md")" "入れなかった古いログ: 3 本" "--max を超えた分を書く"
    _done
}

test_pull_pushed_out_and_failures() {
    echo ""; echo -e "${CLR_HEAD}[TEST] pull: 押し出し・失敗${CLR_RST}"
    _env
    _run start -o dev -y
    _log 07L000000000011AAA "$ME" 1; _log 07L000000000012AAA "$ME" 2
    # -n の直前に、他の人の新しいログができる（押し出し）
    _org_set "o.injectOnGetLog=[{Id:'07L000000000019AAA',LogUserId:'$OTHER',StartTime:new Date(Date.now()+9000).toISOString().replace(/\.\d{3}Z\$/,'Z'),Operation:'x',Status:'成功',LogLength:1,DurationMilliseconds:1}]"
    : > "$MOCK_CALL_LOG"
    _run pull -o dev
    assert_exit_ok "$RC" "押し出しがあっても成功する"
    assert_file_contains "$MOCK_CALL_LOG" "apex get log -n 2" "まず -n 2 で取る"
    assert_file_contains "$MOCK_CALL_LOG" "apex get log -i 07L000000000011AAA" "押し出された自分のログを -i で取る"
    assert_equals "$(ls "$TD"/logs/apex/2*/*.log 2>/dev/null | wc -l | tr -d ' ')" "2" "自分のログ 2 本を保存する"
    assert_equals "$(ls -R "$TD"/logs/apex | grep -c 07L000000000019AAA)" "0" "押し出しの代わりに入った他の人のログは、保存しない"
    assert_dir_not_exists "$TD/logs/apex/.fetch" "一時フォルダを残さない"
    _done

    # 想定しない名前のファイル → 失敗（しおりを進めない）
    _env
    _run start -o dev -y
    _log 07L000000000021AAA "$ME" 1
    _org_set "o.junkFile='other-user.log'"
    local before; before=$(_kv .state LAST_FETCH)
    _run pull -o dev
    assert_exit_fail "$RC" "想定しない名前のファイル → 失敗"
    assert_equals "$(_kv .state LAST_FETCH)" "$before" "失敗 → しおりを進めない"
    assert_dir_not_exists "$TD/logs/apex/.fetch" "失敗しても、一時フォルダを残さない"
    _done

    # 一覧の失敗 → name だけを記録
    _env
    _run start -o dev -y
    _org_set "o.fail={'query:ApexLog':'INVALID_SESSION_ID'}"
    _run pull -o dev
    assert_exit_fail "$RC" "一覧の失敗 → 失敗"
    assert_file_contains "$TD/sf-tools/logs/sf-log.log" "ApexLog の一覧: 失敗（INVALID_SESSION_ID）" "一覧の失敗は、name だけを記録する"
    _done

    # 51 本以上 → 何回かに分けて全部取る
    _env
    _run start -o dev -y
    _org_set "for(let i=0;i<55;i++){o.logs.push({Id:'07L'+String(100+i).padStart(12,'0')+'AAA',LogUserId:'$ME',StartTime:new Date(Date.now()+1000+i*1000).toISOString().replace(/\.\d{3}Z\$/,'Z'),Operation:'/aura',Status:'成功',LogLength:10,DurationMilliseconds:1})}"
    _run pull -o dev --max 100
    assert_exit_ok "$RC" "55 本 → 成功する"
    assert_equals "$(wc -l < "$TD/logs/apex/.index" | tr -d ' ')" "55" "55 本 → 2 回に分けて、全部保存する"
    _done
}

test_stop_status() {
    echo ""; echo -e "${CLR_HEAD}[TEST] stop・status${CLR_RST}"
    _env
    _tf 7tf000000000921AAA DEVELOPER_LOG 3600
    _run start -o dev -y
    local tf; tf=$(_kv .state TRACE_FLAG_ID)
    _log 07L000000000031AAA "$ME" 1
    _run pull -o dev
    _run status -o dev
    assert_exit_ok "$RC" "status が成功する"
    _has "$OUT" "${tf}  USER_DEBUG  active" "status: 自分の TraceFlag を表示する"
    _has "$OUT" "（sf-log.sh が作ったもの）" "status: sf-log.sh が作ったものに印を付ける"
    _has "$OUT" "7tf000000000921AAA  DEVELOPER_LOG" "status: ほかの TraceFlag も表示する"
    _run stop
    assert_exit_ok "$RC" "stop が成功する"
    assert_equals "$(_org "o.traceFlags.map(t=>t.Id).join(',')")" "7tf000000000921AAA" "stop: 自分の TraceFlag だけを消す"
    assert_equals "$(_kv .state TRACE_FLAG_ID)" "" "stop: .state の ID を消す"
    assert_equals "$(_kv .status STATE)" "stopped" "stop: .status を stopped にする"
    assert_equals "$(ls "$TD"/logs/apex/2*/*.log 2>/dev/null | wc -l | tr -d ' ')" "1" "stop: 手元のログは消さない"
    assert_equals "$(_org 'o.debugLevels.length')" "1" "stop: DebugLevel は消さない"
    assert_file_not_exists "$TD/logs/apex/.owners" "stop: 後始末の印を残さない"
    _run stop
    assert_exit_ok "$RC" "2 回目の stop も成功する"
    _has "$OUT" "TraceFlag はありません" "2 回目: 作った TraceFlag はない"
    # すでに消えている
    _run start -o dev -y
    _org_set "o.traceFlags=o.traceFlags.filter(t=>t.LogType!=='USER_DEBUG')"
    _run stop
    assert_exit_ok "$RC" "すでに消えていても、stop は成功する"
    _has "$OUT" "すでにありません" "すでに消えていることを表示する"
    _done
}

# ------------------------------------------------------------------------------
# collect（取得役）
# ------------------------------------------------------------------------------
# 取得役を裏で起動する（exec で、記録された PID と $! を同じにする）。引数: 追加の環境変数（K=V。任意）
_collect_bg() {
    (cd "$TD" && exec env FAKE_ORG="$FK" PATH="$MB:$PATH" SF_TOOLS_SF_CHECK_STAMP="$FK/stamp" SF_LOG_TEST_FAST=1 SF_LOG_INTERVAL=2 "$@" \
        bash "$SFLOG" collect </dev/null >/dev/null 2>&1) &
    CPID=$!
}
# 条件が成り立つまで待つ。引数: 秒 条件（eval する）
_wait_for() { local i; for ((i = 0; i < $1 * 5; i++)); do eval "$2" && return 0; sleep 0.2; done; return 1; }
# 生きている持ち主の代わり（sleep）の印を作る。結果: MARK
_live_mark() { sleep 600 & SLEEPERS="${SLEEPERS:-} $!"; MARK="$!:$(date +%s):t$RANDOM"; }
_alive() { kill -0 "$1" 2>/dev/null; }
_tf_count() { _org '(o.traceFlags||[]).filter(t=>t.LogType==="USER_DEBUG").length'; }

# ------------------------------------------------------------------------------
# 遅れて現れるログの拾い直し（doc/sf-log-design.md 8.3）。ApexLog は処理が終わってから一覧に現れる（2026-11-24 に実機で確認）
# ------------------------------------------------------------------------------
# 遅れて現れるログを足す（visibleAt まで、一覧・本文に出ない）。引数: ID ユーザー 開始（今からの秒） 現れるまで（今からの秒）
_late_log() {
    _org_set "o.logs=o.logs||[]; o.logs.push({Id:'$1',LogUserId:'$2',StartTime:new Date(Date.now()+($3)*1000).toISOString().replace(/\.\d{3}Z\$/,'Z'),Operation:'/long',Status:'成功',LogLength:100,DurationMilliseconds:9000,visibleAt:Date.now()+($4)*1000})"
}

# 遅れて現れるログを、今すぐ一覧に出す（時間で待たずに、テストが決めた時点で現れるようにする。引数: ID）
#   以前は「N 秒後に現れる」で書いていて、1 回目の pull が負荷で N 秒を超えると、通常の取得で取れてしまい、テストが揺れた（2026-11-24）
_reveal() { _org_set "(o.logs||[]).forEach(l=>{ if (l.Id==='$1') l.visibleAt=Date.now(); })"; }

test_late_recheck() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 拾い直し: 遅れて現れた自分のログを取り、要約に入れる${CLR_RST}"
    _env
    _run start -o dev -y
    # 長い処理 L（開始 +1 秒・1 回目の pull のあとで現れる）と、あとから始まった短い処理 S（開始 +2 秒・すぐ見える）。他の人の遅れたログ O も
    _late_log 07L000000000070AAA "$ME" 1 600
    _late_log 07L000000000072AAA "$OTHER" 1 600
    _log 07L000000000071AAA "$ME" 2
    _run pull -o dev
    assert_exit_ok "$RC" "1 回目の pull が成功する"
    assert_equals "$(wc -l < "$TD/logs/apex/.index" | tr -d ' ')" "1" "1 回目は、見えている短い処理だけを取る"
    _has "$(cat "$TD/logs/apex/latest.md")" "07L000000000071AAA" "1 回目の要約に、短い処理が入る"
    _reveal 07L000000000070AAA; _reveal 07L000000000072AAA
    : > "$MOCK_CALL_LOG"
    _run pull -o dev
    assert_exit_ok "$RC" "2 回目の pull が成功する"
    assert_file_contains "$TD/logs/apex/.index" "07L000000000070AAA" "遅れて現れた長い処理のログを、拾い直して目録に入れる"
    assert_file_contains "$MOCK_CALL_LOG" "LogUserId = '${ME}' AND StartTime >=" "拾い直しの検索は、自分のログだけ（LogUserId で絞る）"
    assert_file_contains "$MOCK_CALL_LOG" "apex get log -i 07L000000000070AAA" "拾い直しは、-i で 1 本ずつ取る"
    _has "$(cat "$TD/logs/apex/latest.md")" "07L000000000070AAA" "開始が前回の要約より前でも、要約に入れる（目録に足された順で選ぶ）"
    _hasnt "$(cat "$TD/logs/apex/latest.md")" "07L000000000071AAA" "前回の要約に入れたログは、もう入れない"
    assert_equals "$(ls "$TD"/logs/apex/2*/ | grep -c 07L000000000072AAA)" "0" "他の人の遅れたログは、取らない"
    assert_file_not_contains "$TD/sf-tools/logs/sf-log.log" "07L000000000072AAA" "sf-log.log に、他の人のログの ID を残さない"
    assert_file_contains "$TD/sf-tools/logs/sf-log.log" "1 本を拾い直しました" "拾い直した本数を sf-log.log に書く"
    assert_equals "$(_kv .state LATE_FROM)" "" "成功したら、LATE_FROM は空"
    _done
}

test_late_recheck_failure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 拾い直し: 失敗したら LATE_FROM を残し、次の回に取り戻す${CLR_RST}"
    _env
    _run start -o dev -y
    # しおりが 30 分より古く、LATE_FROM もない（新しいログもない）→ 拾い直しの検索をしない
    grep -v '^LAST_FETCH=' "$TD/logs/apex/.state" > "$TD/st.t"; printf 'LAST_FETCH=2020-01-01T00:00:00Z\n' >> "$TD/st.t"; mv "$TD/st.t" "$TD/logs/apex/.state"
    _org_set "o.lateQueries=0"
    _run pull -o dev
    assert_exit_ok "$RC" "しおりが古くても、pull は成功する"
    assert_equals "$(_org 'o.lateQueries||0')" "0" "しおりが 30 分より古く、LATE_FROM もない → 拾い直しの検索をしない"
    _late_log 07L000000000080AAA "$ME" 1 600
    _log 07L000000000081AAA "$ME" 2
    _run pull -o dev
    _reveal 07L000000000080AAA
    _org_set "o.failOnce={'query:ApexLogLate':'UNKNOWN_EXCEPTION'}"
    _run pull -o dev
    assert_exit_ok "$RC" "拾い直しが失敗しても、pull は成功する"
    _has "$(cat "$TD/logs/apex/latest.md")" "拾い直しに失敗しました" "失敗を、要約の先頭に書く"
    [[ "$(_kv .state LATE_FROM)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && pass "失敗した回の下限を LATE_FROM に残す" || fail "失敗した回の下限を LATE_FROM に残す" "$(_kv .state LATE_FROM)"
    assert_file_not_contains "$TD/logs/apex/.index" "07L000000000080AAA" "失敗した回は、拾い直せていない"
    _run pull -o dev
    assert_file_contains "$TD/logs/apex/.index" "07L000000000080AAA" "次の回に、拾い直す"
    assert_equals "$(_kv .state LATE_FROM)" "" "拾い直しが成功したら、LATE_FROM を消す"
    _has "$(cat "$TD/logs/apex/latest.md")" "07L000000000080AAA" "拾い直したログを、要約に入れる"
    # LATE_FROM が 24 時間より古い → 消して、知らせる
    grep -v '^LATE_FROM=' "$TD/logs/apex/.state" > "$TD/st.t"; printf 'LATE_FROM=2020-01-01T00:00:00Z\n' >> "$TD/st.t"; mv "$TD/st.t" "$TD/logs/apex/.state"
    _run pull -o dev
    assert_equals "$(_kv .state LATE_FROM)" "" "LATE_FROM が 24 時間より古ければ、消す"
    _has "$(cat "$TD/logs/apex/latest.md")" "24 時間続いた" "LATE_FROM を消したことを、要約の先頭に書く"
    _done
}

test_pull_read_marks() {
    echo ""; echo -e "${CLR_HEAD}[TEST] pull: 要約のしおり（目録の行・古い形からの移し・行のずれ・--since・要約のロック）${CLR_RST}"
    _env
    _run start -o dev -y
    _log 07L000000000091AAA "$ME" 1; _log 07L000000000092AAA "$ME" 2; _log 07L000000000093AAA "$ME" 3
    _run pull -o dev
    assert_equals "$(_kv .state LAST_READ_LINE)" "3" "要約のしおりは、読んだ目録の最後の行の番号"
    assert_equals "$(_kv .state LAST_READ_ID)" "$(sed -n 3p "$TD/logs/apex/.index" | cut -f2)" "LAST_READ_ID は、その行のログの ID"
    # 古い形（LAST_READ・LAST_READ_IDS）からの移し: 2 行目と 3 行目を同じ秒にし、2 行目だけを要約に入れたことにする
    local t1="2026-01-01T00:00:01Z" t2="2026-01-01T00:00:02Z" id2 id3
    id2=$(sed -n 2p "$TD/logs/apex/.index" | cut -f2); id3=$(sed -n 3p "$TD/logs/apex/.index" | cut -f2)
    awk -F'\t' -v OFS='\t' -v a="$t1" -v b="$t2" 'NR == 1 { $3 = a } NR >= 2 { $3 = b } { print }' "$TD/logs/apex/.index" > "$TD/idx.t" && mv "$TD/idx.t" "$TD/logs/apex/.index"
    grep -v '^LAST_READ' "$TD/logs/apex/.state" > "$TD/st.t"; printf 'LAST_READ=%s\nLAST_READ_IDS=%s\n' "$t2" "$id2" >> "$TD/st.t"; mv "$TD/st.t" "$TD/logs/apex/.state"
    _run pull -o dev
    _has "$OUT" "・1 本・" "移し: 同じ秒で、要約に入れていないログ（3 行目）だけを入れる"
    _has "$(cat "$TD/logs/apex/latest.md")" "$id3" "移し: 3 行目のログが要約に入る"
    assert_equals "$(_kv .state LAST_READ_LINE)" "3" "移したあと、新しい形のしおりを書く"
    assert_equals "$(_kv .state LAST_READ)" "" "移したあと、古い形のしおりを消す"
    # 行のずれ（目録を手で直し、先頭に行が入った）→ ID で行を探し直す。
    #   差し込む行は、拾い直しの範囲の外（2020 年・架空の ID）にする（範囲の中の自分のログを目録から消すと、拾い直しが足し直すため）
    { printf '%s\t07L000000000099AAA\t2020-01-01T00:00:00Z\t/old\t成功\t1\t1\n' "logs/apex/20200101/000000_07L000000000099AAA_old.log"; cat "$TD/logs/apex/.index"; } > "$TD/idx.t" && mv "$TD/idx.t" "$TD/logs/apex/.index"
    _run pull -o dev
    _has "$OUT" "探し直しました" "行がずれたら、ID で行を探し直す"
    _has "$OUT" "・0 本・" "探し直した行より後に、新しいログはない"
    assert_equals "$(_kv .state LAST_READ_LINE)" "4" "しおりを、今の目録の行に合わせる"
    # --since は、しおりを使わず、進めない（2026-01-01 の 3 本と、新しい 1 本。2020 年の行は入らない）
    _log 07L000000000094AAA "$ME" 4
    _run pull -o dev --since 600000
    _has "$OUT" "・4 本・" "--since は、しおりを使わず、目録の全行から直近 N 分を選ぶ"
    assert_equals "$(_kv .state LAST_READ_LINE)" "4" "--since は、しおりを進めない"
    # 要約のロックが取れない（ほかの pull が動いている）→ しおりを読まず・進めずに、直近 30 分で要約する
    _live_mark
    mkdir "$TD/logs/apex/.read.lock" && printf '%s\n' "${MARK%%:*}" > "$TD/logs/apex/.read.lock/pid"
    _run pull -o dev
    _has "$OUT" "要約のロックを取れませんでした" "要約のロックが取れなければ、その旨を表示する"
    assert_equals "$(_kv .state LAST_READ_LINE)" "4" "ロックが取れなければ、しおりを進めない"
    rm -rf "$TD/logs/apex/.read.lock"
    _run pull -o dev
    assert_equals "$(_kv .state LAST_READ_LINE)" "5" "ロックが外れたら、しおりを進める"
    assert_dir_not_exists "$TD/logs/apex/.read.lock" "要約のロックを残さない"
    _done
}

test_collect_late() {
    echo ""; echo -e "${CLR_HEAD}[TEST] collect: 取得役も、遅れて現れたログを拾い直す${CLR_RST}"
    _env
    _run auto on -o dev
    _live_mark; local m1="$MARK"
    _run start -o dev --auto --owner "$m1"
    _late_log 07L000000000075AAA "$ME" 1 600
    _log 07L000000000076AAA "$ME" 2
    _collect_bg
    _wait_for 40 'grep -q 07L000000000076AAA "$TD/logs/apex/.index" 2>/dev/null' && pass "取得役が、短い処理のログを取る" || fail "取得役が、短い処理のログを取る"
    _reveal 07L000000000075AAA   # 短い処理を取ったあとで現れる（通常の取得のしおりは、もう先に進んでいる）
    _wait_for 40 'grep -q 07L000000000075AAA "$TD/logs/apex/.index" 2>/dev/null' && pass "取得役が、遅れて現れた長い処理のログを拾い直す" || fail "取得役が、遅れて現れた長い処理のログを拾い直す" "$(cat "$TD/logs/apex/.index" 2>/dev/null)"
    _done
}

test_collect_basic() {
    echo ""; echo -e "${CLR_HEAD}[TEST] collect: 裏で取る・pull は取得役に頼む・leave${CLR_RST}"
    _env
    _run auto on -o dev
    _live_mark; local m1="$MARK"
    _run start -o dev --auto --owner "$m1"
    assert_exit_ok "$RC" "start --auto --owner が成功する"
    assert_file_contains "$TD/logs/apex/.owners" "$m1" "持ち主の一覧に、印を足す"
    _collect_bg
    _wait_for 15 '[[ "$(_kv .collector PID)" == "$CPID" ]]' && pass "取得役が印（.collector）を書く" || fail "取得役が印（.collector）を書く"
    _log 07L000000000041AAA "$ME" 1; _log 07L000000000042AAA "$OTHER" 2; _log 07L000000000043AAA "$ME" 3
    _wait_for 30 '[[ "$(wc -l < "$TD/logs/apex/.index" 2>/dev/null | tr -d " ")" == "2" ]]' \
        && pass "取得役が、自分のログ 2 本を、裏で保存する" || fail "取得役が、自分のログ 2 本を、裏で保存する" "$(cat "$TD/logs/apex/.index" 2>/dev/null)"
    _run collect
    assert_exit_ok "$RC" "2 つ目の collect は、すぐ終わる（成功）"
    assert_equals "$(_kv .collector PID)" "$CPID" "2 つ目の collect は、印を書き換えない"
    # pull は取得役に頼む（直前のログも取ってもらう）
    _log 07L000000000044AAA "$ME" 4
    _run pull -o dev
    assert_exit_ok "$RC" "取得役がいるときの pull が成功する"
    _has "$(cat "$TD/logs/apex/latest.md")" "取得役: 動作中" "要約に、取得役が動作中と書く"
    _has "$(cat "$TD/logs/apex/latest.md")" "07L000000000044AAA" "pull の直前のログも、取得役が取って要約に入る"
    # ほかの持ち主がいれば、leave は何も止めない
    _live_mark; local m2="$MARK"
    _run start -o dev --auto --owner "$m2"
    _run leave --owner "$m2"
    assert_exit_ok "$RC" "leave（ほかの持ち主あり）が成功する"
    _has "$OUT" "止めません" "ほかの持ち主がいる → 止めないと表示する"
    _alive "$CPID" && pass "ほかの持ち主がいる → 取得役は動いたまま" || fail "ほかの持ち主がいる → 取得役は動いたまま"
    assert_equals "$(_tf_count)" "1" "ほかの持ち主がいる → TraceFlag は残る"
    # 最後の持ち主の leave → 止める
    _run leave --owner "$m1"
    assert_exit_ok "$RC" "最後の leave が成功する"
    _wait_for 15 '! _alive "$CPID"' && pass "最後の leave → 取得役が止まる" || fail "最後の leave → 取得役が止まる"
    assert_equals "$(_tf_count)" "0" "最後の leave → TraceFlag を消す"
    assert_file_not_exists "$TD/logs/apex/.owners" "最後の leave → 持ち主の一覧（と CLOSING）を消す"
    assert_equals "$(_kv .status STATE)" "stopped" "最後の leave → .status を stopped にする"
    _done
}

test_collect_stops() {
    echo ""; echo -e "${CLR_HEAD}[TEST] collect: 止まり方${CLR_RST}"
    # 持ち主が死んだ → 自分で後始末をして止まる
    _env
    _run auto on -o dev
    local dead; bash -c 'exit 0' & dead=$!; wait "$dead"
    _run start -o dev --auto --owner "${dead}:1:dead"
    _collect_bg
    _wait_for 20 '! _alive "$CPID"' && pass "持ち主が死んだ → 取得役が止まる" || fail "持ち主が死んだ → 取得役が止まる"
    assert_equals "$(_tf_count)" "0" "持ち主が死んだ → 取得役が TraceFlag を消す"
    _has "$(_kv .status REASON)" "持ち主" ".status に、止まった理由を書く"
    _done

    # stop → 取得役を止めて、TraceFlag を消す
    _env
    _run auto on -o dev; _live_mark
    _run start -o dev --auto --owner "$MARK"
    _collect_bg
    _wait_for 15 '[[ "$(_kv .collector PID)" == "$CPID" ]]'
    _run stop
    assert_exit_ok "$RC" "取得役がいるときの stop が成功する"
    _wait_for 15 '! _alive "$CPID"' && pass "stop → 取得役が止まる" || fail "stop → 取得役が止まる"
    assert_equals "$(_tf_count)" "0" "stop → TraceFlag を消す"
    _done

    # 上限の時間（12 時間の代わりに 2 秒）
    _env
    _run auto on -o dev; _live_mark
    _run start -o dev --auto --owner "$MARK"
    _collect_bg SF_LOG_MAX_SECONDS=2
    _wait_for 20 '! _alive "$CPID"' && pass "上限の時間 → 取得役が止まる" || fail "上限の時間 → 取得役が止まる"
    assert_equals "$(_tf_count)" "0" "上限の時間 → TraceFlag を消す"
    _has "$(_kv .status REASON)" "12 時間" ".status に、12 時間で止まったと書く"
    _done

    # 印が入れ替わった → 組織に何もせずに止まる
    _env
    _run auto on -o dev; _live_mark
    _run start -o dev --auto --owner "$MARK"
    _collect_bg
    _wait_for 15 '[[ "$(_kv .collector PID)" == "$CPID" ]]'
    printf 'PID=1\nSTARTED=1\nORG=dev\n' > "$TD/logs/apex/.collector"
    _wait_for 15 '! _alive "$CPID"' && pass "印が入れ替わった → 取得役が止まる" || fail "印が入れ替わった → 取得役が止まる"
    assert_equals "$(_tf_count)" "1" "印が入れ替わった → TraceFlag には触れない"
    rm -f "$TD/logs/apex/.collector"
    _done
}

test_collect_extend() {
    echo ""; echo -e "${CLR_HEAD}[TEST] collect: TraceFlag を延ばす${CLR_RST}"
    _env
    _run auto on -o dev; _live_mark
    _run start -o dev --auto --owner "$MARK"
    # 残り 10 分にする（偽の組織と .status の両方）
    _org_set "const t=o.traceFlags.find(x=>x.LogType==='USER_DEBUG'); t.ExpirationDate=Date.now()+600000"
    local exp10; exp10=$(_org "new Date(o.traceFlags.find(x=>x.LogType==='USER_DEBUG').ExpirationDate).toISOString().replace(/\\.\\d{3}Z\$/,'Z')")
    sed -i.bak "s/^EXPIRES=.*/EXPIRES=${exp10}/" "$TD/logs/apex/.status" && rm -f "$TD/logs/apex/.status.bak"
    _collect_bg
    _wait_for 30 '[[ "$(_org "(o.traceFlags.find(x=>x.LogType===\"USER_DEBUG\").ExpirationDate - Date.now()) > 6000000")" == "true" ]]' \
        && pass "残り 60 分未満 → 今から約 2 時間に延ばす" || fail "残り 60 分未満 → 今から約 2 時間に延ばす"
    _wait_for 10 '[[ "$(_kv .status EXPIRES)" != "$exp10" ]]' && pass "延ばした期限を .status に書く" || fail "延ばした期限を .status に書く"
    _done
}

test_register_owner() {
    echo ""; echo -e "${CLR_HEAD}[TEST] start --auto --owner: 後始末の最中${CLR_RST}"
    _env
    _run auto on -o dev
    _live_mark; local closer="$MARK"
    printf 'CLOSING=%s\n' "$closer" > "$TD/logs/apex/.owners"
    _live_mark
    _run start -o dev --auto --owner "$MARK"
    assert_equals "$RC" "10" "後始末の最中（生きている CLOSING）→ 待っても終わらなければ 10"
    assert_equals "$(_tf_count)" "0" "後始末の最中 → TraceFlag を作らない"
    # 死んだ CLOSING → 消して進む
    local dead; bash -c 'exit 0' & dead=$!; wait "$dead"
    printf 'CLOSING=%s:1:old\n' "$dead" > "$TD/logs/apex/.owners"
    _run start -o dev --auto --owner "$MARK"
    assert_exit_ok "$RC" "死んだ CLOSING → 消して登録し、取り始める"
    assert_file_not_contains "$TD/logs/apex/.owners" "CLOSING=" "死んだ CLOSING を消す"
    assert_file_contains "$TD/logs/apex/.owners" "$MARK" "自分の印を足す"
    # 同じ印は 2 回足さない（入れ子の sf-start）
    _run start -o dev --auto --owner "$MARK"
    assert_equals "$(grep -c -- "$MARK" "$TD/logs/apex/.owners")" "1" "同じ印は 2 回足さない"
    # 別の組織の取得役が動いているときの pull は中断
    _live_mark
    printf 'PID=%s\nSTARTED=1\nORG=other-org\n' "${MARK%%:*}" > "$TD/logs/apex/.collector"
    _run pull -o dev
    assert_exit_fail "$RC" "別の組織の取得役が動いている → pull は中断"
    _has "$OUT" "別の組織（other-org）" "どの組織の取得役かを表示する"
    rm -f "$TD/logs/apex/.collector"
    _done
}

test_begin() {
    echo ""; echo -e "${CLR_HEAD}[TEST] begin（sf-start の前面。sf を呼ばない）${CLR_RST}"
    _env
    _live_mark
    : > "$MOCK_CALL_LOG"
    _run begin -o dev --owner "$MARK"
    assert_equals "$RC" "10" "答えがなく、端末でない → 10"
    assert_file_not_exists "$TD/logs/apex/.consent" "端末でない → 答えを保存しない"
    assert_file_not_contains "$TD/logs/apex/.owners" "$MARK" "取らない → 持ち主として登録しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf data" "begin は、組織に問い合わせない（sf を呼ばない）"
    _run begin -o develop --owner "$MARK"
    assert_equals "$RC" "10" "予約名 → 10"
    _run begin -o dev
    assert_exit_fail "$RC" "--owner なし → 中断"
    _run begin --owner "$MARK"
    assert_exit_fail "$RC" "-o なし → 中断"
    # 答えが on → すぐ 0 で終わり、裏で準備してから取得役になる
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    _run begin -o dev --owner "$MARK"
    assert_exit_ok "$RC" "答えが on → 0（裏で準備を始めた）"
    _has "$OUT" "裏で始めました" "裏で始めたことを表示する"
    assert_file_contains "$TD/logs/apex/.owners" "$MARK" "持ち主として登録する"
    _wait_for 40 'p=$(_kv .collector PID); [[ -n "$p" ]] && _alive "$p" && [[ "$(_kv .status STATE)" == "collecting" ]]' \
        && pass "裏で TraceFlag を準備し、そのまま取得役になる" || fail "裏で TraceFlag を準備し、そのまま取得役になる" "$(cat "$TD/logs/apex/.status" 2>/dev/null)"
    assert_equals "$(_tf_count)" "1" "裏で TraceFlag を作る"
    [[ "$(_kv .status EXPIRES_AT)" =~ ^[0-9]{2}:[0-9]{2}$ ]] && pass ".status に、期限の表示用の時刻（HH:MM）を書く" || fail ".status に、期限の表示用の時刻（HH:MM）を書く" "$(_kv .status EXPIRES_AT)"
    assert_equals "$(_kv .consent ORG_ID)" "00D000000000001AAA" "裏の start --auto が、答えに組織 ID を書く"
    # 登録していない印の leave → 何もしない
    _run leave --owner "1:1:notmine"
    _has "$OUT" "この印はありません" "登録していない印の leave → 何もしない"
    assert_equals "$(_tf_count)" "1" "登録していない印の leave → TraceFlag は残る"
    _run leave --owner "$MARK"
    p=$(_kv .collector PID)
    _wait_for 20 '[[ "$(_tf_count)" == "0" ]]' && pass "leave → 止めて、TraceFlag を消す" || fail "leave → 止めて、TraceFlag を消す"
    _wait_for 10 '[[ "$(_kv .status STATE)" == "stopped" ]]'
    assert_equals "$(_kv .status EXPIRES_AT)" "" "止めた → 期限の表示（EXPIRES_AT）を消す"
    _done
}

# begin の裏の準備の失敗（sf の一時的な失敗）→ 1 回だけやり直す（2026-11-23 に実機で、sf の読み込みエラーで 1 回失敗した）
test_begin_retry() {
    echo ""; echo -e "${CLR_HEAD}[TEST] begin: 裏の準備の失敗を 1 回だけやり直す${CLR_RST}"
    _env
    _live_mark
    mkdir -p "$TD/logs/apex"   # まだ sf-log.sh を動かしていないため、作業フォルダがない
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    _org_set "o.failOnce={'query:DebugLevel':'ModuleLoadError'}"
    _run begin -o dev --owner "$MARK"
    assert_exit_ok "$RC" "begin は 0（裏で準備を始めた）"
    _wait_for 40 'p=$(_kv .collector PID); [[ -n "$p" ]] && _alive "$p" && [[ "$(_kv .status STATE)" == "collecting" ]]' \
        && pass "1 回目の失敗 → やり直して、取得役になる" || fail "1 回目の失敗 → やり直して、取得役になる" "$(cat "$TD/logs/apex/.status" 2>/dev/null)"
    assert_file_contains "$TD/sf-tools/logs/sf-log.log" "もう一度やります" "やり直すことを、ログに書く"
    assert_equals "$(grep -c "FROM DebugLevel" "$MOCK_CALL_LOG")" "2" "DebugLevel の検索は 2 回（失敗 1 回・やり直し 1 回）"
    assert_equals "$(_kv .status WARNING)" "" "やり直して成功 → 「やり直しています」を消す"
    assert_equals "$(_tf_count)" "1" "TraceFlag は 1 つ"
    _run leave --owner "$MARK"
    _wait_for 20 '[[ "$(_tf_count)" == "0" ]]' >/dev/null
    _done

    # 失敗が続く → やり直しは 1 回だけ。.status は error
    _env
    _live_mark
    mkdir -p "$TD/logs/apex"   # まだ sf-log.sh を動かしていないため、作業フォルダがない
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    _org_set "o.fail={'query:DebugLevel':'ModuleLoadError'}"
    _run begin -o dev --owner "$MARK"
    _wait_for 40 '[[ "$(_kv .status STATE)" == "error" ]]' \
        && pass "失敗が続く → .status を error にする" || fail "失敗が続く → .status を error にする" "$(cat "$TD/logs/apex/.status" 2>/dev/null)"
    assert_equals "$(grep -c "FROM DebugLevel" "$MOCK_CALL_LOG")" "2" "失敗が続く → やり直しは 1 回だけ（DebugLevel の検索は 2 回）"
    assert_equals "$(_tf_count)" "0" "失敗が続く → TraceFlag を作らない"
    _done

    # 持ち主が死んでいる → やり直さない
    _env
    mkdir -p "$TD/logs/apex"   # まだ sf-log.sh を動かしていないため、作業フォルダがない
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    _org_set "o.fail={'query:DebugLevel':'ModuleLoadError'}"
    _run start -o dev --auto --collect --retry 1 --owner "999999:1:dead"
    assert_exit_fail "$RC" "持ち主が死んでいる → やり直さずに失敗"
    assert_equals "$(grep -c "FROM DebugLevel" "$MOCK_CALL_LOG")" "1" "持ち主が死んでいる → DebugLevel の検索は 1 回"
    # 引数の検査
    _run start -o dev --auto --retry 1
    assert_exit_fail "$RC" "--retry は --collect なしでは使えない"
    _run start -o dev --auto --collect --retry 9 --owner "$MARK"
    assert_exit_fail "$RC" "--retry 9 → 中断（0〜3）"
    _done
}

# ------------------------------------------------------------------------------
# 環境の混在（Git Bash と WSL。doc/sf-log-design.md 5.6）。SF_LOG_TEST_RUNTIME で、自分の環境の名前を決める
# ------------------------------------------------------------------------------
# 死んだ PID を作る。結果: DEAD
_dead_pid() { bash -c 'exit 0' & DEAD=$!; wait "$DEAD"; }
# 生きている持ち主の代わりの印（環境の名前つき）。引数: 環境の名前。結果: MARK
_rt_mark() { sleep 600 & SLEEPERS="${SLEEPERS:-} $!"; MARK="$!:$(date +%s):$1$RANDOM"; }
# 別の環境の取得役の記録を書く。引数: PID 環境 合図（エポック秒または文字） [起動の時刻]
_foreign_collector() {
    mkdir -p "$TD/logs/apex"
    printf 'PID=%s\nSTARTED=%s\nORG=dev\nRUNTIME=%s\nHEARTBEAT=%s\n' "$1" "${4:-$(date +%s)}" "$2" "$3" > "$TD/logs/apex/.collector"
}

test_runtime_other_active() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の混在: 別の環境が扱っているときは、status 以外は何もしない${CLR_RST}"
    _env
    export SF_LOG_TEST_RUNTIME=gitbash
    local now c; now=$(date +%s)
    _dead_pid
    mkdir -p "$TD/logs/apex"
    printf 'AUTO=on\nORG=dev\nORG_ID=\nVERSION=1\n' > "$TD/logs/apex/.consent"
    printf 'STATE=collecting\nORG=dev\n' > "$TD/logs/apex/.status"
    cp "$TD/logs/apex/.status" "$TD/status.before"
    _foreign_collector "$DEAD" wsl "$now"
    : > "$MOCK_CALL_LOG"
    _rt_mark gitbash
    _run begin -o dev --owner "$MARK"
    assert_equals "$RC" "10" "begin → 10"
    _has "$OUT" "別の環境（wsl）で、デバッグログを取っています。この環境では取りません" "begin → 別の環境で取っていると表示する"
    assert_file_not_exists "$TD/logs/apex/.owners" "begin → 持ち主として登録しない"
    assert_file_not_exists "$TD/logs/apex/.claim" "begin → 名乗らない"
    _run start -o dev --auto --owner "$MARK"
    assert_equals "$RC" "10" "start --auto → 10"
    for c in "pull -o dev" "stop" "start -o dev -y" "auto on -o dev"; do
        # shellcheck disable=SC2086  # サブコマンドと引数に分けるため
        _run $c
        assert_exit_fail "$RC" "${c} → 中断"
        _has "$OUT" "別の環境（wsl）で、デバッグログを取っています" "${c} → 事実を表示する"
    done
    _run leave --owner "$MARK"
    assert_exit_ok "$RC" "leave → 0（何もしない）"
    _run collect
    assert_exit_ok "$RC" "collect → 0（2 つ目の取得役を立てない）"
    assert_equals "$(_kv .collector PID)" "$DEAD" "collect → 別の環境の印を書き換えない"
    assert_equals "$(cat "$TD/logs/apex/.status")" "$(cat "$TD/status.before")" ".status を書き換えない"
    [[ ! -s "$MOCK_CALL_LOG" ]] && pass "sf を呼ばない（組織に触れない）" || fail "sf を呼ばない（組織に触れない）" "$(cat "$MOCK_CALL_LOG")"
    _run status -o dev
    assert_exit_ok "$RC" "status は答える"
    _has "$OUT" "取得役: 別の環境（wsl）で動作中（最後の合図は" "status → 別の環境で動作中と表示する"
    # 合図が読めない・未来の時刻 → 扱っているとみなす（分からないものは、扱っているかもしれない側に倒す）
    _foreign_collector "$DEAD" wsl "abc"
    _run pull -o dev
    assert_exit_fail "$RC" "合図が読めない → 扱っているとみなす（pull は中断）"
    _foreign_collector "$DEAD" wsl "$((now + 5000))"
    _run pull -o dev
    assert_exit_fail "$RC" "合図が未来の時刻 → 扱っているとみなす（pull は中断）"
    # 環境の名前が不正・unknown → 環境不明（unknown 同士でも同じとみなさない）
    _foreign_collector "$DEAD" bogus "$now"
    _run pull -o dev
    _has "$OUT" "別の環境（不明）で" "環境の名前が不正 → 環境不明として扱う"
    _foreign_collector "$DEAD" unknown "$now"
    _run pull -o dev
    assert_exit_fail "$RC" "記録の環境が unknown → 環境不明として扱う（pull は中断）"
    # 自分の環境が unknown → 判断しない（これまでの動き）
    export SF_LOG_TEST_RUNTIME=unknown
    _foreign_collector "$DEAD" wsl "$now"
    _run pull -o dev
    assert_exit_ok "$RC" "自分の環境が unknown → 判断しない（pull は自分で取る）"
    unset SF_LOG_TEST_RUNTIME
    _done
}

test_runtime_stale_and_legacy() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の混在: 古い合図・古い形の記録${CLR_RST}"
    _env
    export SF_LOG_TEST_RUNTIME=gitbash
    local now lp; now=$(date +%s)
    # 合図が 30 分より古い別の環境の記録 → 止まったものとみなす。記録の PID が、たまたま自分の環境で生きていても、何も送らない
    sleep 600 & lp=$!; SLEEPERS="${SLEEPERS:-} $lp"
    _foreign_collector "$lp" wsl "$((now - 2000))"
    _log 07L000000000061AAA "$ME" -5
    _run pull -o dev
    assert_exit_ok "$RC" "合図が 30 分より古い → 止まったものとみなし、pull が自分で取る"
    _has "$(cat "$TD/logs/apex/latest.md")" "取得役: 動いていません" "別の環境の古い記録の PID に、取得を頼まない"
    _run status -o dev
    _has "$OUT" "取得役: 動いていません" "status → 動いていない"
    _run stop
    assert_exit_ok "$RC" "stop が成功する"
    _alive "$lp" && pass "別の環境の記録の PID には、止める合図（TERM）を送らない" || fail "別の環境の記録の PID には、止める合図（TERM）を送らない"
    assert_file_not_exists "$TD/logs/apex/.collector" "stop → 古い記録を消す"
    # 古い形（RUNTIME なし）・起動から 12 時間以内 → kill -0 によらず「環境不明」
    _dead_pid
    printf 'PID=%s\nSTARTED=%s\nORG=dev\n' "$DEAD" "$now" > "$TD/logs/apex/.collector"
    _run pull -o dev
    assert_exit_fail "$RC" "古い形の記録（12 時間以内）→ pull は中断"
    _has "$OUT" "別の環境（不明（古い形の記録））で" "古い形の記録 → 環境不明と表示する"
    _run status -o dev
    _has "$OUT" "取得役: 状態不明（環境の記録のない、古い形" "status → 古い形の記録は「状態不明」"
    # 古い形・12 時間より古い → 止まったもの
    printf 'PID=%s\nSTARTED=%s\nORG=dev\n' "$DEAD" "$((now - 50000))" > "$TD/logs/apex/.collector"
    _run pull -o dev
    assert_exit_ok "$RC" "古い形の記録（12 時間より古い）→ 止まったものとみなす"
    # 形の正しくない記録 → status は「状態不明」
    printf 'PID=x\n' > "$TD/logs/apex/.collector"
    _run status -o dev
    _has "$OUT" "取得役: 状態不明（" "status → 形の正しくない記録は「状態不明」"
    rm -f "$TD/logs/apex/.collector"
    # .status が別の組織の記録 → 状態不明
    printf 'STATE=collecting\nORG=other-org\n' > "$TD/logs/apex/.status"
    _run status -o dev
    _has "$OUT" "表示の状態: 状態不明（別の組織（other-org）の記録です" "status → 別の組織の .status は「状態不明」"
    unset SF_LOG_TEST_RUNTIME
    _done
}

test_runtime_claim() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の混在: 扱う環境の名乗り（.claim）${CLR_RST}"
    _env
    export SF_LOG_TEST_RUNTIME=gitbash
    local now m1 m2; now=$(date +%s)
    _run auto on -o dev
    # 別の環境の新しい名乗り → 取り始めない・登録しない
    printf 'RUNTIME=wsl\nOWNER=1:1:wsl1\nAT=%s\n' "$now" > "$TD/logs/apex/.claim"
    _rt_mark gitbash; m1="$MARK"
    _run start -o dev --auto --owner "$m1"
    assert_equals "$RC" "10" "別の環境の新しい名乗り → 10"
    assert_equals "$(_tf_count)" "0" "別の環境の新しい名乗り → TraceFlag を作らない"
    assert_file_not_contains "$TD/logs/apex/.owners" "$m1" "別の環境の新しい名乗り → 持ち主として登録しない"
    _run status -o dev
    _has "$OUT" "取得役: 取得役の起動待ち（環境 wsl・名乗りは" "status → 名乗りだけなら「起動待ち」"
    # 名乗りの環境が unknown → 環境不明（同じとみなさない）
    printf 'RUNTIME=unknown\nOWNER=1:1:unknown1\nAT=%s\n' "$now" > "$TD/logs/apex/.claim"
    _run pull -o dev
    _has "$OUT" "別の環境（不明）で" "名乗りの環境が unknown → 環境不明として扱う"
    # 30 分より古い名乗り → 自分の環境で名乗り直して、取り始める
    printf 'RUNTIME=wsl\nOWNER=1:1:wsl1\nAT=%s\n' "$((now - 2000))" > "$TD/logs/apex/.claim"
    _run start -o dev --auto --owner "$m1"
    assert_exit_ok "$RC" "古い名乗り → 取り始める"
    assert_equals "$(_kv .claim RUNTIME)" "gitbash" "古い名乗り → 自分の環境で名乗り直す"
    assert_equals "$(_kv .claim OWNER)" "$m1" "名乗りに、自分の印を書く"
    # 同じ環境の名乗り（印の持ち主が生きている）→ 印は変えず、時刻だけ今にする
    printf 'RUNTIME=gitbash\nOWNER=%s\nAT=%s\n' "$m1" "$((now - 100))" > "$TD/logs/apex/.claim"
    _rt_mark gitbash; m2="$MARK"
    _run start -o dev --auto --owner "$m2"
    assert_exit_ok "$RC" "同じ環境の名乗り → 取り始める"
    assert_equals "$(_kv .claim OWNER)" "$m1" "同じ環境の名乗り → 印を書き換えない"
    [[ "$(_kv .claim AT)" -ge "$now" ]] && pass "同じ環境の名乗り → 時刻を今にする" || fail "同じ環境の名乗り → 時刻を今にする" "$(_kv .claim AT)"
    _run stop
    assert_exit_ok "$RC" "stop が成功する"
    assert_file_not_exists "$TD/logs/apex/.claim" "stop → 名乗りを消す"
    # 取り始めに失敗（取らない設定）→ 自分の名乗りを消す
    _run auto off -o dev
    printf 'RUNTIME=gitbash\nOWNER=%s\nAT=%s\n' "$m1" "$now" > "$TD/logs/apex/.claim"
    printf '%s\n' "$m1" > "$TD/logs/apex/.owners"
    _run start -o dev --auto --owner "$m1"
    assert_equals "$RC" "10" "取らない設定 → 10"
    assert_file_not_exists "$TD/logs/apex/.claim" "取り始めに失敗 → 自分の名乗りを消す"
    # 同じ環境のほかの生きている持ち主がいれば、消さない
    printf 'RUNTIME=gitbash\nOWNER=%s\nAT=%s\n' "$m1" "$now" > "$TD/logs/apex/.claim"
    printf '%s\n%s\n' "$m1" "$m2" > "$TD/logs/apex/.owners"
    _run start -o dev --auto --owner "$m1"
    assert_file_exists "$TD/logs/apex/.claim" "同じ環境のほかの持ち主がいる → 名乗りを消さない"
    # 自分の印でない名乗りは、消さない
    printf 'RUNTIME=gitbash\nOWNER=%s\nAT=%s\n' "$m2" "$now" > "$TD/logs/apex/.claim"
    printf '%s\n' "$m1" > "$TD/logs/apex/.owners"
    _run start -o dev --auto --owner "$m1"
    assert_equals "$(_kv .claim OWNER)" "$m2" "自分の印でない名乗り → 消さない"
    unset SF_LOG_TEST_RUNTIME
    _done
}

test_runtime_locks() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の混在: ロックの古さ（pid ファイルの環境と時刻）${CLR_RST}"
    _env
    export SF_LOG_TEST_RUNTIME=gitbash
    local now; now=$(date +%s)
    mkdir -p "$TD/logs/apex/.lock"
    # 別の環境のロック・10 分より古い → 残ったロックとして消す
    printf '1 wsl %s\n' "$((now - 700))" > "$TD/logs/apex/.lock/pid"
    _run auto on -o dev
    assert_exit_ok "$RC" "別の環境の古いロック（10 分より前）→ 消して進む"
    # 同じ環境・死んだ PID → これまでどおり消す
    _dead_pid
    mkdir -p "$TD/logs/apex/.lock"; printf '%s gitbash %s\n' "$DEAD" "$now" > "$TD/logs/apex/.lock/pid"
    _run auto on -o dev
    assert_exit_ok "$RC" "同じ環境の死んだ PID のロック → 消して進む"
    # 別の環境のロック・新しい → 奪わずに待ち、上限で中断する（PID が自分の環境で死んでいても）
    mkdir -p "$TD/logs/apex/.lock"; printf '%s wsl %s\n' "$DEAD" "$now" > "$TD/logs/apex/.lock/pid"
    _run auto on -o dev
    assert_exit_fail "$RC" "別の環境の新しいロック → 奪わずに待ち、取れなければ中断する"
    assert_file_exists "$TD/logs/apex/.lock/pid" "別の環境の新しいロック → 消さない"
    rm -rf "$TD/logs/apex/.lock"
    unset SF_LOG_TEST_RUNTIME
    _done
}

test_runtime_collector() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の混在: 取得役の合図・名乗り・別の環境の印${CLR_RST}"
    _env
    export SF_LOG_TEST_RUNTIME=gitbash
    local m1 mw hb1
    _run auto on -o dev
    _rt_mark gitbash; m1="$MARK"
    _run start -o dev --auto --owner "$m1"
    assert_exit_ok "$RC" "start --auto --owner が成功する"
    _rt_mark wsl; mw="$MARK"
    printf '%s\n' "$mw" >> "$TD/logs/apex/.owners"   # 前に別の環境で使ったときの残り（PID は、たまたま生きている）
    _collect_bg
    _wait_for 15 '[[ "$(_kv .collector PID)" == "$CPID" ]]' && pass "取得役が印を書く" || fail "取得役が印を書く"
    assert_equals "$(_kv .collector RUNTIME)" "gitbash" "取得役の印に、環境の名前（RUNTIME）を書く"
    hb1=$(_kv .collector HEARTBEAT)
    [[ "$hb1" =~ ^[0-9]+$ ]] && pass "取得役の印に、合図（HEARTBEAT）を書く" || fail "取得役の印に、合図（HEARTBEAT）を書く" "$hb1"
    _wait_for 15 '! grep -qF -- "$mw" "$TD/logs/apex/.owners"' && pass "持ち主の見張りが、別の環境の印を外す" || fail "持ち主の見張りが、別の環境の印を外す" "$(cat "$TD/logs/apex/.owners")"
    assert_file_contains "$TD/logs/apex/.owners" "$m1" "同じ環境の印は残す"
    _wait_for 15 '[[ "$(_kv .collector HEARTBEAT)" -gt "$hb1" ]]' && pass "取得役が、合図を書き直す" || fail "取得役が、合図を書き直す"
    [[ "$(_kv .claim AT)" -ge "$hb1" ]] && pass "取得役が、名乗りの時刻を書き直す" || fail "取得役が、名乗りの時刻を書き直す" "$(_kv .claim AT)"
    # 別の環境（wsl）から見ると、扱っている環境がある
    export SF_LOG_TEST_RUNTIME=wsl
    _run pull -o dev
    assert_exit_fail "$RC" "別の環境からの pull → 中断"
    _has "$OUT" "別の環境（gitbash）で、デバッグログを取っています" "別の環境からの pull → 扱っている環境を表示する"
    _rt_mark wsl
    _run begin -o dev --owner "$MARK"
    assert_equals "$RC" "10" "別の環境からの begin → 10"
    assert_file_not_contains "$TD/logs/apex/.owners" "$MARK" "別の環境からの begin → 持ち主として登録しない"
    _alive "$CPID" && pass "別の環境からの操作で、取得役は止まらない" || fail "別の環境からの操作で、取得役は止まらない"
    # 扱っている環境での後始末 → 名乗りも消える（別の環境が始められる）
    export SF_LOG_TEST_RUNTIME=gitbash
    _run leave --owner "$m1"
    assert_exit_ok "$RC" "最後の leave が成功する"
    _wait_for 15 '! _alive "$CPID"' && pass "最後の leave → 取得役が止まる" || fail "最後の leave → 取得役が止まる"
    assert_file_not_exists "$TD/logs/apex/.claim" "最後の leave → 名乗りを消す"
    assert_file_not_exists "$TD/logs/apex/.collector" "最後の leave → 取得役の印を消す"
    unset SF_LOG_TEST_RUNTIME
    _done
}

test_start_basic
test_start_count_today
test_start_waits_for_upgrade
test_mock_org_lock
test_start_upgrade_owner_left
test_start_other_traceflags
test_start_auto
test_args
test_pull
test_pull_pushed_out_and_failures
test_late_recheck
test_late_recheck_failure
test_pull_read_marks
test_stop_status
test_collect_basic
test_collect_late
test_collect_stops
test_collect_extend
test_register_owner
test_begin
test_begin_retry
test_runtime_other_active
test_runtime_stale_and_legacy
test_runtime_claim
test_runtime_locks
test_runtime_collector

print_summary
