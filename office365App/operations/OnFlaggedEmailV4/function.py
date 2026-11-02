# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import azure.functions as func
import azurefunctions.extensions.connectors.office365 as office365
import logging
from typing import List


blueprint = func.Blueprint()


# ------------------------------------------------------------------------------
# OnFlaggedEmail - GraphClientReceiveMessage type
# ------------------------------------------------------------------------------
@blueprint.function_name(name="OnFlaggedEmail")
@blueprint.connector_trigger(arg_name="emails")
def on_flagged_email(emails: List[office365.GraphClientReceiveMessage]) -> None:
    """Triggered when an email is flagged in Office 365."""
    logging.info("OnFlaggedEmail trigger received.")

    for email in emails:
        logging.info(f"Subject: '{email.subject}'.")
        logging.info(f"From: '{email.from_}'.")
        logging.info(f"Importance: '{email.importance}'.")
