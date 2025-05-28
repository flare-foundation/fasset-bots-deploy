generate_secrets() {
    echo $(
        docker run --rm -v $PWD/config/secrets.json.template:/usr/src/app/secrets.json.template \
            ghcr.io/flare-foundation/fasset-bots:latest yarn key-gen generateSecrets \
            --agent "$1" --other -c "./packages/fasset-bots-core/run-config/${CHAIN}-bot.json"
    )
}

if [ -z "$1" ]; then
    echo "Error: please provide the agent's management address as the argument"
    exit 1
fi

generate_secrets "$1" | jq > secrets.json