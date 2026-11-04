#!/usr/bin/env python3
# zle-cost-sum.py <raw.tsv>: per round ratio of each setting to off in
# the same round, median and min-max over the rounds.  off2 against off
# is the A/A control: a difference inside its range is noise.
import csv
import statistics
import sys

METRICS = ['iops', 'eff_mib', 'p50_us', 'p99_us', 'sys_us_io', 'usr_us_io',
           'wall_s']

rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
byk = {(r['round'], r['target'], r['pattern'], r['data'], r['setting']): r
       for r in rows}
conds = sorted({(r['target'], r['pattern'], r['data']) for r in rows})
rounds = sorted({r['round'] for r in rows})

print('target', 'pattern', 'data', 'setting', 'metric', 'off_median',
      'median', 'ratio_median', 'ratio_min', 'ratio_max', sep='\t')
for c in conds:
    for s in ('off2', 'zle', 'lz4'):
        for m in METRICS:
            ratios, base, vals = [], [], []
            for r in rounds:
                o = byk.get((r, *c, 'off'))
                x = byk.get((r, *c, s))
                if o is None or x is None or float(o[m]) == 0:
                    continue
                ratios.append(float(x[m]) / float(o[m]))
                base.append(float(o[m]))
                vals.append(float(x[m]))
            if ratios:
                print(*c, s, m, statistics.median(base),
                      statistics.median(vals),
                      '%.3f' % statistics.median(ratios),
                      '%.3f' % min(ratios), '%.3f' % max(ratios), sep='\t')
