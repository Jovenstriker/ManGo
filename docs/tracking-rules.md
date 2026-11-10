# Battle tracking contract

This contract follows the user's “Pokémon GO PvP Rules,” supplied November 4, 2026. It guides
the screen reader and deterministic energy tracker; the POMDP project is separate. Bundled
PvPoke data supplies move durations and energy values. The supplied damage multipliers were
explicitly approximate and are not used to identify moves or compute energy.

- A turn is 0.5 seconds. Fast-move damage and energy land at the end of the last turn;
  energy caps at 100. Lost energy at the cap does not imply fewer attacks occurred.
- No turns pass during charged-move cinematics, shield prompts, or minigames.
- A queued charged move waits for the current fast move to finish. Missing button labels
  alone are insufficient evidence of a freeze; recognize battle cues or confirm the absence.
- Your charged move can allow their in-progress/aligned/sneaked fast move. The displayed
  credit during the cinematic forecasts its completion afterward. A same-turn charged
  move does not get that bonus; switching out instead of sneaking does not get it either.
- A normal switch costs one turn. Replacing a fainted Pokémon is free. Either side can
  switch freely as a charged move ends; once play has resumed, the normal switch turn applies.
  Choosing to switch out after the other side fainted costs one turn.
- A switch in play waits for the fast move in progress, like a charged move, so the Pokémon
  leaving has thrown a whole number: its time on the field over its fast move, to the nearest
  (confirmed by hand six times on November 9, 2026). Not for a lead leaving before the first stop,
  whose clock starts at GO and may run ahead of a late start.
- A switch made in play costs its turn even when the new name first shows in a stop: dated by its
  "Go, X!" (never before a read still showing the Pokémon it replaced), before the stop began, it had
  no fast move in progress at your charged move unless its turn was over. A charged move ends a
  switch turn: after it, the new Pokémon starts with the restart (221337: Mimikyu for Greninja just
  before your 6:09 charged move, then 7 Shadow Claws by its Shadow Sneak, by the user's count).
- Your own switch as your buttons come back (made in the stop) doesn't break their rhythm from the
  restart; one made in play does.
- A free switch counts from when the Pokémon it replaced left. Gone from their name box before
  the last read before your buttons came back, it left during the stop and the new one starts
  at the restart: a moment before your buttons after your charged move, with them after theirs
  (play restarts around your buttons then, even when you shield).
- After a faint, your first charged move gives them a sneak, even if your buttons never showed
  play resuming: you can only throw once it has, so yours took its first turn and they started a
  fast move on it (010753: Nidoqueen in for the fainted Forretress, your charged move at 2:29.8; the
  user saw it sneak a Mud Slap). Unlike a switch made in play, a replacement has no switch turn.
- After a faint, neither side attacks until the replacement is out. Dimmed move labels
  can remain on screen during this transition. Confirmed player pokéball loss overrides them.
- Benched Pokémon keep their energy. Form clarification must preserve their history.
- CMP knockouts do not spend energy for the move that never happens. Only an observed
  opponent banner spends energy; absence of a banner does not prove a sneak occurred.
- A charged move requires at least its cost. If an observed spend contradicts the clock,
  preserve the raw discrepancy and record a minimum-energy constraint (the card shows no
  uncertainty marks, at the user's request).
  That does not prove an exact missing attack count. It does switch the assumed fast move when
  another one the Pokémon learns could have paid for it (the user confirmed Flygon used Mud Shot,
  not PvPoke's Dragon Tail), but not to one of the same length when the assumed move is less than
  one fast move short: those fit the same turns, and a lag can lose one (Furret, Sucker Punch).
- A GO (or "CO") read sooner after a countdown digit than the countdown can get there (1.5s
  after its "3", 0.8s after its "2") is that digit misread (014321: "co" 0.26s after the "3";
  the real GO came 2.7s later). In every other recording GO came 2.46s or more after a "3" and
  1.30s after a "2".
- A "Go, X!" within 1.5s of your buttons changing to moves X learns is your switch, even with
  your name box covered (014321: "Go, Jumpluff!" as your buttons became Energy Ball and
  Acrobatics, while Cramorant's box went blank for its Dive; taken for theirs, it made Machamp a
  fourth Pokémon and started a new battle, resetting their energy).
- The lead starts 0.2s after GO is first read: of the starts tried after the countdown on
  November 8, 2026, the only one that fits every lead's hand count. GO stands about 0.65s, then
  grows as it fades; a first read that caught it fading (taller than it stands) came most of that
  late, and the start is 0.5s earlier (152828: up from 0:43.9, first read at 0:44.56; Marowak's 4
  Mud Slaps). Your HP bar doesn't date the lead: Stunfisk in 223847 waited about a second after its
  sixth Thunder Shock before Mud Bomb, so dated from its first hit it got 7, not the user's 6.
- Their charged move starts as one of their fast moves finishes, so a restart shown late may hide
  one more, if the restart that implies is within 0.5s before to 0.4s after your buttons came back
  (also after they blocked yours: Mimikyu in 221337 threw 6, not 7, after the 6:36 tie). Your HP bar
  overrules that when it held steady where the extra one would have hit you,
  or, after your charged move, a fast move earlier, where their move in progress would have. And it
  doesn't apply when the restart was seen: their move in progress hitting you as play resumed.
- On a same-turn throw (CMP) they had no fast move in progress: no sneak. Both sides throw as
  their fast moves finish, so they'd finished a whole number: the move counted in progress at
  your charged move is taken back if the clock had it less than half done, and kept if nearer
  done (it had landed and the clock was behind). That shows when both charged moves play out;
  if yours knocks theirs out first, theirs never shows, and neither does the tie, but its energy
  no longer matters.
- When theirs goes first and yours follows in the same stop with no play between (no hit on their
  Pokémon after their banner has gone, your buttons never back, your Pokémon not out), it was the
  same turn and theirs won the tie: no sneak. The move the clock had in progress at theirs counts
  only when the finished ones couldn't pay for their charged move: the clock was behind (233921:
  Stunfisk's Discharge and your Energy Ball at 1:22.2, 5 Thunder Shocks before it and 5 before its
  Mud Bomb, by the user's count; 211526: Quagsire's Stone Edge on 7 Mud Shots, 6 being 54). When
  they could pay, it doesn't, however done the clock had it (211824: Hydreigon's Brutal Swing on
  14 Dragon Breaths with the 15th 99% done; the user saw a sneak at the tie). A sneak after their charged move
  needs play between (002722: your Mandibuzz's fast move hit Greninja after its Hydro Cannon).
- After your charged move, their fast move in progress finishes as play resumes: its hit on you
  ("…EFFECTIVE" over your Pokémon, fresh in the stop) shows play had restarted by that read, often
  before your buttons are readable. Not if it knocked yours out: play then waits for your next
  Pokémon, whose "Go, X!" or the switch prompt follows the hit.
- After a restart both sides start fast moves on the same turn: your first fast move landing (a
  step in your buttons' fill) dates the restart, often earlier than the buttons are readable.
  The opponent's count starts from it less a 0.35s reaction; restarts only ever move earlier.
- A switch or unreadable interval breaks the premise of uninterrupted fast moves.
  A clear repeated HP-damage cadence can refine an assumed moveset. Shared durations and
  occluded bars remain ambiguous; do not convert their absence into a measured zero.
- Base-name matches retain multiple possible forms until distinguishing evidence arrives.
  Ranked recommendations are hypotheses, not visual identification.

`BattleAccuracyTests` enforces all 103 supplied count labels, exact energy checkpoints, minimum
spends, and the observed Waterfall moveset. Unknown labels remain unknown. Reports also flag
raw timing undercounts even after the ledger resynchronizes. v7's Azumarill label was corrected
from 9 to 10 Bubbles by the user's recount on November 4, 2026.
