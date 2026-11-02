import ast
import importlib.util
import json
import os
from pathlib import Path
import shutil
import unittest
import uuid


REPO_ROOT = Path(__file__).resolve().parents[1]

OPERATIONS = (
    {
        "app": "office365App",
        "operation_id": "OnNewEmailV3",
        "function_name": "OnNewEmail",
        "connector_name": "office365",
        "parameters": [
            {"name": "folderPath", "value": "Inbox"},
            {"name": "importance", "value": "High"},
        ],
    },
    {
        "app": "office365App",
        "operation_id": "OnFlaggedEmailV4",
        "function_name": "OnFlaggedEmail",
        "connector_name": "office365",
        "parameters": [{"name": "folderPath", "value": "Inbox"}],
    },
    {
        "app": "office365App",
        "operation_id": "OnNewMentionMeEmailV3",
        "function_name": "OnNewMentionMeEmail",
        "connector_name": "office365",
        "parameters": [{"name": "folderPath", "value": "Inbox"}],
    },
    {
        "app": "office365App",
        "operation_id": "CalendarGetOnNewItemsV3",
        "function_name": "OnNewCalendarEvent",
        "connector_name": "office365",
        "parameters": [{"name": "table", "value": "Calendar"}],
    },
    {
        "app": "office365App",
        "operation_id": "OnUpcomingEventsV3",
        "function_name": "OnUpcomingEvent",
        "connector_name": "office365",
        "parameters": [{"name": "table", "value": "Calendar"}],
    },
    {
        "app": "sharepointApp",
        "operation_id": "GetOnNewFileItems",
        "function_name": "OnSharepointNewFile",
        "connector_name": "sharepointonline",
        "parameters": [
            {"name": "dataset", "azdOutput": "sharepointSiteUrl"},
            {"name": "table", "azdOutput": "sharepointLibraryName"},
        ],
    },
    {
        "app": "sharepointApp",
        "operation_id": "GetOnUpdatedFileItems",
        "function_name": "OnSharepointUpdatedFile",
        "connector_name": "sharepointonline",
        "parameters": [
            {"name": "dataset", "azdOutput": "sharepointSiteUrl"},
            {"name": "table", "azdOutput": "sharepointLibraryName"},
        ],
    },
)


def load_module(path: Path, prefix: str):
    module_name = f"{prefix}_{uuid.uuid4().hex}"
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"Unable to import {path}.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def dotted_name(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{dotted_name(node.value)}.{node.attr}"
    raise AssertionError(f"Expected a dotted name, got {ast.dump(node)}.")


def keyword_map(call: ast.Call) -> dict[str, ast.AST]:
    return {keyword.arg: keyword.value for keyword in call.keywords if keyword.arg}


class OperationOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work_root = (
            REPO_ROOT
            / f".ow-{os.getpid()}-{uuid.uuid4().hex[:8]}"
        )
        cls.work_root.mkdir(parents=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work_root, ignore_errors=True)

    def test_owned_paths_are_complete_and_non_overlapping(self):
        expected = {
            (operation["app"], operation["operation_id"])
            for operation in OPERATIONS
        }
        actual = {
            (path.parents[2].name, path.parent.name)
            for path in REPO_ROOT.glob(
                "*/operations/*/trigger-config.json"
            )
        }
        self.assertEqual(expected, actual)

        owned_paths = [
            REPO_ROOT
            / operation["app"]
            / "operations"
            / operation["operation_id"]
            for operation in OPERATIONS
        ]
        self.assertEqual(len(owned_paths), len(set(owned_paths)))
        for owned_path in owned_paths:
            self.assertEqual(
                {"function.py", "trigger-config.json"},
                {
                    path.name
                    for path in owned_path.iterdir()
                    if path.name != "__pycache__"
                },
            )

    def test_every_mapping_copies_and_prunes_to_one_exact_operation(self):
        for index, operation in enumerate(OPERATIONS):
            with self.subTest(
                app=operation["app"], operation_id=operation["operation_id"]
            ):
                source_root = REPO_ROOT / operation["app"]
                selected_root = self.work_root / str(index)
                shutil.copytree(source_root, selected_root)

                loader = load_module(
                    selected_root / "shared" / "operation_loader.py",
                    "operation_loader",
                )
                with self.assertRaisesRegex(
                    RuntimeError, "exactly one retained operation descriptor"
                ):
                    loader.discover_selected_operation(selected_root)

                for sibling in (selected_root / "operations").iterdir():
                    if sibling.name != operation["operation_id"]:
                        shutil.rmtree(sibling)

                operation_directories = [
                    path.name
                    for path in (selected_root / "operations").iterdir()
                    if path.is_dir()
                ]
                self.assertEqual(
                    [operation["operation_id"]], operation_directories
                )
                self.assertEqual(
                    1,
                    len(
                        list(
                            selected_root.glob(
                                "operations/**/trigger-config.json"
                            )
                        )
                    ),
                )
                self.assertEqual(
                    selected_root
                    / "operations"
                    / operation["operation_id"],
                    loader.discover_selected_operation(selected_root),
                )

                self.assert_operation_registration(selected_root, operation)
                self.assert_operation_descriptor(selected_root, operation)

                (
                    selected_root
                    / "operations"
                    / operation["operation_id"]
                    / "trigger-config.json"
                ).unlink()
                with self.assertRaisesRegex(
                    RuntimeError, "exactly one retained operation descriptor"
                ):
                    loader.discover_selected_operation(selected_root)

    def assert_operation_registration(self, selected_root, operation):
        source_path = (
            selected_root
            / "operations"
            / operation["operation_id"]
            / "function.py"
        )
        module = ast.parse(source_path.read_text(encoding="utf-8"))
        functions = [
            node for node in module.body if isinstance(node, ast.FunctionDef)
        ]
        self.assertEqual(1, len(functions))
        function = functions[0]
        self.assertEqual("List[str]", ast.unparse(function.args.args[0].annotation))

        decorators = [
            decorator
            for decorator in function.decorator_list
            if isinstance(decorator, ast.Call)
        ]
        function_name = next(
            decorator
            for decorator in decorators
            if dotted_name(decorator.func).endswith(".function_name")
        )
        connector_trigger = next(
            decorator
            for decorator in decorators
            if dotted_name(decorator.func).endswith(".connector_trigger")
        )

        function_name_keywords = keyword_map(function_name)
        self.assertEqual(
            operation["function_name"],
            ast.literal_eval(function_name_keywords["name"]),
        )

        keywords = keyword_map(connector_trigger)
        self.assertEqual("payloads", ast.literal_eval(keywords["arg_name"]))
        self.assertEqual(
            "func.DeliveryMode.POLL", dotted_name(keywords["delivery_mode"])
        )
        self.assertEqual(
            "ConnectorNamespace", ast.literal_eval(keywords["connection"])
        )
        self.assertEqual(
            "%ConnectorTriggerConfigName%",
            ast.literal_eval(keywords["trigger_config_name"]),
        )
        self.assertEqual(
            "func.Cardinality.MANY", dotted_name(keywords["cardinality"])
        )
        self.assertEqual(4, ast.literal_eval(keywords["max_batch_size"]))
        self.assertEqual(
            16,
            ast.literal_eval(keywords["target_pending_event_threshold"]),
        )
        self.assertNotIn("max_concurrent_calls", keywords)

    def assert_operation_descriptor(self, selected_root, operation):
        descriptor_path = (
            selected_root
            / "operations"
            / operation["operation_id"]
            / "trigger-config.json"
        )
        descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
        self.assertEqual(
            {
                "functionName",
                "connectorName",
                "operationName",
                "description",
                "parameters",
            },
            set(descriptor),
        )
        self.assertEqual(
            operation["function_name"], descriptor["functionName"]
        )
        self.assertEqual(
            operation["connector_name"], descriptor["connectorName"]
        )
        self.assertEqual(
            operation["operation_id"], descriptor["operationName"]
        )
        self.assertTrue(descriptor["description"])
        self.assertEqual(operation["parameters"], descriptor["parameters"])

    def test_shared_composition_and_deployment_are_operation_neutral(self):
        forbidden = {
            value
            for operation in OPERATIONS
            for value in (
                operation["operation_id"],
                operation["function_name"],
            )
        }
        for app_name in ("office365App", "sharepointApp"):
            app_root = REPO_ROOT / app_name
            shared_paths = [
                app_root / "function_app.py",
                *sorted((app_root / "shared").glob("*.py")),
                app_root / "infra" / "scripts" / "postdeploy.ps1",
                app_root / "infra" / "scripts" / "postdeploy.sh",
            ]
            shared_text = "\n".join(
                path.read_text(encoding="utf-8") for path in shared_paths
            )
            for value in forbidden:
                self.assertNotIn(value, shared_text)

            for legacy_webhook_value in (
                "callbackUrl",
                "notificationDetails",
                "connector_extension",
                "/runtime/webhooks/connector",
            ):
                self.assertNotIn(legacy_webhook_value, shared_text)

            self.assertIn("2026-05-01-preview", shared_text)
            self.assertIn("deliveryMode", shared_text)
            self.assertIn("'Poll'", shared_text)
            self.assertIn(
                "ConnectorNamespace__pollingEndpoint", shared_text
            )
            self.assertIn("ConnectorTriggerConfigName", shared_text)
            self.assertIn("azdOutput", shared_text)
            self.assertIn("--method put", shared_text)

            self.assertIn(
                "-Recurse",
                (
                    app_root / "infra" / "scripts" / "postdeploy.ps1"
                ).read_text(encoding="utf-8"),
            )
            self.assertIn(
                "find \"${OPERATION_ROOT}\" -type f",
                (
                    app_root / "infra" / "scripts" / "postdeploy.sh"
                ).read_text(encoding="utf-8"),
            )

        for filename in ("postdeploy.ps1", "postdeploy.sh"):
            self.assertEqual(
                (
                    REPO_ROOT
                    / "office365App"
                    / "infra"
                    / "scripts"
                    / filename
                ).read_bytes(),
                (
                    REPO_ROOT
                    / "sharepointApp"
                    / "infra"
                    / "scripts"
                    / filename
                ).read_bytes(),
            )

    def test_raw_poll_payload_normalizer_safely_unwraps_outputs_body(self):
        payloads = [
            json.dumps(
                {"outputs": {"body": {"value": [{"id": 1}, {"id": 2}]}}}
            ),
            json.dumps({"outputs": {"body": {"id": 3}}}),
            json.dumps(
                {
                    "outputs": {
                        "body": json.dumps({"value": [{"id": 4}]})
                    }
                }
            ),
            json.dumps({"outputs": {"body": [{"id": 5}]}}),
            "{not-json",
            json.dumps({"outputs": None}),
            json.dumps({"outputs": {"body": None}}),
        ]
        expected = [
            {"id": 1},
            {"id": 2},
            {"id": 3},
            {"id": 4},
            {"id": 5},
        ]

        for app_name in ("office365App", "sharepointApp"):
            with self.subTest(app=app_name):
                module = load_module(
                    REPO_ROOT
                    / app_name
                    / "shared"
                    / "poll_payload.py",
                    "poll_payload",
                )
                self.assertEqual(
                    expected, module.normalize_poll_payloads(payloads)
                )

    def test_deployment_helper_resolves_values_and_polling_endpoints(self):
        outputs = {
            "sharepointSiteUrl": "https://example.sharepoint.com/sites/demo",
            "sharepointLibraryName": "Documents",
        }
        cases = (
            (
                "office365App",
                "OnNewEmailV3",
                [
                    {"name": "folderPath", "value": "Inbox"},
                    {"name": "importance", "value": "High"},
                ],
            ),
            (
                "sharepointApp",
                "GetOnNewFileItems",
                [
                    {
                        "name": "dataset",
                        "value": outputs["sharepointSiteUrl"],
                    },
                    {
                        "name": "table",
                        "value": outputs["sharepointLibraryName"],
                    },
                ],
            ),
        )
        endpoint_cases = (
            (
                "https://namespace.example/api/triggerConfigs/name/receive"
                "?ignored=true",
                "https://namespace.example",
            ),
            (
                "https://scale.example:8443/api/connectorGateways/gateway-id/"
                "triggerConfigs/name/receive",
                "https://scale.example:8443/api/connectorGateways/gateway-id",
            ),
        )

        for app_name, operation_id, expected_parameters in cases:
            with self.subTest(app=app_name, operation_id=operation_id):
                module = load_module(
                    REPO_ROOT
                    / app_name
                    / "shared"
                    / "deployment_config.py",
                    "deployment_config",
                )
                resolved = module.resolve_descriptor(
                    REPO_ROOT
                    / app_name
                    / "operations"
                    / operation_id
                    / "trigger-config.json",
                    outputs,
                )
                self.assertEqual(expected_parameters, resolved["parameters"])

                request_body = module.build_request_body(
                    resolved, "connection-name"
                )
                properties = request_body["properties"]
                self.assertEqual("Poll", properties["deliveryMode"])
                self.assertEqual("Enabled", properties["state"])
                self.assertNotIn("notificationDetails", properties)

                for receive_uri, expected_endpoint in endpoint_cases:
                    self.assertEqual(
                        expected_endpoint,
                        module.polling_endpoint(
                            {
                                "properties": {
                                    "pollingEndpoints": {
                                        "receiveUri": receive_uri
                                    }
                                }
                            }
                        ),
                    )

    def test_poll_runtime_and_identity_configuration(self):
        for app_name in ("office365App", "sharepointApp"):
            with self.subTest(app=app_name):
                app_root = REPO_ROOT / app_name
                requirements = (
                    app_root / "requirements.txt"
                ).read_text(encoding="utf-8")
                self.assertIn("azure-functions>=2.4.0b1", requirements)
                self.assertNotIn(
                    "azurefunctions-extensions-connectors", requirements
                )

                host = json.loads(
                    (app_root / "host.json").read_text(encoding="utf-8")
                )
                self.assertEqual(
                    "[4.42.0, 5.0.0)",
                    host["extensionBundle"]["version"],
                )

                settings = json.loads(
                    (app_root / "local.settings.json").read_text(
                        encoding="utf-8"
                    )
                )["Values"]
                self.assertIn(
                    "ConnectorNamespace__pollingEndpoint", settings
                )
                self.assertIn("ConnectorTriggerConfigName", settings)

                main_bicep = (
                    app_root / "infra" / "main.bicep"
                ).read_text(encoding="utf-8")
                self.assertIn("version: '3.13'", main_bicep)
                self.assertIn(
                    "ConnectorNamespace__credential: 'managedidentity'",
                    main_bicep,
                )
                self.assertIn(
                    "ConnectorNamespace__clientId", main_bicep
                )

                namespace_bicep = (
                    app_root / "infra" / "connectorNamespace.bicep"
                ).read_text(encoding="utf-8")
                self.assertGreaterEqual(
                    namespace_bicep.count(
                        "connections/accessPolicies@2026-05-01-preview"
                    ),
                    3,
                )
                self.assertIn("functionAppPrincipalId", namespace_bicep)
                self.assertIn(
                    "connectorNamespace.identity.principalId",
                    namespace_bicep,
                )
                self.assertIn("userPrincipalId", namespace_bicep)


if __name__ == "__main__":
    unittest.main()
