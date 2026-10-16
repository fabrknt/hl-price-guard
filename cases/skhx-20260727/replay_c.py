"""Replay the xyz:SKHX oracle (2026-07-27 22:57-23:04 UTC) through the jump check, three ways.

    python3 -I replay_c.py skhx-oracle.json

skhx-oracle.json: every setOracle the deployer sent for SKHX, [time, L1 height, oracle], from the
public explorer blocks (extracted with hip3-ops web/incident_oracle.py).

The pool reads the oracle at every update and keeps one stored price to compare against:
  P1  previous read: always overwrite the stored price.
  P2  last accepted: overwrite only on accept; a stored price older than WINDOW is not compared
      (the first version of checkJump, since replaced).
  P3  latch: on a jump, pause; resume only once the oracle is back within MAX_JUMP of the price
      stored before the jump (HLPriceGuard.JumpLatch).
"""
import datetime, json, sys

MAX_JUMP_BPS, WINDOW = 200, 90
rows = json.load(open(sys.argv[1]))["updates"]
t = [datetime.datetime.fromisoformat(r[0]).timestamp() for r in rows]
px = [r[2] for r in rows]


def bps(a, b):
    return abs(a / b - 1) * 1e4


def run(policy):
    stored, stored_at, paused = None, None, False
    accepted = []
    for ti, p in zip(t, px):
        if policy == "P1":
            ok = stored is None or bps(p, stored) <= MAX_JUMP_BPS
            stored, stored_at = p, ti
        elif policy == "P2":
            ok = stored is None or ti > stored_at + WINDOW or bps(p, stored) <= MAX_JUMP_BPS
            if ok:
                stored, stored_at = p, ti
        else:
            ok = stored is None or bps(p, stored) <= MAX_JUMP_BPS
            if ok:
                stored, stored_at = p, ti
        if ok:
            accepted.append((ti, p))
    return accepted


bad = [i for i in range(len(px)) if px[i] < 1000]
print(f"{len(rows)} updates; the oracle sat below $1,000 in {len(bad)} of them "
      f"({rows[bad[0]][0][11:]} to {rows[bad[-1]][0][11:]}), low ${min(px):,.2f}")
for policy in ("P1", "P2", "P3"):
    acc = run(policy)
    low = [(ti, p) for ti, p in acc if p < 1000]
    gap = [rows[i][0][11:] for i in range(len(rows)) if (t[i], px[i]) not in set(acc)]
    print(f"{policy}: accepted {len(acc)}/{len(rows)}; accepted below $1,000: {len(low)}"
          + (f", lowest ${min(p for _, p in low):,.2f}" if low else "")
          + (f"; rejected {len(gap)}, first {gap[0]}, last {gap[-1]}" if gap else ""))
