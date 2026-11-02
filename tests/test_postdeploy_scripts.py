import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell.exe") or shutil.which("pwsh")
BASH = shutil.which("bash")


FAKE_CLI = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path


def load_state():
    path = Path(os.environ["FAKE_STATE"])
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    state = {
        "consented": os.environ.get("FAKE_OAUTH_REQUIRED") != "1",
        "triggers": [item for item in os.environ.get("FAKE_EXISTING_TRIGGERS", "").split(",") if item],
    }
    path.write_text(json.dumps(state), encoding="utf-8")
    return state


def save_state(state):
    Path(os.environ["FAKE_STATE"]).write_text(json.dumps(state), encoding="utf-8")


def argument_value(args, name):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None


tool = sys.argv[1]
args = sys.argv[2:]
extra = {}
if tool == "az" and args[:3] == ["connector-namespace", "trigger", "create"]:
    notification = argument_value(args, "--notification-details")
    if notification and notification.startswith("@"):
        extra["notification"] = json.loads(Path(notification[1:]).read_text(encoding="utf-8"))
with Path(os.environ["FAKE_LOG"]).open("a", encoding="utf-8") as log_file:
    log_file.write(json.dumps({"tool": tool, "args": args, **extra}) + "\n")

if tool == "azd":
    if args[:3] == ["env", "get-values", "--output"]:
        print(os.environ["FAKE_OUTPUTS"])
        raise SystemExit(0)
    print("unsupported azd command", file=sys.stderr)
    raise SystemExit(2)

if args[:2] == ["extension", "show"]:
    print("connector-namespace")
    raise SystemExit(0)

state = load_state()
if args[:3] == ["connector-namespace", "connection", "show"]:
    print("Connected" if state["consented"] else "NotConnected")
    raise SystemExit(0)
if args[:3] == ["connector-namespace", "connection", "list-consent-links"]:
    state["consented"] = True
    save_state(state)
    print("https://login.example.test/consent")
    raise SystemExit(0)
if args[:3] == ["functionapp", "keys", "list"]:
    print("connector-key")
    raise SystemExit(0)
if args[:3] == ["connector-namespace", "trigger", "list"]:
    print("\n".join(state["triggers"]))
    raise SystemExit(0)
if args[:3] == ["connector-namespace", "trigger", "delete"]:
    trigger_name = argument_value(args, "-n")
    state["triggers"] = [item for item in state["triggers"] if item != trigger_name]
    save_state(state)
    raise SystemExit(0)
if args[:3] == ["connector-namespace", "trigger", "create"]:
    operation_id = argument_value(args, "--operation-name")
    if operation_id == os.environ.get("FAKE_FAIL_OPERATION"):
        print(f"simulated create failure for {operation_id}", file=sys.stderr)
        raise SystemExit(1)
    trigger_name = argument_value(args, "-n")
    if trigger_name not in state["triggers"]:
        state["triggers"].append(trigger_name)
        save_state(state)
    print("Succeeded")
    raise SystemExit(0)
if args[:3] == ["connector-namespace", "trigger", "show"]:
    trigger_name = argument_value(args, "-n")
    if trigger_name in state["triggers"]:
        print("Succeeded")
        raise SystemExit(0)
    print("trigger not found", file=sys.stderr)
    raise SystemExit(1)

print("unsupported az command: " + " ".join(args), file=sys.stderr)
raise SystemExit(2)
'''


FAKE_JQ = r'''#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

args = sys.argv[1:]
flags = set()
variables = {}
json_variables = {}
positionals = []
i = 0
while i < len(args):
    arg = args[i]
    if arg.startswith("-") and not arg.startswith("--"):
        flags.update(arg[1:])
        i += 1
    elif arg == "--arg":
        variables[args[i + 1]] = args[i + 2]
        i += 3
    elif arg == "--argjson":
        json_variables[args[i + 1]] = json.loads(args[i + 2])
        i += 3
    else:
        positionals.append(arg)
        i += 1

filter_text = positionals[0] if positionals else ""
file_names = positionals[1:]
if "n" in flags:
    data = None
elif file_names:
    data = json.loads(Path(file_names[0]).read_text(encoding="utf-8"))
else:
    raw_input = sys.stdin.read()
    data = json.loads(raw_input) if raw_input.strip() else None


def emit(value):
    if "r" in flags and isinstance(value, str):
        print(value)
    elif "c" in flags:
        print(json.dumps(value, separators=(",", ":")))
    else:
        print(json.dumps(value))


def nonempty_string(value):
    return isinstance(value, str) and bool(value) and value != "null"

if "n" in flags:
    if "callback_url" in variables:
        emit({
            "callbackUrl": variables["callback_url"],
            "authentication": {"type": "QueryString", "name": "code", "value": variables["connector_key"]},
        })
    elif "connection_name" in variables:
        emit({"connectionName": variables["connection_name"], "connectorName": variables["connector_name"]})
    elif "function_app_name" in variables:
        emit({
            "destinationType": "functionApp",
            "functionAppName": variables["function_app_name"],
            "functionAppResourceGroup": variables["resource_group_name"],
            "functionAppSubscriptionId": variables["subscription_id"],
            "functionName": variables["function_name"],
            "recurrenceFrequency": "Minute",
            "recurrenceInterval": "5",
        })
    else:
        raise SystemExit(2)
    raise SystemExit(0)

if "operation_directory" in variables:
    valid = isinstance(data, dict)
    connector_name = data.get("connectorName") if valid else None
    operation_id = data.get("operationId") if valid else None
    function_name = data.get("functionName") if valid else None
    description = data.get("description") if valid else None
    parameters = data.get("parameters") if valid else None
    valid = (
        valid
        and nonempty_string(connector_name)
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", connector_name) is not None
        and operation_id == variables["operation_directory"]
        and nonempty_string(function_name)
        and re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", function_name) is not None
        and nonempty_string(description)
        and isinstance(parameters, list)
    )
    if valid:
        names = []
        for parameter in parameters:
            if not isinstance(parameter, dict) or not nonempty_string(parameter.get("name")):
                valid = False
                break
            has_value = "value" in parameter
            has_value_from = "valueFrom" in parameter
            selected = parameter.get("value") if has_value else parameter.get("valueFrom")
            if has_value == has_value_from or not nonempty_string(selected):
                valid = False
                break
            names.append(parameter["name"])
        valid = valid and len(names) == len(set(names))
    print("true" if valid else "false")
    raise SystemExit(0 if valid else 1)

stripped = filter_text.strip()
if stripped in {".connectorName", ".operationId", ".functionName", ".description"}:
    emit(data[stripped[1:]])
    raise SystemExit(0)
if "type == \"object\"" in filter_text:
    valid = isinstance(data, dict)
    print("true" if valid else "false")
    raise SystemExit(0 if valid else 1)
if "output_name" in variables:
    value = data.get(variables["output_name"]) if isinstance(data, dict) else None
    if nonempty_string(value):
        emit(value)
        raise SystemExit(0)
    raise SystemExit(1 if "e" in flags else 0)
if "outputs" in json_variables:
    outputs = json_variables["outputs"]
    resolved = []
    for parameter in data["parameters"]:
        if "value" in parameter:
            value = parameter["value"]
        else:
            value = outputs.get(parameter["valueFrom"])
            if not nonempty_string(value):
                print("missing valueFrom output", file=sys.stderr)
                raise SystemExit(1)
        resolved.append({"name": parameter["name"], "value": value})
    emit(resolved)
    raise SystemExit(0)

print("unsupported jq invocation", file=sys.stderr)
raise SystemExit(2)
'''


class PostdeployScriptTests(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.temp_context = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.temp_root = Path(self.temp_context.name)
        self.bin_dir = self.temp_root / "bin"
        self.bin_dir.mkdir()
        self.log_path = self.temp_root / "cli-log.jsonl"
        self.state_path = self.temp_root / "cli-state.json"
        self._write_fake_tools()

    def tearDown(self):
        self.temp_context.cleanup()

    def _write_executable(self, path, content):
        path.write_text(content, encoding="utf-8", newline="\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def _write_fake_tools(self):
        fake_cli = self.temp_root / "fake_cli.py"
        fake_cli.write_text(FAKE_CLI, encoding="utf-8", newline="\n")
        fake_jq = self.temp_root / "fake_jq.py"
        fake_jq.write_text(FAKE_JQ, encoding="utf-8", newline="\n")

        python_path = Path(sys.executable).as_posix()
        cli_path = fake_cli.as_posix()
        jq_path = fake_jq.as_posix()
        self._write_executable(
            self.bin_dir / "jq",
            f'#!/usr/bin/env bash\nexec "{python_path}" "{jq_path}" "$@"\n',
        )
        for tool in ("az", "azd"):
            self._write_executable(
                self.bin_dir / tool,
                f'#!/usr/bin/env bash\nexec "{python_path}" "{cli_path}" {tool} "$@"\n',
            )
            (self.bin_dir / f"{tool}.cmd").write_text(
                f'@echo off\r\n"{sys.executable}" "{fake_cli}" {tool} %*\r\n',
                encoding="utf-8",
                newline="",
            )
        self._write_executable(self.bin_dir / "sleep", "#!/usr/bin/env bash\nexit 0\n")
        self._write_executable(self.bin_dir / "xdg-open", "#!/usr/bin/env bash\nexit 0\n")

    def _materialize_app(self, app_name, operation_ids, script_name):
        app_root = self.temp_root / app_name
        scripts_dir = app_root / "infra" / "scripts"
        scripts_dir.mkdir(parents=True)
        shutil.copy2(ROOT / app_name / "infra" / "scripts" / script_name, scripts_dir / script_name)
        for operation_id in operation_ids:
            source = ROOT / app_name / "operations" / operation_id
            destination = app_root / "operations" / operation_id
            destination.mkdir(parents=True)
            shutil.copy2(source / "function.py", destination / "function.py")
            shutil.copy2(source / "trigger-config.json", destination / "trigger-config.json")
        return app_root

    def _environment(self, **overrides):
        outputs = {
            "resourceGroupName": "sample-rg",
            "connectorNamespaceName": "sample-namespace",
            "connectorNamespaceConnectionName": "sample-connection",
            "functionAppName": "sample-function",
            "functionAppDefaultHostname": "sample-function.azurewebsites.example",
            "AZURE_SUBSCRIPTION_ID": "00000000-0000-0000-0000-000000000000",
            "sharepointSiteUrl": "https://contoso.sharepoint.com/sites/sample",
            "sharepointLibraryName": "Documents",
        }
        environment = os.environ.copy()
        environment.update({
            "PATH": str(self.bin_dir) + os.pathsep + environment.get("PATH", ""),
            "FAKE_LOG": str(self.log_path),
            "FAKE_STATE": str(self.state_path),
            "FAKE_OUTPUTS": json.dumps(outputs),
            "FAKE_OAUTH_REQUIRED": "0",
            "FAKE_EXISTING_TRIGGERS": "",
            "FAKE_FAIL_OPERATION": "",
        })
        environment.update(overrides)
        return environment

    def _events(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]

    def _run_powershell(self, script_path, environment):
        if POWERSHELL is None:
            self.skipTest("PowerShell is unavailable")
        wrapper = self.temp_root / "run-postdeploy.ps1"
        wrapper.write_text(
            textwrap.dedent(
                f"""
                function global:Start-Sleep {{ param([int] $Seconds) }}
                function global:Start-Process {{ param([string] $FilePath) }}
                & '{script_path}'
                """
            ),
            encoding="utf-8",
            newline="\n",
        )
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(wrapper)],
            cwd=self.temp_root,
            env=environment,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def _run_bash(self, script_path, environment):
        if BASH is None:
            self.skipTest("Bash is unavailable")
        return subprocess.run(
            [BASH, script_path.as_posix()],
            cwd=self.temp_root,
            env=environment,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_powershell_authorizes_before_configuring_and_resolves_value_from(self):
        app_root = self._materialize_app(
            "sharepointApp",
            ["GetOnNewFileItems"],
            "postdeploy.ps1",
        )
        environment = self._environment(
            FAKE_OAUTH_REQUIRED="1",
            FAKE_EXISTING_TRIGGERS="sample-connection-onsharepointnewfile",
        )
        result = self._run_powershell(app_root / "infra" / "scripts" / "postdeploy.ps1", environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self._events()
        commands = [event["args"][:3] for event in events if event["tool"] == "az"]
        consent_index = commands.index(["connector-namespace", "connection", "list-consent-links"])
        create_index = commands.index(["connector-namespace", "trigger", "create"])
        self.assertLess(consent_index, create_index)

        create_event = next(event for event in events if event["args"][:3] == ["connector-namespace", "trigger", "create"])
        parameters = create_event["args"][create_event["args"].index("--parameters") + 1]
        self.assertIn("https://contoso.sharepoint.com/sites/sample", parameters)
        self.assertEqual(
            create_event["notification"]["callbackUrl"],
            "https://sample-function.azurewebsites.example/runtime/webhooks/connector?functionName=OnSharepointNewFile",
        )
        self.assertFalse(list((app_root / "infra" / "scripts").glob(".notification-details-*.json")))

    def test_bash_runs_oauth_and_config_driven_trigger_creation(self):
        app_root = self._materialize_app("office365App", ["OnNewEmailV3"], "postdeploy.sh")
        result = self._run_bash(
            app_root / "infra" / "scripts" / "postdeploy.sh",
            self._environment(FAKE_OAUTH_REQUIRED="1"),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = self._events()
        commands = [event["args"][:3] for event in events if event["tool"] == "az"]
        self.assertLess(
            commands.index(["connector-namespace", "connection", "list-consent-links"]),
            commands.index(["connector-namespace", "trigger", "create"]),
        )
        create_event = next(event for event in events if event["args"][:3] == ["connector-namespace", "trigger", "create"])
        self.assertIn("OnNewEmailV3", create_event["args"])
        self.assertEqual(
            create_event["notification"]["authentication"],
            {"type": "QueryString", "name": "code", "value": "connector-key"},
        )

    def test_powershell_reports_partial_failure_and_continues(self):
        operation_ids = ["CalendarGetOnNewItemsV3", "OnFlaggedEmailV4"]
        app_root = self._materialize_app("office365App", operation_ids, "postdeploy.ps1")
        result = self._run_powershell(
            app_root / "infra" / "scripts" / "postdeploy.ps1",
            self._environment(FAKE_FAIL_OPERATION="CalendarGetOnNewItemsV3"),
        )
        combined = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, combined)
        self.assertIn("Configured 1 of 2 retained trigger config(s).", combined)
        self.assertIn("CalendarGetOnNewItemsV3", combined)
        events = self._events()
        create_operations = [
            event["args"][event["args"].index("--operation-name") + 1]
            for event in events
            if event["args"][:3] == ["connector-namespace", "trigger", "create"]
        ]
        self.assertEqual(create_operations.count("CalendarGetOnNewItemsV3"), 3)
        self.assertIn("OnFlaggedEmailV4", create_operations)

    def test_powershell_rejects_directory_operation_mismatch_before_azd_or_mutation(self):
        app_root = self._materialize_app("office365App", ["OnNewEmailV3"], "postdeploy.ps1")
        config_path = app_root / "operations" / "OnNewEmailV3" / "trigger-config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["operationId"] = "DifferentOperation"
        config_path.write_text(json.dumps(config), encoding="utf-8", newline="\n")

        result = self._run_powershell(
            app_root / "infra" / "scripts" / "postdeploy.ps1",
            self._environment(),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exactly match directory", result.stdout + result.stderr)
        events = self._events()
        self.assertFalse(any(event["tool"] == "azd" for event in events))
        self.assertFalse(any(event["args"][:2] == ["connector-namespace", "trigger"] for event in events))

    def test_app_script_copies_remain_identical(self):
        for script_name in ("postdeploy.ps1", "postdeploy.sh"):
            self.assertEqual(
                (ROOT / "office365App" / "infra" / "scripts" / script_name).read_bytes(),
                (ROOT / "sharepointApp" / "infra" / "scripts" / script_name).read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()
