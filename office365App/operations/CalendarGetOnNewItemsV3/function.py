# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import azure.functions as func
import azurefunctions.extensions.connectors.office365 as office365
import logging
from typing import List


blueprint = func.Blueprint()


# ------------------------------------------------------------------------------
# OnNewCalendarEvent - GraphCalendarEventClientReceive type
# ------------------------------------------------------------------------------
@blueprint.function_name(name="OnNewCalendarEvent")
@blueprint.connector_trigger(arg_name="events")
def on_new_calendar_event(events: List[office365.GraphCalendarEventClientReceive]) -> None:
    """Triggered when a new calendar event is created in Office 365."""
    logging.info("OnNewCalendarEvent trigger received.")

    for event in events:
        logging.info(f"Subject: '{event.subject}'.")
        logging.info(f"Organizer: '{event.organizer}'.")
        logging.info(f"Start: '{event.start}'.")
        logging.info(f"End: '{event.end}'.")

    logging.info(f"Batch contains '{len(events)}' event(s).")
