#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
OPERATION_ROOT="${APP_ROOT}/operations"
DEPLOYMENT_HELPER="${APP_ROOT}/shared/deployment_config.py"

descriptorFiles=''
if [ -d "${OPERATION_ROOT}" ]; then
  descriptorFiles=$(find "${OPERATION_ROOT}" -type f -name 'trigger-config.json' -print | sort)
fi
descriptorCount=$(printf '%s\n' "${descriptorFiles}" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "${descriptorCount}" -ne 1 ]; then
  echo "ERROR: Expected exactly one retained operation descriptor under operations/, but found ${descriptorCount}." >&2
  exit 1
fi
descriptorFile=${descriptorFiles}

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo 'ERROR: Python 3.13 or later is required for this project.' >&2
  exit 1
fi

if ! az extension show --name connector-namespace --query name -o tsv >/dev/null 2>&1; then
  echo "ERROR: The 'connector-namespace' Azure CLI extension is required." >&2
  echo 'Install: curl -fsSL https://aka.ms/connector-namespace-cli-install | sh' >&2
  exit 1
fi

outputs=$(azd env get-values --output json) || {
  echo "ERROR: Unable to read azd environment outputs. Run 'azd provision' first." >&2
  exit 1
}

resolvedDescriptor=$(printf '%s' "${outputs}" | \
  "${PYTHON}" "${DEPLOYMENT_HELPER}" resolve "${descriptorFile}") || {
  echo 'ERROR: Unable to resolve the retained operation descriptor.' >&2
  exit 1
}

required_azd_output() {
  outputName=$1
  value=$(printf '%s' "${outputs}" | \
    "${PYTHON}" "${DEPLOYMENT_HELPER}" output "${outputName}") || {
    echo "ERROR: Required azd output '${outputName}' is missing. Run 'azd provision' first." >&2
    exit 1
  }
  printf '%s' "${value}"
}

resourceGroupName=$(required_azd_output 'resourceGroupName')
connectorNamespaceName=$(required_azd_output 'connectorNamespaceName')
connectorNamespaceConnectionName=$(required_azd_output 'connectorNamespaceConnectionName')
functionAppName=$(required_azd_output 'functionAppName')
subscriptionId=$(required_azd_output 'AZURE_SUBSCRIPTION_ID')
functionName=$(printf '%s' "${resolvedDescriptor}" | \
  "${PYTHON}" "${DEPLOYMENT_HELPER}" field functionName)

echo 'Authorizing the connector connection...'
currentStatus=$(az connector-namespace connection show \
  -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
  -n "${connectorNamespaceConnectionName}" \
  --query 'properties.overallStatus' -o tsv 2>/dev/null || true)
currentStatus=${currentStatus:-Unknown}

if [ "${currentStatus}" = 'Connected' ]; then
  echo 'Connection is already authorized.'
else
  echo 'A browser tab will open for connector OAuth consent.'
  consentLink=''
  attempt=1
  while [ "${attempt}" -le 5 ]; do
    consentLink=$(az connector-namespace connection list-consent-links \
      -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
      --connection-name "${connectorNamespaceConnectionName}" \
      --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" \
      --query 'value[0].link' -o tsv 2>/dev/null || true)

    if [ -z "${consentLink}" ] || [ "${consentLink}" = 'null' ]; then
      consentLink=$(az connector-namespace connection list-consent-links \
        -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
        --connection-name "${connectorNamespaceConnectionName}" \
        --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" \
        --query 'link' -o tsv 2>/dev/null || true)
    fi

    if [ -n "${consentLink}" ] && [ "${consentLink}" != 'null' ]; then
      break
    fi

    if [ "${attempt}" -lt 5 ]; then
      echo "Consent-link attempt ${attempt} failed. Retrying in 5 seconds..."
      sleep 5
    fi
    attempt=$((attempt + 1))
  done

  if [ -z "${consentLink}" ] || [ "${consentLink}" = 'null' ]; then
    echo 'ERROR: Failed to create a connector consent link.' >&2
    exit 1
  fi

  opened=false
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${consentLink}" >/dev/null 2>&1 && opened=true
  elif command -v open >/dev/null 2>&1; then
    open "${consentLink}" >/dev/null 2>&1 && opened=true
  fi
  if [ "${opened}" != true ]; then
    echo 'ERROR: Unable to open a browser for connector consent.' >&2
    exit 1
  fi

  deadline=$(($(date +%s) + 300))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    sleep 3
    currentStatus=$(az connector-namespace connection show \
      -g "${resourceGroupName}" --namespace "${connectorNamespaceName}" \
      -n "${connectorNamespaceConnectionName}" \
      --query 'properties.overallStatus' -o tsv 2>/dev/null || true)
    if [ "${currentStatus}" = 'Connected' ]; then
      break
    fi
  done

  if [ "${currentStatus}" != 'Connected' ]; then
    echo 'ERROR: Timed out waiting for the connector connection to reach Connected status.' >&2
    exit 1
  fi
fi

functionNameLower=$(printf '%s' "${functionName}" | tr '[:upper:]' '[:lower:]')
triggerConfigName="${connectorNamespaceConnectionName}-${functionNameLower}"
namespaceResourceId="/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Web/connectorGateways/${connectorNamespaceName}"
triggerConfigResourceId="${namespaceResourceId}/triggerConfigs/${triggerConfigName}"
apiVersion='2026-05-01-preview'

requestBody=$(printf '%s' "${resolvedDescriptor}" | \
  "${PYTHON}" "${DEPLOYMENT_HELPER}" request-body \
  "${connectorNamespaceConnectionName}") || {
  echo 'ERROR: Unable to build the Poll Trigger Config request.' >&2
  exit 1
}

bodyFile="${SCRIPT_DIR}/.poll-trigger-body.$$.json"
trap 'rm -f "${bodyFile}"' 0 HUP INT TERM
printf '%s' "${requestBody}" > "${bodyFile}"

echo 'Creating or updating the retained Poll Trigger Config...'
if ! response=$(az rest \
  --method put \
  --uri "${triggerConfigResourceId}?api-version=${apiVersion}" \
  --body "@${bodyFile}" \
  -o json); then
  echo 'ERROR: Failed to create or update the Connector Namespace Poll Trigger Config.' >&2
  exit 1
fi

state=$(printf '%s' "${response}" | \
  "${PYTHON}" "${DEPLOYMENT_HELPER}" state) || {
  echo 'ERROR: The Poll Trigger Config response did not contain a state.' >&2
  exit 1
}
if [ "${state}" != 'Enabled' ]; then
  echo 'ERROR: The Connector Namespace Poll Trigger Config was not enabled.' >&2
  exit 1
fi

if ! pollingEndpoint=$(printf '%s' "${response}" | \
  "${PYTHON}" "${DEPLOYMENT_HELPER}" polling-endpoint 2>/dev/null); then
  if ! response=$(az rest \
    --method get \
    --uri "${triggerConfigResourceId}?api-version=${apiVersion}" \
    -o json); then
    echo 'ERROR: Failed to retrieve Poll Trigger Config endpoints.' >&2
    exit 1
  fi
  pollingEndpoint=$(printf '%s' "${response}" | \
    "${PYTHON}" "${DEPLOYMENT_HELPER}" polling-endpoint) || {
    echo 'ERROR: The service-generated receive URI is not a supported Poll endpoint.' >&2
    exit 1
  }
fi

if ! az functionapp config appsettings set \
  -g "${resourceGroupName}" \
  -n "${functionAppName}" \
  --settings \
    "ConnectorNamespace__pollingEndpoint=${pollingEndpoint}" \
    "ConnectorTriggerConfigName=${triggerConfigName}" \
  -o none >/dev/null; then
  echo 'ERROR: Failed to configure the Function App Poll settings.' >&2
  exit 1
fi

echo 'The retained Connector Poll trigger is configured and enabled.'
