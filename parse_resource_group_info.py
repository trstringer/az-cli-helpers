#!/usr/bin/python3

import json
import sys

az_group_output = json.load(sys.stdin)
for az_group in az_group_output:
        print(
            f'Name:     {az_group["name"]}\n'
            f'Location: {az_group["location"]}\n'
            f'FQDN:     {az_group["tags"].get("fqdn", "unknown")}\n'
            f'Created:  {az_group["tags"].get("created_on", "unknown")}\n'
            f'Image:    {az_group["tags"].get("image", "unknown")}\n'
            f'Notes:    {az_group["tags"].get("notes", "")}\n'
        )
