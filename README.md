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

3. Source the scripts. At the very least you need to source `./core.sh` and then subsequently you source any and all scripts that you want to use.

### Reference

If you are unsure of the parameters for a helper function, pass no parameters and it should show the available parameters.
