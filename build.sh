#!/bin/bash
# Copyright 2023 Pangea Cyber Corporation
# Author: Pangea Cyber Corporation

yarn run build
export EMBEDDED_TEMPLATE="$(cat index.html)"
envsubst < src/pangea-gpt.py > bin/pangea-gpt.py
chmod +x bin/pangea-gpt.py
