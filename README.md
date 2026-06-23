# MeshPay — Offline UPI Settlement Network

> UPI payments that survive basements, disaster zones, and dead zones — using encrypted mesh propagation and deferred settlement.

**Live Demo:** https://meshpay-hw8w.onrender.com  
**API Docs (Swagger):** https://meshpay-hw8w.onrender.com/swagger-ui.html  
**GitHub:** https://github.com/saurav7557/MeshPay

---

## What This Actually Does

Standard UPI fails the moment you lose internet. MeshPay solves this differently:

You send ₹500 in a basement with zero signal. Your phone encrypts the payment and broadcasts it to nearby phones over Bluetooth. The packet hops device-to-device — through strangers who can't read it — until one phone walks outside, gets 4G, and silently uploads it to the backend. The backend decrypts, deduplicates, and settles.

This repo is the Spring Boot backend of that system plus a software simulator of the mesh — so you can demo the entire flow on a single laptop without any real Bluetooth hardware.

**Three things this proves end-to-end:**

1. A payment can travel through untrusted intermediaries without any of them being able to read or tamper with it (hybrid RSA + AES-GCM encryption).
2. Even if the same payment arrives simultaneously from multiple bridge nodes, it settles exactly once (atomic idempotency via `ConcurrentHashMap.putIfAbsent`).
3. A tampered or replayed packet is rejected before it touches the ledger.

---

## Quick Start

### Option A — Local dev (H2 in-memory, zero setup)

**Requires:** JDK 17+ on PATH (`java -version` to check). No database, no Docker needed.

```bash
# Mac/Linux
./mvnw spring-boot:run

# Windows
mvnw.cmd spring-boot:run
```

Once you see `Started UpiMeshApplication in X.XXX seconds`, open:

- **Dashboard:** http://localhost:8080
- **Swagger UI:** http://localhost:8080/swagger-ui.html
- **H2 Console:** http://localhost:8080/h2-console (JDBC URL: `jdbc:h2:mem:upimesh`, user: `sa`, no password)

Data is wiped on every restart. Fastest way to explore the demo.

### Option B — Docker Compose (PostgreSQL, production-shaped)

**Requires:** Docker + Docker Compose.

```bash
docker compose up --build
```

Builds the app image, starts PostgreSQL, and runs with `spring.profiles.active=prod`. Data persists in a Docker volume across restarts — same configuration as the live deployment.

### Run the tests

```bash
mvnw.cmd test
```

Tests always run against the dev profile (H2). No Postgres required.

---

## The Demo Flow

The dashboard has four buttons that walk through the full pipeline:

**Step 1 — Compose a payment**  
Choose sender, receiver, amount, and PIN. Click **"📤 Inject into Mesh"**.

The backend acts as the sender's phone: it builds a `PaymentInstruction` with a unique nonce and timestamp, encrypts it using the server's RSA public key (hybrid encryption — see below), wraps the ciphertext in a `MeshPacket` with TTL=5, and hands it to `phone-alice`, an offline virtual device.

**Step 2 — Run gossip rounds**  
Click **"🔄 Run Gossip Round"** twice.

Each round, every device with a packet broadcasts it to every other device in Bluetooth range (simulated as everyone). TTL decrements per hop. After two rounds, all five virtual devices hold the same packet.

**Step 3 — Bridge node walks outside**  
Click **"📡 Bridges Upload to Backend"**.

`phone-bridge` (the only device with `hasInternet=true`) simulates walking outside and getting 4G. It POSTs every packet it holds to `/api/bridge/ingest`. Watch the Account Balances table update and a new row appear in the Transaction Ledger.

**Step 4 — Demonstrate idempotency**  
To see the duplicate-rejection in action without modifying code, run the headline test directly:

```bash
mvnw.cmd test -Dtest=IdempotencyConcurrencyTest#singlePacketDeliveredByThreeBridgesSettlesExactlyOnce
```

Three threads deliver the same packet simultaneously. Exactly one settles; the other two are rejected as `DUPLICATE_DROPPED`. The sender is debited exactly once.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                      SENDER PHONE (offline)                          │
│  PaymentInstruction { sender, receiver, amount, nonce, signedAt }    │
│              │                                                        │
│              ▼  encrypt with server RSA public key                   │
│   MeshPacket { packetId, ttl, createdAt, ciphertext }                │
└─────────────────────────────────┬────────────────────────────────────┘
                                  │  Bluetooth gossip (hop by hop)
                                  ▼
     ┌──────────┐   hop   ┌──────────┐   hop   ┌──────────┐
     │stranger 1│ ──────▶ │stranger 2│ ──────▶ │  bridge  │ ◀── walks outside
     └──────────┘         └──────────┘         └────┬─────┘     gets 4G
                                                    │
                                                    ▼  HTTPS POST
┌──────────────────────────────────────────────────────────────────────┐
│                   SPRING BOOT BACKEND (this repo)                    │
│                                                                       │
│  [1] Hash ciphertext with SHA-256                                    │
│       │                                                               │
│  [2] IdempotencyService.claim(hash)  ← atomic putIfAbsent            │
│       │    Duplicates are rejected here, before any work.            │
│       │                                                               │
│  [3] HybridCryptoService.decrypt(ciphertext)                         │
│       │    RSA-OAEP unwraps the AES key.                             │
│       │    AES-GCM decrypts the payload AND verifies the auth tag.   │
│       │    Any bit-flip in transit = exception here.                 │
│       │                                                               │
│  [4] Freshness check: signedAt within last 24 hours                  │
│       │                                                               │
│  [5] SettlementService.settle()                                       │
│       @Transactional: debit sender, credit receiver, write ledger.   │
│       @Version on Account = optimistic locking (defense in depth).   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## The Three Hard Problems

### Problem 1: Untrusted intermediaries

A random stranger's phone carries your transaction. How do you stop them from reading the amount or changing the receiver?

**Solution: Hybrid RSA-OAEP + AES-256-GCM encryption.**

RSA alone can only encrypt ~245 bytes for a 2048-bit key, and our JSON payload can exceed that. So the system uses the standard hybrid pattern (same as TLS):

1. Generate a fresh AES-256 key for this packet.
2. Encrypt the JSON with AES-256-GCM (fast, authenticated).
3. Encrypt just the AES key with RSA-OAEP.
4. Concatenate: `[256-byte RSA-encrypted AES key][12-byte IV][AES-GCM ciphertext + 16-byte auth tag]`.

GCM is specifically chosen because it's *authenticated* encryption. If any intermediate flips a single bit anywhere in the ciphertext, decryption throws an exception — the GCM auth tag won't verify. The server cannot be tricked into processing tampered data.

See: `HybridCryptoService.java`

---

### Problem 2: The duplicate storm

Three bridge nodes each hold the same packet. They all get connectivity at the same moment and POST to `/api/bridge/ingest` within milliseconds of each other. Naively processing all three would debit the sender ₹1500 instead of ₹500.

**Solution: Atomic compare-and-set on the ciphertext hash.**

The very first thing the server does is compute `SHA-256(ciphertext)` and try to claim it:

```java
// IdempotencyService.java
Instant prev = seen.putIfAbsent(packetHash, now);
return prev == null; // true = first claimer, false = duplicate
```

`ConcurrentHashMap.putIfAbsent` is atomic. Even if 100 threads call it at the exact same nanosecond, exactly one returns `null`. Only that thread proceeds to decrypt and settle. The rest are short-circuited as `DUPLICATE_DROPPED`.

**Why hash the ciphertext and not the packetId or cleartext?**

- `packetId` can be rewritten by a malicious intermediate. Two copies of the same payment could have different IDs.
- Cleartext requires decryption first. We want to deduplicate *before* spending CPU on RSA.
- Two legitimate deliveries of the same packet have byte-identical ciphertexts (AES is deterministic for the same key + IV + plaintext). One hash covers all copies.

There is also a defense-in-depth fallback: the `transactions` table has a unique index on `packet_hash`. If the cache layer somehow fails and two settlements race to write the same hash, the database rejects the second one at the constraint level.

In production this `ConcurrentHashMap` becomes Redis: `SET key NX EX 86400`. Same atomic semantics, distributed across instances.

See: `IdempotencyService.java`, `BridgeIngestionService.java`

---

### Problem 3: Replay attacks

An attacker who captured a valid ciphertext could replay it days or weeks later.

**Solution: Two layers working together.**

- The sender embeds `signedAt` (epoch millis) inside the encrypted payload. The server rejects any packet older than 24 hours. Because the timestamp is inside the GCM-authenticated payload, an attacker cannot modify it without the auth tag failing.
- The sender also embeds a `nonce` (UUID). If Alice legitimately sends Bob ₹100 twice, the nonces differ → ciphertexts differ → hashes differ → both settle. But a replay of one specific signed packet is byte-identical, so the idempotency cache catches it automatically.

See: `BridgeIngestionService.java`

---

## File Structure

```
upi-offline-mesh/
├── pom.xml                              Maven build — Spring Boot 3.3, Java 17
├── mvnw, mvnw.cmd                       Maven wrapper (no install needed)
├── Dockerfile                           Multi-stage build → lean runtime image
├── docker-compose.yml                   App + PostgreSQL wired together
└── src/main/
    ├── resources/
    │   ├── application.properties       Shared config
    │   ├── application-dev.properties   H2 in-memory (default)
    │   ├── application-prod.properties  PostgreSQL via env vars
    │   └── templates/dashboard.html     Interactive demo UI
    └── java/com/demo/upimesh/
        ├── model/                       Domain layer
        │   ├── Account.java             JPA entity. @Version = optimistic lock
        │   ├── Transaction.java         Settled-tx ledger. Unique index on packetHash
        │   ├── MeshPacket.java          Wire format. Outer fields readable; ciphertext opaque
        │   └── PaymentInstruction.java  Decrypted payload
        ├── crypto/
        │   ├── ServerKeyHolder.java     Generates RSA-2048 keypair on startup
        │   └── HybridCryptoService.java RSA-OAEP + AES-256-GCM + SHA-256 hash
        ├── service/
        │   ├── MeshSimulatorService.java Gossip protocol across virtual devices
        │   ├── IdempotencyService.java  ConcurrentHashMap = JVM-local Redis SETNX
        │   ├── SettlementService.java   @Transactional debit + credit + ledger
        │   └── BridgeIngestionService.java The full pipeline: hash → claim → decrypt → settle
        └── controller/
            ├── ApiController.java       All REST endpoints
            └── DashboardController.java Serves dashboard HTML at /
```

```
src/test/java/com/demo/upimesh/
└── IdempotencyConcurrencyTest.java      3-simultaneous-bridges test + tamper rejection test
```

---

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Dashboard UI |
| `GET` | `/swagger-ui.html` | Interactive API docs |
| `GET` | `/api/server-key` | Server RSA public key (base64) |
| `GET` | `/api/accounts` | All accounts and current balances |
| `GET` | `/api/transactions` | Last 20 settled transactions |
| `GET` | `/api/mesh/state` | Current packet state of all virtual devices |
| `POST` | `/api/demo/send` | Simulate sender phone — encrypt and inject a packet |
| `POST` | `/api/mesh/gossip` | Run one gossip round across all devices |
| `POST` | `/api/mesh/flush` | Bridge devices upload all held packets to backend |
| `POST` | `/api/mesh/reset` | Clear mesh state and idempotency cache |
| `POST` | `/api/bridge/ingest` | Production ingest endpoint — real bridges POST here |
| `GET` | `/h2-console` | Browse in-memory DB (dev profile only) |

### `/api/bridge/ingest` — Request / Response

```http
POST /api/bridge/ingest
Content-Type: application/json
X-Bridge-Node-Id: phone-bridge-42
X-Hop-Count: 3

{
  "packetId": "550e8400-e29b-41d4-a716-446655440000",
  "ttl": 2,
  "createdAt": 1730000000000,
  "ciphertext": "<base64-encoded RSA+AES blob>"
}
```

```json
{
  "outcome": "SETTLED",
  "packetHash": "a3f8c9...",
  "reason": null,
  "transactionId": 42
}
```

`outcome` is one of `SETTLED`, `DUPLICATE_DROPPED`, or `INVALID`. `reason` is populated on `INVALID`. `transactionId` is populated on `SETTLED`.

---

## Tests

```bash
mvnw.cmd test
```

Three tests are included:

**`encryptDecryptRoundTrip`** — Verifies that hybrid encryption is symmetric (encrypt → decrypt → same plaintext).

**`tamperedCiphertextIsRejected`** — Flips a single byte in the ciphertext and asserts that `BridgeIngestionService` returns `INVALID` instead of settling or crashing.

**`singlePacketDeliveredByThreeBridgesSettlesExactlyOnce`** — The headline test. Three threads deliver the same packet simultaneously. Asserts exactly one `SETTLED`, two `DUPLICATE_DROPPED`, and that the sender's balance changed by exactly the payment amount — not two or three times it.

---

## What's Not Production-Ready (and Why It's OK)

This is a portfolio and research demo. The cryptography, idempotency, and settlement logic are production-shaped. The infrastructure around them is intentionally simplified:

| This demo | Production equivalent |
|-----------|----------------------|
| H2 in-memory DB | Managed Postgres with replicas, backups, connection pooling |
| `ConcurrentHashMap` for idempotency | Redis `SET NX EX` — same atomic semantics, distributed |
| RSA keypair regenerated on startup | Private key in HSM (AWS KMS / HashiCorp Vault) |
| Software-simulated mesh | Real BLE GATT or Wi-Fi Direct between Android/iOS devices |
| No auth on `/api/bridge/ingest` | JWT + role-based access (ADMIN / BRIDGE_NODE) |
| Accounts seeded on startup | KYC'd users, real VPAs, real PIN verification |

**Roadmap (next up):**
- Redis-backed idempotency with `SETNX + TTL`, replacing the in-process `ConcurrentHashMap`
- Spring Security + JWT with `ADMIN` / `USER` / `BRIDGE_NODE` roles
- Per-sender velocity checks and fraud scoring
- Bridge node monitoring dashboard (active bridges, packets routed, success/failure rate)

---

## Honest Limitations of the Concept

**The receiver cannot verify funds offline.** When sender hands receiver a phone showing "₹500 sent," it's a deferred IOU. If the sender's account is empty when the packet finally reaches the backend, settlement is rejected and the receiver has no recourse. This is why real offline UPI (UPI Lite) uses a pre-funded hardware-backed wallet — to give cryptographic proof of available funds without connectivity.

**A malicious sender can double-spend offline.** With ₹500 in their account, they could send ₹500 to Bob in basement A and ₹500 to Carol in basement B. Whichever packet reaches the backend first settles; the other is rejected. Same root cause as above.

**Bluetooth on real devices is constrained.** Background BLE on Android has been heavily throttled since Android 8. iOS peripheral mode is locked down. Two strangers' phones reliably forming a GATT connection while apps aren't in the foreground is genuinely difficult. This demo skips that problem entirely by simulating the mesh in software.

**Privacy considerations.** A stranger carries your encrypted transaction packet. They can't read it, but its existence is metadata. A real deployment would need regulatory disclosures and a plan for device seizure scenarios.

For a portfolio presentation: name this honestly as "mesh-routed deferred settlement" rather than "real-time offline UPI." The cryptography and idempotency engineering here is real work worth showing off — the concept limitations don't diminish that.

---

## Deployment

This project deploys as a single Docker container plus a managed PostgreSQL instance. On Render or Railway:

1. Create a PostgreSQL database (one-click add-on on both platforms).
2. Create a new Web Service from this repo — it auto-detects the Dockerfile.
3. Set environment variables on the web service:

```
SPRING_PROFILES_ACTIVE=prod
DB_HOST=<host>
DB_PORT=5432
DB_NAME=<database>
DB_USER=<user>
DB_PASSWORD=<password>
PORT=<injected automatically by most platforms>
```

4. Deploy. First boot runs `spring.jpa.hibernate.ddl-auto=update`, which creates the schema automatically.

`docker compose up --build` exercises the same prod profile locally — what you test on your laptop is what runs in the cloud.

---

## Troubleshooting

**`java: command not found`** — Install JDK 17+. On Windows: `winget install EclipseAdoptium.Temurin.17.JDK` or download from [adoptium.net](https://adoptium.net).

**Port 8080 already in use** — Run with `PORT=8081 ./mvnw spring-boot:run` or change `server.port` in `application.properties`.

**First `mvnw` run is slow** — It downloads Maven (~10 MB) then dependencies (~80 MB). Allow 2–3 minutes on first run; subsequent starts take ~5 seconds.

**`mvnw.cmd` not recognized on PowerShell** — Prefix with `.\`: `.\mvnw.cmd spring-boot:run`.

**`docker compose up` fails with Postgres connection refused** — The app container sometimes starts before Postgres finishes initializing on first run. Re-run `docker compose up` — `depends_on: condition: service_healthy` handles this on subsequent starts.

---

## Tech Stack

- **Backend:** Java 17, Spring Boot 3, Spring Data JPA, Hibernate
- **Database:** PostgreSQL (production), H2 (development)
- **Security:** RSA-OAEP, AES-256-GCM, SHA-256
- **DevOps:** Docker, Docker Compose, Render
- **Docs:** Swagger UI / OpenAPI 3

---

## Author

**Saurav Kumar**  
B.Tech Information Technology — Rungta College of Engineering and Technology

[GitHub](https://github.com/saurav7557) · [LinkedIn](https://linkedin.com/in/saurav-kumar-5b03a9391) · [LeetCode](https://leetcode.com/u/sauravkumar757/)
