"""Validate operation descriptors and derive Poll deployment values."""

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any, Dict
from urllib.parse import urlsplit, urlunsplit


def _required_string(data: Dict[str, Any], name: str, source: str) -> str:
    value = data.get(name)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{source} is missing '{name}'.")
    return value


def required_output(outputs: Dict[str, Any], name: str) -> str:
    return _required_string(outputs, name, "azd outputs")


def resolve_descriptor(
    descriptor_path: Path, outputs: Dict[str, Any]
) -> Dict[str, Any]:
    descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
    if not isinstance(descriptor, dict):
        raise ValueError("The retained operation descriptor must be an object.")

    resolved = {
        name: _required_string(descriptor, name, "operation descriptor")
        for name in (
            "functionName",
            "connectorName",
            "operationName",
            "description",
        )
    }

    descriptor_parameters = descriptor.get("parameters", [])
    if not isinstance(descriptor_parameters, list):
        raise ValueError("Operation descriptor parameters must be an array.")

    parameters = []
    for parameter in descriptor_parameters:
        if not isinstance(parameter, dict):
            raise ValueError("Each operation parameter must be an object.")

        parameter_name = _required_string(
            parameter, "name", "operation parameter"
        )
        has_literal = "value" in parameter
        has_azd_output = "azdOutput" in parameter
        if has_literal == has_azd_output:
            raise ValueError(
                f"Parameter '{parameter_name}' must define exactly one "
                "of 'value' or 'azdOutput'."
            )

        if has_literal:
            value = parameter["value"]
        else:
            output_name = _required_string(
                parameter, "azdOutput", "operation parameter"
            )
            value = required_output(outputs, output_name)

        if not isinstance(value, str) or not value.strip():
            raise ValueError(
                f"Parameter '{parameter_name}' resolved to an empty value."
            )
        parameters.append({"name": parameter_name, "value": value})

    resolved["parameters"] = parameters
    return resolved


def build_request_body(
    descriptor: Dict[str, Any], connection_name: str
) -> Dict[str, Any]:
    if not connection_name.strip():
        raise ValueError("The connector connection name is empty.")

    return {
        "properties": {
            "connectionDetails": {
                "connectionName": connection_name,
                "connectorName": descriptor["connectorName"],
            },
            "deliveryMode": "Poll",
            "description": descriptor["description"],
            "operationName": descriptor["operationName"],
            "parameters": descriptor["parameters"],
            "state": "Enabled",
            "type": "NotSpecified",
        }
    }


def polling_endpoint(trigger_config: Dict[str, Any]) -> str:
    try:
        receive_uri = trigger_config["properties"]["pollingEndpoints"][
            "receiveUri"
        ]
    except (KeyError, TypeError) as error:
        raise ValueError(
            "Connector Namespace did not return pollingEndpoints.receiveUri."
        ) from error

    if not isinstance(receive_uri, str) or not receive_uri:
        raise ValueError(
            "Connector Namespace returned an empty polling receive URI."
        )

    parsed = urlsplit(receive_uri)
    if (
        parsed.scheme.lower() != "https"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise ValueError(
            "The service-generated receive URI is not a supported HTTPS endpoint."
        )

    match = re.fullmatch(
        r"(?P<base>/api(?:/connectorGateways/[^/]+)?)/"
        r"triggerConfigs/[^/]+/receive",
        parsed.path,
        flags=re.IGNORECASE,
    )
    if match is None:
        raise ValueError(
            "The service-generated receive URI has an unsupported Poll path."
        )

    base_path = "" if match.group("base").lower() == "/api" else match.group(
        "base"
    )
    return urlunsplit(("https", parsed.netloc, base_path, "", ""))


def _read_json_stdin() -> Dict[str, Any]:
    value = json.load(sys.stdin)
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object.")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("descriptor", type=Path)

    output_parser = subparsers.add_parser("output")
    output_parser.add_argument("name")

    field_parser = subparsers.add_parser("field")
    field_parser.add_argument("name", choices=("functionName",))

    request_parser = subparsers.add_parser("request-body")
    request_parser.add_argument("connection_name")

    subparsers.add_parser("state")
    subparsers.add_parser("polling-endpoint")

    args = parser.parse_args()
    payload = _read_json_stdin()

    if args.command == "resolve":
        result: Any = resolve_descriptor(args.descriptor, payload)
    elif args.command == "output":
        result = required_output(payload, args.name)
    elif args.command == "field":
        result = _required_string(payload, args.name, "resolved descriptor")
    elif args.command == "request-body":
        result = build_request_body(payload, args.connection_name)
    elif args.command == "state":
        result = _required_string(
            payload.get("properties", {}), "state", "Trigger Config response"
        )
    else:
        result = polling_endpoint(payload)

    if isinstance(result, str):
        print(result)
    else:
        print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
