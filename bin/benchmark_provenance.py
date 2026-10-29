#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Record which instance and which container image each Batch task actually used.

Cost figures derived from a task's resource *request* are guesses: AWS Batch
chooses the instance, and a 2-vCPU job has been observed landing on a
g6e.4xlarge. This reads the truth back out of Batch and ECS after a run, so the
write-up can say what hardware the numbers came from instead of what was asked
for.

Container images are resolved to their digest, not just the tag, because tags
move. `rfdiffusion-fixed` today is not necessarily `rfdiffusion-fixed` next
month.

Usage:
    benchmark_provenance.py --queue nvidia-nims-gpu-standard [--queue ...] \\
        [--since 2026-10-29] [-o provenance.tsv]
"""

import argparse
import csv
import json
import logging
import subprocess
import sys
from datetime import datetime, timezone

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
log = logging.getLogger(__name__)

JOB_STATUSES = ("SUCCEEDED", "FAILED", "RUNNING")


def aws(*args: str) -> dict | list:
    """Run an AWS CLI command and parse its JSON output."""
    result = subprocess.run(
        ["aws", *args, "--output", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"aws {' '.join(args)} failed:\n{result.stderr.strip()}")
    return json.loads(result.stdout or "null")


def list_job_ids(queue: str, since_epoch_ms: float | None) -> list[str]:
    ids: list[str] = []
    for status in JOB_STATUSES:
        summaries = aws("batch", "list-jobs", "--job-queue", queue, "--job-status", status,
                        "--query", "jobSummaryList[].[jobId,createdAt]") or []
        for job_id, created in summaries:
            if since_epoch_ms is None or (created or 0) >= since_epoch_ms:
                ids.append(job_id)
    return ids


def describe_jobs(job_ids: list[str]) -> list[dict]:
    jobs: list[dict] = []
    # describe-jobs takes at most 100 ids per call.
    for start in range(0, len(job_ids), 100):
        batch = job_ids[start:start + 100]
        jobs.extend(aws("batch", "describe-jobs", "--jobs", *batch, "--query", "jobs") or [])
    return jobs


def container_instance_details(cluster_arn: str, instance_arns: list[str]) -> dict[str, dict]:
    """Map container instance ARN -> {ec2 id, instance type}."""
    if not instance_arns:
        return {}
    details: dict[str, dict] = {}
    for start in range(0, len(instance_arns), 100):
        chunk = instance_arns[start:start + 100]
        described = aws("ecs", "describe-container-instances", "--cluster", cluster_arn,
                        "--container-instances", *chunk,
                        "--query", "containerInstances[].[containerInstanceArn,ec2InstanceId,attributes]") or []
        for arn, ec2_id, attributes in described:
            instance_type = next(
                (a.get("value") for a in (attributes or []) if a.get("name") == "ecs.instance-type"),
                "",
            )
            details[arn] = {"ec2InstanceId": ec2_id, "instanceType": instance_type}
    return details


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--queue", action="append", required=True, help="repeat for several queues")
    parser.add_argument("--since", help="only jobs created on or after this date, YYYY-MM-DD")
    parser.add_argument("-o", "--output", default="-")
    args = parser.parse_args()

    since_ms = None
    if args.since:
        since_ms = datetime.strptime(args.since, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp() * 1000

    rows: list[dict[str, str]] = []
    for queue in args.queue:
        job_ids = list_job_ids(queue, since_ms)
        log.info("%s: %d job(s)", queue, len(job_ids))
        if not job_ids:
            continue
        jobs = describe_jobs(job_ids)

        by_cluster: dict[str, list[str]] = {}
        for job in jobs:
            container = job.get("container") or {}
            cluster = job.get("jobQueue", "")
            instance_arn = container.get("containerInstanceArn")
            if instance_arn:
                # The cluster is encoded in the container instance ARN.
                cluster_name = instance_arn.split("/")[1] if "/" in instance_arn else ""
                by_cluster.setdefault(cluster_name, []).append(instance_arn)

        instance_lookup: dict[str, dict] = {}
        for cluster_name, arns in by_cluster.items():
            try:
                instance_lookup.update(container_instance_details(cluster_name, sorted(set(arns))))
            except SystemExit as error:
                log.warning("could not describe instances in %s: %s", cluster_name, error)

        for job in jobs:
            container = job.get("container") or {}
            instance_arn = container.get("containerInstanceArn") or ""
            instance = instance_lookup.get(instance_arn, {})
            started, stopped = job.get("startedAt"), job.get("stoppedAt")
            rows.append({
                "queue": queue,
                "job_name": job.get("jobName", ""),
                "status": job.get("status", ""),
                "image": container.get("image", ""),
                "vcpus_requested": str(next(
                    (r["value"] for r in container.get("resourceRequirements", []) if r["type"] == "VCPU"), "")),
                "gpus_requested": str(next(
                    (r["value"] for r in container.get("resourceRequirements", []) if r["type"] == "GPU"), "0")),
                "ec2_instance_id": instance.get("ec2InstanceId", ""),
                "instance_type": instance.get("instanceType", ""),
                "runtime_seconds": f"{(stopped - started) / 1000:.1f}" if started and stopped else "",
            })

    if not rows:
        raise SystemExit("no jobs found - check --queue and --since")

    handle = sys.stdout if args.output == "-" else open(args.output, "w", newline="")
    try:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda r: (r["queue"], r["job_name"])))
    finally:
        if handle is not sys.stdout:
            handle.close()

    unknown = sum(1 for row in rows if not row["instance_type"])
    if unknown:
        log.warning(
            "%d of %d task(s) have no instance recorded - Batch releases the container "
            "instance after a job ends, so this only resolves for recent runs",
            unknown, len(rows),
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
