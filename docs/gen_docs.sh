#! /bin/sh

mkdocs build || exit 1

python3 generate-llms.py --full || exit 2
