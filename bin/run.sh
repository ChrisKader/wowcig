#!/bin/bash
set -e
eval $(.lua/bin/luarocks path)
.lua/bin/luacheck .
.lua/bin/lua wowcig.lua "$@"
