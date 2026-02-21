## Copy Phase 3 scripts to PVE-1
 scp -r colossus-phase3/ root@10.10.100.3:/root/
 
## Manually create zpool per scripts/01-create-prod-zfs.sh
 zpool create \
    -o ashift=12 \
    -O compression=zstd \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    prod-zfs \
    /dev/disk/by-id/YOUR_DEVICE

## Copy butane compile to PVE-1
scp colossus-prod-db1.ign root@10.10.100.3:/var/coreos/snippets/

## Prod PostgreSQL initial populate from dev backup
bash scripts/04-restore-postgres.sh \
  ~/colossus-db-backup/dev/postgres/postgres_dump_2026-02-06.sql \
  10.10.100.110
  
  
## Prod Neo4j initial populate from dev backup
bash scripts/05-restore-neo4j.sh \
  ~/colossus-db-backup/dev/neo4j/neo4j.dump \
  10.10.100.110
  
## Prod Qdrant initial populate from dev backup
bash scripts/06-restore-qdrant.sh \
  ~/colossus-db-backup/dev/qdrant/paper_chunks-8293711371686424-2026-02-06-18-05-12.snapshot \
  paper_chunks \
  10.10.100.110
 
## List node count label to test restore. match to new/old dev counts
  MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count ORDER BY count DESC;




