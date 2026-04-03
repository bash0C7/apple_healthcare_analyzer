#!/bin/bash
cd "$(dirname "$0")/.."
exec bundle exec ruby scripts/mcp_server.rb
