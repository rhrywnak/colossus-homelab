# NEO4J_MIGRATION_PROCESS.md — Colossus-Legal

> **How we manage DEV and PROD Neo4j instances.**  
> DEV is the working instance. PROD is a milestone snapshot for the attorney.  
> Migration scripts document what changed — they're the audit trail, not the delivery mechanism.

Last updated: 2026-02-12

---

## How It Works

```
  DEV (VM-210, 10.10.100.200:7687)
    │
    │  All work happens here:
    │  - Schema changes
    │  - Document imports
    │  - Evidence grounding
    │  - Query development
    │
    │  When ready for attorney review:
    ▼
  dump/restore ──► PROD (<prod-ip>:7687)
                     │
                     └── Stable snapshot for Chuck Penzien / Marie Awad
```

**DEV** — Where you and Claude work. Break things, iterate, experiment. All Cypher runs here first.

**PROD** — A periodic snapshot of DEV at known-good milestones. Updated via `neo4j-admin` dump/restore. Nobody runs ad-hoc queries against PROD.

---

## Syncing DEV to PROD

Do this when you've reached a milestone worth showing (e.g., after completing a schema phase, after a major document import, before a meeting with the attorney).

### Step 1: Stop Neo4j on both instances

```bash
# On DEV
sudo systemctl stop neo4j

# On PROD
sudo systemctl stop neo4j
```

### Step 2: Dump DEV

```bash
# On DEV (adjust paths for your environment)
neo4j-admin database dump neo4j --to-path=/tmp/
```

### Step 3: Transfer to PROD

```bash
scp /tmp/neo4j.dump prod-host:/tmp/
```

### Step 4: Load on PROD

```bash
# On PROD
neo4j-admin database load neo4j --from-path=/tmp/neo4j.dump --overwrite-destination
```

### Step 5: Restart both

```bash
# On both instances
sudo systemctl start neo4j
```

### Step 6: Record it

Add an entry to the Sync Log below.

> **Note:** Adjust commands for your container/VM setup. If Neo4j runs in Podman,
> you may need `podman exec` or volume mount paths instead of direct filesystem access.

---

## Sync Log

| Date | Milestone | DEV State | Synced By |
|------|-----------|-----------|-----------|
| 2026-02-08 | Schema v4 migration complete | 207 nodes, 492 rels | Roman |
| | | | |

---

## Migration Scripts — The Audit Trail

Migration scripts live in `migrations/` and document every significant database change. They exist for three reasons:

1. **Documentation** — What changed, when, and why. Future-you can read `MIG-001` and understand exactly what Phase C grounding did.
2. **Emergency patching** — If PROD needs a targeted fix without a full sync, run the script directly with `cypher-shell`:
   ```bash
   cypher-shell -a bolt://prod-ip:7687 -u neo4j -p 'password' \
     -f migrations/MIG-001_phase-c_ground-coa-evidence.cypher
   ```
3. **Reproducibility** — If you ever need to rebuild the database from scratch, the migration scripts plus the source JSON files give you the complete recipe.

### Script Format

Every `.cypher` file follows this structure:

```
// ============================================================
// MIG-NNN: <Short description>
// Phase: <Schema phase letter>
// Date verified in DEV: YYYY-MM-DD
// ============================================================
//
// WHAT THIS DOES:
//   <1-3 sentence description>
//
// EXPECTED IMPACT:
//   Nodes created/modified: N
//   Rels created/modified:  N
//
// ============================================================

// --- PRE-FLIGHT AUDIT ---
// EXPECT: <what you should see>
<audit query>

// --- MUTATIONS ---
// EXPECT: N rows per query
<mutation queries>

// --- POST-FLIGHT VERIFICATION ---
// EXPECT: <what success looks like>
<verification query>

// ============================================================
// END OF MIGRATION MIG-NNN
// ============================================================
```

### When to Write a Migration Script

After work is **verified in DEV**, not before. Write it once the queries are final and tested. The script captures the finished product, not the exploration.

### Migration Index

| Migration | Description | DEV Verified |
|-----------|-------------|--------------|
| MIG-001 | Phase C: Ground 6 Phillips CoA Evidence nodes with verbatim quotes + page numbers | 2026-02-12 |

---

## Directory Structure

```
~/Projects/colossus-legal/
  migrations/
    README.md                                         ← This file
    MIG-001_phase-c_ground-coa-evidence.cypher
    MIG-002_...
```

---

## Environment Reference

| Environment | Neo4j Browser | Bolt URI | Purpose |
|-------------|---------------|----------|---------|
| **DEV** | http://10.10.100.200:7474 | bolt://10.10.100.200:7687 | All development work |
| **PROD** | http://<prod-ip>:7474 | bolt://<prod-ip>:7687 | Attorney-facing snapshot |

---

## Integration with Other Docs

- **DECISION_LOG.md** — Major schema decisions
- **PROJECT_WISDOM.md** — Lessons learned (like: `$` in Neo4j passwords needs single quotes in .env)
- **TRANSITION_DOC** — References which migrations were created per session
- **SCHEMA_EVOLUTION_v4.md** — The design. Migration scripts are the execution.
