#!/bin/bash

yarn run build
export EMBEDDED_TEMPLATE="$(cat index.html)"
envsubst < src/pangea-gpt.py > bin/pangea-gpt.py
chmod +x bin/pangea-gpt.py
