#!/bin/bash
# ==============================================================================
# verify-samples.sh - リリースの仕組みの確認用サンプル（パターン別のコンポーネント）
# ==============================================================================
# lib/verify-common.sh から source される（単独では、source しない）。
# sf-init.sh --verify --components が、develop の組織に、リリースして、削除する。
# 目的は、「種類ごとに、書き方（ターゲットファイルの書式・パス・メンバー名）が違っても、リリースの仕組みが動く」ことの確認。
# 全種類を試すのではなく、書き方のパターンごとに、最小のものを 1 つずつ置く。
#
# 【サンプル（名前は、すべて SfToolsE2eHello 系。誰も使わない）】
#   段階 1（先に削除する。ほかのものから、参照されない）
#     ApexClass         SfToolsE2eHello / SfToolsE2eHelloTest / SfToolsE2eHelloTriggerTest   ... 1 ファイル + -meta.xml
#     ApexTrigger       SfToolsE2eHelloTrigger（SfToolsE2eHello__c の before insert）          ... オブジェクトに依存
#     LWC               sfToolsE2eHello（.html / .js / .js-meta.xml）                          ... バンドル（[files] に .js を指定）
#     Aura              SfToolsE2eHelloAura（.cmp / .cmp-meta.xml）                           ... バンドル（[members] で指定。LWC と名前空間が同じため、LWC とは別名）
#     Flow              SfToolsE2eHello（Draft）                                               ... 単独の XML
#     PermissionSet     SfToolsE2eHello                                                        ... 単独の XML
#     Layout            SfToolsE2eHello__c-SfToolsE2eHello Layout                              ... 名前に、空白・ハイフン
#     EmailTemplate     unfiled$public/SfToolsE2eHello                                         ... フォルダ付き・名前に $
#     CustomLabels      SfToolsE2eHello（1 ファイルに、複数のメンバーを持つ種類）                ... 既存の labels があるときは、使わない
#   段階 2（段階 1 のあとで削除する）
#     CustomObject      SfToolsE2eHello__c                                                     ... 親
#     CustomField       SfToolsE2eHello__c.Note__c                                             ... 子（Object.Field の書式）
#
# 【オブジェクト系（ApexTrigger とそのテスト・Layout・CustomObject・CustomField）】
#   カスタムオブジェクトは、削除すると、15 日間、削除済みの状態で名前が予約され、同じ API 名を再作成できない
#   （ごみ箱から消すまで）。そのため、リリースと削除の通しでは、既定で、含めない（--with-objects で、明示したときだけ含める）。
#   検証のみ（--validate-only）は、何も作らないため、常に含める（オブジェクトへの依存関係まで、実際の組織で検証する）。
#   Layout は、オブジェクトの最後の 1 つにできない（"Cannot delete the only layout"）ため、削除対象にせず、オブジェクトの削除に任せる。
#
# 【Flow】
#   Flow の削除は、API 経由では、Flow 型でも FlowDefinition 型でも拒否される場合がある（"insufficient access rights on
#   cross-reference id"。接続ユーザーに、Flow を API で削除する権限がない）。削除できないものを、リリースすると、組織に残る。
#   そのため、Flow は、検証のみ（--validate-only。何も作らない）で検証し、リリースと削除の通しには、含めない。
#   --cleanup は、リポジトリの Flow のファイルを削除する（組織の Flow は、API では消せないため、画面で、手動で削除する）。
#   削除対象（remove-target.txt）には、Flow を、含めない。
#
# 【環境変数】
#   VERIFY_SAMPLE_LABELS   1 = CustomLabels を含める（既定 1）。リポジトリに、すでに labels のファイルがあるときは、0 にする
#                          （そのファイルを、上書きして、削除してしまうため）
#   VERIFY_SAMPLE_OBJECTS  1 = オブジェクト系を含める（既定 1。verify.sh が、通しでは 0、--with-objects・検証のみでは 1 にする）
#   VERIFY_SAMPLE_FLOW     1 = Flow を含める（既定 1。verify.sh が、通しでは 0、検証のみ・--cleanup（ファイルの削除）では 1 にする）
# ==============================================================================

VERIFY_SAMPLE_NAME="SfToolsE2eHello"
VERIFY_SAMPLE_OBJ="SfToolsE2eHello__c"
VERIFY_SAMPLE_LWC="sfToolsE2eHello"
VERIFY_SAMPLE_AURA="SfToolsE2eHelloAura"   # LWC と Aura は、同じ名前空間（同名のバンドルは、作れない）。LWC とは別名にする
VERIFY_SAMPLE_BASE="force-app/main/default"
VERIFY_SAMPLE_API="64.0"
VERIFY_SAMPLE_LABELS_PATH="force-app/main/default/labels/CustomLabels.labels-meta.xml"
VERIFY_SAMPLE_TRIGGER="SfToolsE2eHelloTrigger"
VERIFY_SAMPLE_TRIGGER_TEST="SfToolsE2eHelloTriggerTest"
VERIFY_SAMPLE_LAYOUT="${VERIFY_SAMPLE_OBJ}-${VERIFY_SAMPLE_NAME} Layout"

# ------------------------------------------------------------------------------
# verify_sample_labels_file_is_ours - labels のファイル（標準入力）が、サンプル自身のものか
#   サンプルのラベル（fullName が SfToolsE2eHello）だけを含むファイルなら、サンプルのもの（前回の検証の残り）。
#   ほかのラベルを含む（または、読めない・空）ときは、利用者のものとして、触らない。戻り値: 0 = サンプルのもの / 1 = それ以外
#   （前回の検証が、途中で止まって、サンプルの labels のファイルが残ると、「利用者のファイル」と取り違えて、
#     ラベルを削除対象から外してしまい、ラベルとファイルが、後始末でも消えなくなるため）
# ------------------------------------------------------------------------------
verify_sample_labels_file_is_ours() {
    local body n
    body=$(cat)  # VAR=$(cmd) のため run 不使用
    n=$(printf '%s\n' "$body" | grep -c '<fullName>')  # VAR=$(cmd) のため run 不使用
    [[ "$n" == "1" ]] && printf '%s\n' "$body" | grep -q "<fullName>${VERIFY_SAMPLE_NAME}</fullName>"
}

# ------------------------------------------------------------------------------
# パスの一覧（リポジトリの中のパス）。引数: stage1 | stage2 | all（既定 all）
# ------------------------------------------------------------------------------
verify_sample_paths() {
    local stage="${1:-all}" b="$VERIFY_SAMPLE_BASE"
    if [[ "$stage" == "stage1" || "$stage" == "all" ]]; then
        printf '%s\n' \
            "${b}/classes/${VERIFY_SAMPLE_NAME}.cls" \
            "${b}/classes/${VERIFY_SAMPLE_NAME}.cls-meta.xml" \
            "${b}/classes/${VERIFY_APEX_HELLO_TEST}.cls" \
            "${b}/classes/${VERIFY_APEX_HELLO_TEST}.cls-meta.xml" \
            "${b}/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.html" \
            "${b}/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.js" \
            "${b}/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.js-meta.xml" \
            "${b}/aura/${VERIFY_SAMPLE_AURA}/${VERIFY_SAMPLE_AURA}.cmp" \
            "${b}/aura/${VERIFY_SAMPLE_AURA}/${VERIFY_SAMPLE_AURA}.cmp-meta.xml" \
            "${b}/permissionsets/${VERIFY_SAMPLE_NAME}.permissionset-meta.xml" \
            "${b}/email/unfiled\$public/${VERIFY_SAMPLE_NAME}.email" \
            "${b}/email/unfiled\$public/${VERIFY_SAMPLE_NAME}.email-meta.xml"
        [[ "${VERIFY_SAMPLE_FLOW:-1}" == "1" ]] && printf '%s\n' "${b}/flows/${VERIFY_SAMPLE_NAME}.flow-meta.xml"
        if [[ "${VERIFY_SAMPLE_OBJECTS:-1}" == "1" ]]; then
            printf '%s\n' \
                "${b}/classes/${VERIFY_SAMPLE_TRIGGER_TEST}.cls" \
                "${b}/classes/${VERIFY_SAMPLE_TRIGGER_TEST}.cls-meta.xml" \
                "${b}/triggers/${VERIFY_SAMPLE_TRIGGER}.trigger" \
                "${b}/triggers/${VERIFY_SAMPLE_TRIGGER}.trigger-meta.xml" \
                "${b}/layouts/${VERIFY_SAMPLE_LAYOUT}.layout-meta.xml"
        fi
        [[ "${VERIFY_SAMPLE_LABELS:-1}" == "1" ]] && printf '%s\n' "$VERIFY_SAMPLE_LABELS_PATH"
    fi
    if [[ "${VERIFY_SAMPLE_OBJECTS:-1}" == "1" && ( "$stage" == "stage2" || "$stage" == "all" ) ]]; then
        printf '%s\n' \
            "${b}/objects/${VERIFY_SAMPLE_OBJ}/${VERIFY_SAMPLE_OBJ}.object-meta.xml" \
            "${b}/objects/${VERIFY_SAMPLE_OBJ}/fields/Note__c.field-meta.xml"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# パスに対応する本文
# ------------------------------------------------------------------------------
_vs_xml_head() { printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'; }

verify_sample_content_for() {
    local p="$1"
    case "$p" in
        *"/classes/${VERIFY_SAMPLE_NAME}.cls")        verify_hello_cls ;;
        *"/classes/${VERIFY_APEX_HELLO_TEST}.cls")    verify_hello_test_cls ;;
        *"/classes/${VERIFY_SAMPLE_TRIGGER_TEST}.cls")
            printf '%s\n' "@isTest" \
                "private class ${VERIFY_SAMPLE_TRIGGER_TEST} {" \
                "    @isTest" \
                "    static void triggerSetsNote() {" \
                "        ${VERIFY_SAMPLE_OBJ} r = new ${VERIFY_SAMPLE_OBJ}();" \
                "        insert r;" \
                "        r = [SELECT Note__c FROM ${VERIFY_SAMPLE_OBJ} WHERE Id = :r.Id];" \
                "        System.assertEquals('hello', r.Note__c);" \
                "    }" \
                "}" ;;
        *".cls-meta.xml")                             verify_apex_meta ;;
        *"/triggers/${VERIFY_SAMPLE_TRIGGER}.trigger")
            printf '%s\n' "trigger ${VERIFY_SAMPLE_TRIGGER} on ${VERIFY_SAMPLE_OBJ} (before insert) {" \
                "    for (${VERIFY_SAMPLE_OBJ} r : Trigger.new) {" \
                "        if (r.Note__c == null) { r.Note__c = 'hello'; }" \
                "    }" \
                "}" ;;
        *".trigger-meta.xml")
            _vs_xml_head
            printf '%s\n' '<ApexTrigger xmlns="http://soap.sforce.com/2006/04/metadata">' \
                "    <apiVersion>${VERIFY_SAMPLE_API}</apiVersion>" \
                '    <status>Active</status>' \
                '</ApexTrigger>' ;;
        *"/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.html")
            printf '%s\n' '<template>' '    <p>Hello, World!</p>' '</template>' ;;
        *"/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.js")
            printf '%s\n' "import { LightningElement } from 'lwc';" \
                "export default class SfToolsE2eHello extends LightningElement {}" ;;
        *"/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.js-meta.xml")
            _vs_xml_head
            printf '%s\n' '<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">' \
                "    <apiVersion>${VERIFY_SAMPLE_API}</apiVersion>" \
                '    <isExposed>false</isExposed>' \
                '</LightningComponentBundle>' ;;
        *"/aura/${VERIFY_SAMPLE_AURA}/${VERIFY_SAMPLE_AURA}.cmp")
            printf '%s\n' '<aura:component>' '    <p>Hello, World!</p>' '</aura:component>' ;;
        *"/aura/${VERIFY_SAMPLE_AURA}/${VERIFY_SAMPLE_AURA}.cmp-meta.xml")
            _vs_xml_head
            printf '%s\n' '<AuraDefinitionBundle xmlns="http://soap.sforce.com/2006/04/metadata">' \
                "    <apiVersion>${VERIFY_SAMPLE_API}</apiVersion>" \
                '    <description>SfToolsE2eHello</description>' \
                '</AuraDefinitionBundle>' ;;
        *"/flows/${VERIFY_SAMPLE_NAME}.flow-meta.xml")
            _vs_xml_head
            printf '%s\n' '<Flow xmlns="http://soap.sforce.com/2006/04/metadata">' \
                "    <apiVersion>${VERIFY_SAMPLE_API}</apiVersion>" \
                "    <label>${VERIFY_SAMPLE_NAME}</label>" \
                '    <processType>AutoLaunchedFlow</processType>' \
                '    <start>' \
                '        <locationX>50</locationX>' \
                '        <locationY>0</locationY>' \
                '    </start>' \
                '    <status>Draft</status>' \
                '</Flow>' ;;
        *"/permissionsets/${VERIFY_SAMPLE_NAME}.permissionset-meta.xml")
            _vs_xml_head
            printf '%s\n' '<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">' \
                '    <hasActivationRequired>false</hasActivationRequired>' \
                "    <label>${VERIFY_SAMPLE_NAME}</label>" \
                '</PermissionSet>' ;;
        *"/layouts/${VERIFY_SAMPLE_LAYOUT}.layout-meta.xml")
            _vs_xml_head
            printf '%s\n' '<Layout xmlns="http://soap.sforce.com/2006/04/metadata">' \
                '    <layoutSections>' \
                '        <customLabel>false</customLabel>' \
                '        <detailHeading>false</detailHeading>' \
                '        <editHeading>true</editHeading>' \
                '        <label>Information</label>' \
                '        <layoutColumns>' \
                '            <layoutItems>' \
                '                <behavior>Required</behavior>' \
                '                <field>Name</field>' \
                '            </layoutItems>' \
                '        </layoutColumns>' \
                '        <style>OneColumn</style>' \
                '    </layoutSections>' \
                '</Layout>' ;;
        *"/email/unfiled\$public/${VERIFY_SAMPLE_NAME}.email")
            printf '%s\n' 'Hello, World!' ;;
        *"/email/unfiled\$public/${VERIFY_SAMPLE_NAME}.email-meta.xml")
            _vs_xml_head
            printf '%s\n' '<EmailTemplate xmlns="http://soap.sforce.com/2006/04/metadata">' \
                '    <available>true</available>' \
                "    <description>${VERIFY_SAMPLE_NAME}</description>" \
                '    <encodingKey>UTF-8</encodingKey>' \
                "    <name>${VERIFY_SAMPLE_NAME}</name>" \
                '    <style>none</style>' \
                "    <subject>${VERIFY_SAMPLE_NAME}</subject>" \
                '    <type>text</type>' \
                '    <uiType>Aloha</uiType>' \
                '</EmailTemplate>' ;;
        "$VERIFY_SAMPLE_LABELS_PATH")
            _vs_xml_head
            printf '%s\n' '<CustomLabels xmlns="http://soap.sforce.com/2006/04/metadata">' \
                '    <labels>' \
                "        <fullName>${VERIFY_SAMPLE_NAME}</fullName>" \
                '        <language>en_US</language>' \
                '        <protected>false</protected>' \
                '        <shortDescription>SfToolsE2eHello</shortDescription>' \
                '        <value>Hello, World!</value>' \
                '    </labels>' \
                '</CustomLabels>' ;;
        *"/objects/${VERIFY_SAMPLE_OBJ}/${VERIFY_SAMPLE_OBJ}.object-meta.xml")
            _vs_xml_head
            printf '%s\n' '<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">' \
                '    <deploymentStatus>Deployed</deploymentStatus>' \
                '    <label>SfToolsE2eHello</label>' \
                '    <nameField>' \
                '        <label>Name</label>' \
                '        <type>Text</type>' \
                '    </nameField>' \
                '    <pluralLabel>SfToolsE2eHellos</pluralLabel>' \
                '    <sharingModel>ReadWrite</sharingModel>' \
                '</CustomObject>' ;;
        *"/objects/${VERIFY_SAMPLE_OBJ}/fields/Note__c.field-meta.xml")
            _vs_xml_head
            printf '%s\n' '<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">' \
                '    <fullName>Note__c</fullName>' \
                '    <label>Note</label>' \
                '    <length>80</length>' \
                '    <required>false</required>' \
                '    <type>Text</type>' \
                '    <unique>false</unique>' \
                '</CustomField>' ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# deploy-target.txt / remove-target.txt の本文
#   リリース: [files] と [members] の両方の書き方を使う（どちらも、通ることの確認）
#   削除    : 段階 1（stage1）→ 段階 2（stage2）。オブジェクトは、参照するもの（トリガー・項目の参照・Layout）を消したあとで消す
# ------------------------------------------------------------------------------
verify_sample_deploy_target_text() {
    local b="$VERIFY_SAMPLE_BASE" obj="${VERIFY_SAMPLE_OBJECTS:-1}"
    printf '%s\n' '[files]' \
        "${b}/classes/${VERIFY_SAMPLE_NAME}.cls" \
        "${b}/classes/${VERIFY_APEX_HELLO_TEST}.cls"
    if [[ "$obj" == "1" ]]; then
        printf '%s\n' \
            "${b}/classes/${VERIFY_SAMPLE_TRIGGER_TEST}.cls" \
            "${b}/triggers/${VERIFY_SAMPLE_TRIGGER}.trigger"
    fi
    printf '%s\n' "${b}/lwc/${VERIFY_SAMPLE_LWC}/${VERIFY_SAMPLE_LWC}.js"
    [[ "${VERIFY_SAMPLE_FLOW:-1}" == "1" ]] && printf '%s\n' "${b}/flows/${VERIFY_SAMPLE_NAME}.flow-meta.xml"
    printf '%s\n' \
        "${b}/permissionsets/${VERIFY_SAMPLE_NAME}.permissionset-meta.xml" \
        "${b}/email/unfiled\$public/${VERIFY_SAMPLE_NAME}.email" \
        '' '[members]' \
        "AuraDefinitionBundle:${VERIFY_SAMPLE_AURA}"
    if [[ "$obj" == "1" ]]; then
        printf '%s\n' \
            "CustomObject:${VERIFY_SAMPLE_OBJ}" \
            "CustomField:${VERIFY_SAMPLE_OBJ}.Note__c" \
            "Layout:${VERIFY_SAMPLE_LAYOUT}"
    fi
    [[ "${VERIFY_SAMPLE_LABELS:-1}" == "1" ]] && printf '%s\n' "CustomLabel:${VERIFY_SAMPLE_NAME}"
    return 0
}
# 引数: stage1 | stage2
#   stage1: ほかから参照されないもの。Layout は、含めない（オブジェクトの削除に任せる）。Flow も、含めない（API で削除できない場合がある）
#   stage2: 項目・オブジェクト（オブジェクト系を含めるときだけ）。オブジェクトは、項目のあと
verify_sample_remove_target_text() {
    printf '%s\n' '[files]' '' '[members]'
    if [[ "${1:-stage1}" == "stage1" ]]; then
        if [[ "${VERIFY_SAMPLE_OBJECTS:-1}" == "1" ]]; then
            printf '%s\n' \
                "ApexTrigger:${VERIFY_SAMPLE_TRIGGER}" \
                "ApexClass:${VERIFY_SAMPLE_TRIGGER_TEST}"
        fi
        printf '%s\n' \
            "ApexClass:${VERIFY_APEX_HELLO_TEST}" \
            "ApexClass:${VERIFY_SAMPLE_NAME}" \
            "LightningComponentBundle:${VERIFY_SAMPLE_LWC}" \
            "AuraDefinitionBundle:${VERIFY_SAMPLE_AURA}" \
            "PermissionSet:${VERIFY_SAMPLE_NAME}" \
            "EmailTemplate:unfiled\$public/${VERIFY_SAMPLE_NAME}"
        [[ "${VERIFY_SAMPLE_LABELS:-1}" == "1" ]] && printf '%s\n' "CustomLabel:${VERIFY_SAMPLE_NAME}"
    elif [[ "${VERIFY_SAMPLE_OBJECTS:-1}" == "1" ]]; then
        printf '%s\n' \
            "CustomField:${VERIFY_SAMPLE_OBJ}.Note__c" \
            "CustomObject:${VERIFY_SAMPLE_OBJ}"
    fi
    return 0
}
