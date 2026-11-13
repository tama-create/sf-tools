'use strict';
// ==============================================================================
// metasync.js - 組織から取得した内容と手元の main を比べて計画を作り、反映する（bin/sf-metasync.sh から呼ぶ）
// ==============================================================================
// 組織の内容を正として、手元の「同期の対象のフォルダ」を、取得結果と同じにする（鏡像）。追加・変更・削除を、計画（plan）に
// して出し、削除には、安全の守り（S2〜S5・S9）を通す。反映（apply）は、計画の A・M・D だけを行う（H = 保留は、何もしない）。
// Node の標準ライブラリだけを使う（追加パッケージなし。sf CLI が npm 版のため、Node は前提）。
// 境界は、この 1 ファイルだけ。シェル側（bin/sf-metasync.sh）が、順序・Git・警告と確認・終了コードを受け持つ。
// 設計: doc/sf-metasync-redesign.md（3.4 境界・4.5 削除の守り）
//
// 【使い方】
//   node lib/metasync.js plan  --repo DIR --fetched DIR --types-file F --dirs-table F --out PLAN
//                              [--recent-files F] [--retrieve-json F] [--allow-mass-delete]
//   node lib/metasync.js apply --plan PLAN --repo DIR --fetched DIR
//   node lib/metasync.js root  --repo DIR     # sfdx-project.json のパッケージのフォルダ（path）を出す。1 つでなければ中断（S8）
//   node lib/metasync.js detect --org ALIAS --types-file F --table F --state F --out-state F [--now ISO]
//                                              # 組織に変更があるかを、取得の前に調べる（読み取りのみ。設計 15 章）
//   node lib/metasync.js fingerprint --org ALIAS --fp-config F --state F --out-state F [--out-report F] [--repo DIR] [--now ISO]
//                                              # 一覧（Node 直接の SOAP）の指紋を作り、前回と比べる（読み取りのみ。設計 16 章。P1 の影の比較）
//   node lib/metasync.js fpcompare --report F --plan PLAN --fp-config F --dirs-table F
//                                              # 指紋の結果と、計画（実際の変更）を突き合わせて、見逃しを記録する（影の比較。情報のみ）
//   node lib/metasync.js manifest --org ALIAS --extra-config F --out PACKAGE_XML [--repo DIR]
//                                              # 追加の取得の package.xml を作る（組織の一覧から名前を集める。読み取りのみ。設計 16 章の P2）
//   node lib/metasync.js scan --plan PLAN --repo DIR --fetched DIR [--allow F] [--out-report F]
//                                              # これから書く内容（計画の A・M）に、秘密情報の疑いがないか調べる（読み取りのみ。設計 16.7）
//
// 【オプション】
//   --fp-config F       : （fingerprint・fpcompare）指紋を取る種類の表（sf-tools の config/metasync-fingerprint.txt）
//   --out-report F      : （fingerprint）種類ごとの結果（JSON。fpcompare が読む）の出力先／（scan）疑いの一覧（規則<TAB>パス<TAB>件数<TAB>キー）の出力先
//   --extra-config F    : （manifest・plan）追加の取得の表（sf-tools の config/metasync-extra.txt）
//   --extra-json F      : （plan）追加の取得の sf project retrieve の応答（JSON）
//   --extra-state S     : （plan）追加の取得の結果: off（行わない設定）/ ok / failed（省略 = 追加の取得の扱いをしない。従来どおり）
//   --extra-manifest F  : （plan）追加の取得に使った package.xml（取れたかを、指定した名前 − 実際のファイルで確かめる。--extra-state ok のとき）
//   --allow F           : （scan）許可の一覧（1 行に「規則 パス [キー]」。規則は * で全部。パスは * が使える。キーは、疑いの表示の「キー: …」
//                         = 項目名・ラベル名・要素名・変数名。省略すると、そのパスの規則すべて）。なくてもよい
//   --report F          : （fpcompare）fingerprint の --out-report
//   --org ALIAS         : （detect・fingerprint）問い合わせる組織のエイリアス
//   --table F           : （detect）種類ごとの検知の区分の表（sf-tools の config/metasync-detect.txt）
//   --state F           : （detect・fingerprint）前回の状態（force-* の sf-tools/metasync/state.json・fingerprint.json）。なくても、読めなくてもよい
//   --out-state F       : （detect・fingerprint）今回の状態の出力先。書くのは、終了コード 10・11 で、一覧の取得ができたときだけ
//   --now ISO           : （detect・fingerprint）今回の開始時刻（テスト用。省略時は現在）
//   --repo DIR          : 手元のリポジトリの根（sfdx-project.json がある場所。fingerprint では、API バージョン（sourceApiVersion）を読む。省略時は 64.0）
//   --fetched DIR       : 取得結果の一時プロジェクトの根（sfdx-project.json の packageDirectories と同じ構成）
//   --types-file F      : 同期する種類の一覧（force-* の sf-tools/config/metadata.txt）
//   --dirs-table F      : 種類 → フォルダ名の表（sf-tools の config/metadata-dirs.txt）
//   --out PLAN          : 計画の出力先（TSV。上書き）
//   --recent-files F    : 直近に、同期以外のコミットで変わったファイルの一覧（リポジトリの根からの相対パス。1 行に 1 つ）。S5 に使う
//   --retrieve-json F   : sf project retrieve start --json の応答。S1・S2 に使う（空・読めないときは、問題なしとみなす）
//   --allow-mass-delete : S3（消えたフォルダ）・S4（削除が多い）の保留を解く
//
// 【処理の流れ】（plan）
//   1. sfdx-project.json の packageDirectories が 1 つでなければ、中断する（S8）。根 = <path>/main/default
//   2. 同期の対象のフォルダ = 「--types-file の種類に当たるフォルダ（--dirs-table）」と「取得結果にあるフォルダ」の和集合
//   3. フォルダごとに、手元（A）と取得結果（B）のファイルを比べる。B だけ = A（追加）／ 両方で中身が違う = M（変更）／
//      A だけ = D（削除）。中身は、バイト単位で比べる。改行コード（CRLF / LF）だけの違いは、同じとみなす（テキストのみ）
//   4. 残すファイル（削除の対象にしない）: .gitkeep と、.forceignore の行に当たるファイル（否定の ! の行は、警告して無視する）
//   5. 削除の守り（当たった削除は H = 保留にして、ファイルを残す）:
//        S1 取得の応答の status が 0 以外 → 中断（終了コード 1）
//        S2 取得の応答に、問題の報告がある → 報告に種類が読み取れて、その種類のフォルダがあれば、そのフォルダの削除を保留。
//           種類が読み取れなければ、その回の削除を、すべて保留。
//           ただし、「この組織・この API バージョンでは使えない種類」（Entity type 'X' is not available in this organization /
//           api version）の報告は、取得の失敗ではないので、表（--dirs-table）にある種類のフォルダだけ保留し、表にない種類は保留しない
//        S3 手元に 1 件以上あった（残すファイルを除く）フォルダが、取得結果で 0 件 → そのフォルダの削除を保留（--allow-mass-delete で解く）
//        S5 --recent-files にあるファイルの削除 → 保留（時間がたてば解ける。--allow-mass-delete では解けない）
//        S4 残りの削除の件数が、max(100, 手元の同期の対象のファイルの 10%) を超える → 削除をすべて保留（--allow-mass-delete で解く）
//        S9 追加の取得を行わない設定（--extra-state off）のときの、標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除 → 保留（on で取ったファイルを消さない。
//           取得も削除もしない状態が続くだけなので、終了コードは 3 にしない。--allow-mass-delete では解けない）
//   6. 標準出力に、要約（件数・削除の一覧の先頭 30 件・保留とその理由）を出し、--out に計画を書く。
//      要約の最後に、「使えない種類」（S2 の報告）と、警告（先頭に [WARNING] を付ける行）を出す。どちらも、種類が多くても 1 行にまとめる
//      （重複は除く。名前は省略しない）。表（--dirs-table）にない種類の警告も、1 行
//
// 【補足】
//   ・計画の形式（TSV。見出し行なし）: 操作<TAB>パス<TAB>理由。操作は A・M・D・H。パスは、リポジトリの根からの相対（/ 区切り）。
//     H の理由は S2 / S3 / S4 / S5 / S9。A・M・D の理由は空
//   ・終了コード: 0 = 計画できた（保留なし、または S5・S9 だけ）／ 3 = 計画できた（S2・S3・S4 の保留あり）／ 1 = 中断
//     （引数の誤り・読めない・S1・S8・パスの安全の確認。メッセージは標準エラーに [ERROR] で出す）
//   ・apply は、計画のパスが、根（<path>/main/default）の外を指していたら、何も変えずに中断する（終了コード 1）。
//     削除で空になったフォルダは、根の直下まで消す（根は残す）
//   ・.forceignore の解釈は、*・**・?・先頭の /・末尾の / だけに対応する（gitignore の簡易版）
//
// 【処理の流れ】（detect。変更の検知。設計 15 章）
//   1. --types-file の種類を、--table の区分で分ける: A = 設定変更の履歴（SetupAuditTrail）で検知 ／ B = 更新日時の一覧
//      （sf org list metadata）で検知 ／ C = 表にない種類（検知できない。毎日の全件取得でだけ反映される）
//   2. 区分 B の種類の一覧を取り、種類ごとの「最新の更新日時・件数・名前のハッシュ」を作る（Report・Dashboard・Document・
//      EmailTemplate は、フォルダの種類を先に一覧し、フォルダごとに問い合わせる。sf は同時に 4 つまで）
//   3. 前回の状態（--state）が読めて、版（version）と設定のハッシュ（configHash）が合うときだけ、比べる。
//      区分 A に種類があれば、履歴に「前回の開始時刻の 10 分前」より後の記録が 1 件でもあるかを、1 回の問い合わせ
//      （SELECT COUNT() FROM SetupAuditTrail WHERE CreatedDate > …）で調べる（履歴の分類名・Action は、見ない）
//   4. 区分 B のどれかが前回と違う、または履歴に記録がある → 変更あり（10）。どちらもない → 変更なし（0）。
//      状態が使えない・履歴の問い合わせが失敗 → 不明（11）。一覧の取得が失敗 → 不明（11。状態は書かない）
//   5. 10・11 のとき（一覧が取れていれば）、今回の状態（lastFullSyncAt = 今回の開始時刻）を --out-state に書く。
//      呼び出し側は、全件取得が成功したあとで、これを状態ファイルにする
//
// 【補足】（detect）
//   ・終了コード: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明（呼び出し側は、0 以外では、必ず全件取得する）／ 1 = 引数の誤り
//   ・環境変数 SF_METASYNC_SF: 起動するコマンドを sf から差し替える（テストで、モックの sf を使うため）
//   ・変更なしと判定できても、区分 C の種類の変更は見えない（毎日の全件取得で反映される）。検知は、取得を省くための手がかりで、
//     正しさの根拠にしない（失敗・不明は、すべて全件取得に倒す）
//
// 【処理の流れ】（fingerprint。一覧の指紋。設計 16 章の P1。影の比較のため、取得は従来どおり行う）
//   1. --fp-config の種類（子の種類・フォルダ型を含む）ごとに、組織の一覧を、Node 直接の SOAP（listMetadata。1 種類 1 回。
//      フォルダ型は、フォルダを先に一覧し、フォルダごとの部品を 3 か所ずつまとめて一覧する（1 回の呼び出しに問い合わせを 3 つまで入れられる）。
//      フォルダは 900 個まで。同時に 6 つまで）で取る。アクセストークンとインスタンス URL は、sf org display --json から読む
//      （現行の sf はトークンを伏せ字で返すので、そのときは sf org auth show-access-token で取る。メモリだけに持ち、出力・ログには出さない）。送る先は https のインスタンス URL だけ（テストのモックのため、手元の
//      127.0.0.1・localhost・[::1] の http だけ例外）。転送（リダイレクト）は追わない（トークン入りの本文が、転送先へ再送されるのを防ぐ）。
//      API バージョンは、--repo の sfdx-project.json の sourceApiVersion（なければ 64.0）
//   2. 管理パッケージ本体の部品（manageableState = installed）を除き、種類ごとに「件数・最新の更新日時・名前と更新日時のハッシュ」を作る。
//      この組織では使えない種類（INVALID_TYPE）は、失敗ではなく「使えない」として記録する。応答が Metadata API の形でない
//      （HTTP 200 のメンテナンス画面など）、1 回の待ち（30 秒）や全体（180 秒。sf の呼び出しを含む。最後の 1 回の待ちの分だけ超えうる）の
//      期限切れ、フォルダが上限超えは、失敗（= 不明）にする。注意: Node の fetch は、HTTPS_PROXY を使わない（プロキシ越しでは常に不明になる）
//   3. 前回の状態（--state）が読めて、版（version）と設定のハッシュ（configHash。種類の表と API バージョン）が合うときだけ、比べる。
//      種類ごとの判定: 変更なし／変更あり（件数または指紋が違う・使えるようになった／使えなくなった）／不審（件数が前回の半分以下に
//      なった。前回が 4 件以上のとき）。更新日時は、前回との比較だけに使う（時計とは比べない）
//   4. 全体の判定: どれかが失敗 → 不明（11。状態は書かない。1 つ失敗した時点で、残りの問い合わせは中止し、実行中の要求のやり直しも止める。
//      失敗の一覧と件数は、中止の時点で実行中だった分まで（中止後はやり直さないため、やり直せば成功した要求も、失敗として並ぶことがある。原因は最初の 1 件）。接続エラーは 1 回やり直すので、1 件の待ちは最大で 2 倍）／ 状態がない・不審がある → 不明（11）／ 変更ありの種類がある → 変更あり（10）／
//      どれもない → 変更なし（0）。10・11 のとき（失敗がなければ）、今回の状態を --out-state に書く。--out-report には、
//      判定と、種類ごとの結果（status・件数・前回の件数）を書く
//
// 【処理の流れ】（fpcompare。影の比較。情報のみ。終了コードは常に 0）
//   1. 計画（--plan）の追加・変更・削除（A・M・D。保留 H は除く）を、フォルダ（objects は、子の種類を分ける: fields・validationRules・
//      recordTypes・listViews・webLinks・fieldSets・compactLayouts・businessProcesses・オブジェクト本体）ごとに、まとめる
//   2. グループごとに、指紋の種類（--fp-config の dir= と --dirs-table）を結びつけ、判定する: 検知できた（指紋が変わった種類がある）／
//      見逃し（指紋の対象の種類があるのに、どれも変わっていない。WARNING で出す）／ 日時では検知できない種類（Profile・PermissionSet など、
//      別の部品を足しても自分の更新日時が動かない種類と、一覧の日時がすべて 1970 年のままの種類。見逃しとは分けて数える。WARNING にしない）／
//      指紋の対象外（結びつく種類がない）。0 件の種類・使えない種類は、「日時では検知できない」の判定から外す。
//      注意: 指紋は取得の前に取るため、その間に組織が変わると、その回は「見逃し」、次の回は「空振り」になる（対で見る）。
//      S5 の保留が解けた削除（D）も、指紋が動かないまま計画に現れる。1 回の見逃しだけで、種類を表から外す判断をしない
//   3. 逆に、指紋が変わったのに、計画に変更がなかった種類（空振り）も、一覧にする。指紋が不明（11）のときは、比べない
//
// 【処理の流れ】（manifest。追加の取得の package.xml。設計 16.2・16.5.3）
//   1. --extra-config の種類ごとに、組織の一覧（Node 直接の SOAP の listMetadata。管理パッケージ本体は除く）から名前を集める: folder= = フォルダの一覧を先に取り、
//      フォルダごとに部品を一覧する（フォルダ自身も取る。unfiled$public はフォルダとしては取らない）／ mode=stdobj = 標準オブジェクト（オブジェクト名に __ を含まない）の
//      部品だけ（CustomField は __c だけ）／ mode=svs = StandardValueSet（一覧が 0 件のため、固定の名前の表）
//   2. --out に package.xml を書く。終了コード: 0 = 書いた ／ 12 = 取る部品がない（書かない）／ 11 = 不明（一覧の失敗・部品が 9000 件超）／ 1 = 引数・表の誤り
//   plan の追加の取得（--extra-state）: ok = その種類のフォルダを同期の対象にする（取得結果が 0 件でも、組織に本当にない。S3 の守りは効く）。failed = その種類のフォルダと
//   標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除を、すべて保留する（S2）。off（行わない設定）= 追加の取得の種類のフォルダのうち、取得結果に現れないものは
//   同期の対象にせず、標準オブジェクトの部品の削除を保留する（on で入れたファイルを、off に戻した回に消さない）。
//   取れたかどうかは、応答の文言ではなく、ディスクで確かめる: --extra-manifest（指定した名前）のうち、取得結果にファイルがない名前は、そのファイルの削除だけ保留する
//   （文言のない空の報告・「cannot be found」・取れない StandardValueSet・権限不足の警告は、情報としてだけ読む。実機では、取れなかった部品が、文言のない報告になる）
//
// 【処理の流れ】（scan。秘密情報の検査。設計 16.7）
//   1. 計画（--plan）の追加（A）・変更（M）のファイルの、取得結果（--fetched）の内容を調べる。削除・保留は対象外。UTF-16（BOM つき）は、
//      UTF-16 として読む。バイナリ（先頭 8000 バイトに NUL）は、秘密鍵と既知のトークンだけを探す。20 MB 超は検査しない。どちらも、
//      ファイル名を「検査に制限があるファイル」として出す。規則の正規表現が、数 MB の連続した文字列でスタックを溢れさせたとき（RangeError）は、
//      検査全体を落とさず、「検査できなかった」ことを疑いの 1 件（規則 scan-error・キー = 落ちた規則名）にする（on では止まる。確かめたら、許可の
//      一覧の「scan-error パス」で外す）。変更（M）は、手元（--repo）にすでにある同じ疑わしい文字列を除く（今回新しく入る分だけ）
//   2. 規則: xml-secret-element（consumerSecret・clientSecret・password・privateKey・apiKey・token などの要素。属性つき・CDATA も。
//      プレースホルダでない値）／ custommetadata-secret-field・customlabel-secret（秘密らしい項目名・ラベル名に、秘密らしい値）／
//      private-key（BEGIN … PRIVATE KEY）／ known-token（AWS・GitHub・Slack（Webhook を含む）・Stripe・Google の API キー、JWT、
//      Salesforce のセッション）／ url-secret（?client_secret=…・&password=… などの URL の引数、user:pass@host、Bearer …）／
//      code-hardcoded-secret（classes・triggers・lwc・aura・pages・components の、秘密らしい名前への文字列の代入。引用符つきのキーと => も。
//      テストクラス *Test.cls・*Tests.cls・*_test.cls・*_tests.cls は除く）。「秘密らしい値」= 空白なし・ASCII だけ・8 文字以上・数字を含む・API 名（__c など / c.… /
//      Label.…）でない・認証情報のない URL でない・数値・日付・パス（/a/b の形）でない・プレースホルダでない（名前・URL・日付・日本語の文言を、
//      疑いにしない）。数字を含まない値（英字だけの長いパスワードなど）は検出しない（既知の制約。エントロピーでは、普通の名前と区別できない）。
//      XML の規則は、対象のファイルを限る（xml-secret-element = *.xml ／ custommetadata-secret-field = *.md-meta.xml と *.flow-meta.xml
//      ／ customlabel-secret = *.labels-meta.xml）。CustomMetadata は文字列型（xsd:string）だけ。CDATA は外して調べる。Key という単語だけの
//      名前（External_Key など）は、値が 16 文字以上のときだけ。名前の最後の単語が name・label・url・date・expiry・id などのものは、秘密の入れ物にしない。
//      Flow は、<field> の代入と、<name> の後の <stringValue>（定数・変数・入力パラメータ。{!…} を含む動的な値は除く）も見る
//      プレースホルダ: Placeholder_…、* や x だけ、{!…}、${…}、<…>、真偽値、redacted など
//   3. --allow の「規則 パス [キー]」に当たる疑いは、除く。標準出力に要約と、疑い（先頭が [WARNING]。規則名・パス・キーだけ。値は出さない）を出し、
//      --out-report に一覧（規則<TAB>パス<TAB>件数<TAB>キー）を書く。終了コード: 0 = 疑いなし ／ 10 = 疑いあり ／ 1 = 中断（引数・許可の書式・読めないファイル・計画のパス）
//
// 【補足】（fingerprint・fpcompare）
//   ・終了コード（fingerprint）: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明（呼び出し側は、取得を省かない）／ 1 = 引数・設定の誤り
//   ・環境変数 SF_METASYNC_SF: sf の差し替え（テストで、モックの sf を使う。sf org display の応答の instanceUrl に、モックの SOAP の
//     サーバーを指す）
//   ・環境変数 SF_METASYNC_FP_TIMEOUT_MS（1 回の待ちの上限。既定 30000）・SF_METASYNC_FP_DEADLINE_MS（全体の期限。既定 180000）: テスト用
//   ・--out-report の種類ごとの結果には、更新日時が 1970 年のままの件数（epoch）も入る（fpcompare 用。状態ファイルには入れない）
//   ・P1 は、取得を省かない（影の比較のため）。指紋は、取得を省くための手がかりで、正しさの根拠にしない
// ==============================================================================

const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const crypto = require('crypto');

const MASS_MIN = 100;        // S4: 削除の件数のしきい値の下限
const MASS_RATIO = 0.10;     // S4: 手元の同期の対象のファイルに対する割合
const LIST_MAX = 30;         // 要約に出す削除の一覧の件数

function fail(msg) {
  process.stderr.write('[ERROR] ' + msg + '\n');
  process.exit(1);
}

// ---- 引数 ----
function parseArgs(argv) {
  const cmd = argv[0];
  if (!['plan', 'apply', 'root', 'detect', 'fingerprint', 'fpcompare', 'scan', 'manifest'].includes(cmd)) fail('使い方: node lib/metasync.js plan|apply|root|detect|fingerprint|fpcompare|scan|manifest [オプション]');
  const o = { cmd, allowMass: false };
  const need = new Set(['--repo', '--fetched', '--types-file', '--dirs-table', '--out', '--recent-files', '--retrieve-json', '--plan',
    '--org', '--table', '--state', '--out-state', '--now', '--fp-config', '--out-report', '--report', '--allow', '--extra-config', '--extra-json', '--extra-state', '--extra-manifest']);
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--allow-mass-delete') { o.allowMass = true; continue; }
    if (need.has(a)) {
      if (i + 1 >= argv.length) fail(a + ' に値がありません。');
      o[a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
      continue;
    }
    fail('不明なオプションです: ' + a);
  }
  const req = cmd === 'plan' ? ['repo', 'fetched', 'typesFile', 'dirsTable', 'out'] : cmd === 'root' ? ['repo']
    : cmd === 'detect' ? ['org', 'typesFile', 'table', 'state', 'outState']
    : cmd === 'fingerprint' ? ['org', 'fpConfig', 'state', 'outState']
    : cmd === 'fpcompare' ? ['report', 'plan', 'fpConfig', 'dirsTable']
    : cmd === 'manifest' ? ['org', 'extraConfig', 'out'] : ['plan', 'repo', 'fetched'];
  for (const k of req) if (!o[k]) fail('--' + k.replace(/[A-Z]/g, c => '-' + c.toLowerCase()) + ' は必須です。');
  return o;
}

// ---- ファイルの読み取りの部品 ----
function readLines(file) {
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith('#'));
}

function packageRoot(repo) {
  const f = path.join(repo, 'sfdx-project.json');
  if (!fs.existsSync(f)) fail('sfdx-project.json が見つかりません: ' + f);
  let j;
  try { j = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { fail('sfdx-project.json を読めません: ' + e.message); }
  const dirs = j && j.packageDirectories;
  if (!Array.isArray(dirs) || dirs.length !== 1 || !dirs[0].path) {
    fail('sfdx-project.json の packageDirectories が 1 つではありません（S8。新しい部品の置き場所を決められないため、中断します）。');
  }
  return dirs[0].path.replace(/\\/g, '/').replace(/\/+$/, '') + '/main/default';
}

function walk(dir) {   // dir の下のファイルを、dir からの相対パス（/ 区切り）で返す。なければ空
  const out = [];
  if (!fs.existsSync(dir)) return out;
  (function rec(d, rel) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const r = rel ? rel + '/' + e.name : e.name;
      if (e.isDirectory()) rec(path.join(d, e.name), r);
      else if (e.isFile()) out.push(r);
    }
  })(dir, '');
  return out.sort();
}

function sameContent(fa, fb) {
  const a = fs.readFileSync(fa), b = fs.readFileSync(fb);
  if (a.equals(b)) return true;
  if (a.includes(0) || b.includes(0)) return false;   // バイナリは、改行の違いを無視しない
  const norm = x => x.toString('latin1').replace(/\r\n/g, '\n');
  return norm(a) === norm(b);
}

// ---- .forceignore（gitignore の簡易版）----
function globToRegex(pat) {
  let re = '';
  for (let i = 0; i < pat.length; i++) {
    const c = pat[i];
    if (c === '*') {
      if (pat[i + 1] === '*') {
        if (pat[i + 2] === '/') { re += '(?:.*/)?'; i += 2; } else { re += '.*'; i += 1; }
      } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return re;
}

function loadIgnore(repo, warnings) {
  const f = path.join(repo, '.forceignore');
  const rules = [];
  if (!fs.existsSync(f)) return () => false;
  for (let line of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('!')) { warnings.push('.forceignore の否定の行は、解釈しません（無視します）: ' + line); continue; }
    let anchored = false;
    if (line.startsWith('/')) { anchored = true; line = line.slice(1); }
    line = line.replace(/\/+$/, '');
    if (!line) continue;
    if (line.includes('/')) anchored = true;
    const body = globToRegex(line);
    rules.push(new RegExp(anchored ? '^' + body + '(?:/.*)?$' : '(?:^|/)' + body + '(?:/.*)?$'));
  }
  return p => rules.some(r => r.test(p));
}

// ---- 追加の取得のファイルの場所（根からの相対。拡張子の前まで）----
//   標準オブジェクトの部品: objects/<オブジェクト>/<サブフォルダ>/<名前>。ほかは、フォルダ/<名前>（Report・Dashboard・EmailTemplate の名前は「フォルダ/名前」）
const EXTRA_OBJECT_SUBDIR = { CustomField: 'fields', ValidationRule: 'validationRules', ListView: 'listViews', RecordType: 'recordTypes', BusinessProcess: 'businessProcesses',
  WebLink: 'webLinks', FieldSet: 'fieldSets', CompactLayout: 'compactLayouts' };
const EXTRA_TYPE_DIR = { Report: 'reports', ReportFolder: 'reports', Dashboard: 'dashboards', DashboardFolder: 'dashboards', EmailTemplate: 'email',
  EmailFolder: 'email', StandardValueSet: 'standardValueSets' };
function extraPathPrefix(type, name) {
  if (EXTRA_OBJECT_SUBDIR[type]) {
    const i = String(name).indexOf('.');
    return i > 0 ? `objects/${name.slice(0, i)}/${EXTRA_OBJECT_SUBDIR[type]}/${name.slice(i + 1)}` : null;
  }
  return EXTRA_TYPE_DIR[type] ? `${EXTRA_TYPE_DIR[type]}/${name}` : null;
}
// 追加の取得で「指定したのに、取得結果にファイルがない」名前の、ファイルの場所（拡張子の前まで）の一覧。応答の文言には頼らない（実機では、取れなかった部品が、
//   文言のない報告になる）。package.xml（--extra-manifest）の types/members を読み、<場所>.<拡張子> のファイルが、取得結果（fetchedRoot）にあるか見る。
//   場所を決められない種類は、数えない（extraPathPrefix が null）
function extraMissing(manifestFile, fetchedRoot) {
  const res = { missing: [], specified: 0 };
  if (!manifestFile || !fs.existsSync(manifestFile)) return res;
  const xml = fs.readFileSync(manifestFile, 'utf8');
  const dirCache = new Map();
  const filesIn = d => {
    if (!dirCache.has(d)) {
      let l = [];
      try { l = fs.readdirSync(path.join(fetchedRoot, d)); } catch (e) { /* ディレクトリがない = 空 */ }
      dirCache.set(d, l);
    }
    return dirCache.get(d);
  };
  for (const tb of xml.split('<types>').slice(1)) {
    const type = xmlTag(tb, 'name');
    for (const mm of tb.matchAll(/<members>([^<]*)<\/members>/g)) {
      const prefix = extraPathPrefix(type, xmlUnesc(mm[1]));
      if (!prefix) continue;
      res.specified++;
      const d = path.posix.dirname(prefix), b = path.posix.basename(prefix) + '.';
      if (!filesIn(d).some(n => n.startsWith(b))) res.missing.push(prefix);
    }
  }
  return res;
}

// ---- 取得の応答（S1・S2）----
// 報告は、2 つの形を読む。
//   ・「この組織・この API バージョンでは使えない種類」（Entity type 'X' is not available in this organization / api version）:
//     取得の失敗ではない（その種類の部品は、もともと取得されない。Developer Edition などでは、ふつうに出る）。
//     表（typeToFolder）にある種類は、そのフォルダだけ保留する。表にない種類は、保留しない（取得結果にフォルダが現れず、同期の対象にならない
//     ため、守る対象がない）
//   ・上以外の問題の報告: 種類が読めて、表にあれば、そのフォルダだけ保留する。読めない・表にないときは、その回の削除を、すべて保留する
//   追加の取得（extra = true。設計 16.5.4・16.14）: 取れなかった部品の報告は、文言で判断しない（実機では、取れなかったレポートが、文言のない
//   空の報告 {"fileName":"unpackaged/package.xml","problem":""} になる）。「cannot be found」・取れない StandardValueSet・権限不足（Dashboard など）・
//   文言のない報告は、情報として数えるだけ（infoCount）で、保留の対象にしない。取れたかどうかは、plan が、指定した名前 − 実際のファイルで確かめる
//   （missingExtra）。それ以外の問題の報告は、上と同じ
function readRetrieve(file, types, typeToFolder, warnings, extra) {
  const res = { status: 0, holdAll: false, holdFolders: new Set(), notes: [], unavailable: [], infoCount: 0 };   // unavailable: 使えない種類の名前（重複なし。表示は 1 行にまとめる）
  if (!file || !fs.existsSync(file)) return res;
  let j;
  try { j = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return res; }   // 空・JSON でない = 情報なし
  if (!j || typeof j !== 'object') return res;
  if (typeof j.status === 'number' && j.status !== 0) { res.status = j.status; return res; }
  const r = j.result || {};
  const items = [].concat(Array.isArray(r.messages) ? r.messages : [], Array.isArray(r.warnings) ? r.warnings : []);
  for (const it of items) {
    const text = typeof it === 'string' ? it : String((it && (it.problem || it.message)) || JSON.stringify(it));
    if (extra) {
      // 文言のない報告（problem が空）・「Entity of type 'T' named 'N' cannot be found」・「Unable to retrieve file for id 54 (QuoteStatus). This Standard Value Set
      //   is either inaccessible or not supported」・「You do not have the proper permissions to access Dashboard.」: 取れなかった部品。ディスクで確かめるため、情報だけ
      const empty = it && typeof it === 'object' && !it.problem && !it.message;
      if (empty || /Entity of type '[A-Za-z0-9_]+' named '[^']+' cannot be found/i.test(text)
        || /Unable to retrieve file for id \d+ \([A-Za-z0-9_]+\)\. This Standard Value Set/i.test(text)
        || /permissions to access [A-Za-z0-9_]+/i.test(text)) { res.infoCount++; continue; }
    }
    const na = /Entity type '([A-Za-z0-9_]+)' is not available in this (?:organization|api version)/i.exec(text);
    if (na) {
      const naFolder = typeToFolder.get(na[1]);
      if (naFolder) res.holdFolders.add(naFolder);
      if (!res.unavailable.includes(na[1])) res.unavailable.push(na[1]);
      continue;
    }
    const m = /type:\s*([A-Za-z0-9_]+)/.exec(text) || /of type\s+([A-Za-z0-9_]+)/.exec(text)
      || /permissions to access ([A-Za-z0-9_]+)/.exec(text);   // 「You do not have the proper permissions to access Dashboard.」（そのフォルダだけ保留）
    const folder = m ? typeToFolder.get(m[1]) : null;
    if (folder) { res.holdFolders.add(folder); res.notes.push(m[1] + ': ' + text.slice(0, 120)); }
    else { res.holdAll = true; res.notes.push(text.slice(0, 120)); }
  }
  return res;
}

// ---- plan ----
function plan(o) {
  const warnings = [];
  const root = packageRoot(o.repo);
  const repoRoot = path.join(o.repo, root), fetchedRoot = path.join(o.fetched, root);

  const types = readLines(o.typesFile);
  const typeToFolder = new Map();
  for (const l of readLines(o.dirsTable)) {
    const p = l.replace(/\s+#.*$/, '').split(/\s+/);
    if (p.length >= 2) typeToFolder.set(p[0], p[1]);
  }
  const managed = new Set();
  for (const t of types) {
    if (typeToFolder.has(t)) managed.add(typeToFolder.get(t));
  }
  const fetchedTop = fs.existsSync(fetchedRoot)
    ? fs.readdirSync(fetchedRoot, { withFileTypes: true }).filter(e => e.isDirectory()).map(e => e.name) : [];
  for (const d of fetchedTop) managed.add(d);
  // 表にない種類は、1 行にまとめる（重複は除く。名前は、省略しない）。種類ごとに 1 行ずつ出すと、40 行以上になるため
  const unmapped = [...new Set(types.filter(t => !typeToFolder.has(t)))];
  if (unmapped.length) {
    warnings.push(`表（--dirs-table）にない種類が ${unmapped.length} 個あります（取得結果にフォルダが現れれば同期し、現れなければ触りません）: ${unmapped.join('、')}`);
  }

  const retrieve = readRetrieve(o.retrieveJson, types, typeToFolder, warnings);
  if (retrieve.status !== 0) fail('取得の応答の status が 0 以外です（S1）: ' + retrieve.status);

  // 追加の取得（--extra-state。省略 = 扱わない。従来どおり）。
  //   ok（成功）: その種類のフォルダを、同期の対象にする（取得結果が 0 件でも、組織に本当にない = 削除できる。S3 の守りは効く）。指定した名前のうち、
  //     取得結果にファイルがないものは、そのファイルの削除だけ保留する（extraMissing。応答の文言には頼らない）
  //   failed（一覧・取得の失敗、応答の status が 0 以外）: その種類のフォルダと、標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除を、すべて保留する
  //     （取れなかったものを、削除と取り違えない。設計 16.5.4）
  //   off（行わない設定）: 追加の取得の種類のフォルダのうち、取得結果に現れないものは、同期の対象にしない。標準オブジェクトの部品の削除は保留する
  //     （on で入れたファイルを、off に戻した回に、鏡像で消さない）
  let extraState = o.extraState || 'none';
  let extraHoldStd = false, extraStdHeld = 0;
  const extraPrefixes = [];
  let extraNotFound = 0, extraInfo = 0;
  const extraFolders = [];
  if (extraState !== 'none') {
    if (!['off', 'ok', 'failed'].includes(extraState)) fail('--extra-state は off・ok・failed のどれかにしてください: ' + extraState);
    if (!o.extraConfig) fail('--extra-state には --extra-config が要ります。');
    for (const s of loadExtraConfig(o.extraConfig)) {
      for (const t of [s.type, s.folder].filter(Boolean)) {
        const f = typeToFolder.get(t);
        if (f && f !== 'objects' && !extraFolders.includes(f)) extraFolders.push(f);
      }
    }
    if (extraState === 'ok') {
      const ex = readRetrieve(o.extraJson, types, typeToFolder, warnings, true);
      if (ex.status !== 0) extraState = 'failed';
      else {
        if (ex.holdAll) retrieve.holdAll = true;
        for (const f of ex.holdFolders) retrieve.holdFolders.add(f);
        for (const n of ex.notes) retrieve.notes.push('（追加の取得）' + n);
        for (const u of ex.unavailable) if (!retrieve.unavailable.includes(u)) retrieve.unavailable.push(u);
        extraInfo = ex.infoCount;
        const mi = extraMissing(o.extraManifest, fetchedRoot);
        extraPrefixes.push(...mi.missing);
        extraNotFound = mi.missing.length;
        extraHoldStd = ex.holdAll || ex.holdFolders.has('objects');   // 標準オブジェクトの部品は、objects の問題か、種類の読めない問題のときだけ
      }
    }
    if (extraState === 'ok') for (const f of extraFolders) managed.add(f);
    else if (extraState === 'failed') { for (const f of extraFolders) retrieve.holdFolders.add(f); extraHoldStd = true; }
    else { for (const f of extraFolders) if (!fetchedTop.includes(f)) managed.delete(f); extraHoldStd = true; }   // off
  }

  const ignored = loadIgnore(o.repo, warnings);
  const recent = new Set(o.recentFiles && fs.existsSync(o.recentFiles) ? readLines0(o.recentFiles) : []);

  const rows = [];      // {op, p, reason}
  const delByFolder = new Map();
  let localTotal = 0;
  const folders = [...managed].sort();
  for (const f of folders) {
    const A = walk(path.join(repoRoot, f));
    let B = walk(path.join(fetchedRoot, f));
    // 追加の取得: 標準オブジェクトの部品を取ると、中身のない objects/<標準オブジェクト>/<標準オブジェクト>.object-meta.xml（入れ物だけ）も付いてくる。
    //   これは、追加も変更も削除もしない（手元に同じ名前があっても、そのまま残す）
    const emptyStd = new Set();
    if (extraState !== 'none' && f === 'objects') {
      B = B.filter(rel => {
        const seg = rel.split('/');
        if (seg.length !== 2 || seg[0].includes('__') || seg[1] !== seg[0] + '.object-meta.xml') return true;
        const body = fs.readFileSync(path.join(fetchedRoot, f, rel), 'utf8');
        if (/<CustomObject\b[^>]*\/>|<CustomObject\b[^>]*>\s*<\/CustomObject>/.test(body)) { emptyStd.add(rel); return false; }
        return true;
      });
    }
    const setA = new Set(A), setB = new Set(B);
    const isKeep = rel => path.posix.basename(rel) === '.gitkeep' || ignored(root + '/' + f + '/' + rel);
    localTotal += A.filter(x => !isKeep(x)).length;
    const dels = [];
    for (const rel of B) {
      const p = root + '/' + f + '/' + rel;
      if (!setA.has(rel)) rows.push({ op: 'A', p, reason: '' });
      else if (!sameContent(path.join(repoRoot, f, rel), path.join(fetchedRoot, f, rel))) rows.push({ op: 'M', p, reason: '' });
    }
    for (const rel of A) {
      if (setB.has(rel) || isKeep(rel) || emptyStd.has(rel)) continue;
      dels.push(root + '/' + f + '/' + rel);
    }
    delByFolder.set(f, { dels, fetchedCount: B.length, localKept: A.filter(x => !isKeep(x)).length });
  }

  // 削除の守り
  const held = (p, reason) => rows.push({ op: 'H', p, reason });
  let pending = [];
  for (const f of folders) {
    const d = delByFolder.get(f);
    for (const p of d.dels) {
      const relp = p.slice(root.length + 1);
      if (retrieve.holdAll || retrieve.holdFolders.has(f)) held(p, 'S2');
      else if (extraHoldStd && f === 'objects' && !(relp.split('/')[1] || '').includes('__')) {   // 標準オブジェクトの部品: 追加の取得が不完全（S2）／ 行わない設定（S9）
        held(p, extraState === 'off' ? 'S9' : 'S2'); extraStdHeld++;
      }
      else if (extraPrefixes.some(x => relp.startsWith(x + '.'))) held(p, 'S2');   // 追加の取得で、指定したのに取れなかった名前のファイル
      else if (!o.allowMass && d.localKept >= 1 && d.fetchedCount === 0) held(p, 'S3');
      else if (recent.has(p)) held(p, 'S5');
      else pending.push(p);
    }
  }
  const limit = Math.max(MASS_MIN, Math.floor(localTotal * MASS_RATIO));
  if (!o.allowMass && pending.length > limit) {
    for (const p of pending) held(p, 'S4');
    pending = [];
  }
  for (const p of pending) rows.push({ op: 'D', p, reason: '' });

  rows.sort((a, b) => (a.p < b.p ? -1 : a.p > b.p ? 1 : 0));
  fs.writeFileSync(o.out, rows.map(r => r.op + '\t' + r.p + '\t' + r.reason).join('\n') + (rows.length ? '\n' : ''));

  // 要約
  const cnt = op => rows.filter(r => r.op === op).length;
  const out = [];
  out.push(`計画: 追加 ${cnt('A')} 件 / 変更 ${cnt('M')} 件 / 削除 ${cnt('D')} 件 / 削除の保留 ${cnt('H')} 件`);
  out.push(`  （同期の対象のフォルダ ${folders.length} 個 / 手元の対象のファイル ${localTotal} 件 / 大量削除のしきい値 ${limit} 件）`);
  const dl = rows.filter(r => r.op === 'D');
  if (dl.length) {
    out.push(`削除（先頭 ${Math.min(LIST_MAX, dl.length)} 件 / 全 ${dl.length} 件）:`);
    for (const r of dl.slice(0, LIST_MAX)) out.push('  - ' + r.p);
  }
  const hl = rows.filter(r => r.op === 'H');
  if (hl.length) {
    const by = {};
    for (const r of hl) by[r.reason] = (by[r.reason] || 0) + 1;
    const why = { S2: '取得の応答に問題の報告がある', S3: '手元にあったフォルダが、取得結果で 0 件', S4: '削除が多い', S5: '直近にマージされたファイル', S9: '追加の取得を行わない設定（標準オブジェクトの部品）' };
    out.push('削除の保留（ファイルは残す）:');
    for (const k of Object.keys(by).sort()) out.push(`  - ${k} ${why[k]}: ${by[k]} 件`);
    for (const r of hl.slice(0, LIST_MAX)) out.push(`    ${r.reason} ${r.p}`);
  }
  if (retrieve.unavailable.length) {
    out.push(`この組織・この API バージョンでは使えない種類が ${retrieve.unavailable.length} 個あります（取得されません）: ${retrieve.unavailable.join('、')}`);
  }
  for (const n of retrieve.notes.slice(0, 10)) out.push('取得の応答の問題: ' + n);
  if (extraState === 'ok') {
    out.push(`追加の取得: 反映した（同期の対象に ${extraFolders.length} フォルダ + 標準オブジェクトの部品。指定したのに取れなかった名前 ${extraNotFound} 件は、そのファイルの削除だけ保留。応答の報告 ${extraInfo} 件は情報のみ）`);
  } else if (extraState === 'failed') {
    out.push(`[WARNING] 追加の取得が失敗または不完全だったため、${extraFolders.join('・')} と標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除を、すべて保留しました`);
  } else if (extraState === 'off' && extraStdHeld) {
    out.push(`追加の取得は行わない設定（SF_METASYNC_EXTRA=off）のため、標準オブジェクトの部品（objects/<標準オブジェクト>/）の削除 ${extraStdHeld} 件を保留しました（on で取ったファイルを消さないため。S9。終了コードは 3 にしません）`);
  }
  for (const w of warnings) out.push('[WARNING] ' + w);
  process.stdout.write(out.join('\n') + '\n');
  process.exitCode = hl.some(r => r.reason !== 'S5' && r.reason !== 'S9') ? 3 : 0;   // process.exit は使わない（Windows のパイプで、出力が欠けないように）
}

function readLines0(file) {   // 行の前後の空白は残さず、# の行も含めて、すべて読む（パスの一覧用）
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
}

// ---- apply ----
function apply(o) {
  const root = packageRoot(o.repo);
  const repoRoot = path.resolve(o.repo, root), fetchedRoot = path.resolve(o.fetched, root);
  const rows = fs.readFileSync(o.plan, 'utf8').split('\n').filter(Boolean).map(l => l.split('\t'));
  const inside = (base, rel) => {
    const abs = path.resolve(o.repo, rel);
    return abs === base || abs.startsWith(base + path.sep) ? abs : null;
  };
  for (const [op, p] of rows) {      // 先に、すべてのパスを確かめる（途中で中断して、半端に反映しない）
    if (!['A', 'M', 'D', 'H'].includes(op) || !p) fail('計画の形式が正しくありません: ' + op + ' ' + p);
    if (!inside(repoRoot, p)) fail('計画のパスが、同期の対象の外を指しています: ' + p);
  }
  let a = 0, m = 0, d = 0;
  for (const [op, p] of rows) {
    const dst = inside(repoRoot, p);
    const rel = p.slice(root.length + 1);
    if (op === 'A' || op === 'M') {
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.copyFileSync(path.join(fetchedRoot, rel), dst);
      if (op === 'A') a++; else m++;
    } else if (op === 'D') {
      fs.rmSync(dst, { force: true });
      d++;
      for (let dir = path.dirname(dst); dir !== repoRoot && dir.startsWith(repoRoot + path.sep); dir = path.dirname(dir)) {
        if (fs.readdirSync(dir).length) break;
        fs.rmdirSync(dir);
      }
    }
  }
  process.stdout.write(`反映: 追加 ${a} 件 / 変更 ${m} 件 / 削除 ${d} 件\n`);
}

// ---- root: sfdx-project.json の packageDirectories の path を出す（S8 の確認を兼ねる。シェルが、一時プロジェクトと git add に使う）----
function rootCmd(o) {
  packageRoot(o.repo);   // 1 つでなければ、ここで中断する
  const j = JSON.parse(fs.readFileSync(path.join(o.repo, 'sfdx-project.json'), 'utf8'));
  process.stdout.write(j.packageDirectories[0].path.replace(/\\/g, '/').replace(/\/+$/, '') + '\n');
}

// ---- detect: 変更の検知（設計 15 章）----
const SKEW_MIN = 10;          // 履歴の問い合わせの基準を、前回の開始時刻より前にずらす分（時計のずれと、記録の遅れの分）
const SF_MAX_PARALLEL = 4;    // sf の同時実行の上限
// フォルダ型の種類 → フォルダの種類。フォルダごとに問い合わせる
const FOLDER_TYPE = { Report: 'ReportFolder', Dashboard: 'DashboardFolder', Document: 'DocumentFolder', EmailTemplate: 'EmailFolder' };
const UNFILED = { Report: 'unfiled$public', EmailTemplate: 'unfiled$public' };   // フォルダに入っていない部品の置き場所

const sha = s => crypto.createHash('sha1').update(s).digest('hex').slice(0, 16);
const isoSec = d => d.toISOString().replace(/\.\d+Z$/, 'Z');
const sq = a => {   // sf の引数を、シェルを通して渡すための引用（名前に $ や空白を含むため）
  const s = String(a);
  return process.platform === 'win32' ? '"' + s.replace(/"/g, '\\"') + '"' : "'" + s.replace(/'/g, "'\\''") + "'";
};

let sfActive = 0;
const sfWaiters = [];
async function sfAcquire() { if (sfActive < SF_MAX_PARALLEL) { sfActive++; return; } await new Promise(r => sfWaiters.push(r)); }
function sfRelease() { const w = sfWaiters.shift(); if (w) w(); else sfActive--; }

// sf を実行して、応答（JSON）を返す。失敗（終了コード・status・JSON でない）は、例外
//   timeoutMs: 待ちの上限（省略時は 180 秒。fingerprint は、全体の期限の残りを渡す）
async function sfJson(args, timeoutMs) {
  await sfAcquire();
  try {
    const cmd = (process.env.SF_METASYNC_SF || 'sf') + ' ' + args.concat('--json').map(sq).join(' ');
    return await new Promise((resolve, reject) => {
      cp.exec(cmd, { maxBuffer: 1 << 26, timeout: timeoutMs || 180000 }, (err, stdout, stderr) => {
        // 待ちの上限で止められた（応答が空のため、JSON が読めない失敗と区別する）
        if (err && err.killed && err.code !== 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') return reject(new Error(`sf が時間切れです（${Math.round((timeoutMs || 180000) / 1000)} 秒）: ` + args.slice(0, 4).join(' ')));
        let j;
        try { j = JSON.parse(stdout.slice(stdout.indexOf('{'))); } catch (e) { return reject(new Error('sf の応答を読めません: ' + args.slice(0, 4).join(' '))); }
        if (err || j.status !== 0) return reject(new Error('sf が失敗しました: ' + args.slice(0, 4).join(' ') + ' (' + String(j.message || stderr || '').replace(/\s+/g, ' ').slice(0, 100) + ')'));
        resolve(j);
      });
    });
  } finally { sfRelease(); }
}

async function listMeta(org, type, folder) {
  const a = ['org', 'list', 'metadata', '--metadata-type', type, '--target-org', org];
  if (folder) a.push('--folder', folder);
  const r = (await sfJson(a)).result;
  return Array.isArray(r) ? r : r ? [r] : [];
}

// 種類ごとの「最新の更新日時・件数・名前のハッシュ」。フォルダ型は、フォルダ自身と、フォルダの中の部品を合わせる
async function snapshotType(org, type) {
  let entries;
  if (FOLDER_TYPE[type]) {
    const folders = await listMeta(org, FOLDER_TYPE[type]);
    const names = folders.map(e => e.fullName);
    if (UNFILED[type]) names.push(UNFILED[type]);
    const parts = await Promise.all(names.map(f => listMeta(org, type, f)));
    entries = folders.concat(...parts);
  } else entries = await listMeta(org, type);
  const names = entries.map(e => String(e.fullName)).sort();
  const newest = entries.map(e => String(e.lastModifiedDate || '')).sort().pop() || '';
  return { newest, count: entries.length, hash: sha(names.join('\n')) };
}

async function detect(o) {
  const out = [];
  const finish = (code) => { process.stdout.write(out.join('\n') + '\n'); process.exitCode = code; };
  const types = readLines(o.typesFile);
  const table = new Map();
  for (const l of readLines(o.table)) {
    const p = l.replace(/\s+#.*$/, '').split(/\s+/);
    if (p.length >= 2 && (p[0] === 'A' || p[0] === 'B')) table.set(p[1], p[0]);
  }
  const aTypes = types.filter(t => table.get(t) === 'A'), bTypes = types.filter(t => table.get(t) === 'B');
  const cCount = types.length - aTypes.length - bTypes.length;
  const configHash = sha([...aTypes].sort().join(',') + '|' + [...bTypes].sort().join(',') + '|' + types.slice().sort().join(','));
  const now = o.now ? new Date(o.now) : new Date();
  if (isNaN(now.getTime())) fail('--now が日時として読めません: ' + o.now);
  out.push(`検知: A ${aTypes.length} 種類（履歴）/ B ${bTypes.length} 種類（更新日時の一覧）/ C ${cCount} 種類（毎日の全件取得でだけ反映）`);

  // 前回の状態（読めない・版や設定が違う = 使えない）
  let state = null, stateWhy = '';
  if (!fs.existsSync(o.state)) stateWhy = '前回の状態がありません';
  else {
    try {
      const s = JSON.parse(fs.readFileSync(o.state, 'utf8'));
      if (s && s.version === 1 && s.configHash === configHash && s.types && typeof s.types === 'object' && !isNaN(Date.parse(s.lastFullSyncAt))) state = s;
      else stateWhy = '前回の状態の版または設定が、今回と合いません';
    } catch (e) { stateWhy = '前回の状態を読めません'; }
  }

  // 区分 B の一覧。失敗したら、状態も書かずに、不明で終える
  const snap = {};
  try { await Promise.all(bTypes.map(async t => { snap[t] = await snapshotType(o.org, t); })); } catch (e) {
    out.push('不明: 更新日時の一覧を取得できませんでした: ' + e.message);
    return finish(11);
  }
  const next = { version: 1, configHash, lastFullSyncAt: isoSec(now), types: snap };
  const save = () => fs.writeFileSync(o.outState, JSON.stringify(next, null, 2) + '\n');

  if (!state) { out.push('不明: ' + stateWhy + '（全件取得で、状態を作ります）'); save(); return finish(11); }

  const reasons = [];
  for (const t of bTypes) {
    const a = state.types[t], b = snap[t];
    if (!a) reasons.push(`${t}: 前回の記録がありません`);
    else if (a.count !== b.count) reasons.push(`${t}: 件数が変わりました（${a.count} → ${b.count}）`);
    else if (a.hash !== b.hash) reasons.push(`${t}: 名前が変わりました`);
    else if (a.newest !== b.newest) reasons.push(`${t}: 更新日時が変わりました`);
  }
  if (aTypes.length) {
    const since = isoSec(new Date(Date.parse(state.lastFullSyncAt) - SKEW_MIN * 60000));
    try {
      const q = await sfJson(['data', 'query', '--query', `SELECT COUNT() FROM SetupAuditTrail WHERE CreatedDate > ${since}`, '--target-org', o.org]);
      const n = Number((q.result || {}).totalSize);
      if (!Number.isFinite(n)) throw new Error('履歴の件数を読めません');
      if (n > 0) reasons.push(`設定変更の履歴に ${n} 件の記録があります（${since} より後）`);
    } catch (e) {
      out.push('不明: 履歴の問い合わせに失敗しました: ' + e.message);
      save();
      return finish(11);
    }
  }
  if (reasons.length) { out.push('変更あり:'); for (const r of reasons.slice(0, 20)) out.push('  - ' + r); save(); return finish(10); }
  out.push('変更なし（区分 A の履歴・区分 B の一覧とも、前回から変わっていません）');
  return finish(0);
}

// ---- fingerprint: 一覧の指紋（設計 16 章の P1。影の比較: 取得は従来どおり行い、指紋との食い違いを記録する）----
const FP_VERSION = 1;
const FP_PARALLEL = 6;        // 一覧の問い合わせ（SOAP）の同時実行の上限
const FP_DROP_MIN = 4;        // 前回の件数がこれ以上のときだけ、件数の急減を疑う
const FP_DROP_RATIO = 0.5;    // 件数が前回の半分以下に減ったら、不審（不明に倒す）
const FP_DEFAULT_API = '64.0';
const FP_BATCH = 3;           // listMetadata は、1 回の呼び出しに、問い合わせを 3 つまで入れられる（公式の上限）
const FP_MAX_FOLDERS = 900;   // フォルダ型 1 種類あたりのフォルダ数の上限（超えたら、その回は不明。呼び出しは 300 回まで）
// 1 回の応答待ちと、全体の期限（超えたら不明。同期を、組織の不調で長く待たせないため）。環境変数は、テスト用
const FP_REQ_TIMEOUT_MS = Number(process.env.SF_METASYNC_FP_TIMEOUT_MS) || 30000;
const FP_DEADLINE_MS = Number(process.env.SF_METASYNC_FP_DEADLINE_MS) || 180000;
// 一覧の更新日時が、中身の変更に追従しない種類（Profile・PermissionSet は、別の部品（項目・オブジェクトなど）を足すと、
// 自分の更新日時が動かないまま、中身が変わる。実測 16.12）。影の比較で、見逃しと分けて数える
const FP_CONTEXT_TYPES = new Set(['Profile', 'PermissionSet', 'PermissionSetGroup', 'CustomObjectTranslation']);
const ABORTED = '(中止)';   // 別の種類が失敗したため、問い合わせを中止した印（失敗の一覧には出さない）
const FP_KEYS = new Set(['dir', 'folder', 'unfiled']);
// objects フォルダの下の、子の種類のフォルダ名 → 種類（影の比較で、計画の変更を、子の種類に結びつける）
const OBJECT_SUBDIR = { fields: 'CustomField', validationRules: 'ValidationRule', recordTypes: 'RecordType', listViews: 'ListView',
  webLinks: 'WebLink', fieldSets: 'FieldSet', compactLayouts: 'CompactLayout', businessProcesses: 'BusinessProcess' };

const xmlEsc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const xmlUnesc = s => String(s).replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
const xmlTag = (b, n) => { const m = new RegExp('<' + n + '>([^<]*)</' + n + '>').exec(b); return m ? xmlUnesc(m[1]) : ''; };

// 指紋を取る種類の表を読む（書式は config/metasync-fingerprint.txt の冒頭）。誤りは、中断する
function loadFpConfig(file) {
  const specs = [], seen = new Set();
  for (const line of readLines(file)) {
    const p = line.replace(/\s+#.*$/, '').split(/\s+/);
    const type = p[0];
    if (!/^[A-Za-z0-9_]+$/.test(type)) fail('--fp-config の種類名が正しくありません: ' + type);
    if (seen.has(type)) fail('--fp-config に、同じ種類が 2 回あります: ' + type);
    seen.add(type);
    const s = { type };
    for (const kv of p.slice(1)) {
      const m = /^([a-z]+)=(\S+)$/.exec(kv);
      if (!m || !FP_KEYS.has(m[1])) fail(`--fp-config の ${type} に、不明な指定があります: ${kv}`);
      s[m[1]] = m[2];
    }
    if (s.unfiled && !s.folder) fail(`--fp-config の ${type}: unfiled= は folder= と一緒に指定します。`);
    specs.push(s);
  }
  return specs;
}

function fpApiVersion(repo) {
  try {
    const j = JSON.parse(fs.readFileSync(path.join(repo, 'sfdx-project.json'), 'utf8'));
    const v = String(j.sourceApiVersion || '');
    if (/^\d+\.\d$/.test(v)) return v;
  } catch (e) { /* 読めなければ、既定 */ }
  return FP_DEFAULT_API;
}

// 接続情報（アクセストークン・インスタンス URL）。sf org display --json から読み、メモリだけに持つ（出力・ログには出さない）
//   現行の sf（2.x）は、org display のトークンを伏せ字（"[REDACTED] Use 'sf org auth show-access-token' to view"）で返すため、
//   そのときは、最初から sf org auth show-access-token で取る（伏せ字を SOAP に送らない）。本物のトークンが返る古い sf では、
//   それを使い、期限切れ（INVALID_SESSION_ID）のときだけ show-access-token で取り直して、1 回やり直す
//   （同時に失敗した問い合わせは、取り直しを共有する）
//   deadline: 全体の期限（エポックの ms）。sf の呼び出しも、残り時間（最低 1 秒）で待ちを打ち切る（Windows では、打ち切られた sf のプロセスが残ることがある。判定には影響しない）
async function orgCreds(org, deadline) {
  const left = () => Math.max(1000, deadline - Date.now());
  const r = (await sfJson(['org', 'display', '--target-org', org], left())).result || {};
  if (!r.accessToken || !r.instanceUrl) throw new Error('接続情報（アクセストークン・インスタンス URL）を取得できませんでした。');
  // トークンを送る先は、https だけ（テストのモックのため、手元の 127.0.0.1・localhost の http だけ例外）。リダイレクトも追わない（soapList）
  let u;
  try { u = new URL(String(r.instanceUrl)); } catch (e) { throw new Error('接続情報のインスタンス URL を読めません。'); }
  const local = u.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname);
  if (u.protocol !== 'https:' && !local) throw new Error('インスタンス URL が https ではないため、トークンを送りません。');
  const c = { token: String(r.accessToken), base: u.origin, refreshP: null, deadline };
  c.refresh = (stale) => {   // stale: 失敗した問い合わせが使ったトークン。すでに取り直されていれば、取り直さない。取り直しは 1 回だけ（共有する）
    if (c.token !== stale) return Promise.resolve(true);
    if (!c.refreshP) {
      c.refreshP = sfJson(['org', 'auth', 'show-access-token', '--target-org', org], left()).then(j => {
        const v = j.result;
        const t = typeof v === 'string' ? v : v && (v.accessToken || v.token);
        if (!t) return false;
        c.token = String(t);
        return true;
      }).catch(() => false);
    }
    return c.refreshP;
  };
  // 伏せ字（または、トークンの形でない値）は、送らずに、最初に取る。取れなければ、不明（SOAP は呼ばない）
  if (/^\[REDACTED|\s/.test(c.token)) {
    if (!(await c.refresh(c.token))) throw new Error('アクセストークンを取得できませんでした（sf org auth show-access-token が失敗しました）。');
    c.refreshP = null;   // この取得は、期限切れの取り直しに数えない（このあと期限切れになったら、もう 1 回取り直せる）
  }
  return c;
}

function limiter(n) {
  let active = 0;
  const q = [];
  const next = () => { while (active < n && q.length) { active++; q.shift()(); } };
  return fn => new Promise((resolve, reject) => {
    q.push(() => fn().then(resolve, reject).finally(() => { active--; next(); }));
    next();
  });
}

// 一覧 1 回（listMetadata）。queries = [{ type, folder? }]（3 つまで。結果は、まとめて 1 つの一覧）。
//   使えない種類（INVALID_TYPE）は { unavailable: true }。それ以外の失敗（応答が SOAP でない・全体の期限切れを含む）は、例外
async function soapList(c, api, queries) {
  if (typeof fetch !== 'function') throw new Error('この Node には fetch がありません（Node 18 以上が必要です）。');
  const where = queries.map(q => q.type + (q.folder ? ' / ' + q.folder : '')).join('、');
  const qxml = queries.map(q => `<met:queries>${q.folder ? `<met:folder>${xmlEsc(q.folder)}</met:folder>` : ''}<met:type>${xmlEsc(q.type)}</met:type></met:queries>`).join('');
  const mkBody = token => '<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">'
    + `<soapenv:Header><met:SessionHeader><met:sessionId>${xmlEsc(token)}</met:sessionId></met:SessionHeader></soapenv:Header>`
    + `<soapenv:Body><met:listMetadata>${qxml}<met:asOfVersion>${api}</met:asOfVersion></met:listMetadata></soapenv:Body></soapenv:Envelope>`;
  let res, text, usedToken, fault;
  for (let attempt = 1; ; attempt++) {
    if (c.deadline && Date.now() > c.deadline) throw new Error(`一覧の取得に失敗しました（${where}）: 時間切れ（全体で ${Math.round(FP_DEADLINE_MS / 1000)} 秒を超えました）`);
    try {
      usedToken = c.token;
      // redirect: 'error'（リダイレクトを追わない。307・308 は、POST の本文（トークン入り）を、転送先へ再送してしまうため）
      res = await fetch(`${c.base}/services/Soap/m/${api}`, { method: 'POST', redirect: 'error', headers: { 'Content-Type': 'text/xml; charset=UTF-8', SOAPAction: '""' }, body: mkBody(usedToken), signal: AbortSignal.timeout(FP_REQ_TIMEOUT_MS) });
      text = await res.text();
    } catch (e) {
      if (attempt >= 2 || c.aborted) throw new Error(`一覧の取得に失敗しました（${where}）: 接続エラー（${String(e.message || e).slice(0, 80)}）`);
      continue;
    }
    fault = /<faultstring>([^<]*)<\/faultstring>/.exec(text);
    // セッションが無効なら、トークンを取り直して、1 回だけやり直す
    if (fault && /INVALID_SESSION_ID/.test(fault[1]) && attempt < 2 && !c.aborted && c.refresh && await c.refresh(usedToken)) continue;
    break;
  }
  if (fault) {
    const msg = xmlUnesc(fault[1]);
    if (/INVALID_TYPE/.test(msg)) return { unavailable: true };
    throw new Error(`一覧の取得に失敗しました（${where}）: ${msg.split(usedToken).join('***').replace(/\s+/g, ' ').slice(0, 120)}`);
  }
  if (!res.ok) throw new Error(`一覧の取得に失敗しました（${where}）: HTTP ${res.status}`);
  // HTTP 200 でも、Metadata API の応答でない本文（メンテナンス画面・プロキシの HTML など）は、「0 件の一覧」にせず、失敗にする
  //   0 件の一覧は、自己終了タグ（<listMetadataResponse/>）で返る（実機で確認）ため、「/」も許す。名前空間の接頭辞付きも許す
  if (!/<(?:[A-Za-z0-9_]+:)?listMetadataResponse[\s>\/]/.test(text)) throw new Error(`一覧の取得に失敗しました（${where}）: 応答が、Metadata API の形ではありません`);
  const entries = (text.match(/<result>[\s\S]*?<\/result>/g) || []).map(r => ({
    fullName: xmlTag(r, 'fullName'), lastModifiedDate: xmlTag(r, 'lastModifiedDate'), manageableState: xmlTag(r, 'manageableState') }));
  return { entries };
}

// 一覧の項目から、指紋（件数・最新の更新日時・名前と更新日時のハッシュ）を作る。管理パッケージ本体の部品は除く。
//   epoch = 更新日時が、1970・0001 年のまま（または空）の件数（日時では、変更を見分けられない部品。影の比較の分類に使う。状態には入れない）
function fpSummarize(entries) {
  const mine = entries.filter(e => e.manageableState !== 'installed');
  const lines = mine.map(e => e.fullName + '|' + e.lastModifiedDate).sort();
  const newest = mine.map(e => e.lastModifiedDate).filter(Boolean).sort().pop() || '';
  const epoch = mine.filter(e => !e.lastModifiedDate || /^(1970|0001)-/.test(e.lastModifiedDate)).length;
  return { count: mine.length, newest, hash: sha(lines.join('\n')), epoch };
}

// 種類 1 つの指紋。フォルダ型は、フォルダを先に一覧し、フォルダごとに部品を一覧する（フォルダ自身と、中の部品を合わせる）
async function fpSnapshot(c, api, spec, run) {
  if (!spec.folder) {
    const r = await run(() => soapList(c, api, [{ type: spec.type }]));
    return r.unavailable ? { unavailable: true } : fpSummarize(r.entries);
  }
  const fl = await run(() => soapList(c, api, [{ type: spec.folder }]));
  if (fl.unavailable) return { unavailable: true };
  const names = [...new Set(fl.entries.map(e => e.fullName).concat(spec.unfiled ? [spec.unfiled] : []))];
  if (names.length > FP_MAX_FOLDERS) throw new Error(`フォルダが多すぎます（${names.length} 個。上限 ${FP_MAX_FOLDERS} 個）`);
  const chunks = [];
  for (let i = 0; i < names.length; i += FP_BATCH) chunks.push(names.slice(i, i + FP_BATCH));   // 3 つずつまとめて、呼び出しの回数を減らす
  const parts = await Promise.all(chunks.map(ch => run(() => soapList(c, api, ch.map(f => ({ type: spec.type, folder: f }))))));
  if (parts.some(p => p.unavailable)) return { unavailable: true };
  const byName = new Map();
  for (const e of fl.entries.concat(...parts.map(p => p.entries))) byName.set(e.fullName, e);   // 同じ名前は 1 件（unfiled が、フォルダの一覧にも現れることがある）
  return fpSummarize([...byName.values()]);
}

async function fingerprint(o) {
  const out = [];
  const finish = (code) => { process.stdout.write(out.join('\n') + '\n'); process.exitCode = code; };
  const writeReport = (rep) => { if (o.outReport) fs.writeFileSync(o.outReport, JSON.stringify(rep, null, 2) + '\n'); };
  const specs = loadFpConfig(o.fpConfig);
  if (!specs.length) fail('--fp-config に、種類がありません。');
  const api = o.repo ? fpApiVersion(o.repo) : FP_DEFAULT_API;
  const configHash = sha(api + '|' + specs.map(s => [s.type, s.folder || '', s.unfiled || ''].join(':')).sort().join(','));
  const now = o.now ? new Date(o.now) : new Date();
  if (isNaN(now.getTime())) fail('--now が日時として読めません: ' + o.now);

  // 前回の状態（読めない・版や設定が違う = 使えない）
  let state = null, stateWhy = '';
  if (!fs.existsSync(o.state)) stateWhy = '前回の指紋がありません';
  else {
    try {
      const s = JSON.parse(fs.readFileSync(o.state, 'utf8'));
      if (s && s.version === FP_VERSION && s.configHash === configHash && s.types && typeof s.types === 'object') state = s;
      else stateWhy = '前回の指紋の版または設定（種類の表・API バージョン）が、今回と合いません';
    } catch (e) { stateWhy = '前回の指紋を読めません'; }
  }

  let creds;
  try { creds = await orgCreds(o.org, Date.now() + FP_DEADLINE_MS); } catch (e) { out.push('[WARNING] 不明: ' + e.message); writeReport({ verdict: 11, types: {} }); return finish(11); }
  const t0 = Date.now();
  let calls = 0;
  const lim = limiter(FP_PARALLEL);
  // 1 種類でも失敗すれば、全体は不明（状態も書かない）。残りの問い合わせは、すぐ中止する（組織が応答しない回に、全種類ぶん待たない）
  let aborted = false, skipped = 0;   // skipped: 中止して、問い合わせなかった数
  //   旗は、失敗の発生元で立てる（待ち行列の次の 1 件が、旗が立つ前に出ないように）。creds.aborted は、実行中の問い合わせのやり直しも止める
  //   async: 同期の例外で、limiter の数え方が狂わないように
  const abort = () => { aborted = true; creds.aborted = true; };   // 待ち行列の中止と、実行中の要求のやり直しの中止
  const run = fn => lim(async () => {
    if (aborted) { skipped++; throw new Error(ABORTED); }
    calls++;
    try { return await fn(); } catch (e) { abort(); throw e; }
  });
  const snap = {}, failures = [];
  await Promise.all(specs.map(async s => { try { snap[s.type] = await fpSnapshot(creds, api, s, run); } catch (e) { abort(); if (e.message !== ABORTED) failures.push(`${s.type}: ${e.message}`); } }));
  const abortedNote = skipped ? '（同時に走っていた分だけの数。ほかの種類は、中止しました）' : '';
  const sec = ((Date.now() - t0) / 1000).toFixed(1);
  if (failures.length) {
    out.push(`[WARNING] 不明: 一覧の取得に失敗した種類があります（${failures.length} 種類${abortedNote}。状態は書きません）:`);
    for (const f of failures.slice(0, 5)) out.push('  - ' + f);
    writeReport({ verdict: 11, types: {} });
    return finish(11);
  }

  // 種類ごとの判定
  const types = {};
  for (const s of specs) {
    const b = snap[s.type], a = state && state.types[s.type];
    let status;
    if (!state) status = 'new';
    else if (b.unavailable) status = !a ? 'new' : a.unavailable ? 'unavailable' : 'changed';
    else if (!a) status = 'new';
    else if (a.unavailable) status = 'changed';
    else if (a.count >= FP_DROP_MIN && b.count <= a.count * FP_DROP_RATIO) status = 'suspect';
    else status = a.count !== b.count || a.hash !== b.hash ? 'changed' : 'unchanged';
    types[s.type] = { status, count: b.unavailable ? null : b.count, prevCount: a && !a.unavailable ? a.count : null, unavailable: !!b.unavailable,
      epoch: b.unavailable ? null : b.epoch };   // epoch: 影の比較用（状態ファイルには入れない）
  }
  const unavailable = specs.filter(s => snap[s.type].unavailable).map(s => s.type);
  out.push(`指紋: ${specs.length} 種類（使える ${specs.length - unavailable.length} / この組織では使えない ${unavailable.length}）・一覧の呼び出し ${calls} 回・${sec} 秒（API ${api}）`);

  const stat = k => specs.filter(s => types[s.type].status === k).map(s => s.type);
  let verdict;
  if (!state) { verdict = 11; out.push('不明: ' + stateWhy + '（全件取得で、指紋の基準を作ります）'); }
  else if (stat('suspect').length) {
    verdict = 11;
    out.push('[WARNING] 不明: 件数が前回の半分以下になった種類があります（一覧が欠けた可能性。全件取得に倒します）: '
      + stat('suspect').map(t => `${t}（${types[t].prevCount} → ${types[t].count}）`).join('、'));
  } else if (stat('changed').length || stat('new').length) {
    verdict = 10;
    out.push(`変更あり（指紋が前回と違う種類 ${stat('changed').length + stat('new').length} 個）:`);
    for (const t of stat('changed').concat(stat('new')).slice(0, 20)) out.push(`  - ${t}（件数 ${types[t].prevCount === null ? '-' : types[t].prevCount} → ${types[t].count === null ? '-' : types[t].count}）`);
  } else { verdict = 0; out.push('変更なし（すべての種類で、指紋が前回と同じです）'); }

  const next = { version: FP_VERSION, configHash, apiVersion: api, createdAt: isoSec(now), types: {} };
  for (const s of specs) { const b = snap[s.type]; next.types[s.type] = b.unavailable ? { unavailable: true } : { count: b.count, newest: b.newest, hash: b.hash }; }
  if (verdict !== 0) fs.writeFileSync(o.outState, JSON.stringify(next, null, 2) + '\n');
  writeReport({ verdict, apiVersion: api, types });
  return finish(verdict);
}

// ---- fpcompare: 影の比較（指紋の結果と、計画（実際の変更）を突き合わせる。情報のみ）----
function fpcompare(o) {
  const out = [];
  const done = () => { process.stdout.write(out.join('\n') + '\n'); process.exitCode = 0; };
  let rep;
  try { rep = JSON.parse(fs.readFileSync(o.report, 'utf8')); } catch (e) { out.push('指紋の影の比較: 指紋の結果を読めないため、比べません。'); return done(); }
  if (!rep || rep.verdict === 11 || !rep.types) { out.push('指紋の影の比較: 指紋が不明（全件取得に倒す回）のため、比べません。'); return done(); }
  const specs = loadFpConfig(o.fpConfig);
  const typeToFolder = new Map();
  for (const l of readLines(o.dirsTable)) { const p = l.replace(/\s+#.*$/, '').split(/\s+/); if (p.length >= 2) typeToFolder.set(p[0], p[1]); }
  const dirOf = s => s.dir || typeToFolder.get(s.type) || null;
  const moved = new Set(Object.keys(rep.types).filter(t => ['changed', 'new', 'suspect'].includes(rep.types[t].status)));

  // 計画の変更（A・M・D）を、グループ（フォルダ。objects は子の種類ごと）にまとめる
  const groups = new Map();   // キー → { files: [], types: [候補の種類] }
  for (const line of readLines0(o.plan)) {
    const [op, p] = line.split('\t');
    if (!['A', 'M', 'D'].includes(op)) continue;
    const m = /\/main\/default\/([^/]+)\/(.*)$/.exec(p);
    if (!m) continue;
    const folder = m[1], rest = m[2];
    let key = folder, cand;
    if (folder === 'objects') {
      const parts = rest.split('/');
      const type = parts.length >= 3 ? OBJECT_SUBDIR[parts[1]] || null : /\.object-meta\.xml$/.test(rest) ? 'CustomObject' : null;
      key = 'objects/' + (type || '(その他)');
      cand = type && specs.some(s => s.type === type) ? [type] : [];
    } else cand = specs.filter(s => dirOf(s) === folder).map(s => s.type);
    if (!groups.has(key)) groups.set(key, { files: [], types: cand });
    groups.get(key).files.push(op + ' ' + p);
  }
  // 日時では変更を見分けられない種類（Profile など。または、一覧の日時がすべて 1970 年のままの種類）。見逃しとは分けて数える
  const dateless = t => FP_CONTEXT_TYPES.has(t) || (rep.types[t] && rep.types[t].count > 0 && rep.types[t].epoch === rep.types[t].count);
  let hit = 0, miss = 0, outOfScope = 0, noDate = 0, filesHit = 0, filesMiss = 0, filesOut = 0, filesNoDate = 0;
  const missList = [], outList = [], noDateList = [], coveredTypes = new Set();
  for (const [key, g] of groups) {
    g.types.forEach(t => coveredTypes.add(t));
    if (!g.types.length) { outOfScope++; filesOut += g.files.length; outList.push(key); continue; }
    if (g.types.some(t => moved.has(t))) { hit++; filesHit += g.files.length; continue; }
    // 0 件の種類（同じフォルダの子の種類など）は、判定から外す（0 件の種類が混じるだけで、見逃しに数えられないように）
    //   使えない種類（この組織にない）も、同じく外す
    const active = g.types.filter(t => !(rep.types[t] && (rep.types[t].count === 0 || rep.types[t].unavailable)));
    if (active.length && active.every(dateless)) { noDate++; filesNoDate += g.files.length; noDateList.push(key); continue; }
    miss++; filesMiss += g.files.length; missList.push({ key, types: g.types, sample: g.files.slice(0, 3) });
  }
  const total = filesHit + filesMiss + filesOut + filesNoDate;
  if (!total) {
    out.push('指紋の影の比較: 実際の変更はありませんでした。');
  } else {
    out.push(`指紋の影の比較: 実際の変更 ${total} 件（${groups.size} グループ）— 検知できた ${hit}（${filesHit} 件）/ 見逃し ${miss}（${filesMiss} 件）/ 日時では検知できない種類 ${noDate}（${filesNoDate} 件）/ 指紋の対象外 ${outOfScope}（${filesOut} 件）`);
    for (const m of missList) {
      out.push(`[WARNING] 指紋の見逃し: ${m.key}（指紋の種類: ${m.types.join('・')}）。ファイルは変わったのに、指紋は動きませんでした。先頭: ${m.sample.join(' / ')}`);
    }
    if (noDateList.length) out.push(`  日時では検知できない種類（更新日時が動かない。別の仕組みで拾う必要がある）: ${noDateList.slice(0, 15).join('、')}${noDateList.length > 15 ? ' ほか' : ''}`);
    if (outList.length) out.push(`  指紋の対象外（毎日の全件取得で反映される）: ${outList.slice(0, 15).join('、')}${outList.length > 15 ? ' ほか' : ''}`);
  }
  const idle = [...moved].filter(t => !coveredTypes.has(t));
  if (idle.length) out.push(`指紋の空振り（指紋は変わったが、ファイルの変更はなかった種類）: ${idle.slice(0, 20).join('、')}${idle.length > 20 ? ' ほか' : ''}`);
  return done();
}

// ---- manifest: 追加の取得（現行の取得で取れていないもの）の package.xml を作る（設計 16.2・16.5.3。読み取りのみ）----
// StandardValueSet は、ワイルドカードも一覧（listMetadata）も 0 件のため、固定の名前で指定する（公式の一覧のうち、ふつうの組織にあるもの）。
//   組織にないものは、取得のときに「見つからない」という警告になる（readRetrieve の extra で無視する）
const STANDARD_VALUE_SETS = ['AccountContactMultiRoles', 'AccountContactRole', 'AccountOwnership', 'AccountRating', 'AccountType', 'AssetStatus',
  'CampaignMemberStatus', 'CampaignStatus', 'CampaignType', 'CaseContactRole', 'CaseOrigin', 'CasePriority', 'CaseReason', 'CaseStatus', 'CaseType',
  'ContactRole', 'ContractContactRole', 'ContractStatus', 'EntitlementType', 'EventSubject', 'EventType', 'IdeaCategory1', 'IdeaMultiCategory',
  'IdeaStatus', 'IdeaThemeStatus', 'Industry', 'InvoiceStatus', 'LeadSource', 'LeadStatus', 'OpportunityCompetitor', 'OpportunityStage',
  'OpportunityType', 'OrderStatus', 'OrderType', 'PartnerRole', 'Product2Family', 'QuestionOrigin1', 'QuickTextCategory', 'QuickTextChannel',
  'QuoteStatus', 'SalesTeamRole', 'Salutation', 'ServiceContractApprovalStatus', 'SolutionStatus', 'TaskPriority', 'TaskStatus', 'TaskSubject',
  'TaskType', 'WorkOrderLineItemStatus', 'WorkOrderPriority', 'WorkOrderStatus'];
const EXTRA_MODES = new Set(['list', 'stdobj', 'svs']);
const EXTRA_MAX_MEMBERS = 9000;   // 1 回の取得の上限（10,000 ファイル）に近い。超えたら、取得しない（不明）

// 追加の取得の表を読む。誤りは中断する
function loadExtraConfig(file) {
  const specs = [], seen = new Set();
  for (const line of readLines(file)) {
    const parts = line.replace(/\s+#.*$/, '').split(/\s+/);
    const type = parts[0];
    if (!/^[A-Za-z0-9_]+$/.test(type)) fail(`追加の取得の表の種類名が正しくありません: ${line}`);
    if (seen.has(type)) fail(`追加の取得の表に、同じ種類が 2 回あります: ${type}`);
    seen.add(type);
    const spec = { type, mode: 'list' };
    for (const kv of parts.slice(1)) {
      const m = /^(folder|unfiled|mode)=(\S+)$/.exec(kv);
      if (!m) fail(`追加の取得の表に、不明な指定があります: ${line}`);
      spec[m[1]] = m[2];
    }
    if (!EXTRA_MODES.has(spec.mode)) fail(`追加の取得の表の mode が正しくありません: ${line}`);
    if (spec.unfiled && !spec.folder) fail(`追加の取得の表で、unfiled= には folder= が要ります: ${line}`);
    if (spec.folder && !/^[A-Za-z0-9_]+$/.test(spec.folder)) fail(`追加の取得の表の folder= が正しくありません: ${line}`);
    specs.push(spec);
  }
  return specs;
}

// 標準オブジェクトの部品か（オブジェクト名に __ を含まない）。CustomField は、カスタム項目（__c で終わる）だけ
function isStdObjectMember(type, fullName) {
  const obj = String(fullName).split('.')[0];
  if (!obj || obj.includes('__') || !String(fullName).includes('.')) return false;
  return type !== 'CustomField' || /__c$/.test(fullName);
}

// 結果: 0 = package.xml を書いた ／ 12 = 取る部品がない（package.xml は書かない） ／ 11 = 不明（失敗・上限超え）
async function manifest(o) {
  const out = [];
  const finish = (code) => { process.stdout.write(out.join('\n') + '\n'); process.exitCode = code; };
  const specs = loadExtraConfig(o.extraConfig);
  if (!specs.length) fail('--extra-config に、種類がありません。');
  const api = o.repo ? fpApiVersion(o.repo) : FP_DEFAULT_API;
  let creds;
  try { creds = await orgCreds(o.org, Date.now() + FP_DEADLINE_MS); } catch (e) { out.push('[WARNING] 追加の取得: ' + e.message); return finish(11); }
  const lim = limiter(FP_PARALLEL);
  let aborted = false;
  const run = fn => lim(async () => {
    if (aborted) throw new Error(ABORTED);
    try { return await fn(); } catch (e) { aborted = true; creds.aborted = true; throw e; }
  });
  const members = new Map();   // 種類 → Set(名前)
  const add = (t, n) => { if (!members.has(t)) members.set(t, new Set()); members.get(t).add(n); };
  const mine = r => r.entries.filter(e => e.manageableState !== 'installed' && e.fullName);   // 管理パッケージ本体の部品は除く
  const failures = [];
  await Promise.all(specs.map(async s => {
    try {
      if (s.mode === 'svs') { for (const n of STANDARD_VALUE_SETS) add(s.type, n); return; }
      if (s.folder) {   // フォルダ型: フォルダを先に一覧し、フォルダごとに部品を一覧する（3 か所ずつまとめる）
        const fl = await run(() => soapList(creds, api, [{ type: s.folder }]));
        if (fl.unavailable) return;   // この組織にない種類は、取らない
        const folders = mine(fl).map(e => e.fullName);
        for (const f of folders) if (f !== s.unfiled) add(s.folder, f);   // フォルダ自身（unfiled$public は、実在のフォルダではない）
        const names = [...new Set(folders.concat(s.unfiled ? [s.unfiled] : []))];
        if (names.length > FP_MAX_FOLDERS) throw new Error(`フォルダが多すぎます（${names.length} 個。上限 ${FP_MAX_FOLDERS} 個）`);
        const chunks = [];
        for (let i = 0; i < names.length; i += FP_BATCH) chunks.push(names.slice(i, i + FP_BATCH));
        const parts = await Promise.all(chunks.map(ch => run(() => soapList(creds, api, ch.map(f => ({ type: s.type, folder: f }))))));
        if (parts.some(p => p.unavailable)) return;
        for (const p of parts) for (const e of mine(p)) add(s.type, e.fullName);
        return;
      }
      const r = await run(() => soapList(creds, api, [{ type: s.type }]));
      if (r.unavailable) return;
      for (const e of mine(r)) if (s.mode !== 'stdobj' || isStdObjectMember(s.type, e.fullName)) add(s.type, e.fullName);
    } catch (e) { aborted = true; creds.aborted = true; if (e.message !== ABORTED) failures.push(`${s.type}: ${e.message}`); }
  }));
  if (failures.length) {
    out.push(`[WARNING] 追加の取得: 一覧の取得に失敗した種類があります（${failures.length} 種類）:`);
    for (const f of failures.slice(0, 5)) out.push('  - ' + f);
    return finish(11);
  }
  let total = 0;
  const counts = [];
  for (const [t, set] of members) { total += set.size; counts.push(`${t} ${set.size}`); }
  out.push(`追加の取得: ${total} 部品（${counts.join('・') || 'なし'}。API ${api}）`);
  if (!total) return finish(12);
  if (total > EXTRA_MAX_MEMBERS) { out.push(`[WARNING] 追加の取得: 部品が多すぎます（${total} 件。上限 ${EXTRA_MAX_MEMBERS} 件）。今回は取りません`); return finish(11); }
  const xml = ['<?xml version="1.0" encoding="UTF-8"?>', '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'];
  for (const t of [...members.keys()].sort()) {
    xml.push('  <types>');
    for (const n of [...members.get(t)].sort()) xml.push(`    <members>${xmlEsc(n)}</members>`);
    xml.push(`    <name>${xmlEsc(t)}</name>`, '  </types>');
  }
  xml.push(`  <version>${api}</version>`, '</Package>');
  fs.writeFileSync(o.out, xml.join('\n') + '\n');
  return finish(0);
}

// ---- scan: 秘密情報の検査（設計 16.7。これから書く内容を、反映の前・コミットの前に調べる。読み取りのみ）----
const SCAN_MAX_BYTES = 20 * 1024 * 1024;   // これより大きいファイルは、検査しない（名前だけ出す）。バイナリは、秘密鍵と既知のトークンだけ探す
// 秘密らしい名前（項目名・ラベル名）。ただし、末尾が名前・ラベル・URL・日時・期限などのものは、秘密の入れ物ではない
const SECRET_NAME = /(secret|passw(?:or)?d|token|api[_-]?key|private[_-]?key|credential)/i;
const KEY_NAME = /(?:^|_)key(?:_|$)/i;   // Key という単語だけの名前（External_Key など、秘密でないものが多い）。値が 16 文字以上のときだけ疑う
// 名前の最後の「単語」（_ 区切り・小文字から大文字の境目で分ける）が、これらなら、秘密の入れ物ではない。末尾の文字列ではなく、単語で見る
//   （Api_Key_Android や Secret_Account は、末尾が id・count に当たるだけで、別の単語なので除外しない）
const BENIGN_LAST_WORDS = new Set(['name', 'label', 'url', 'uri', 'endpoint', 'lifetime', 'updated', 'date', 'time', 'type', 'id', 'sec', 'secs',
  'seconds', 'ms', 'count', 'length', 'policy', 'policies', 'enabled', 'required']);
function scanBenignName(name) {
  const words = String(name).replace(/__c$/i, '').split(/_+|(?<=[a-z0-9])(?=[A-Z])/).filter(Boolean);
  const last = (words[words.length - 1] || '').toLowerCase();
  return BENIGN_LAST_WORDS.has(last) || /^expir/.test(last);
}
// 値が入っていれば秘密の疑いがある XML の要素名（完全一致。passwordComplexity などは含まない。属性つきでもよい）
const XML_SECRET_TAGS = 'consumerSecret|clientSecret|sharedSecret|password|privateKey|secretKey|apiKey|accessToken|refreshToken|securityToken|token';
// 直書きの検査（コード）の対象のフォルダ。テストクラス（*Test.cls・*Tests.cls・*_test.cls・*_tests.cls）は、ダミーの値が多いため、この規則から外す
//   （Contest.cls のように、名前が test で終わるだけの本番クラスは、外さない）
const CODE_DIRS = /\/(classes|triggers|lwc|aura|pages|components)\//;
const TEST_CLASS = /(?:Test|Tests|_test|_tests)\.cls$/;
// 既知のトークンの形（AWS・GitHub・Slack・Slack の Webhook・Stripe・Google・JWT・Salesforce のセッション）
const KNOWN_TOKEN_RE = new RegExp([
  '\\bAKIA[0-9A-Z]{16}\\b',
  '\\bgh[pousr]_[A-Za-z0-9]{36,}\\b', '\\bgithub_pat_[A-Za-z0-9_]{22,}\\b',
  '\\bxox[abprs]-[A-Za-z0-9-]{10,}',
  'hooks\\.slack\\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+',
  '\\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\\b',
  '\\bAIza[0-9A-Za-z_-]{35}\\b',
  // JWT。先頭は、前が英数字・_・- でない位置だけ（\b だと、- の直後ごとに開始して、2 乗時間になる）
  '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}',
  '\\b00D[A-Za-z0-9]{12,15}![A-Za-z0-9._]{40,}',
].join('|'), 'g');
const PRIVATE_KEY_RE = /-----BEGIN (?:[A-Z]+ )*PRIVATE KEY(?: BLOCK)?-----/g;

// 既知のプレースホルダ・秘密でない値（Salesforce が伏せて返す Placeholder_…、* や x だけ、{!…}、${…}、<…>、真偽値など）
function scanIsPlaceholder(v) {
  const s = String(v).trim();
  return !s || /^placeholder_/i.test(s) || /^[*xX.\-_#]+$/.test(s) || /^(true|false|null|none)$/i.test(s)
    || /^\{!.*\}$/.test(s) || /^\$\{.*\}$/.test(s) || /^<.*>$/.test(s)
    || /redacted|changeme|change_me|your[_-]?(?:api|secret|token|password|key)/i.test(s);
}
// 値が、秘密らしいか（誤検知を減らす。名前・ラベル・URL・日付・数値・相対パス・日本語の文言は、秘密ではない）:
//   空白なし・ASCII だけ・8 文字以上・数字を含む・プレースホルダでない・API 名（__c など / c.… / Label.…）でない・認証情報のない URL でない・
//   数値だけ・日付や日時の形・/ で始まるパスでない。数字を含まない値（英字だけの長いパスワードなど）は、検出しない（既知の制約）
function scanLooksSecret(v) {
  const s = String(v).trim();
  if (!/^[\x21-\x7e]{8,}$/.test(s) || !/[0-9]/.test(s) || scanIsPlaceholder(s)) return false;
  if (/__(?:c|mdt|r|e|x)\b/.test(s) || /^(?:c|Label|\$Label)\./.test(s)) return false;
  if (/^[a-z][a-z0-9+.-]*:\/\/[^\/@\s]*(?:[\/?#]|$)/i.test(s)) return false;   // 認証情報（user:pass@）のない URL
  if (/^[0-9.,+-]+$/.test(s) || /^\d{4}-\d{2}-\d{2}/.test(s) || /^\/[\w.-]+(?:\/[\w.-]+)+\/?$/.test(s)) return false;   // 数値・日付・パス（/a/b）
  return true;
}
// 名前と値の組が、秘密らしいか。Key という単語だけの名前は、値が 16 文字以上のときだけ
function scanSecretPair(name, val) {
  if (scanBenignName(name)) return false;
  if (SECRET_NAME.test(name)) return scanLooksSecret(val);
  return KEY_NAME.test(name) && String(val).trim().length >= 16 && scanLooksSecret(val);
}
const matchAll = (re, text) => [...text.matchAll(re)];
// 規則の結果の 1 件: s = 一致した文字列（メモリの中だけ。出力しない）／ key = 秘密でない識別子（項目名・ラベル名・要素名・変数名。許可の一覧の絞り込みと、表示に使う）
//   key の制御文字（改行・タブなど）は空白にして、80 文字までにする（ログの行・報告の TSV・Slack の本文を、壊せないように）
const hit = (s, key) => ({ s, key: String(key || '').replace(/[\x00-\x1f\x7f\\]+/g, ' ').slice(0, 80) });
const isXml = p => /\.xml$/i.test(p);

// 規則。find(パス, 本文) は、疑わしいもの（hit）の配列を返す。本文は、XML では CDATA を外したもの（scanPrepare）。
//   XML の規則は、対象のファイルを限り（閉じタグのない巨大な入力で遅くならないよう、[^<]* だけを使う）、線形の時間で動く
const SCAN_RULES = [
  { id: 'xml-secret-element',
    find: (p, t) => !isXml(p) ? [] : matchAll(new RegExp(`<(${XML_SECRET_TAGS})(?:\\s[^<>]*)?>([^<]*)</\\1>`, 'gi'), t)
      .filter(m => !scanIsPlaceholder(m[2])).map(m => hit(m[0], m[1])) },
  { id: 'custommetadata-secret-field',   // CustomMetadata（*.md-meta.xml）と Flow（*.flow-meta.xml）の、項目名と値の組。文字列型だけ。{!…} を含む値は、動的な値
    find: (p, t) => {
      if (!/\.(?:md|flow)-meta\.xml$/i.test(p)) return [];
      const out = matchAll(/<field>([^<]*)<\/field>\s*<value([^>]*)>(?:\s*<stringValue>)?([^<]*)/g, t)
        .filter(m => !/xsi:type="xsd:(?!string)/.test(m[2]) && !m[3].includes('{!') && scanSecretPair(m[1], m[3])).map(m => hit(m[0], m[1]));
      if (/\.flow-meta\.xml$/i.test(p)) {   // Flow の定数・変数・入力パラメータ: <name>X</name> の後（0〜6 個の要素をはさんで）に、<value><stringValue>（代入要素 <assignToReference> は対象外）
        out.push(...matchAll(/<name>([^<]*)<\/name>(?:\s*<[A-Za-z]+>[^<]*<\/[A-Za-z]+>){0,6}\s*<value>\s*<stringValue>([^<]*)/g, t)
          .filter(m => !m[2].includes('{!') && scanSecretPair(m[1], m[2])).map(m => hit(m[0], m[1])));
      }
      return out;
    } },
  { id: 'customlabel-secret',   // カスタム表示ラベル（*.labels-meta.xml）。<labels> ごとに区切る（線形）
    find: (p, t) => !/\.labels-meta\.xml$/i.test(p) ? [] : t.split('<labels>').slice(1).map(part => part.split('</labels>')[0])
      .filter(b => scanSecretPair(xmlTag(b, 'fullName'), xmlTag(b, 'value'))).map(b => hit(b, xmlTag(b, 'fullName'))) },
  { id: 'private-key',
    find: (p, t) => matchAll(PRIVATE_KEY_RE, t).map(m => hit(m[0])) },
  { id: 'known-token',
    find: (p, t) => matchAll(KNOWN_TOKEN_RE, t).map(m => hit(m[0])) },
  { id: 'url-secret',   // URL の中の秘密（?client_secret=… / &password=… / user:pass@host / Bearer …）
    find: (p, t) => [
      ...matchAll(/[?&]((?:client_)?secret|password|passwd|access_token|refresh_token|api_?key|apikey|token)=([^&'"\s<>]{8,})/gi, t)
        .filter(m => scanLooksSecret(m[2])).map(m => hit(m[0], m[1].toLowerCase())),
      ...matchAll(/:\/\/[^\/\s:@'"<>]+:([^\/\s@'"<>]{3,})@/g, t).filter(m => !scanIsPlaceholder(m[1])).map(m => hit(m[0], 'userinfo')),
      ...matchAll(/\bBearer\s+([A-Za-z0-9._~+\/-]{20,})/g, t).filter(m => scanLooksSecret(m[1])).map(m => hit(m[0], 'bearer')),
    ] },
  { id: 'code-hardcoded-secret',   // 秘密らしい名前への、文字列リテラルの代入（連結・呼び出しを含む値は除く）
    find: (p, t) => (!CODE_DIRS.test('/' + p) || TEST_CLASS.test(p)) ? [] :
      matchAll(/['"]?\b(\w*(?:password|passwd|secret(?:_?key)?|api_?key|private_?key|access_?key|(?:access|auth|api|bearer|refresh|session)_?token))['"]?\s*(?::|=>|=)\s*(['"])([^'"\s()+]{8,})\2/gi, t)
        .filter(m => scanLooksSecret(m[3])).map(m => hit(m[0], m[1])) },
];
// バイナリは、秘密鍵と既知のトークンだけを探す
const SCAN_BINARY_RULES = SCAN_RULES.filter(r => r.id === 'private-key' || r.id === 'known-token');
// XML は、CDATA を外す（<![CDATA[x]]> → x）。値が CDATA に入っていても、検査できるように
//   閉じない <![CDATA[ が多くても遅くならないよう、<![CDATA[ で分けて、各部分で ]]> を探す（線形）
function stripCdata(t) {
  const parts = t.split('<![CDATA[');
  let out = parts[0];
  for (let i = 1; i < parts.length; i++) {
    const e = parts[i].indexOf(']]>');
    out += e < 0 ? '<![CDATA[' + parts[i] : parts[i].slice(0, e) + parts[i].slice(e + 3);
  }
  return out;
}
const scanPrepare = (p, t) => isXml(p) ? stripCdata(t) : t;

// 許可の一覧（--allow）の読み取り。1 行に「規則 パス [キー]」（規則は * で全部。パスは * を「任意の文字列」として使える。
//   パスに空白があるときは、* で書く。キーは、疑いの表示の「キー: …」（項目名・ラベル名・要素名・変数名）。省略すると、そのパスの規則すべて）。
//   なくてもよい。書式の誤り（語が 4 つ以上・不明な規則名）は、中断する（黙って別の意味にしない）
function loadScanAllow(file) {
  if (!file || !fs.existsSync(file)) return [];
  return readLines(file).map(l => {   // readLines は trim する（先頭の BOM も外れる）
    const w = l.split(/\s+/);
    if (w[0] !== '*' && w[0] !== 'scan-error' && !SCAN_RULES.some(r => r.id === w[0])) fail('--allow の規則名が正しくありません（* か scan-error か ' + SCAN_RULES.map(r => r.id).join(' / ') + '）: ' + l);
    if (w.length < 2 || w.length > 3) fail('--allow の形式が正しくありません（「規則 パス [キー]」。パスに空白があるときは * で書く）: ' + l);
    return { rule: w[0], key: w[2] || '', re: new RegExp('^' + w[1].replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$') };
  });
}

// ファイルの内容をテキストにする。戻り値: { text, mode } mode = 'text'（全部の規則）／ 'binary'（秘密鍵・既知のトークンだけ）／ 'skip'（20 MB 超: 検査しない）。
//   UTF-16（BOM つき）は、UTF-16 として読む（バイト数が奇数なら、末尾の 1 バイトを捨てる）
function scanDecode(buf) {
  if (buf.length > SCAN_MAX_BYTES) return { mode: 'skip', text: '' };
  if (buf.length >= 2 && ((buf[0] === 0xff && buf[1] === 0xfe) || (buf[0] === 0xfe && buf[1] === 0xff))) {
    const even = Buffer.from(buf.subarray(0, buf.length - (buf.length % 2)));
    return { mode: 'text', text: (buf[0] === 0xfe ? even.swap16() : even).subarray(2).toString('utf16le') };
  }
  if (buf.subarray(0, 8000).includes(0)) return { mode: 'binary', text: buf.toString('latin1') };
  return { mode: 'text', text: buf.toString('utf8') };
}

function scan(o) {
  const root = packageRoot(o.repo);
  const repoRoot = path.resolve(o.repo, root), fetchedRoot = path.resolve(o.fetched, root);
  const allow = loadScanAllow(o.allow);
  const rows = fs.readFileSync(o.plan, 'utf8').split('\n').filter(Boolean).map(l => l.split('\t')).filter(r => r[0] === 'A' || r[0] === 'M');
  let files = 0, allowed = 0;
  const found = [];        // { rule, path, key, count }
  const allowedBy = new Map();   // 許可で外した疑い（規則・パス・キーごとの件数。値が変わったことに気づけるよう、内訳を出す）
  const limited = [];      // 検査に制限があったファイル（バイナリ・20 MB 超）
  for (const [op, p] of rows) {
    const rel = p.slice(root.length + 1);
    const abs = path.resolve(o.repo, p);
    if (abs !== repoRoot && !abs.startsWith(repoRoot + path.sep)) fail('計画のパスが、同期の対象の外を指しています: ' + p);
    let cur;
    try { cur = scanDecode(fs.readFileSync(path.join(fetchedRoot, rel))); } catch (e) { fail('検査するファイルを読めません: ' + p); }
    files++;
    if (cur.mode !== 'text') limited.push(p + (cur.mode === 'skip' ? '（20 MB 超: 検査しない）' : '（バイナリ: 秘密鍵・既知のトークンだけ）'));
    if (cur.mode === 'skip') continue;
    // 変更（M）は、今のファイルにすでにある疑わしい文字列を除く（これまでにコミット済みのものは、今回の新しい疑いにしない）
    let oldText = '';
    if (op === 'M') { try { oldText = scanPrepare(p, scanDecode(fs.readFileSync(abs)).text); } catch (e) { oldText = ''; } }
    const text = scanPrepare(p, cur.text);
    for (const rule of (cur.mode === 'text' ? SCAN_RULES : SCAN_BINARY_RULES)) {
      // 手元（変更前）の側で失敗したら、空として扱う（今回の側の疑いを、すべて出す。安全側）
      let before = new Set();
      try { if (oldText) before = new Set(rule.find(p, oldText).map(h => h.s)); } catch (e) { if (!(e instanceof RangeError)) throw e; before = new Set(); }
      const byKey = new Map();
      let hits;
      try { hits = rule.find(p, text); } catch (e) {
        // 数 MB の連続した文字列などで、正規表現がスタックを溢れさせたとき（RangeError）は、検査全体を落とさず、「検査できなかった」ことを
        //   疑いの 1 件（規則 scan-error・キー = 落ちた規則名）にする。on では止まり（検査していないものを、黙って通さない）、
        //   管理者が確かめたら、許可の一覧の「scan-error パス」で外せる。それ以外の例外（実装の誤り）は、投げ直す
        if (!(e instanceof RangeError)) throw e;
        const k = rule.id;
        if (allow.some(a => (a.rule === '*' || a.rule === 'scan-error') && a.re.test(p) && (!a.key || a.key === k))) {
          allowed++;
          const ak = `scan-error ${p}（キー: ${k}）`;
          allowedBy.set(ak, (allowedBy.get(ak) || 0) + 1);
        } else found.push({ rule: 'scan-error', path: p, key: k, count: 1 });
        continue;
      }
      for (const h of hits) {
        if (before.has(h.s)) continue;
        if (allow.some(a => (a.rule === '*' || a.rule === rule.id) && a.re.test(p) && (!a.key || a.key === h.key))) {
          allowed++;
          const k = `${rule.id} ${p}${h.key ? `（キー: ${h.key}）` : ''}`;
          allowedBy.set(k, (allowedBy.get(k) || 0) + 1);
          continue;
        }
        byKey.set(h.key, (byKey.get(h.key) || 0) + 1);
      }
      for (const [key, count] of byKey) found.push({ rule: rule.id, path: p, key, count });
    }
  }
  const out = [];
  out.push(`秘密の検査: 対象 ${files} ファイル（追加・変更）／ 疑い ${found.length} 件（${new Set(found.map(f => f.path)).size} ファイル）／ 許可済み ${allowed} 件`);
  for (const f of found.slice(0, 50)) {
    if (f.rule === 'scan-error') out.push(`[WARNING] 検査できなかった規則: ${f.key} ${f.path}（scan-error。ファイルが大きすぎるなど。中身を確かめ、問題なければ許可の一覧に「scan-error パス ${f.key}」）`);
    else out.push(`[WARNING] 秘密の疑い: ${f.rule} ${f.path}${f.key ? `（キー: ${f.key}）` : ''}（${f.count} 件。値は表示しません）`);
  }
  if (found.length > 50) out.push(`[WARNING] 秘密の疑い: ほか ${found.length - 50} 件`);
  for (const [k, n] of [...allowedBy].slice(0, 20)) out.push(k.startsWith('scan-error ') ? `  許可済み: ${k}（この規則は、このファイルを検査していない）` : `  許可済み: ${k}（${n} 件。許可は、そのキーの以後の値もすべて通す）`);
  if (limited.length) out.push(`検査に制限があるファイル ${limited.length} 個（先頭 10 個）: ${limited.slice(0, 10).join('、')}`);
  process.stdout.write(out.join('\n') + '\n');
  if (o.outReport) fs.writeFileSync(o.outReport, found.map(f => `${f.rule}\t${f.path}\t${f.count}\t${f.key}`).join('\n') + (found.length ? '\n' : ''));
  process.exitCode = found.length ? 10 : 0;
}

const o = parseArgs(process.argv.slice(2));
if (o.cmd === 'plan') plan(o);
else if (o.cmd === 'root') rootCmd(o);
else if (o.cmd === 'detect') detect(o).catch(e => { process.stderr.write('[ERROR] ' + e.message + '\n'); process.exitCode = 11; });
else if (o.cmd === 'fingerprint') fingerprint(o).catch(e => { process.stderr.write('[ERROR] ' + e.message + '\n'); process.exitCode = 11; });
else if (o.cmd === 'fpcompare') fpcompare(o);
else if (o.cmd === 'scan') scan(o);
else if (o.cmd === 'manifest') manifest(o).catch(e => { process.stderr.write('[ERROR] ' + e.message + '\n'); process.exitCode = 11; });
else apply(o);
