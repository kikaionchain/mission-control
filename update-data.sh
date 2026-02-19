#!/bin/bash
# Mission Control data updater
# Run by cron or manually to refresh dashboard data
# Reads from OS files and generates data.json

WORKSPACE="/Users/kikai/clawd"
OUTPUT="$WORKSPACE/mission-control/data.json"

# Read active task
ACTIVE_TASK=""
TASK_STATUS="IDLE"
TASK_NAME="No active task"
CHECKLIST_JSON="[]"

if [ -f "$WORKSPACE/ops/ACTIVE-TASK.md" ]; then
  TASK_NAME=$(grep "^## Task:" "$WORKSPACE/ops/ACTIVE-TASK.md" | sed 's/## Task: //' | head -1)
  TASK_STATUS=$(grep "^\*\*Status:\*\*" "$WORKSPACE/ops/ACTIVE-TASK.md" | sed 's/\*\*Status:\*\* //' | head -1)
  
  # Parse checklist
  CHECKLIST_JSON=$(grep -E "^\- \[" "$WORKSPACE/ops/ACTIVE-TASK.md" | python3 -c "
import sys, json
items = []
for line in sys.stdin:
    line = line.strip()
    done = line.startswith('- [x]')
    text = line.replace('- [x] ', '').replace('- [ ] ', '')
    items.append({'done': done, 'text': text})
print(json.dumps(items))
" 2>/dev/null || echo "[]")
fi

# Read goals from GOALS.md
GOALS_JSON=$(python3 -c "
import json
goals = []
try:
    with open('$WORKSPACE/GOALS.md') as f:
        content = f.read()
    # Simple parser for ### headers under ## sections
    sections = content.split('### ')
    for s in sections[1:]:
        name = s.split('\n')[0].strip()
        if 'activated' in s.lower() or 'backburner' in s.lower():
            progress = 10
        elif 'Live' in s or 'Ongoing' in s:
            progress = 50
        elif 'RIGHT NOW' in content.split('### ' + name)[0][-200:]:
            progress = 30
        else:
            progress = 15
        goals.append({'name': name, 'progress': progress})
except Exception as e:
    goals = [{'name': 'Error reading goals', 'progress': 0}]
print(json.dumps(goals[:5]))
" 2>/dev/null || echo "[]")

# Current priority
PRIORITY_NAME=$(grep -A1 "^### .*RIGHT NOW" "$WORKSPACE/GOALS.md" 2>/dev/null | tail -1 | sed 's/### //' || echo "None set")
PRIORITY_DETAIL=$(grep -A3 "^## Current Priority" "$WORKSPACE/GOALS.md" 2>/dev/null | grep "^-" | head -1 | sed 's/^- //' || echo "")

# Cron job data - read from OpenClaw's cron list
# We use a pre-generated cron snapshot if available
CRON_JSON="[]"
if [ -f "$WORKSPACE/mission-control/cron-snapshot.json" ]; then
  CRON_JSON=$(cat "$WORKSPACE/mission-control/cron-snapshot.json")
fi

# Recent activity from today's memory file
TODAY=$(date +%Y-%m-%d)
ACTIVITY_JSON=$(python3 -c "
import json, os
from datetime import datetime
activity = []
memfile = '$WORKSPACE/memory/$TODAY.md'
if os.path.exists(memfile):
    with open(memfile) as f:
        for line in f:
            line = line.strip()
            if line.startswith('- ') and len(line) > 5:
                text = line[2:]
                icon = '📝'
                if 'cron' in text.lower(): icon = '⏱'
                elif 'fix' in text.lower() or 'error' in text.lower(): icon = '🔧'
                elif 'build' in text.lower() or 'creat' in text.lower(): icon = '🏗'
                elif 'wjp' in text.lower(): icon = '👤'
                elif 'clean' in text.lower(): icon = '🧹'
                activity.append({'time': '', 'icon': icon, 'text': text})
# Add from ops/output recent files
try:
    outputs = sorted(os.listdir('$WORKSPACE/ops/output/'))
    today_outputs = [f for f in outputs if f.startswith('$TODAY')]
    for f in today_outputs[-5:]:
        activity.append({'time': '', 'icon': '📄', 'text': 'Output: ' + f})
except: pass
print(json.dumps(activity[-15:]))
" 2>/dev/null || echo "[]")

# Check Yama status
YAMA_STATUS="unknown"
if ssh -o ConnectTimeout=3 -o BatchMode=yes yama "echo ok" &>/dev/null; then
  YAMA_STATUS="online"
else
  YAMA_STATUS="offline"
fi

# Build final JSON
python3 -c "
import json
from datetime import datetime

data = {
    'updatedAt': datetime.now().isoformat(),
    'activeTask': {
        'name': $(python3 -c "import json; print(json.dumps('$TASK_NAME'))" 2>/dev/null || echo '""'),
        'status': $(python3 -c "import json; print(json.dumps('$TASK_STATUS'))" 2>/dev/null || echo '""'),
        'checklist': $CHECKLIST_JSON
    },
    'crons': $CRON_JSON,
    'goals': $GOALS_JSON,
    'currentPriority': {
        'name': 'Perfect the OS',
        'detail': 'Mission Control + Alex Finn standard + triple check everything'
    },
    'activity': $ACTIVITY_JSON,
    'agents': {
        'kikai': 'online',
        'yama': '$YAMA_STATUS'
    }
}
print(json.dumps(data, indent=2))
" > "$OUTPUT"

echo "Mission Control data updated: $OUTPUT"
