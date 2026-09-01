from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import tempfile
import unittest

from tools.coco80.ablation import (
    AblationError, FORMAT_SUMMARY, SAMPLE_FIELDS, build_manifest,
    summarize, timing_to_samples, write_paper_tables,
)
from tools.coco80.assets import sha256_file
from tools.coco80.hardware_plan import COCO80_HARDWARE_PLAN
from tools.coco80.net_protocol import (
    DECODE_DEMO, EXTENDED_TIMING, EXTENDED_TIMING_BYTES,
    EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION, OUTPUT_TIMING,
)


ROOT = Path(__file__).resolve().parents[2]


class AblationTests(unittest.TestCase):
    def _hardware(self, root: Path, variant: str) -> tuple[Path, Path, Path, Path, Path, Path]:
        profile = f"abi_v2_ablation_200_{variant}"
        features = {"a1": (1, 0, 0), "a2": (1, 1, 0)}[variant]
        directory = root / variant / "reports"
        directory.mkdir(parents=True)
        metadata = directory / "build_profile.txt"
        metadata.write_text("\n".join([
            f"profile={profile}", "clock_hz=200000000", "rows=18", "cols=16",
            "cout_tile=32", f"enable_layer_long_hwc_ifm={features[0]}",
            "enable_tagged_context=1", f"enable_weight_preload={features[1]}",
            f"enable_fast_context_handoff={features[2]}", "enforce_gates=1",
            "git_sha=0123456789abcdef", "git_dirty=0", "git_dirty_end=0",
            "provenance_stable=1",
            "release_eligible=0", "ablation_profile=1", "",
        ]), encoding="utf-8")
        (directory / "system_impl_gate.txt").write_text("\n".join([
            "gate=SYSTEM_IMPL", "status=PASS", "metric.lut=56000",
            "metric.ff=48000", "metric.clb_percent=75.00", "metric.bram=94",
            "metric.uram=48", "metric.dsp=650", "metric.wns=0.010", "",
        ]), encoding="utf-8")
        bit = root / variant / "design.bit"; bit.write_bytes((variant + "bit").encode())
        xsa = root / variant / "design.xsa"; xsa.write_bytes((variant + "xsa").encode())
        sha = directory / "system_artifacts.sha256"
        sha.write_text(f"{sha256_file(bit)}  {bit.name}\n{sha256_file(xsa)}  {xsa.name}\n",
                       encoding="utf-8")
        power = directory / "system_power_post_route.rpt"
        power.write_text("\n".join([
            "| Total On-Chip Power (W)  | 4.000 |",
            "| Dynamic (W)              | 3.700 |",
            "| Device Static (W)        | 0.300 |",
            "| Junction Temperature (C) | 34.0  |",
            "| Confidence Level         | Medium |",
        ]), encoding="utf-8")
        assumptions = directory / "system_power_assumptions.txt"
        assumptions.write_text("\n".join([
            "format=lasa-post-route-power-assumptions", "version=1",
            "vivado_version=2022.2", "operating_process=typical",
            "ambient_temp_c=25", "default_toggle_rate_percent=12.5",
            "default_static_probability=0.5", "resets=deasserted",
            "activity_source=vectorless", "saif=none",
            "measurement=post_route_estimated", "",
        ]), encoding="utf-8")
        return metadata, sha, bit, xsa, power, assumptions

    def _manifest(self, root: Path, variant: str) -> Path:
        metadata, sha, bit, xsa, power, assumptions = self._hardware(root, variant)
        parameter = root / "parameters.json"
        parameter.write_text(json.dumps({"layers": [
            {
                "layer_id": item.layer.layer_id,
                "schedule": {"ofm_bytes": item.ofm_bytes},
                "bias": {"bytes": item.bias_bytes},
                "weight": {"bytes": item.weight_bytes},
            }
            for item in COCO80_HARDWARE_PLAN.layers
        ]}), encoding="utf-8")
        index = root / "input.json"; index.write_text("[]", encoding="utf-8")
        output = root / f"{variant}.json"
        build_manifest(argparse.Namespace(
            variant=variant, stream_config=0x2B, experiment="full", layers=None,
            case_label=variant,
            sessions=1, warmup=1, timed=2, hardware_metadata=metadata,
            hardware_sha_manifest=sha, bit=bit, xsa=xsa,
            power_report=power, power_assumptions=assumptions,
            model_spec=ROOT / "tools/coco80/model_spec.json",
            parameter_manifest=parameter, input_index=index, output=output,
        ))
        return output

    @staticmethod
    def _timing(
        path: Path, layer_ticks: int, traffic: dict[str, dict[str, int]],
        contract: dict[str, dict[str, int]],
    ) -> None:
        rows = []
        for index in range(3):
            telemetry = []
            for layer in (
                "m0", "m2", "m4", "m6", "m8", "m10", "m13",
                "m14", "m15", "m16", "m19", "p4_detect", "p5_detect",
            ):
                expected_ifm = traffic[layer]["lasa_external_ifm_bytes"]
                words = [
                    expected_ifm, contract[layer]["bias_dma_bytes"],
                    contract[layer]["weight_dma_bytes"], contract[layer]["ofm_dma_bytes"],
                    1, 1, 1, 1, 1,
                ]
                words.extend([0, 0, 0, 0, 0, 0, 1, 0, 1])
                words.extend([0] * (32 - len(words)))
                telemetry.extend(words)
            rows.append(EXTENDED_TIMING.pack(
                EXTENDED_TIMING_MAGIC, EXTENDED_TIMING_VERSION,
                EXTENDED_TIMING_BYTES, index + 1, index + 1, 200_000_000,
                OUTPUT_TIMING, DECODE_DEMO, 1000, 800, 150, 50, 10, 10, 30,
                *([layer_ticks] * 13), *([10] * 10), 1, 13, 0, 0x1234 + index,
                0x2B, 13, 128, *([0] * 5), *telemetry,
            ))
        path.write_bytes(b"".join(rows))

    def test_manifest_samples_summary_and_paper_are_hash_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifests, samples = [], []
            for variant, ticks in (("a1", 100), ("a2", 80)):
                manifest = self._manifest(root, variant)
                parsed_manifest = json.loads(manifest.read_text(encoding="utf-8"))
                timing = root / f"{variant}.bin"
                self._timing(
                    timing, ticks, parsed_manifest["workload"]["traffic_model"],
                    parsed_manifest["workload"]["dma_contract"],
                )
                sample = root / f"{variant}.csv"
                self.assertEqual(timing_to_samples(argparse.Namespace(
                    manifest=manifest, timing=[timing], session=[1], output=sample)), 3)
                with sample.open(newline="", encoding="utf-8") as handle:
                    self.assertEqual(tuple(csv.DictReader(handle).fieldnames or ()), SAMPLE_FIELDS)
                manifests.append(manifest); samples.append(sample)
            failure_root = root / "a0" / "reports"
            failure_root.mkdir(parents=True)
            failure_profile = failure_root / "build_profile.txt"
            failure_profile.write_text("\n".join([
                "profile=abi_v2_ablation_200_a0", "clock_hz=200000000",
                "git_sha=0123456789abcdef", "git_dirty=0", "",
            ]), encoding="utf-8")
            failure_gate = failure_root / "system_place_gate.txt"
            failure_gate.write_text("\n".join([
                "gate=SYSTEM_PLACE", "status=FAIL", "metric.lut=43000",
                "metric.clb_percent=60.0", "metric.bram=94", "metric.uram=36",
                "metric.dsp=650", "metric.wns=-2.842", "",
            ]), encoding="utf-8")
            failure_log = root / "a0.log"; failure_log.write_text("FAIL", encoding="utf-8")
            failure_jou = root / "a0.jou"; failure_jou.write_text("FAIL", encoding="utf-8")
            bound = lambda path: {
                "path": str(path), "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
            failure_path = failure_root / "ablation_hardware_failure.json"
            failure_path.write_text(json.dumps({
                "format": "kv260-lasa-ablation-hardware", "version": 1,
                "status": "FAIL", "variant": "a0",
                "profile": "abi_v2_ablation_200_a0",
                "reason": "formal implementation failed",
                "git_sha": "0123456789abcdef", "release_eligible": False,
                "bit_xsa_published": False, "gate": bound(failure_gate),
                "build_profile": bound(failure_profile), "log": bound(failure_log),
                "journal": bound(failure_jou),
            }), encoding="utf-8")
            summary_path = root / "summary.json"
            result = summarize(argparse.Namespace(
                manifest=manifests, samples=samples,
                hardware_failure=[failure_path], output=summary_path))
            self.assertEqual(result["format"], FORMAT_SUMMARY)
            self.assertEqual(result["failed_hardware"][0]["failed_gate"], "SYSTEM_PLACE")
            self.assertEqual(result["paired_comparisons"][0]["paired_rows"], 26)
            self.assertAlmostEqual(
                result["paired_comparisons"][0]["layer_speedup"]["mean"], 1.25)
            output_json, output_tex = root / "paper.json", root / "paper.tex"
            write_paper_tables(argparse.Namespace(
                summary=summary_path, output_json=output_json, output_tex=output_tex))
            self.assertTrue(output_json.is_file())
            tex = output_tex.read_text(encoding="utf-8")
            self.assertIn("A1", tex)
            self.assertIn("A0", tex)
            self.assertEqual(
                tex.count("\\begin{table*}"), tex.count("\\end{table*}"))
            self.assertEqual(
                tex.count("\\begin{table}"), tex.count("\\end{table}"))

    def test_manifest_rejects_profile_feature_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            metadata, sha, bit, xsa, power, assumptions = self._hardware(root, "a1")
            metadata.write_text(metadata.read_text().replace(
                "enable_weight_preload=0", "enable_weight_preload=1"), encoding="utf-8")
            dummy = root / "dummy"; dummy.write_text("x", encoding="utf-8")
            with self.assertRaisesRegex(AblationError, "mismatch"):
                build_manifest(argparse.Namespace(
                    variant="a1", stream_config=0x2B, experiment="full", layers=None,
                    case_label="drift",
                    sessions=1, warmup=1, timed=2, hardware_metadata=metadata,
                    hardware_sha_manifest=sha, bit=bit, xsa=xsa,
                    power_report=power, power_assumptions=assumptions,
                    model_spec=ROOT / "tools/coco80/model_spec.json",
                    parameter_manifest=dummy, input_index=dummy, output=root / "out.json",
                ))


if __name__ == "__main__":
    unittest.main()
