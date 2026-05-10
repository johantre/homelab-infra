# Disaster Recovery — NanoPi R6S Router

## Scenarios

| Scenario | Situatie | Aanpak |
|----------|----------|--------|
| **A** | Config update / routine deploy | GitHub Actions workflow_dispatch |
| **B** | eMMC corrupt of NanoPi kapot | SD card procedure → eMMC → deploy |

---

## Scenario A: Re-deploy (routine)

De runner draait op de NanoPi zelf en verbindt outbound naar GitHub. Geen extra stappen nodig.

1. Ga naar GitHub → `homelab-infra` → Actions → **Deploy NanoPi Router**
2. Klik **Run workflow** → environment: `prod`
3. Verificatiestap toont PASS/FAIL per check — verwacht: 12/13 groen (Modbus FAIL = normaal, geen carrier)

---

## Scenario B: Volledige herbouw (eMMC corrupt of nieuw hardware)

### Kritische opmerking

Na de cutover is de NanoPi de enige router. Als hij faalt, heeft het thuisnetwerk **geen internet**.
De herbouw vereist internet (Armbian download, runner registratie).

**Oplossing tijdens herbouw:** laptop rechtstreeks op modem aansluiten via ethernet voor tijdelijk internet.

### Wat je nodig hebt

- [ ] SD kaartje (8 GB+)
- [ ] SD kaartlezer aangesloten op de Linux laptop
- [ ] Internet (via modem direct of mobiel hotspot)
- [ ] GitHub toegang (voor runner registratie)
- [ ] SD kaart procedure draait op: `johan-Kaisa` (de Linux laptop)

### Stap 1 — SD kaart aanmaken

```bash
cd ~/homelab/infra/boot
./create-install-usb.sh
# Kies optie: NanoPi R6S
```

Het script:
- Download automatisch de laatste Armbian image (cached na eerste keer)
- Injecteert firstboot config (user, SSH key, timezone, keyboard)
- Schrijft naar SD kaart
- De firstboot service installeert automatisch naar eMMC bij eerste boot

### Stap 2 — Booten en installeren

1. SD kaart in NanoPi R6S
2. NanoPi opstarten — firstboot service draait automatisch:
   - `armbian-install` kopieert SD → eMMC
   - NanoPi herstart van eMMC
   - `setup-machine.sh` registreert GitHub Actions runner
3. Wacht tot runner online is in GitHub → Settings → Actions → Runners → `nanopirouter`

### Stap 3 — Deploy triggeren

Zelfde als Scenario A: GitHub Actions → **Deploy NanoPi Router** → Run workflow.

Ansible configureert het volledige systeem: netwerk, firewall, DHCP, DNS, WireGuard.

---

## Productie Cutover Procedure

**Wanneer:** eenmalig, om de NanoPi de officiële router te maken.
**Downtime:** ~3-5 minuten (kabels herschikken + Ansible deploy tijd).

### Voorbereiding (vóór de cutover)

- [ ] Laatste deploy gedraaid en 12/13 checks groen
- [ ] PC op lan1 getest: DHCP ✓, DNS ✓, internet ✓, PiHole blokkeert ads ✓
- [ ] Orbi admin interface open op laptop: `http://192.168.3.1` → Advanced → Router/AP Mode

### Cutoverstappen

| # | Actie | Opmerking |
|---|-------|-----------|
| 1 | Kabel: modem → NanoPi WAN poort | Modem los van Orbi |
| 2 | Kabel: NanoPi LAN1 → Orbi (eender welke poort) | Bestaande kabel hergebruiken |
| 3 | Orbi admin: schakel naar **AP Mode** → Apply | Orbi DHCP stopt |
| 4 | GitHub Actions → **Deploy NanoPi Router** → Run workflow | NanoPi wordt 192.168.3.1 |
| 5 | Wacht op groene verificatiestap in GitHub Actions | ~2-3 minuten |
| 6 | Devices herverbinden WiFi of DHCP vernieuwen | Krijgen IP van NanoPi |

### Verificatie na cutover

Verwacht resultaat in GitHub Actions verificatiestap:

```
✅  LAN interface has IP (lan1)        → 192.168.3.1
❌  Modbus interface has IP (lan2)     → verwacht (geen carrier)
✅  Default route via WAN present
✅  Internet reachable (HTTP)
✅  nftables service active
✅  NAT postrouting rules present
✅  SSH allowed in input chain
✅  dnsmasq service active
✅  dnsmasq listening on DNS  (:53)
✅  dnsmasq listening on DHCP (:67)
✅  DNS resolves via PiHole
✅  WireGuard interface active
✅  WireGuard route present (wg0)
Verification: 12 passed, 1 failed
```

### Na de cutover: modem port forwarding bijwerken

Het modem stuurt poort 1194 (OpenVPN) door naar het Orbi WAN IP (192.168.0.174).
Na de cutover krijgt de NanoPi een IP op het modem-subnet (192.168.0.x).
Dat nieuwe IP moet je instellen in de Telenet modem port forwarding.

1. SSH naar NanoPi: `ssh ubuntu@192.168.3.1`
2. Controleer WAN IP op modem-subnet: `ip addr show wan`
3. Telenet modem → Port forwarding: pas lokaal IP aan naar NanoPi WAN IP
4. Zet de port forwarding toggle op **aan**

---

## Vaste IP-adressen

| Device | IP | MAC |
|--------|----|-----|
| NanoPi (gateway) | 192.168.3.1 | — |
| Orbi hoofd | 192.168.3.2 | 34:98:b5:43:8a:2f |
| Orbi Laundry | 192.168.3.3 | 34:98:b5:46:33:4d |
| Orbi Bedroom | 192.168.3.4 | 6c:cd:d6:29:b9:ce |
| Orbi Kitchen | 192.168.3.5 | 34:98:b5:46:33:a9 |
| HomeAssistant | 192.168.3.8 | e4:5f:01:ac:4a:71 |
| PiHole | 192.168.3.11 | e4:5f:01:ac:4a:94 |
| NAS | 192.168.3.38 | 00:11:32:98:1b:51 |
| windows-laptop | 192.168.3.28 | a8:3b:76:e6:d8:65 |
| hw-p1meter | 192.168.3.27 | 5c:2f:af:35:d7:5e |
| omvormer-wifi | 192.168.3.40 | 2c:bc:bb:5d:0b:f0 |
| akeem-kaisa | 192.168.3.41 | 5c:e4:2a:26:cd:ed |
| pixel8pro | 192.168.3.50 | 94:45:60:3c:50:2c |
| fp4 | 192.168.3.51 | e8:78:29:c4:90:6b |

DHCP range: 192.168.3.100 – 192.168.3.200

---

## Modbus segment (192.168.4.0/24)

| Device | IP | MAC |
|--------|----|-----|
| NanoPi Modbus gateway | 192.168.4.1 | — |
| Dantherm | 192.168.4.2 | 00:25:6f:80:04:ca |
| Omvormer (wired) | 192.168.4.3 | 2c:bc:bb:5d:0b:f3 |

Whitelist (mogen Modbus bereiken): 192.168.3.8, 192.168.3.28, 192.168.3.41, 192.168.3.50, 192.168.3.51
