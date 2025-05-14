#!/usr/bin/env bash
source <(grep -v '^#' "./.env" | sed -E 's|^(.+)=(.*)$|: ${\1=\2}; export \1|g')

CONFIG_PATH="$PWD/config.json"
SECRETS_PATH="$PWD/secrets.json"

NOTIFIER_API_URL="http://localhost:1234${BACKEND_PATH}"
API_NOTIFIER_CONFIG=$(cat <<EOF
{
    "apiKey": "${NOTIFIER_API_KEY}",
    "apiUrl": "${NOTIFIER_API_URL}"
}
EOF
)

generate_config_json() {
    echo "{}"
}

generate_secrets() {
    echo $(
        docker run --rm -v $PWD/config/secrets.json.template:/usr/src/app/secrets.json.template \
            ghcr.io/flare-foundation/fasset-bots:latest yarn key-gen generateSecrets \
            --agent $AGENT_MANAGEMENT_ADDRESS --other -c "./packages/fasset-bots-core/run-config/${CHAIN}-bot.json"
    )
}

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
    echo "config file $CONFIG_PATH does not exist, generating a new one."
    generate_config_json | jq > $CONFIG_PATH
fi

# create secrets if not exist
if [ ! -e $SECRETS_PATH ]; then
    echo "secrets file $SECRETS_PATH does not exist, generating a new one."
    generate_secrets | jq > $SECRETS_PATH
fi

# write chain configuration
update_config_json ".extends = \"${CHAIN}-bot-postgresql.json\""

# write frontend password inside config
update_secrets_json ".apiKey.agent_bot = \"${FRONTEND_PASSWORD}\""

# write notifier api key inside secrets
update_secrets_json ".apiKey.notifier_key = \"${NOTIFIER_API_KEY}\""

# write database config
update_config_json ".
    | (.ormOptions.type = \"postgresql\")
    | (.ormOptions.host = \"postgres\")
    | (.ormOptions.dbName = \"${FASSET_DB_NAME}\")
    | (.ormOptions.port = 5432)"

# write database secrets
update_secrets_json ".
    | (.database.user = \"${FASSET_DB_USER}\")
    | (.database.password = \"${FASSET_DB_PASSWORD}\")"

# update notifier api key inside config
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
    update_config_json ".apiNotifierConfigs += [$API_NOTIFIER_CONFIG]"
fi