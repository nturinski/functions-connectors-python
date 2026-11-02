# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import azure.functions as func
import azurefunctions.extensions.connectors.office365 as office365
import logging
from typing import List


blueprint = func.Blueprint()


# ------------------------------------------------------------------------------
# OnUpcomingEvent - GraphCalendarEventClientReceive type
# ------------------------------------------------------------------------------
@blueprint.function_name(name="OnUpcomingEvent")
@blueprint.connector_trigger(arg_name="events")
def on_upcoming_event(events: List[office365.GraphCalendarEventClientReceive]) -> None:
    """Triggered when an upcoming calendar event is about to start."""
    logging.info("OnUpcomingEvent trigger received.")

    for event in events:
        logging.info(f"Subject: '{event.subject}'.")
        logging.info(f"Start: '{event.start}'.")
