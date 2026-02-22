#!/bin/bash
# Mission Control — generates data.json for the work board
# Projects-first format: For Crypto, Divvvy, 67, OS (no Kanso)
# Run by cron (every 2h) or manually.

WORKSPACE="/Users/kikai/clawd"
OUTPUT="$WORKSPACE/mission-control/data.json"
INTEL_FILE="$WORKSPACE/mission-control/intel.json"
CRON_FILE="$HOME/.openclaw/cron/jobs.json"

python3 << 'PYEOF'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

WORKSPACE = "/Users/kikai/clawd"
CRON_FILE = os.path.expanduser("~/.openclaw/cron/jobs.json")
SESSIONS_DIR = os.path.expanduser("~/.openclaw/agents/main/sessions")
OUTPUT = f"{WORKSPACE}/mission-control/data.json"
INTEL_FILE = f"{WORKSPACE}/mission-control/intel.json"
now_iso = datetime.now(timezone.utc).isoformat()
now_ms  = int(datetime.now(timezone.utc).timestamp() * 1000)
today   = datetime.now().strftime("%Y-%m-%d")

def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except:
        return ""

# ─── ACTIVE TASK PARSER ────────────────────────────────────────
def parse_active_task(md):
    """Return (title, status, last_done_phases, next_unchecked, blocked_on)"""
    title, status, blocked_on = "Unknown task", "IN_PROGRESS", None
    last_done = []
    next_action = "Continue task"

    for line in md.splitlines():
        if line.startswith("# ACTIVE TASK:"):
            title = line.replace("# ACTIVE TASK:", "").strip()
        if line.startswith("**Status:**"):
            status = line.replace("**Status:**", "").strip()
        if "✅ DONE" in line and line.startswith("##"):
            ph = re.sub(r'\s*\(.*?\)\s*', '', line.replace("##","").replace("✅ DONE","")).strip()
            if ph: last_done.append(ph)
        if "blocked on" in line.lower() and not blocked_on:
            m = re.search(r'blocked on[:\s]+(.+)', line, re.IGNORECASE)
            if m: blocked_on = m.group(1).strip().rstrip('.')
        if line.strip().startswith("- [ ]") and next_action == "Continue task":
            next_action = line.strip().replace("- [ ]", "").strip()

    last_update = ". ".join(last_done[-2:]) + "." if last_done else "Task in progress."
    return title, status, last_update, next_action, blocked_on

# ─── NEEDS-WJP PARSER ─────────────────────────────────────────
def parse_needs_wjp(md):
    """Return list of {id, project, title, urgency, ask, impact, updatedAt}"""
    items = []
    if not md:
        return items

    content = md.split("## ✅")[0]
    content = content.split("## How to Use")[0]

    urgency_map = {}  # will fill from section headers

    current_urgency = "medium"
    lines = content.split("\n")
    for line in lines:
        if "🔴" in line or "Blocking" in line: current_urgency = "critical"
        elif "🟠" in line or "Enabling" in line: current_urgency = "high"
        elif "🟡" in line or "Signal" in line: current_urgency = "medium"

    blocks = content.split("\n### ")
    cur_urg = "medium"
    for raw in blocks[1:]:  # skip block[0] = file preamble
        lines2 = raw.split("\n")
        title_line = lines2[0].strip()
        if not title_line or "Archive" in title_line or "How to Use" in title_line:
            continue
        # Skip Kanso/Agency items — project dropped
        if any(k in title_line.lower() for k in ["agency", "kanso"]):
            continue

        block_text = "### " + raw
        if "🔴" in block_text[:100] or "CRITICAL" in title_line.upper() or "🚨" in title_line:
            urg = "critical"
        elif "🟠" in block_text[:100]:
            urg = "high"
        elif "🟡" in block_text[:100]:
            urg = "medium"
        else:
            # detect from position in file
            pos = md.find("### " + title_line)
            before = md[:pos] if pos > 0 else ""
            last_red = before.rfind("🔴")
            last_yellow = before.rfind("🟡")
            last_orange = before.rfind("🟠")
            mx = max(last_red, last_yellow, last_orange)
            if mx == last_red and last_red > -1: urg = "critical"
            elif mx == last_orange and last_orange > -1: urg = "high"
            else: urg = "medium"
            if "CRITICAL" in title_line.upper() or "🚨" in title_line:
                urg = "critical"

        ask_m = re.search(r'\*\*Ask:\*\*\s*(.+)', raw)
        ask = ask_m.group(1).strip() if ask_m else title_line[:80]
        impact_m = re.search(r'\*\*Impact:\*\*\s*(.+)', raw)
        impact = impact_m.group(1).strip() if impact_m else ""

        # Detect project
        project = "General"
        raw_lower = raw.lower()
        title_lower = title_line.lower()
        if "forcrypto" in raw_lower or "for crypto" in title_lower or "pr #7" in title_lower or "dns" in title_lower:
            project = "For Crypto"
        elif "67" in title_line and "brand" in raw_lower:
            project = "67"
        elif "agency" in title_lower or "kanso" in title_lower:
            project = "General"  # Kanso dropped
        elif "divvvy" in title_lower:
            project = "Divvvy"
        if "67" in title_line[:5]:
            project = "67"

        title_clean = re.sub(r'^#+\s*', '', title_line).strip()
        title_clean = re.sub(r'^\d+\.\s*', '', title_clean).strip()  # strip "1. ", "2. " etc
        title_clean = re.sub(r'^🚨\s*CRITICAL:\s*', '', title_clean).strip()  # strip 🚨 CRITICAL: prefix

        items.append({
            "id": re.sub(r'[^a-z0-9-]', '-', title_clean.lower())[:40],
            "project": project,
            "title": title_clean,
            "urgency": urg,
            "ask": ask,
            "impact": impact,
            "updatedAt": now_iso,
        })

    return items

# ─── SESSION ANALYSIS (Kikai context %) ───────────────────────
def kikai_session_info():
    """Return (status, workingOn, contextPct, sessionDurationMin, lastActivityMin)"""
    if not os.path.exists(SESSIONS_DIR):
        return "online", "idle", 0, None, None

    session_files = []
    for fname in os.listdir(SESSIONS_DIR):
        if fname.endswith(".jsonl") and ".deleted." not in fname:
            fpath = os.path.join(SESSIONS_DIR, fname)
            try:
                mtime_ms = int(os.path.getmtime(fpath) * 1000)
                size = os.path.getsize(fpath)
                session_files.append((mtime_ms, size, fpath))
            except:
                pass

    if not session_files:
        return "online", "idle", 0, None, None

    session_files.sort(reverse=True)  # most recent first
    recent = [f for f in session_files if (now_ms - f[0]) < 4 * 3600 * 1000]

    if not recent:
        return "online", "idle", 0, None, None

    # Most recently active session
    latest_mtime, latest_size, latest_path = recent[0]
    last_activity_min = (now_ms - latest_mtime) // 60000

    # Oldest session in this "run" (last 4 hours)
    oldest_mtime = min(f[0] for f in recent)
    session_duration_min = (now_ms - oldest_mtime) // 60000

    # Context % estimate: largest recent session file / 800KB baseline
    # (800KB ≈ full 200k token context in JSONL encoding)
    max_size = max(f[1] for f in recent)
    ctx_pct = min(95, int(max_size / 8000))  # 8000 bytes per %

    status = "active" if last_activity_min < 10 else "online"

    # Try to read working-on from ACTIVE-TASK
    active_task_md = read_file(f"{WORKSPACE}/ops/ACTIVE-TASK.md")
    working_on = "idle"
    if active_task_md:
        for line in active_task_md.splitlines():
            if line.startswith("# ACTIVE TASK:"):
                working_on = line.replace("# ACTIVE TASK:", "").strip()
                break

    return status, working_on, ctx_pct, int(session_duration_min), int(last_activity_min)

# ─── YAMA STATUS ───────────────────────────────────────────────
def yama_status():
    """Return (status, workingOn, contextPct, sessionDurationMin, lastActivityMin)"""
    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes", "yama",
             "cat ~/clawd/ops/ACTIVE-TASK.md 2>/dev/null | head -5; "
             "ls -lt ~/.openclaw/agents/main/sessions/*.jsonl 2>/dev/null | head -3 | awk '{print $5, $6}'"],
            capture_output=True, text=True, timeout=6
        )
        if result.returncode != 0:
            return "offline", "idle", 0, None, None

        out = result.stdout.strip()
        working_on = "idle"
        for line in out.splitlines():
            if "# ACTIVE TASK:" in line:
                working_on = line.replace("# ACTIVE TASK:", "").strip()
                break

        # Try to parse session file sizes (ls -lt output: first col is size)
        sizes = []
        for line in out.splitlines():
            parts = line.strip().split()
            # ls -lt format: "475607 /path/..." or just size
            if parts and parts[0].isdigit() and int(parts[0]) > 1000:
                sizes.append(int(parts[0]))

        ctx_pct = 0
        if sizes and max(sizes) > 10000:
            ctx_pct = min(90, int(max(sizes) / 8000))

        return "ssh-only", working_on, ctx_pct, None, None

    except Exception as e:
        return "offline", "idle", 0, None, None

# ─── CRON HEALTH ───────────────────────────────────────────────
def cron_health():
    healthy, errors = 0, 0
    if os.path.exists(CRON_FILE):
        try:
            with open(CRON_FILE) as f:
                cron_data = json.load(f)
            for job in cron_data.get("jobs", []):
                if not job.get("enabled", True):
                    continue
                errs = job.get("state", {}).get("consecutiveErrors", 0)
                if errs > 0: errors += 1
                else: healthy += 1
        except:
            pass
    return healthy, errors

# ─── KEY FILES ─────────────────────────────────────────────────
def build_files():
    sources = [
        ("ACTIVE TASK", f"{WORKSPACE}/ops/ACTIVE-TASK.md",   "⚡"),
        ("NEEDS WJP",   f"{WORKSPACE}/ops/NEEDS-WJP.md",     "🔴"),
        ("SESSION STATE",f"{WORKSPACE}/SESSION-STATE.md",    "💾"),
        ("GOALS",       f"{WORKSPACE}/GOALS.md",              "🎯"),
        ("CORRECTIONS", f"{WORKSPACE}/CORRECTIONS.md",        "📋"),
        ("MEMORY",      f"{WORKSPACE}/MEMORY.md",             "🧠"),
        ("TODAY'S LOG", f"{WORKSPACE}/memory/{today}.md",    "📅"),
    ]
    files = []
    for name, path, icon in sources:
        content = read_file(path)
        if not content.strip():
            continue
        plain_lines = [
            l for l in content.splitlines()
            if l.strip() and not l.startswith('#') and not l.startswith('---')
        ]
        preview_raw = plain_lines[0][:160] if plain_lines else ""
        # Strip markdown from preview
        preview = re.sub(r'\*{1,3}([^*]+)\*{1,3}', r'\1', preview_raw)
        preview = re.sub(r'`[^`]+`', '', preview)
        preview = re.sub(r'^\s*[-*+]\s+', '', preview).strip()
        files.append({
            "name": name, "icon": icon,
            "path": path.replace(WORKSPACE + "/", ""),
            "content": content,
            "preview": preview,
        })
    return files

# ─── INTEL ─────────────────────────────────────────────────────
def load_intel():
    try:
        with open(INTEL_FILE) as f:
            data = json.load(f)
        items = data.get("items", [])
        generated = data.get("generated_at", now_iso)
        return [{"text": t, "time": generated} for t in items]
    except:
        return []

# ═══════════════════════════════════════════════════════════════
# BUILD PROJECTS
# ═══════════════════════════════════════════════════════════════

active_task_md = read_file(f"{WORKSPACE}/ops/ACTIVE-TASK.md")
needs_wjp_md   = read_file(f"{WORKSPACE}/ops/NEEDS-WJP.md")
goals_md        = read_file(f"{WORKSPACE}/GOALS.md")

# Parse active task
fc_title, fc_status, fc_last, fc_next, fc_blocked = parse_active_task(active_task_md)
fc_task_status = "blocked" if fc_blocked else "active"

# Parse needs-wjp
all_needs_wjp = parse_needs_wjp(needs_wjp_md)

# Project: needs-to-do lists (cross-reference from all_needs_wjp + goals)
def needs_for_project(proj_keywords, wjp_items, extra=None):
    result = []
    for item in wjp_items:
        if any(k.lower() in (item.get("project","")+" "+item.get("title","")).lower()
               for k in proj_keywords):
            result.append({
                "id": item["id"],
                "text": f"WJP: {item['ask']}",
                "wjp": True,
                "urgent": item["urgency"] == "critical",
            })
    if extra:
        result.extend(extra)
    return result

projects = [
    {
        "id": "for-crypto",
        "name": "For Crypto",
        "priority": 1,
        "status": "Active",
        "color": "#00D9FF",
        "description": 'Cosell marketplace — "Sell. Cosell. For Crypto." USDC on Base + Solana.',
        "tasks": [
            {
                "id": "fc-testing",
                "title": fc_title,
                "owner": "Kikai",
                "status": fc_task_status,
                "lastUpdate": fc_last,
                "nextAction": fc_next,
            }
        ],
        "needsToDo": needs_for_project(
            ["for crypto", "forcrypto", "dns", "pr #7", "pr7"],
            all_needs_wjp,
            extra=[
                {
                    "id": "phase-b",
                    "text": "Kikai: Complete Phase B (auth) → unblocks Phases D + E",
                    "wjp": False,
                    "urgent": fc_blocked is not None,
                }
            ] if fc_task_status == "blocked" else []
        ),
    },
    {
        "id": "divvvy",
        "name": "Divvvy",
        "priority": 2,
        "status": "Building",
        "color": "#f472b6",
        "description": "Payment splitting on Base chain. GTM: \"Kickstarter of crypto\", 1% fee.",
        "tasks": [
            {
                "id": "divvvy-gtm",
                "title": "GTM report done — awaiting activation",
                "owner": "Kikai",
                "status": "queued",
                "lastUpdate": "GTM report complete. Parked while For Crypto is #1. Priority #2 means it's next.",
                "nextAction": "WJP signals activation → pick up from GTM report",
            }
        ],
        "needsToDo": needs_for_project(
            ["divvvy"],
            all_needs_wjp,
            extra=[{
                "id": "divvvy-go",
                "text": "WJP: Signal when to activate Divvvy (GTM report ready, just need the GO)",
                "wjp": True,
                "urgent": False,
            }]
        ),
    },
    {
        "id": "67",
        "name": "67",
        "priority": 3,
        "status": "Paused",
        "color": "#FFD700",
        "description": "Cultural meme coin on Solana. Anti-hype, ironic tone. 3 posts/day via cron.",
        "tasks": [
            {
                "id": "67-posts",
                "title": "Daily content — 3 posts/day (currently dark)",
                "owner": "Kikai",
                "status": "paused",
                "lastUpdate": "WJP disabled posts Feb 19. fal.ai balance topped up. Posts ready to resume on GO.",
                "nextAction": "WJP GO signal → re-enable crons + Phase 1 community rebuild",
            }
        ],
        "needsToDo": needs_for_project(
            ["67"],
            all_needs_wjp,
        ),
    },
    {
        "id": "os",
        "name": "OS",
        "priority": 4,
        "status": "Active",
        "color": "#a78bfa",
        "description": "Internal agent operating system — skills, crons, memory, session hygiene.",
        "tasks": [
            {
                "id": "os-maintenance",
                "title": "Ongoing OS maintenance",
                "owner": "Kikai",
                "status": "active",
                "lastUpdate": "28 skills audited + Anthropic-clean (Feb 20). Crons: 11 healthy, 0 errors.",
                "nextAction": "Monitor cron health, respond to morning brief, maintain memory",
            }
        ],
        "needsToDo": [],
    },
]

# ─── AGENTS ────────────────────────────────────────────────────
k_status, k_working, k_ctx, k_dur, k_last = kikai_session_info()
y_status, y_working, y_ctx, y_dur, y_last = yama_status()

agents = {
    "kikai": {
        "status": k_status,
        "workingOn": k_working,
        "contextPct": k_ctx,
        "model": "claude-sonnet-4-6",
        "sessionDurationMin": k_dur,
        "lastActivityMin": k_last,
        "rateLimit": False,
    },
    "yama": {
        "status": y_status,
        "workingOn": y_working or "idle",
        "contextPct": y_ctx,
        "model": "claude-sonnet-4-6",
        "sessionDurationMin": y_dur,
        "lastActivityMin": y_last,
        "rateLimit": False,
    },
}

# ─── ASSEMBLE ──────────────────────────────────────────────────
cron_ok, cron_err = cron_health()

data = {
    "updatedAt": now_iso,
    "projects": projects,
    "agents": agents,
    "needsWjp": all_needs_wjp,
    "intel": load_intel(),
    "files": build_files(),
    "health": {
        "crons": {"healthy": cron_ok, "errors": cron_err},
        "lastHeartbeat": now_iso,
    },
}

with open(OUTPUT, "w") as f:
    json.dump(data, f, indent=2)

print(f"✅ data.json: {len(projects)} projects, {len(all_needs_wjp)} WJP items | kikai={k_status} ctx={k_ctx}% | yama={y_status} | crons={cron_ok}ok/{cron_err}err")
PYEOF
