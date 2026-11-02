#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OPERATIONS_DIR="${APP_DIR}/operations"
NOTIFICATION_FILES=()

cleanup_notification_files() {
  local notification_file
  for notification_file in "${NOTIFICATION_FILES[@]}"; do
    rm -f "${notification_file}"
  done
}
trap cleanup_notification_files EXIT

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

fail() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  exit 1
}

require_output() {
  local output_name="$1"
  local output_value
  output_value="$(jq -r --arg output_name "${output_name}" 'if .[$output_name] == null then empty else (.[$output_name] | tostring) end' <<<"${outputs_json}")" || fail "unable to read azd output '${output_name}'"
  if [[ -z "${output_value}" || "${output_value}" == "null" ]]; then
    fail "required azd output '${output_name}' is missing or empty"
  fi
  printf '%s' "${output_value}"
}

escape_shorthand_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\\\'\'}"
  printf '%s' "${value}"
}

build_parameters() {
  local config_file="$1"
  local parameters_shorthand="["
  local first_parameter=1
  local parameter_kind
  local parameter_name
  local parameter_value
  local escaped_value
  local parameter_item

  while IFS=$'\t' read -r parameter_kind parameter_name parameter_value; do
    [[ -n "${parameter_kind}" ]] || continue
    if [[ "${parameter_kind}" == "valueFrom" ]]; then
      parameter_value="$(require_output "${parameter_value}")"
    fi
    escaped_value="$(escape_shorthand_value "${parameter_value}")"
    parameter_item="{name:${parameter_name},value:'${escaped_value}'}"
    if [[ "${first_parameter}" -eq 0 ]]; then
      parameters_shorthand+=","
    fi
    parameters_shorthand+="${parameter_item}"
    first_parameter=0
  done < <(jq -r '.parameters[] | if has("value") then ["value", .name, .value] else ["valueFrom", .name, .valueFrom] end | @tsv' "${config_file}")

  parameters_shorthand+="]"
  printf '%s' "${parameters_shorthand}"
}

echo -e "${YELLOW}Post-deployment configuration...${NC}"

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for this script. Please install jq."
fi

if ! az extension show --name connector-namespace --query name -o tsv >/dev/null 2>&1; then
  echo -e "${RED}Install: curl -fsSL https://aka.ms/connector-namespace-cli-install | sh${NC}" >&2
  fail "the 'connector-namespace' Azure CLI extension is required"
fi

config_files=()
while IFS= read -r config_file; do
  if [[ -f "${config_file}" ]]; then
    config_files+=("${config_file}")
  fi
done < <(LC_ALL=C printf '%s\n' "${OPERATIONS_DIR}"/*/trigger-config.json | LC_ALL=C sort)

if [[ "${#config_files[@]}" -eq 0 ]]; then
  fail "no retained trigger configs found under operations/*/trigger-config.json"
fi

connector_name=""
for config_file in "${config_files[@]}"; do
  validation_error=""
  if ! validation_error="$(jq -e '
    type == "object"
    and (.connectorName | type == "string" and length > 0)
    and (.operationId | type == "string" and length > 0)
    and (.functionName | type == "string" and length > 0)
    and (.description | type == "string" and length > 0)
    and (.parameters | type == "array" and length > 0)
    and all(.parameters[];
      type == "object"
      and (.name | type == "string" and length > 0)
      and (((if has("value") then 1 else 0 end) + (if has("valueFrom") then 1 else 0 end)) == 1)
      and (if has("value") then (.value | type == "string" and length > 0) else (.valueFrom | type == "string" and length > 0) end)
    )
  ' "${config_file}" 2>&1)"; then
    fail "malformed or invalid trigger config '${config_file}': ${validation_error}"
  fi

  current_connector_name="$(jq -r '.connectorName' "${config_file}")"
  if [[ -z "${connector_name}" ]]; then
    connector_name="${current_connector_name}"
  elif [[ "${connector_name}" != "${current_connector_name}" ]]; then
    fail "retained trigger configs use mixed connectorName values"
  fi
done

outputs_json="$(azd env get-values --output json 2>&1)" || fail "azd env get-values --output json failed: ${outputs_json}"
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${outputs_json}"; then
  fail "azd env get-values --output json returned invalid JSON"
fi

resource_group_name="$(require_output resourceGroupName)"
connector_namespace_name="$(require_output connectorNamespaceName)"
connector_namespace_connection_name="$(require_output connectorNamespaceConnectionName)"
function_app_name="$(require_output functionAppName)"
subscription_id="$(require_output AZURE_SUBSCRIPTION_ID)"

echo -e "${CYAN}Fetching connector extension key for ${function_app_name}...${NC}"
connector_extension_key="$(az functionapp keys list -g "${resource_group_name}" -n "${function_app_name}" --query "systemKeys.connector_extension" -o tsv 2>&1)" || fail "could not fetch connector_extension system key: ${connector_extension_key}"
if [[ -z "${connector_extension_key}" || "${connector_extension_key}" == "null" ]]; then
  fail "could not fetch a non-empty connector_extension system key from ${function_app_name}"
fi

create_trigger_config() {
  local config_file="$1"
  local operation_name
  local function_name
  local description
  local parameters_shorthand
  local trigger_name
  local callback_url
  local notification_file

  operation_name="$(jq -r '.operationId' "${config_file}")"
  function_name="$(jq -r '.functionName' "${config_file}")"
  description="$(jq -r '.description' "${config_file}")"
  parameters_shorthand="$(build_parameters "${config_file}")"
  trigger_name="${connector_namespace_connection_name}-$(printf '%s' "${function_name}" | tr '[:upper:]' '[:lower:]')"
  callback_url="https://${function_app_name}.azurewebsites.net/runtime/webhooks/connector?functionName=${function_name}"
  notification_file="${SCRIPT_DIR}/.notification-details.$$.${RANDOM}.json"
  NOTIFICATION_FILES+=("${notification_file}")
  printf '{"callbackUrl":"%s","authentication":{"type":"QueryString","name":"code","value":"%s"}}' \
    "${callback_url}" "${connector_extension_key}" > "${notification_file}"

  echo -e "${CYAN}  Creating trigger: ${function_name} -> ${operation_name}${NC}"

  az connector-namespace trigger delete \
    -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
    -n "${trigger_name}" --yes >/dev/null 2>&1 || true

  if ! az connector-namespace trigger create \
    -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
    -n "${trigger_name}" \
    --connection-details "{connectionName:${connector_namespace_connection_name},connectorName:${connector_name}}" \
    --operation-name "${operation_name}" \
    --parameters "${parameters_shorthand}" \
    --notification-details "@${notification_file}" \
    --description "${description}" \
    --metadata "{destinationType:functionApp,functionAppName:${function_app_name},functionAppResourceGroup:${resource_group_name},functionAppSubscriptionId:${subscription_id},functionName:${function_name},recurrenceFrequency:Minute,recurrenceInterval:'5'}" \
    -o none; then
    fail "failed to create trigger for function '${function_name}'"
  fi

  rm -f "${notification_file}"
}

echo -e "${YELLOW}Creating Connector Namespace trigger configs...${NC}"
for config_file in "${config_files[@]}"; do
  create_trigger_config "${config_file}"
done
echo -e "${GREEN}Created ${#config_files[@]} retained trigger config(s).${NC}"

echo ""
echo -e "${YELLOW}Authorizing ${connector_name} connection...${NC}"

current_status="$(az connector-namespace connection show \
  -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
  -n "${connector_namespace_connection_name}" \
  --query "properties.overallStatus" -o tsv 2>/dev/null || true)"
current_status="${current_status:-Unknown}"

if [[ "${current_status}" == "Connected" ]]; then
  echo -e "${GREEN}Connection is already authorized.${NC}"
else
  echo -e "${CYAN}-> A browser tab will open. Sign in with the account authorized for this connector.${NC}"

  consent_link=""
  for attempt in 1 2 3 4 5; do
    consent_link="$(az connector-namespace connection list-consent-links \
      -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
      --connection-name "${connector_namespace_connection_name}" \
      --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" \
      --query "value[0].link" -o tsv 2>/dev/null || true)"

    if [[ -z "${consent_link}" || "${consent_link}" == "null" ]]; then
      consent_link="$(az connector-namespace connection list-consent-links \
        -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
        --connection-name "${connector_namespace_connection_name}" \
        --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" \
        --query "link" -o tsv 2>/dev/null || true)"
    fi

    if [[ -n "${consent_link}" && "${consent_link}" != "null" ]]; then
      break
    fi

    if [[ "${attempt}" != "5" ]]; then
      echo -e "${YELLOW}list-consent-links attempt ${attempt} failed. Retrying in 5 seconds...${NC}"
      sleep 5
    fi
  done

  if [[ -z "${consent_link}" || "${consent_link}" == "null" ]]; then
    fail "failed to create consent link"
  fi

  echo -e "${CYAN}Consent URL: ${consent_link}${NC}"

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${consent_link}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "${consent_link}" >/dev/null 2>&1 || true
  else
    echo -e "${YELLOW}Unable to open a browser automatically. Paste the consent URL into your browser.${NC}"
  fi

  deadline=$((SECONDS + 300))
  last_printed_status="${current_status}"
  echo -e "${CYAN}Connection status: ${current_status}${NC}"

  while (( SECONDS < deadline )); do
    sleep 3
    current_status="$(az connector-namespace connection show \
      -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
      -n "${connector_namespace_connection_name}" \
      --query "properties.overallStatus" -o tsv 2>/dev/null || true)"
    current_status="${current_status:-Unknown}"

    if [[ "${current_status}" != "${last_printed_status}" ]]; then
      echo -e "${CYAN}Connection status: ${current_status}${NC}"
      last_printed_status="${current_status}"
    fi

    if [[ "${current_status}" == "Connected" ]]; then
      break
    fi
  done

  if [[ "${current_status}" != "Connected" ]]; then
    fail "timed out waiting for the connection to reach Connected status"
  fi
fi

echo ""
echo -e "${GREEN}Done. All retained connector triggers are configured.${NC}"
echo -e "${GREEN}   Tail logs: az functionapp log tail -g ${resource_group_name} -n ${function_app_name}${NC}"
echo ""
