# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import azure.functions as func
import json
import logging


blueprint = func.Blueprint()


@blueprint.function_name(name="OnSharepointUpdatedFile")
@blueprint.connector_trigger(arg_name="payload")
def on_sharepoint_updated_file(payload: str) -> None:
    """Triggered when a file is updated in SharePoint Online."""
    logging.info("OnSharepointUpdatedFile trigger received.")

    data = json.loads(payload)
    files = data.get("body", {}).get("value", [])

    for file in files:
        logging.info(f"Name: '{file.get('Name')}'.")
        logging.info(f"Path: '{file.get('Path')}'.")
        logging.info(f"LastModified: '{file.get('LastModified')}'.")
