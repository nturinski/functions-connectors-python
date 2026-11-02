# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import azure.functions as func
import azurefunctions.extensions.connectors.office365 as office365
import logging
from typing import List


blueprint = func.Blueprint()


# ------------------------------------------------------------------------------
# OnNewMentionMeEmail - GraphClientReceiveMessage type
# ------------------------------------------------------------------------------
@blueprint.function_name(name="OnNewMentionMeEmail")
@blueprint.connector_trigger(arg_name="emails")
def on_new_mention_me_email(emails: List[office365.GraphClientReceiveMessage]) -> None:
    """Triggered when a new email mentioning the current user arrives."""
    logging.info("OnNewMentionMeEmail trigger received.")

    for email in emails:
        logging.info(f"Subject: '{email.subject}'.")
        logging.info(f"From: '{email.from_}'.")
