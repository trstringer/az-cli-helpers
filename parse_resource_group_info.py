#!/usr/bin/python3

import re
import sys

is_first_line = True
for line in sys.stdin:
    line = re.sub(r' +', ' ', line)
    if line:
        line = line.replace('\n', '')
        split_line = line.split(' ')
        notes = f'\nNotes:    {" ".join(split_line[3:])}' if len(split_line) > 3 else ""
        if not is_first_line:
            print()
        print(
            f'Name:     {split_line[0] if len(split_line) >= 1 else ""}\n'
            f'Location: {split_line[1] if len(split_line) >= 2 else ""}\n'
            f'Created:  {split_line[2] if len(split_line) >= 3 else ""}'
            f'{notes}'
        )
        is_first_line = False
