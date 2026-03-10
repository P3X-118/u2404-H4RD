#!/usr/bin/env python3
"""
Script to generate STIG audit visualization from molecule test results.
Run this after 'molecule test' to update README with latest audit results.
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

RESULTS_DIR = Path("molecule/results")
README_PATH = Path("README.md")


def parse_goss_json(json_path: Path) -> dict:
    """Parse Goss JSON audit file and extract summary."""
    with open(json_path) as f:
        data = json.load(f)
    
    summary = data.get("goss", {}).get("summary", {})
    return {
        "total": summary.get("total-count", 0),
        "passed": summary.get("passed-count", 0),
        "failed": summary.get("failed-count", 0),
        "skipped": summary.get("skipped-count", 0),
        "duration": summary.get("duration", 0),
    }


def generate_badge(passed: int, failed: int, total: int) -> str:
    """Generate SVG badge for pass rate."""
    pass_rate = round((passed / total * 100), 1) if total > 0 else 0
    
    if failed == 0:
        color = "brightgreen"
        status = "PASSING"
    elif failed < 10:
        color = "yellow"
        status = "PARTIAL"
    else:
        color = "red"
        status = "FAILING"
    
    badge = f"![STIG Compliance](https://img.shields.io/badge/STIG-{pass_rate}%25-{color}?style=flat&logo=lock&logoColor=white)"
    return badge


def generate_ascii_chart(stats: dict) -> str:
    """Generate ASCII bar chart."""
    total = stats["total"]
    passed = stats["passed"]
    failed = stats["failed"]
    skipped = stats["skipped"]
    
    bar_width = 40
    passed_width = int((passed / total * bar_width)) if total > 0 else 0
    failed_width = int((failed / total * bar_width)) if total > 0 else 0
    skipped_width = bar_width - passed_width - failed_width
    
    chart = f"""
```
┌────────────────────────────────────────────────────────────────────┐
│                    STIG COMPLIANCE REPORT                          │
├────────────────────────────────────────────────────────────────────┤
│  PASSED  [{'#' * passed_width}{' ' * (bar_width - passed_width)}] {passed:>4} │
│  FAILED  [{'!' * failed_width}{' ' * (bar_width - failed_width)}] {failed:>4} │
│  SKIPPED [{'~' * skipped_width}{' ' * (bar_width - skipped_width)}] {skipped:>4} │
├────────────────────────────────────────────────────────────────────┤
│  TOTAL: {total:>4}  |  PASS RATE: {round((passed/total*100), 1) if total > 0 else 0:>5.1f}%  |  Duration: {stats['duration']:.3f}s │
└────────────────────────────────────────────────────────────────────┘
```
"""
    return chart


def update_readme(stats: dict, audit_file: Path):
    """Update README with audit results."""
    if not README_PATH.exists():
        print("README.md not found, skipping update")
        return
    
    with open(README_PATH) as f:
        readme_content = f.read()
    
    # Find the audit results section
    badge = generate_badge(stats["passed"], stats["failed"], stats["total"])
    chart = generate_ascii_chart(stats)
    
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    results_section = f"""
---

## Molecule Test Results

{badge}

**Test Date:** {timestamp}

{chart}

**Detailed Results:** [Audit Report]({audit_file.name})

*This report is generated automatically after running `molecule test`.*
"""
    
    # Check if results section already exists
    if "## Molecule Test Results" in readme_content:
        # Replace existing section
        pattern = r"\n---\n\n## Molecule Test Results\n.*?(?=\n---|\n## |\Z)"
        readme_content = re.sub(pattern, f"\n---\n{results_section}\n", readme_content, flags=re.DOTALL)
    else:
        # Append at end
        readme_content += f"\n\n---\n{results_section}\n"
    
    with open(README_PATH, "w") as f:
        f.write(readme_content)
    
    print(f"README.md updated successfully")


def main():
    # Find latest audit file
    if not RESULTS_DIR.exists():
        print(f"Results directory {RESULTS_DIR} not found")
        print("Run 'molecule test' first to generate audit results")
        # Don't exit with error in CI - just skip
        return
    
    # Find latest JSON file
    json_files = sorted(RESULTS_DIR.glob("*-UBUNTU24-STIG-post_scan_*.json"))
    if not json_files:
        print("No audit results found in molecule/results/")
        print("Run 'molecule test' first to generate audit results")
        sys.exit(1)
    
    latest_file = json_files[-1]
    print(f"Processing: {latest_file}")
    
    # Parse and display results
    stats = parse_goss_json(latest_file)
    print(f"\nAudit Summary:")
    print(f"  Total:   {stats['total']}")
    print(f"  Passed:  {stats['passed']}")
    print(f"  Failed:  {stats['failed']}")
    print(f"  Skipped: {stats['skipped']}")
    print(f"  Duration: {stats['duration']:.3f}s")
    
    # Generate and display chart
    print(generate_ascii_chart(stats))
    
    # Update README
    update_readme(stats, latest_file)
    
    print(f"\nFull report: {latest_file}")


if __name__ == "__main__":
    main()
