#! /bin/sh

ANTHROPIC_BASE_URL="http://127.0.0.1:8081/v1/myratest/prod/anthropic"
ANTHROPIC_API_KEY=9613bd066f4334acca3a418773d832507708ecdd111345befd5d47a875c20d73

HOME=/home/sas/work/ai-gateway/testhome
mkdir -p $HOME/work

export ANTHROPIC_API_KEY ANTHROPIC_BASE_URL

cd $HOME/work && claude --dangerously-skip-permissions
