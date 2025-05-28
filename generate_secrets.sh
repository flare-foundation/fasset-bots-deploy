generate_secrets() {
    echo $(
        docker run --rm -v $PWD/config/secrets.json.template:/usr/src/app/secrets.json.template \
            ghcr.io/flare-foundation/fasset-bots:latest yarn key-gen generateSecrets \
            --agent "$1" --other -c "./packages/fasset-bots-core/run-config/${CHAIN}-bot.json"
    )
}

if [[ -e "$PWD/secrets.json" ]]; then
    echo 'error: local file "secrets.json" already exists, remove it manually before proceeding.'
    exit 1
fi

if [ -z "$1" ]; then
    echo "error: please provide the agent's management address as the argument"
    exit 1
fi

generate_secrets "$1" | jq > secrets.json