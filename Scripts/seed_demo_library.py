#!/usr/bin/env python3
"""Plant a self-contained demo meeting library for screenshots / manual QA.

Mirrors StorageManager's on-disk layout (the same shape the Swift UI-test
fixture writes) so the app indexes it on launch. Dates are anchored to *now*
so the meeting list always reads TODAY / YESTERDAY.

Usage:
    python3 Scripts/seed_demo_library.py <storage-root>

Point the app at <storage-root> via LOKALBOTV3_STORAGE_ROOT. See
Scripts/capture-screenshots.sh for the full capture flow.
"""
import json, os, shutil, sqlite3, sys, time
from datetime import datetime, timezone, timedelta


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(s):
    s = int(s)
    return f"{s // 60:02d}:{s % 60:02d}"


def relpath(dt, slug):
    return f"meetings/{dt.year}/{dt.month:02d}/{dt.day:02d}-{slug}"


def seg(a, b, sp, t):
    return {"start": a, "end": b, "speaker": sp, "text": t}


def build(now):
    return [
        dict(id="11111111-1111-4111-8111-111111111111", title="Design review", app="Zoom",
             started=now - timedelta(minutes=70), ended=now - timedelta(minutes=45), sys=True,
             transcript=[
                 seg(0, 12, "me", "Let's lock the caching layer. I propose Redis for the pub-sub support."),
                 seg(12, 26, "them", "Agreed on Redis. Open question: do we need cluster mode from day one?"),
                 seg(26, 38, "me", "I'll draft the eviction-policy doc by Thursday."),
                 seg(38, 52, "them", "Please benchmark failover latency before we commit to a cluster."),
             ],
             summary="## TL;DR\nThe team chose Redis for caching and deferred cluster mode pending a failover benchmark.\n\n## Decisions\n- Adopt Redis for the caching layer (pub-sub support won the comparison).\n\n## Action items\n- [ ] Draft the eviction-policy document by Thursday — Me\n- [ ] Benchmark failover latency before committing to cluster mode — Them\n\n## Open questions\n- Do we need Redis cluster mode at launch, or can it wait?"),
        dict(id="22222222-2222-4222-8222-222222222222", title="Engineering standup", app="Slack",
             started=now - timedelta(minutes=150), ended=now - timedelta(minutes=135), sys=False,
             transcript=[
                 seg(0, 9, "me", "Quick standup. I'm picking up the Postgres migration today."),
                 seg(9, 20, "me", "Blocker on the index rebuild — needs a review from the data team."),
             ],
             summary="## TL;DR\nPostgres migration kicked off; the index rebuild is blocked on data-team review.\n\n## Action items\n- [ ] Unblock the index rebuild with the data team — Me"),
        dict(id="33333333-3333-4333-8333-333333333333", title="Q3 roadmap planning", app="Google Meet",
             started=now - timedelta(days=1, minutes=30), ended=now - timedelta(days=1), sys=False,
             transcript=[
                 seg(0, 20, "me", "We need to lock the Q3 roadmap. Onboarding is the top priority for new accounts."),
                 seg(20, 42, "them", "Second is reliability — the alerting backlog has grown three quarters running."),
                 seg(42, 60, "me", "Let's commit onboarding first, reliability second."),
             ],
             summary="## TL;DR\nQ3 priorities are onboarding (top) and reliability (alerting backlog).\n\n## Decisions\n- Onboarding ranks above reliability for Q3.\n\n## Action items\n- [ ] Scope the onboarding revamp epic — Me"),
        dict(id="44444444-4444-4444-8444-444444444444", title="Customer call - Northwind", app="Microsoft Teams",
             started=now - timedelta(days=2, minutes=40), ended=now - timedelta(days=2), sys=True,
             transcript=[
                 seg(0, 15, "them", "Our team loves the export feature, but we need SSO before we roll out company-wide."),
                 seg(15, 30, "me", "SSO is on the Q3 roadmap. I'll send you the security overview this week."),
                 seg(30, 45, "them", "Great. Pricing for 250 seats would help us get budget approved."),
             ],
             summary="## TL;DR\nNorthwind is happy with exports; SSO is the blocker for a company-wide rollout.\n\n## Decisions\n- Send the security overview and a 250-seat quote this week.\n\n## Action items\n- [ ] Email the SSO security overview — Me\n- [ ] Prepare a 250-seat pricing quote — Me\n\n## Open questions\n- Target rollout date once SSO ships?"),
    ]


def write_meeting(root, m):
    rel = relpath(m["started"], m["title"].lower().replace(" ", "-"))
    folder = os.path.join(root, rel)
    os.makedirs(folder, exist_ok=True)
    meta = {"appName": m["app"], "endedAt": iso(m["ended"]), "hasSystemTrack": m["sys"],
            "id": m["id"], "relativePath": rel, "startedAt": iso(m["started"]), "title": m["title"]}
    with open(os.path.join(folder, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    tj = {"engine": "demo-fixture", "segments": m["transcript"]}
    with open(os.path.join(folder, "transcript.json"), "w") as f:
        json.dump(tj, f, indent=2)
    md = "\n\n".join(f"**[{stamp(s['start'])}] {s['speaker'].capitalize()}:** {s['text']}" for s in m["transcript"])
    with open(os.path.join(folder, "transcript.md"), "w") as f:
        f.write(md)
    with open(os.path.join(folder, "summary.md"), "w") as f:
        f.write(m["summary"])


def seed_activity(root):
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    cur.execute("""CREATE TABLE IF NOT EXISTS activity_blocks (id INTEGER PRIMARY KEY AUTOINCREMENT,
        app TEXT NOT NULL, title TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);""")
    midnight = time.mktime(datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timetuple())
    rows = [
        ("Xcode", "TimelineView.swift", 9 * 60, 10 * 60 + 30),
        ("Safari", "Pull request #42 - caching", 10 * 60 + 30, 11 * 60 + 15),
        ("Slack", "#engineering", 11 * 60 + 15, 11 * 60 + 40),
        ("Zoom", "Design review", 11 * 60 + 40, 12 * 60 + 5),
        ("Notion", "Q3 planning doc", 13 * 60, 14 * 60 + 20),
        ("Terminal", "lokalbot build", 14 * 60 + 20, 15 * 60),
    ]
    for app, title, a, b in rows:
        cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)",
                    (app, title, midnight + a * 60, midnight + b * 60))
    con.commit()
    con.close()


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    root = sys.argv[1]
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(os.path.join(root, "meetings"), exist_ok=True)
    now = datetime.now(timezone.utc)
    for m in build(now):
        write_meeting(root, m)
    seed_activity(root)
    print(f"Seeded demo library at {root}")


if __name__ == "__main__":
    main()
