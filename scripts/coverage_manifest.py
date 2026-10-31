#!/usr/bin/env python3.11
"""Reproducible AXI4-Lite regression/coverage manifest runner."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import html
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from typing import Any

SCHEMA_VERSION = "1.0"
COVERAGE_TYPES = "line+cond+fsm+tgl+branch+assert"
UVM_KEYS = ("UVM_WARNING", "UVM_ERROR", "UVM_FATAL")


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def read_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def read_plan(path: Path) -> dict[str, Any]:
    """Read a plan, optionally extending a base plan without mutating it."""
    raw = read_json(path)
    extends = raw.pop("extends", None)
    if extends is None:
        return raw
    base_path = (path.parent / extends).resolve()
    if base_path == path.resolve():
        raise ValueError(f"plan cannot extend itself: {path}")
    merged = json.loads(json.dumps(read_plan(base_path)))
    for key, value in raw.items():
        if key == "runs":
            merged.setdefault("runs", []).extend(value)
        elif key in ("builds", "merge_groups", "source_inventory"):
            merged.setdefault(key, {}).update(value)
        else:
            merged[key] = value
    merged["resolved_extends"] = str(base_path)
    return merged


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(data, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    os.replace(temporary, path)


def canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def compatibility_signature(plan: dict[str, Any], run: dict[str, Any]) -> dict[str, Any]:
    build = plan["builds"][run["build_variant"]]
    return {
        "top": build["top"],
        "build_variant": run["build_variant"],
        "compile_config": build.get("compile_config", ""),
        "dut_parameters": build["dut_parameters"],
        "coverage_object": run["coverage_object"],
    }


def validate_plan(plan: dict[str, Any]) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    for key in ("schema_version", "builds", "merge_groups", "runs"):
        if key not in plan:
            errors.append(f"missing top-level key: {key}")
    if errors:
        return errors, warnings
    required = (
        "id", "set", "merge_group", "test_name", "target", "seed",
        "execution_target", "build_variant", "config", "coverage_object",
        "driver_mode", "runtime_parameters", "expected_outcome", "plusargs",
    )
    run_ids: set[str] = set()
    seeds: dict[tuple[str, str, str, int], list[str]] = collections.defaultdict(list)
    grouped: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for index, run in enumerate(plan["runs"]):
        missing = [key for key in required if key not in run]
        if missing:
            errors.append(f"run[{index}] missing keys: {', '.join(missing)}")
            continue
        run_id = run["id"]
        if run_id in run_ids:
            errors.append(f"duplicate run id: {run_id}")
        run_ids.add(run_id)
        if run["build_variant"] not in plan["builds"]:
            errors.append(f"{run_id}: unknown build_variant {run['build_variant']}")
        if run["merge_group"] not in plan["merge_groups"]:
            errors.append(f"{run_id}: unknown merge_group {run['merge_group']}")
        elif plan["merge_groups"][run["merge_group"]]["coverage_object"] != run["coverage_object"]:
            errors.append(f"{run_id}: coverage object does not match merge group")
        if not isinstance(run["seed"], int) or run["seed"] < 0:
            errors.append(f"{run_id}: seed must be a non-negative integer")
        expected = run["expected_outcome"]
        if expected.get("kind") not in ("clean_uvm", "controlled_checker_faults"):
            errors.append(f"{run_id}: unsupported expected outcome")
        if expected.get("kind") == "controlled_checker_faults":
            if not expected.get("fault_injection") or not expected.get("required_markers"):
                errors.append(f"{run_id}: controlled fault run needs faults and markers")
        seeds[(run["test_name"], run["build_variant"], run["config"], run["seed"])].append(run_id)
        grouped[run["merge_group"]].append(run)
    for key, ids in sorted(seeds.items()):
        if len(ids) > 1:
            warnings.append(
                f"duplicate seed for identical test/build/config {key}: {', '.join(ids)}"
            )
    for group_name, runs in sorted(grouped.items()):
        signatures: dict[str, list[str]] = collections.defaultdict(list)
        for run in runs:
            if run["build_variant"] in plan["builds"]:
                signatures[canonical(compatibility_signature(plan, run))].append(run["id"])
        if len(signatures) > 1:
            errors.append(f"merge group {group_name} mixes incompatible variants")
    return errors, warnings


def coverage_db_present(path: Path) -> bool:
    db_root = path / "snps" / "coverage" / "db"
    testdata = db_root / "testdata"
    return (
        path.is_dir() and db_root.is_dir() and testdata.is_dir()
        and any(item.is_file() for item in testdata.rglob("*"))
    )


def parse_uvm_summary(text: str) -> dict[str, int | None]:
    counts: dict[str, int | None] = {key: None for key in UVM_KEYS}
    for key in UVM_KEYS:
        matches = re.findall(rf"^{key}\s*:\s*(\d+)\s*$", text, re.MULTILINE)
        if matches:
            counts[key] = int(matches[-1])
    return counts


def count_runtime_sva_failures(text: str) -> int:
    patterns = (
        r"(?im)^Error-\[(?:SVA|OVL)[^\]]*\]",
        r"(?im)\bassert(?:ion)?\b[^\n]*(?:failed|failure)",
        r"(?im)\bSVA\b[^\n]*(?:failed|failure)",
    )
    lines: set[str] = set()
    for pattern in patterns:
        for match in re.finditer(pattern, text):
            start = text.rfind("\n", 0, match.start()) + 1
            end = text.find("\n", match.end())
            lines.add(text[start:end if end >= 0 else len(text)])
    return len(lines)


def evaluate_run(
    exit_code: int,
    log_path: Path,
    coverage_db: Path,
    expected_outcome: dict[str, Any],
) -> dict[str, Any]:
    text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    uvm = parse_uvm_summary(text)
    sva_failures = count_runtime_sva_failures(text)
    db_ok = coverage_db_present(coverage_db)
    missing_markers = [
        marker for marker in expected_outcome.get("required_markers", []) if marker not in text
    ]
    reasons: list[str] = []
    if exit_code != 0:
        reasons.append(f"run_exit_code={exit_code}")
    if not log_path.is_file():
        reasons.append("missing_log")
    if any(uvm[key] is None for key in UVM_KEYS):
        reasons.append("missing_uvm_summary")
    if (uvm["UVM_ERROR"] or 0) != 0:
        reasons.append(f"UVM_ERROR={uvm['UVM_ERROR']}")
    if (uvm["UVM_FATAL"] or 0) != 0:
        reasons.append(f"UVM_FATAL={uvm['UVM_FATAL']}")
    if sva_failures:
        reasons.append(f"runtime_sva_failures={sva_failures}")
    if not db_ok:
        reasons.append("missing_or_empty_coverage_db")
    if missing_markers:
        reasons.append("missing_expected_markers=" + ",".join(missing_markers))
    return {
        "status": "PASS" if not reasons else "FAIL",
        "reasons": reasons,
        "uvm_warning": uvm["UVM_WARNING"],
        "uvm_error": uvm["UVM_ERROR"],
        "uvm_fatal": uvm["UVM_FATAL"],
        "sva_failures": sva_failures,
        "coverage_db_present": db_ok,
        "expected_outcome_observed": not missing_markers,
        "missing_expected_markers": missing_markers,
    }


def run_command(
    command: list[str], cwd: Path, environment: dict[str, str], console_log: Path
) -> tuple[int, str, str]:
    console_log.parent.mkdir(parents=True, exist_ok=True)
    started = now_iso()
    completed = subprocess.run(
        command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, errors="replace", check=False
    )
    console_log.write_text(completed.stdout, encoding="utf-8", newline="\n")
    return completed.returncode, started, now_iso()


def command_string(command: list[str]) -> str:
    return shlex.join(str(value) for value in command)


def git_value(repo_root: Path, args: list[str]) -> str:
    result = subprocess.run(
        ["git", *args], cwd=repo_root, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, check=False
    )
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def tool_identity(vcs: Path, environment: dict[str, str], cwd: Path) -> str:
    result = subprocess.run(
        [str(vcs), "-full64", "-ID"], cwd=cwd, env=environment, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False
    )
    match = re.search(r"Compiler version\s*=\s*(.+)", result.stdout)
    return match.group(1).strip() if match else "unavailable"


def resolved_record(plan: dict[str, Any], run: dict[str, Any], selected: bool) -> dict[str, Any]:
    build = plan["builds"][run["build_variant"]]
    planned = dict(run)
    planned.update({
        "planned": True, "selected": selected, "top": build["top"],
        "compile_config": build.get("compile_config", ""),
        "dut_parameters": build["dut_parameters"],
    })
    return {
        "id": run["id"],
        "planned": planned,
        "actual": {
            "status": "NOT_RUN", "run_timestamp_start": None,
            "run_timestamp_end": None, "exit_code": None, "uvm_warning": None,
            "uvm_error": None, "uvm_fatal": None, "sva_failures": None,
            "coverage_db": None, "coverage_db_present": False,
            "report_path": None, "command": None, "log_path": None,
            "reasons": ["not selected"] if not selected else ["not run"],
        },
    }


def make_manifest(
    plan_path: Path, plan: dict[str, Any], selected_ids: set[str], warnings: list[str]
) -> dict[str, Any]:
    repo_root = plan_path.resolve().parent.parent
    return {
        "schema_version": SCHEMA_VERSION, "phase": plan.get("phase", "AXI4-Lite coverage"),
        "plan_path": str(plan_path.resolve()), "generated_at": now_iso(),
        "git": {
            "commit": git_value(repo_root, ["rev-parse", "HEAD"]),
            "branch": git_value(repo_root, ["branch", "--show-current"]),
            "describe": git_value(repo_root, ["describe", "--always", "--tags", "--dirty"]),
        },
        "warnings": warnings, "source_inventory": plan.get("source_inventory", {}),
        "runs": [
            resolved_record(plan, run, run["id"] in selected_ids) for run in plan["runs"]
        ],
        "builds": {}, "merge_results": {}, "overall_status": "PLANNED",
    }


def metric_value(value: str) -> dict[str, Any]:
    if value.endswith("%"):
        return {"covered": None, "total": None, "percent": float(value[:-1])}
    if "/" in value:
        covered, total = (int(part) for part in value.split("/", 1))
        percent = round(100.0 * covered / total, 2) if total else None
        return {"covered": covered, "total": total, "percent": percent}
    return {"covered": None, "total": None, "percent": None}


def parse_urg_report(report_path: Path) -> dict[str, Any]:
    result: dict[str, Any] = {
        "metrics": {name: None for name in (
            "line", "condition", "toggle", "fsm", "branch", "assertion",
            "functional_group"
        )},
        "assertion_objects_total": None, "assertion_objects_attempted": None,
        "assertion_attempts": None, "assertion_failures": None,
        "sva_cover_properties_total": None,
        "sva_cover_properties_matched": None, "low_coverage_modules": [],
    }
    session = report_path / "session.xml"
    if session.is_file():
        text = session.read_text(encoding="utf-8", errors="replace")
        top_match = re.search(r'<scope type="top" name="top">(.*?)</scope>', text, re.DOTALL)
        if top_match:
            names = {
                "Line": "line", "Cond": "condition", "Toggle": "toggle",
                "FSM": "fsm", "Branch": "branch", "Assert": "assertion",
                "Group": "functional_group",
            }
            for source, destination in names.items():
                match = re.search(
                    rf'<metric name="{source}" value="([^"]+)"', top_match.group(1)
                )
                if match:
                    result["metrics"][destination] = metric_value(match.group(1))
    asserts = report_path / "asserts.html"
    if asserts.is_file():
        text = asserts.read_text(encoding="utf-8", errors="replace")
        assertion_section = re.search(
            r"Summary for Assertions</b><table.*?</table>", text, re.DOTALL
        )
        cover_section = re.search(
            r"Summary for Cover Properties</b><table.*?</table>", text, re.DOTALL
        )
        if assertion_section:
            clean = re.sub(r"<[^>]+>", " ", assertion_section.group(0))
            total = re.search(r"Total Number\s+(\d+)", clean)
            failures = re.search(r"Failure\s+(\d+)", clean)
            no_attempt = re.search(r"Without Attempts\s+(\d+)", clean)
            if total:
                result["assertion_objects_total"] = int(total.group(1))
            if failures:
                result["assertion_failures"] = int(failures.group(1))
            if total and no_attempt:
                result["assertion_objects_attempted"] = int(total.group(1)) - int(no_attempt.group(1))
        if cover_section:
            clean = re.sub(r"<[^>]+>", " ", cover_section.group(0))
            total = re.search(r"Total Number\s+(\d+)", clean)
            matches = re.search(r"Matches\s+(\d+)", clean)
            if total:
                result["sva_cover_properties_total"] = int(total.group(1))
            if matches:
                result["sva_cover_properties_matched"] = int(matches.group(1))
        detail_rows = re.findall(
            r'<tr class="wht"><td class="lf"><a name="tag_hvp_ast_.*?</tr>',
            text, re.DOTALL
        )
        attempt_total = 0
        failure_total = 0
        parsed_rows = 0
        for row in detail_rows:
            cells = re.findall(r"<td[^>]*>(.*?)</td>", row, re.DOTALL)
            if len(cells) < 7:
                continue
            values = []
            for cell in cells[1:7]:
                match = re.search(r"\d+", re.sub(r"<[^>]+>", " ", cell))
                values.append(int(match.group(0)) if match else 0)
            attempt_total += values[2]
            failure_total += values[4]
            parsed_rows += 1
        if parsed_rows:
            result["assertion_attempts"] = attempt_total
            result["assertion_failures"] = failure_total
    modules = report_path / "modlist.html"
    if modules.is_file():
        text = modules.read_text(encoding="utf-8", errors="replace")
        rows = re.findall(
            r'<tr data-tt-id="mod_[^"]+" data-tt-parent-id="hierarchyTable_root">(.*?)</tr>',
            text, re.DOTALL
        )
        for row in rows:
            cells = re.findall(r"<td[^>]*>(.*?)</td>", row, re.DOTALL)
            if len(cells) < 2:
                continue
            names = re.findall(r">\s*([^<>]+?)\s*</a>", cells[0], re.DOTALL)
            score_match = re.search(r"(\d+(?:\.\d+)?)", re.sub(r"<[^>]+>", " ", cells[1]))
            if names and score_match and float(score_match.group(1)) < 90.0:
                result["low_coverage_modules"].append({
                    "module": html.unescape(names[-1].strip()),
                    "score": float(score_match.group(1)),
                })
    return result


def select_runs(plan: dict[str, Any], sets: set[str] | None) -> set[str]:
    if not sets or "all" in sets:
        return {run["id"] for run in plan["runs"]}
    return {run["id"] for run in plan["runs"] if run["set"] in sets}


def write_overview(path: Path, manifest: dict[str, Any], plan: dict[str, Any]) -> None:
    lines = [
        f"# {plan.get('phase', 'AXI4-Lite')} Coverage Overview", "",
        f"- 生成时间：{manifest['generated_at']}",
        f"- Git：{manifest['git']['describe']} ({manifest['git']['commit']})",
        f"- 工具：{manifest.get('tool', 'not run')}",
        f"- 总体状态：{manifest['overall_status']}", "",
        "## Run 结果", "",
        "| ID | Set / group | Test | Target | Seed | 执行对象 | Driver | 预期 | 实际 | Exit | UVM W/E/F | SVA fail | DB |",
        "|---|---|---|---|---:|---|---|---|---|---:|---|---:|---|",
    ]
    for record in manifest["runs"]:
        planned, actual = record["planned"], record["actual"]
        counts = f"{actual['uvm_warning']}/{actual['uvm_error']}/{actual['uvm_fatal']}"
        lines.append(
            f"| {record['id']} | {planned['set']} / {planned['merge_group']} | "
            f"{planned['test_name']} | {planned['target']} | {planned['seed']} | "
            f"{planned['execution_target']} | {planned['driver_mode']} | "
            f"{planned['expected_outcome']['kind']} | {actual['status']} | "
            f"{actual['exit_code']} | {counts} | {actual['sva_failures']} | "
            f"{actual['coverage_db_present']} |"
        )
    lines.extend(["", "## URG 分组汇总", ""])
    if manifest["merge_results"]:
        lines.extend([
            "| Group | Coverage object / claim | 状态 | Tests | Line | Cond | Toggle | FSM | Branch | Functional | Assertion attempts/fail | SVA covers |",
            "|---|---|---|---:|---:|---:|---:|---|---:|---:|---|---|",
        ])
        for group_name, merge in manifest["merge_results"].items():
            report = merge.get("report_metrics", {})
            metrics = report.get("metrics", {})
            def pct(name: str) -> str:
                value = metrics.get(name)
                return "N/A" if not value or value.get("percent") is None else f"{value['percent']:.2f}%"
            group_plan = plan["merge_groups"][group_name]
            lines.append(
                f"| {group_name} | {group_plan['coverage_object']} — {group_plan['coverage_claim']} | "
                f"{merge['status']} | {merge['included_run_count']} | {pct('line')} | "
                f"{pct('condition')} | {pct('toggle')} | {pct('fsm')} | {pct('branch')} | "
                f"{pct('functional_group')} | {report.get('assertion_attempts')}/"
                f"{report.get('assertion_failures')} | {report.get('sva_cover_properties_matched')}/"
                f"{report.get('sva_cover_properties_total')} |"
            )
        lines.append("")
    else:
        lines.extend(["尚未执行 URG 合并。", ""])
    lines.extend([
        "## 真实边界与 gaps", "",
        "- FSM 的 N/A 表示 URG 没有可评分 FSM 对象，不得解释为 0% 或 100%。",
        "- v4_controlled_slave 证明 v4 BFM/controlled slave，不是 GPIO DUT RTL coverage。",
        "- checker_selftest PASS 表示受控 fault injection 被检出且未污染正常回归。",
        "- Functional group 只代表当前被计分的 covergroups，不代表全部规格已 sign-off。",
    ])
    for group_name, merge in manifest["merge_results"].items():
        low = merge.get("report_metrics", {}).get("low_coverage_modules", [])
        if low:
            summary = ", ".join(f"{item['module']}={item['score']:.2f}%" for item in low)
            lines.append(f"- {group_name} 低于 90% 的模块定义总分：{summary}。")
    if plan.get("report_notes"):
        lines.extend(f"- {note}" for note in plan["report_notes"])
        lines.append("")
    else:
        lines.extend([
            "- C3.1 只建立采集、manifest、分组、合并和报告；未新增 bin/test/waiver。",
            "- C3.2 功能覆盖收敛、C3.3 参数/负向扩展、C3.4 sign-off 均未开始。", "",
        ])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def execute(plan_path: Path, output_root: Path, selected_sets: set[str]) -> int:
    plan = read_plan(plan_path)
    errors, warnings = validate_plan(plan)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2
    selected_ids = select_runs(plan, selected_sets)
    manifest = make_manifest(plan_path, plan, selected_ids, warnings)
    repo_root = plan_path.resolve().parent.parent
    sim_dir = repo_root / "sim"
    output_root = output_root if output_root.is_absolute() else sim_dir / output_root
    output_root.mkdir(parents=True, exist_ok=True)
    manifest_path, overview_path = output_root / "manifest.json", output_root / "overview.md"
    write_json(manifest_path, manifest)
    vcs_home = Path(os.environ.get("VCS_HOME", plan["tool_defaults"]["vcs_home"]))
    vcs, urg = vcs_home / "bin" / "vcs", vcs_home / "bin" / "urg"
    environment = os.environ.copy()
    environment["VCS_HOME"] = str(vcs_home)
    environment.setdefault("VCS_ARCH_OVERRIDE", "linux")
    manifest["tool"] = tool_identity(vcs, environment, sim_dir)
    record_by_id = {record["id"]: record for record in manifest["runs"]}
    selected_runs = [run for run in plan["runs"] if run["id"] in selected_ids]
    variants = sorted({run["build_variant"] for run in selected_runs})
    build_ok: dict[str, bool] = {}
    binaries: dict[str, Path] = {}
    for variant in variants:
        build = plan["builds"][variant]
        build_dir = output_root / "build" / variant
        build_dir.mkdir(parents=True, exist_ok=True)
        binary, compile_db = build_dir / "simv_cov", build_dir / "compile.vdb"
        compile_log = output_root / "logs" / f"compile_{variant}.log"
        command = [
            str(vcs), "-full64", "-sverilog", "-ntb_opts", "uvm-1.2",
            "-timescale=1ns/1ps", "-f", build["filelist"], "-top", build["top"],
            *build.get("compile_options", []), "-cm", COVERAGE_TYPES,
            "-cm_dir", str(compile_db), "-o", str(binary), "-l", str(compile_log),
        ]
        exit_code, started, ended = run_command(
            command, sim_dir, environment,
            output_root / "logs" / f"compile_{variant}.console.log"
        )
        ok = exit_code == 0 and binary.is_file() and compile_db.is_dir()
        build_ok[variant], binaries[variant] = ok, binary
        manifest["builds"][variant] = {
            "status": "PASS" if ok else "FAIL", "timestamp_start": started,
            "timestamp_end": ended, "exit_code": exit_code, "binary": str(binary),
            "compile_coverage_db": str(compile_db), "log_path": str(compile_log),
            "command": command_string(command),
        }
        write_json(manifest_path, manifest)
    for run in selected_runs:
        actual = record_by_id[run["id"]]["actual"]
        variant = run["build_variant"]
        if not build_ok.get(variant, False):
            actual.update({"status": "NOT_RUN", "reasons": [f"build {variant} failed"]})
            continue
        run_db = output_root / "runs" / f"{run['id']}.vdb"
        run_log = output_root / "logs" / f"{run['id']}.log"
        if run_db.exists():
            actual.update({
                "status": "FAIL",
                "reasons": ["preexisting_coverage_db_choose_new_C3_OUT"],
                "coverage_db": str(run_db),
                "coverage_db_present": coverage_db_present(run_db),
            })
            write_json(manifest_path, manifest)
            continue
        command = [
            str(binaries[variant]), f"+UVM_TESTNAME={run['test_name']}",
            f"+ntb_random_seed={run['seed']}", "+UVM_VERBOSITY=UVM_LOW",
            *run["plusargs"], "-cm", COVERAGE_TYPES, "-cm_dir", str(run_db),
            "-cm_name", run["id"], "-l", str(run_log),
        ]
        exit_code, started, ended = run_command(
            command, sim_dir, environment,
            output_root / "logs" / f"{run['id']}.console.log"
        )
        actual.update(evaluate_run(exit_code, run_log, run_db, run["expected_outcome"]))
        actual.update({
            "run_timestamp_start": started, "run_timestamp_end": ended,
            "exit_code": exit_code, "coverage_db": str(run_db),
            "command": command_string(command), "log_path": str(run_log),
        })
        write_json(manifest_path, manifest)
    selected_groups = sorted({run["merge_group"] for run in selected_runs})
    for group_name in selected_groups:
        group_runs = [run for run in selected_runs if run["merge_group"] == group_name]
        passing = [
            run for run in group_runs
            if record_by_id[run["id"]]["actual"]["status"] == "PASS"
        ]
        merge: dict[str, Any] = {
            "status": "NOT_RUN", "planned_run_count": len(group_runs),
            "included_run_count": len(passing),
            "excluded_runs": [run["id"] for run in group_runs if run not in passing],
            "compatibility_signature": compatibility_signature(plan, group_runs[0]),
        }
        if passing:
            report = output_root / "reports" / group_name
            merged_name = f"merged_{group_name}"
            merged_db = output_root / f"{merged_name}.vdb"
            run_dbs = [
                record_by_id[run["id"]]["actual"]["coverage_db"] for run in passing
            ]
            compile_db = manifest["builds"][group_runs[0]["build_variant"]][
                "compile_coverage_db"
            ]
            source_dbs = [compile_db, *run_dbs]
            command = [
                str(urg), "-full64", "-dir", *source_dbs, "-dbname",
                merged_name, "-report", str(report), "-format", "both",
            ]
            exit_code, started, ended = run_command(
                command, output_root, environment,
                output_root / "logs" / f"urg_{group_name}.console.log"
            )
            report_ok = (report / "dashboard.html").is_file() and (report / "session.xml").is_file()
            complete = len(passing) == len(group_runs)
            merge.update({
                "status": "PASS" if exit_code == 0 and report_ok and complete else (
                    "PARTIAL" if exit_code == 0 and report_ok else "FAIL"
                ),
                "timestamp_start": started, "timestamp_end": ended,
                "exit_code": exit_code, "compile_coverage_db": compile_db,
                "source_run_coverage_dbs": run_dbs,
                "source_coverage_dbs": source_dbs,
                "merged_coverage_db": str(merged_db),
                "report_path": str(report), "report_present": report_ok,
                "command": command_string(command),
                "report_metrics": parse_urg_report(report) if report_ok else {},
            })
            for run in group_runs:
                record_by_id[run["id"]]["actual"]["report_path"] = (
                    str(report) if report_ok else None
                )
        manifest["merge_results"][group_name] = merge
        write_json(manifest_path, manifest)
    run_statuses = [record_by_id[run["id"]]["actual"]["status"] for run in selected_runs]
    merge_statuses = [entry["status"] for entry in manifest["merge_results"].values()]
    manifest["generated_at"] = now_iso()
    manifest["overall_status"] = (
        "PASS" if run_statuses and all(value == "PASS" for value in run_statuses)
        and all(value == "PASS" for value in merge_statuses) else "FAIL"
    )
    write_json(manifest_path, manifest)
    write_overview(overview_path, manifest, plan)
    print(f"manifest: {manifest_path}")
    print(f"overview: {overview_path}")
    return 0 if manifest["overall_status"] == "PASS" else 1


def plan_only(plan_path: Path, output_path: Path) -> int:
    plan = read_plan(plan_path)
    errors, warnings = validate_plan(plan)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2
    manifest = make_manifest(
        plan_path, plan, {run["id"] for run in plan["runs"]}, warnings
    )
    write_json(output_path, manifest)
    print(f"planned manifest: {output_path}")
    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--plan", type=Path, required=True)
    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--plan", type=Path, required=True)
    plan_parser.add_argument("--output", type=Path, required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--plan", type=Path, required=True)
    run_parser.add_argument("--output-root", type=Path, required=True)
    run_parser.add_argument("--sets", default="all")
    args = parser.parse_args()
    if args.command == "validate":
        errors, warnings = validate_plan(read_plan(args.plan))
        for warning in warnings:
            print(f"WARNING: {warning}")
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 2 if errors else 0
    if args.command == "plan":
        return plan_only(args.plan, args.output)
    sets = {item.strip() for item in args.sets.split(",") if item.strip()}
    return execute(args.plan, args.output_root, sets)


if __name__ == "__main__":
    raise SystemExit(main())
