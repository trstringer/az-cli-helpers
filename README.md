# Azure Linux CLI helpers

Helper shell functions for Azure resource management.

## Index

- [Installation](#installation)
- [Reference](#reference)

### Installation

1. Clone this repository.

2. Set the following environment variables (most likely in your `~/.bashrc`):

```
export AZLH_PREFIX="..."  # e.g. thstring
export AZLH_ADMIN_USERNAME="..."  # e.g. trstringer
export AZLH_REGION="..."  # e.g. eastus
export AZLH_DEFAULT_IMAGE_NAME="Debian:Debian-10:10:latest"
export AZLH_SSH_KEY_FILE="..."
```

3. Add the following to `~/.bashrc`:

```
# Import Azure CLI helpers.
CLI_HELPERS_SCRIPT="/home/trstringer/dev/azure/cli_helpers.sh"
if [[ -f "$CLI_HELPERS_SCRIPT"  ]]; then
    source "$CLI_HELPERS_SCRIPT"
fi
```

Note: Change `$CLI_HELPERS_SCRIPT` to the correct location of the script on your machine.

### Reference

If you are unsure of the parameters for a helper function, pass no parameters and it should show the available parameters.
