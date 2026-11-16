import os, tempfile
# Where the stream tools find things: the repo, the PvPCore tools (built with
# `swift build -c release --product battle-report` and `--product screen-log` into
# MANGO_BUILD_DIR, as scripts/battle_reports.sh does) and the stream's games, kept on this Mac
# only ("Stream Battles/", git-ignored like the recordings).
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) + '/'
BUILD = os.environ.get('MANGO_BUILD_DIR', '/tmp/ManGo-PvPCore')
BR = BUILD + '/release/battle-report'
SL = BUILD + '/release/screen-log'
GAMES = os.environ.get('STREAM_GAMES', ROOT + 'Stream Battles/gdansk-2027-day2')
TRUTH = GAMES + '/truth.json'
EMPTY = os.path.join(tempfile.gettempdir(), 'mango-no-hand-counts.json')
if not os.path.exists(EMPTY):
    open(EMPTY, 'w').write('{}')
