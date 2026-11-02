# Office 365 Outlook Triggers (Python)

Azure Functions sample app demonstrating **Office 365 Outlook** connector triggers using the
`azurefunctions-extensions-connectors` package with the Functions connector trigger extension.

## Operation ownership

Each supported polling operation owns one directory under `operations/<operationId>/`. The directory contains exactly `function.py` and `trigger-config.json`; it has no `__init__.py`.

| Operation directory | Function | Description |
| --- | --- | --- |
| `operations/OnNewEmailV3/` | `OnNewEmail` | Fires when a new email arrives |
| `operations/OnFlaggedEmailV4/` | `OnFlaggedEmail` | Fires when an email is flagged |
| `operations/OnNewMentionMeEmailV3/` | `OnNewMentionMeEmail` | Fires when a new email mentions the authenticated user |
| `operations/CalendarGetOnNewItemsV3/` | `OnNewCalendarEvent` | Fires when a new calendar event is created |
| `operations/OnUpcomingEventsV3/` | `OnUpcomingEvent` | Fires when an upcoming calendar event is starting soon |

The shared `function_app.py` dynamically discovers sorted `operations/*/function.py` files with `importlib.util.spec_from_file_location`, requires each exported `blueprint`, and registers it with `FunctionApp`. A full checkout loads all five functions. A downstream or sparse template copy can retain one or more operation directories and the loader will register only those functions.

The post-deploy scripts discover the retained `trigger-config.json` files in the same deterministic order. Each config contains the connector name, operation ID, function name, description, and parameters. Before changing triggers, the scripts validate the complete retained set, resolve `valueFrom` entries from `azd env get-values --output json`, and complete the Connector Namespace OAuth flow. Each retained trigger replacement is retried up to three times; failures are collected so the final error names every incomplete operation while successful operations remain configured. Re-run `azd hooks run postdeploy` after correcting a partial failure. Polling metadata remains `recurrenceFrequency:Minute` with `recurrenceInterval:'5'`.

A sparse first deployment creates only the retained operations. The script intentionally does not delete Azure trigger configs for operation directories that are no longer present, because it cannot prove those remote resources are safe to remove. Delete an old trigger explicitly when narrowing an already-deployed app.

The root [`template-metadata.json`](../template-metadata.json) records the exact operation-to-function mapping and one-element POSIX `ownedPaths` contract for downstream copying. Template tooling must copy the shared loader/scripts and the selected `operations/<operationId>/` directories together with the metadata contract.

> [!CAUTION]
> **Personal data.** This sample writes email/calendar content to Blob Storage for demonstration only. Restrict access to the resources to appropriate users only, and run `azd down --purge` when done.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later
- [Python 3.13](https://www.python.org/downloads/)
- [`connector-namespace` Azure CLI extension](https://github.com/Azure/Connectors/tree/main/public-preview/connector-namespace-cli) - install with:

  ```bash
  # Bash
  curl -fsSL https://aka.ms/connector-namespace-cli-install | sh
  ```

  or

  ```pwsh
  # PowerShell
  irm https://aka.ms/connector-namespace-cli-install-ps | iex
  ```

## Deploy to Azure

```bash
cd office365App
azd auth login
az login
azd up
```

### Resources provisioned

| Resource | Purpose |
| --- | --- |
| **Resource Group** | Contains all resources |
| **Flex Consumption Function App** (Python 3.13) | Hosts all retained connector trigger functions |
| **App Service Plan** (FC1) | Flex Consumption plan |
| **User-Assigned Managed Identity** | Identity for the function app |
| **Storage Account** | Deployment artifacts, function runtime state, and trigger payload output |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the Office 365 connection and retained trigger configs |
| **Office 365 Outlook Connection** (OAuth) | Authenticates to Office 365 - requires interactive consent during post-deploy |

After provisioning, a post-deploy hook authorizes the Office 365 connection and creates trigger configs for every retained operation. To re-run:

```bash
azd hooks run postdeploy
```

### Trigger configuration

The checked-in config for `operations/OnNewEmailV3/trigger-config.json` preserves these defaults:

| Setting | Value |
| ------- | ----- |
| `operationId` | `OnNewEmailV3` |
| `functionName` | `OnNewEmail` |
| `folderPath` | `Inbox` |
| `importance` | `High` |

The other operation directories contain their own operation-specific config. To select a smaller downstream sample, retain the shared app files and only the desired operation directories; do not hardcode trigger lists in either post-deploy script.

## Rich SDK Types

Each Office 365 operation keeps the existing rich SDK type hints in its operation-owned `function.py`. For example:

```python
import azure.functions as func
import azurefunctions.extensions.connectors.office365 as office365
from typing import List

blueprint = func.Blueprint()

@blueprint.function_name(name="OnNewEmail")
@blueprint.connector_trigger(arg_name="emails")
def on_new_email(emails: List[office365.ClientReceiveMessage]) -> None:
    for email in emails:
        print(f"Subject: {email.subject}")
        print(f"From: {email.from_}")
```

## Verify

After `azd up`, open the [Connector Namespaces portal](https://connectors.azure.com/) to verify:

- One **Connection** (Office 365 Outlook) with status **Connected**
- One enabled trigger config for every retained operation directory

Send yourself a high-importance email to fire the new-email trigger. Tail logs with:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [Office 365 Outlook connector reference](https://learn.microsoft.com/en-us/connectors/office365/)
- [Built-in auth sample](https://github.com/Azure-Samples/functions-connectors-net-builtinauth) - secretless authentication using managed identity + Easy Auth.
