#!/usr/bin/env bash
#
# Show Mutagen sync status
#

mutagen sync list --label-selector=name=claude-remote 2>/dev/null || echo "No sync session running"
