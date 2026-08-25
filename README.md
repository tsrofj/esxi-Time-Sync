# ESXi Time Sync

This project contains scripts and configuration for validating ESXi time synchronization.

## Purpose

Track scripts, notes, and configuration related to ESXi time sync and NTP/Chrony validation across ESXi hosts.

## Contents

- [Compare-EsxiTimeSync.ps1](Compare-EsxiTimeSync.ps1)
- [Compare-EsxiTimeSync.py](Compare-EsxiTimeSync.py)
- [requirements.txt](requirements.txt)

## Requirements

- Windows PowerShell 5.1 or later
- Posh-SSH for SSH connections to ESXi hosts
- VMware PowerCLI if you want to discover hosts from a vSphere cluster
- SSH access to each ESXi host, typically with the `root` account
- Python 3.9 or later with the packages in `requirements.txt` for the Python implementation

## What the script collects

The script gathers the following from each ESXi host:

- Host date and host identity
- IPv4 interface information
- `cat /etc/ntp.conf`
- `esxcli system ntp get`
- `ntpq -p`
- `ntpq -pn`
- `esxcli network firewall ruleset list | grep -i ntp`
- `esxcli hardware platform get`
- `esxcli hardware clock get`
- `cat /etc/chrony.conf`
- `chronyc tracking`
- `chronyc sources`

`watch ntpq -pn` is intentionally omitted because it is interactive and not suitable for unattended collection.

## How to use

### Python implementation

Install the required packages, then run the Python 3 version. It uses `clusternames.txt` by default and prompts for vCenter and ESXi SSH credentials.

```powershell
python -m pip install -r .\requirements.txt
python .\Compare-EsxiTimeSync.py
```

Use the optional manual host list or provide cluster values directly:

```powershell
python .\Compare-EsxiTimeSync.py --host-file .\hosts.txt
python .\Compare-EsxiTimeSync.py --cluster-name 'Production Cluster' --vcenter-server vcsa01.domain.local
```

The Python version accepts self-signed vCenter certificates by default. Add `--verify-vcenter-certificate` to require a trusted certificate. To restart NTP after collection, provide both `--restart-ntp` and `--yes`.

### Query the cluster in clusternames.txt (default)

```powershell
.\Compare-EsxiTimeSync.ps1
```

Create `clusternames.txt` in the same folder as the script:

```text
ClusterName: Production Cluster
vCenterServer: 192.0.2.10
```

`vCenterServer` accepts either a DNS name or IP address. You can also use `vCenterIp` or `vCenterAddress` as the key. Blank lines and lines starting with `#` are ignored.

### Query hosts from a text file

`hosts.txt` is an optional manual target list. Use it to bypass vCenter cluster discovery when PowerCLI or vCenter is unavailable, or when you need to audit a specific subset of ESXi hosts.

```powershell
.\Compare-EsxiTimeSync.ps1 -HostFile .\hosts.txt
```

Create `hosts.txt`, with one ESXi host DNS name or IP address per line:

```text
esx01.domain.local
esx02.domain.local
```

### Query a vSphere cluster

```powershell
Connect-VIServer vcsa01.domain.local
.\Compare-EsxiTimeSync.ps1 -ClusterName 'Production Cluster' -vCenterServer vcsa01.domain.local
```

### Query a vSphere cluster from a text file

Create a file such as `clusternames.txt`:

```text
ClusterName: Production Cluster
vCenterServer: vcsa01.domain.local
```

Then run:

```powershell
.\Compare-EsxiTimeSync.ps1 -ClusterInputFile .\clusternames.txt
```

You can also provide one value via command line and the other via file:

```powershell
.\Compare-EsxiTimeSync.ps1 -ClusterName 'Production Cluster' -ClusterInputFile .\clusternames.txt
```

## Output

Each run creates a timestamped folder under `Results/` with:

- A per-host raw report in `Raw/<host>/esxi-time-sync-report.txt`
- A comparison CSV named `esxi_time_sync_comparison.csv`

## Optional action

Use the `-RestartNtp` switch if you want the script to toggle the ESXi NTP service off and back on after the audit completes.

## Status

Initial script scaffold created.
