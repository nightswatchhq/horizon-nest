-- Indexer service registrations, folded latest-wins.
--
-- This is what lets a prober reach an indexer without asking anyone's gateway who to talk to.
-- `ServiceProviderRegistered(address indexed serviceProvider, bytes data)` carries the endpoint an
-- operator published, so it is on the chain and needs no permission to read.
--
-- Latest-wins per indexer, exactly as `20-allocations.sql` folds allocation events. Operators
-- re-register when their endpoint moves and every registration stays in the log — pinax's earliest
-- points at `riv-dev1.pinax.io` while they currently serve from `indexer1.subgraphs.pinax.network`.
-- Taking any row but the newest would send traffic to a host the operator retired, and then record
-- the failure against them.
--
-- The `data` blob is deliberately NOT decoded here. It is `abi.encode(string url, string geohash, …)`
-- and unpacking it means offset arithmetic over a hex string, which is a lot of untested SQL to put
-- between us and the addresses we send paid queries to. The consumer decodes it, where the decode
-- can be unit-tested against real registrations. See `foghorn_probe::nest` on the Foghorn side.
--
-- Verified layout, from live rows: word 0 is the byte offset of `url`, word 1 the offset of
-- `geohash`; at each offset a length word, then the UTF-8 bytes.
--   0xbdfb5ee5… → https://indexer.upgrade.thegraph.com/  (geohash uzfpbrgxu)
--   0x0d6c95e9… → https://indexer-horizon.xyz            (geohash 69y7mznpj)
CREATE VIEW service_endpoints AS
SELECT indexer, data, registered_at_block
FROM (
  SELECT "serviceProvider" AS indexer,
         "data"            AS data,
         block_number      AS registered_at_block,
         row_number() OVER (
           PARTITION BY "serviceProvider"
           ORDER BY block_number DESC, log_index DESC
         ) AS rn
  FROM "service__service_provider_registered"
)
WHERE rn = 1;
