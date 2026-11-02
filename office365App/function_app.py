# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import importlib.util
from pathlib import Path

import azure.functions as func


app = func.FunctionApp()
operations_dir = Path(__file__).with_name("operations")

for function_path in sorted(operations_dir.glob("*/function.py")):
    module_name = f"_connector_operation_{function_path.parent.name}"
    spec = importlib.util.spec_from_file_location(module_name, function_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load connector operation module: {function_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    blueprint = getattr(module, "blueprint", None)
    if blueprint is None:
        raise RuntimeError(f"Connector operation module has no blueprint: {function_path}")

    app.register_functions(blueprint)
