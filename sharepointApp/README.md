# SharePoint Online Poll triggers (Python)

Azure Functions project-template source for SharePoint Online Connector Namespace
triggers using host-pull **Poll** delivery.

## Operation ownership

Each selectable operation owns its complete source and deployment descriptor:

| Owned path | Function | Connector operation |
| --- | --- | --- |
| `operations/GetOnNewFileItems` | `OnSharepointNewFile` | `GetOnNewFileItems` |
| `operations/GetOnUpdatedFileItems` | `OnSharepointUpdatedFile` | `GetOnUpdatedFileItems` |

The project-template materializer retains one whole operation directory and removes
its sibling. If you use this repository directly, delete the unselected
`operations/<operationId>` directory before running or deploying the app.
`function_app.py` and the post-deploy scripts intentionally fail unless exactly one
`trigger-config.json` remains.

The retained operation registers one `typing.List[str]` Poll binding with:

- `connection="ConnectorNamespace"`
- `trigger_config_name="%ConnectorTriggerConfigName%"`
- `cardinality=func.Cardinality.MANY`
- `max_batch_size=4`
- `target_pending_event_threshold=16`

Each string is one raw Poll event. The shared normalizer unwraps
`outputs.body`, including `{ "value": [...] }` collection bodies, without logging
file metadata.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- [Python 3.13](https://www.python.org/downloads/)
- [`connector-namespace` Azure CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli)

Install the Connector Namespace extension with one of:

```bash
curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
```

```pwsh
irm https://aka.ms/connector-namespace-cli-install-ps | iex
```

## Deploy

Set the SharePoint operation inputs:

```bash
azd env set SHAREPOINT_SITE_URL "https://contoso.sharepoint.com/sites/mysite"
azd env set SHAREPOINT_LIBRARY_NAME "Documents"
```

The retained descriptor resolves those `azd` outputs into the operation's
`dataset` and `table` parameters. After retaining one operation:

```bash
cd sharepointApp
azd auth login
az login
azd up
```

The post-deploy hook:

1. authorizes the SharePoint connection through OAuth consent;
2. reads the retained operation descriptor and resolves its `azdOutput` values;
3. creates or updates one enabled Poll Trigger Config through the
   `2026-05-01-preview` ARM API;
4. derives the gateway-level polling endpoint returned by the service; and
5. sets `ConnectorNamespace__pollingEndpoint` and
   `ConnectorTriggerConfigName` on the Function App.

It does not create a callback URL, webhook notification, or callback key.
Re-run only this setup with:

```bash
azd hooks run postdeploy
```

The deployment grants the Connector Namespace identity permission to run the
connector trigger and grants the Function App identity permission to receive and
acknowledge Poll events. The deployer also receives connection access for local
debugging.

## Run locally

Install dependencies and replace the placeholders in `local.settings.json` with
the gateway-level Poll endpoint and Trigger Config name produced by deployment:

```bash
python -m pip install -r requirements.txt
func start
```

For local development, omit `ConnectorNamespace__credential`; the extension uses
the signed-in developer credential. Never commit a real polling endpoint or
credential.

## Verify

In Connector Namespace, verify that the retained Trigger Config is enabled. Create
or modify a file, according to the selected operation, then inspect the Function
App logs for event and item counts.

## More

- [Connector trigger configuration](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/connector-trigger-configuration.md)
- [SharePoint Online connector reference](https://learn.microsoft.com/connectors/sharepointonline/)
