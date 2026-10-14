#!/usr/bin/env python3
"""Narrow local MCP server for ControlDeck controller profile settings."""

from __future__ import annotations

import json
import plistlib
import subprocess
import sys
from typing import Any


DOMAINS = (
    "com.ianhansel.controldeck",
    "com.ianhansel.ps5codex",
)
STORAGE_KEY = "controllerProfiles.v3"
PROFILE_WHEEL_STORAGE_KEY = "profileWheelSettings.v1"
VALID_INPUTS = {
    "cross", "circle", "square", "triangle",
    "dpadUp", "dpadDown", "dpadLeft", "dpadRight",
    "l1", "r1", "l2", "r2", "l3", "r3",
    "create", "options", "ps", "touchpadClick", "microphone",
}
VALID_STICKS = {"off", "left", "right"}
VALID_GYRO_GESTURES = {
    "shake", "tiltLeft", "tiltRight", "tiltUp", "tiltDown",
    "twistCounterclockwise", "twistClockwise",
}
VALID_ACTIONS = {
    "none",
    "codexSend", "codexStop", "codexReview", "codexPlan",
    "codexNewTask", "codexCommandMenu", "codexFocus",
    "codexPreviousTask", "codexNextTask", "codexBack", "codexForward",
    "codexSidebar", "codexQuickChat", "codexTerminal", "codexApprove",
    "codexDecline", "codexDictation", "codexAppSnapshot",
    "codexFastMode", "codexContinueInNewTask",
    "claudeNewChat", "claudeSidebar", "claudeCode", "claudeProjects",
    "meetingMute", "meetingPushToTalk", "meetingVideo", "meetingChat",
    "meetingParticipants", "meetingShare", "meetingRaiseHand",
    "presentationStart", "presentationNext", "presentationPrevious",
    "presentationBlackScreen", "presentationPointer",
    "presentationNotesUp", "presentationNotesDown", "presentationExit",
    "slackJumpConversation", "slackPreviousUnread", "slackNextUnread",
    "slackThreads", "slackActivity", "slackHuddle",
    "mailArchive", "mailReply", "mailUnread",
    "photosFavorite", "photosEdit", "photosRotate", "photosInfo",
    "timelinePlayPause", "timelineReverse", "timelinePause",
    "timelineForward", "timelineMarkIn", "timelineMarkOut",
    "timelinePreviousEdit", "timelineNextEdit", "timelineRecord",
    "timelineRewind", "timelineFastForward",
    "figmaComment", "figmaFrame", "figmaHand", "figmaDevMode",
    "terminalNewTab", "terminalCloseTab", "terminalNextTab",
    "terminalPreviousTab", "terminalClear", "terminalInterrupt",
    "terminalSearchHistory", "terminalSplitPane", "terminalClosePane",
    "mouseLeftClick", "mouseRightClick", "mouseMiddleClick",
    "screenshotSelection",
    "back", "forward", "missionControl", "showDesktop", "appSwitcher",
    "returnKey", "escapeKey", "spaceKey", "tabKey",
    "copy", "paste", "cut", "selectAll", "undo", "redo",
    "zoomIn", "zoomOut",
    "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
    "browserAddress", "browserNewTab", "browserCloseTab",
    "browserReopenTab", "browserReload", "browserFind",
    "browserNextTab", "browserPreviousTab",
    "mediaPlayPause", "mediaNext", "mediaPrevious",
    "volumeUp", "volumeDown", "volumeMute",
    "openCodex", "openChrome", "openSpotify", "openClaude",
    "systemDictation", "cursorDictation", "grokDictation", "cursorPreviousConversation", "cursorNextConversation", "cursorCollapseWorkspace", "cursorExpandWorkspace", "grokPreviousBot", "grokNextBot", "grokCollapseSection", "grokExpandSection", "assistantRightPanel", "assistantSend", "showControllerOverlay", "deleteTextWithConfirmation",
}


def _read_profiles() -> tuple[list[dict[str, Any]], str]:
    for domain in DOMAINS:
        result = subprocess.run(
            ["/usr/bin/defaults", "export", domain, "-"],
            check=False,
            capture_output=True,
        )
        if result.returncode != 0:
            continue
        try:
            plist = plistlib.loads(result.stdout)
            payload = plist.get(STORAGE_KEY)
            if isinstance(payload, bytes):
                profiles = json.loads(payload.decode("utf-8"))
                if isinstance(profiles, list):
                    return profiles, domain
        except (ValueError, TypeError, json.JSONDecodeError):
            continue
    raise RuntimeError(
        "No controller profiles found. Open ControlDeck once, then try again."
    )


def _write_profiles(profiles: list[dict[str, Any]]) -> None:
    encoded = json.dumps(
        profiles, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8").hex()
    failures: list[str] = []
    for domain in DOMAINS:
        result = subprocess.run(
            [
                "/usr/bin/defaults", "write", domain, STORAGE_KEY,
                "-data", encoded,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            failures.append(result.stderr.strip() or domain)
    if len(failures) == len(DOMAINS):
        raise RuntimeError("Could not save profiles: " + "; ".join(failures))


def _read_profile_wheel() -> list[dict[str, Any]]:
    for domain in DOMAINS:
        result = subprocess.run(
            ["/usr/bin/defaults", "export", domain, "-"],
            check=False,
            capture_output=True,
        )
        if result.returncode != 0:
            continue
        try:
            plist = plistlib.loads(result.stdout)
            payload = plist.get(PROFILE_WHEEL_STORAGE_KEY)
            if isinstance(payload, bytes):
                slots = json.loads(payload.decode("utf-8"))
                if isinstance(slots, list):
                    return slots
        except (ValueError, TypeError, json.JSONDecodeError):
            continue
    raise RuntimeError(
        "No profile wheel found. Open ControlDeck once, then try again."
    )


def _write_profile_wheel(slots: list[dict[str, Any]]) -> None:
    encoded = json.dumps(
        slots, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8").hex()
    failures: list[str] = []
    for domain in DOMAINS:
        result = subprocess.run(
            [
                "/usr/bin/defaults", "write", domain,
                PROFILE_WHEEL_STORAGE_KEY,
                "-data", encoded,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            failures.append(result.stderr.strip() or domain)
    if len(failures) == len(DOMAINS):
        raise RuntimeError(
            "Could not save the profile wheel: " + "; ".join(failures)
        )


def _profile(
    profiles: list[dict[str, Any]], identifier: str
) -> dict[str, Any]:
    wanted = identifier.casefold()
    for profile in profiles:
        candidates = {
            str(profile.get("kind", "")).casefold(),
            str(profile.get("name", "")).casefold(),
        }
        if wanted in candidates:
            return profile
    available = ", ".join(str(item.get("name")) for item in profiles)
    raise ValueError(f"Unknown profile '{identifier}'. Available: {available}")


def _text(value: Any) -> dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(value, indent=2, ensure_ascii=False),
            }
        ]
    }


def _tool_result(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name == "get_profile_wheel":
        return _text(_read_profile_wheel())
    if name == "set_profile_wheel_slot":
        position = int(arguments["slot"])
        if position < 1 or position > 8:
            raise ValueError("slot must be between 1 and 8")
        profiles, _ = _read_profiles()
        selected_profile = _profile(profiles, str(arguments["profile"]))
        selected_kind = str(selected_profile.get("kind"))
        slots = _read_profile_wheel()
        target = next(
            (item for item in slots if int(item.get("position", -1)) == position - 1),
            None,
        )
        if target is None:
            raise ValueError(f"Profile wheel slot {position} is missing")
        displaced_kind = target.get("profileKind")
        existing = next(
            (
                item for item in slots
                if item.get("profileKind") == selected_kind
            ),
            None,
        )
        if existing is not None and existing is not target:
            existing["profileKind"] = displaced_kind
        target["profileKind"] = selected_kind
        _write_profile_wheel(slots)
        return _text(
            {
                "updatedSlot": position,
                "profile": selected_profile.get("name"),
                "reload": "Return to ControlDeck to load the change.",
            }
        )

    profiles, _ = _read_profiles()
    if name == "list_profiles":
        return _text(
            [
                {
                    "id": item.get("kind"),
                    "name": item.get("name"),
                    "apps": item.get("bundleIdentifiers", []),
                    "pointer": item.get("pointer", {}),
                    "gyro": item.get("gyro", {}),
                }
                for item in profiles
            ]
        )
    if name == "get_profile":
        return _text(_profile(profiles, str(arguments["profile"])))
    if name == "set_button_mapping":
        input_name = str(arguments["input"])
        if input_name not in VALID_INPUTS:
            raise ValueError(f"Unsupported controller input: {input_name}")
        action = str(arguments["action"])
        if action not in VALID_ACTIONS:
            raise ValueError(f"Unsupported action: {action}")
        profile = _profile(profiles, str(arguments["profile"]))
        profile.setdefault("bindings", {})[input_name] = action
        _write_profiles(profiles)
        return _text(
            {
                "updated": profile.get("name"),
                "input": input_name,
                "action": action,
                "reload": "Return to ControlDeck to load the change.",
            }
        )
    if name == "set_pointer":
        source = str(arguments["source"])
        if source not in VALID_STICKS:
            raise ValueError("source must be off, left, or right")
        profile = _profile(profiles, str(arguments["profile"]))
        pointer = profile.setdefault("pointer", {})
        pointer["source"] = source
        for key in ("speed", "acceleration", "deadZone"):
            if key in arguments:
                pointer[key] = float(arguments[key])
        if "scrollSource" in arguments:
            scroll_source = str(arguments["scrollSource"])
            if scroll_source not in VALID_STICKS:
                raise ValueError("scrollSource must be off, left, or right")
            pointer["scrollSource"] = scroll_source
        for key in (
            "scrollSpeed", "scrollAcceleration", "scrollDeadZone"
        ):
            if key in arguments:
                pointer[key] = float(arguments[key])
        _write_profiles(profiles)
        return _text(
            {
                "updated": profile.get("name"),
                "pointer": pointer,
                "reload": "Return to ControlDeck to load the change.",
            }
        )
    if name == "set_gyro":
        profile = _profile(profiles, str(arguments["profile"]))
        gyro = profile.setdefault("gyro", {})
        gyro.setdefault("enabled", True)
        gyro.setdefault("shakeThreshold", 2.25)
        gyro.setdefault("tiltThreshold", 0.68)
        gyro.setdefault("rotationThreshold", 3.4)
        gyro.setdefault(
            "gestureBindings",
            {"shake": "deleteTextWithConfirmation"},
        )
        if "enabled" in arguments:
            gyro["enabled"] = bool(arguments["enabled"])
        for key in (
            "shakeThreshold", "tiltThreshold", "rotationThreshold"
        ):
            if key in arguments:
                gyro[key] = float(arguments[key])
        _write_profiles(profiles)
        return _text(
            {
                "updated": profile.get("name"),
                "gyro": gyro,
                "reload": "Return to ControlDeck to load the change.",
            }
        )
    if name == "set_gyro_mapping":
        gesture = str(arguments["gesture"])
        if gesture not in VALID_GYRO_GESTURES:
            raise ValueError(f"Unsupported gyro gesture: {gesture}")
        action = str(arguments["action"])
        if action not in VALID_ACTIONS:
            raise ValueError(f"Unsupported action: {action}")
        profile = _profile(profiles, str(arguments["profile"]))
        gyro = profile.setdefault("gyro", {})
        gyro.setdefault("enabled", True)
        gyro.setdefault("shakeThreshold", 2.25)
        gyro.setdefault("tiltThreshold", 0.68)
        gyro.setdefault("rotationThreshold", 3.4)
        gyro.setdefault("gestureBindings", {})[gesture] = action
        _write_profiles(profiles)
        return _text(
            {
                "updated": profile.get("name"),
                "gesture": gesture,
                "action": action,
                "reload": "Return to ControlDeck to load the change.",
            }
        )
    if name == "assign_profile_apps":
        profile = _profile(profiles, str(arguments["profile"]))
        apps = arguments["bundleIdentifiers"]
        if not isinstance(apps, list) or not all(
            isinstance(item, str) and item for item in apps
        ):
            raise ValueError("bundleIdentifiers must be a list of strings")
        profile["bundleIdentifiers"] = apps
        _write_profiles(profiles)
        return _text(
            {
                "updated": profile.get("name"),
                "bundleIdentifiers": apps,
                "reload": "Return to ControlDeck to load the change.",
            }
        )
    raise ValueError(f"Unknown tool: {name}")


TOOLS = [
    {
        "name": "get_profile_wheel",
        "description": "Read the eight Options profile-wheel slots.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "set_profile_wheel_slot",
        "description": "Assign or swap one of the eight Options profile-wheel slots.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "slot": {"type": "integer", "minimum": 1, "maximum": 8},
                "profile": {"type": "string"},
            },
            "required": ["slot", "profile"],
            "additionalProperties": False,
        },
    },
    {
        "name": "list_profiles",
        "description": "List profiles with assigned apps, pointer and gyro settings.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_profile",
        "description": "Read one complete controller profile before changing it.",
        "inputSchema": {
            "type": "object",
            "properties": {"profile": {"type": "string"}},
            "required": ["profile"],
            "additionalProperties": False,
        },
    },
    {
        "name": "set_button_mapping",
        "description": "Assign one action identifier to one controller input.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string"},
                "input": {"type": "string", "enum": sorted(VALID_INPUTS)},
                "action": {
                    "type": "string",
                    "enum": sorted(VALID_ACTIONS),
                },
            },
            "required": ["profile", "input", "action"],
            "additionalProperties": False,
        },
    },
    {
        "name": "set_pointer",
        "description": "Choose pointer and scroll sticks and tune their tracking values.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string"},
                "source": {"type": "string", "enum": sorted(VALID_STICKS)},
                "speed": {"type": "number", "minimum": 100, "maximum": 2400},
                "acceleration": {"type": "number", "minimum": 1, "maximum": 3},
                "deadZone": {"type": "number", "minimum": 0.02, "maximum": 0.5},
                "scrollSource": {
                    "type": "string",
                    "enum": sorted(VALID_STICKS),
                },
                "scrollSpeed": {
                    "type": "number",
                    "minimum": 100,
                    "maximum": 2400,
                },
                "scrollAcceleration": {
                    "type": "number",
                    "minimum": 1,
                    "maximum": 3,
                },
                "scrollDeadZone": {
                    "type": "number",
                    "minimum": 0.02,
                    "maximum": 0.5,
                },
            },
            "required": ["profile", "source"],
            "additionalProperties": False,
        },
    },
    {
        "name": "assign_profile_apps",
        "description": "Replace the macOS bundle identifiers that activate a profile.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string"},
                "bundleIdentifiers": {
                    "type": "array",
                    "items": {"type": "string"},
                    "maxItems": 30,
                },
            },
            "required": ["profile", "bundleIdentifiers"],
            "additionalProperties": False,
        },
    },
    {
        "name": "set_gyro",
        "description": "Enable gyro input and tune motion thresholds for one profile.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string"},
                "enabled": {"type": "boolean"},
                "shakeThreshold": {
                    "type": "number", "minimum": 1.4, "maximum": 3.6
                },
                "tiltThreshold": {
                    "type": "number", "minimum": 0.45, "maximum": 0.88
                },
                "rotationThreshold": {
                    "type": "number", "minimum": 1.5, "maximum": 6.0
                },
            },
            "required": ["profile"],
            "additionalProperties": False,
        },
    },
    {
        "name": "set_gyro_mapping",
        "description": "Assign one safe ControlDeck action to a gyro gesture.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string"},
                "gesture": {
                    "type": "string", "enum": sorted(VALID_GYRO_GESTURES)
                },
                "action": {"type": "string", "enum": sorted(VALID_ACTIONS)},
            },
            "required": ["profile", "gesture", "action"],
            "additionalProperties": False,
        },
    },
]


def _handle(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    request_id = message.get("id")
    if request_id is None:
        return None
    if method == "initialize":
        result = {
            "protocolVersion": "2025-03-26",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "control-deck", "version": "1.2.0"},
            "instructions": (
                "Read a profile before changing it. Make narrow changes only. "
                "Never invent input names; use the tool schema. Profile writes "
                "affect only ControlDeck controller, gyro and profile-wheel settings."
            ),
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = message.get("params") or {}
        try:
            result = _tool_result(
                str(params.get("name")), params.get("arguments") or {}
            )
        except (KeyError, ValueError, RuntimeError) as error:
            result = _text({"error": str(error)})
            result["isError"] = True
    else:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "Method not found"},
        }
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def main() -> None:
    for line in sys.stdin:
        try:
            message = json.loads(line)
            response = _handle(message)
            if response is not None:
                sys.stdout.write(json.dumps(response) + "\n")
                sys.stdout.flush()
        except (json.JSONDecodeError, TypeError) as error:
            sys.stdout.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": str(error)},
                    }
                )
                + "\n"
            )
            sys.stdout.flush()


if __name__ == "__main__":
    main()
