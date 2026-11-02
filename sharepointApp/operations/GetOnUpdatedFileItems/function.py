# Copyright (c) .NET Foundation. All rights reserved.
# Licensed under the MIT License.

import logging
from typing import List

import azure.functions as func

from shared.poll_payload import normalize_poll_payloads

bp = func.Blueprint()


@bp.function_name(name="OnSharepointUpdatedFile")
@bp.connector_trigger(
    arg_name="payloads",
    delivery_mode=func.DeliveryMode.POLL,
    connection="ConnectorNamespace",
    trigger_config_name="%ConnectorTriggerConfigName%",
    cardinality=func.Cardinality.MANY,
    max_batch_size=4,
    target_pending_event_threshold=16,
)
def on_sharepoint_updated_file(payloads: List[str]) -> None:
    items = normalize_poll_payloads(payloads)
    logging.info(
        "OnSharepointUpdatedFile received %s item(s) from %s Poll event(s).",
        len(items),
        len(payloads),
    )
