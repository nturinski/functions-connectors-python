# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import azure.functions as func
import azurefunctions.extensions.connectors.office365 as office365
import logging
from typing import List


blueprint = func.Blueprint()


# ------------------------------------------------------------------------------
# OnNewEmail - ClientReceiveMessage type
# ------------------------------------------------------------------------------
@blueprint.function_name(name="OnNewEmail")
@blueprint.connector_trigger(arg_name="emails")
def on_new_email(emails: List[office365.ClientReceiveMessage]) -> None:
    """Triggered when a new email arrives in Office 365."""
    logging.info("OnNewEmail trigger received.")

    for email in emails:
        logging.info(f"Subject: '{email.subject}'.")
        logging.info(f"From: '{email.from_}'.")
        logging.info(f"Importance: '{email.importance}'.")
        logging.info(f"Has attachments: '{email.has_attachments}'.")

    logging.info(f"Batch contains '{len(emails)}' email(s).")
