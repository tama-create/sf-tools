'use strict';
// ==============================================================================
// typecheck.js - メタデータの種類ごとの「リリース・削除」の可否を、実際の組織で確かめる（bin/sf-typecheck.sh から呼ぶ）
// ==============================================================================
// 種類ごとの最小のサンプル（XML など）を、使い捨てのプロジェクトに作り、実際に、リリース → 削除して、結果を表にする。
// Node の標準ライブラリだけを使う（追加パッケージなし。sf CLI が npm 版のため、Node は前提）。
// 境界は、この 1 ファイルだけ。シェル側（bin/sf-typecheck.sh）が、警告・確認・接続先の組織の種類の確認を行う。
//
// 【使い方】
//   node lib/typecheck.js --list
//   node lib/typecheck.js --org ALIAS --work DIR [--mode full|validate] [--only 種類,種類] [--out FILE]
//
// 【オプション】
//   --org ALIAS      : 接続先（--list 以外では必須）
//   --work DIR       : 種類ごとのプロジェクトを作るフォルダ（--list 以外では必須）。DIR/<種類>/ を、毎回、作り直す
//   --mode full      : 実際にリリースして、削除する（既定）
//   --mode validate  : 検証（sf project deploy validate）だけ。削除はしない（delete の列は unknown）
//   --only A,B       : サンプルの種類名（--list の名前）と完全一致するものだけ確認する。一致しない名前は無視する
//   --out FILE       : 結果の TSV の出力先（すべての種類を処理し終えたときだけ書く。上書き）
//   --list           : サンプルの種類の一覧（定義の順）を出して、終了する（ほかの引数の検査（下）は、先に行う）
//   上記以外の引数・値のないオプション・--mode の full / validate 以外の値・予約名の --org は、--list があっても、
//   エラー（終了コード 1）
//
// 【処理の流れ】（種類ごと。定義の順）
//   1. DIR/<種類>/ に sfdx-project.json と force-app/main/default/ 以下のファイルを書く（1 ファイルずつ、書く前に、
//      安全の確認（下の【補足】）をする）。続けて、削除するメンバー名を確認する。安全の条件を満たさなければ、その時点で
//      全体を中断する
//   2. sf project deploy start（validate モードは validate）--source-dir force-app --wait 30 でリリースする。
//      Apex を含むサンプルは --test-level RunSpecifiedTests --tests <テストクラス>
//   3. full モードで、リリースが成功したときだけ、削除する。削除の対象（del）を null で段階に分け、段階ごとに、
//      空の package.xml と destructiveChanges.xml で sf project deploy start --pre-destructive-changes を実行する。
//      応答に already in progress を含む失敗は、30 秒おきに最大 8 回やり直す。ある段階が失敗したら、
//      delete = ng として、残りの段階は実行しない（サンプルが組織に残る）
//   4. covers（同じサンプルで確認できる別の種類）があれば、同じ結果の行を追加する
//
// 【補足】
//   ・出力: 標準出力に、進行と結果の一覧。--out があれば、結果を TSV（見出し行なし）で書く:
//     種類<TAB>release<TAB>delete<TAB>備考。release / delete: ok | ng | unknown
//     （unknown = 実行していない: validate モードの delete・release が ng のときの delete）。
//     組織の機能の不足による失敗も ng になる（理由は備考に出る）
//   ・終了コード: 0 = release・delete に ng がない（--list も 0）/ 3 = ng がある / 1 = 中断（引数の誤り・安全の確認・
//     その他の例外。メッセージは標準エラーに [ERROR] で出す）
//   ・安全: 実行する sf のコマンドは、project deploy start / project deploy validate だけ（それ以外は、例外で中断する）
//   ・安全: 書くファイルは、パスに SfToolsE2eMin を含むもの（ownsBody・sharedFile のサンプルは、中身に含むものも可）、
//     削除するメンバー名は、SfToolsE2eMin を含むものだけ。大文字・小文字を区別する。満たさなければ、全体を中断する
//     （それまでに処理した種類のリリース・削除は、実行済みのまま。--out は書かない）。
//     LWC のコンポーネント名は先頭が小文字でなければならないため、先頭を小文字にした sfToolsE2eMin も、含むものとして認める
//     （認めるのは、この 2 通りの綴りだけ。それ以外の大文字・小文字の違いは、認めない）
//   ・安全: 接続先が、共有環境の予約名（prod / staging / develop / main）なら、中断する
//   ・カスタムオブジェクト（__c・__mdt・__e）は、削除後 15 日間、名前が予約されるため、名前に、実行時の日時（月日時分）を入れる
//   ・成否: sf の --json の応答で、status が 0、かつ result.success が false でなければ ok。応答を JSON として読めなければ ng
//   ・環境変数 SF_TYPECHECK_CMD: 起動するコマンドを sf から差し替える（テストで、モックの sf を使うため）
// ==============================================================================
const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const API = '64.0';
const P = 'SfToolsE2eMin';
const PL = P.charAt(0).toLowerCase() + P.slice(1);   // LWC のコンポーネント名は、先頭が小文字でなければならないため、この形だけも安全な名前として扱う
const hasP = (x) => x.includes(P) || x.includes(PL);  // 安全の確認: 名前にテスト用の接頭辞を含む（大文字・小文字は区別する。許すのは P と PL の 2 通りだけ）
const RESERVED = ['prod', 'staging', 'develop', 'main'];
const NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"';
const HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n';
const pad = (n) => String(n).padStart(2, '0');
const d0 = new Date();
const STAMP = pad(d0.getMonth() + 1) + pad(d0.getDate()) + pad(d0.getHours()) + pad(d0.getMinutes());

// 引数の解析。値を取るオプション（--org / --work / --mode / --only / --out）に、値がない（末尾・次が -- で始まる）ときは、エラー
function parseArgs(argv) {
    const o = { mode: 'full' };
    const val = (i) => {
        const v = argv[i + 1];
        if (v === undefined || v.startsWith('--')) throw new Error(argv[i] + ' の値がありません');
        return v;
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--org') o.org = val(i++);
        else if (a === '--work') o.work = val(i++);
        else if (a === '--mode') o.mode = val(i++);
        else if (a === '--only') o.only = val(i++).split(',').filter(Boolean);
        else if (a === '--out') o.out = val(i++);
        else if (a === '--list') o.list = true;
        else throw new Error('不明なオプション: ' + a);
    }
    return o;
}

const xml = (root, body) => `${HEAD}<${root} ${NS}>\n${body}\n</${root}>\n`;
const apexMeta = (root) => xml(root, `    <apiVersion>${API}</apiVersion>\n    <status>Active</status>`);

// ---- サンプルの定義 ----
// files: { 相対パス（force-app/main/default からの）: 本文 }
// del  : [[種類, メンバー名], ...]（削除の順。子 → 親）。null は段階の区切り（前の段階の削除が終わってから、次を削除する）
// extra（add の 4 つ目の引数。省略可）:
//   tests: Apex を含むときの、テストクラス（RunSpecifiedTests）
//   covers（同じ結果の行を追加する別の種類）・notes（備考）・ownsBody / sharedFile（パスに SfToolsE2eMin を
//   含まないファイルを、中身に含めば書いてよい）
const O = P + STAMP + 'Obj';      // カスタムオブジェクト（実行ごとの別名）
const M = P + STAMP + 'Mdt';      // カスタムメタデータ型（実行ごとの別名）
const S = [];
const add = (type, files, del, extra) => S.push(Object.assign({ type, files, del }, extra || {}));

add('ApexClass', {
    [`classes/${P}Cls.cls`]: `public with sharing class ${P}Cls {\n    public static String hello() { return 'Hello'; }\n}\n`,
    [`classes/${P}Cls.cls-meta.xml`]: apexMeta('ApexClass'),
    [`classes/${P}ClsTest.cls`]: `@isTest\nprivate class ${P}ClsTest {\n    @isTest static void t() { System.assertEquals('Hello', ${P}Cls.hello()); }\n}\n`,
    [`classes/${P}ClsTest.cls-meta.xml`]: apexMeta('ApexClass'),
}, [['ApexClass', P + 'ClsTest'], ['ApexClass', P + 'Cls']], { tests: [P + 'ClsTest'] });
add('ApexTestSuite', {
    [`classes/${P}SuiteCls.cls`]: `public with sharing class ${P}SuiteCls {\n    public static String hello() { return 'Hello'; }\n}\n`,
    [`classes/${P}SuiteCls.cls-meta.xml`]: apexMeta('ApexClass'),
    [`classes/${P}SuiteClsTest.cls`]: `@isTest\nprivate class ${P}SuiteClsTest {\n    @isTest static void t() { System.assertEquals('Hello', ${P}SuiteCls.hello()); }\n}\n`,
    [`classes/${P}SuiteClsTest.cls-meta.xml`]: apexMeta('ApexClass'),
    [`testSuites/${P}Suite.testSuite-meta.xml`]: xml('ApexTestSuite', `    <testClassName>${P}SuiteClsTest</testClassName>`),
}, [['ApexTestSuite', P + 'Suite'], ['ApexClass', P + 'SuiteClsTest'], ['ApexClass', P + 'SuiteCls']], { tests: [P + 'SuiteClsTest'] });
add('ApexTrigger', {
    [`triggers/${P}Trg.trigger`]: `trigger ${P}Trg on Account (before insert) {\n    for (Account a : Trigger.new) { System.debug(a.Name); }\n}\n`,
    [`triggers/${P}Trg.trigger-meta.xml`]: apexMeta('ApexTrigger'),
    [`classes/${P}TrgTest.cls`]: `@isTest\nprivate class ${P}TrgTest {\n    @isTest static void t() { insert new Account(Name = 'x'); }\n}\n`,
    [`classes/${P}TrgTest.cls-meta.xml`]: apexMeta('ApexClass'),
}, [['ApexTrigger', P + 'Trg'], ['ApexClass', P + 'TrgTest']], { tests: [P + 'TrgTest'] });
add('ApexPage', {
    [`pages/${P}Page.page`]: '<apex:page><h1>Hello, World!</h1></apex:page>\n',
    [`pages/${P}Page.page-meta.xml`]: xml('ApexPage', `    <apiVersion>${API}</apiVersion>\n    <label>${P}Page</label>`),
}, [['ApexPage', P + 'Page']]);
add('ApexComponent', {
    [`components/${P}Comp.component`]: '<apex:component><p>Hello</p></apex:component>\n',
    [`components/${P}Comp.component-meta.xml`]: xml('ApexComponent', `    <apiVersion>${API}</apiVersion>\n    <label>${P}Comp</label>`),
}, [['ApexComponent', P + 'Comp']]);
add('LightningComponentBundle', {
    [`lwc/${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc/${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc.html`]: '<template><p>Hello</p></template>\n',
    [`lwc/${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc/${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc.js`]: "import { LightningElement } from 'lwc';\nexport default class Hello extends LightningElement {}\n",
    [`lwc/${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc/${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc.js-meta.xml`]:
        xml('LightningComponentBundle', `    <apiVersion>${API}</apiVersion>\n    <isExposed>false</isExposed>`),
}, [['LightningComponentBundle', `${P.charAt(0).toLowerCase()}${P.slice(1)}Lwc`]]);
add('AuraDefinitionBundle', {
    [`aura/${P}Aura/${P}Aura.cmp`]: '<aura:component><p>Hello</p></aura:component>\n',
    [`aura/${P}Aura/${P}Aura.cmp-meta.xml`]: xml('AuraDefinitionBundle', `    <apiVersion>${API}</apiVersion>\n    <description>${P}</description>`),
}, [['AuraDefinitionBundle', P + 'Aura']]);
add('CustomPermission', {
    [`customPermissions/${P}Perm.customPermission-meta.xml`]: xml('CustomPermission', `    <isLicensed>false</isLicensed>\n    <label>${P}Perm</label>`),
}, [['CustomPermission', P + 'Perm']]);
add('PermissionSetGroup', {
    [`permissionsets/${P}Ps.permissionset-meta.xml`]: xml('PermissionSet', `    <hasActivationRequired>false</hasActivationRequired>\n    <label>${P}Ps</label>`),
    [`permissionsetgroups/${P}Psg.permissionsetgroup-meta.xml`]: xml('PermissionSetGroup',
        `    <description>sf-tools</description>\n    <label>${P}Psg</label>\n    <permissionSets>${P}Ps</permissionSets>\n    <status>Updated</status>`),
}, [['PermissionSetGroup', P + 'Psg'], ['PermissionSet', P + 'Ps']]);
add('RemoteSiteSetting', {
    [`remoteSiteSettings/${P}Site.remoteSite-meta.xml`]: xml('RemoteSiteSetting',
        '    <disableProtocolSecurity>false</disableProtocolSecurity>\n    <isActive>true</isActive>\n    <url>https://example.com</url>'),
}, [['RemoteSiteSetting', P + 'Site']]);
add('CspTrustedSite', {
    [`cspTrustedSites/${P}Csp.cspTrustedSite-meta.xml`]: xml('CspTrustedSite',
        '    <context>All</context>\n    <endpointUrl>https://example.com</endpointUrl>\n    <isActive>true</isActive>\n' +
        '    <isApplicableToConnectSrc>true</isApplicableToConnectSrc>\n    <isApplicableToFontSrc>false</isApplicableToFontSrc>\n' +
        '    <isApplicableToFrameSrc>false</isApplicableToFrameSrc>\n    <isApplicableToImgSrc>false</isApplicableToImgSrc>\n' +
        '    <isApplicableToMediaSrc>false</isApplicableToMediaSrc>\n    <isApplicableToStyleSrc>false</isApplicableToStyleSrc>'),
}, [['CspTrustedSite', P + 'Csp']]);
add('CorsWhitelistOrigin', {
    [`corsWhitelistOrigins/${P}Cors.corsWhitelistOrigin-meta.xml`]: xml('CorsWhitelistOrigin', '    <urlPattern>https://example.com</urlPattern>'),
}, [['CorsWhitelistOrigin', P + 'Cors']]);
add('Queue', {
    [`queues/${P}Queue.queue-meta.xml`]: xml('Queue',
        `    <doesSendEmailToMembers>false</doesSendEmailToMembers>\n    <name>${P}Queue</name>\n    <queueSobject>\n        <sobjectType>Case</sobjectType>\n    </queueSobject>`),
}, [['Queue', P + 'Queue']]);
add('ExternalDataSource', {
    [`dataSources/${P}Ds.dataSource-meta.xml`]: xml('ExternalDataSource',
        `    <endpoint>https://example.com/odata</endpoint>\n    <isWritable>false</isWritable>\n    <label>${P}Ds</label>\n` +
        '    <principalType>Anonymous</principalType>\n    <protocol>NoAuthentication</protocol>\n    <type>OData</type>'),
}, [['ExternalDataSource', P + 'Ds']]);
add('NamedCredential', {
    [`namedCredentials/${P}Nc.namedCredential-meta.xml`]: xml('NamedCredential',
        `    <endpoint>https://example.com</endpoint>\n    <label>${P}Nc</label>\n    <namedCredentialType>Legacy</namedCredentialType>\n` +
        '    <principalType>Anonymous</principalType>\n    <protocol>NoAuthentication</protocol>'),
}, [['NamedCredential', P + 'Nc']]);
add('GlobalValueSet', {
    [`globalValueSets/${P}Gvs.globalValueSet-meta.xml`]: xml('GlobalValueSet',
        `    <masterLabel>${P}Gvs</masterLabel>\n    <sorted>false</sorted>\n    <customValue>\n        <fullName>A</fullName>\n        <default>false</default>\n        <label>A</label>\n    </customValue>`),
}, [['GlobalValueSet', P + 'Gvs']]);
add('LightningMessageChannel', {
    [`messageChannels/${P}Chan.messageChannel-meta.xml`]: xml('LightningMessageChannel',
        `    <description>sf-tools</description>\n    <isExposed>false</isExposed>\n    <masterLabel>${P}Chan</masterLabel>`),
}, [['LightningMessageChannel', P + 'Chan']]);
add('PlatformEventChannel', {
    [`platformEventChannels/${P}Ch__chn.platformEventChannel-meta.xml`]: xml('PlatformEventChannel',
        `    <channelType>event</channelType>\n    <label>${P}Ch</label>`),
}, [['PlatformEventChannel', P + 'Ch__chn']]);
add('SynonymDictionary', {
    [`synonymDictionaries/${P}Syn.synonymDictionary-meta.xml`]: xml('SynonymDictionary',
        `    <groups>\n        <languages>en_US</languages>\n        <terms>hello</terms>\n        <terms>hi</terms>\n    </groups>\n    <isProtected>false</isProtected>\n    <label>${P}Syn</label>`),
}, [['SynonymDictionary', P + 'Syn']]);
add('CustomTab', {
    [`tabs/${P}Tab.tab-meta.xml`]: xml('CustomTab',
        `    <customObject>false</customObject>\n    <frameHeight>600</frameHeight>\n    <label>${P}Tab</label>\n    <motif>Custom1: Heart</motif>\n    <url>https://example.com</url>\n    <urlEncodingKey>UTF-8</urlEncodingKey>`),
}, [['CustomTab', P + 'Tab']]);
add('HomePageComponent', {
    [`homePageComponents/${P}Hpc.homePageComponent-meta.xml`]: xml('HomePageComponent',
        '    <body>hello</body>\n    <pageComponentType>htmlArea</pageComponentType>\n    <width>narrow</width>'),
}, [['HomePageComponent', P + 'Hpc']]);
add('HomePageLayout', {
    [`homePageLayouts/${P}Home.homePageLayout-meta.xml`]: xml('HomePageLayout', '    <narrowComponents>standard-CreateNew</narrowComponents>\n    <wideComponents>standard-Tasks</wideComponents>'),
}, [['HomePageLayout', P + 'Home']]);
add('Letterhead', {
    [`letterhead/${P}Lh.letter-meta.xml`]: xml('Letterhead',
        '    <available>true</available>\n    <backgroundColor>#FFFFFF</backgroundColor>\n    <bodyColor>#FFFFFF</bodyColor>\n' +
        '    <bottomLine>\n        <color>#000000</color>\n        <height>1</height>\n    </bottomLine>\n' +
        '    <footer>\n        <backgroundColor>#FFFFFF</backgroundColor>\n        <height>20</height>\n        <horizontalAlignment>Left</horizontalAlignment>\n        <verticalAlignment>Top</verticalAlignment>\n    </footer>\n' +
        '    <header>\n        <backgroundColor>#FFFFFF</backgroundColor>\n        <height>20</height>\n        <horizontalAlignment>Left</horizontalAlignment>\n        <verticalAlignment>Top</verticalAlignment>\n    </header>\n' +
        `    <middleLine>\n        <color>#000000</color>\n        <height>1</height>\n    </middleLine>\n    <name>${P}Lh</name>\n    <topLine>\n        <color>#000000</color>\n        <height>1</height>\n    </topLine>`),
}, [['Letterhead', P + 'Lh']]);
add('ReportType', {
    [`reportTypes/${P}Rt.reportType-meta.xml`]: xml('ReportType',
        `    <baseObject>Account</baseObject>\n    <category>accounts</category>\n    <deployed>true</deployed>\n    <description>sf-tools</description>\n    <label>${P}Rt</label>\n` +
        '    <sections>\n        <columns>\n            <field>Name</field>\n            <table>Account</table>\n        </columns>\n        <masterLabel>Account</masterLabel>\n    </sections>'),
}, [['ReportType', P + 'Rt']]);
add('Report', {
    [`reports/${P}Rf.reportFolder-meta.xml`]: xml('ReportFolder', `    <accessType>Hidden</accessType>\n    <name>${P}Rf</name>`),
    [`reports/${P}Rf/${P}Rep.report-meta.xml`]: xml('Report',
        `    <columns>\n        <field>ACCOUNT.NAME</field>\n    </columns>\n    <format>Tabular</format>\n    <name>${P}Rep</name>\n    <reportType>AccountList</reportType>\n    <scope>organization</scope>\n    <showDetails>true</showDetails>`),
}, [['Report', `${P}Rf/${P}Rep`], ['ReportFolder', P + 'Rf']], { covers: ['ReportFolder'] });
add('Document', {
    [`documents/${P}Df.documentFolder-meta.xml`]: xml('DocumentFolder',
        `    <accessType>Hidden</accessType>\n    <name>${P}Df</name>\n    <publicFolderAccess>ReadOnly</publicFolderAccess>`),
    [`documents/${P}Df/${P}Doc.txt`]: 'hello\n',
    [`documents/${P}Df/${P}Doc.document-meta.xml`]: xml('Document', `    <internalUseOnly>false</internalUseOnly>\n    <name>${P}Doc</name>\n    <public>false</public>`),
}, [['Document', `${P}Df/${P}Doc`], ['DocumentFolder', P + 'Df']], { covers: ['DocumentFolder'] });
add('EmailTemplate', {
    [`email/unfiled$public/${P}Tpl.email`]: 'Hello, World!\n',
    [`email/unfiled$public/${P}Tpl.email-meta.xml`]: xml('EmailTemplate',
        `    <available>true</available>\n    <description>${P}</description>\n    <encodingKey>UTF-8</encodingKey>\n    <name>${P}Tpl</name>\n` +
        `    <style>none</style>\n    <subject>${P}</subject>\n    <type>text</type>\n    <uiType>Aloha</uiType>`),
}, [['EmailTemplate', `unfiled$public/${P}Tpl`]]);
add('CustomLabel', {
    'labels/CustomLabels.labels-meta.xml': xml('CustomLabels',
        `    <labels>\n        <fullName>${P}Label</fullName>\n        <language>en_US</language>\n        <protected>false</protected>\n        <shortDescription>${P}</shortDescription>\n        <value>Hello</value>\n    </labels>`),
}, [['CustomLabel', P + 'Label']], { ownsBody: true });
add('CustomObject', {   // 親（＋項目・Layout）。名前は、実行ごとの別名（削除後、15 日間、名前が予約されるため）
    [`objects/${O}__c/${O}__c.object-meta.xml`]: xml('CustomObject',
        `    <deploymentStatus>Deployed</deploymentStatus>\n    <label>${O}</label>\n    <nameField>\n        <label>Name</label>\n        <type>Text</type>\n    </nameField>\n` +
        `    <pluralLabel>${O}s</pluralLabel>\n    <sharingModel>ReadWrite</sharingModel>`),
    [`objects/${O}__c/fields/Note__c.field-meta.xml`]: xml('CustomField',
        '    <fullName>Note__c</fullName>\n    <label>Note</label>\n    <length>80</length>\n    <required>false</required>\n    <type>Text</type>\n    <unique>false</unique>'),
    [`layouts/${O}__c-${O} Layout.layout-meta.xml`]: xml('Layout',
        '    <layoutSections>\n        <customLabel>false</customLabel>\n        <detailHeading>false</detailHeading>\n        <editHeading>true</editHeading>\n' +
        '        <label>Information</label>\n        <layoutColumns>\n            <layoutItems>\n                <behavior>Required</behavior>\n                <field>Name</field>\n' +
        '            </layoutItems>\n        </layoutColumns>\n        <style>OneColumn</style>\n    </layoutSections>'),
}, [['CustomField', `${O}__c.Note__c`], ['CustomObject', `${O}__c`]], { notes: 'カスタムオブジェクトは、削除後 15 日間、名前が予約される' });
add('CustomMetadata', {
    [`objects/${M}__mdt/${M}__mdt.object-meta.xml`]: xml('CustomObject',
        `    <label>${M}</label>\n    <pluralLabel>${M}s</pluralLabel>\n    <visibility>Public</visibility>`),
    [`customMetadata/${M}.${P}Rec.md-meta.xml`]: xml('CustomMetadata', `    <label>${P}Rec</label>\n    <protected>false</protected>`),
}, [['CustomMetadata', `${M}.${P}Rec`], ['CustomObject', `${M}__mdt`]]);
add('MilestoneType', {
    [`milestoneTypes/${P}Mile.milestoneType-meta.xml`]: xml('MilestoneType', '    <recurrenceType>none</recurrenceType>'),
}, [['MilestoneType', P + 'Mile']]);
add('CustomNotificationType', {
    [`notificationtypes/${P}Notif.notiftype-meta.xml`]: xml('CustomNotificationType',
        `    <customNotifTypeName>${P}Notif</customNotifTypeName>\n    <desktop>true</desktop>\n    <masterLabel>${P}Notif</masterLabel>\n    <mobile>false</mobile>\n    <slack>false</slack>`),
}, [['CustomNotificationType', P + 'Notif']]);
add('Workflow', {   // Account に、ルール 1 つと項目自動更新 1 つを追加する（既存のものには、触れない）
    'workflows/Account.workflow-meta.xml': xml('Workflow',
        `    <fieldUpdates>\n        <fullName>${P}Fu</fullName>\n        <field>Description</field>\n        <formula>"x"</formula>\n        <name>${P}Fu</name>\n` +
        '        <notifyAssignee>false</notifyAssignee>\n        <operation>Formula</operation>\n        <protected>false</protected>\n        <reevaluateOnChange>false</reevaluateOnChange>\n    </fieldUpdates>\n' +
        `    <rules>\n        <fullName>${P}Wr</fullName>\n        <actions>\n            <name>${P}Fu</name>\n            <type>FieldUpdate</type>\n        </actions>\n        <active>false</active>\n` +
        '        <criteriaItems>\n            <field>Account.Name</field>\n            <operation>notEqual</operation>\n            <value>zzz</value>\n        </criteriaItems>\n' +
        '        <triggerType>onCreateOnly</triggerType>\n    </rules>'),
}, [['WorkflowRule', `Account.${P}Wr`], ['WorkflowFieldUpdate', `Account.${P}Fu`]], { sharedFile: true, covers: ['WorkflowRule', 'WorkflowFieldUpdate'] });

add('CustomHelpMenuSection', {
    [`customHelpMenuSections/${P}Help.customHelpMenuSection-meta.xml`]: xml('CustomHelpMenuSection',
        `    <customHelpMenuItems>\n        <linkUrl>https://example.com</linkUrl>\n        <masterLabel>${P}Item</masterLabel>\n        <sortOrder>1</sortOrder>\n    </customHelpMenuItems>\n    <masterLabel>${P}Help</masterLabel>`),
}, [['CustomHelpMenuSection', P + 'Help']]);
add('QuickAction', {
    [`quickActions/${P}Qa.quickAction-meta.xml`]: xml('QuickAction',
        `    <label>${P}Qa</label>\n    <optionsCreateFeedItem>false</optionsCreateFeedItem>\n    <targetObject>Case</targetObject>\n` +
        '    <quickActionLayout>\n        <layoutSectionStyle>TwoColumnsLeftToRight</layoutSectionStyle>\n        <quickActionLayoutColumns>\n' +
        '            <quickActionLayoutItems>\n                <emptySpace>false</emptySpace>\n                <field>Subject</field>\n' +
        '                <uiBehavior>Edit</uiBehavior>\n            </quickActionLayoutItems>\n        </quickActionLayoutColumns>\n' +
        '        <quickActionLayoutColumns/>\n    </quickActionLayout>\n    <type>Create</type>'),
}, [['QuickAction', P + 'Qa']]);
add('ExternalCredential', {
    [`externalCredentials/${P}Ec.externalCredential-meta.xml`]: xml('ExternalCredential',
        `    <authenticationProtocol>Custom</authenticationProtocol>\n    <label>${P}Ec</label>`),
}, [['ExternalCredential', P + 'Ec']]);
add('ApprovalProcess', {
    [`approvalProcesses/Account.${P}Ap.approvalProcess-meta.xml`]: xml('ApprovalProcess',
        '    <active>false</active>\n    <allowRecall>false</allowRecall>\n    <allowedSubmitters>\n        <type>allInternalUsers</type>\n    </allowedSubmitters>\n' +
        '    <approvalPageFields>\n        <field>Name</field>\n    </approvalPageFields>\n    <approvalStep>\n        <allowDelegate>false</allowDelegate>\n' +
        '        <assignedApprover>\n            <approver>\n                <type>adhoc</type>\n            </approver>\n        </assignedApprover>\n' +
        '        <label>Step1</label>\n        <name>Step1</name>\n    </approvalStep>\n    <enableMobileDeviceAccess>false</enableMobileDeviceAccess>\n' +
        '    <entryCriteria>\n        <criteriaItems>\n            <field>Account.Name</field>\n            <operation>notEqual</operation>\n            <value>zzz</value>\n' +
        '        </criteriaItems>\n    </entryCriteria>\n    <finalApprovalRecordLock>false</finalApprovalRecordLock>\n' +
        `    <finalRejectionRecordLock>false</finalRejectionRecordLock>\n    <label>${P}Ap</label>\n    <processOrder>1</processOrder>\n` +
        '    <recordEditability>AdminOnly</recordEditability>\n    <showApprovalHistory>false</showApprovalHistory>'),
}, [['ApprovalProcess', `Account.${P}Ap`]]);
add('FlexiPage', {
    [`flexipages/${P}Page.flexipage-meta.xml`]: xml('FlexiPage',
        `    <flexiPageRegions>\n        <name>main</name>\n        <type>Region</type>\n    </flexiPageRegions>\n    <masterLabel>${P}Page</masterLabel>\n` +
        '    <template>\n        <name>flexipage:defaultAppHomeTemplate</name>\n    </template>\n    <type>AppPage</type>'),
}, [['FlexiPage', P + 'Page']]);
add('CustomApplication', {
    [`applications/${P}App.app-meta.xml`]: xml('CustomApplication',
        `    <formFactors>Large</formFactors>\n    <isNavAutoTempTabsDisabled>false</isNavAutoTempTabsDisabled>\n    <isNavPersonalizationDisabled>false</isNavPersonalizationDisabled>\n` +
        `    <label>${P}App</label>\n    <navType>Standard</navType>\n    <uiType>Lightning</uiType>`),
}, [['CustomApplication', P + 'App']]);

// ---- 追加のサンプル（2026-10-16: メタシンクの対象のうち、未確認だった種類）----
// 注意: 組織の機能（Omni-Channel・Entitlement・Knowledge など）が、有効でないと、リリースできない種類がある。
//   その場合も、このファイルの結果では ng になる（種類の制限と、組織の機能の不足を、区別しない）。理由は備考に出る
const O2 = P + STAMP + 'Sh1';     // 共有ルール（条件）用のカスタムオブジェクト
const O3 = P + STAMP + 'Sh2';     // 共有ルール（所有者）用のカスタムオブジェクト
const EV = P + STAMP + 'Evt';     // プラットフォームイベント
const sharingObj = (o) => ({
    [`objects/${o}__c/${o}__c.object-meta.xml`]: xml('CustomObject',
        `    <deploymentStatus>Deployed</deploymentStatus>\n    <label>${o}</label>\n    <nameField>\n        <label>Name</label>\n        <type>Text</type>\n    </nameField>\n` +
        `    <pluralLabel>${o}s</pluralLabel>\n    <sharingModel>Private</sharingModel>`),
    [`objects/${o}__c/fields/Note__c.field-meta.xml`]: xml('CustomField',
        '    <fullName>Note__c</fullName>\n    <label>Note</label>\n    <length>80</length>\n    <required>false</required>\n    <type>Text</type>\n    <unique>false</unique>'),
});
add('WorkflowAlert', {
    [`email/unfiled$public/${P}TplWa.email`]: 'Hello\n',
    [`email/unfiled$public/${P}TplWa.email-meta.xml`]: xml('EmailTemplate',
        `    <available>true</available>\n    <description>${P}</description>\n    <encodingKey>UTF-8</encodingKey>\n    <name>${P}TplWa</name>\n` +
        `    <style>none</style>\n    <subject>${P}</subject>\n    <type>text</type>\n    <uiType>Aloha</uiType>`),
    'workflows/Account.workflow-meta.xml': xml('Workflow',
        `    <alerts>\n        <fullName>${P}Wa</fullName>\n        <description>${P}Wa</description>\n        <protected>false</protected>\n` +
        `        <recipients>\n            <type>owner</type>\n        </recipients>\n        <senderType>CurrentUser</senderType>\n        <template>unfiled$public/${P}TplWa</template>\n    </alerts>`),
}, [['WorkflowAlert', `Account.${P}Wa`], ['EmailTemplate', `unfiled$public/${P}TplWa`]], { sharedFile: true });
add('DashboardFolder', {
    [`dashboards/${P}Dbf.dashboardFolder-meta.xml`]: xml('DashboardFolder',
        `    <accessType>Hidden</accessType>\n    <name>${P}Dbf</name>\n    <publicFolderAccess>ReadOnly</publicFolderAccess>`),
}, [['DashboardFolder', P + 'Dbf']]);
add('EmailFolder', {
    [`email/${P}Ef.emailFolder-meta.xml`]: xml('EmailFolder',
        `    <accessType>Hidden</accessType>\n    <name>${P}Ef</name>\n    <publicFolderAccess>ReadOnly</publicFolderAccess>`),
}, [['EmailFolder', P + 'Ef']]);
add('KeywordList', {
    [`keywords/${P}Kw.keywords-meta.xml`]: xml('KeywordList', `    <description>sf-tools</description>\n    <keywords>\n        <keyword>abc</keyword>\n    </keywords>`),
}, [['KeywordList', P + 'Kw']]);
add('ServiceChannel', {
    [`serviceChannels/${P}Sc.serviceChannel-meta.xml`]: xml('ServiceChannel',
        `    <label>${P}Sc</label>\n    <relatedEntityType>Case</relatedEntityType>`),
}, [['ServiceChannel', P + 'Sc']]);
add('PresenceUserConfig', {
    [`presenceUserConfigs/${P}Puc.presenceUserConfig-meta.xml`]: xml('PresenceUserConfig',
        `    <capacity>1</capacity>\n    <enableAutoAccept>false</enableAutoAccept>\n    <enableDecline>false</enableDecline>\n    <enableDeclineReason>false</enableDeclineReason>\n` +
        `    <enableDisconnectSound>false</enableDisconnectSound>\n    <enableRequestSound>false</enableRequestSound>\n` +
        `    <label>${P}Puc</label>`),
}, [['PresenceUserConfig', P + 'Puc']]);
add('QueueRoutingConfig', {
    [`queueRoutingConfigs/${P}Qrc.queueRoutingConfig-meta.xml`]: xml('QueueRoutingConfig',
        `    <capacityWeight>1</capacityWeight>\n    <label>${P}Qrc</label>\n    <routingModel>LEAST_ACTIVE</routingModel>\n    <routingPriority>1</routingPriority>`),
}, [['QueueRoutingConfig', P + 'Qrc']]);
add('EmailServicesFunction', {
    [`classes/${P}EsfH.cls`]: `global class ${P}EsfH implements Messaging.InboundEmailHandler {\n    global Messaging.InboundEmailResult handleInboundEmail(Messaging.InboundEmail email, Messaging.InboundEnvelope env) {\n        return new Messaging.InboundEmailResult();\n    }\n}\n`,
    [`classes/${P}EsfH.cls-meta.xml`]: apexMeta('ApexClass'),
    [`classes/${P}EsfHTest.cls`]: `@isTest\nprivate class ${P}EsfHTest {\n    @isTest static void t() { new ${P}EsfH().handleInboundEmail(new Messaging.InboundEmail(), new Messaging.InboundEnvelope()); }\n}\n`,
    [`classes/${P}EsfHTest.cls-meta.xml`]: apexMeta('ApexClass'),
    [`emailservices/${P}Esf.xml`]: xml('EmailServicesFunction',
        `    <apexClass>${P}EsfH</apexClass>\n    <attachmentOption>None</attachmentOption>\n    <authenticationFailureAction>Discard</authenticationFailureAction>\n` +
        `    <authorizationFailureAction>Discard</authorizationFailureAction>\n    <functionInactiveAction>Discard</functionInactiveAction>\n    <functionName>${P}Esf</functionName>\n` +
        '    <isActive>true</isActive>\n    <isAuthenticationRequired>false</isAuthenticationRequired>\n    <isErrorRoutingEnabled>false</isErrorRoutingEnabled>\n' +
        '    <isTextAttachmentsAsBinary>false</isTextAttachmentsAsBinary>\n    <isTlsRequired>false</isTlsRequired>\n    <overLimitAction>Discard</overLimitAction>'),
}, [['EmailServicesFunction', P + 'Esf'], ['ApexClass', P + 'EsfHTest'], ['ApexClass', P + 'EsfH']], { tests: [P + 'EsfHTest'] });
add('SharingCriteriaRule', Object.assign(sharingObj(O2), {
    [`sharingRules/${O2}__c.sharingRules-meta.xml`]: xml('SharingRules',
        `    <sharingCriteriaRules>\n        <fullName>${P}Sr</fullName>\n        <accessLevel>Read</accessLevel>\n        <label>${P}Sr</label>\n` +
        '        <sharedTo>\n            <allInternalUsers></allInternalUsers>\n        </sharedTo>\n' +
        '        <criteriaItems>\n            <field>Note__c</field>\n            <operation>equals</operation>\n            <value>a</value>\n        </criteriaItems>\n' +
        '        <includeRecordsOwnedByAll>false</includeRecordsOwnedByAll>\n    </sharingCriteriaRules>'),
}), [['SharingCriteriaRule', `${O2}__c.${P}Sr`], null, ['CustomField', `${O2}__c.Note__c`], ['CustomObject', `${O2}__c`]],
    { covers: ['SharingRules'], notes: 'カスタムオブジェクトは、削除後 15 日間、名前が予約される' });
add('SharingOwnerRule', Object.assign(sharingObj(O3), {
    [`sharingRules/${O3}__c.sharingRules-meta.xml`]: xml('SharingRules',
        `    <sharingOwnerRules>\n        <fullName>${P}So</fullName>\n        <accessLevel>Read</accessLevel>\n        <label>${P}So</label>\n` +
        '        <sharedTo>\n            <allInternalUsers></allInternalUsers>\n        </sharedTo>\n' +
        '        <sharedFrom>\n            <allInternalUsers></allInternalUsers>\n        </sharedFrom>\n    </sharingOwnerRules>'),
}), [['SharingOwnerRule', `${O3}__c.${P}So`], null, ['CustomField', `${O3}__c.Note__c`], ['CustomObject', `${O3}__c`]],
    { notes: 'カスタムオブジェクトは、削除後 15 日間、名前が予約される' });
add('PlatformEventChannelMember', {
    [`objects/${EV}__e/${EV}__e.object-meta.xml`]: xml('CustomObject',
        `    <deploymentStatus>Deployed</deploymentStatus>\n    <eventType>HighVolume</eventType>\n    <label>${EV}</label>\n    <pluralLabel>${EV}s</pluralLabel>\n    <publishBehavior>PublishAfterCommit</publishBehavior>`),
    [`platformEventChannels/${P}Mc__chn.platformEventChannel-meta.xml`]: xml('PlatformEventChannel', `    <channelType>event</channelType>\n    <label>${P}Mc</label>`),
    [`platformEventChannelMembers/${P}Mem.platformEventChannelMember-meta.xml`]: xml('PlatformEventChannelMember',
        `    <eventChannel>${P}Mc__chn</eventChannel>\n    <selectedEntity>${EV}__e</selectedEntity>`),
}, [['PlatformEventChannelMember', `${P}Mem`], ['PlatformEventChannel', P + 'Mc__chn'], ['CustomObject', `${EV}__e`]],
    { notes: 'カスタムオブジェクトは、削除後 15 日間、名前が予約される' });
add('Profile', {
    [`profiles/${P}Prof.profile-meta.xml`]: xml('Profile', '    <custom>true</custom>\n    <userLicense>Salesforce</userLicense>'),
}, [['Profile', P + 'Prof']]);
add('CustomPageWebLink', {
    [`weblinks/${P}Wl.weblink-meta.xml`]: xml('CustomPageWebLink',
        `    <availability>online</availability>\n    <displayType>link</displayType>\n    <encodingKey>UTF-8</encodingKey>\n    <linkType>url</linkType>\n    <masterLabel>${P}Wl</masterLabel>\n` +
        '    <openType>newWindow</openType>\n    <position>none</position>\n    <protected>false</protected>\n    <url>https://example.com</url>'),
}, [['CustomPageWebLink', P + 'Wl']]);
add('WebLink', {   // Account に、カスタムボタンを 1 つ追加する（既存のものには、触れない）
    [`objects/Account/webLinks/${P}Bt.webLink-meta.xml`]: xml('WebLink',
        `    <fullName>${P}Bt</fullName>\n    <availability>online</availability>\n    <displayType>button</displayType>\n    <encodingKey>UTF-8</encodingKey>\n    <linkType>url</linkType>\n` +
        `    <masterLabel>${P}Bt</masterLabel>\n    <openType>replace</openType>\n    <protected>false</protected>\n    <url>https://example.com</url>`),
}, [['WebLink', `Account.${P}Bt`]]);
add('ContentAsset', {
    [`contentassets/${P}Asset.asset`]: 'hello\n',
    [`contentassets/${P}Asset.asset-meta.xml`]: xml('ContentAsset',
        `    <isVisibleByExternalUsers>false</isVisibleByExternalUsers>\n    <language>en_US</language>\n    <masterLabel>${P}Asset</masterLabel>\n` +
        `    <versions>\n        <version>\n            <number>1</number>\n            <pathOnClient>${P}Asset.txt</pathOnClient>\n        </version>\n    </versions>`),
}, [['ContentAsset', P + 'Asset']]);
add('DataCategoryGroup', {
    [`datacategorygroups/${P}Dcg.datacategorygroup-meta.xml`]: xml('DataCategoryGroup',
        `    <active>false</active>\n    <dataCategory>\n        <label>All</label>\n        <name>All</name>\n    </dataCategory>\n    <description>sf-tools</description>\n    <label>${P}Dcg</label>`),
}, [['DataCategoryGroup', P + 'Dcg']]);
add('EntitlementTemplate', {
    [`entitlementTemplates/${P}Et.entitlementTemplate-meta.xml`]: xml('EntitlementTemplate',
        '    <casesPerEntitlement>1</casesPerEntitlement>\n    <isPerIncident>true</isPerIncident>\n    <term>12</term>\n    <type>Phone Support</type>'),
}, [['EntitlementTemplate', P + 'Et']]);
add('ExternalServiceRegistration', {
    [`namedCredentials/${P}NcEsr.namedCredential-meta.xml`]: xml('NamedCredential',
        `    <endpoint>https://example.com</endpoint>\n    <label>${P}NcEsr</label>\n    <namedCredentialType>Legacy</namedCredentialType>\n` +
        '    <principalType>Anonymous</principalType>\n    <protocol>NoAuthentication</protocol>'),
    [`externalServiceRegistrations/${P}Esr.externalServiceRegistration-meta.xml`]: xml('ExternalServiceRegistration',
        `    <label>${P}Esr</label>\n    <namedCredential>${P}NcEsr</namedCredential>\n    <registrationProviderType>Custom</registrationProviderType>\n` +
        '    <schema>{"openapi":"3.0.0","info":{"title":"t","version":"1.0"},"servers":[{"url":"https://example.com"}],' +
        '"paths":{"/ping":{"get":{"operationId":"ping","responses":{"200":{"description":"ok"}}}}}}</schema>\n' +
        '    <schemaType>OpenApi3</schemaType>\n    <status>Complete</status>'),
}, [['ExternalServiceRegistration', P + 'Esr'], ['NamedCredential', P + 'NcEsr']]);

// 進行の表示: 「[時:分:秒] メッセージ」を標準出力に出す
function log(m) {
    const d = new Date();
    console.log(`[${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}] ${m}`);
}

const ALLOWED = ['project deploy start', 'project deploy validate'];
// sf の起動: 引数は、シェルを通して渡すため、引用符で囲む（名前に $ や空白を含む: unfiled$public/..、Layout の名前）。
//   環境変数 SF_TYPECHECK_CMD で、起動するコマンドを差し替えられる（テストで、モックの sf を使うため。引用符で囲まずに、そのまま先頭に置く）
function quote(a) {
    const s = String(a);
    // POSIX: ' を '\'' にする（JS の文字列では "'\\''"。"'\''" と書くと、\' が ' になり、''' という誤った置換になる）
    return process.platform === 'win32' ? '"' + s.replace(/"/g, '\\"') + '"' : "'" + s.replace(/'/g, "'\\''") + "'";
}
// sf の実行: 引数の先頭 3 語が ALLOWED（project deploy start / validate）でなければ、例外で中断する。--json を末尾に付ける。
//   戻り値: { j: 応答の JSON（最初の { から読む。読めなければ { status: 1, message: 出力の末尾 300 文字 }）, sec: 所要秒 }
function sf(argv, cwd) {
    const sub = argv.slice(0, 3).join(' ');
    if (!ALLOWED.includes(sub)) throw new Error('許可していない sf のコマンドです: ' + sub);
    const t0 = Date.now();
    const cmd = (process.env.SF_TYPECHECK_CMD || 'sf') + ' ' + argv.concat('--json').map(quote).join(' ');
    const r = cp.spawnSync(cmd, { cwd, encoding: 'utf8', shell: true, maxBuffer: 64 * 1024 * 1024 });
    let j;
    const out = r.stdout || '';
    try { j = JSON.parse(out.slice(out.indexOf('{'))); } catch (e) { j = { status: 1, message: (out || r.stderr || '').slice(-300) }; }
    return { j, sec: Math.round((Date.now() - t0) / 100) / 10 };
}
// 成否: status が 0、かつ result.success が false でなければ ok
const okOf = (j) => j.status === 0 && ((j.result || {}).success !== false);
// 失敗の理由（備考用）: componentFailures の最初の 2 件（種類・名前・問題の先頭 120 文字）。なければ message
//   （なければ result.errorMessage）の空白を詰めた先頭 200 文字
function why(j) {
    const r = j.result || {};
    let cf = (r.details || {}).componentFailures || [];
    if (!Array.isArray(cf)) cf = [cf];
    if (cf.length) return cf.slice(0, 2).map((f) => `${f.componentType || ''} ${f.fullName || ''}: ${(f.problem || '').slice(0, 120)}`).join(' | ');
    return String(j.message || r.errorMessage || '').replace(/\s+/g, ' ').slice(0, 200);
}

function main() {
    const o = parseArgs(process.argv.slice(2));
    // 引数の値の検査は、--list より先に行う（--list があっても、--mode の誤り・予約名の --org は、エラーにする）
    if (!['full', 'validate'].includes(o.mode)) throw new Error('--mode は full または validate');
    if (o.org !== undefined && RESERVED.includes(o.org)) throw new Error('共有環境の予約名（' + o.org + '）には、実行できません');
    if (o.list) { S.forEach((s) => console.log(s.type)); return 0; }
    if (!o.org || !o.work) throw new Error('--org と --work が必要です');
    const list = S.filter((s) => !o.only || o.only.includes(s.type));
    fs.mkdirSync(o.work, { recursive: true });
    const rows = [];
    log(`種類ごとの確認（${o.mode}）: ${list.length} 種類。組織: ${o.org}`);
    list.forEach((s, i) => {
        const dir = path.join(o.work, s.type.replace(/[^A-Za-z0-9_]/g, '_'));
        fs.rmSync(dir, { recursive: true, force: true });
        fs.mkdirSync(path.join(dir, 'force-app', 'main', 'default'), { recursive: true });
        fs.writeFileSync(path.join(dir, 'sfdx-project.json'), '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"' + API + '"}');
        // 安全: 作成するファイルは、パスに SfToolsE2eMin を含むもの（ownsBody・sharedFile のサンプルは、中身に含むものも可）だけ。
        //   大文字・小文字を区別する（LWC のサンプル lwc/sfToolsE2eMinLwc/ は、先頭が小文字の綴りも認める hasP で確認する）。
        //   P + STAMP（実行ごとの別名）を含むパスは、hasP でも真になる（その条件は、念のための重ね）
        for (const [rel, body] of Object.entries(s.files)) {
            if (!(hasP(rel) || (s.ownsBody || s.sharedFile) && hasP(body)) && !rel.includes(P + STAMP)) {
                throw new Error('安全のため中断: 名前に ' + P + ' を含まないファイルです: ' + rel);
            }
            const dst = path.join(dir, 'force-app', 'main', 'default', ...rel.split('/'));
            fs.mkdirSync(path.dirname(dst), { recursive: true });
            fs.writeFileSync(dst, body, 'utf8');
        }
        for (const [t, m] of s.del.filter(Boolean)) if (!hasP(m)) throw new Error('安全のため中断: 削除対象の名前に ' + P + ' を含みません: ' + m);
        const row = { type: s.type, release: 'unknown', delete: 'unknown', note: s.notes || '' };
        log(`(${i + 1}/${list.length}) ${s.type}`);
        const extra = s.tests ? ['--test-level', 'RunSpecifiedTests'].concat(...s.tests.map((x) => ['--tests', x])) : [];
        const cmd = o.mode === 'full' ? 'start' : 'validate';
        const r1 = sf(['project', 'deploy', cmd, '--source-dir', 'force-app', '--target-org', o.org, '--wait', '30'].concat(extra), dir);
        row.release = okOf(r1.j) ? 'ok' : 'ng';
        if (row.release === 'ng') row.note = ('リリース: ' + why(r1.j)).slice(0, 220);
        log(`    リリース${o.mode === 'validate' ? '（検証）' : ''} ${row.release}（${r1.sec} 秒）${row.release === 'ok' ? '' : ' ' + why(r1.j).slice(0, 150)}`);
        if (o.mode === 'full' && row.release === 'ok') {
            // 削除は、null で区切った段階ごとに、順に実行する（例: 共有ルールの削除が終わってから、オブジェクトを削除する）
            const steps = [[]];
            s.del.forEach((d) => { if (d === null) steps.push([]); else steps[steps.length - 1].push(d); });
            fs.writeFileSync(path.join(dir, 'package.xml'), `${HEAD}<Package ${NS}><version>${API}</version></Package>`);
            row.delete = 'ok';
            let secTotal = 0;
            for (const st of steps) {
                const by = {};
                st.forEach(([t, m]) => { (by[t] = by[t] || []).push(m); });
                const types = Object.entries(by).map(([t, ms]) => `<types>${ms.map((m) => `<members>${m}</members>`).join('')}<name>${t}</name></types>`).join('');
                fs.writeFileSync(path.join(dir, 'destructiveChanges.xml'), `${HEAD}<Package ${NS}>${types}<version>${API}</version></Package>`);
                let r2 = sf(['project', 'deploy', 'start', '--manifest', 'package.xml', '--pre-destructive-changes', 'destructiveChanges.xml', '--target-org', o.org, '--wait', '30'], dir);
                secTotal += r2.sec;
                // 共有の再計算が終わるまで、削除が失敗する（already in progress）。30 秒おきに、最大 8 回、やり直す
                for (let n = 0; n < 8 && !okOf(r2.j) && /already in progress/.test(JSON.stringify(r2.j)); n++) {
                    log(`    共有の再計算の完了を待っています（${n + 1}/8）`);
                    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 30000);
                    r2 = sf(['project', 'deploy', 'start', '--manifest', 'package.xml', '--pre-destructive-changes', 'destructiveChanges.xml', '--target-org', o.org, '--wait', '30'], dir);
                    secTotal += r2.sec;
                }
                if (!okOf(r2.j)) {
                    row.delete = 'ng';
                    row.note = (row.note + ' 削除: ' + why(r2.j)).trim().slice(0, 220);
                    break;
                }
            }
            log(`    削除 ${row.delete}（${Math.round(secTotal * 10) / 10} 秒）${row.delete === 'ok' ? '' : ' ' + row.note.slice(0, 150)}`);
        }
        rows.push(row);
        // 同じサンプルの中で、一緒に確認できた別の種類（covers）も、同じ結果の行にする
        (s.covers || []).forEach((t) => rows.push(Object.assign({}, row, { type: t, note: ('（' + s.type + ' のサンプルと同時に確認）' + row.note).trim() })));
    });
    log('=== 結果 ===');
    rows.forEach((r) => log(`${r.type.padEnd(28)} release=${r.release.padEnd(7)} delete=${r.delete.padEnd(7)} ${r.note.slice(0, 100)}`));
    log(`リリース ok ${rows.filter((r) => r.release === 'ok').length} / 削除 ok ${rows.filter((r) => r.delete === 'ok').length}（全 ${rows.length} 種類）`);
    if (o.out) {
        fs.writeFileSync(o.out, rows.map((r) => [r.type, r.release, r.delete, r.note.replace(/[\t\r\n]+/g, ' ')].join('\t')).join('\n') + '\n', 'utf8');
        log('結果を書きました: ' + o.out);
    }
    const ng = rows.filter((r) => r.release === 'ng' || r.delete === 'ng').length;
    return ng === 0 ? 0 : 3;
}

try { process.exitCode = main(); } catch (e) { console.error('[ERROR] ' + e.message); process.exitCode = 1; }
