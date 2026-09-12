"""Acceptance logic for the resident timing harness; no video or Windows API needed."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('bench_service', Path(__file__).with_name('bench-service.py'))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def run(arm, renders, peak_mb=450):
    return dict(round=0, arm=arm, jobs=[
        dict(render=value, memory=None if peak_mb is None else
             dict(peak_ws_mib=peak_mb * 1000000 / 1048576)) for value in renders])


class AcceptanceTests(unittest.TestCase):
    def test_stable_slow_run_passes_age_gate_but_fails_latency_budget(self):
        runs = [run(arm, [1.4] * 50) for arm in ['fresh', 'aged']]
        result = bench.summarize(runs, 1.3, max_p95_seconds=1.3)
        self.assertFalse(result['slowdown_detected'])
        self.assertTrue(result['budget_exceeded'])
        self.assertEqual([v['metric'] for v in result['budget_violations']],
                         ['warm_p95_seconds', 'warm_p95_seconds'])

    def test_fast_process_cannot_hide_another_process_tail(self):
        runs = [run('fresh', [1.0] * 50), run('aged', [1.0] * 47 + [1.4] * 3)]
        result = bench.summarize(runs, 2, max_p95_seconds=1.3)
        self.assertEqual(len(result['budget_violations']), 1)
        self.assertEqual(result['budget_violations'][0]['arm'], 'aged')

    def test_first_render_is_excluded_from_warm_budget(self):
        runs = [run(arm, [2.0] + [1.2] * 49) for arm in ['fresh', 'aged']]
        result = bench.summarize(runs, 1.3, max_p95_seconds=1.3)
        self.assertFalse(result['budget_exceeded'])
        self.assertEqual(result['process_budgets'][0]['warm_samples'], 49)

    def test_memory_budget_uses_decimal_mb_and_includes_first_render(self):
        runs = [run(arm, [1.2] * 10, peak_mb=512) for arm in ['fresh', 'aged']]
        self.assertFalse(bench.summarize(runs, 1.3, max_peak_mb=512)['budget_exceeded'])
        runs[0]['jobs'][0]['memory']['peak_ws_mib'] = 490
        result = bench.summarize(runs, 1.3, max_peak_mb=512)
        self.assertEqual(result['budget_violations'][0]['metric'], 'peak_ws_mb')
        self.assertGreater(result['budget_violations'][0]['observed'], 512)

    def test_unavailable_memory_fails_required_memory_budget(self):
        runs = [run(arm, [1.2] * 10, peak_mb=None) for arm in ['fresh', 'aged']]
        self.assertTrue(bench.summarize(runs, 1.3, max_peak_mb=512)['budget_exceeded'])

    def test_omitting_budgets_preserves_age_only_acceptance(self):
        runs = [run(arm, [1.4] * 10, peak_mb=None) for arm in ['fresh', 'aged']]
        result = bench.summarize(runs, 1.3)
        self.assertFalse(result['budget_exceeded'])
        self.assertFalse(result['slowdown_detected'])


if __name__ == '__main__':
    unittest.main()
