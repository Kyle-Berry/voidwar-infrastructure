# Enterprise-Grade Linux Infrastructure & Networking Lab
## Dedicated Production Environment | Bare-Metal Systems Administration & Perimeter Hardening

This repository serves as the official version-controlled documentation, configuration ledger, and automation script vault for my dedicated, remote Linux production environment hosted on the global OVHcloud backbone network. 

The primary objective of this infrastructure architecture is to apply foundational Computer Science theory and vendor-neutral networking protocols to a live, high-concurrency production sandbox, prioritizing cost optimization (FinOps), cryptographic access controls, and strict perimeter defense.

---

## 1. Physical Hardware & Storage Infrastructure Layer (FinOps Architecture)
To mitigate public cloud resource throttling and eliminate the "noisy neighbor" effect inherent in shared virtual instances, the environment is provisioned on a dedicated, bare-metal host optimized for high-throughput and low-latency I/O operations:

* **Compute Engine:** Intel Xeon-E3 1230v6 (4 Cores / 8 Threads, clocked at 3.5 GHz base / 3.9 GHz turbo boost).
* **Memory Pool:** 16 GB ECC (Error-Correcting Code) RAM operating at 2133 MHz, ensuring native runtime resilience against single-bit memory corruption during sustained processing loads.
* **Storage Topology:** Dual 450 GB Enterprise NVMe Solid-State Drives configured via software utilities into a **RAID 0 (Stripped) Array**. This layout doubles data-striping velocity across parallel PCIe communication lanes, maximizing Input/Output Operations Per Second (IOPS) to support heavy asynchronous disk-write application cycles.
* **Capital Efficiency (FinOps Evaluation):** Implemented an "N-2" hardware procurement strategy, securing dedicated enterprise silicon and bare-metal processing lanes for a 75% reduction in monthly infrastructure overhead compared to standard public cloud offerings.

---

## 2. Perimeter Hardening & Network Access Security
The edge perimeter of the Ubuntu Server 22.04 LTS (Jammy Jellyfish) deployment is hardened against external attack vectors using automated intrusion prevention protocols and a minimalist surface architecture:

* **Cryptographic Authentication Gate:** Enforced mandatory public-key cryptography for all remote administrative access tunnels via PuTTY and WinSCP interfaces. The environment utilizes highly resilient **Ed25519 signature keys** (Twisted Edwards curves), offering optimal security metrics over legacy RSA protocols. Core administrative root SSH logins are completely closed.
* **Attack Surface Optimization:** Deployed localized firewall rules configured via Netfilter/UFW frameworks to drop all unauthorized transport layer traffic, mapping strictly to essential application ports. Disabled all native IPv6 stack protocols to permanently eliminate unmonitored dual-stack network scanning surfaces.
* **Intrusion Prevention System (IPS):** Implemented **Fail2Ban** to actively parse system authorization logs (`/var/log/auth.log`) in real time. The service tracks authentication anomalies and automatically executes dynamic local firewall rules to temporarily jail and drop malicious brute-force source IPs at the packet level.

---

## 3. Multi-Tenant Administration & Least Privilege Protocols
The underlying file system structures are designed to support collaborative deployment pipelines while maintaining total environment integrity:

* **Directory Isolation Jails:** Established a multi-user permission matrix enforcing the **Principle of Least Privilege**. Collaborative developers operate under dedicated, non-privileged user accounts.
* **Symbolic Link Access Control:** Utilized explicit symbolic links (`sym-links`) to bridge access to designated shared development workspaces. This prevents external users from mapping out parent directories, modifying system-level configurations, or traversing unvetted paths on the file system.
* **Session Multiplexing and Uptime:** Integrated `tmux` (Terminal Multiplexer) to manage continuous application runtime consoles. This decouples live process execution from active remote SSH network socket states, ensuring persistent application loops continue to compile smoothly within the kernel regardless of local machine connectivity.

---

## 4. Production Roadmap & Continuous Integration
This repository maintains a live log of all automation assets and maintenance workflows running on the host server:
* `/scripts` - Production Bash shell scripts for automated backup tarball generation and system optimization routines.
* `/config` - Hardened configuration templates for SSH, UFW, and Fail2Ban perimeters.
