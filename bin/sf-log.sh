#!/bin/bash
# ==============================================================================
# sf-log.sh - AI の開発サイクル用に、デバッグログを手元に取り、AI 向けの要約を作る
# ==============================================================================
# 自分のユーザーのデバッグログ（ApexLog。Apex だけでなく、フロー・入力規則・重複ルールなど、1 回の処理の動きの記録）を、TraceFlag で出させて手元（logs/apex/）に保存し、AI が最初に読む要約
# （logs/apex/latest.md）を作る。ログを読むのは人ではなく AI（Claude Code など）。
# 設計: doc/sf-log-design.md（要約・一覧の検査・日時の計算は lib/apexlog.js）
#
# 【使い方】
#   sf-log.sh pull [-o ALIAS] [--max N] [--since 分]      # 新しいログを取って、要約を作る（AI が実行する。組織には書き込まない）
#   sf-log.sh status [-o ALIAS]                           # 状態を表示する（読み取りのみ）
#   sf-log.sh auto on|off [-o ALIAS]                      # sf-start のときに自動で取るか（このプロジェクトの答え）を変える
#   sf-log.sh start [-o ALIAS] [--level standard|detail] [--hours N] [-y]   # 取り始める（TraceFlag を作る・延ばす）
#   sf-log.sh stop [-o ALIAS]                             # 止める（自分が作った TraceFlag を消す）
#   sf-log.sh begin -o ALIAS --owner 印                   # 内部用（sf-start.sh が前面で呼ぶ。sf を呼ばずに判定し、準備と取得役を裏で起動する）
#   sf-log.sh start --auto [--collect [--retry N]] [--owner 印]   # 内部用（begin が裏で呼ぶ。尋ねない。--collect なら、成功のあと取得役になる）
#   sf-log.sh collect                                     # 内部用（裏の取得役。sf-start.sh が裏で起動する）
#   sf-log.sh leave --owner 印                            # 内部用（sf-start.sh の終了時。持ち主の一覧から外れる）
#
# 【オプション】
#   -o ALIAS            : 接続先の組織のエイリアス（省略時: 環境変数 SF_TARGET_ORG > sf org display の alias）
#   --level standard|detail : （start）ログの詳しさ（doc/sf-log-design.md 7 章）。既定 standard。--auto は常に standard
#   --hours N           : （start）TraceFlag の期限（時間）。1〜23 の整数（公式: 開始から 24 時間未満）。既定 2
#   -y                  : （start）AI への送信の確認と、ほかの USER_DEBUG の TraceFlag を止める確認を省く（手動のみ）
#   --auto              : （start）sf-start.sh からの自動の取り始め。終了コード 0 = 取り始めた／10 = 取らない／1 = 失敗
#   --owner 印          : （begin・start --auto・leave）持ち主（sf-start）の印。「PID:起動の時刻:環境の名前と乱数」（数字:数字:英数字。
#                         例 1234:1795500000:wsl8f3a。環境の名前は gitbash / wsl / macos / linux / unknown。doc/sf-log-design.md 5.6）
#   --collect           : （start --auto）準備が成功したら、同じプロセスで取得役（collect）になる（begin が使う）
#   --retry N           : （start --auto --collect）準備が失敗したとき（終了コード 1。「取らない」の 10 は除く）に、やり直す回数（0〜3。既定 0。
#                         begin は 1 を付ける）。持ち主が生きていて、後始末の最中でなければ、30 秒待ってから、回数を 1 減らして自分を exec する
#   --max N             : （pull）要約に入れるログの数の上限（1 以上の整数。既定 50。超えたら新しいほうから）
#   --since 分          : （pull）前回の pull を無視して、直近 N 分に始まったログを要約する（1 以上の整数）
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help          : このヘルプを表示する（1 番目の引数のときだけ）
#
# 【処理の流れ】
#   共通（status・auto 以外）:
#     0. （start のみ）sf の更新（sf-update-cli.sh。ロック ~/.sf-tools-upgrade.lock の PID が生きている）が動いていれば、
#        終わるまで最大 10 分待つ（sf の入れ替えの途中に sf を呼ぶと、部品が見つからずに失敗するため。2026-11-24。
#        sf-start は、sf-refresh.sh（その中で sf-update-cli.sh）と begin を同時に裏で動かす）。.status の WARNING に、待っていることを書く。
#        待つあいだに持ち主（--owner）がいなくなれば、準備をやめて 0 で終わる。待ち切れなければ、WARNING を出して進む
#     1a. 環境の判断（status 以外。0 より前。Git Bash と WSL の混在。doc/sf-log-design.md 5.6）: 手元のファイル（.collector・.claim）だけを
#        読み、別の環境が、このプロジェクトのログを扱っていれば、ファイル・ロック・組織に触れずに終える
#        （begin・start --auto: 終了コード 10／leave・collect: 0／start・pull・stop・auto: 中断）。別の環境が扱っている、とみなすのは:
#          a. 名乗り（.claim）の RUNTIME が自分と違い、AT が 30 分以内（読めない・未来の時刻を含む）
#          b. .collector の STARTED が 12 時間以内（読めない記録・12 時間より古い記録は、止まったもの）で、
#             RUNTIME がない（この変更の前の取得役。kill -0 によらず「環境不明」）か、RUNTIME が自分と違い、HEARTBEAT が 30 分以内（同上）
#        環境の名前（detect_runtime）は、unknown 同士でも同じとみなさない。記録の名前が 4 つ（gitbash / wsl / macos / linux）以外なら「環境不明」。
#        自分の環境が unknown のときは、この判断をしない（これまでの動き）
#     1. sf の確認（check_sf_cli --cache）・接続先の決定（get_target_org）
#     2. （start・pull）接続先が予約名（prod / staging / develop / main）・本番・種類を確認できない組織なら止める
#        （手動: 中断／--auto: 終了コード 10）。確認できないときは、理由を分ける（どれもログは取らない）:
#        認証の期限切れ・取り消し（lib/org.sh の org_is_auth_expired）→ 10（--auto の理由に、ログインし直し方を添える。die には添えない）／
#        組織の情報を読めない（通信・sf の一時的な失敗など）→ 1（裏の準備は、30 秒後に 1 回だけやり直す）／読めたが種類を判定できない → 10。
#        読めないときは、sf の応答の name と message の先頭を sf-log.log に残す（セッション ID の形の文字列は伏せる）
#     3. 自分のユーザー ID と組織 ID（sf org display user --json）
#   begin（sf-start の前面。sf を呼ばない。ランチャーを待たせないため）:
#     1. GitHub Actions 上・予約名 → 10
#     2. このプロジェクトの答え（logs/apex/.consent の AUTO・ORG（エイリアス）・VERSION）で判定する。「取らない」→ 10。
#        答えがない・エイリアスが変わった・注意の文面の版が変わったときは、注意を表示して Y/N で聞く（端末でない・q・N は「取らない」。
#        端末でないときは、答えを保存しない）
#     3. 持ち主の一覧に --owner の印を足す（後始末の最中なら、最大 60 秒待つ。終わらなければ 10）。同じ短いロックの中で、別の環境が
#        扱っていないかを確かめ直し（扱っていれば、何も書かずに 10）、扱う環境の名乗り（.claim の RUNTIME・OWNER・AT）を書いてから足す。
#        同じ環境の名乗りがあり、その印の持ち主が生きていれば、印は変えずに AT だけ今にする
#     4. .status を starting にし、start --auto --collect --retry 1 を nohup で裏に起動して、すぐ 0 で終わる
#        （ふつうの出力は捨て、エラー出力は sf-log.log に追記する）
#   start:
#     4. （--auto）GitHub Actions 上なら 10。尋ねない: 答え（.consent）が「取る」で、エイリアスと文面の版が同じでなければ 10。
#        答えの組織 ID（ORG_ID）が空なら、今の組織 ID を書く。違えば（同じエイリアスで別の組織に入り直した）、答えを消して 10
#        （次の sf-start の begin で聞き直す。同意のない組織のログを取らない）
#        （手動）注意を表示し、ask_yn || die（-y で省く）
#        --owner があれば、持ち主の一覧（logs/apex/.owners）に足す（同じ印は 2 回足さない。begin の 3 と同じ。名乗りも書く）。
#        後始末の最中（CLOSING）なら、終わるまで最大 60 秒待つ（CLOSING の持ち主が死んでいれば（別の環境の印を含む）消して進む。
#        待っても終わらなければ 10）
#     5. DebugLevel「sf_tools_log_<level>」を名前で探し、あれば 7 章の値で上書き、なければ作る（2 つ以上なら止める）
#     6. 自分のユーザーの TraceFlag を探す（lib/apexlog.js tflist で、有効・期限切れ・これから始まるものに分ける）
#        a. .state の TRACE_FLAG_ID と一致する USER_DEBUG があり、ほかに有効な USER_DEBUG がない → DebugLevel・開始（今）・
#           期限（今から --hours 時間）を更新。ほかに有効なものがあれば、延ばさずに b へ（手元に期限切れの自分の ID が残ったまま、
#           別の場所が取り始めていると、延ばすと期間が重なって失敗するため。PC の再起動のあとなど）
#        b. ほかの有効な USER_DEBUG が 2 つ以上 → 止める／1 つ → 手動: 表示して確認のあと、期限を「元の期限」と
#           「今から 2 分後」の早いほうに縮める（今にはできない）。
#           --auto: DebugLevel が sf_tools_log_standard / sf_tools_log_detail のもの（別の場所の sf-log.sh のもの）なら、
#           消して引き継ぐ（後から起動した sf-start を優先する。同じ Salesforce のユーザーなら、別のフォルダ・別の PC でも同じ）。
#           消せなければ 1。--owner の sf-start がもう終了していれば、引き継がずに 10。
#           それ以外（人・ほかの道具の設定）は、触らずに 10（理由に、期限と置き換え方を書く）
#           DEVELOPER_LOG・ほかの種類には触れない（USER_DEBUG とぶつからない）
#        c. 作る（USER_DEBUG。開始は今。b で縮めたときは、その期限の 1 秒後。それが過ぎていれば今）。
#           b で縮めたあとに作成が失敗しても、元に戻さない（縮めた ID・元の期限・縮めた期限を書く）
#     7. 組織を切り替えた（.state の ORG と違う）なら、前の組織の、sf-log.sh が作った TraceFlag を消す（消せなければ WARNING）
#        .state に組織・ユーザー ID・TraceFlag の ID を書く（組織・ユーザーが変わったら、取得と要約の時刻を今にする）
#     8. 組織のログの量を表示し、700MB を超えていれば WARNING（組織の上限は 1,000MB）
#     9. .status に STATE=collecting・期限（EXPIRES は UTC・EXPIRES_AT は PC の時刻の HH:MM。ランチャーが表示する）・
#        今日の本数（COUNT_TODAY。今日の日付のフォルダの *.log の数。前回の値を残さない）と、TAKEOVER（引き継いだら 1。
#        それ以外は空。ランチャーが表示する）を書く。--collect なら、同じプロセスで collect になる（exec）。
#     （--auto で取らない・失敗のとき）.status に理由を書き、別の組織の取得役（この環境のもの）が動いていれば、止まるよう頼む（5.3）。
#        自分の名乗り（.claim の OWNER が自分の印）は、同じ環境のほかの生きている持ち主がいなくて、この環境の取得役も動いていなければ消す
#        （別の環境を 30 分待たせない）。sf の更新を待つあいだに持ち主がいなくなって準備をやめるときも、同じく消す
#     （--retry が残っていて、失敗のとき）.status を starting に戻して WARNING（やり直しています）を書き、30 秒後にやり直す。
#        成功したら WARNING を消す。待つあいだに持ち主が終了した・後始末が始まったら、やり直さずに失敗として終わる
#   pull:
#     4. 取得役（logs/apex/.collector の PID）が生きていれば、自分では取らず、依頼（logs/apex/requests/pull.<ID>）を置いて、
#        自分の ID の応答（done.<ID>）を最大 90 秒待つ（待っても来なければ、手元にある分で要約し、その旨を書く）。
#        別の組織の取得役なら中断する。取得役がいなければ、取得のロック（logs/apex/.fetch.lock。最大 90 秒待つ）を持ち、しおり（.state の LAST_FETCH・LAST_FETCH_ID）から
#        古い順に取る（1 回 50 本。最大 4 回 = 200 本）。一覧は全ユーザーの見出し（run を通さない。他の人の ID を記録しない）、
#        本文は自分のログだけを保存する。取りたいログより新しいログがすべて自分のものなら sf apex get log -n でまとめて、
#        それ以外は -i で 1 本ずつ取る。本文は logs/apex/.fetch/ に書かせ、取りたい ID 以外は中を読まずに消す。
#        追いついたら（残りがなければ）、取得のロックを持ったまま、遅れて現れたログを拾い直す（下の「拾い直し」）
#     5. 保存: logs/apex/<日付>/<時刻>_<ID>_<操作>.log（日付・時刻は PC のタイムゾーン）と、目録 logs/apex/.index
#     6. 要約のロック（logs/apex/.read.lock。最大 90 秒）を取り、そのあとで、しおり（.state の LAST_READ_LINE・LAST_READ_ID）を読む。
#        目録は 1 回だけ読み、改行で終わる行だけを使う。選び方（開始時刻ではなく、目録に足された順）:
#          --since: しおりを使わず、目録の全行から直近 N 分に始まったログ
#          しおりが使えない（ない・形が違う・LAST_READ_ID が見つからない）・ロックが取れない: 目録の全行から直近 30 分に始まったログ（WARNING）
#          それ以外: LAST_READ_LINE 行目より後のすべての行（LAST_READ_LINE 行目の ID が LAST_READ_ID と違えば、ID で行を探し直す）
#        古い .state（LAST_READ・LAST_READ_IDS）は、開始が LAST_READ より前の行と、同じ秒で LAST_READ_IDS にある行を「見た」として移す。
#        --max を超えたら、開始時刻の新しいほう。要約の中は開始時刻の順
#     7. 要約を作り（node lib/apexlog.js summarize）、logs/apex/summaries/<時刻>.md と logs/apex/latest.md に書く
#     8. 成功したら（--since とロックが取れないときを除く）、読んだ目録の最後の行の番号と ID を LAST_READ_LINE・LAST_READ_ID にし、
#        要約のロックを外す。要約の 1 行目と latest.md のパスを表示する
#   拾い直し（取得役と pull の自分での取得。通常の取得が追いついた回に 1 回。doc/sf-log-design.md 8.3）:
#     ApexLog は処理が終わってから一覧に現れる（Id と StartTime は始まったときのもの）。長い処理のログは、しおりより前に
#     始まっていて、通常の取得では二度と取れないため、「今から 30 分前」（前の回の失敗で残した .state の LATE_FROM があれば、
#     その早いほう）から、しおりまでに始まった自分のログ（LogUserId で絞る。他の人の見出しは入らない）を、新しい順に 200 本ずつ
#     （最大 5 回 = 1,000 本）問い合わせ、目録にない ID を -i で 1 本ずつ取る（-n は使わない）。しおりは動かさない。
#     しおりが 30 分より古く、LATE_FROM もなければ、動かさない。失敗したら、その回の下限を LATE_FROM に残す（次の回にやり直す。
#     成功で消す。24 時間より古ければ消して WARNING）。1,000 本で範囲の終わりに届かなければ、限界として WARNING（LATE_FROM は消す）。
#     WARNING は sf-log.log と .status（WARNING・LATE_WARNING）に書き、pull は要約の先頭に書く
#   stop（人の判断。持ち主の一覧にかかわらず止める。別の環境の取得役には、何も送らない）:
#     4. .owners を CLOSING だけにする。取得役が生きていれば、停止の依頼（requests/stop）を置き、最大 30 秒待つ。
#        止まらなければ TERM で止め、さらに最大 10 秒待つ。それでも生きていれば、TraceFlag は消さずに中断する
#     5. .state の TRACE_FLAG_ID の TraceFlag を消す（すでになければ WARNING。消せなければ中断し、ID は残す）
#     6. TRACE_FLAG_ID・.collector・.owners を消し、.status を stopped にする（期限の表示も消す）。DebugLevel・手元のログは消さない。
#        後始末が済んだら、最後に名乗り（.claim）を消す（.owners を消したあと。別の環境は、そのあとで名乗れる）
#   leave --owner 印（sf-start の終了時）:
#     4. 持ち主の一覧から自分の印を外し、死んだ持ち主（と、別の環境の印）を除く。生きている持ち主が残っていれば、何も止めずに
#        終わる（残りの件数と、組織のログの設定が残ることを表示する。sf-start は、この出力を表示する）。死んだ印を数えないのは、
#        PC の再起動などで残った印は、取得役がいないと消えず、数えると TraceFlag を消せなくなるため
#     5. 誰もいなければ、CLOSING を書いて、stop の 4〜6 と同じ後始末をする（名乗りも最後に消す）。失敗は WARNING だけ（終了コードは 0）
#   collect（裏の取得役。.state の組織・ユーザーで取る。出力は sf-log.log と .status だけ）:
#     4. 取得役の印（.collector）を確かめる（短いロックの中で、別の環境が扱っていないかも確かめ直す。扱っていれば 0 で終わる）:
#        同じ組織の取得役（この環境のもの）が生きていれば、何もせずに終わる。別の組織なら、止めてもらって入れ替わる。
#        印には PID・STARTED・ORG・RUNTIME（環境の名前）・HEARTBEAT（生きている合図。エポック秒）を書き、名乗りの AT も今にする
#     5. 5 秒ごとに目を覚まし、次を繰り返す（sf を呼ぶのは、取得と延長のときだけ）。目を覚ますたび・sf を呼ぶ直前・ログを 1 本保存する
#        たびに、合図（HEARTBEAT）と名乗りの AT を書き直す（30 秒より短い間隔では書かない。別の環境は、30 分途絶えたら止まったとみなす）:
#        a. 持ち主の見張り: 死んだ持ち主（kill -0）と、環境の名前が自分と違う印（前に別の環境で使ったときの残り）を一覧から外す。
#           一覧が空 → 自分で後始末（TraceFlag を消す）をして止まる。
#           起動から 12 時間（SF_LOG_MAX_SECONDS）でも、同じく止まる
#        b. 停止の依頼・CLOSING・印の入れ替わり → 組織に何もせずに止まる（延長の直前にも確かめる）
#        c. 間隔（SF_LOG_INTERVAL）が来た・pull の依頼がある・取り残しがある → 取得のロックが取れたら、pull と同じ方法で 1 回取る。
#           sf の更新（sf-update-cli.sh）が動いているあいだは、取らずに次に回す（start の 0 と同じ理由）。
#           追いついた回は、取得のロックを持ったまま拾い直し（pull の「拾い直し」）をし、目録に書き終えてから、待っている pull に応える。
#           追いついたら、待っている pull に応答する。失敗したら、次の取得までの間隔を倍にする（最大 600 秒）
#        c2. 取得の回ごとに、自分の TraceFlag がまだ自分のものかを確かめる（取得のあと。引き継がれる前のログは取り終えている）。
#           自分のものが有効でなく、別の sf_tools_log_* の有効な USER_DEBUG があれば、引き継がれたとみなして止まる
#           （組織には書き込まない。.state の TRACE_FLAG_ID を空にし、.collector・名乗りを消し、.status を stopped にして理由を書く。
#           持ち主の一覧は残す。ランチャーの Start・次の sf-start で取り戻せる。取得役からは取り返さない）。
#           自分のものがないだけなら、作り直さずに WARNING を書き、取得は続ける。期限が切れただけで相手がいなければ、d へ。
#           組織の切り替えの最中（.state の ORG が違う）と、問い合わせの失敗は、判断しない
#        d. TraceFlag の残りが 60 分未満なら、ID と種類を確かめてから、今から 2 時間に延ばす
#        e. 5 分より古い依頼・応答を消す
#   status: 取得役が動いているか、手元の状態（.status・.state）、持ち主の数、自分のユーザーの TraceFlag、自分のログの本数と合計を表示する（読み取りのみ）。
#     取得役の行: 別の環境が扱っていれば「別の環境（X）で動作中（最後の合図は N 秒前）」、名乗りだけなら「取得役の起動待ち」、
#     古い形・形の正しくない記録は「状態不明」。.status の ORG が接続先と違えば「状態不明」。組織に問い合わせできなくても、止めずにその旨を表示する
#   auto on|off: logs/apex/.consent の AUTO・ORG（エイリアス）・ORG_ID・VERSION を書く（組織には書き込まない）
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること
#   - Salesforce CLI（npm 版）と Node（sf に含まれる）。接続ユーザーが DebugLevel・TraceFlag を作れること
#   - 一人用の開発組織（Developer Edition・Sandbox・スクラッチ組織）で、ダミーデータで使うこと
#
# 【補足】
#   - 本体は、入口（このファイル: 1〜3 章と 11 章）と、phases/log/ の部品 7 つ（common・start・fetch・pull・stop・collect・status。
#     4〜10b 章）に分けてある（2026-11-28 に、1665 行を分けた。部品は、このファイルが 4 章の位置で、章の順に source する）
#   - 終了コード: 0 = 成功／1 = 失敗（手動の中断を含む）／10 = 取らない（start --auto のみ）
#   - ログには、レコードの値・SOQL の条件などが載る。AI に読ませると、AI の提供元に送られる（start の確認）
#   - 手元のログ（logs/apex/）は Git の管理外。stop も消さない。消すときは、日付のフォルダを手で消す
#   - 他の人のログは、本文を保存・記録・要約しない。sf apex get log -n の直後にできた他の人のログが
#     logs/apex/.fetch/ に一瞬書かれることがあるが、中を読まずに消す（取得のたびに空にする）
#   - sf-start.sh が、ランチャーを開く前に begin、終了時に leave を呼ぶ（5 章）。ランチャーは .status を 1 行で表示する
#   - 環境変数: SF_LOG_INTERVAL（取得の間隔。秒。30〜600。既定 180。sf の 1 回が約 10 秒かかるため。pull はすぐ取らせる）・
#     SF_LOG_MAX_SECONDS（取得役の上限。秒。既定 43200 = 12 時間）・SF_LOG_TEST_FAST=1（テスト用。間隔の下限を 1 にし、待ち時間を短くする）・
#     SF_TOOLS_UPGRADE_LOCK（sf の更新のロックの場所。既定 ~/.sf-tools-upgrade.lock。sf-update-cli.sh と同じ。テストで差し替える）・
#     SF_LOG_TEST_RUNTIME（テスト用。自分の環境の名前を決める。英小文字だけ）
#   - 持ち主の生死は kill -0 で見る（PID が使い回されたときは、12 時間の上限で止まる）。別の環境（Git Bash と WSL）の PID は見えないため、
#     環境の名前で見分ける（1a・doc/sf-log-design.md 5.6）。1 つのプロジェクトのログは、同時には 1 つの環境だけが扱う
#   - ロック（.lock・.fetch.lock・.read.lock。mkdir）の pid ファイルは「PID 環境 取った時刻（エポック秒）」の 1 行（一時ファイルから置き換える）。
#     同じ環境（または環境のない古い形）なら PID が死んでいれば、別の環境なら取った時刻から 10 分より古ければ、残ったロックとして消す。
#     pid ファイルがない・形が違う・時刻が未来のロックは、奪わずに、それぞれの上限まで待つ
#   - ログ: ./sf-tools/logs/sf-log.log（追記）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"   # pull・start・stop が同じログに書く（取得の記録を残す）

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 共通ライブラリ（第 1 引数の -h / --help も、ここで処理する: lib/common.sh の 0 章）
source "${SCRIPT_DIR}/../lib/common.sh" \
    || { echo "[FATAL ERROR] Library not found: ${SCRIPT_DIR}/../lib/common.sh" >&2; exit 1; }  # run 不使用: run の定義前
source "${SCRIPT_DIR}/../lib/org.sh"   # org_local_release_check（組織の種類の確認）

# ------------------------------------------------------------------------------
# 3. 定数・引数
# ------------------------------------------------------------------------------
readonly AJS="${SCRIPT_DIR}/../lib/apexlog.js"
readonly APEX_DIR="logs/apex"
readonly STATE_F="${APEX_DIR}/.state"
readonly STATUS_F="${APEX_DIR}/.status"
readonly CONSENT_F="${APEX_DIR}/.consent"
readonly OWNERS_F="${APEX_DIR}/.owners"
readonly COLLECTOR_F="${APEX_DIR}/.collector"
readonly INDEX_F="${APEX_DIR}/.index"
readonly LOCK_DIR="${APEX_DIR}/.lock"
readonly FETCH_LOCK="${APEX_DIR}/.fetch.lock"
readonly FETCH_TMP="${APEX_DIR}/.fetch"
readonly READ_LOCK="${APEX_DIR}/.read.lock"   # 要約のロック（pull が、しおりを読んでから書くまで。4.4 の 3）
readonly CLAIM_F="${APEX_DIR}/.claim"         # 扱う環境の名乗り（5.6。begin・start --auto が書き、取得役が AT を書き直す）
readonly MIX_STALE=1800 FOREIGN_LOCK_AGE=600   # 5.6: 別の環境の合図・名乗りは 30 分、別の環境のロックは 10 分で、古いとみなす
readonly LATE_WINDOW=1800 LATE_PAGE=200 LATE_MAX_PAGES=5 LATE_MAX_AGE=86400   # 拾い直し（8.3）: 30 分・200 本ずつ・最大 5 回・LATE_FROM は 24 時間まで
readonly REQ_DIR="${APEX_DIR}/requests"
readonly CONSENT_VERSION="1"            # AI への送信の注意の文面の版（変えたら上げる。10.2）
readonly ORG_LOG_WARN_BYTES=$((700 * 1024 * 1024))
readonly ID_RE='^[A-Za-z0-9]{15}([A-Za-z0-9]{3})?$'
readonly ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

CMD="${1:-}"
[[ -n "$CMD" ]] || die "サブコマンドを指定してください（pull / status / auto / start / stop / collect / leave / begin）。"
shift
AUTO_ARG=""
if [[ "$CMD" == "auto" ]]; then
    AUTO_ARG="${1:-}"
    [[ "$AUTO_ARG" == "on" || "$AUTO_ARG" == "off" ]] || die "auto には on か off を指定してください。"
    shift
fi
ORG_ARG=""; LEVEL="standard"; HOURS=2; YES=0; AUTO=0; OWNER=""; MAX_LOGS=50; SINCE_MIN=""; COLLECT_AFTER=0; RETRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)        [[ -n "${2:-}" && "${2:-}" != -* ]] || die "-o の値（組織のエイリアス）がありません。"; ORG_ARG="$2"; shift ;;
        --level)   LEVEL="${2:-}"; shift ;;
        --hours)   HOURS="${2:-}"; shift ;;
        -y)        YES=1 ;;
        --auto)    AUTO=1 ;;
        --collect) COLLECT_AFTER=1 ;;
        --retry)   RETRY="${2:-}"; shift ;;
        --owner)   OWNER="${2:-}"; shift ;;
        --max)     MAX_LOGS="${2:-}"; shift ;;
        --since)   SINCE_MIN="${2:-}"; shift ;;
        -v|--verbose) : ;;   # SILENT_EXEC は common.sh が設定済み
        *)         die "不明なオプションです: $1" ;;
    esac
    shift
done
case "$CMD" in
    start|pull|stop|status|auto|collect|leave|begin) ;;
    *) die "不明なサブコマンドです: ${CMD}（pull / status / auto / start / stop / collect / leave / begin）" ;;
esac
[[ ( "$CMD" != "leave" && "$CMD" != "begin" ) || -n "$OWNER" ]] || die "${CMD} には --owner が要ります。"
[[ "$CMD" != "begin" || -n "$ORG_ARG" ]] || die "begin には -o が要ります。"
[[ $COLLECT_AFTER -eq 0 || $AUTO -eq 1 ]] || die "--collect は start --auto だけに付けられます。"
[[ "$RETRY" =~ ^[0-3]$ ]] || die "--retry は 0〜3 の整数です: ${RETRY}"
[[ "$RETRY" -eq 0 || $COLLECT_AFTER -eq 1 ]] || die "--retry は start --auto --collect だけに付けられます。"
[[ "$LEVEL" == "standard" || "$LEVEL" == "detail" ]] || die "--level は standard か detail です: ${LEVEL}"
[[ "$HOURS" =~ ^[0-9]+$ && "$HOURS" -ge 1 && "$HOURS" -le 23 ]] || die "--hours は 1〜23 の整数です: ${HOURS}"
[[ "$MAX_LOGS" =~ ^[0-9]+$ && "$MAX_LOGS" -ge 1 ]] || die "--max は 1 以上の整数です: ${MAX_LOGS}"
[[ -z "$SINCE_MIN" || ( "$SINCE_MIN" =~ ^[0-9]+$ && "$SINCE_MIN" -ge 1 ) ]] || die "--since は 1 以上の整数（分）です: ${SINCE_MIN}"
[[ -z "$OWNER" || "$OWNER" =~ ^[0-9]+:[0-9]+:[A-Za-z0-9]+$ ]] || die "--owner の形が正しくありません: ${OWNER}"
if [[ $AUTO -eq 1 ]]; then
    [[ "$CMD" == "start" ]] || die "--auto は start だけに付けられます。"
    LEVEL="standard"; YES=0
fi
# 取得役の時間（4.3）。SF_LOG_TEST_FAST=1 はテスト用（下限を外し、目を覚ます間隔と待ち時間を短くする）
_fast=0; [[ "${SF_LOG_TEST_FAST:-}" == "1" ]] && _fast=1
INTERVAL="${SF_LOG_INTERVAL:-180}"      # 取得の間隔（秒）。sf の 1 回が約 10 秒かかるため、既定 180（2026-11-23。pull はすぐ取らせる）
_min_iv=30; [[ $_fast -eq 1 ]] && _min_iv=1
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge $_min_iv && "$INTERVAL" -le 600 ]] || die "SF_LOG_INTERVAL は ${_min_iv}〜600（秒）の整数です: ${INTERVAL}"
TICK=5; [[ $_fast -eq 1 ]] && TICK=1    # 取得役が目を覚ます間隔（秒。sf は呼ばない）
MAX_RUN="${SF_LOG_MAX_SECONDS:-43200}"  # 取得役の上限（秒。12 時間。PID の再利用への備え。5.5）
[[ "$MAX_RUN" =~ ^[0-9]+$ && "$MAX_RUN" -ge 1 ]] || die "SF_LOG_MAX_SECONDS は 1 以上の整数です: ${MAX_RUN}"
PULL_WAIT=90; STOP_WAIT=30; CLOSING_WAIT=60; RETRY_WAIT=30   # RETRY_WAIT: 裏の準備の失敗から、やり直すまで（秒）
UPGRADE_WAIT=600   # sf の更新（sf-update-cli.sh）が終わるのを待つ上限（秒）。WSL の実機で、sf の入れ替えに約 3 分かかった（2026-11-24）
READ_TRIES=450     # 要約のロックを待つ回数（0.2 秒ごと。最大 90 秒）
[[ $_fast -eq 1 ]] && { PULL_WAIT=30; STOP_WAIT=10; CLOSING_WAIT=10; RETRY_WAIT=1; UPGRADE_WAIT=10; READ_TRIES=10; }
# sf の更新のロック（sf-update-cli.sh が、動いているあいだ PID を書く。場所は sf-update-cli.sh と同じ）
UPGRADE_LOCK="${SF_TOOLS_UPGRADE_LOCK:-${HOME}/.sf-tools-upgrade.lock}"
# 動いている環境（5.6。gitbash / wsl / macos / linux / unknown）。SF_LOG_TEST_RUNTIME はテスト用（別の環境の代わりをする）
RUNTIME_SELF=$(detect_runtime)  # VAR=$(cmd) のため run 不使用
[[ -n "${SF_LOG_TEST_RUNTIME:-}" ]] && RUNTIME_SELF="$SF_LOG_TEST_RUNTIME"
[[ "$RUNTIME_SELF" =~ ^[a-z]+$ ]] || die "環境の名前の形が正しくありません: ${RUNTIME_SELF}"
HB_EVERY=30; [[ $_fast -eq 1 ]] && HB_EVERY=1   # 取得役が合図（HEARTBEAT）を書く最短の間隔（秒。目安の 30 分より十分に短い）
IS_COLLECTOR=0; HB_LAST=0
command -v node >/dev/null 2>&1 || die "node が見つかりません（sf CLI の npm 版に必要です）。"  # 存在確認のため run 不使用
mkdir -p "$APEX_DIR"  # run 不使用: 自分の作業フォルダを作るだけ（失敗は、次の書き込みで分かる）

# ------------------------------------------------------------------------------
# 4〜10b. 部品の読み込み（phases/log/。2026-11-28 に、このファイルから分けた。読み込む順番は、元の章の順のまま）
# ------------------------------------------------------------------------------
# 部品は関数の定義と、その前の小さな変数の初期化だけ。ここで順に source するため、動きは分ける前と同じ
LOG_PARTS_DIR="${SCRIPT_DIR%/*}/phases/log"
for _part in common start fetch pull stop collect status; do
    source "${LOG_PARTS_DIR}/${_part}.sh" \
        || die "sf-log.sh の部品を読み込めません: ${LOG_PARTS_DIR}/${_part}.sh"
done
unset _part

# ------------------------------------------------------------------------------
# 11. 入口
# ------------------------------------------------------------------------------
# 環境の判断（4.1 の 1a・5.6）: 手元のファイル（.collector・.claim）だけを読む。別の環境が扱っていれば、status 以外は、ここで終える
if [[ "$CMD" != "status" ]] && other_runtime_active; then refuse_other_runtime; fi
case "$CMD" in
    begin)   cmd_begin ;;
    start)   cmd_start ;;
    pull)    cmd_pull ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    auto)    cmd_auto ;;
    collect) cmd_collect ;;
    leave)   cmd_leave ;;
esac
