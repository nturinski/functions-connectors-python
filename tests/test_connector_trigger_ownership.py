import ast
import importlib.util
import json
import shutil
import sys
import tempfile
import types
import unittest
from contextlib import contextmanager
from pathlib import Path
from pathlib import PurePosixPath


ROOT = Path(__file__).resolve().parents[1]

MAPPINGS = {
    "office365App": [
        ("OnNewEmailV3", "OnNewEmail"),
        ("OnFlaggedEmailV4", "OnFlaggedEmail"),
        ("OnNewMentionMeEmailV3", "OnNewMentionMeEmail"),
        ("CalendarGetOnNewItemsV3", "OnNewCalendarEvent"),
        ("OnUpcomingEventsV3", "OnUpcomingEvent"),
    ],
    "sharepointApp": [
        ("GetOnNewFileItems", "OnSharepointNewFile"),
        ("GetOnUpdatedFileItems", "OnSharepointUpdatedFile"),
    ],
}

EXPECTED_CONFIGS = {
    "office365App": {
        "OnNewEmailV3": {
            "connectorName": "office365",
            "operationId": "OnNewEmailV3",
            "functionName": "OnNewEmail",
            "description": "When a new email arrives",
            "parameters": [
                {"name": "folderPath", "value": "Inbox"},
                {"name": "importance", "value": "High"},
            ],
        },
        "OnFlaggedEmailV4": {
            "connectorName": "office365",
            "operationId": "OnFlaggedEmailV4",
            "functionName": "OnFlaggedEmail",
            "description": "When an email is flagged",
            "parameters": [{"name": "folderPath", "value": "Inbox"}],
        },
        "OnNewMentionMeEmailV3": {
            "connectorName": "office365",
            "operationId": "OnNewMentionMeEmailV3",
            "functionName": "OnNewMentionMeEmail",
            "description": "When a new email mentioning me arrives",
            "parameters": [{"name": "folderPath", "value": "Inbox"}],
        },
        "CalendarGetOnNewItemsV3": {
            "connectorName": "office365",
            "operationId": "CalendarGetOnNewItemsV3",
            "functionName": "OnNewCalendarEvent",
            "description": "When a new calendar event is created",
            "parameters": [{"name": "table", "value": "Calendar"}],
        },
        "OnUpcomingEventsV3": {
            "connectorName": "office365",
            "operationId": "OnUpcomingEventsV3",
            "functionName": "OnUpcomingEvent",
            "description": "When an upcoming event is starting soon",
            "parameters": [{"name": "table", "value": "Calendar"}],
        },
    },
    "sharepointApp": {
        "GetOnNewFileItems": {
            "connectorName": "sharepointonline",
            "operationId": "GetOnNewFileItems",
            "functionName": "OnSharepointNewFile",
            "description": "When a file is created (properties only)",
            "parameters": [
                {"name": "dataset", "valueFrom": "sharepointSiteUrl"},
                {"name": "table", "valueFrom": "sharepointLibraryName"},
            ],
        },
        "GetOnUpdatedFileItems": {
            "connectorName": "sharepointonline",
            "operationId": "GetOnUpdatedFileItems",
            "functionName": "OnSharepointUpdatedFile",
            "description": "When a file is created or modified (properties only)",
            "parameters": [
                {"name": "dataset", "valueFrom": "sharepointSiteUrl"},
                {"name": "table", "valueFrom": "sharepointLibraryName"},
            ],
        },
    },
}


class FakeBlueprint:
    def __init__(self):
        self.functions = []

    def function_name(self, *, name):
        def decorator(function):
            function._fake_function_name = name
            self.functions.append(function)
            return function

        return decorator

    def connector_trigger(self, **kwargs):
        def decorator(function):
            function._fake_connector_trigger = kwargs
            return function

        return decorator


class FakeFunctionApp:
    def __init__(self):
        self.blueprints = []

    def register_functions(self, blueprint):
        self.blueprints.append(blueprint)


@contextmanager
def fake_azure_runtime():
    originals = {}

    def install(name, module):
        originals[name] = sys.modules.get(name)
        sys.modules[name] = module

    azure = types.ModuleType("azure")
    azure.__path__ = []
    functions = types.ModuleType("azure.functions")
    functions.Blueprint = FakeBlueprint
    functions.FunctionApp = FakeFunctionApp
    azure.functions = functions
    install("azure", azure)
    install("azure.functions", functions)

    azurefunctions = types.ModuleType("azurefunctions")
    azurefunctions.__path__ = []
    extensions = types.ModuleType("azurefunctions.extensions")
    extensions.__path__ = []
    connectors = types.ModuleType("azurefunctions.extensions.connectors")
    connectors.__path__ = []
    office365 = types.ModuleType("azurefunctions.extensions.connectors.office365")
    office365.ClientReceiveMessage = type("ClientReceiveMessage", (), {})
    office365.GraphClientReceiveMessage = type("GraphClientReceiveMessage", (), {})
    office365.GraphCalendarEventClientReceive = type("GraphCalendarEventClientReceive", (), {})
    connectors.office365 = office365
    extensions.connectors = connectors
    azurefunctions.extensions = extensions
    install("azurefunctions", azurefunctions)
    install("azurefunctions.extensions", extensions)
    install("azurefunctions.extensions.connectors", connectors)
    install("azurefunctions.extensions.connectors.office365", office365)

    try:
        yield
    finally:
        dynamic_modules = [name for name in sys.modules if name.startswith("_connector_operation_")]
        for name in dynamic_modules:
            sys.modules.pop(name, None)
        for name, original in originals.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original


def load_materialized_app(app_root):
    module_name = f"materialized_{app_root.name}_{id(app_root)}"
    spec = importlib.util.spec_from_file_location(module_name, app_root / "function_app.py")
    if spec is None or spec.loader is None:
        raise AssertionError("materialized function_app.py did not produce an import spec")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        sys.modules.pop(module_name, None)


class ConnectorTriggerOwnershipTests(unittest.TestCase):
    def test_metadata_contract_mappings_and_owned_paths(self):
        metadata = json.loads((ROOT / "template-metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(set(metadata), {"templates"})
        self.assertEqual(len(metadata["templates"]), len(MAPPINGS))

        seen_paths = set()
        for template in metadata["templates"]:
            app_name = template["folderPath"]
            self.assertIn(app_name, MAPPINGS)
            operations = template["connectorTrigger"]["operations"]
            expected = MAPPINGS[app_name]
            self.assertEqual(
                [(entry["operationId"], entry["functionName"]) for entry in operations],
                expected,
            )

            app_paths = set()
            for entry in operations:
                self.assertEqual(set(entry), {"operationId", "functionName", "ownedPaths"})
                operation_id = entry["operationId"]
                function_name = entry["functionName"]
                self.assertIn((operation_id, function_name), expected)
                self.assertEqual(len(entry["ownedPaths"]), 1)
                owned_path = entry["ownedPaths"][0]
                self.assertEqual(owned_path, PurePosixPath(owned_path).as_posix())
                self.assertFalse(PurePosixPath(owned_path).is_absolute())
                self.assertNotIn("\\", owned_path)
                self.assertEqual(owned_path, f"operations/{operation_id}")
                self.assertTrue((ROOT / app_name / Path(*PurePosixPath(owned_path).parts)).is_dir())
                app_paths.add(owned_path)
                self.assertNotIn(owned_path, seen_paths)
                seen_paths.add(owned_path)
            self.assertEqual(len(app_paths), len(expected))

    def test_operation_directories_have_exact_files_and_no_init(self):
        for app_name, mappings in MAPPINGS.items():
            for operation_id, _ in mappings:
                operation_dir = ROOT / app_name / "operations" / operation_id
                actual_files = {path.name for path in operation_dir.iterdir() if path.name != "__pycache__"}
                self.assertEqual(actual_files, {"function.py", "trigger-config.json"})
                self.assertFalse((operation_dir / "__init__.py").exists())

    def test_trigger_configs_are_exact_and_parameters_are_structured(self):
        for app_name, expected_configs in EXPECTED_CONFIGS.items():
            for operation_id, expected in expected_configs.items():
                config_path = ROOT / app_name / "operations" / operation_id / "trigger-config.json"
                config = json.loads(config_path.read_text(encoding="utf-8"))
                self.assertEqual(config, expected)
                self.assertEqual(
                    set(config),
                    {"connectorName", "operationId", "functionName", "description", "parameters"},
                )
                for parameter in config["parameters"]:
                    self.assertEqual(
                        set(parameter) & {"value", "valueFrom"},
                        {"value"} if "value" in parameter else {"valueFrom"},
                    )
                    self.assertTrue(parameter["name"])
                    self.assertTrue(parameter.get("value", parameter.get("valueFrom")))

    def test_operation_artifacts_compile_and_register_one_matching_function(self):
        for app_name, mappings in MAPPINGS.items():
            for operation_id, function_name in mappings:
                operation_path = ROOT / app_name / "operations" / operation_id / "function.py"
                source = operation_path.read_text(encoding="utf-8")
                compile(source, str(operation_path), "exec")
                tree = ast.parse(source, filename=str(operation_path))
                functions = [node for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]
                self.assertEqual(len(functions), 1, operation_path)
                decorated = functions[0]
                function_name_calls = [
                    node for node in decorated.decorator_list
                    if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "blueprint"
                    and node.func.attr == "function_name"
                ]
                connector_trigger_calls = [
                    node for node in decorated.decorator_list
                    if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "blueprint"
                    and node.func.attr == "connector_trigger"
                ]
                self.assertEqual(len(function_name_calls), 1, operation_path)
                self.assertEqual(len(connector_trigger_calls), 1, operation_path)
                self.assertEqual(
                    ast.literal_eval(function_name_calls[0].keywords[0].value),
                    function_name,
                )
                expected_argument = (
                    "emails"
                    if app_name == "office365App" and function_name not in {"OnNewCalendarEvent", "OnUpcomingEvent"}
                    else "events"
                    if app_name == "office365App"
                    else "payload"
                )
                self.assertEqual(
                    ast.literal_eval(connector_trigger_calls[0].keywords[0].value),
                    expected_argument,
                )
                self.assertIn("blueprint = func.Blueprint()", source)

    def test_shared_bootstrap_and_scripts_do_not_hardcode_operations(self):
        for app_name, mappings in MAPPINGS.items():
            shared_paths = [
                ROOT / app_name / "function_app.py",
                ROOT / app_name / "infra" / "scripts" / "postdeploy.ps1",
                ROOT / app_name / "infra" / "scripts" / "postdeploy.sh",
            ]
            shared_source = "\n".join(path.read_text(encoding="utf-8") for path in shared_paths)
            for operation_id, function_name in mappings:
                self.assertNotIn(operation_id, shared_source)
                self.assertNotIn(function_name, shared_source)
            bootstrap_source = (ROOT / app_name / "function_app.py").read_text(encoding="utf-8")
            self.assertIn("spec_from_file_location", bootstrap_source)
            self.assertIn("register_functions", bootstrap_source)
            for script_name in ("postdeploy.ps1", "postdeploy.sh"):
                script_source = (ROOT / app_name / "infra" / "scripts" / script_name).read_text(encoding="utf-8")
                self.assertIn("trigger-config.json", script_source)
                self.assertIn("valueFrom", script_source)
                self.assertIn("recurrenceFrequency:Minute", script_source)
                self.assertIn("recurrenceInterval:'5'", script_source)
                self.assertIn("connectorName", script_source)

    def test_sparse_materialization_registers_only_selected_operation(self):
        for app_name, mappings in MAPPINGS.items():
            operation_id, function_name = mappings[0]
            with tempfile.TemporaryDirectory(dir=ROOT / "tests") as temp_dir:
                materialized = Path(temp_dir) / app_name
                operation_dir = materialized / "operations" / operation_id
                operation_dir.mkdir(parents=True)
                shutil.copy2(ROOT / app_name / "function_app.py", materialized / "function_app.py")
                for artifact_name in ("function.py", "trigger-config.json"):
                    shutil.copy2(
                        ROOT / app_name / "operations" / operation_id / artifact_name,
                        operation_dir / artifact_name,
                    )
                with fake_azure_runtime():
                    module = load_materialized_app(materialized)
                self.assertEqual(len(module.app.blueprints), 1)
                registered_functions = module.app.blueprints[0].functions
                self.assertEqual(len(registered_functions), 1)
                self.assertEqual(registered_functions[0]._fake_function_name, function_name)
                self.assertTrue(hasattr(registered_functions[0], "_fake_connector_trigger"))

    def test_full_materialization_registers_all_current_operations(self):
        for app_name, mappings in MAPPINGS.items():
            with tempfile.TemporaryDirectory(dir=ROOT / "tests") as temp_dir:
                materialized = Path(temp_dir) / app_name
                materialized.mkdir(parents=True)
                shutil.copy2(ROOT / app_name / "function_app.py", materialized / "function_app.py")
                for operation_id, _ in mappings:
                    operation_dir = materialized / "operations" / operation_id
                    operation_dir.mkdir(parents=True)
                    for artifact_name in ("function.py", "trigger-config.json"):
                        shutil.copy2(
                            ROOT / app_name / "operations" / operation_id / artifact_name,
                            operation_dir / artifact_name,
                        )
                with fake_azure_runtime():
                    module = load_materialized_app(materialized)
                registered_functions = [
                    function
                    for blueprint in module.app.blueprints
                    for function in blueprint.functions
                ]
                expected_function_names = [
                    function_name
                    for _, function_name in sorted(mappings, key=lambda item: item[0])
                ]
                self.assertEqual(
                    [function._fake_function_name for function in registered_functions],
                    expected_function_names,
                )


if __name__ == "__main__":
    unittest.main()
