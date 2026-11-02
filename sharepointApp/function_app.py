# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

import azure.functions as func


def _load_operation_blueprints(operations_dir: Path) -> list[object]:
    function_paths = sorted(operations_dir.glob("*/function.py"))
    if not function_paths:
        raise RuntimeError(
            f"No connector operation modules found under {operations_dir}. "
            "Retain at least one operations/<operationId> directory."
        )

    blueprints = []
    failures = []
    for index, function_path in enumerate(function_paths):
        module_name = f"_connector_operation_{index}_{function_path.parent.name}"
        try:
            spec = spec_from_file_location(module_name, function_path)
            if spec is None or spec.loader is None:
                raise RuntimeError("module import specification has no loader")

            module = module_from_spec(spec)
            spec.loader.exec_module(module)
            blueprint = getattr(module, "blueprint", None)
            if blueprint is None:
                raise RuntimeError("module does not export 'blueprint'")
            blueprints.append(blueprint)
        except Exception as error:
            failures.append((function_path, error))

    if failures:
        details = "\n".join(
            f"- {function_path}: {type(error).__name__}: {error}"
            for function_path, error in failures
        )
        raise RuntimeError(
            f"Unable to load {len(failures)} connector operation module(s):\n{details}"
        ) from failures[0][1]

    return blueprints


app = func.FunctionApp()
operations_dir = Path(__file__).with_name("operations")
for operation_blueprint in _load_operation_blueprints(operations_dir):
    app.register_functions(operation_blueprint)
