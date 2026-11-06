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
- A free switch counts from when the Pokémon it replaced left. Gone from their name box before
  the last read before your buttons came back, it left during the stop and the new one starts
  at the restart: a moment before your buttons after your charged move, with them after theirs
  (play restarts around your buttons then, even when you shield).
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
  not PvPoke's Dragon Tail).
- After a restart both sides start fast moves on the same turn: your first fast move landing (a
  step in your buttons' fill) dates the restart, often earlier than the buttons are readable.
  The opponent's count starts from it less a 0.35s reaction; restarts only ever move earlier.
- A switch or unreadable interval breaks the premise of uninterrupted fast moves.
  A clear repeated HP-damage cadence can refine an assumed moveset. Shared durations and
  occluded bars remain ambiguous; do not convert their absence into a measured zero.
- Base-name matches retain multiple possible forms until distinguishing evidence arrives.
  Ranked recommendations are hypotheses, not visual identification.

`BattleAccuracyTests` enforces all 43 supplied count labels, exact energy checkpoints, minimum
spends, and the observed Waterfall moveset. Unknown labels remain unknown. Reports also flag
raw timing undercounts even after the ledger resynchronizes. v7's Azumarill label was corrected
from 9 to 10 Bubbles by the user's recount on November 4, 2026.
