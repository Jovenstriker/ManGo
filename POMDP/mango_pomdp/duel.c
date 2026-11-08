/* The 1v1 solver from duel.py, function for function, for speed.
 *
 * duel.py's Duel is the reference: same state, same recursion, same matrix game solver, same
 * order of floating point operations, so the two agree exactly (the tests check). Damage tables,
 * CMP attack stats and buffs are worked out in Python and passed in, so the game data and damage
 * formula live in one place. duel.py compiles this on first use (CDuel) and loads it with ctypes.
 */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { HP = 0, E = 2, SH = 4, ATK = 6, DEF = 8, NF = 10 };
#define FAST (-1)
#define BUSY (-2)
#define MAX_ENERGY 100
#define MAX_PERIOD 64

/* One side's moves against the other: damage by [attacker atk stage + 4][defender def stage + 4]. */
typedef struct {
    int hp, fast_turns, fast_gain, n_charged;
    int fast_dmg[81];
    int cost[2];
    int dmg[2][81];
    int buff_self[2][2];
    int buff_opp[2][2];
    double buff_chance[2];
    double atk[9];   /* attack stat at each stage, for CMP */
} SideSpec;

typedef struct { uint64_t key; double value; } Slot;

typedef struct {
    SideSpec s[2];
    int period;
    double w;
    Slot *slots;
    uint64_t cap, size;
} Duel;

typedef struct { int n; int x[2]; int i[2]; } Queue;

static double value(Duel *d, const int *s, int k);

/* Memo ------------------------------------------------------------------------------------- */

static uint64_t pack(const int *s) {
    return (uint64_t)s[0] | (uint64_t)s[1] << 10 | (uint64_t)s[2] << 20 | (uint64_t)s[3] << 27
         | (uint64_t)s[4] << 34 | (uint64_t)s[5] << 36
         | (uint64_t)(s[6] + 4) << 38 | (uint64_t)(s[7] + 4) << 42
         | (uint64_t)(s[8] + 4) << 46 | (uint64_t)(s[9] + 4) << 50 | (uint64_t)1 << 60;
}

static uint64_t mix(uint64_t z) {
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static Slot *find(Slot *slots, uint64_t cap, uint64_t key) {
    uint64_t m = cap - 1, h = mix(key) & m;
    while (slots[h].key && slots[h].key != key) h = (h + 1) & m;
    return &slots[h];
}

static void insert(Duel *d, uint64_t key, double v) {
    if (10 * (d->size + 1) > 7 * d->cap) {   /* grow past 70% full */
        uint64_t cap = d->cap * 2;
        Slot *slots = calloc(cap, sizeof(Slot));
        for (uint64_t h = 0; h < d->cap; h++)
            if (d->slots[h].key) *find(slots, cap, d->slots[h].key) = d->slots[h];
        free(d->slots);
        d->slots = slots;
        d->cap = cap;
    }
    Slot *sl = find(d->slots, d->cap, key);
    if (!sl->key) { sl->key = key; d->size++; }
    sl->value = v;
}

/* Zero-sum matrix games, as duel.solve_matrix ---------------------------------------------- */

static int linsolve(double A[3][4], int n, double *x) {
    for (int col = 0; col < n; col++) {
        int piv = col;
        for (int r = col + 1; r < n; r++) if (fabs(A[r][col]) > fabs(A[piv][col])) piv = r;
        if (fabs(A[piv][col]) < 1e-12) return 0;
        if (piv != col) for (int c = 0; c <= n; c++) { double t = A[col][c]; A[col][c] = A[piv][c]; A[piv][c] = t; }
        for (int r = 0; r < n; r++) {
            if (r == col) continue;
            double f = A[r][col] / A[col][col];
            for (int c = 0; c <= n; c++) A[r][c] = A[r][c] - f * A[col][c];
        }
    }
    for (int i = 0; i < n; i++) x[i] = A[i][n] / A[i][i];
    return 1;
}

static double payoff_floor(double M[3][3], int m, int n, const double *x) {
    double val = INFINITY;
    for (int c = 0; c < n; c++) {
        double s = 0.0;
        for (int r = 0; r < m; r++) s += x[r] * M[r][c];
        if (s < val) val = s;
    }
    return val;
}

static void try_vertex(double M[3][3], int m, int n, double forms[6][3], const int *combo,
                       double *best, double *best_x) {
    double A[3][4], x[3];
    for (int t = 0; t < m - 1; t++) {
        for (int r = 0; r < m; r++) A[t][r] = forms[combo[t]][r];
        A[t][m] = 0.0;
    }
    for (int r = 0; r < m; r++) A[m - 1][r] = 1.0;
    A[m - 1][m] = 1.0;
    if (!linsolve(A, m, x)) return;
    double lo = x[0], total = 0.0;
    for (int r = 1; r < m; r++) if (x[r] < lo) lo = x[r];
    if (lo < -1e-9) return;
    for (int r = 0; r < m; r++) { if (x[r] < 0.0) x[r] = 0.0; total += x[r]; }
    for (int r = 0; r < m; r++) x[r] = x[r] / total;
    double val = payoff_floor(M, m, n, x);
    if (val > *best + 1e-12) { *best = val; memcpy(best_x, x, sizeof x); }
}

static void maximin(double M[3][3], int m, int n, double *x) {
    if (m == 1) { x[0] = 1.0; return; }
    double forms[6][3];
    int nf = 0;
    for (int i = 0; i < m; i++, nf++) for (int r = 0; r < m; r++) forms[nf][r] = (r == i);
    for (int j = 0; j < n; j++)
        for (int k = j + 1; k < n; k++, nf++) for (int r = 0; r < m; r++) forms[nf][r] = M[r][j] - M[r][k];
    double best = -INFINITY;
    int combo[2];
    if (m == 2) {
        for (combo[0] = 0; combo[0] < nf; combo[0]++) try_vertex(M, m, n, forms, combo, &best, x);
    } else {
        for (combo[0] = 0; combo[0] < nf; combo[0]++)
            for (combo[1] = combo[0] + 1; combo[1] < nf; combo[1]++) try_vertex(M, m, n, forms, combo, &best, x);
    }
}

static double solve_value(double M[3][3], int m, int n) {
    int bi = 0, bj = 0;
    double rmin[3], cmax[3];
    for (int r = 0; r < m; r++) { rmin[r] = M[r][0]; for (int c = 1; c < n; c++) if (M[r][c] < rmin[r]) rmin[r] = M[r][c]; }
    for (int c = 0; c < n; c++) { cmax[c] = M[0][c]; for (int r = 1; r < m; r++) if (M[r][c] > cmax[c]) cmax[c] = M[r][c]; }
    for (int r = 1; r < m; r++) if (rmin[r] > rmin[bi]) bi = r;
    for (int c = 1; c < n; c++) if (cmax[c] < cmax[bj]) bj = c;
    if (rmin[bi] >= cmax[bj] - 1e-12) return M[bi][bj];
    double x[3];
    maximin(M, m, n, x);
    return payoff_floor(M, m, n, x);
}

/* The game, as duel.Duel ------------------------------------------------------------------- */

static int clamp(int s) { return s < -4 ? -4 : (s > 4 ? 4 : s); }

static int quiet(int a) { return a < 0; }

static void reg(const Duel *d, int *st, int x) {
    int o = 1 - x;
    if (st[HP + o] <= 0) return;
    const SideSpec *sp = &d->s[x];
    st[HP + o] -= sp->fast_dmg[(st[ATK + x] + 4) * 9 + st[DEF + o] + 4];
    if (st[HP + o] < 0) st[HP + o] = 0;
    st[E + x] += sp->fast_gain;
    if (st[E + x] > MAX_ENERGY) st[E + x] = MAX_ENERGY;
}

static double terminal(const Duel *d, const int *st) {
    int hp0 = st[HP], hp1 = st[HP + 1];
    int result = (hp0 <= 0 && hp1 <= 0) ? 0 : (hp1 <= 0 ? 1 : -1);
    return (1 - d->w) * result + d->w * ((double)hp0 / d->s[0].hp - (double)hp1 / d->s[1].hp);
}

static double charges(Duel *d, const int *in, Queue q, const int *floating, int nf);

static double hit(Duel *d, const int *st, int x, int i, Queue rest, int shield) {
    int o = 1 - x;
    const SideSpec *sp = &d->s[x];
    int b[NF], bf[NF];
    memcpy(b, st, sizeof b);
    if (shield) b[SH + o] -= 1;
    b[HP + o] -= shield ? 1 : sp->dmg[i][(b[ATK + x] + 4) * 9 + b[DEF + o] + 4];
    if (b[HP + o] < 0) b[HP + o] = 0;
    double p = sp->buff_chance[i];
    if (p <= 0) return charges(d, b, rest, NULL, 0);
    memcpy(bf, b, sizeof bf);
    bf[ATK + x] = clamp(bf[ATK + x] + sp->buff_self[i][0]);
    bf[DEF + x] = clamp(bf[DEF + x] + sp->buff_self[i][1]);
    bf[ATK + o] = clamp(bf[ATK + o] + sp->buff_opp[i][0]);
    bf[DEF + o] = clamp(bf[DEF + o] + sp->buff_opp[i][1]);
    if (p >= 1) return charges(d, bf, rest, NULL, 0);
    double with = charges(d, bf, rest, NULL, 0);
    return p * with + (1 - p) * charges(d, b, rest, NULL, 0);
}

static double charges(Duel *d, const int *in, Queue q, const int *floating, int nf) {
    if (q.n == 0) {
        if (in[HP] <= 0 || in[HP + 1] <= 0) return terminal(d, in);
        return value(d, in, 0);
    }
    int x = q.x[0], i = q.i[0], o = 1 - x;
    Queue rest = {q.n - 1, {q.x[1], 0}, {q.i[1], 0}};
    if (in[HP + x] <= 0 || in[HP + o] <= 0) return charges(d, in, rest, floating, nf);
    int st[NF];
    memcpy(st, in, sizeof st);
    for (int t = 0; t < nf; t++) reg(d, st, floating[t]);
    if (st[HP + x] <= 0 || st[HP + o] <= 0) return charges(d, st, rest, NULL, 0);
    st[E + x] -= d->s[x].cost[i];
    if (st[SH + o] == 0) return hit(d, st, x, i, rest, 0);
    double no = hit(d, st, x, i, rest, 0);
    double yes = hit(d, st, x, i, rest, 1);
    if (o == 0) return yes > no ? yes : no;
    return yes < no ? yes : no;
}

static double resolve(Duel *d, const int *s, int k, int a0, int a1) {
    int st[NF], acts[2] = {a0, a1}, floating[2], nf = 0;
    memcpy(st, s, sizeof st);
    for (int x = 0; x < 2; x++) {
        if (!quiet(acts[x])) continue;
        int n = d->s[x].fast_turns;
        if (k % n == n - 1) reg(d, st, x);
        else floating[nf++] = x;
    }
    Queue q = {0, {0, 0}, {0, 0}};
    for (int x = 0; x < 2; x++) if (!quiet(acts[x])) { q.x[q.n] = x; q.i[q.n] = acts[x]; q.n++; }
    if (q.n == 2) {
        double atk0 = d->s[0].atk[st[ATK] + 4], atk1 = d->s[1].atk[st[ATK + 1] + 4];
        Queue r = {2, {q.x[1], q.x[0]}, {q.i[1], q.i[0]}};
        if (atk1 > atk0) q = r;
        else if (atk1 == atk0) {
            double first = charges(d, st, q, floating, nf);
            return 0.5 * first + 0.5 * charges(d, st, r, floating, nf);
        }
    }
    return charges(d, st, q, floating, nf);
}

static void quiet_turn(const Duel *d, int *st, int k) {
    for (int x = 0; x < 2; x++) {
        int n = d->s[x].fast_turns;
        if (k % n == n - 1) reg(d, st, x);
    }
}

static int actions(const Duel *d, const int *st, int k, int x, int *out) {
    const SideSpec *sp = &d->s[x];
    if (k % sp->fast_turns) { out[0] = BUSY; return 1; }
    int na = 0;
    out[na++] = FAST;
    for (int i = 0; i < sp->n_charged; i++) if (st[E + x] >= sp->cost[i]) out[na++] = i;
    return na;
}

static double turn(Duel *d, const int *st, int k, double cont) {
    int a0[3], a1[3];
    int m = actions(d, st, k, 0, a0), n = actions(d, st, k, 1, a1);
    if (m == 1 && n == 1) return cont;
    double M[3][3];
    for (int i = 0; i < m; i++)
        for (int j = 0; j < n; j++)
            M[i][j] = (quiet(a0[i]) && quiet(a1[j])) ? cont : resolve(d, st, k, a0[i], a1[j]);
    if (n == 1) { double v = M[0][0]; for (int i = 1; i < m; i++) if (M[i][0] > v) v = M[i][0]; return v; }
    if (m == 1) { double v = M[0][0]; for (int j = 1; j < n; j++) if (M[0][j] < v) v = M[0][j]; return v; }
    return solve_value(M, m, n);
}

static double cycle(Duel *d, const int *s, int k) {
    int chain[MAX_PERIOD][NF], len = 0, st[NF], ended = 0;
    double v = 0.0;
    memcpy(st, s, sizeof st);
    for (int j = k; j < d->period; j++) {
        memcpy(chain[len++], st, sizeof st);
        quiet_turn(d, st, j);
        if (st[HP] <= 0 || st[HP + 1] <= 0) { v = terminal(d, st); ended = 1; break; }
    }
    if (!ended) v = value(d, st, 0);
    for (int idx = len - 1; idx >= 0; idx--) v = turn(d, chain[idx], k + idx, v);
    return v;
}

static double value(Duel *d, const int *s, int k) {
    if (k) return cycle(d, s, k);
    uint64_t key = pack(s);
    Slot *sl = find(d->slots, d->cap, key);
    if (sl->key) return sl->value;
    double v = cycle(d, s, 0);
    insert(d, key, v);
    return v;
}

/* API -------------------------------------------------------------------------------------- */

void *duel_new(const SideSpec *a, const SideSpec *b, int period, double w) {
    if (period > MAX_PERIOD) return NULL;
    Duel *d = calloc(1, sizeof(Duel));
    d->s[0] = *a;
    d->s[1] = *b;
    d->period = period;
    d->w = w;
    d->cap = 1 << 16;
    d->slots = calloc(d->cap, sizeof(Slot));
    return d;
}

void duel_free(void *h) {
    Duel *d = h;
    free(d->slots);
    free(d);
}

long duel_size(void *h) { return (long)((Duel *)h)->size; }

double duel_value(void *h, const int *s, int k) { return value(h, s, k); }

double duel_continue(void *h, const int *s, int k) {
    Duel *d = h;
    int st[NF];
    memcpy(st, s, sizeof st);
    quiet_turn(d, st, k);
    if (st[HP] <= 0 || st[HP + 1] <= 0) return terminal(d, st);
    return value(d, st, (k + 1) % d->period);
}

double duel_resolve(void *h, const int *s, int k, int a0, int a1) { return resolve(h, s, k, a0, a1); }

double duel_hit(void *h, const int *st, int x, int i, int rest_x, int rest_i, int shield) {
    Queue rest = {rest_x >= 0, {rest_x, 0}, {rest_i, 0}};
    return hit(h, st, x, i, rest, shield);
}
