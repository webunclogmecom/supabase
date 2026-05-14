# Truck attribution thresholds — retro analysis

_Generated 2026-05-14. Sample = 46 known-good visits with property GPS, run against canonical vehicle_telemetry_readings._

## Composition by truck

| Truck | Visits sampled |
|---|---:|
| Cloggy | 8 |
| Moises | 37 |
| David | 1 |
| _(no GPS at all)_ | 1 |

## Percentiles (pings + dwell within distance threshold)

| Threshold | p10 pings | p50 pings | p90 pings | p10 dwell (min) | p50 dwell (min) | p90 dwell (min) | % with ≥1 ping |
|---|---:|---:|---:|---:|---:|---:|---:|
| 100m | 1 | 63 | 304 | 0 | 69 | 164 | 76% |
| 150m | 1 | 72 | 486 | 0 | 65 | 168 | 76% |
| 250m | 1 | 87 | 498 | 0 | 65 | 168 | 78% |
| 333m | 1 | 94 | 530 | 0 | 66 | 168 | 78% |
| 500m | 1 | 105 | 540 | 0 | 67 | 169 | 78% |
| 1000m | 1 | 142 | 596 | 0 | 79 | 187 | 78% |

## Candidate rules (distance ≤ D AND dwell ≥ T min) — coverage of known-good visits

| Rule | Captures | Coverage |
|---|---:|---:|
| ≤250m for ≥0min | 46 | 100% |
| ≤333m for ≥0min | 46 | 100% |
| ≤500m for ≥0min | 46 | 100% |
| ≤150m for ≥0min | 44 | 96% |
| ≤100m for ≥0min | 42 | 91% |
| ≤250m for ≥1min | 36 | 78% |
| ≤333m for ≥1min | 36 | 78% |
| ≤500m for ≥1min | 36 | 78% |
| ≤500m for ≥2min | 36 | 78% |
| ≤100m for ≥1min | 35 | 76% |
| ≤100m for ≥2min | 35 | 76% |
| ≤100m for ≥5min | 35 | 76% |
| ≤100m for ≥10min | 35 | 76% |
| ≤100m for ≥15min | 35 | 76% |
| ≤100m for ≥20min | 35 | 76% |
| ≤150m for ≥1min | 35 | 76% |
| ≤150m for ≥2min | 35 | 76% |
| ≤150m for ≥5min | 35 | 76% |
| ≤150m for ≥10min | 35 | 76% |
| ≤150m for ≥15min | 35 | 76% |
| ≤150m for ≥20min | 35 | 76% |
| ≤250m for ≥2min | 35 | 76% |
| ≤250m for ≥5min | 35 | 76% |
| ≤250m for ≥10min | 35 | 76% |
| ≤250m for ≥15min | 35 | 76% |
| ≤250m for ≥20min | 35 | 76% |
| ≤333m for ≥2min | 35 | 76% |
| ≤333m for ≥5min | 35 | 76% |
| ≤333m for ≥10min | 35 | 76% |
| ≤333m for ≥15min | 35 | 76% |
