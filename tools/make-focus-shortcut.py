#!/usr/bin/env python3
# 生成「共享时隐身」用的勿扰快捷指令 focus.shortcut。
# 系统不给普通程序直接开关专注模式的接口，所以程序通过这个快捷指令来开关「勿扰模式」：
#   shortcuts run <名字> -i 文件   文件内容是 on 就打开勿扰，否则关闭。
# 快捷指令只有一个「如果」和两个「设定专注模式」，没有别的动作。
#
# 用法：python3 tools/make-focus-shortcut.py
#       （先生成未签名文件，再用 shortcuts sign --mode anyone 签名成仓库里的 focus.shortcut）
import plistlib
import subprocess
import tempfile
import uuid
from pathlib import Path

# 只写系统内部编号：带上 DisplayString 的话会按名字找，中文系统里叫「勿扰模式」就找不到（2026-10-20 实测）
DND = {"Identifier": "com.apple.donotdisturb.mode.default"}
group = str(uuid.uuid4()).upper()


def set_focus(enabled):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
        "WFWorkflowActionParameters": {"Enabled": 1 if enabled else 0, "FocusModes": DND},
    }


def branch(mode, extra=None):
    params = {"GroupingIdentifier": group, "WFControlFlowMode": mode}
    params.update(extra or {})
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.conditional", "WFWorkflowActionParameters": params}


# 输入转成文本后看是否包含 on
shortcut_input = {
    "Type": "Variable",
    "Variable": {
        "WFSerializationType": "WFTextTokenAttachment",
        "Value": {
            "Type": "ExtensionInput",
            "Aggrandizements": [{"Type": "WFCoercionVariableAggrandizement", "CoercionItemClass": "WFStringContentItem"}],
        },
    },
}

workflow = {
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 1440408063, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowTypes": [],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFQuickActionSurfaces": [],
    "WFWorkflowActions": [
        branch(0, {"WFInput": shortcut_input, "WFCondition": 99, "WFConditionalActionString": "on"}),
        set_focus(True),
        branch(1),
        set_focus(False),
        branch(2),
    ],
}

out = Path(__file__).resolve().parent.parent / "focus.shortcut"
with tempfile.TemporaryDirectory() as tmp:
    raw = Path(tmp) / "raw.shortcut"
    with open(raw, "wb") as f:
        plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
    # 签名结果不能直接写到仓库：shortcuts sign 输出的文件过几分钟会被系统删掉（2026-10-20 实测），先写临时目录再复制
    signed = Path(tmp) / "signed.shortcut"
    subprocess.run(["shortcuts", "sign", "--mode", "anyone", "-i", str(raw), "-o", str(signed)], check=True)
    out.write_bytes(signed.read_bytes())
    out.chmod(0o644)
print(out)
