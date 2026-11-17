"""A battle simulator in your browser: you against the planner, in real time.

    cd POMDP
    python3 -m experiments.arena              # opens http://127.0.0.1:8228
    python3 -m experiments.arena --phone      # also serves it on your Wi-Fi, to play on your phone
    python3 -m experiments.arena --record     # your record against each opponent, from your games here

The battle runs here, in the same engine the planner plans with, at the game's pace: a turn every
half second, a pause after each charged move, a shield prompt with a time limit, and a pick after a
faint. The page only ever gets what your screen would show (their bench stays hidden until it comes
in), plus, if you leave it on, their energy counted from their moves the way ManGo counts it and
the damage numbers.

Tap (or Space) for a fast move, or leave auto attack on; charged moves fire when your fast move
finishes, as in the game. Switching right after a charged move is a free (0-turn) switch.

Opponents are players from mango_pomdp.match. "blind" picks the rollout planner or POMCP at random
and tells you which only at the end. Finished games go to data/local/arena/games.jsonl (git-ignored).

With --phone, anyone on your Wi-Fi can open the page while it runs. Ctrl+C stops it.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import socket
import threading
import time
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from mango_pomdp import gamedata
from mango_pomdp.battle import FAST, MAX_ENERGY, TIME_LIMIT_TURNS, WAIT, Battle, View
from mango_pomdp.belief import EnergyCounter
from mango_pomdp.gamedata import damage
from mango_pomdp.match import make_player
from mango_pomdp.policies import STYLES
from mango_pomdp.team_prior import TeamPrior, build_team
from mango_pomdp.timeline import render
from experiments.top_teams import FORMAT, label, rotate, short, team_index

PAGE = Path(__file__).with_name("arena.html")
LOG = Path(__file__).resolve().parents[1] / "data" / "local" / "arena" / "games.jsonl"
TURN_SECONDS = 0.5
CHARGE_PAUSE = 1.5    # seconds the game stops for a charged move (the minigame and animation, roughly)
FAINT_PAUSE = 1.0
COUNTDOWN = 3.0
BLIND = ("planner-list-mixed", "pomcp-list-mixed")
OPPONENTS = {
    "planner-list": "Rollout planner that knows PvPoke's top teams",
    "planner-list-mixed": "Rollout planner, top teams, weighs five opponent styles",
    "pomcp-list-mixed": "POMCP: the same, with a search tree over its later decisions",
    "blind": "Rollout planner or POMCP at random, revealed at the end",
    "planner": "Rollout planner with only the general team prior",
    **{s: f"Heuristic: {s}" for s in STYLES},
}


class Quit(Exception):
    pass


def move_info(m) -> dict:
    return {"name": m.name, "type": m.type, "energy": m.energy, "gain": m.energy_gain, "turns": m.turns}


class Game:
    """One battle in its own thread. It is also the controller for side 0 (you): `act` takes what you
    pressed since the last turn, and `shield`/`replace` wait for your answer, up to a time limit.
    The page polls `state()` and sends presses to `press()`."""

    side = 0

    def __init__(self, gd, prior, mine: int, theirs: int, lead: int = 1, opponent: str = "planner-list",
                 rollouts: int = 12, speed: float = 1.0, shield_secs: float | None = 4.0,
                 replace_secs: float | None = 10.0, coach: bool = False, info: bool = True,
                 seed: int | None = None, log: Path | None = LOG, pace: bool = True):
        self.gd, self.mine, self.theirs, self.lead = gd, mine, theirs, lead
        rng = random.Random(seed)
        self.blind = opponent == "blind"
        self.opponent = rng.choice(BLIND) if self.blind else opponent
        self.rollouts, self.speed, self.info = rollouts, speed, info
        self.shield_secs, self.replace_secs = shield_secs, replace_secs
        self.log_path, self.pace = log, pace
        self.seed = rng.randrange(1 << 30)
        self.ours = rotate(gd.teams[mine].spec, lead)
        # The opponent's list prior: PvPoke's top teams, leaving out its own (as in experiments.play).
        listed = [t for k, t in enumerate(gd.teams) if t.source == "pvpoke" and k != theirs]
        self.foe = make_player(self.opponent, gd, prior, rng.randrange(1 << 30), rollouts=rollouts, teams=listed)
        self.coach = make_player("planner-list", gd, prior, rng.randrange(1 << 30), rollouts=rollouts,
                                 teams=[gd.teams[k] for k in gd.team_pool("pvpoke")]) if coach else None
        self.counter = EnergyCounter()
        self.cv = threading.Condition()
        # Your presses since the last turn.
        self.intent: tuple[str, int] | None = None
        self.taps = 0
        self.auto = True
        # What the page shows.
        self.phase = "countdown"
        self.paused = self.stopped = False
        self.prompt: dict | None = None
        self.answer = None
        self.snap: dict = {}
        self.feed: list[dict] = []   # what happened, but fast moves
        self.fx: list[dict] = []     # fast move hits, for the page to flash
        self.events = 0
        self.hint: str | None = None
        self.result: dict | None = None
        self.error: str | None = None
        self.seq = 0
        self.battle: Battle | None = None

    # Running -------------------------------------------------------------------------------

    def start_thread(self) -> threading.Thread:
        th = threading.Thread(target=self.run, daemon=True)
        th.start()
        return th

    def run(self) -> None:
        try:
            self._run()
        except Quit:
            with self.cv:
                self.phase = "quit"
                self.prompt = None
                self.seq += 1
        except Exception:   # show it on the page rather than leave it hanging
            with self.cv:
                self.phase, self.error = "error", traceback.format_exc()
                self.seq += 1

    def _run(self) -> None:
        gd = self.gd
        b = self.battle = Battle([build_team(gd, self.ours), build_team(gd, list(gd.teams[self.theirs].spec))],
                                 seed=self.seed)
        players = [self, self.foe]
        if hasattr(self.foe, "start"):
            self.foe.start(1)
        if self.coach:
            self.coach.start(0)
        observers = [o for o in (self, self.foe, self.coach) if o is not None and hasattr(o, "observe")]
        for o in observers:
            o.observe(b.log)
        self._publish()
        self._sleep(COUNTDOWN)
        with self.cv:
            self.phase = "play"
        mark, pause = time.monotonic(), 0.0
        while not b.done:
            for o in observers:
                if hasattr(o, "before_turn"):
                    o.before_turn(View(b, o.side))
            hint = None
            if self.coach and b.sides[0].busy_until <= b.turn:
                hint = self._describe(b.view(0), self.coach.act(b.view(0)))
            with self.cv:
                self.hint = hint
            self._publish()
            self._sleep(pause - (time.monotonic() - mark))
            start = len(b.log)
            b.step(players)
            new = b.log[start:]
            for o in observers:
                o.observe(new)
            self._publish()
            mark = time.monotonic()
            pause = TURN_SECONDS / self.speed
            if any(e.kind == "charged" for e in new):
                pause += CHARGE_PAUSE
            if any(e.kind == "faint" for e in new):
                pause += FAINT_PAUSE
        self._finish(b)

    def _finish(self, b: Battle) -> None:
        gd = self.gd
        winner = {0: "you", 1: "them", -1: "tie"}[b.winner]
        result = {
            "winner": winner,
            "text": {"you": "You win!", "them": "You lose.", "tie": "A tie."}[winner],
            "their_team": [gd.species[s].name for s in gd.teams[self.theirs].species],
            "their_label": label(gd, self.theirs),
            "opponent": self.opponent,
            "timeline": render(b, ("You", "Them")),
            "left": [b.sides[0].remaining(), b.sides[1].remaining()],
            "timeout": b.clock >= TIME_LIMIT_TURNS,
        }
        with self.cv:
            self.result, self.phase, self.prompt, self.hint = result, "over", None, None
            self.seq += 1
        if self.log_path:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            row = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "you": label(gd, self.mine), "lead": self.lead,
                   "them": label(gd, self.theirs), "opponent": self.opponent, "blind": self.blind,
                   "rollouts": self.rollouts, "speed": self.speed, "shield_secs": self.shield_secs,
                   "coach": self.coach is not None, "winner": winner, "left": result["left"],
                   "turns": b.turn, "timeout": result["timeout"], "seed": self.seed}
            with self.log_path.open("a") as f:
                f.write(json.dumps(row) + "\n")

    def _sleep(self, secs: float) -> None:
        """Waits `secs` of unpaused time, or returns at once when not pacing (tests)."""
        if not self.pace:
            if self.stopped:
                raise Quit
            return
        end = time.monotonic() + secs
        with self.cv:
            while True:
                if self.stopped:
                    raise Quit
                if self.paused:
                    left = end - time.monotonic()
                    while self.paused and not self.stopped:
                        self.cv.wait(0.1)
                    end = time.monotonic() + max(left, 0.0)
                    continue
                left = end - time.monotonic()
                if left <= 0:
                    return
                self.cv.wait(min(left, 0.05))

    def _ask(self, prompt: dict, secs: float | None, default):
        """Shows a prompt and waits for the answer, up to `secs` of unpaused time (None: no limit)."""
        if not self.pace and not secs:
            return default
        with self.cv:
            self.answer = None
            self.prompt = dict(prompt, left=secs)
            self.seq += 1
            last = time.monotonic()
            while self.answer is None and not self.stopped and (secs is None or self.prompt["left"] > 0):
                self.cv.wait(0.05)
                now = time.monotonic()
                if secs is not None and not self.paused:
                    self.prompt["left"] -= now - last
                last = now
            answer, self.answer, self.prompt = self.answer, None, None
            self.seq += 1
            if self.stopped:
                raise Quit
        return default if answer is None else answer

    # The controller for side 0 --------------------------------------------------------------

    def start(self, side: int) -> None:
        assert side == 0

    def observe(self, events) -> None:
        lines = []
        for e in events:
            if e.side == 1:
                self.counter.observe(e)
            line = self._line(e)
            if line:
                lines.append(line)
        if lines:
            with self.cv:
                for line in lines:
                    line["id"] = self.events
                    self.events += 1
                    (self.fx if line["kind"] == "fast" else self.feed).append(line)
                del self.fx[:-8]

    def act(self, view: View):
        with self.cv:
            if self.stopped:
                raise Quit
            legal = view.legal_actions()
            choice, self.intent = self.intent, None
            if choice not in legal:   # a charged move it can't afford, or a switch it can't make
                choice = None
            if choice is None and self.taps:
                self.taps -= 1
                choice = FAST
            if choice is None:
                choice = FAST if self.auto else WAIT
            return choice

    def shield(self, view: View, move) -> bool:
        mon = view.mon
        if mon.form == "disguised":
            return False   # Mimikyu's Disguise takes it for free
        hit = damage(move, view.foe_species, mon.species, view.foe_stages[0], mon.def_stage)
        prompt = {"kind": "shield", "move": move.name, "type": move.type, "attacker": view.foe_species.name,
                  "hp": mon.hp, "shields": view.me.shields,
                  "damage": hit if self.info else None, "ko": hit >= mon.hp if self.info else None}
        if self.coach:
            prompt["hint"] = "shield" if self.coach.shield(view, move) else "take it"
        self._publish()
        return bool(self._ask(prompt, self.shield_secs, False))

    def replace(self, view: View) -> int:
        bench = view.me.bench()
        if len(bench) == 1:
            return bench[0]
        prompt = {"kind": "replace", "fainted": view.mon.species.name,
                  "options": [{"i": i, "name": view.me.mons[i].species.name, "hp": view.me.mons[i].hp,
                               "max": view.me.mons[i].max_hp} for i in bench]}
        if self.coach:
            pick = self.coach.replace(view)
            prompt["hint"] = view.me.mons[pick].species.name if pick in bench else None
        self._publish()
        pick = self._ask(prompt, self.replace_secs, bench[0])
        return pick if pick in bench else bench[0]

    # From the page ---------------------------------------------------------------------------

    def press(self, msg: dict) -> None:
        do = msg.get("do")
        with self.cv:
            if do == "fast":
                self.taps = min(self.taps + 1, 2)
            elif do == "auto":
                self.auto = bool(msg.get("on", not self.auto))
            elif do == "charged":
                self.intent = ("charged", int(msg["i"]))
            elif do == "switch":
                self.intent = ("switch", int(msg["i"]))
            elif do == "shield" and self.prompt and self.prompt["kind"] == "shield":
                self.answer = bool(msg.get("on"))
            elif do == "replace" and self.prompt and self.prompt["kind"] == "replace":
                if int(msg["i"]) in [o["i"] for o in self.prompt["options"]]:
                    self.answer = int(msg["i"])
            elif do == "pause":
                self.paused = bool(msg.get("on", not self.paused))
            elif do == "speed":
                self.speed = min(2.0, max(0.1, float(msg["x"])))
            elif do == "quit":
                self.stopped = True
            self.seq += 1
            self.cv.notify_all()

    def state(self) -> dict:
        with self.cv:
            queued = None
            if self.intent:
                queued = list(self.intent)
            return {
                "phase": self.phase, "seq": self.seq, **self.snap,
                "paused": self.paused, "auto": self.auto, "taps": self.taps, "queued": queued,
                "speed": self.speed, "info": self.info, "coach": self.coach is not None,
                "prompt": None if self.prompt is None else dict(self.prompt),
                "feed": self.feed[-40:], "fx": list(self.fx), "hint": self.hint, "result": self.result, "error": self.error,
                "opponent": self.opponent if (self.result or not self.blind) else "hidden",
                "opponent_note": OPPONENTS.get("blind" if self.blind and not self.result else self.opponent, ""),
            }

    # What the screen shows --------------------------------------------------------------------

    def _publish(self) -> None:
        """Called from the game thread only: builds what side 0 sees, for `state()` to hand out."""
        snap = self._snap(self.battle.view(0))
        with self.cv:
            self.snap = snap
            self.seq += 1

    def _snap(self, view: View) -> dict:
        gd, me, t = self.gd, view.me, view.turn
        foe = view.foe_species
        foe_atk, foe_def = view.foe_stages
        mons = []
        for i, m in enumerate(me.mons):
            d = {"i": i, "name": m.species.name, "types": list(m.species.types), "hp": m.hp, "max": m.max_hp,
                 "energy": m.energy, "form": m.form, "fast": move_info(m.fast),
                 "charged": [move_info(c) for c in m.charged], "atk": m.atk_stage, "def": m.def_stage}
            if self.info and i == me.active:
                d["fast"]["damage"] = damage(m.fast, m.species, foe, m.atk_stage, foe_def)
                for c, ci in zip(m.charged, d["charged"]):
                    ci["damage"] = damage(c, m.species, foe, m.atk_stage, foe_def)
            mons.append(d)
        seen = []
        for sid, s in view.foe_seen().items():   # only Pokémon that have come in, in the order they did
            sp = gd.species[sid]
            seen.append({"name": sp.name, "types": list(sp.types), "hp": view.foe_hp_of(sid), "max": sp.hp,
                         "active": sid == foe.id, "fast": s["fast"].name if s["fast"] else None,
                         "charged": [gd.moves[c].name for c in sorted(s["charged"])],
                         "energy": self.counter.energy.get(sid, 0) if self.info else None})
        return {
            "turn": t, "left": max(0, TIME_LIMIT_TURNS - view.clock) * TURN_SECONDS, "max_energy": MAX_ENERGY,
            "me": {"active": me.active, "shields": me.shields, "switch": me.switch_timer * TURN_SECONDS,
                   "busy": max(0, me.busy_until - t), "mons": mons},
            "foe": {"name": foe.name, "types": list(foe.types), "hp": view.foe_hp, "max": foe.hp,
                    "shields": view.foe_shields, "remaining": view.foe_remaining, "form": view.foe_form_of(foe.id),
                    "atk": foe_atk, "def": foe_def,
                    "energy": self.counter.energy.get(foe.id, 0) if self.info else None,
                    "switch": max(0, self.counter.switch_ready - t) * TURN_SECONDS if self.info else None,
                    "seen": seen},
        }

    def _line(self, e) -> dict | None:
        gd = self.gd
        who = "you" if e.side == 0 else "them"
        whose = "Your" if e.side == 0 else "Their"
        name = gd.species[e.species].name
        if e.kind == "fast":
            return {"kind": "fast", "who": who, "turn": e.turn, "damage": e.info["damage"]}
        if e.kind == "enter":
            if e.info.get("lead"):
                return {"kind": "enter", "who": who, "turn": e.turn, "text": f"{whose} lead: {name}"}
            return {"kind": "enter", "who": who, "turn": e.turn,
                    "text": f"{whose} {name} comes in" + (" (switch)" if e.info.get("switch") else "")}
        if e.kind == "charged":
            how = ("shielded" if e.info["shielded"] else "blocked by Disguise" if e.info["disguise"]
                   else f"{e.info['damage']} damage")
            return {"kind": "charged", "who": who, "turn": e.turn, "type": e.move.type, "damage": e.info["damage"],
                    "shielded": e.info["shielded"], "text": f"{whose} {name} used {e.move.name}: {how}"}
        if e.kind == "gulp":
            return {"kind": "gulp", "who": who, "turn": e.turn, "damage": e.info["damage"],
                    "text": f"{whose} Cramorant's Gulp Missile: {e.info['damage']} damage"}
        if e.kind == "faint":
            return {"kind": "faint", "who": who, "turn": e.turn, "text": f"{whose} {name} fainted"}
        return None

    @staticmethod
    def _describe(view: View, a) -> str:
        kind, arg = a
        if kind == "charged":
            return f"throw {view.mon.charged[arg].name}"
        if kind == "switch":
            return f"switch to {view.me.mons[arg].species.name}"
        return {"fast": "fast move", "wait": "wait"}[kind]


# Your record ----------------------------------------------------------------------------------

def record(path: Path = LOG) -> list[dict]:
    """Per opponent (the real one, for blind games): games, wins, losses, ties, win rate (a tie
    counts half) and its standard error. Blind games are also counted on their own."""
    rows = []
    if path.exists():
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    groups: dict[str, list[dict]] = {}
    for r in rows:
        groups.setdefault(r["opponent"], []).append(r)
        if r.get("blind"):
            groups.setdefault(f"{r['opponent']} (blind)", []).append(r)
    out = []
    for name, rs in sorted(groups.items()):
        xs = [{"you": 1.0, "tie": 0.5, "them": 0.0}[r["winner"]] for r in rs]
        m = sum(xs) / len(xs)
        se = math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1) / len(xs)) if len(xs) > 1 else None
        out.append({"opponent": name, "games": len(xs), "wins": xs.count(1.0), "ties": xs.count(0.5),
                    "losses": xs.count(0.0), "rate": m, "se": se})
    return out


def print_record(path: Path = LOG) -> None:
    rs = record(path)
    if not rs:
        print(f"No games yet ({path}).")
        return
    print(f"{'opponent':<28}{'games':>6}{'W-L-T':>10}   your win rate")
    for r in rs:
        se = f" ± {r['se']:.2f}" if r["se"] is not None else ""
        print(f"{r['opponent']:<28}{r['games']:>6}{r['wins']:>4}-{r['losses']}-{r['ties']:<4}  {r['rate']:.2f}{se}")


# The web server -------------------------------------------------------------------------------

class Arena:
    def __init__(self, gd, prior, log: Path | None = LOG):
        self.gd, self.prior, self.log = gd, prior, log
        self.game: Game | None = None
        self.lock = threading.Lock()

    def setup(self) -> dict:
        gd = self.gd

        def teams(source):
            return [{"value": label(gd, k), "text": f"{label(gd, k)}  {short(gd, gd.teams[k])}",
                     "members": [gd.species[s].name for s in gd.teams[k].species]} for k in gd.team_pool(source)]
        return {"mine": teams("mine"), "pvpoke": teams("pvpoke"), "faced": teams("faced"),
                "opponents": [{"value": k, "text": v} for k, v in OPPONENTS.items()], "record": record(self.log)}

    def new(self, msg: dict) -> None:
        gd = self.gd
        rng = random.Random()
        mine = team_by_label(gd, msg.get("you") or label(gd, (gd.team_pool("mine") or gd.team_pool("pvpoke"))[0]))
        them = msg.get("them") or "random-pvpoke"
        if them.startswith("random-"):
            pool = [k for k in gd.team_pool(them.removeprefix("random-")) if k != mine]
            theirs = rng.choice(pool)
        else:
            theirs = team_by_label(gd, them)
        opponent = msg.get("opponent") or "planner-list"
        if opponent not in OPPONENTS:
            raise ValueError(f"unknown opponent {opponent!r}")
        lead, rollouts = int(msg.get("lead") or 1), int(msg.get("rollouts") or 12)
        if lead not in (1, 2, 3) or not 1 <= rollouts <= 256:
            raise ValueError("lead is 1 to 3, rollouts 1 to 256")
        shield = msg.get("shield_secs", 4.0)
        game = Game(gd, self.prior, mine, theirs, lead=lead, opponent=opponent, rollouts=rollouts,
                    speed=min(2.0, max(0.1, float(msg.get("speed") or 1.0))),
                    shield_secs=None if shield in (None, 0, "none") else float(shield),
                    coach=bool(msg.get("coach")), info=bool(msg.get("info", True)), log=self.log)
        with self.lock:
            if self.game:
                self.game.press({"do": "quit"})
            self.game = game
        game.start_thread()

    def state(self) -> dict:
        with self.lock:
            game = self.game
        return game.state() if game else {"phase": "setup"}

    def press(self, msg: dict) -> None:
        with self.lock:
            game = self.game
            if game and msg.get("do") == "quit" and game.phase in ("over", "error", "quit"):
                self.game = None   # back to the setup screen
                return
        if game:
            game.press(msg)


def team_by_label(gd, text: str) -> int:
    try:
        return team_index(gd, text)
    except SystemExit as e:   # top_teams is a command line tool
        raise ValueError(str(e)) from None


def make_handler(arena: Arena):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, body: bytes, ctype: str = "application/json", code: int = 200) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, code: int = 200) -> None:
            self._send(json.dumps(obj).encode(), code=code)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path in ("/", "/index.html"):
                self._send(PAGE.read_bytes(), "text/html; charset=utf-8")
            elif path == "/api/setup":
                self._json(arena.setup())
            elif path == "/api/state":
                self._json(arena.state())
            else:
                self._json({"error": "not found"}, 404)

        def do_POST(self):
            path = self.path.split("?")[0]
            try:
                n = int(self.headers.get("Content-Length") or 0)
                msg = json.loads(self.rfile.read(n) or b"{}")
                if path == "/api/new":
                    arena.new(msg)
                elif path == "/api/press":
                    arena.press(msg)
                else:
                    return self._json({"error": "not found"}, 404)
            except (ValueError, KeyError, TypeError) as e:
                return self._json({"error": str(e)}, 400)
            self._json({"ok": True})

    return Handler


def lan_address() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))   # no packet is sent; this just picks the outgoing interface
            return s.getsockname()[0]
    except OSError:
        return "your-computer's-address"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8228)
    ap.add_argument("--phone", action="store_true", help="also listen on your Wi-Fi, to play from your phone")
    ap.add_argument("--no-open", action="store_true", help="don't open a browser")
    ap.add_argument("--record", action="store_true", help="print your record here and exit")
    ap.add_argument("--log", type=Path, default=LOG, help=f"where finished games go (default {LOG})")
    args = ap.parse_args()
    if args.record:
        print_record(args.log)
        return
    gd = gamedata.use(FORMAT)
    arena = Arena(gd, TeamPrior(gd), log=args.log)
    server = ThreadingHTTPServer(("0.0.0.0" if args.phone else "127.0.0.1", args.port), make_handler(arena))
    url = f"http://127.0.0.1:{args.port}/"
    print(f"Arena at {url}" + (f"  (on your phone: http://{lan_address()}:{args.port}/)" if args.phone else ""))
    print("Ctrl+C to stop.")
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
