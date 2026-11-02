# SharePoint Online Triggers (Python)

Azure Functions sample app demonstrating **SharePoint Online** connector triggers using the
`azure-functions` connector trigger extension.

## Operation ownership

Each supported polling operation owns one directory under `operations/<operationId>/`. The directory contains exactly `function.py` and `trigger-config.json`; it has no `__init__.py`.

| Operation directory | Function | Description |
| --- | --- | --- |
| `operations/GetOnNewFileItems/` | `OnSharepointNewFile` | Fires when a new file is created in a SharePoint library |
| `operations/GetOnUpdatedFileItems/` | `OnSharepointUpdatedFile` | Fires when a file is modified in a SharePoint library |

The shared `function_app.py` dynamically discovers sorted `operations/*/function.py` files with `importlib.util.spec_from_file_location`, requires each exported `blueprint`, and registers it with `FunctionApp`. A full checkout loads both functions. A downstream or sparse template copy can retain one operation directory and the loader will register only that function.

The post-deploy scripts discover the retained `trigger-config.json` files in deterministic order. SharePoint parameters use `dataset` from `sharepointSiteUrl` and `table` from `sharepointLibraryName`; the scripts resolve those `valueFrom` names through `azd env get-values --output json`. Before changing triggers, they validate the complete retained set and finish the OAuth/consent flow. Each retained trigger replacement is retried up to three times; failures are collected so the final error names every incomplete operation while successful operations remain configured. Re-run `azd hooks run postdeploy` after correcting a partial failure. Polling metadata remains `recurrenceFrequency:Minute` with `recurrenceInterval:'5'`.

A sparse first deployment creates only the retained operations. The script intentionally does not delete Azure trigger configs for operation directories that are no longer present, because it cannot prove those remote resources are safe to remove. Delete an old trigger explicitly when narrowing an already-deployed app.

The root [`template-metadata.json`](../template-metadata.json) records the exact operation-to-function mapping and one-element POSIX `ownedPaths` contract for downstream copying. Template tooling must copy the shared loader/scripts and the selected `operations/<operationId>/` directories together with the metadata contract.

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

Before running `azd up`, set the SharePoint site URL:

```bash
azd env set SHAREPOINT_SITE_URL "https://contoso.sharepoint.com/sites/mysite"
azd env set SHAREPOINT_LIBRARY_NAME "Documents"  # optional, defaults to "Documents"
```

Then deploy:

```bash
cd sharepointApp
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
| **Storage Account** | Deployment artifacts and function runtime state |
| **Log Analytics Workspace** | Backing store for Application Insights |
| **Application Insights** | Telemetry and logging |
| **Connector Namespace** | Hosts the SharePoint connection and retained trigger configs |
| **SharePoint Online Connection** (OAuth) | Authenticates to SharePoint - requires interactive consent during post-deploy |

After provisioning, a post-deploy hook authorizes the SharePoint connection and creates trigger configs for every retained operation. To re-run:

```bash
azd hooks run postdeploy
```

## Verify

After `azd up`, open the [Connector Namespaces portal](https://connectors.azure.com/) to verify:

- One **Connection** (SharePoint Online) with status **Connected**
- One enabled trigger config for every retained operation directory

Create or modify a file in the configured SharePoint library to fire the corresponding trigger. Tail logs with:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## More

- [Operations to Functions Signature Mapping](https://github.com/Azure/azure-functions-connector-extension/blob/main/docs/operations-functions-match.md)
- [SharePoint Online connector reference](https://learn.microsoft.com/en-us/connectors/sharepointonline/)
