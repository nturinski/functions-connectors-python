# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

from pathlib import Path

import azure.functions as func

from shared.operation_loader import load_selected_blueprint

app = func.FunctionApp()
app.register_functions(load_selected_blueprint(Path(__file__).parent))
