#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export AZURE_CORE_ONLY_SHOW_ERRORS=true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OPERATIONS_DIR="${APP_DIR}/operations"
NOTIFICATION_FILES=()
RETRY_ATTEMPTS=3
RETRY_DELAY_SECONDS=5
AZ_OUTPUT=""
COMMAND_ERROR_FILE="${SCRIPT_DIR}/.command-error.$$.${RANDOM}"

cleanup_notification_files() {
  local notification_file
  for notification_file in "${NOTIFICATION_FILES[@]}"; do
    rm -f "${notification_file}"
  done
  rm -f "${COMMAND_ERROR_FILE}"
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

contains_value() {
  local needle="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if [[ "${candidate}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

require_output() {
  local output_name="$1"
  local output_value
  if ! output_value="$(jq -er --arg output_name "${output_name}" '
    .[$output_name]
    | select(type == "string" and length > 0 and . != "null")
  ' <<<"${outputs_json}")"; then
    fail "required azd output '${output_name}' must be a non-empty string"
  fi
  printf '%s' "${output_value}"
}

optional_output() {
  local output_name="$1"
  jq -r --arg output_name "${output_name}" '
    .[$output_name]
    | if type == "string" and length > 0 and . != "null" then . else empty end
  ' <<<"${outputs_json}"
}

build_parameters_json() {
  local config_file="$1"
  jq -ce --argjson outputs "${outputs_json}" '
    [.parameters[] |
      .name as $name |
      if has("value") then
        {name: $name, value: .value}
      else
        .valueFrom as $source |
        ($outputs[$source] // null) as $resolved |
        if (($resolved | type) != "string" or ($resolved | length) == 0 or $resolved == "null") then
          error("required azd output referenced by parameter \($name) is missing or empty: \($source)")
        else
          {name: $name, value: $resolved}
        end
      end
    ]
  ' "${config_file}"
}

run_az_with_retry() {
  local description="$1"
  shift
  local attempt
  local output
  local error_output
  for ((attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++)); do
    : >"${COMMAND_ERROR_FILE}"
    if output="$(az "$@" 2>"${COMMAND_ERROR_FILE}")"; then
      AZ_OUTPUT="${output//$'\r'/}"
      return 0
    fi
    error_output="$(cat "${COMMAND_ERROR_FILE}")"
    AZ_OUTPUT="${error_output:-${output}}"
    if [[ "${attempt}" -lt "${RETRY_ATTEMPTS}" ]]; then
      echo -e "${YELLOW}  ${description} failed on attempt ${attempt}. Retrying in ${RETRY_DELAY_SECONDS} seconds...${NC}" >&2
      sleep "${RETRY_DELAY_SECONDS}"
    fi
  done
  return 1
}

get_connection_status() {
  run_az_with_retry "Reading connector connection status" \
    connector-namespace connection show \
    --subscription "${subscription_id}" \
    -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
    -n "${connector_namespace_connection_name}" \
    --query "properties.overallStatus" -o tsv
}

authorize_connection() {
  echo ""
  echo -e "${YELLOW}Authorizing ${connector_name} connection...${NC}"

  if ! get_connection_status || [[ -z "${AZ_OUTPUT}" ]]; then
    fail "could not read connector connection status: ${AZ_OUTPUT}"
  fi
  local current_status="${AZ_OUTPUT}"
  if [[ "${current_status}" == "Connected" ]]; then
    echo -e "${GREEN}Connection is already authorized.${NC}"
    return
  fi

  echo -e "${CYAN}-> A browser tab will open. Sign in with the account authorized for this connector.${NC}"
  local consent_link=""
  local attempt
  for attempt in 1 2 3 4 5; do
    consent_link="$(az connector-namespace connection list-consent-links \
      --subscription "${subscription_id}" \
      -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
      --connection-name "${connector_namespace_connection_name}" \
      --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" \
      --query "value[0].link" -o tsv 2>/dev/null || true)"

    if [[ -z "${consent_link}" || "${consent_link}" == "null" ]]; then
      consent_link="$(az connector-namespace connection list-consent-links \
        --subscription "${subscription_id}" \
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

  local deadline=$((SECONDS + 300))
  local last_printed_status="${current_status}"
  echo -e "${CYAN}Connection status: ${current_status}${NC}"

  while ((SECONDS < deadline)); do
    sleep 3
    current_status="$(az connector-namespace connection show \
      --subscription "${subscription_id}" \
      -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
      -n "${connector_namespace_connection_name}" \
      --query "properties.overallStatus" -o tsv 2>/dev/null || true)"
    current_status="${current_status:-Unknown}"

    if [[ "${current_status}" != "${last_printed_status}" ]]; then
      echo -e "${CYAN}Connection status: ${current_status}${NC}"
      last_printed_status="${current_status}"
    fi
    if [[ "${current_status}" == "Connected" ]]; then
      return
    fi
  done

  fail "timed out waiting for the connection to reach Connected status"
}

trigger_exists() {
  local trigger_name="$1"
  local existing_trigger
  for existing_trigger in "${existing_triggers[@]}"; do
    if [[ "${existing_trigger}" == "${trigger_name}" ]]; then
      return 0
    fi
  done
  return 1
}

configure_trigger() {
  local config_file="$1"
  local parameters_json="$2"
  local operation_name
  local function_name
  local description
  local trigger_name
  local callback_url
  local notification_file
  local notification_json
  local connection_details
  local metadata_json
  local attempt
  local create_output=""
  local create_error
  local delete_error
  local delete_still_present

  operation_name="$(jq -r '.operationId' "${config_file}")"
  function_name="$(jq -r '.functionName' "${config_file}")"
  description="$(jq -r '.description' "${config_file}")"
  trigger_name="${connector_namespace_connection_name}-$(printf '%s' "${function_name}" | tr '[:upper:]' '[:lower:]')"
  callback_url="https://${function_app_hostname}/runtime/webhooks/connector?functionName=${function_name}"
  notification_file="${SCRIPT_DIR}/.notification-details.$$.${RANDOM}.json"
  NOTIFICATION_FILES+=("${notification_file}")

  notification_json="$(jq -cn \
    --arg callback_url "${callback_url}" \
    --arg connector_key "${connector_extension_key}" \
    '{callbackUrl: $callback_url, authentication: {type: "QueryString", name: "code", value: $connector_key}}')"
  printf '%s' "${notification_json}" >"${notification_file}"

  if trigger_exists "${trigger_name}"; then
    if ! run_az_with_retry "Deleting existing trigger '${trigger_name}'" \
      connector-namespace trigger delete \
      --subscription "${subscription_id}" \
      -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
      -n "${trigger_name}" --yes; then
      delete_error="${AZ_OUTPUT}"
      delete_still_present=1
      if run_az_with_retry "Verifying deletion of trigger '${trigger_name}'" \
        connector-namespace trigger list \
        --subscription "${subscription_id}" \
        -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
        --query "[].name" -o tsv; then
        delete_still_present=0
        while IFS= read -r remaining_trigger; do
          if [[ "${remaining_trigger}" == "${trigger_name}" ]]; then
            delete_still_present=1
            break
          fi
        done <<<"${AZ_OUTPUT}"
      fi
      if [[ "${delete_still_present}" -eq 1 ]]; then
        CONFIGURE_ERROR="${function_name} (${operation_name}): delete failed after ${RETRY_ATTEMPTS} attempts: ${delete_error}"
        rm -f "${notification_file}"
        return 1
      fi
    fi
  fi

  connection_details="$(jq -cn \
    --arg connection_name "${connector_namespace_connection_name}" \
    --arg connector_name "${connector_name}" \
    '{connectionName: $connection_name, connectorName: $connector_name}')"
  metadata_json="$(jq -cn \
    --arg function_app_name "${function_app_name}" \
    --arg resource_group_name "${resource_group_name}" \
    --arg subscription_id "${subscription_id}" \
    --arg function_name "${function_name}" \
    '{destinationType: "functionApp", functionAppName: $function_app_name, functionAppResourceGroup: $resource_group_name, functionAppSubscriptionId: $subscription_id, functionName: $function_name, recurrenceFrequency: "Minute", recurrenceInterval: "5"}')"

  echo -e "${CYAN}  Configuring trigger: ${function_name} -> ${operation_name}${NC}"
  for ((attempt = 1; attempt <= RETRY_ATTEMPTS; attempt++)); do
    : >"${COMMAND_ERROR_FILE}"
    if create_output="$(az connector-namespace trigger create \
      --subscription "${subscription_id}" \
      -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
      -n "${trigger_name}" \
      --connection-details "${connection_details}" \
      --operation-name "${operation_name}" \
      --parameters "${parameters_json}" \
      --notification-details "@${notification_file}" \
      --description "${description}" \
      --metadata "${metadata_json}" \
      --query "properties.provisioningState" -o tsv 2>"${COMMAND_ERROR_FILE}")"; then
      create_output="${create_output//$'\r'/}"
    else
      create_error="$(cat "${COMMAND_ERROR_FILE}")"
      create_output="${create_error:-${create_output}}"
    fi
    if [[ "${create_output}" == "Succeeded" ]]; then
      rm -f "${notification_file}"
      CONFIGURE_ERROR=""
      return 0
    fi

    if [[ "${attempt}" -lt "${RETRY_ATTEMPTS}" ]]; then
      echo -e "${YELLOW}  Creating trigger '${trigger_name}' failed on attempt ${attempt}. Retrying in ${RETRY_DELAY_SECONDS} seconds...${NC}" >&2
      sleep "${RETRY_DELAY_SECONDS}"
    fi
  done

  if run_az_with_retry "Verifying trigger '${trigger_name}' after create failure" \
    connector-namespace trigger show \
    --subscription "${subscription_id}" \
    -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
    -n "${trigger_name}" \
    --query "properties.provisioningState" -o tsv \
    && [[ "${AZ_OUTPUT}" == "Succeeded" ]]; then
    rm -f "${notification_file}"
    CONFIGURE_ERROR=""
    return 0
  fi

  create_output="${create_output:-no provisioning state returned}"
  CONFIGURE_ERROR="${function_name} (${operation_name}): create failed after ${RETRY_ATTEMPTS} attempts: ${create_output}"
  rm -f "${notification_file}"
  return 1
}

echo -e "${YELLOW}Post-deployment configuration...${NC}"

for command_name in az azd jq; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    fail "required command '${command_name}' was not found on PATH"
  fi
done

if ! az extension show --name connector-namespace --query name -o tsv >/dev/null 2>&1; then
  echo -e "${RED}Install: curl -fsSL https://aka.ms/connector-namespace-cli-install | sh${NC}" >&2
  fail "the 'connector-namespace' Azure CLI extension is required"
fi

shopt -s nullglob
config_files=("${OPERATIONS_DIR}"/*/trigger-config.json)
if [[ "${#config_files[@]}" -eq 0 ]]; then
  fail "no retained trigger configs found under operations/*/trigger-config.json"
fi

connector_name=""
seen_operation_ids=()
seen_function_names=()
for config_file in "${config_files[@]}"; do
  operation_directory="$(basename "$(dirname "${config_file}")")"
  validation_error=""
  if ! validation_error="$(jq -e --arg operation_directory "${operation_directory}" '
    type == "object"
    and (.connectorName | type == "string" and length > 0 and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    and (.operationId | type == "string" and length > 0 and . == $operation_directory)
    and (.functionName | type == "string" and length > 0 and test("^[A-Za-z][A-Za-z0-9_]*$"))
    and (.description | type == "string" and length > 0)
    and (.parameters | type == "array")
    and ((.parameters | map(.name) | unique | length) == (.parameters | length))
    and all(.parameters[];
      type == "object"
      and (.name | type == "string" and length > 0)
      and (((if has("value") then 1 else 0 end) + (if has("valueFrom") then 1 else 0 end)) == 1)
      and (if has("value") then (.value | type == "string" and length > 0) else (.valueFrom | type == "string" and length > 0) end)
    )
  ' "${config_file}" 2>&1)"; then
    fail "malformed or invalid trigger config '${config_file}': ${validation_error}"
  fi
  if [[ ! -f "$(dirname "${config_file}")/function.py" ]]; then
    fail "operation '${operation_directory}' is missing function.py"
  fi

  current_connector_name="$(jq -r '.connectorName' "${config_file}")"
  operation_id="$(jq -r '.operationId' "${config_file}")"
  function_name="$(jq -r '.functionName' "${config_file}")"
  operation_key="$(printf '%s' "${operation_id}" | tr '[:upper:]' '[:lower:]')"
  function_key="$(printf '%s' "${function_name}" | tr '[:upper:]' '[:lower:]')"

  if contains_value "${operation_key}" "${seen_operation_ids[@]}"; then
    fail "duplicate operationId '${operation_id}' in retained trigger configs"
  fi
  if contains_value "${function_key}" "${seen_function_names[@]}"; then
    fail "duplicate functionName '${function_name}' in retained trigger configs"
  fi
  seen_operation_ids+=("${operation_key}")
  seen_function_names+=("${function_key}")

  if [[ -z "${connector_name}" ]]; then
    connector_name="${current_connector_name}"
  elif [[ "${connector_name}" != "${current_connector_name}" ]]; then
    fail "retained trigger configs use mixed connectorName values"
  fi
done

if ! outputs_json="$(azd env get-values --output json 2>"${COMMAND_ERROR_FILE}")"; then
  azd_error="$(cat "${COMMAND_ERROR_FILE}")"
  fail "azd env get-values --output json failed: ${azd_error:-${outputs_json}}"
fi
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"${outputs_json}"; then
  fail "azd env get-values --output json returned invalid JSON"
fi

resource_group_name="$(require_output resourceGroupName)"
connector_namespace_name="$(require_output connectorNamespaceName)"
connector_namespace_connection_name="$(require_output connectorNamespaceConnectionName)"
function_app_name="$(require_output functionAppName)"
subscription_id="$(require_output AZURE_SUBSCRIPTION_ID)"
function_app_hostname="$(optional_output functionAppDefaultHostname)"
if [[ -z "${function_app_hostname}" ]]; then
  function_app_hostname="${function_app_name}.azurewebsites.net"
  echo -e "${YELLOW}azd output 'functionAppDefaultHostname' is unavailable; using compatibility hostname '${function_app_hostname}'.${NC}"
fi

parameters_json=()
for config_file in "${config_files[@]}"; do
  parameter_value="$(build_parameters_json "${config_file}" 2>&1)" || fail "unable to resolve parameters in '${config_file}': ${parameter_value}"
  parameters_json+=("${parameter_value}")
done

authorize_connection

echo -e "${CYAN}Fetching connector extension key for ${function_app_name}...${NC}"
if ! run_az_with_retry "Fetching connector extension key" \
  functionapp keys list \
  --subscription "${subscription_id}" \
  -g "${resource_group_name}" -n "${function_app_name}" \
  --query "systemKeys.connector_extension" -o tsv; then
  fail "could not fetch connector_extension system key: ${AZ_OUTPUT}"
fi
connector_extension_key="${AZ_OUTPUT}"
if [[ -z "${connector_extension_key}" || "${connector_extension_key}" == "null" ]]; then
  fail "could not fetch a non-empty connector_extension system key from ${function_app_name}"
fi

if ! run_az_with_retry "Listing existing Connector Namespace triggers" \
  connector-namespace trigger list \
  --subscription "${subscription_id}" \
  -g "${resource_group_name}" --namespace "${connector_namespace_name}" \
  --query "[].name" -o tsv; then
  fail "could not list existing Connector Namespace triggers: ${AZ_OUTPUT}"
fi
existing_triggers=()
while IFS= read -r existing_trigger; do
  if [[ -n "${existing_trigger}" ]]; then
    existing_triggers+=("${existing_trigger}")
  fi
done <<<"${AZ_OUTPUT}"

echo -e "${YELLOW}Configuring Connector Namespace trigger configs...${NC}"
configured_count=0
failures=()
for ((config_index = 0; config_index < ${#config_files[@]}; config_index++)); do
  if configure_trigger "${config_files[config_index]}" "${parameters_json[config_index]}"; then
    configured_count=$((configured_count + 1))
  else
    failures+=("${CONFIGURE_ERROR}")
    echo -e "${RED}  FAILED: ${CONFIGURE_ERROR}${NC}" >&2
  fi
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo -e "${RED}Configured ${configured_count} of ${#config_files[@]} retained trigger config(s).${NC}" >&2
  for failure_message in "${failures[@]}"; do
    echo -e "${RED}  - ${failure_message}${NC}" >&2
  done
  fail "${#failures[@]} retained trigger config(s) failed; successful operations remain configured and re-running this script is safe"
fi

echo -e "${GREEN}Configured all ${configured_count} retained trigger config(s).${NC}"
echo ""
echo -e "${GREEN}Done. All retained connector triggers are configured.${NC}"
echo -e "${GREEN}   Tail logs: az functionapp log tail -g ${resource_group_name} -n ${function_app_name}${NC}"
echo ""
