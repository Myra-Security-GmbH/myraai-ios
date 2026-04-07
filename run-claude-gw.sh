#! /bin/sh

#ANTHROPIC_BASE_URL="http://127.0.0.1:8081/v1/myratest/prod/anthropic"
#ANTHROPIC_API_KEY=9613bd066f4334acca3a418773d832507708ecdd111345befd5d47a875c20d73

ANTHROPIC_BASE_URL="https://ai-api.myra.eu/v1/myratest/prod/anthropic/chat/completions"
ANTHROPIC_API_KEY=24d2ca1f24c94e1906b43a7479adbc163d8366581eb55ce5b9ec6047841ad46d


HOME=/home/sas/work/ai-gateway/testhome
mkdir -p $HOME/work

export ANTHROPIC_API_KEY ANTHROPIC_BASE_URL

cd $HOME/work && claude --dangerously-skip-permissions $@
