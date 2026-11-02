"""Normalize raw Connector Poll events without assuming connector SDK models."""

import json
from typing import Any, Iterable, List


def _decode_json(value: Any) -> Any:
    if not isinstance(value, str):
        return value

    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return None


def normalize_poll_payloads(payloads: Iterable[str]) -> List[Any]:
    items: List[Any] = []

    for payload in payloads:
        event = _decode_json(payload)
        if not isinstance(event, dict):
            continue

        outputs = event.get("outputs")
        if not isinstance(outputs, dict):
            continue

        body = _decode_json(outputs.get("body"))
        if body is None:
            continue

        if isinstance(body, dict) and isinstance(body.get("value"), list):
            items.extend(body["value"])
        elif isinstance(body, list):
            items.extend(body)
        else:
            items.append(body)

    return items
