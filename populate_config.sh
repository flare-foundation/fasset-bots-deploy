#!/usr/bin/env bash
set -e
source <(grep -v '^#' "./.env" | sed -E 's|^(.+)=(.*)$|: ${\1=\2}; export \1|g')

# params

DOCKER_USER_UID=1000
CONFIG_PATH="$PWD/config.json"
SECRETS_PATH="$PWD/secrets.json"

FXRP_SYMBOL=FXRP
if [ $CHAIN == 'coston' -o $CHAIN == 'coston2' ]; then
    FXRP_SYMBOL=FTestXRP
fi

# do some basic checks

if ! command -v jq > /dev/null 2>&1; then
    echo "error: jq is not installed."
    exit 1
fi

if [ "$UID" -ne 1000 -a "$UID" -ne 0 ]; then
    echo "error: running with non-root user with UID $UID != 1000."
    exit 1
fi

if [ ! -e $SECRETS_PATH ]; then
    echo "error: file $SECRETS_PATH does not exist. Run 'bash generate_secrets.sh <agent management address>' and securly store a copy."
    exit 1
fi

if [[ ! "$MACHINE_ADDRESS" =~ ^https?:// ]]; then
    echo "error: machine address should start with 'http' or 'https'"
    exit 1
fi

if ! jq -e ".pricePublisher" $SECRETS_PATH > /dev/null; then
    echo "error: pricePublisher account must be present in secrets.json"
    exit 1
fi

if [[ $XRP_RPC_URL == *","* ]] || [[ $XRP_RPC_API_KEY == *","* ]]; then
    echo "error: due to inconsistent states between nodes 'XRP_RPC_URL' and 'XRP_RPC_URL' must be of length one."
fi

if [[ $NATIVE_RPC_URL == *","* ]] || [[ $NATIVE_RPC_API_KEY == *","* ]]; then
    echo "error: due to inconsistent states between nodes 'NATIVE_RPC_URL' and 'NATIVE_RPC_API_KEY' must be of length one."
fi

safe_json_update() {
    tmp="$(mktemp "$(dirname "$2")/config.XXXXXX.json")"
    if ! jq "$1" "$2" > "$tmp"; then
        echo "jq failed updating $2." >&2
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$2"
}

update_config_json() {
    safe_json_update "$1" "$CONFIG_PATH"
}

update_secrets_json() {
    safe_json_update "$1" "$SECRETS_PATH"
}

fetch_config_json() {
    cat "$CONFIG_PATH" | jq "$1"
}

fetch_secrets_json() {
    cat "$SECRETS_PATH" | jq "$1"
}

# create config if not exists
if [ ! -e $CONFIG_PATH ]; then
    echo "{}" | jq > $CONFIG_PATH
fi

# write chain config
update_config_json ".extends = \"$CHAIN-bot-postgresql.json\""

# enable price publishing
update_config_json ".pricePublisherConfig.enabled = true"

# write database config
update_config_json ".
    | (.ormOptions.type = \"postgresql\")
    | (.ormOptions.host = \"postgres\")
    | (.ormOptions.dbName = \"$FASSET_DB_NAME\")
    | (.ormOptions.port = 5432)"

# write database secrets
update_secrets_json ".
    | (.database.user = \"$FASSET_DB_USER\")
    | (.database.password = \"$FASSET_DB_PASSWORD\")"

# write frontend password inside config
update_secrets_json ".apiKey.agent_bot = \"$FRONTEND_PASSWORD\""

# write notifier api key inside secrets
update_secrets_json ".apiKey.notifier_key = \"$NOTIFIER_API_KEY\""

# write native node rpc

if [ -n "$NATIVE_RPC_URL" ]; then
    update_config_json ".rpcUrl = \"$NATIVE_RPC_URL\""
else
    echo "error: .env variable 'NATIVE_RPC_URL' is required."
    exit 1
fi

if [ -n "$NATIVE_RPC_API_KEY" ]; then
    update_secrets_json ".apiKey.native_rpc = \"$NATIVE_RPC_API_KEY\""
else
    echo "error: .env variable 'NATIVE_RPC_API_KEY' is required."
    exit 1
fi

# write ripple node rpc

if [ -n "$XRP_RPC_URL" ]; then
    update_config_json ".fAssets.$FXRP_SYMBOL.walletUrls = [\"${XRP_RPC_URL}\"]"
else
    echo "error: .env variable 'XRP_RPC_URL' is required."
    exit 1
fi

if [ -n "$XRP_RPC_API_KEY" ]; then
    sym=$([ $CHAIN == 'flare' -o $CHAIN == 'songbird' ] && echo XRP || echo testXRP)
    update_secrets_json ".apiKey.${sym}_rpc = [\"$XRP_RPC_API_KEY\"]"
else
    echo "error: .env variable 'XRP_RPC_API_KEY' is required."
    exit 1
fi

# write dal api urls and api keys

dal_urls=()
if [ -n "$DAL_URLS" ]; then
    IFS=',' read -r -a dal_urls <<< "$DAL_URLS"
fi

dal_api_keys=()
if [ -n "$DAL_API_KEYS" ]; then
    IFS=',' read -r -a dal_api_keys <<< "$DAL_API_KEYS"
fi

if [ "${#dal_urls[@]}" -ne "${#dal_api_keys[@]}" ]; then
    echo "error: .env variables 'DAL_URLS' and 'DAL_API_KEYS' require equal lengths."
    exit 1
fi

if [ "${#dal_urls[@]}" -gt 0 ]; then
    urls=$(printf '%s\n' "${dal_urls[@]}" | jq -R . | jq -s .)
    update_config_json ".dataAccessLayerUrls = $urls"
else
    echo "error: .env variable 'DAL_URLS' requires at least one value."
    exit 1
fi

if [ "${#dal_api_keys[@]}" -gt 0 ]; then
    keys=$(printf '%s\n' "${dal_api_keys[@]}" | jq -R . | jq -s .)
    update_secrets_json ".apiKey.data_access_layer = $keys"
else
    echo "error: .env variable 'DAL_API_KEYS' requires at least one value."
fi

# indexer urls and api keys

xrp_indexer_urls=()
if [ -n "$XRP_INDEXER_URLS" ]; then
    IFS=',' read -r -a xrp_indexer_urls <<< "$XRP_INDEXER_URLS"
fi

xrp_indexer_api_keys=()
if [ -n "$XRP_INDEXER_API_KEYS" ]; then
    IFS=',' read -r -a xrp_indexer_api_keys <<< "$XRP_INDEXER_API_KEYS"
fi

if [ "${#xrp_indexer_urls[@]}" -ne "${#xrp_indexer_api_keys[@]}" ]; then
    echo "error: .env variables 'XRP_INDEXER_URLS' and 'XRP_INDEXER_API_KEYS' require equal lengths."
    exit 1
fi

if [ "${#xrp_indexer_urls[@]}" -gt 0 ]; then
    urls=$(printf '%s\n' "${xrp_indexer_urls[@]}" | jq -R . | jq -s .)
    update_config_json ".fAssets.$FXRP_SYMBOL.indexerUrls = $urls"
else
    echo "error: .env variable 'XRP_INDEXER_URLS' requires at least one value."
    exit 1
fi

if [ "${#xrp_indexer_api_keys[@]}" -gt 0 ]; then
    keys=$(printf '%s\n' "${xrp_indexer_api_keys[@]}" | jq -R . | jq -s .)
    update_secrets_json ".apiKey.indexer = $keys"
else
    echo "error: .env variable 'XRP_INDEXER_API_KEYS' requires at least one value."
    exit 1
fi

# write notifier api key config

NOTIFIER_API_URL="http://localhost:1234$BACKEND_PATH"

push_notifier_config=1
if ! jq -e 'has("apiNotifierConfigs")' $CONFIG_PATH > /dev/null; then
    update_config_json '.apiNotifierConfigs = []'
else
    for i in $(seq 0 $(fetch_config_json '.apiNotifierConfigs | length')); do
        if jq -e ".apiNotifierConfigs[$i].apiUrl == \"$NOTIFIER_API_URL\"" $CONFIG_PATH > /dev/null; then
            update_config_json ".apiNotifierConfigs[$i].apiKey = \"$NOTIFIER_API_KEY\""
            push_notifier_config=0
            break
        fi
    done
fi
if [ $push_notifier_config == 1 ]; then
    update_config_json ".apiNotifierConfigs += [$(jq -n \
        --arg apiKey "$NOTIFIER_API_KEY" \
        --arg apiUrl "$NOTIFIER_API_URL" \
        '{apiKey: $apiKey, apiUrl: $apiUrl}')]"
fi

# write core vault automation config

if [ -z "$AUTOMATE_CORE_VAULT_TRANSFERS" ]; then
    AUTOMATE_CORE_VAULT_TRANSFERS=false
fi
update_config_json ".agentBotSettings.fAssets.$FXRP_SYMBOL.useAutomaticCoreVaultTransferAndReturn = $AUTOMATE_CORE_VAULT_TRANSFERS"

if [ -n "$TRANSFER_TO_CORE_VAULT_THRESHOLD_RATIO" ]; then
    update_config_json ".agentBotSettings.fAssets.$FXRP_SYMBOL.transferToCVRatio = $TRANSFER_TO_CORE_VAULT_THRESHOLD_RATIO"
else
    update_config_json "del(.agentBotSettings.fAssets.$FXRP_SYMBOL.transferToCVRatio)"
fi

if [ -n "$TRANSFER_TO_CORE_VAULT_TARGET_RATIO" ]; then
    update_config_json ".agentBotSettings.fAssets.$FXRP_SYMBOL.targetTransferToCVRatio = $TRANSFER_TO_CORE_VAULT_TARGET_RATIO"
else
    update_config_json "del(.agentBotSettings.fAssets.$FXRP_SYMBOL.targetTransferToCVRatio)"
fi

if [ -n "$RETURN_FROM_CORE_VAULT_THRESHOLD_RATIO" ]; then
    update_config_json ".agentBotSettings.fAssets.$FXRP_SYMBOL.returnFromCVRatio = $RETURN_FROM_CORE_VAULT_THRESHOLD_RATIO"
else
    update_config_json "del(.agentBotSettings.fAssets.$FXRP_SYMBOL.returnFromCVRatio)"
fi

if [ -n "$RETURN_FROM_CORE_VAULT_TARGET_RATIO" ]; then
    update_config_json ".agentBotSettings.fAssets.$FXRP_SYMBOL.targetReturnFromCVRatio = $RETURN_FROM_CORE_VAULT_TARGET_RATIO"
else
    update_config_json "del(.agentBotSettings.fAssets.$FXRP_SYMBOL.targetReturnFromCVRatio)"
fi

# change mounts owner and secrets permissions
chown $DOCKER_USER_UID:$DOCKER_USER_UID $SECRETS_PATH
chown $DOCKER_USER_UID:$DOCKER_USER_UID $CONFIG_PATH
chown -R $DOCKER_USER_UID:$DOCKER_USER_UID ./log
chmod 600 $SECRETS_PATH
