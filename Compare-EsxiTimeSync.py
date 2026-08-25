#!/usr/bin/env python3
"""Compare time synchronization configuration across ESXi hosts."""

from __future__ import annotations

import argparse
import csv
import getpass
import hashlib
import re
import ssl
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import paramiko
    from pyVim.connect import Disconnect, SmartConnect
    from pyVmomi import vim
except ImportError as error:
    raise SystemExit(
        f"Missing Python dependency: {error.name}. Install requirements with "
        "python -m pip install -r requirements.txt"
    ) from error


SCRIPT_ROOT = Path(__file__).resolve().parent
COMMANDS = {
    "Host Date": "date",
    "Host Information": "esxcli system hostname get",
    "IPv4 Addressing": "esxcli network ip interface ipv4 get",
    "NTP Config File": "cat /etc/ntp.conf",
    "NTP Service Settings": "esxcli system ntp get",
    "NTP Peers": "ntpq -p",
    "NTP Peers Numeric": "ntpq -pn",
    "Firewall NTP Rules": "esxcli network firewall ruleset list | grep -i ntp",
    "BIOS / Platform": "esxcli hardware platform get",
    "Hardware Clock": "esxcli hardware clock get",
    "Chrony Config File": "cat /etc/chrony.conf",
    "Chrony Tracking": "chronyc tracking",
    "Chrony Sources": "chronyc sources",
}
RESTART_NTP_COMMANDS = {
    "Restart NTP - Disable": "esxcli system ntp set -e 0",
    "Restart NTP - Enable": "esxcli system ntp set -e 1",
    "Restart NTP - Verify": "esxcli system ntp get",
}
COMPARISON_FIELDS = (
    "NtpEnabled",
    "NtpServers",
    "NtpConfigHash",
    "NtpPeersHash",
    "NtpPeersNumericHash",
    "FirewallNtpHash",
    "BIOSVersion",
    "HardwareClock",
    "ChronyDetected",
    "ChronyConfigHash",
    "ChronyTrackingHash",
    "ChronySourcesHash",
)


@dataclass(frozen=True)
class CommandResult:
    label: str
    command: str
    output: str
    exit_status: int
    success: bool


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect and compare ESXi NTP and Chrony configuration."
    )
    input_group = parser.add_mutually_exclusive_group()
    input_group.add_argument(
        "--host-file",
        type=Path,
        help="Optional manual ESXi host list. One hostname or IP address per line.",
    )
    input_group.add_argument(
        "--cluster-input-file",
        type=Path,
        default=SCRIPT_ROOT / "clusternames.txt",
        help="Cluster and vCenter input file (default: clusternames.txt).",
    )
    parser.add_argument("--cluster-name", help="vSphere cluster name.")
    parser.add_argument("--vcenter-server", help="vCenter DNS name or IP address.")
    parser.add_argument(
        "--output-root",
        type=Path,
        default=SCRIPT_ROOT / "Results",
        help="Directory for timestamped reports (default: Results).",
    )
    parser.add_argument("--ssh-username", default="root", help="ESXi SSH username (default: root).")
    parser.add_argument("--vcenter-username", help="vCenter username; prompted when needed.")
    parser.add_argument(
        "--verify-vcenter-certificate",
        action="store_true",
        help="Verify the vCenter TLS certificate instead of accepting self-signed certificates.",
    )
    parser.add_argument(
        "--restart-ntp",
        action="store_true",
        help="Disable then enable the ESXi NTP service after collection.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Confirm a requested NTP restart without an interactive prompt.",
    )
    arguments = parser.parse_args()
    if arguments.restart_ntp and not arguments.yes:
        parser.error("--restart-ntp requires --yes to confirm the configuration change.")
    return arguments


def read_non_comment_lines(path: Path) -> list[str]:
    if not path.is_file():
        raise FileNotFoundError(f"Input file not found: {path}")
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def read_cluster_inputs(path: Path) -> tuple[str | None, str | None]:
    cluster_name: str | None = None
    vcenter_server: str | None = None
    lines = read_non_comment_lines(path)
    for line in lines:
        match = re.fullmatch(r"\s*([^:=]+?)\s*[:=]\s*(.+?)\s*", line)
        if not match:
            continue
        key = match.group(1).strip().lower()
        value = match.group(2).strip()
        if key in {"cluster", "clustername"}:
            cluster_name = value
        elif key in {"vcenter", "vcenterserver", "server", "vcenterip", "vcenteraddress", "ip"}:
            vcenter_server = value
    if cluster_name is None and lines:
        cluster_name = lines[0]
    if vcenter_server is None and len(lines) > 1:
        vcenter_server = lines[1]
    return cluster_name, vcenter_server


def unique_hosts(lines: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(lines))


def discover_cluster_hosts(
    cluster_name: str, vcenter_server: str, username: str, password: str, verify_certificate: bool
) -> list[str]:
    ssl_context = ssl.create_default_context() if verify_certificate else ssl._create_unverified_context()
    service_instance = SmartConnect(
        host=vcenter_server,
        user=username,
        pwd=password,
        sslContext=ssl_context,
    )
    try:
        content = service_instance.RetrieveContent()
        container_view = content.viewManager.CreateContainerView(
            content.rootFolder, [vim.ClusterComputeResource], True
        )
        try:
            cluster = next((item for item in container_view.view if item.name == cluster_name), None)
        finally:
            container_view.Destroy()
        if cluster is None:
            raise RuntimeError(f"vSphere cluster not found: {cluster_name}")
        return sorted(host.name for host in cluster.host)
    finally:
        Disconnect(service_instance)


def resolve_target_hosts(arguments: argparse.Namespace) -> list[str]:
    if arguments.host_file is not None:
        return unique_hosts(read_non_comment_lines(arguments.host_file))

    file_cluster_name, file_vcenter_server = read_cluster_inputs(arguments.cluster_input_file)
    cluster_name = arguments.cluster_name or file_cluster_name
    vcenter_server = arguments.vcenter_server or file_vcenter_server
    if not cluster_name:
        raise RuntimeError("Cluster mode requires --cluster-name or a ClusterName in clusternames.txt.")
    if not vcenter_server:
        raise RuntimeError("Cluster mode requires --vcenter-server or a vCenterServer in clusternames.txt.")

    username = arguments.vcenter_username or input(f"vCenter username for {vcenter_server}: ")
    password = getpass.getpass(f"vCenter password for {username}: ")
    return discover_cluster_hosts(
        cluster_name, vcenter_server, username, password, arguments.verify_vcenter_certificate
    )


def run_ssh_command(client: paramiko.SSHClient, label: str, command: str) -> CommandResult:
    try:
        stdin, stdout, stderr = client.exec_command(command)
        del stdin
        output = stdout.read().decode("utf-8", errors="replace")
        error_output = stderr.read().decode("utf-8", errors="replace")
        exit_status = stdout.channel.recv_exit_status()
        combined_output = output if output.strip() or not error_output.strip() else error_output
        return CommandResult(label, command, combined_output.rstrip(), exit_status, exit_status == 0)
    except Exception as error:
        return CommandResult(label, command, str(error), -1, False)


def collect_host(host_name: str, username: str, password: str) -> dict[str, CommandResult]:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=host_name,
            username=username,
            password=password,
            timeout=20,
            banner_timeout=20,
            auth_timeout=20,
            look_for_keys=False,
            allow_agent=False,
        )
        return {label: run_ssh_command(client, label, command) for label, command in COMMANDS.items()}
    finally:
        client.close()


def write_host_report(path: Path, host_name: str, results: Mapping[str, CommandResult]) -> None:
    lines = [
        "ESXi Time Sync Report",
        f"Host: {host_name}",
        f"Collected: {datetime.now(timezone.utc).isoformat()}",
        "",
    ]
    for result in results.values():
        lines.extend(
            [
                "==============================",
                result.label,
                "==============================",
                f"Command: {result.command}",
                f"ExitStatus: {result.exit_status}",
                "--- Output ---",
                result.output if result.output.strip() else "<empty>",
                "",
            ]
        )
    path.write_text("\n".join(lines), encoding="utf-8")


def parse_key_value_text(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        match = re.fullmatch(r"\s*([^:]+?)\s*:\s*(.+?)\s*", line)
        if match:
            values.setdefault(match.group(1).strip(), match.group(2).strip())
    return values


def get_field(values: Mapping[str, str], candidates: Iterable[str]) -> str | None:
    candidate_list = list(candidates)
    for candidate in candidate_list:
        for key, value in values.items():
            if key.casefold() == candidate.casefold():
                return value
    for candidate in candidate_list:
        for key, value in values.items():
            if candidate.casefold() in key.casefold():
                return value
    return None


def single_line_text(text: str, max_length: int = 180) -> str:
    value = re.sub(r"\s+", " ", text).strip()
    if not value:
        return "<empty>"
    return value if len(value) <= max_length else f"{value[: max_length - 3]}..."


def text_hash(text: str) -> str:
    normalized = text.replace("\r\n", "\n").strip()
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest().upper()


def safe_file_name(value: str) -> str:
    return re.sub(r'[<>:"/\\|?*]', "_", value)


def summarize_host(host_name: str, report_path: Path, results: Mapping[str, CommandResult]) -> dict[str, str]:
    ntp_settings = parse_key_value_text(results["NTP Service Settings"].output)
    platform_settings = parse_key_value_text(results["BIOS / Platform"].output)
    clock_settings = parse_key_value_text(results["Hardware Clock"].output)
    host_info = parse_key_value_text(results["Host Information"].output)
    hardware_clock = get_field(clock_settings, ("Hardware Clock",))
    chrony_config = results["Chrony Config File"].output
    chrony_tracking = results["Chrony Tracking"].output
    chrony_sources = results["Chrony Sources"].output
    unavailable = ("not found", "not available", "failed")
    chrony_detected = (
        "chrony" in chrony_config.casefold()
        or not any(value in chrony_tracking.casefold() for value in unavailable)
        or not any(value in chrony_sources.casefold() for value in unavailable)
    )
    return {
        "HostName": host_name,
        "Date": single_line_text(results["Host Date"].output, 80),
        "ReportedHostName": get_field(host_info, ("Host Name", "Fully Qualified Domain Name")) or "<not reported>",
        "IPv4Summary": single_line_text(results["IPv4 Addressing"].output),
        "NtpEnabled": get_field(ntp_settings, ("Enabled", "NTP Client Enabled", "NTP daemon enabled")) or "<not reported>",
        "NtpServers": get_field(ntp_settings, ("NTP Servers", "Servers", "Server")) or "<not reported>",
        "NtpConfigHash": text_hash(results["NTP Config File"].output),
        "NtpPeersHash": text_hash(results["NTP Peers"].output),
        "NtpPeersNumericHash": text_hash(results["NTP Peers Numeric"].output),
        "FirewallNtpHash": text_hash(results["Firewall NTP Rules"].output),
        "BIOSVersion": get_field(platform_settings, ("BIOS Version",)) or "<not reported>",
        "HardwareClock": hardware_clock or single_line_text(results["Hardware Clock"].output),
        "ChronyDetected": "Yes" if chrony_detected else "No",
        "ChronyConfigHash": text_hash(chrony_config),
        "ChronyTrackingHash": text_hash(chrony_tracking),
        "ChronySourcesHash": text_hash(chrony_sources),
        "ReportPath": str(report_path),
    }


def write_comparison_csv(path: Path, summaries: list[dict[str, str]]) -> None:
    if not summaries:
        return
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)


def print_summary(summaries: list[dict[str, str]]) -> None:
    print("\n============================== ESXi TIME SYNC COMPARISON ==============================")
    fields = ("HostName", "Date", "NtpEnabled", "NtpServers", "ChronyDetected", "BIOSVersion", "HardwareClock")
    for summary in summaries:
        print(" | ".join(f"{field}={summary[field]}" for field in fields))

    differences = []
    for field in COMPARISON_FIELDS:
        values = list(dict.fromkeys(summary[field] for summary in summaries))
        if len(values) > 1:
            differences.append((field, " | ".join(values)))
    print("\n============================== DIFFERENCES ==========================================")
    if differences:
        for field, values in differences:
            print(f"{field}: {values}")
    else:
        print("No differences were detected in the summarized fields.")


def restart_ntp(client: paramiko.SSHClient, host_folder: Path, host_name: str) -> None:
    results = {
        label: run_ssh_command(client, label, command)
        for label, command in RESTART_NTP_COMMANDS.items()
    }
    write_host_report(host_folder / "restart-ntp.txt", host_name, results)


def main() -> int:
    arguments = parse_arguments()
    try:
        target_hosts = resolve_target_hosts(arguments)
    except Exception as error:
        print(f"Unable to resolve ESXi hosts: {error}", file=sys.stderr)
        return 1
    if not target_hosts:
        print("No ESXi hosts were resolved from the selected input source.", file=sys.stderr)
        return 1

    ssh_password = getpass.getpass(f"ESXi SSH password for {arguments.ssh_username}: ")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_root = arguments.output_root / timestamp
    raw_root = run_root / "Raw"
    raw_root.mkdir(parents=True, exist_ok=True)
    summaries: list[dict[str, str]] = []
    failed_hosts: list[str] = []

    for host_name in target_hosts:
        print(f"Querying {host_name} ...")
        host_folder = raw_root / safe_file_name(host_name)
        host_folder.mkdir(parents=True, exist_ok=True)
        try:
            results = collect_host(host_name, arguments.ssh_username, ssh_password)
            report_path = host_folder / "esxi-time-sync-report.txt"
            write_host_report(report_path, host_name, results)
            summaries.append(summarize_host(host_name, report_path, results))
            if arguments.restart_ntp:
                client = paramiko.SSHClient()
                client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                try:
                    client.connect(host_name, username=arguments.ssh_username, password=ssh_password, timeout=20)
                    restart_ntp(client, host_folder, host_name)
                finally:
                    client.close()
        except Exception as error:
            failed_hosts.append(host_name)
            print(f"Warning: failed to query {host_name}: {error}", file=sys.stderr)

    comparison_path = run_root / "esxi_time_sync_comparison.csv"
    write_comparison_csv(comparison_path, summaries)
    print_summary(summaries)
    print(f"\nPer-host reports saved under: {raw_root}")
    print(f"Comparison CSV saved to: {comparison_path}")
    if failed_hosts:
        print("Warning: one or more hosts could not be queried: " + ", ".join(failed_hosts), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())